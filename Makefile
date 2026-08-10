# Variables
-include .env
KUBECTL ?= kubectl
NAMESPACES_DIR := namespaces
TAILSCALE_NAMESPACE ?= infrastructure
HELM ?= helm
export

.PHONY: help check-cluster apply-namespaces delete-namespaces status-namespaces helm-repo install-tailscale uninstall-tailscale  deploy-vaultwarden delete-vaultwarden status-vaultwarden

help: ## Show available commands
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check-cluster: ## Verify connection to the Kubernetes cluster
	@echo "Checking Kubernetes cluster connection..."
	@$(KUBECTL) cluster-info > /dev/null 2>&1 || (echo "Error: Cannot connect to cluster. Check your KUBECONFIG." && exit 1)
	@echo "Connected to cluster: $$(kubectl config current-context)"

apply-namespaces: check-cluster ## Create or update all core namespaces
	@echo "Applying namespaces..."
	@$(KUBECTL) apply -f $(NAMESPACES_DIR)/

delete-namespaces: check-cluster ## Delete all managed namespaces (Caution!)
	@echo "Deleting namespaces..."
	@$(KUBECTL) delete -f $(NAMESPACES_DIR)/ --ignore-not-found

status-namespaces: check-cluster ## Check status of managed namespaces
	@echo "Namespace status:"
	@$(KUBECTL) get ns infrastructure monitoring applications -o wide --ignore-not-found

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
