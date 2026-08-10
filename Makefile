# ==============================================================================
# Variables & Configuration
# ==============================================================================
-include .env
export

KUBECTL             ?= kubectl
HELM                ?= helm
NAMESPACES_DIR      := namespaces
TAILSCALE_NAMESPACE ?= infrastructure
HEADLAMP_NAMESPACE  ?= headlamp
HEADLAMP_DIR        ?= applications/headlamp


# ==============================================================================
# General & Cluster Targets
# ==============================================================================
.PHONY: help check-cluster

help: ## Show available commands
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check-cluster: ## Verify connection to the Kubernetes cluster
	@echo "Checking Kubernetes cluster connection..."
	@$(KUBECTL) cluster-info > /dev/null 2>&1 || (echo "Error: Cannot connect to cluster. Check your KUBECONFIG." && exit 1)
	@echo "Connected to cluster: $$(kubectl config current-context)"


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
	@$(KUBECTL) get ns infrastructure monitoring applications -o wide --ignore-not-found


# ==============================================================================
# Tailscale Operator
# ==============================================================================
.PHONY: helm-repo install-tailscale uninstall-tailscale

helm-repo: ## Add Tailscale Helm repository
	@echo "Adding Tailscale Helm repository..."
	@$(HELM) repo add tailscale https://pkgs.tailscale.com/helmcharts
	@$(HELM) repo update

install-tailscale: check-cluster helm-repo ## Install or upgrade Tailscale Operator
	@if [ -z "$(TAILSCALE_CLIENT_ID)" ] || [ -z "$(TAILSCALE_CLIENT_SECRET)" ]; then \
		echo "Error: TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET must be set in .env or environment"; \
		exit 1; \
	fi
	@echo "Installing Tailscale Operator into namespace '$(TAILSCALE_NAMESPACE)'..."
	@$(HELM) upgrade --install tailscale-operator tailscale/tailscale-operator \
		--namespace $(TAILSCALE_NAMESPACE) \
		-f infrastructure/tailscale-values.yaml \
		--set oauth.clientId="$(TAILSCALE_CLIENT_ID)" \
		--set oauth.clientSecret="$(TAILSCALE_CLIENT_SECRET)" \
		--wait
	@echo "Tailscale Operator successfully installed."

uninstall-tailscale: check-cluster ## Remove Tailscale Operator
	@echo "Uninstalling Tailscale Operator..."
	@$(HELM) uninstall tailscale-operator --namespace $(TAILSCALE_NAMESPACE) --ignore-not-found


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
	@$(KUBECTL) get pods,svc,ingress -n applications -l app.kubernetes.io/name=vaultwarden


# ==============================================================================
# Headlamp Dashboard
# ==============================================================================
.PHONY: deploy-headlamp delete-headlamp status-headlamp get-headlamp-token

deploy-headlamp: check-cluster ## Deploy Headlamp dashboard via Helm and apply manifests
	@echo "Ensuring namespace '$(HEADLAMP_NAMESPACE)' exists..."
	@$(KUBECTL) create namespace $(HEADLAMP_NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
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

delete-headlamp: check-cluster ## Delete Headlamp application and namespace
	@echo "Deleting Headlamp resources..."
	@$(KUBECTL) delete -f $(HEADLAMP_DIR)/ingress.yaml --ignore-not-found
	@$(KUBECTL) delete -f $(HEADLAMP_DIR)/rbac.yaml --ignore-not-found
	@$(HELM) uninstall headlamp -n $(HEADLAMP_NAMESPACE) --ignore-not-found || true
	@$(KUBECTL) delete namespace $(HEADLAMP_NAMESPACE) --ignore-not-found

status-headlamp: check-cluster ## Check Headlamp pods, service, and ingress status
	@$(KUBECTL) get pods,svc,ingress -n $(HEADLAMP_NAMESPACE)

get-headlamp-token: check-cluster ## Fetch the admin bearer token for Headlamp login
	@echo "Headlamp Admin Bearer Token:"
	@$(KUBECTL) get secret headlamp-admin-token -n $(HEADLAMP_NAMESPACE) -o jsonpath='{.data.token}' | base64 --decode
	@echo ""
