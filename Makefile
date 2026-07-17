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
ARGOCD_FILE     := $(INFRA_DIR)/argocd/root-application.yaml
TAG             := local
APP_NAMESPACE   := default
ARGO_NAMESPACE  := argocd
INGRESS_PF_PORT := 8081

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
	@kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s
	@echo "✓ Ingress controller ready"

ingress-down: ## Uninstall NGINX Ingress Controller
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml --ignore-not-found

argocd-up: ## Install ArgoCD (v2.9.5)
	@kubectl get namespace $(ARGO_NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(ARGO_NAMESPACE)
	@echo "→ Installing ArgoCD $(ARGOCD_VERSION)"
	kubectl apply -n $(ARGO_NAMESPACE) --server-side --force-conflicts -f $(ARGOCD_MANIFEST)
	@kubectl wait --namespace $(ARGO_NAMESPACE) \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=argocd-server \
		--timeout=240s
	@echo "✓ ArgoCD $(ARGOCD_VERSION) installed"

argocd-down: ## Uninstall ArgoCD
	-kubectl delete -n $(ARGO_NAMESPACE) -f $(ARGOCD_MANIFEST) --ignore-not-found

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

# ---- Deploy -----------------------------------------------------------------
.PHONY: deploy

deploy: ## Apply all Kubernetes manifests
	kubectl apply -f $(INFRA_DIR)/ -n $(APP_NAMESPACE)
	kubectl apply -f $(ARGOCD_FILE) -n $(ARGO_NAMESPACE)

# ---- Rollout ----------------------------------------------------------------
.PHONY: restart

restart: ## Rolling-restart all deployments
	@for svc in $(SERVICES); do \
		kubectl rollout restart deployment/$$svc -n $(APP_NAMESPACE); \
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
	@echo "→ /api/auth/health"    && curl -s http://localhost:$(INGRESS_PF_PORT)/api/auth/health && echo
	@echo "→ /api/profile/health" && curl -s http://localhost:$(INGRESS_PF_PORT)/api/profile/health && echo
	@echo "→ / (frontend)"       && curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:$(INGRESS_PF_PORT)/

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

# ---- Cleanup ----------------------------------------------------------------
.PHONY: clean nuke

clean: ## Delete all deployed resources
	-kubectl delete -f $(INFRA_DIR)/ -n $(APP_NAMESPACE)
	-kubectl delete -f $(ARGOCD_FILE) -n $(ARGO_NAMESPACE)
	@echo "✓ Cleanup complete"

nuke: clean argocd-down ingress-down ## Tear everything down — start fresh

# ---- Convenience ------------------------------------------------------------
.PHONY: up dev

up: build deploy ## Build + deploy everything
dev: deploy ## Deploy only (skip build)
