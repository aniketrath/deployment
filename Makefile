# Variables
KUBECTL ?= kubectl
NAMESPACES_DIR := namespaces

.PHONY: help check-cluster apply-namespaces delete-namespaces status-namespaces

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
