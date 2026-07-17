# ============================================================================
# Kube Sandbox — GitOps-driven Microservices on Docker Desktop Kubernetes
# ============================================================================
# Target platform : macOS / Docker Desktop (built-in Kubernetes)
#
# Two image-push modes are supported:
#   LOCAL (default) — build directly into Docker Desktop's shared daemon.
#                      No registry, no insecure-registry config needed.
#                      Uses the manifests' image: line as `<name>:local`.
#   REGISTRY        — build, push to a registry, then pull into the cluster.
#                      Requires `make registry-up` and the registry to be
#                      reachable from inside the cluster.
#
# Usage:
#   make up                       # LOCAL mode (default; works out of the box)
#   make up MODE=REGISTRY REGISTRY=host.docker.internal:5001
# ============================================================================

# ---- Configuration ----------------------------------------------------------
MODE          ?= LOCAL                  # LOCAL or REGISTRY
REGISTRY      ?= host.docker.internal:5001
LOCAL_TAG     := local                  # tag used in LOCAL mode
PULL_POLICY   := IfNotPresent           # used in REGISTRY mode (Never used in LOCAL)

BACKEND_DIR   := backend
FRONTEND_DIR  := frontend
INFRA_DIR     := infrastructure
APPS_DIR      := $(INFRA_DIR)/apps
ARGOCD_FILE   := $(INFRA_DIR)/argocd/root-application.yaml
INGRESS_FILE  := $(INFRA_DIR)/ingress.yaml

SERVICES      := auth-service profile-service frontend
BACKEND_SVCS  := auth-service profile-service

# Kubernetes namespaces
APP_NAMESPACE  := default
ARGO_NAMESPACE := argocd

# Image tags (only used in REGISTRY mode)
AUTH_TAG      ?= latest
PROFILE_TAG   ?= latest
FRONTEND_TAG  ?= latest

# Test URLs
TEST_HOST     := http://localhost:8081   # default for port-forwarded ingress
INGRESS_PF_PORT := 8081

# ArgoCD version (pinned — newer 'stable' manifests exceed the 256KB CRD annotation limit)
ARGOCD_VERSION  := v2.9.5
ARGOCD_MANIFEST := https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml

# ---- Image refs (computed from MODE) ---------------------------------------
# Conditional assignment using deferred expansion — the right-hand side is only
# expanded when the variable is used, so `MODE` is consulted at use-time.
AUTH_IMG      = $(if $(filter LOCAL,$(MODE)),auth-service:$(LOCAL_TAG),$(REGISTRY)/auth-service:$(AUTH_TAG))
PROFILE_IMG   = $(if $(filter LOCAL,$(MODE)),profile-service:$(LOCAL_TAG),$(REGISTRY)/profile-service:$(PROFILE_TAG))
FRONTEND_IMG  = $(if $(filter LOCAL,$(MODE)),frontend:$(LOCAL_TAG),$(REGISTRY)/frontend:$(FRONTEND_TAG))
SKIP_PUSH     = $(if $(filter LOCAL,$(MODE)),1,)

# ---- Helpers ----------------------------------------------------------------
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════════╗"
	@echo "║   Kube Sandbox — macOS / Docker Desktop Edition                ║"
	@echo "║   Registry target : $(REGISTRY)"
	@echo "╚════════════════════════════════════════════════════════════════╝"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---- Bootstrap (one-time per machine) ---------------------------------------
.PHONY: setup
setup: check-deps registry-up ingress-up argocd-up ## One-time bootstrap: install ingress + ArgoCD + start local registry

.PHONY: check-deps
check-deps: ## Verify required CLI tools exist
	@command -v docker >/dev/null 2>&1    || { echo "✗ docker missing";    exit 1; }
	@command -v kubectl >/dev/null 2>&1   || { echo "✗ kubectl missing";   exit 1; }
	@command -v helm >/dev/null 2>&1      || { echo "✗ helm missing";      exit 1; }
	@command -v curl >/dev/null 2>&1      || { echo "✗ curl missing";      exit 1; }
	@echo "✓ All required CLI tools present"

.PHONY: ingress-up
ingress-up: ## Install NGINX Ingress Controller (Docker Desktop)
	@echo "→ Installing NGINX Ingress Controller in namespace 'ingress-nginx'"
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
	@echo "→ Waiting for ingress controller to be ready..."
	@kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s || { echo "✗ Ingress controller failed to come up"; exit 1; }
	@echo "✓ Ingress controller is ready"

