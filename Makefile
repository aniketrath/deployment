#######################################################################
# .env & Variables
#######################################################################
FLUX_NAMESPACE     ?= flux-system
FLUX_PATH          ?= clusters/staging
GITLAB_OWNER       ?= stackcraft
GITLAB_REPO        ?= deployment
GIT_BRANCH         ?= staging
HEADLAMP_NAMESPACE ?= infrastructure
NAMESPACES_DIR     ?= namespaces
DEPLOYMENTS_DIR    ?= deployments
FLUX               ?= flux
HELM               ?= helm
KUBECTL            ?= kubectl
PYTHON             ?= python3
YAMLLINT           ?= yamllint
KUBECONFORM        ?= kubeconform
TRIVY              ?= trivy
KUBECONFORM_CACHE  ?= .cache/kubeconform
TRIVY_IGNOREFILE   ?= .trivyignore.yaml
# Public catalog of real JSON Schemas for popular CRDs (Flux, cert-manager, etc.),
# generated from the CRDs themselves. See https://github.com/datreeio/CRDs-catalog
CRD_SCHEMA_LOCATION ?= https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

#######################################################################
# Naming convention for targets:
#   install-<app>            - first-time Helm install/upgrade for a single app
#   status-<app>/<scope>     - pods/svc/ingress status
#   creds-<app>              - print login credentials (password, token, etc.)
#   deploy-<scope>           - bulk manual apply across several manifests/apps
#   clean-<scope>            - bulk manual teardown, mirrors deploy-<scope>
#   reconcile-<tier>         - force Flux to re-sync a specific Kustomization now
#######################################################################

.PHONY: help check-cluster

help:
	@echo "Available Makefile targets:"
	@echo "  bootstrap-flux        - Bootstrap Flux against this repo (GITLAB_TOKEN required)"
	@echo "  clean                 - Full teardown: Flux, namespaces, finalizer stripping"
	@echo "  clean-namespaces      - Delete all managed namespaces (Caution!)"
	@echo "  creds-headlamp        - Retrieve Headlamp admin bearer token"
	@echo "  deploy-namespaces     - Manually apply core namespaces (break-glass only; Flux owns this)"
	@echo "  install-test-tools    - Install/verify local CLI tools needed by 'make test' (yamllint, kubeconform, trivy, PyYAML)"
	@echo "  reconcile-<tier>      - Force Flux to reconcile now (namespaces|infra-postgres|infra-redis|apps-infisical|apps-vaultwarden)"
	@echo "  setup-prerequisites   - Add all Helm repos and install cluster prerequisites (Reflector)"
	@echo "  status-flux           - Check status of all Flux Kustomizations, HelmReleases, and sources"
	@echo "  status-headlamp       - Check status of Headlamp pods, service, and ingress (deployed via Flux HelmRelease)"
	@echo "  status-namespaces     - Check status of managed namespaces"
	@echo "  test                  - Run all local CI checks (lint, schema + Flux CRD validation, Flux build/graph validation, security scan)"
	@echo "  uninstall-flux        - Remove Flux controllers and CRDs (does NOT remove already-applied workloads)"

check-cluster:
	@$(KUBECTL) cluster-info >/dev/null 2>&1 || (echo "Error: Kubernetes cluster is not accessible." && exit 1)

# ==============================================================================
# Namespaces
# ==============================================================================
.PHONY: status-namespaces deploy-namespaces clean-namespaces

status-namespaces: check-cluster ## Check status of managed namespaces
	@$(KUBECTL) get ns infrastructure applications tailscale flux-system -o wide --ignore-not-found

deploy-namespaces: check-cluster ## Manually apply core namespaces (break-glass only; Flux's "namespaces" Kustomization owns this in normal operation)
	@echo "===> Applying namespaces..."
	@$(KUBECTL) apply -f $(NAMESPACES_DIR)/

clean-namespaces: check-cluster ## Delete all managed namespaces (Caution!)
	@echo "===> Deleting namespaces..."
	@$(KUBECTL) delete -f $(NAMESPACES_DIR)/ --ignore-not-found

