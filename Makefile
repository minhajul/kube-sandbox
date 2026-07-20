# ============================================================================
# Kube Sandbox — DevOps Practice Sandbox
# ============================================================================

TAG             := local
APP_NAMESPACE   := default
ARGO_NAMESPACE  := argocd
INGRESS_PF_PORT := 8081
GHCR_REGISTRY   := ghcr.io
GHCR_ORG        ?= minhajul
GHCR_TAG        ?= 0.0.0

SERVICES        := auth-service profile-service frontend

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@echo "\n  Kube Sandbox Commands:\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---- Local Development & Docker ----

.PHONY: build
build: ## Build all Docker images locally
	docker build -t auth-service:$(TAG)    backend/auth-service
	docker build -t profile-service:$(TAG) backend/profile-service
	docker build -t frontend:$(TAG)        frontend

.PHONY: push-ghcr
push-ghcr: build ## Build and push images to GHCR with tag $(GHCR_TAG)
	docker login $(GHCR_REGISTRY) -u $(GHCR_ORG)
	@for svc in $(SERVICES); do \
		docker tag $$svc:$(TAG) $(GHCR_REGISTRY)/$(GHCR_ORG)/$$svc:$(GHCR_TAG); \
		docker push $(GHCR_REGISTRY)/$(GHCR_ORG)/$$svc:$(GHCR_TAG); \
	done

# ---- Kubernetes & ArgoCD Setup ----

.PHONY: setup
setup: ## Bootstrap Kubernetes: Install NGINX Ingress and ArgoCD
	@echo "→ Installing Ingress Controller..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
	@echo "→ Installing ArgoCD..."
	kubectl create namespace $(ARGO_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n $(ARGO_NAMESPACE) -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.5/manifests/install.yaml
	@echo "→ Waiting for controllers to be ready..."
	kubectl wait --namespace ingress-nginx --for=condition=Available deployment/ingress-nginx-controller --timeout=180s
	kubectl wait --namespace $(ARGO_NAMESPACE) --for=condition=Available --all deployments --timeout=180s
	@echo "✓ Setup complete! Use 'make deploy' to run the apps."

.PHONY: deploy
deploy: ## Deploy the root ArgoCD application
	kubectl apply -n $(ARGO_NAMESPACE) -f infrastructure/argocd/root-application.yaml

.PHONY: argo-sync
argo-sync: ## Force ArgoCD to sync immediately
	kubectl -n $(ARGO_NAMESPACE) patch application root-application --type merge \
		-p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# ---- Access & Port-forwarding ----

.PHONY: port-forward
port-forward: ## Expose Ingress (8081), ArgoCD UI (8080), and Grafana (3003) (Ctrl-C to stop)
	@echo "→ Access frontend dashboard at: http://localhost:$(INGRESS_PF_PORT)"
	@echo "→ Access ArgoCD UI at: https://localhost:8080"
	@echo "→ Access Grafana at: http://localhost:3003 (admin / admin)"
	@echo "→ Retrieve admin password with: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
	@kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller $(INGRESS_PF_PORT):80 & \
	 kubectl port-forward svc/argocd-server -n $(ARGO_NAMESPACE) 8080:443 & \
	 kubectl port-forward svc/grafana -n observability 3003:3000 2>/dev/null || true & \
	 wait

# ---- Verification & Logs ----

.PHONY: test
test: ## Smoke-test backend and frontend routes
	@echo "→ Testing routes..."
	@curl -s http://localhost:$(INGRESS_PF_PORT)/api/auth/health && echo || echo "auth-service unreachable"
	@curl -s http://localhost:$(INGRESS_PF_PORT)/api/profile/health && echo || echo "profile-service unreachable"
	@curl -s -I http://localhost:$(INGRESS_PF_PORT)/ | head -n 1

.PHONY: logs
logs: ## Tail logs for all three app components
	kubectl logs -f -l app.kubernetes.io/part-of=kube-sandbox -n $(APP_NAMESPACE) --tail=30

.PHONY: status
status: ## Show running pods and services
	kubectl get pods -n $(APP_NAMESPACE) -o wide
	kubectl get svc -n $(APP_NAMESPACE)

# ---- Observability ----

OBS_DIR         := infrastructure/observability
OBS_NAMESPACE   := observability
OBS_ARGOCD_FILE := infrastructure/argocd/observability-application.yaml

.PHONY: deploy-obs
deploy-obs: ## Deploy the observability stack (Prometheus, Grafana, Loki, OTel)
	kubectl apply -f $(OBS_DIR)/namespace.yaml
	kubectl apply -f $(OBS_DIR)/ -n $(OBS_NAMESPACE)
	kubectl apply -f $(OBS_ARGOCD_FILE) -n $(ARGO_NAMESPACE)
	@echo "✓ Observability stack deployed"

.PHONY: grafana
grafana: ## Expose Grafana on http://localhost:3003 (Ctrl-C to stop)
	@echo "→ Access Grafana at: http://localhost:3003  (Credentials: admin / admin)"
	kubectl port-forward -n $(OBS_NAMESPACE) svc/grafana 3003:3000

# ---- Cleanup ----

.PHONY: clean
clean: ## Remove deployed root app (ArgoCD will prune resource objects)
	-kubectl delete -f infrastructure/argocd/root-application.yaml -n $(ARGO_NAMESPACE)
	-kubectl delete deployments,services,ingress,serviceaccounts -n $(APP_NAMESPACE) -l app.kubernetes.io/part-of=kube-sandbox

.PHONY: nuke
nuke: clean ## Delete Ingress, ArgoCD, and Observability setups entirely
	-kubectl delete -f $(OBS_ARGOCD_FILE) -n $(ARGO_NAMESPACE)
	-kubectl delete namespace $(OBS_NAMESPACE) $(ARGO_NAMESPACE)
	-kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
