# ============================================================================
# Kube Sandbox — GitOps Microservices on Docker Desktop Kubernetes
# ============================================================================
# Images are built directly into Docker Desktop's shared daemon — no registry
# needed. ArgoCD syncs manifests from Git automatically.
#
# Quick start:
#   make setup          # one-time: install ingress + ArgoCD
#   make up             # build images + deploy manifests
#   make port-forward   # expose ingress on localhost:8081
#   make test           # smoke-test all routes
# ============================================================================

# ---- Configuration ----------------------------------------------------------
BACKEND_DIR     := backend
FRONTEND_DIR    := frontend
INFRA_DIR       := infrastructure
CHART_DIR       := $(INFRA_DIR)/charts/kube-sandbox
ARGOCD_FILE     := $(INFRA_DIR)/argocd/root-application.yaml
TAG             := local
APP_NAMESPACE   := default
ARGO_NAMESPACE  := argocd
INGRESS_PF_PORT := 8081

# GHCR config — defaults to your git remote's owner segment. Override on the
# command line: `make push-ghcr GHCR_ORG=my-user`.
GHCR_REGISTRY   := ghcr.io
GHCR_ORG        ?= $(shell git remote get-url origin | sed -E 's|.*[:/]([^/]+)/.*|\1|')
GHCR_TAG        ?= 0.0.0

ARGOCD_VERSION  := v2.9.5
ARGOCD_MANIFEST := https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml

SERVICES := auth-service profile-service frontend

# ---- Help -------------------------------------------------------------------
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@echo ""
	@echo "  Kube Sandbox — Docker Desktop Edition"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---- Bootstrap (one-time) ---------------------------------------------------
.PHONY: setup check-deps ingress-up ingress-down argocd-up argocd-down

setup: check-deps ingress-up argocd-up ## One-time bootstrap: install ingress + ArgoCD

check-deps: ## Verify required CLI tools
	@for cmd in docker kubectl helm curl; do \
		command -v $$cmd >/dev/null 2>&1 || { echo "✗ $$cmd missing"; exit 1; }; \
	done
	@echo "✓ All required CLI tools present"

ingress-up: ## Install NGINX Ingress Controller
	@echo "→ Installing NGINX Ingress Controller"
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
	# Wait on the Deployment's Available condition instead of the pod directly.
	# `kubectl wait --selector=...` exits non-zero when 0 pods match, which
	# races with pod scheduling right after `kubectl apply`. Waiting on the
	# Deployment polls until the rollout reports Available, which inherently
	# means at least one pod is ready.
	kubectl wait --namespace ingress-nginx \
		--for=condition=Available deployment/ingress-nginx-controller \
		--timeout=180s
	@echo "✓ Ingress controller ready"

ingress-down: ## Uninstall NGINX Ingress Controller
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml --ignore-not-found