# ==============================================================================
# Prerequisites & Helm Repositories
# ==============================================================================
.PHONY: setup-prerequisites add-helm-repos install-test-tools

setup-prerequisites: add-helm-repos ## Install cluster-side prerequisites (Helm-managed)
	@echo "===> Installing Kubernetes Reflector controller..."
	@$(HELM) upgrade --install reflector emberstack/reflector \
		--namespace kube-system \
		--wait
	@echo "===> Prerequisites setup complete!"

add-helm-repos:
	@echo "===> Adding and updating all required Helm repositories..."
	@$(HELM) repo add emberstack https://emberstack.github.io/helm-charts --force-update
	@$(HELM) repo update

# NOTE: yamllint, kubeconform, trivy, and PyYAML are local CLI/library tooling
# used only to lint and dry-run manifests on your machine before anything is
# ever applied to a cluster - they are not Kubernetes workloads, so Helm has
# nothing to install here. This target is the local-tooling equivalent of
# setup-prerequisites: idempotent, and safe to re-run any time.
install-test-tools: ## Install/verify local CLI tools needed by 'make test'
	@echo "===> Checking local test tooling..."
	@command -v $(PYTHON) >/dev/null 2>&1 || (echo "Error: python3 is required and was not found on PATH." && exit 1)
	@$(PYTHON) -c "import yaml" >/dev/null 2>&1 || { \
		echo "--> Installing PyYAML (required by scripts/validate-flux-deps.py)..."; \
		$(PYTHON) -m pip install --user pyyaml || exit 1; \
	}
	@command -v $(YAMLLINT) >/dev/null 2>&1 || { \
		echo "--> Installing yamllint..."; \
		$(PYTHON) -m pip install --user yamllint || exit 1; \
	}
	@command -v $(KUBECONFORM) >/dev/null 2>&1 || { \
		echo "--> Installing kubeconform..."; \
		if command -v brew >/dev/null 2>&1; then \
			brew install kubeconform; \
		elif command -v go >/dev/null 2>&1; then \
			go install github.com/yannh/kubeconform/cmd/kubeconform@latest; \
		else \
			echo "Error: kubeconform not found and no brew/go available to install it."; \
			echo "        Install manually: https://github.com/yannh/kubeconform#installation"; \
			exit 1; \
		fi; \
	}
	@command -v $(TRIVY) >/dev/null 2>&1 || { \
		echo "--> Installing trivy..."; \
		if command -v brew >/dev/null 2>&1; then \
			brew install trivy; \
		else \
			curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
				| sh -s -- -b /usr/local/bin || { \
					echo "Error: trivy install script failed."; \
					echo "        Install manually: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"; \
					exit 1; \
				}; \
		fi; \
	}
	@mkdir -p $(KUBECONFORM_CACHE)
	@echo "===> All test tooling present."

# ==============================================================================
# Flux (GitOps Controller)
# ==============================================================================
.PHONY: bootstrap-flux uninstall-flux status-flux reconcile-%

bootstrap-flux: check-cluster ## Bootstrap Flux against this repo (requires GITLAB_TOKEN env var, api scope)
	@if [ -z "$$GITLAB_TOKEN" ]; then \
		echo "Error: GITLAB_TOKEN is not set."; exit 1; \
	fi
	@echo "Bootstrapping Flux ($(GIT_BRANCH) branch, path $(FLUX_PATH))..."
	@$(FLUX) bootstrap gitlab \
		--owner=$(GITLAB_OWNER) \
		--repository=$(GITLAB_REPO) \
		--branch=$(GIT_BRANCH) \
		--path=$(FLUX_PATH) \
		--token-auth \
		--personal
	@echo "Waiting for all Kustomizations to reconcile..."
	@$(FLUX) get kustomizations
	@echo "Flux bootstrap complete."

uninstall-flux: check-cluster ## Remove Flux controllers and CRDs only (workloads already applied remain running)
	@echo "Uninstalling Flux..."
	@$(FLUX) uninstall --namespace=$(FLUX_NAMESPACE) --silent
	@echo "Flux controller cleanup complete."

