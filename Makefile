#######################################################################
# .env & Variables
#######################################################################
ARGOCD_NAMESPACE   ?= argocd
HEADLAMP_NAMESPACE ?= infrastructure
NAMESPACES_DIR     ?= namespaces
HELM               ?= helm
KUBECTL            ?= kubectl

#######################################################################
# Naming convention for targets:
#   install-<app>            - first-time Helm install/upgrade for a single app
#   status-<app>/<scope>     - pods/svc/ingress status
#   creds-<app>              - print login credentials (password, token, etc.)
#   deploy-<scope>           - bulk manual apply across several manifests/apps
#   clean-<scope>            - bulk manual teardown, mirrors deploy-<scope>
#######################################################################

.PHONY: help check-cluster

help:
	@echo "Available Makefile targets:"
	@echo "  clean                 - Full teardown: Argo CD, wave infra, namespaces, finalizer stripping"
	@echo "  clean-namespaces      - Delete all managed namespaces (Caution!)"
	@echo "  clean-wave-infra      - Manually remove Wave -1 infrastructure"
	@echo "  creds-argocd          - Retrieve initial Argo CD admin password"
	@echo "  creds-headlamp        - Retrieve Headlamp admin bearer token"
	@echo "  deploy-argocd-stack   - Install Argo CD stack and apply the root ApplicationSet"
	@echo "  deploy-namespaces     - Create or update all core namespaces"
	@echo "  deploy-wave-infra     - Manually apply Wave -1 infrastructure (Postgres, Redis)"
	@echo "  install-argocd        - Install/upgrade Argo CD only"
	@echo "  setup-prerequisites   - Add all Helm repos and install cluster prerequisites (Reflector)"
	@echo "  status-argocd         - Check status of Argo CD pods, services, and ingress"
	@echo "  status-headlamp       - Check status of Headlamp pods, service, and ingress (deployed via ArgoCD)"
	@echo "  status-namespaces     - Check status of managed namespaces"
	@echo "  test                  - Run all local CI checks (lint, schema validation, security scan)"
	@echo "  uninstall-argocd      - Remove Argo CD release and associated root apps"

check-cluster:
	@$(KUBECTL) cluster-info >/dev/null 2>&1 || (echo "Error: Kubernetes cluster is not accessible." && exit 1)

# ==============================================================================
# Namespaces
# ==============================================================================
.PHONY: status-namespaces deploy-namespaces clean-namespaces

status-namespaces: check-cluster ## Check status of managed namespaces
	@$(KUBECTL) get ns infrastructure monitoring applications argocd -o wide --ignore-not-found

deploy-namespaces: check-cluster ## Create or update all core namespaces
	@echo "===> Applying namespaces..."
	@$(KUBECTL) apply -f $(NAMESPACES_DIR)/

clean-namespaces: check-cluster ## Delete all managed namespaces (Caution!)
	@echo "===> Deleting namespaces..."
	@$(KUBECTL) delete -f $(NAMESPACES_DIR)/ --ignore-not-found

# ==============================================================================
# Prerequisites & Helm Repositories
# ==============================================================================
.PHONY: setup-prerequisites add-helm-repos

setup-prerequisites: add-helm-repos
	@echo "===> Installing Kubernetes Reflector controller..."
	@$(HELM) upgrade --install reflector emberstack/reflector \
		--namespace kube-system \
		--wait
	@echo "===> Prerequisites setup complete!"

add-helm-repos:
	@echo "===> Adding and updating all required Helm repositories..."
	@$(HELM) repo add argo https://argoproj.github.io/argo-helm --force-update
	@$(HELM) repo add emberstack https://emberstack.github.io/helm-charts --force-update
	@$(HELM) repo update

# ==============================================================================
# Argo CD (GitOps Controller)
# ==============================================================================
.PHONY: deploy-argocd-stack install-argocd uninstall-argocd status-argocd creds-argocd

deploy-argocd-stack: add-helm-repos install-argocd status-argocd creds-argocd

install-argocd: check-cluster
	@echo "Installing/Upgrading Argo CD in namespace '$(ARGOCD_NAMESPACE)'..."
	@if [ -f "charts/argo-cd-10.3.2.tgz" ]; then \
		echo "Using local chart tarball charts/argo-cd-10.3.2.tgz..."; \
		$(HELM) upgrade --install argocd charts/argo-cd-10.3.2.tgz \
			--namespace $(ARGOCD_NAMESPACE) \
			-f infrastructure/argocd-values.yaml; \
	else \
		echo "Local chart not found, fetching from remote repo..."; \
		$(HELM) upgrade --install argocd argo/argo-cd \
			--namespace $(ARGOCD_NAMESPACE) \
			-f infrastructure/argocd-values.yaml; \
	fi
	@echo "Waiting for Argo CD server to be ready before applying bootstrap..."
	@$(KUBECTL) rollout status deployment argocd-server -n $(ARGOCD_NAMESPACE) --timeout=120s
	@echo "Applying root ApplicationSet (deployments)..."
	@$(KUBECTL) apply -f bootstrap/argocd.yaml
	@echo "Argo CD deployment and application bootstrap completed successfully."

