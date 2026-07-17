# ============================================================================
# Kube Sandbox — GitOps-driven Microservices Development Environment
# ============================================================================
# Common commands:
#   make help              Show this help message
#   make build-all         Build all Docker images
#   make push-all          Push all images to local registry
#   make deploy            Apply all Kubernetes manifests
#   make status            Show status of all deployments
#   make clean             Remove all resources and images
# ============================================================================

# ---- Configuration ----------------------------------------------------------
REGISTRY      := localhost:5001
BACKEND_DIR   := backend
FRONTEND_DIR  := frontend
INFRA_DIR     := infrastructure
APPS_DIR      := $(INFRA_DIR)/apps
ARGOCD_FILE   := $(INFRA_DIR)/argocd/root-application.yaml
INGRESS_FILE  := $(INFRA_DIR)/ingress.yaml

SERVICES      := auth-service profile-service frontend
BACKEND_SVCS  := auth-service profile-service

# Kubernetes contexts / namespaces
K8S_NAMESPACE := default

# Image tags (override via: make build AUTH_TAG=v1.0.0)
AUTH_TAG      := latest
PROFILE_TAG   := latest
FRONTEND_TAG  := latest

# ---- Helpers ----------------------------------------------------------------
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════════╗"
	@echo "║           Kube Sandbox — Make Command Reference                ║"
	@echo "╚════════════════════════════════════════════════════════════════╝"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---- Docker / Image targets -------------------------------------------------
.PHONY: build build-auth build-profile build-frontend build-all
build: build-all ## Build all Docker images (alias for build-all)

build-auth: ## Build auth-service image
	@echo "→ Building $(REGISTRY)/auth-service:$(AUTH_TAG)"
	docker build -t $(REGISTRY)/auth-service:$(AUTH_TAG) $(BACKEND_DIR)/auth-service

build-profile: ## Build profile-service image
	@echo "→ Building $(REGISTRY)/profile-service:$(PROFILE_TAG)"
	docker build -t $(REGISTRY)/profile-service:$(PROFILE_TAG) $(BACKEND_DIR)/profile-service

build-frontend: ## Build frontend image
	@echo "→ Building $(REGISTRY)/frontend:$(FRONTEND_TAG)"
	docker build -t $(REGISTRY)/frontend:$(FRONTEND_TAG) $(FRONTEND_DIR)

build-all: build-auth build-profile build-frontend ## Build all Docker images

.PHONY: push push-auth push-profile push-frontend push-all
push: push-all ## Push all images to local registry (alias for push-all)

push-auth: ## Push auth-service image
	docker push $(REGISTRY)/auth-service:$(AUTH_TAG)

push-profile: ## Push profile-service image
	docker push $(REGISTRY)/profile-service:$(PROFILE_TAG)

push-frontend: ## Push frontend image
	docker push $(REGISTRY)/frontend:$(FRONTEND_TAG)

push-all: push-auth push-profile push-frontend ## Push all images

.PHONY: rebuild rebuild-auth rebuild-profile rebuild-frontend
rebuild: ## Rebuild all images (no cache)
	docker build --no-cache -t $(REGISTRY)/auth-service:$(AUTH_TAG) $(BACKEND_DIR)/auth-service
	docker build --no-cache -t $(REGISTRY)/profile-service:$(PROFILE_TAG) $(BACKEND_DIR)/profile-service
	docker build --no-cache -t $(REGISTRY)/frontend:$(FRONTEND_TAG) $(FRONTEND_DIR)

# ---- Kubernetes deployment targets -----------------------------------------
.PHONY: deploy deploy-apps deploy-ingress deploy-argocd deploy-all
deploy: deploy-all ## Apply all Kubernetes manifests (alias for deploy-all)

deploy-apps: ## Apply all app manifests (auth, profile, frontend)
	@echo "→ Deploying applications to namespace '$(K8S_NAMESPACE)'"
	kubectl apply -f $(APPS_DIR)/auth-service.yaml
	kubectl apply -f $(APPS_DIR)/profile-service.yaml
	kubectl apply -f $(APPS_DIR)/frontend.yaml

deploy-ingress: ## Apply NGINX Ingress manifest
	@echo "→ Applying Ingress"
	kubectl apply -f $(INGRESS_FILE)

deploy-argocd: ## Apply ArgoCD root application
	@echo "→ Applying ArgoCD root application"
	kubectl apply -f $(ARGOCD_FILE)

deploy-all: deploy-apps deploy-ingress deploy-argocd ## Apply everything (apps + ingress + argocd)

# ---- Rollout / restart ------------------------------------------------------
.PHONY: restart restart-auth restart-profile restart-frontend
restart: ## Restart all deployments
	kubectl rollout restart deployment/auth-service -n $(K8S_NAMESPACE)
	kubectl rollout restart deployment/profile-service -n $(K8S_NAMESPACE)
	kubectl rollout restart deployment/frontend -n $(K8S_NAMESPACE)