status-flux: check-cluster
	@echo "===> Kustomizations:"
	@$(FLUX) get kustomizations
	@echo "===> HelmReleases:"
	@$(FLUX) get helmreleases --all-namespaces
	@echo "===> Sources:"
	@$(FLUX) get sources git

reconcile-%: check-cluster ## Force Flux to reconcile a specific tier now, e.g. `make reconcile-apps-infisical`
	@$(FLUX) reconcile kustomization $* --with-source

# ==============================================================================
# Headlamp Dashboard (deployed via Flux HelmRelease — see deployments/infrastructure/headlamp/)
# Install/delete are owned by Flux's reconcile loop; these targets are for local
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
.PHONY: test lint-yaml validate-schemas validate-flux scan-security

lint-yaml: install-test-tools ## Check YAML syntax locally
	@echo "==> Running yamllint..."
	$(YAMLLINT) $(DEPLOYMENTS_DIR)/ $(NAMESPACES_DIR)/ clusters/

# Validates every plain Kubernetes manifest AND every Flux custom resource
# (Kustomization/HelmRelease/HelmRepository/GitRepository) against real
# schemas: core Kubernetes types from kubeconform's default catalog, Flux CRDs
# from the datreeio/CRDs-catalog. kustomization.yaml is excluded on purpose —
# it's a client-side kustomize build file, never a real API object, so it has
# no schema anywhere; it's already fully exercised by `validate-flux` below.
# No -ignore-missing-schemas: every kind actually used in this repo resolves
# to a real schema, so an unresolved kind means something is genuinely wrong.
validate-schemas: install-test-tools ## Validate Kubernetes + Flux CRD schemas with kubeconform
	@echo "==> Running kubeconform (core Kubernetes schemas + Flux CRD catalog)..."
	find $(DEPLOYMENTS_DIR)/ $(NAMESPACES_DIR)/ clusters/ -type f \( -name "*.yaml" -o -name "*.yml" \) \
		! -name "*values*" ! -iname "Chart.yaml" ! -name "kustomization.yaml" -print0 \
		| xargs -0 $(KUBECONFORM) -summary -strict \
			-cache $(KUBECONFORM_CACHE) \
			-schema-location default \
			-schema-location '$(CRD_SCHEMA_LOCATION)'

validate-flux: install-test-tools ## Dry-run kustomize build for every Flux-managed path + validate the clusters/ dependsOn graph
	@echo "==> Validating kustomize build for every Flux-managed path..."
	@found=0; \
	for kfile in $$(find $(DEPLOYMENTS_DIR) -name kustomization.yaml); do \
		dir=$$(dirname "$$kfile"); \
		echo "--> $$dir"; \
		$(KUBECTL) kustomize "$$dir" > /dev/null || exit 1; \
		found=$$((found+1)); \
	done; \
	echo "    ($$found kustomization path(s) built OK)"
	@echo "==> Validating Flux dependsOn graph and Kustomization paths under clusters/..."
	@$(PYTHON) scripts/validate-flux-deps.py || exit 1

scan-security: install-test-tools ## Scan manifests for security risks with Trivy
	@echo "==> Running trivy security scan..."
	$(TRIVY) config --severity HIGH,CRITICAL --ignorefile $(TRIVY_IGNOREFILE) .

test: lint-yaml validate-schemas validate-flux scan-security ## Run all local CI checks in one command
	@echo "==> All local checks passed successfully!"

# ==============================================================================
# Full Cleanup
# ==============================================================================
.PHONY: clean

# NOTE: Vaultwarden, Infisical, Postgres, Redis, Headlamp, and the Tailscale
# operator are all reconciled by Flux Kustomizations/HelmReleases now.
# `uninstall-flux` removes the controllers but does NOT prune what they already
# applied — clean-namespaces below is what actually removes the workloads,
# by deleting the namespaces they live in.
clean: check-cluster uninstall-flux clean-namespaces ## Completely wipe out all apps, operators, and namespaces with dynamic finalizer stripping
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