# ==============================================================================
# Variables & Configuration
# ==============================================================================
-include .env
export

KUBECTL             ?= kubectl
HELM                ?= helm
NAMESPACES_DIR      := namespaces
TAILSCALE_NAMESPACE ?= infrastructure
HEADLAMP_NAMESPACE  ?= infrastructure
HEADLAMP_DIR        ?= applications/headlamp
ARGOCD_NAMESPACE    ?= argocd


# ==============================================================================
# General & Cluster Targets
# ==============================================================================
.PHONY: help check-cluster run

help: ## Show available commands
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check-cluster: ## Verify connection to the Kubernetes cluster
	@echo "Checking Kubernetes cluster connection..."
	@$(KUBECTL) cluster-info > /dev/null 2>&1 || (echo "Error: Cannot connect to cluster. Check your KUBECONFIG." && exit 1)
	@echo "Connected to cluster: $$(kubectl config current-context)"

run: check-cluster apply-namespaces install-tailscale install-argocd deploy-apps deploy-headlamp ## Full stack setup: Namespaces, Tailscale, Argo CD, apps, and Headlamp
	@echo ""
	@echo "================================================================="
	@echo "🚀 Full dynamic stack deployment completed successfully!"
	@echo "================================================================="


# ==============================================================================
# Namespaces
# ==============================================================================
.PHONY: apply-namespaces delete-namespaces status-namespaces

apply-namespaces: check-cluster ## Create or update all core namespaces
	@echo "Applying namespaces..."
	@$(KUBECTL) apply -f $(NAMESPACES_DIR)/

delete-namespaces: check-cluster ## Delete all managed namespaces (Caution!)
	@echo "Deleting namespaces..."
	@$(KUBECTL) delete -f $(NAMESPACES_DIR)/ --ignore-not-found

status-namespaces: check-cluster ## Check status of managed namespaces
	@echo "Namespace status:"
	@$(KUBECTL) get ns infrastructure monitoring applications argocd -o wide --ignore-not-found


# ==============================================================================
# Tailscale Operator
# ==============================================================================
TAILSCALE_CHART_VERSION ?=

.PHONY: helm-repo-tailscale install-tailscale uninstall-tailscale

helm-repo-tailscale: ## Add and update Tailscale Helm repository
	@echo "Adding and updating Tailscale Helm repository..."
	@$(HELM) repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update
	@$(HELM) repo update tailscale

install-tailscale: check-cluster helm-repo-tailscale ## Install or upgrade Tailscale Operator
	@if [ -z "$(TAILSCALE_CLIENT_ID)" ] || [ -z "$(TAILSCALE_CLIENT_SECRET)" ]; then \
		echo "Error: TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET must be set in .env or environment"; \
		exit 1; \
	fi
	@echo "Installing/Upgrading Tailscale Operator into namespace '$(TAILSCALE_NAMESPACE)'..."
	@$(HELM) upgrade --install tailscale-operator tailscale/tailscale-operator \
		--namespace $(TAILSCALE_NAMESPACE) \
		-f infrastructure/tailscale-values.yaml \
		--set oauth.clientId="$(TAILSCALE_CLIENT_ID)" \
		--set oauth.clientSecret="$(TAILSCALE_CLIENT_SECRET)" \
		$(if $(TAILSCALE_CHART_VERSION),--version $(TAILSCALE_CHART_VERSION)) \
		--wait
	@echo "Tailscale Operator successfully installed."

uninstall-tailscale: check-cluster ## Remove Tailscale Operator
	@echo "Uninstalling Tailscale Operator..."
	@$(HELM) uninstall tailscale-operator --namespace $(TAILSCALE_NAMESPACE) --ignore-not-found


# ==============================================================================
# Argo CD
# ==============================================================================
.PHONY: helm-repo-argo install-argocd uninstall-argocd status-argocd get-argocd-password

helm-repo-argo: ## Add and update Argo Helm repository
	@echo "Adding Argo Helm repository..."
	@$(HELM) repo add argo https://argoproj.github.io/argo-helm --force-update
	@$(HELM) repo update argo

install-argocd: check-cluster ## Install or upgrade Argo CD (Uses local cached chart if present)
	@echo "Installing/Upgrading Argo CD in namespace '$(ARGOCD_NAMESPACE)'..."
	@if [ -f "charts/argo-cd-10.3.2.tgz" ]; then \
		echo "Using local chart tarball charts/argo-cd-10.3.2.tgz..."; \
		$(HELM) upgrade --install argocd charts/argo-cd-10.3.2.tgz \
			--namespace $(ARGOCD_NAMESPACE) \
			-f infrastructure/argocd-values.yaml; \
	else \
		echo "Local chart not found, fetching from remote repo..."; \
		$(MAKE) helm-repo-argo; \
		$(HELM) upgrade --install argocd argo/argo-cd \
			--namespace $(ARGOCD_NAMESPACE) \
			-f infrastructure/argocd-values.yaml; \
	fi
	@echo "Argo CD deployment submitted successfully."