restart-auth: ## Restart auth-service deployment
	kubectl rollout restart deployment/auth-service -n $(K8S_NAMESPACE)

restart-profile: ## Restart profile-service deployment
	kubectl rollout restart deployment/profile-service -n $(K8S_NAMESPACE)

restart-frontend: ## Restart frontend deployment
	kubectl rollout restart deployment/frontend -n $(K8S_NAMESPACE)

# ---- Status / inspection ----------------------------------------------------
.PHONY: status
status: ## Show status of all deployments, pods, services
	@echo "→ Deployments:"
	@kubectl get deployments -n $(K8S_NAMESPACE)
	@echo ""
	@echo "→ Pods:"
	@kubectl get pods -n $(K8S_NAMESPACE)
	@echo ""
	@echo "→ Services:"
	@kubectl get svc -n $(K8S_NAMESPACE)
	@echo ""
	@echo "→ Ingress:"
	@kubectl get ingress -n $(K8S_NAMESPACE)

.PHONY: pods
pods: ## List pods with their status
	@kubectl get pods -n $(K8S_NAMESPACE) -o wide

.PHONY: logs logs-auth logs-profile logs-frontend
logs: ## Tail logs from all services
	kubectl logs -f deployment/auth-service -n $(K8S_NAMESPACE) --tail=100 &
	kubectl logs -f deployment/profile-service -n $(K8S_NAMESPACE) --tail=100 &
	kubectl logs -f deployment/frontend -n $(K8S_NAMESPACE) --tail=100 &
	wait

logs-auth: ## Tail logs from auth-service
	kubectl logs -f deployment/auth-service -n $(K8S_NAMESPACE)

logs-profile: ## Tail logs from profile-service
	kubectl logs -f deployment/profile-service -n $(K8S_NAMESPACE)

logs-frontend: ## Tail logs from frontend
	kubectl logs -f deployment/frontend -n $(K8S_NAMESPACE)

# ---- Health checks ----------------------------------------------------------
.PHONY: health
health: ## Curl /health endpoints on all backend services via port-forward
	@echo "→ Checking auth-service health..."
	@kubectl port-forward svc/auth-service-svc 3001:3001 -n $(K8S_NAMESPACE) &>/dev/null & PF=$$!; \
	sleep 2; curl -s http://localhost:3001/health; echo ""; kill $$PF 2>/dev/null
	@echo "→ Checking profile-service health..."
	@kubectl port-forward svc/profile-service-svc 3002:3002 -n $(K8S_NAMESPACE) &>/dev/null & PF=$$!; \
	sleep 2; curl -s http://localhost:3002/health; echo ""; kill $$PF 2>/dev/null

# ---- Cleanup ----------------------------------------------------------------
.PHONY: clean clean-k8s clean-images clean-all
clean: clean-all ## Remove all resources, images, and build artifacts

clean-k8s: ## Delete all Kubernetes resources
	@echo "→ Deleting applications, ingress, and argocd manifests"
	-kubectl delete -f $(APPS_DIR)/auth-service.yaml
	-kubectl delete -f $(APPS_DIR)/profile-service.yaml
	-kubectl delete -f $(APPS_DIR)/frontend.yaml
	-kubectl delete -f $(INGRESS_FILE)
	-kubectl delete -f $(ARGOCD_FILE)

clean-images: ## Remove local Docker images
	-docker rmi $(REGISTRY)/auth-service:$(AUTH_TAG)
	-docker rmi $(REGISTRY)/profile-service:$(PROFILE_TAG)
	-docker rmi $(REGISTRY)/frontend:$(FRONTEND_TAG)

clean-all: clean-k8s clean-images ## Clean both k8s resources and local images
	@echo "✓ Cleanup complete"

# ---- Convenience workflows --------------------------------------------------
.PHONY: up
up: build-all push-all deploy-all ## Build, push, and deploy everything (full refresh)

.PHONY: dev
dev: deploy-apps deploy-ingress ## Deploy apps + ingress (skip ArgoCD for quick local dev)

.PHONY: argo-sync
argo-sync: ## Force ArgoCD to re-sync the root application
	kubectl -n argocd patch application root-application --type merge \
		-p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

.PHONY: argo-status
argo-status: ## Show ArgoCD application status
	kubectl -n argocd get application root-application -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'

# ---- Image registry (local) -------------------------------------------------
.PHONY: registry-up
registry-up: ## Start local Docker registry on :5001 if not running
	@if ! docker ps --filter "publish=5001" --format '{{.Names}}' | grep -q .; then \
		echo "→ Starting local registry on :5001"; \
		docker run -d -p 5001:5000 --name kube-sandbox-registry --restart=always registry:2; \
	else \
		echo "✓ Local registry already running"; \
	fi

.PHONY: registry-down
registry-down: ## Stop and remove the local Docker registry
	-docker stop kube-sandbox-registry
	-docker rm kube-sandbox-registry