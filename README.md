# Kube Sandbox

A **GitOps-driven microservices sandbox** built for practicing Kubernetes, CI/CD, and GitOps locally. It contains two
NestJS backend services (`auth-service`, `profile-service`) and a Next.js frontend, deployed to local Kubernetes via *
*ArgoCD** and fronted by the **NGINX Ingress Controller**.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Local Kubernetes Cluster                      │
│                                                                     │
│   ┌───────────────────────────────────────────────────────────┐     │
│   │                         default                           │     │
│   │                                                           │     │
│   │   ┌──────────────────┐    ┌──────────────────────────┐   │     │
│   │   │  NGINX Ingress   │───▶│  frontend-svc (Next.js)  │   │     │
│   │   │  Controller      │    │   :3000, 2 replicas      │   │     │
│   │   └──────────────────┘    └──────────────────────────┘   │     │
│   │                                  │                       │     │
│   │                                  │  server-side fetch    │     │
│   │                                  │  (cluster DNS)        │     │
│   │                                  ▼                       │     │
│   │   ┌──────────────────┐    ┌──────────────────────────┐   │     │
│   │   │ apps-auth-svc    │    │ apps-profile-svc         │   │     │
│   │   │   :3001, 2 repl  │    │   :3002, 2 replicas      │   │     │
│   │   └──────────────────┘    └──────────────────────────┘   │     │
│   └───────────────────────────────────────────────────────────┘     │
│   ┌───────────────────────────────────────────────────────────┐     │
│   │  ArgoCD  (watches infrastructure/ values.yaml in Git)     │     │
│   └───────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
            ▲                       ▲
            │  localhost:8081        │  localhost:8080
            │  (forwarded Ingress)   │  (forwarded ArgoCD UI)
            │                       │
       ┌────┴─────┐         ┌──────┴──────┐
       │ Browser  │         │  ArgoCD UI  │
       │ :8081    │         │  :8080      │
       └──────────┘         └─────────────┘
```

**Important routing detail:** The Ingress controller routes external traffic (`/`) to the frontend. The frontend
communicates with the backends internally over cluster DNS (using Service URLs `http://apps-kube-sandbox-auth:3001` and
`http://apps-kube-sandbox-profile:3002`) mapped dynamically at runtime.

---

## Prerequisites

Ensure you have a local Kubernetes cluster (like **Docker Desktop Kubernetes**, **Minikube**, or **Kind**) running and
active, along with these CLI tools:

* **kubectl** (`brew install kubectl`)
* **Helm** (`brew install helm`)
* **curl** (pre-installed)
* **make** (pre-installed)

---

## Quick Start (First-time Setup)

1. **Bootstrap the Cluster Infrastructure**: Installs the Ingress controller and ArgoCD.
   ```bash
   make setup
   ```
2. **Push Initial Bootstrap Images**: Builds local images and pushes them to GHCR with tag `0.0.0` (required for initial
   Helm sync).
   ```bash
   make push-ghcr GHCR_ORG=<your-github-username>
   ```
3. **Deploy the Application**: Registers the root application manifest inside ArgoCD.
   ```bash
   make deploy
   ```
4. **Expose the Dashboards**: Starts port-forwarding for both the web app and ArgoCD.
   ```bash
   make port-forward
   ```
5. **Access the applications**:
    * **Frontend Dashboard**: [http://localhost:8081](http://localhost:8081)
    * **ArgoCD UI**: [https://localhost:8080](https://localhost:8080) (Retrieve the login password by running the
      command displayed in the terminal output of `make port-forward`).

---

## The GitOps & CI/CD Workflow

This repository implements a complete automated GitOps pipeline using GitHub Actions:

```
[Developer Push] ──▶ [Lint, Build & Push Workflow] ──▶ [Image Pushed to GHCR]
                                                               │
                                                               ▼
[ArgoCD Syncs main] ◀── [PR Merged] ◀── [PR Opened] ◀── [Promote Workflow]
```

### 1. Code Changes (Automated Promotion)

1. Push code changes to `main`.
2. GitHub Actions compiles/lints code, builds the Docker images, and pushes them to GHCR tagged with the short commit
   SHA (e.g. `df1b0e7`).
3. The **Promote** workflow automatically fires, bumps the tags in `infrastructure/charts/kube-sandbox/values.yaml` in a
   new branch, and opens a Pull Request.
4. **Merge the PR on GitHub**. ArgoCD will detect the change in `values.yaml` and roll out the new images to the
   cluster.

### 2. Infrastructure Changes (Scaling & Config)

To scale your applications (e.g. update replicas):

1. Modify `replicaCount` under `apps.<service>`
   in [infrastructure/charts/kube-sandbox/values.yaml](infrastructure/charts/kube-sandbox/values.yaml).
2. Commit and push the change to `main`.
3. ArgoCD will automatically apply the changes to the cluster (or run `make argo-sync` to apply instantly).

---

## Commands Reference

| Target | Description |
|---|---|
| `make setup` | Installs Ingress Controller and ArgoCD. |
| `make deploy` | Deploys the root ArgoCD application. |
| `make argo-sync` | Forces ArgoCD to sync immediately from Git. |
| `make port-forward` | Exposes the Frontend Ingress (8081) and ArgoCD UI (8080) concurrently. |
| `make build` | Builds all Docker images locally. |
| `make push-ghcr` | Builds local images and pushes them to GHCR with tag `0.0.0`. |
| `make test` | Smoke-tests the backend and frontend routes. |
| `make logs` | Tails logs from frontend and backend components. |
| `make status` | Checks running pods and services in the cluster. |
| `make clean` | Deletes the deployed application manifests. |
| `make nuke` | Deletes the entire setup (including Ingress and ArgoCD namespaces). |