.PHONY: ingress-down
ingress-down: ## Uninstall NGINX Ingress Controller
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml --ignore-not-found

.PHONY: argocd-up
argocd-up: ## Install ArgoCD (pinned to v2.9.5) into the 'argocd' namespace
	@echo "→ Cleaning up any partial ArgoCD install (if any)..."
	- kubectl delete -n $(ARGO_NAMESPACE) -f $(ARGOCD_MANIFEST) --ignore-not-found 2>/dev/null
	@kubectl get namespace $(ARGO_NAMESPACE) >/dev/null 2>&1 || \
		kubectl create namespace $(ARGO_NAMESPACE)
	@echo "→ Installing ArgoCD $(ARGOCD_VERSION) into namespace '$(ARGO_NAMESPACE)'"
	@echo "  (pinned to v2.9.5 — newer 'stable' manifests exceed the 256KB CRD annotation limit)"
	kubectl apply -n $(ARGO_NAMESPACE) --server-side --force-conflicts -f $(ARGOCD_MANIFEST) || { \
		echo ""; \
		echo "✗ ArgoCD install failed. Try:"; \
		echo "   kubectl delete -n $(ARGO_NAMESPACE) -f $(ARGOCD_MANIFEST)"; \
		echo "   make argocd-up"; \
		exit 1; \
	}
	@echo "→ Waiting for ArgoCD server to be ready..."
	@kubectl wait --namespace $(ARGO_NAMESPACE) \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=argocd-server \
		--timeout=240s || { echo "✗ ArgoCD failed to come up"; exit 1; }
	@echo "✓ ArgoCD $(ARGOCD_VERSION) installed"

.PHONY: argocd-down
argocd-down: ## Uninstall ArgoCD
	- kubectl delete -n $(ARGO_NAMESPACE) -f $(ARGOCD_MANIFEST) --ignore-not-found

# ---- Image registry (local, host-side) -------------------------------------
.PHONY: registry-up
registry-up: ## Start local Docker registry on the host (port 5000 -> 5001)
	@if ! docker ps --filter "publish=5001" --format '{{.Names}}' | grep -q .; then \
		echo "→ Starting local registry: $(REGISTRY)"; \
		docker run -d -p 5001:5000 --name kube-sandbox-registry --restart=always registry:2; \
		sleep 2; \
	else \
		echo "✓ Local registry $(REGISTRY) already running"; \
	fi

.PHONY: registry-down
registry-down: ## Stop and remove the local Docker registry
	-docker stop kube-sandbox-registry
	-docker rm kube-sandbox-registry

.PHONY: registry-ping
registry-ping: ## Verify the local registry is reachable from inside a pod
	@echo "→ Probing $(REGISTRY) from inside a pod..."
	@kubectl run registry-test --rm -it --restart=Never --image=curlimages/curl -- \
		curl -s http://$(REGISTRY)/v2/_catalog || true

# ---- Docker / Image targets -------------------------------------------------
.PHONY: build build-auth build-profile build-frontend build-all
build: build-all ## Build all Docker images (alias for build-all)

build-auth: ## Build auth-service image
	@echo "→ Building $(AUTH_IMG)  [MODE=$(MODE)]"
	docker build -t $(AUTH_IMG) $(BACKEND_DIR)/auth-service

build-profile: ## Build profile-service image
	@echo "→ Building $(PROFILE_IMG)  [MODE=$(MODE)]"
	docker build -t $(PROFILE_IMG) $(BACKEND_DIR)/profile-service

build-frontend: ## Build frontend image
	@echo "→ Building $(FRONTEND_IMG)  [MODE=$(MODE)]"
	docker build -t $(FRONTEND_IMG) $(FRONTEND_DIR)

build-all: build-auth build-profile build-frontend ## Build all Docker images

.PHONY: push push-auth push-profile push-frontend push-all
push: push-all ## Push all images to registry (alias for push-all, no-op in LOCAL mode)

push-auth: ## Push auth-service image
ifeq ($(SKIP_PUSH),1)
	@echo "→ Skipping push (LOCAL mode); Docker Desktop K8s reads from the host daemon"
else
	docker push $(AUTH_IMG)
endif

push-profile: ## Push profile-service image
ifeq ($(SKIP_PUSH),1)
	@echo "→ Skipping push (LOCAL mode); Docker Desktop K8s reads from the host daemon"
