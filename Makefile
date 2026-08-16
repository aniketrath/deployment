#######################################################################
# .env & Variables
#######################################################################
ARGOCD_NAMESPACE   ?= argocd
HEADLAMP_NAMESPACE ?= infrastructure
HELM               ?= helm
KUBECTL            ?= kubectl

#######################################################################
# Naming convention for per-app targets:
#   install-<app>  - first-time Helm install/upgrade
#   status-<app>   - pods/svc/ingress status for that app's namespace
#   creds-<app>    - print login credentials (password, token, etc.)
# `deploy-<scope>` is reserved for bulk/wave-based manual applies,
# not individual apps (e.g. deploy-wave-infra).
#######################################################################

.PHONY: help setup-prerequisites add-helm-repos deploy-argocd-stack install-argocd uninstall-argocd status-argocd creds-argocd deploy-wave-infra status-headlamp creds-headlamp check-cluster

help:
	@echo "Available Makefile targets:"
	@echo "  setup-prerequisites  - Add all Helm repos and install cluster prerequisites (Reflector)"
	@echo "  deploy-argocd-stack  - Install Argo CD stack and apply the root ApplicationSet"
	@echo "  uninstall-argocd     - Remove Argo CD release and associated root apps"
	@echo "  status-argocd        - Check status of Argo CD pods, services, and ingress"
	@echo "  creds-argocd         - Retrieve initial Argo CD admin password"
	@echo "  deploy-wave-infra    - Manually apply Wave -1 infrastructure (Postgres, Redis, Tailscale)"
	@echo "  status-headlamp      - Check status of Headlamp pods, service, and ingress (deployed via ArgoCD)"
	@echo "  creds-headlamp       - Retrieve Headlamp admin bearer token"

# ==============================================================================
# Prerequisites & Helm Repositories
# ==============================================================================
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
# ==============================================================================
deploy-wave-infra: check-cluster
	@echo "===> Deploying Wave -1: Postgres, Redis, and Tailscale manifests manually..."
	@$(KUBECTL) apply -f applications/postgres/
	@$(KUBECTL) apply -f applications/redis/
	@$(KUBECTL) apply -f applications/tailscale/
	@echo "===> Wave -1 infrastructure deployed successfully!"

# ==============================================================================
# Headlamp Dashboard (deployed via ArgoCD Application — see applications/headlamp/)
# Deploy/delete are owned by Argo's sync loop; these targets are for local
# inspection only.
# ==============================================================================
status-headlamp: check-cluster
	@$(KUBECTL) get pods,svc,ingress -n $(HEADLAMP_NAMESPACE)

creds-headlamp: check-cluster
	@echo "Headlamp Admin Bearer Token:"
	@$(KUBECTL) get secret headlamp-admin-token -n $(HEADLAMP_NAMESPACE) -o jsonpath='{.data.token}' | base64 --decode
	@echo ""

# ==============================================================================
# Helper Targets
# ==============================================================================
check-cluster:
	@$(KUBECTL) cluster-info >/dev/null 2>&1 || (echo "Error: Kubernetes cluster is not accessible." && exit 1)