argocd-up: ## Install ArgoCD (v2.9.5)
	@kubectl get namespace $(ARGO_NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(ARGO_NAMESPACE)
	@echo "→ Installing ArgoCD $(ARGOCD_VERSION)"
	kubectl apply -n $(ARGO_NAMESPACE) --server-side --force-conflicts -f $(ARGOCD_MANIFEST)
	# Wait on all Deployments in the namespace to be Available. ArgoCD has
	# many components (server, repo-server, application-controller, …) and
	# the old `--selector=app.kubernetes.io/name=argocd-server` race-failed
	# the same way as ingress-up when pods weren't scheduled yet.
	kubectl wait --namespace $(ARGO_NAMESPACE) \
		--for=condition=Available \
		--all deployments \
		--timeout=300s
	@echo "✓ ArgoCD $(ARGOCD_VERSION) installed"

argocd-down: ## Uninstall ArgoCD
	-kubectl delete -n $(ARGO_NAMESPACE) -f $(ARGOCD_MANIFEST) --ignore-not-found

# ----------------------------------------------------------------------------
# ArgoCD repository credentials
# ----------------------------------------------------------------------------
# ArgoCD v2.9.5 has NO `spec.source.repoCredsSecretRef` field on Application —
# credentials live as labelled Secrets in the `argocd` namespace, and the
# repo-server matches them to spec.source.repoURL of each Application.
#
# Secret shape required by ArgoCD v2.9.5:
#   - namespace: argocd
#   - label: argocd.argoproj.io/secret-type: repository
#   - stringData keys: type=git, url=<exact repo URL>,
#                      sshPrivateKey=...  (SSH)
#                      username + password (HTTPS)
#
# ArgoCD's matching rule: the Secret's `url` must be an exact match against
# the Application's repoURL (for `secret-type: repository`).
.PHONY: argocd-creds-ssh argocd-creds-https argocd-creds-show argocd-creds-rm

ARGO_REPO_SECRET := argocd-repo-creds
ARGO_REPO_URL    := https://github.com/$(GHCR_ORG)/$(notdir $(CURDIR)).git

argocd-creds-rm: ## Delete the ArgoCD repo-credentials Secret
	-kubectl delete secret -n $(ARGO_NAMESPACE) $(ARGO_REPO_SECRET)

argocd-creds-ssh: ## Provision ArgoCD creds via SSH key (recommended for local dev)
	@if [ ! -f "$$HOME/.ssh/argocd-deploy" ]; then \
		echo "→ Generating new deploy key at ~/.ssh/argocd-deploy"; \
		ssh-keygen -t ed25519 -f "$$HOME/.ssh/argocd-deploy" -N "" -C "argocd@kube-sandbox"; \
	fi
	@echo ""
	@echo "→ Add this PUBLIC key as a read-only deploy key on the repo:"
	@echo "   https://github.com/$(GHCR_ORG)/$(notdir $(CURDIR))/settings/keys/new"
	@echo ""
	@cat "$$HOME/.ssh/argocd-deploy.pub"
	@echo ""
	@read -p "Press enter once the deploy key is added... "
	@kubectl -n $(ARGO_NAMESPACE) create secret generic $(ARGO_REPO_SECRET) \
		--from-literal=type=git \
		--from-literal=url=$(ARGO_REPO_URL) \
		--from-file=sshPrivateKey=$$HOME/.ssh/argocd-deploy \
		--dry-run=client -o yaml \
		| kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
		| kubectl apply -f -
	@echo "✓ Secret $(ARGO_REPO_SECRET) provisioned (ssh, url=$(ARGO_REPO_URL))"

argocd-creds-https: ## Provision ArgoCD creds via classic PAT (must have `repo` scope)
	@read -p "GitHub username [$(GHCR_ORG)]: " USR; \
	USR=$${USR:-$(GHCR_ORG)}; \
	read -s -p "Classic PAT (must have `repo` scope): " PAT; echo; \
	kubectl -n $(ARGO_NAMESPACE) create secret generic $(ARGO_REPO_SECRET) \
		--from-literal=type=git \
		--from-literal=url=$(ARGO_REPO_URL) \
		--from-literal=username=$$USR \
		--from-literal=password=$$PAT \
		--dry-run=client -o yaml \
		| kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
		| kubectl apply -f -
	@echo "✓ Secret $(ARGO_REPO_SECRET) provisioned (https, url=$(ARGO_REPO_URL))"

argocd-creds-show: ## Show the current ArgoCD repo credentials Secret (metadata only)
	@kubectl -n $(ARGO_NAMESPACE) get secret $(ARGO_REPO_SECRET) -o yaml \
		| sed -E '/^\s*(sshPrivateKey|password):/ d' \
		| head -20

# ---- Build ------------------------------------------------------------------
.PHONY: build rebuild

build: ## Build all Docker images
	docker build -t auth-service:$(TAG)    $(BACKEND_DIR)/auth-service
	docker build -t profile-service:$(TAG) $(BACKEND_DIR)/profile-service
	docker build -t frontend:$(TAG)        $(FRONTEND_DIR)

rebuild: ## Rebuild all images (no cache)
	docker build --no-cache -t auth-service:$(TAG)    $(BACKEND_DIR)/auth-service
	docker build --no-cache -t profile-service:$(TAG) $(BACKEND_DIR)/profile-service
	docker build --no-cache -t frontend:$(TAG)        $(FRONTEND_DIR)

# ----------------------------------------------------------------------------
# GHCR bootstrap — one-time, run BEFORE first ArgoCD sync of the chart
# ----------------------------------------------------------------------------
# The chart defaults to image tag "0.0.0". Push a real image with that tag
# so ArgoCD can pull it. After this, `promote.yaml` takes over and bumps
# `apps.<svc>.image.tag` in values.yaml to the git SHA on every push.
.PHONY: push-ghcr ghcr-login

ghcr-login: ## Log in to GHCR (uses docker creds; needs `read:packages` scope)
	@echo "→ Logging into $(GHCR_REGISTRY) as $(GHCR_ORG)"
	docker login $(GHCR_REGISTRY) -u $(GHCR_ORG)

push-ghcr: build ghcr-login ## Build local images + push to GHCR with tag $(GHCR_TAG)
	@echo "→ Pushing images to $(GHCR_REGISTRY)/$(GHCR_ORG)/<svc>:$(GHCR_TAG)"
	docker tag auth-service:$(TAG)    $(GHCR_REGISTRY)/$(GHCR_ORG)/auth-service:$(GHCR_TAG)
	docker tag profile-service:$(TAG) $(GHCR_REGISTRY)/$(GHCR_ORG)/profile-service:$(GHCR_TAG)
	docker tag frontend:$(TAG)        $(GHCR_REGISTRY)/$(GHCR_ORG)/frontend:$(GHCR_TAG)
	docker push $(GHCR_REGISTRY)/$(GHCR_ORG)/auth-service:$(GHCR_TAG)
	docker push $(GHCR_REGISTRY)/$(GHCR_ORG)/profile-service:$(GHCR_TAG)
	docker push $(GHCR_REGISTRY)/$(GHCR_ORG)/frontend:$(GHCR_TAG)
	@echo "✓ All images pushed. ArgoCD will now be able to pull them."

# ---- Deploy -----------------------------------------------------------------
# The cluster no longer has raw YAML. All reconciliation happens through
# ArgoCD watching the Helm chart. `deploy` re-applies the ArgoCD Application
# (which ArgoCD already owns — this is just a re-bootstrap if it's missing).
.PHONY: deploy sync

deploy: ## (Re)apply ArgoCD Application so ArgoCD reconciles the chart
	kubectl apply -n $(ARGO_NAMESPACE) -f $(ARGOCD_FILE)
	@echo "✓ ArgoCD will reconcile infrastructure/charts/kube-sandbox → cluster"

sync: ## Force ArgoCD to re-sync NOW (don't wait for its polling)
	kubectl -n $(ARGO_NAMESPACE) patch application root-application --type merge \
		-p '{"operation":{"initiatedBy":{"username":"local"},"sync":{"revision":"HEAD"}}}'

# ---- Render (verify what ArgoCD will apply) ---------------------------------
.PHONY: render diff-render

render: ## Render the chart locally — what ArgoCD sees, without applying
	helm template apps $(CHART_DIR) --namespace $(APP_NAMESPACE)

# ---- Rollout ----------------------------------------------------------------
# Deployment names include the Helm release prefix. The chart uses
# fullname "<release>-kube-sandbox-<app>" so auth-service's deployment is
# "apps-kube-sandbox-auth" (kebab-cased, prefixed with release=apps).
HELM_RELEASE ?= apps-kube-sandbox

.PHONY: restart

restart: ## Rolling-restart all deployments via Helm-generated names
	@for svc in auth profile frontend; do \
		kubectl rollout restart deployment/$(HELM_RELEASE)-$$svc -n $(APP_NAMESPACE); \
	done

# ---- Status / Logs ----------------------------------------------------------
.PHONY: status pods logs

status: ## Show deployments, pods, services, and ingress
	@echo "→ Deployments:" && kubectl get deployments -n $(APP_NAMESPACE)
	@echo "" && echo "→ Pods:" && kubectl get pods -n $(APP_NAMESPACE) -o wide
	@echo "" && echo "→ Services:" && kubectl get svc -n $(APP_NAMESPACE)
	@echo "" && echo "→ Ingress:" && kubectl get ingress -n $(APP_NAMESPACE)

pods: ## List pods
	@kubectl get pods -n $(APP_NAMESPACE) -o wide

logs: ## Tail logs from all services
	@for svc in $(SERVICES); do \
		kubectl logs -f deployment/$$svc -n $(APP_NAMESPACE) --tail=50 & \
	done; wait

# ---- Testing ----------------------------------------------------------------
.PHONY: port-forward test health

port-forward: ## Port-forward ingress to localhost:8081
	@echo "→ Ingress on http://localhost:$(INGRESS_PF_PORT)  (Ctrl-C to stop)"
	@kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller $(INGRESS_PF_PORT):80

test: ## Smoke-test public routes via the ingress
	@PORT=80; curl -s -o /dev/null --connect-timeout 2 http://localhost/ || PORT=$(INGRESS_PF_PORT); \
	echo "→ Using port $$PORT"; \
	echo "→ /api/auth/health"    && curl -s http://localhost:$$PORT/api/auth/health && echo; \
	echo "→ /api/profile/health" && curl -s http://localhost:$$PORT/api/profile/health && echo; \
	echo "→ / (frontend)"       && curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:$$PORT/

health: ## Direct health check via port-forward to each backend
	@for pair in "auth-service-svc:3001" "profile-service-svc:3002"; do \
		svc=$${pair%%:*}; port=$${pair##*:}; \
		kubectl port-forward svc/$$svc $$port:$$port -n $(APP_NAMESPACE) &>/dev/null & pf=$$!; \
		sleep 2; echo "→ $$svc:" && curl -s http://localhost:$$port/health && echo; \
		kill $$pf 2>/dev/null; \
	done

# ---- ArgoCD helpers ---------------------------------------------------------
.PHONY: argo-sync argo-status argo-ui

argo-sync: ## Force ArgoCD to re-sync
	kubectl -n $(ARGO_NAMESPACE) patch application root-application --type merge \
		-p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

argo-status: ## Show ArgoCD sync/health status
	@kubectl -n $(ARGO_NAMESPACE) get application root-application \
		-o jsonpath='Sync: {.status.sync.status}  Health: {.status.health.status}{"\n"}'

argo-ui: ## Port-forward ArgoCD UI to https://localhost:8080
	@kubectl port-forward svc/argocd-server -n $(ARGO_NAMESPACE) 8080:443

OBS_DIR         := $(INFRA_DIR)/observability
OBS_NAMESPACE   := observability
OBS_ARGOCD_FILE := $(INFRA_DIR)/argocd/observability-application.yaml

# ---- Observability ----------------------------------------------------------
.PHONY: deploy-obs grafana prometheus obs-status

deploy-obs: ## Deploy the observability stack (Prometheus, Grafana, Loki, OTel)
	kubectl apply -f $(OBS_DIR)/namespace.yaml
	kubectl apply -f $(OBS_DIR)/ -n $(OBS_NAMESPACE)
	kubectl apply -f $(OBS_ARGOCD_FILE) -n $(ARGO_NAMESPACE)
	@echo "✓ Observability stack deployed"

grafana: ## Port-forward Grafana to http://localhost:3003
	@echo "→ Grafana on http://localhost:3003  (admin/admin)  Ctrl-C to stop"
	@kubectl port-forward -n $(OBS_NAMESPACE) svc/grafana 3003:3000

prometheus: ## Port-forward Prometheus to http://localhost:9090
	@echo "→ Prometheus on http://localhost:9090  Ctrl-C to stop"
	@kubectl port-forward -n $(OBS_NAMESPACE) svc/prometheus 9090:9090

rustfs: ## Port-forward RustFS console to http://localhost:9001
	@echo "→ RustFS console on http://localhost:9001  (admin/admin123456)  Ctrl-C to stop"
	@kubectl port-forward -n $(OBS_NAMESPACE) svc/rustfs 9001:9001

obs-status: ## Show observability pod status
	@kubectl get pods -n $(OBS_NAMESPACE) -o wide

# ---- Cleanup ----------------------------------------------------------------
.PHONY: clean clean-obs nuke

clean: ## Delete all deployed app resources
	-kubectl delete -f $(INFRA_DIR)/ -n $(APP_NAMESPACE)
	-kubectl delete -f $(ARGOCD_FILE) -n $(ARGO_NAMESPACE)
	@echo "✓ App cleanup complete"

clean-obs: ## Delete all observability resources
	-kubectl delete -f $(OBS_ARGOCD_FILE) -n $(ARGO_NAMESPACE)
	-kubectl delete -f $(OBS_DIR)/ -n $(OBS_NAMESPACE)
	-kubectl delete namespace $(OBS_NAMESPACE) --ignore-not-found
	@echo "✓ Observability cleanup complete"

nuke: clean clean-obs argocd-down ingress-down ## Tear everything down — start fresh

# ---- Convenience ------------------------------------------------------------
.PHONY: up dev

up: build deploy ## Build + deploy everything
dev: deploy ## Deploy only (skip build)