uninstall-argocd: ## Completely uninstall Argo CD and remove its namespace
	@echo "Uninstalling Argo CD release..."
	@$(HELM) uninstall argocd --namespace $(ARGOCD_NAMESPACE) || true
	@echo "Removing Argo CD namespace..."
	@kubectl delete namespace $(ARGOCD_NAMESPACE) --timeout=60s || true
	@echo "Argo CD cleanup complete."

status-argocd: check-cluster ## Check Argo CD pods, service, and ingress
	@$(KUBECTL) get pods,svc,ingress -n $(ARGOCD_NAMESPACE)

get-argocd-password: check-cluster ## Fetch initial admin password for Argo CD
	@echo "Argo CD Admin Username: admin"
	@echo -n "Argo CD Admin Password: "
	@$(KUBECTL) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode
	@echo ""


# ==============================================================================
# Vaultwarden
# ==============================================================================
.PHONY: deploy-vaultwarden delete-vaultwarden status-vaultwarden

deploy-vaultwarden: check-cluster ## Deploy Vaultwarden with PVC and Tailscale Ingress
	@echo "Deploying Vaultwarden to 'applications' namespace..."
	@$(KUBECTL) apply -f applications/vaultwarden/
	@echo "Vaultwarden deployed. Check ingress for MagicDNS hostname:"
	@echo "  kubectl get ingress vaultwarden -n applications"

delete-vaultwarden: check-cluster ## Delete Vaultwarden application
	@echo "Deleting Vaultwarden application..."
	@$(KUBECTL) delete -f applications/vaultwarden/ --ignore-not-found

status-vaultwarden: check-cluster ## Check Vaultwarden pods and ingress status
	@$(KUBECTL) get pods,svc,ingress -n applications -l app=vaultwarden


# ==============================================================================
# Headlamp Dashboard
# ==============================================================================
.PHONY: deploy-headlamp delete-headlamp status-headlamp get-headlamp-token

deploy-headlamp: check-cluster ## Deploy Headlamp dashboard via Helm and apply manifests
	@echo "Adding and updating Headlamp Helm repository..."
	@$(HELM) repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update
	@$(HELM) repo update headlamp
	@echo "Installing/Upgrading Headlamp release..."
	@$(HELM) upgrade --install headlamp headlamp/headlamp \
		--namespace $(HEADLAMP_NAMESPACE) \
		-f $(HEADLAMP_DIR)/values.yaml
	@echo "Applying Headlamp RBAC and Ingress..."
	@$(KUBECTL) apply -f $(HEADLAMP_DIR)/rbac.yaml
	@$(KUBECTL) apply -f $(HEADLAMP_DIR)/ingress.yaml
	@echo "Headlamp deployment completed successfully."

delete-headlamp: check-cluster ## Delete Headlamp application
	@echo "Deleting Headlamp resources..."
	@$(KUBECTL) delete -f $(HEADLAMP_DIR)/ingress.yaml --ignore-not-found
	@$(KUBECTL) delete -f $(HEADLAMP_DIR)/rbac.yaml --ignore-not-found
	@$(HELM) uninstall headlamp -n $(HEADLAMP_NAMESPACE) --ignore-not-found

status-headlamp: check-cluster ## Check Headlamp pods, service, and ingress status
	@$(KUBECTL) get pods,svc,ingress -n $(HEADLAMP_NAMESPACE)

get-headlamp-token: check-cluster ## Fetch the admin bearer token for Headlamp login
	@echo "Headlamp Admin Bearer Token:"
	@$(KUBECTL) get secret headlamp-admin-token -n $(HEADLAMP_NAMESPACE) -o jsonpath='{.data.token}' | base64 --decode
	@echo ""


# ==============================================================================
# Dynamic Applications
# ==============================================================================
.PHONY: deploy-apps delete-apps

deploy-apps: check-cluster ## Dynamically deploy all applications found in applications/
	@echo "==> Discovering and deploying all applications..."
	@for app_dir in applications/*/; do \
		if [ -d "$$app_dir" ] && [ "$$app_dir" != "applications/headlamp/" ]; then \
			app_name=$$(basename "$$app_dir"); \
			echo "--> Deploying application: $$app_name"; \
			$(KUBECTL) apply -f "$$app_dir"; \
		fi; \
	done
	@echo "==> All applications deployed successfully."

delete-apps: check-cluster ## Dynamically delete all applications found in applications/
	@echo "==> Deleting all applications..."
	@for app_dir in applications/*/; do \
		if [ -d "$$app_dir" ] && [ "$$app_dir" != "applications/headlamp/" ]; then \
			app_name=$$(basename "$$app_dir"); \
			echo "--> Deleting application: $$app_name"; \
			$(KUBECTL) delete -f "$$app_dir" --ignore-not-found; \
		fi; \
	done


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

clean: delete-headlamp delete-vaultwarden uninstall-tailscale uninstall-argocd delete-apps delete-namespaces ## Completely wipe out all apps, operators, and namespaces
	@echo ""
	@echo "================================================================="
	@echo "🧹 Full cluster cleanup completed successfully!"
	@echo "================================================================="