else
	docker push $(PROFILE_IMG)
endif

push-frontend: ## Push frontend image
ifeq ($(SKIP_PUSH),1)
	@echo "→ Skipping push (LOCAL mode); Docker Desktop K8s reads from the host daemon"
else
	docker push $(FRONTEND_IMG)
endif

push-all: push-auth push-profile push-frontend ## Push all images (no-op in LOCAL mode)

.PHONY: rebuild
rebuild: ## Rebuild all images (no cache)
	docker build --no-cache -t $(AUTH_IMG) $(BACKEND_DIR)/auth-service
	docker build --no-cache -t $(PROFILE_IMG) $(BACKEND_DIR)/profile-service
	docker build --no-cache -t $(FRONTEND_IMG) $(FRONTEND_DIR)

# ---- Kubernetes deployment targets -----------------------------------------
.PHONY: deploy deploy-apps deploy-ingress deploy-argocd deploy-all
deploy: deploy-all ## Apply all Kubernetes manifests (alias for deploy-all)

deploy-apps: ## Apply all app manifests (auth, profile, frontend)
	@echo "→ Deploying applications to namespace '$(APP_NAMESPACE)'"
	kubectl apply -f $(APPS_DIR)/auth-service.yaml -n $(APP_NAMESPACE)
	kubectl apply -f $(APPS_DIR)/profile-service.yaml -n $(APP_NAMESPACE)
	kubectl apply -f $(APPS_DIR)/frontend.yaml -n $(APP_NAMESPACE)

deploy-ingress: ## Apply NGINX Ingress manifest
	@echo "→ Applying Ingress"
	kubectl apply -f $(INGRESS_FILE) -n $(APP_NAMESPACE)

deploy-argocd: ## Apply ArgoCD root application
	@echo "→ Applying ArgoCD root application"
	kubectl apply -f $(ARGOCD_FILE) -n $(ARGO_NAMESPACE)

deploy-all: deploy-apps deploy-ingress deploy-argocd ## Apply everything (apps + ingress + argocd)

# ---- Rollout / restart ------------------------------------------------------
.PHONY: restart restart-auth restart-profile restart-frontend
restart: ## Restart all deployments
	kubectl rollout restart deployment/auth-service -n $(APP_NAMESPACE)
	kubectl rollout restart deployment/profile-service -n $(APP_NAMESPACE)
	kubectl rollout restart deployment/frontend -n $(APP_NAMESPACE)

restart-auth: ## Restart auth-service deployment
	kubectl rollout restart deployment/auth-service -n $(APP_NAMESPACE)

restart-profile: ## Restart profile-service deployment
	kubectl rollout restart deployment/profile-service -n $(APP_NAMESPACE)

restart-frontend: ## Restart frontend deployment
	kubectl rollout restart deployment/frontend -n $(APP_NAMESPACE)

# ---- Status / inspection ----------------------------------------------------
.PHONY: status
status: ## Show status of deployments, pods, services, and ingress
	@echo "→ Deployments:"
	@kubectl get deployments -n $(APP_NAMESPACE)
	@echo ""
	@echo "→ Pods:"
	@kubectl get pods -n $(APP_NAMESPACE) -o wide
	@echo ""
	@echo "→ Services:"
	@kubectl get svc -n $(APP_NAMESPACE)
	@echo ""
	@echo "→ Ingress:"
	@kubectl get ingress -n $(APP_NAMESPACE)

.PHONY: pods
pods: ## List pods with their status
	@kubectl get pods -n $(APP_NAMESPACE) -o wide

.PHONY: logs logs-auth logs-profile logs-frontend
logs: ## Tail logs from all services
	kubectl logs -f deployment/auth-service -n $(APP_NAMESPACE) --tail=100 &
	kubectl logs -f deployment/profile-service -n $(APP_NAMESPACE) --tail=100 &
	kubectl logs -f deployment/frontend -n $(APP_NAMESPACE) --tail=100 &
	wait

logs-auth: ## Tail logs from auth-service
	kubectl logs -f deployment/auth-service -n $(APP_NAMESPACE)

logs-profile: ## Tail logs from profile-service
	kubectl logs -f deployment/profile-service -n $(APP_NAMESPACE)

logs-frontend: ## Tail logs from frontend
	kubectl logs -f deployment/frontend -n $(APP_NAMESPACE)