uninstall-argocd:
	@echo "Uninstalling Argo CD release..."
	-@$(KUBECTL) delete application root-applications -n $(ARGOCD_NAMESPACE) --ignore-not-found=true
	@$(HELM) uninstall argocd --namespace $(ARGOCD_NAMESPACE) --ignore-not-found || true
	@echo "Argo CD helm cleanup complete."

status-argocd: check-cluster
	@$(KUBECTL) get pods,svc,ingress -n $(ARGOCD_NAMESPACE)

creds-argocd: check-cluster
	@echo "Argo CD Admin Username: admin"
	@echo -n "Argo CD Admin Password: "
	@$(KUBECTL) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode
	@echo ""

# ==============================================================================
# Manual Infrastructure Deployment (Wave -1)
# Bootstrap-only: applied by hand before Argo CD exists to run these itself.
# ==============================================================================
.PHONY: deploy-wave-infra clean-wave-infra

deploy-wave-infra: check-cluster
	@echo "===> Deploying Wave -1: Postgres and Redis manifests manually..."
	@$(KUBECTL) apply -f applications/postgres/
	@$(KUBECTL) apply -f applications/redis/
	@echo "===> Wave -1 infrastructure deployed successfully!"

clean-wave-infra: check-cluster
	@echo "===> Removing Wave -1: Postgres and Redis manifests manually..."
	@$(KUBECTL) delete -f applications/redis/ --ignore-not-found
	@$(KUBECTL) delete -f applications/postgres/ --ignore-not-found
	@echo "===> Wave -1 infrastructure removed."

# ==============================================================================
# Headlamp Dashboard (deployed via ArgoCD Application — see applications/headlamp/)
# Install/delete are owned by Argo's sync loop; these targets are for local
# inspection only.
# ==============================================================================
.PHONY: status-headlamp creds-headlamp

status-headlamp: check-cluster
	@$(KUBECTL) get pods,svc,ingress -n $(HEADLAMP_NAMESPACE)

creds-headlamp: check-cluster
	@echo "Headlamp Admin Bearer Token:"
	@$(KUBECTL) get secret headlamp-admin-token -n $(HEADLAMP_NAMESPACE) -o jsonpath='{.data.token}' | base64 --decode
	@echo ""

# ==============================================================================
# Local Testing & Linting (Mirrors GitLab CI)
# ==============================================================================
.PHONY: test lint-yaml validate-schemas scan-security

lint-yaml: ## Check YAML syntax locally
	@echo "==> Running yamllint..."
	yamllint applications/ namespaces/ infrastructure/

validate-schemas: ## Validate Kubernetes schemas with kubeconform
	@echo "==> Running kubeconform..."
	find applications/ namespaces/ infrastructure/ -type f \( -name "*.yaml" -o -name "*.yml" \) ! -name "*values*" -print0 | xargs -0 kubeconform -summary -strict -ignore-missing-schemas

scan-security: ## Scan manifests for security risks with Trivy
	@echo "==> Running trivy security scan..."
	trivy config --severity HIGH,CRITICAL .

test: lint-yaml validate-schemas scan-security ## Run all CI checks locally in one command
	@echo "==> All local checks passed successfully!"

# ==============================================================================
# Full Cleanup
# ==============================================================================
.PHONY: clean

# NOTE: Headlamp, Vaultwarden, and Tailscale are all deployed as ArgoCD
# Applications now and are NOT torn down here individually — deleting
# root-applications above (via uninstall-argocd) cascades to them, provided
# cascade delete / finalizers are enabled on those Application resources.
# If an app ever needs a standalone teardown outside of Argo, add a
# `clean-<app>` target for it here.
clean: check-cluster uninstall-argocd clean-wave-infra clean-namespaces ## Completely wipe out all apps, operators, and namespaces with dynamic finalizer stripping
	@echo "==> Cleaning up lingering ingress finalizers across all dynamic namespaces..."
	@for ns in $$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
		if [ "$$ns" != "kube-system" ] && [ "$$ns" != "kube-public" ] && [ "$$ns" != "kube-node-lease" ] && [ "$$ns" != "default" ]; then \
			for ing in $$(kubectl get ingress -n $$ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
				kubectl patch ingress $$ing -n $$ns --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true; \
			done; \
			kubectl get namespace $$ns -o json 2>/dev/null | tr -d '\n' | sed 's/"finalizers":\[[^]]*\]/"finalizers":\[\]/' | kubectl replace --raw /api/v1/namespaces/$$ns/finalize -f - 2>/dev/null || true; \
		fi; \
	done
	@echo "==> Deleting all custom namespaces..."
	@for ns in $$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
		if [ "$$ns" != "kube-system" ] && [ "$$ns" != "kube-public" ] && [ "$$ns" != "kube-node-lease" ] && [ "$$ns" != "default" ]; then \
			kubectl delete namespace $$ns --ignore-not-found=true --timeout=5s 2>/dev/null || true; \
		fi; \
	done
	@echo ""
	@echo "================================================================="
	@echo "Full cluster cleanup completed successfully!"