# ---- Health checks ----------------------------------------------------------
.PHONY: health
health: ## Curl /health endpoints via port-forward to each backend
	@echo "→ Checking auth-service health..."
	@kubectl port-forward svc/auth-service-svc 3001:3001 -n $(APP_NAMESPACE) &>/dev/null & PF=$$!; \
	sleep 2; curl -s http://localhost:3001/health; echo ""; kill $$PF 2>/dev/null
	@echo "→ Checking profile-service health..."
	@kubectl port-forward svc/profile-service-svc 3002:3002 -n $(APP_NAMESPACE) &>/dev/null & PF=$$!; \
	sleep 2; curl -s http://localhost:3002/health; echo ""; kill $$PF 2>/dev/null

.PHONY: port-forward
port-forward: ## Port-forward the ingress controller to localhost:8081 (HTTP) + :8082 (HTTPS)
	@echo "→ Port-forwarding ingress to localhost:$(INGRESS_PF_PORT) (HTTP) and :8082 (HTTPS)"
	@echo "  Stop with Ctrl-C"
	@kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller $(INGRESS_PF_PORT):80 8082:443 --address 0.0.0.0

.PHONY: test
test: ## Smoke test the public routes via the ingress (auth + profile + frontend)
	@echo "→ Testing $(TEST_HOST)/api/auth/health"
	@curl -s $(TEST_HOST)/api/auth/health; echo ""
	@echo "→ Testing $(TEST_HOST)/api/profile/health"
	@curl -s $(TEST_HOST)/api/profile/health; echo ""
	@echo "→ Testing $(TEST_HOST)/  (frontend root)"
	@curl -s -o /dev/null -w "HTTP %{http_code}\n" $(TEST_HOST)/
	@open $(TEST_HOST)/ 2>/dev/null || echo "Open $(TEST_HOST)/ in your browser"

.PHONY: dashboard
dashboard: ## Open the frontend dashboard in your default browser
	@open $(TEST_HOST)/ 2>/dev/null || open http://localhost:$(INGRESS_PF_PORT)/ || echo "Open http://localhost:$(INGRESS_PF_PORT)/"

# ---- Cleanup ----------------------------------------------------------------
.PHONY: clean clean-k8s clean-images clean-all
clean: clean-all ## Remove all resources and images

clean-k8s: ## Delete all Kubernetes resources
	- kubectl delete -f $(APPS_DIR)/auth-service.yaml -n $(APP_NAMESPACE)
	- kubectl delete -f $(APPS_DIR)/profile-service.yaml -n $(APP_NAMESPACE)
	- kubectl delete -f $(APPS_DIR)/frontend.yaml -n $(APP_NAMESPACE)
	- kubectl delete -f $(INGRESS_FILE) -n $(APP_NAMESPACE)
	- kubectl delete -f $(ARGOCD_FILE) -n $(ARGO_NAMESPACE)

clean-images: ## Remove local Docker images
	- docker rmi $(REGISTRY)/auth-service:$(AUTH_TAG)
	- docker rmi $(REGISTRY)/profile-service:$(PROFILE_TAG)
	- docker rmi $(REGISTRY)/frontend:$(FRONTEND_TAG)

clean-all: clean-k8s clean-images ## Clean both k8s resources and local images
	@echo "✓ Cleanup complete"

.PHONY: nuke
nuke: clean-all argocd-down ingress-down registry-down ## Tear EVERYTHING down (cluster-excluded) — start fresh

# ---- Convenience workflows --------------------------------------------------
.PHONY: up
up: build-all push-all deploy-all ## Build, push, and deploy everything (full refresh)

.PHONY: dev
dev: deploy-apps deploy-ingress ## Deploy apps + ingress (skip ArgoCD for quick local dev)

.PHONY: argo-sync
argo-sync: ## Force ArgoCD to re-sync the root application
	kubectl -n $(ARGO_NAMESPACE) patch application root-application --type merge \
		-p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

.PHONY: argo-status
argo-status: ## Show ArgoCD application status
	kubectl -n $(ARGO_NAMESPACE) get application root-application \
		-o jsonpath='Sync: {.status.sync.status}  Health: {.status.health.status}{"\n"}'

.PHONY: argo-ui
argo-ui: ## Port-forward the ArgoCD UI to https://localhost:8080
	@kubectl port-forward svc/argocd-server -n $(ARGO_NAMESPACE) 8080:443
