# Kube Sandbox

A **GitOps-driven microservices sandbox** that runs entirely on your laptop. Two
NestJS backend services (`auth-service`, `profile-service`) and a Next.js frontend are
deployed to **Docker Desktop's built-in Kubernetes** via **ArgoCD**, fronted by the
**NGINX Ingress Controller**, and observed through **Prometheus + Grafana + Loki +
the OpenTelemetry Collector + RustFS** (apps expose `/health` but are not
auto-instrumented for traces).

---

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Repository Layout](#repository-layout)
- [The Makefile](#the-makefile)
- [How the Pieces Fit Together](#how-the-pieces-fit-together)
  - [Ingress routing](#ingress-routing)
  - [ArgoCD sync](#argocd-sync)
  - [Health probes](#health-probes)
  - [Image build model](#image-build-model)
- [Daily Workflows](#daily-workflows)
- [Observability Stack](#observability-stack)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)
- [Limitations & Notes](#limitations--notes)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Docker Desktop (macOS)                        │
│                                                                     │
│   ┌───────────────────────────────────────────────────────────┐     │
│   │              Built-in Kubernetes Cluster                  │     │
│   │                                                           │     │
│   │   ┌──────────────────┐    ┌──────────────────────────┐   │     │
│   │   │  NGINX Ingress   │───▶│  frontend-svc (Next.js)  │   │     │
│   │   │  Controller      │ /  │   :3000, 2 replicas      │   │     │
│   │   └──────────────────┘    └──────────────────────────┘   │     │
│   │                                  │                       │     │
│   │                                  │  server-side fetch    │     │
│   │                                  │  (cluster DNS, never  │     │
│   │                                  │   via ingress)        │     │
│   │                                  ▼                       │     │
│   │   ┌──────────────────┐    ┌──────────────────────────┐   │     │
│   │   │ auth-service-svc │    │ profile-service-svc      │   │     │
│   │   │   :3001, 2 repl  │    │   :3002, 2 replicas      │   │     │
│   │   └──────────────────┘    └──────────────────────────┘   │     │
│   │                                                           │     │
│   │   ┌────────────────────────────────────────────────────┐  │     │
│   │   │  ArgoCD  (watches infrastructure/ in Git → sync)   │  │     │
│   │   └────────────────────────────────────────────────────┘  │     │
│   │                                                           │     │
│   │   namespace: observability                                │     │
│   │   ┌──────────┐ ┌────────────┐ ┌─────────┐ ┌──────────┐    │     │
│   │   │Prometheus│ │  Grafana   │ │  Loki   │ │ OTel Coll│    │     │
│   │   └──────────┘ └────────────┘ └─────────┘ └──────────┘    │     │
│   │   ┌──────────┐ ┌────────────┐ ┌────────────┐              │     │
│   │   │  RustFS  │ │ kube-state │ │node-exporter│             │     │
│   │   └──────────┘ └────────────┘ └────────────┘              │     │
│   └───────────────────────────────────────────────────────────┘     │
│                                                                     │
│   Images built directly into the shared daemon (no registry needed) │
└─────────────────────────────────────────────────────────────────────┘
            ▲                       ▲                                ▲
            │  localhost:8081        │  localhost:8080               │  :9090/:3003/:9001
            │  (forwarded ingress)   │  (forwarded ArgoCD UI)        │  (forwarded observability)
            │                       │                                │
       ┌────┴─────┐         ┌──────┴──────┐                  ┌──────┴──────┐
       │ Browser  │         │  ArgoCD UI  │                  │  kubectl    │
       │ :8081    │         │  :8080      │                  │  port-fwd   │
       └──────────┘         └─────────────┘                  └─────────────┘
```

**Important routing detail:** the NGINX Ingress serves **only** `/` to the
frontend. The `/api/auth/*` and `/api/profile/*` paths are **never** routed by
the ingress — the Next.js server fetches them server-side over cluster DNS
(`*.default.svc.cluster.local`). The browser only ever talks to the frontend.

---

## Prerequisites

You only need a handful of CLI tools and a running Kubernetes cluster on your Mac.

| Tool           | Why                                    | Install                                                  |
| -------------- | -------------------------------------- | -------------------------------------------------------- |
| **Docker Desktop** | Runs the K8s cluster + builds images   | [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) — enable *Settings → Kubernetes* |
| **kubectl**    | Cluster interaction                    | `brew install kubectl`                                   |
| **Helm**       | Used in the install/verify helpers     | `brew install helm`                                      |
| **curl**       | Smoke tests                            | preinstalled                                             |
| **make**       | Drives the build/deploy workflow       | `xcode-select --install`                                 |

Verify everything is in place:

```bash
make check-deps
docker info | grep -i "server version"   # Docker Desktop is up
kubectl get nodes                         # Kubernetes is enabled
```

> **Note on port 80.** Tools like **Laravel Herd** and the built-in Apache on macOS
> bind to port 80, which clashes with the NGINX Ingress Controller. This project
> works around it by exposing the ingress on **`localhost:8081`** via
> `kubectl port-forward`. If you want true port-80 access, stop Herd's nginx first.

---

## Quick Start

Five commands from zero to a running dashboard:

```bash
# 1. Bootstrap the cluster (one-time) — installs ingress + ArgoCD
make setup

# 2. Build images + apply manifests + register ArgoCD app
make up

# 3. Wait for ArgoCD to sync, then expose the ingress
make argo-status          # Sync: Synced  Health: Healthy
make port-forward         # http://localhost:8081

# 4. Smoke-test the routed services
make test

# 5. (Optional) Bring up the observability stack
make deploy-obs
```

> **Before step 1**, update `repoURL` in both
> `infrastructure/argocd/root-application.yaml` and
> `infrastructure/argocd/observability-application.yaml` to point at your fork.
> Each ArgoCD Application has its own `repoURL`, so skipping this in step 5
> causes `make deploy-obs` to fail with a "repository not found" error from
> ArgoCD.

Open **http://localhost:8081** in your browser. You should see the
*Kube Sandbox Dashboard* with both services reporting `online`.

---

## Repository Layout

```
kube-sandbox/
├── README.md                       ← you are here
├── Makefile                        ← single entrypoint for every operation
├── .gitignore
│
├── backend/
│   ├── auth-service/               ← NestJS, port 3001, GET /health
│   │   ├── Dockerfile              ← multi-stage, non-root, distroless-ish
│   │   ├── package.json
│   │   ├── package-lock.json
│   │   ├── tsconfig.json
│   │   ├── nest-cli.json
│   │   └── src/
│   │       ├── main.ts
│   │       ├── app.module.ts
│   │       └── health.controller.ts
│   │
│   └── profile-service/            ← NestJS, port 3002, GET /health
│       └── (mirrors auth-service)
│
├── frontend/                       ← Next.js 14 (App Router), port 3000
│   ├── Dockerfile                  ← 3-stage, output: 'standalone'
│   ├── next.config.js              ← rewrites for backend cluster DNS
│   ├── package.json
│   ├── package-lock.json
│   └── src/app/
│       ├── layout.tsx
│       ├── page.tsx                ← dashboard with auto-polling
│       └── globals.css
│
└── infrastructure/
    ├── ingress.yaml                ← NGINX Ingress (frontend root)
    ├── auth-service.yaml           ← Deployment + ClusterIP Service
    ├── profile-service.yaml        ← Deployment + ClusterIP Service
    ├── frontend.yaml               ← Deployment + ClusterIP Service
    │
    ├── argocd/
    │   ├── root-application.yaml          ← App of Apps root
    │   └── observability-application.yaml ← observes observability/*
    │
    └── observability/
        ├── namespace.yaml
        ├── prometheus.yaml
        ├── grafana.yaml
        ├── loki.yaml
        ├── otel-collector.yaml
        ├── kube-state-metrics.yaml
        ├── node-exporter.yaml
        └── rustfs.yaml
```

---

## The Makefile

The Makefile is the **single entrypoint** for everything. Run `make help` to see
all targets.

### Bootstrap

| Target           | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| `make setup`     | One-time: installs NGINX Ingress + ArgoCD           |
| `make check-deps`| Verifies `docker`, `kubectl`, `helm`, `curl`         |
| `make ingress-up` / `ingress-down` | Install/uninstall NGINX Ingress        |
| `make argocd-up` / `argocd-down`   | Install/uninstall ArgoCD (v2.9.5)       |

### Build / Deploy

| Target           | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| `make build`     | Build all 3 images into the local Docker daemon     |
| `make rebuild`   | Build with `--no-cache`                              |
| `make deploy`    | `kubectl apply` all manifests + ArgoCD app           |
| `make up`        | `build` + `deploy`                                   |
| `make dev`       | `deploy` only (skip rebuild)                         |

### Status / Logs

| Target             | Purpose                                            |
| ------------------ | -------------------------------------------------- |
| `make status`      | Deployments, pods, services, ingress (all-in-one) |
| `make pods`        | Just the pods                                      |
| `make logs`        | Tail logs from all 3 deployments                  |
| `make restart`     | Rolling-restart all 3 deployments                 |
| `make argo-status` | ArgoCD sync + health status (one line)             |
| `make argo-sync`   | Force ArgoCD to re-sync from Git                   |
| `make argo-ui`     | Port-forward ArgoCD UI to `https://localhost:8080` |

### Test

| Target             | Purpose                                              |
| ------------------ | ---------------------------------------------------- |
| `make port-forward`| Expose ingress on `localhost:8081`                   |
| `make test`        | Smoke-test `/api/auth/health`, `/api/profile/health`, `/` |
| `make health`      | Direct port-forward to each backend, no ingress      |

### Observability

| Target                | Purpose                                            |
| --------------------- | -------------------------------------------------- |
| `make deploy-obs`     | Install Prometheus, Grafana, Loki, OTel, RustFS   |
| `make grafana`        | Grafana on `http://localhost:3003` (admin/admin)   |
| `make prometheus`     | Prometheus on `http://localhost:9090`              |
| `make rustfs`         | RustFS console on `http://localhost:9001`          |
| `make obs-status`     | Pod status of the observability namespace          |

### Cleanup

| Target           | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| `make clean`     | Delete app manifests + ArgoCD app                   |
| `make clean-obs` | Delete observability manifests + namespace           |
| `make nuke`      | Everything above + remove ingress + remove ArgoCD   |

---

## How the Pieces Fit Together

### Ingress routing

The single NGINX Ingress at `/` serves the frontend. The frontend talks to
backends over **cluster DNS** — `auth-service-svc.default.svc.cluster.local:3001`
and `profile-service-svc.default.svc.cluster.local:3002` — injected via the
`AUTH_SERVICE_URL` and `PROFILE_SERVICE_URL` env vars in `frontend.yaml`.
The same image works anywhere; routing is purely declarative. The ingress
itself never sees traffic to the backends.

### ArgoCD sync

ArgoCD watches `infrastructure/` in Git and reconciles the cluster to match.
A `git push` is picked up in ~3 minutes (or force-sync with `make argo-sync`).
No `kubectl apply` is needed for manifest edits.

> **Heads-up:** `repoURL` in `infrastructure/argocd/root-application.yaml` and
> `observability-application.yaml` is hardcoded to
> `https://github.com/minhajul/kube-sandbox.git` — point **both** at your fork
> before the first sync, otherwise ArgoCD will fail to clone the repo.

### Health probes

Backends probe `GET /health`; the frontend probes `GET /` on port 3000.
K8s only routes traffic to *ready* pods, so a broken container is automatically
removed from the service until it recovers — the dashboard reflects this in
near-real time.

### Image build model

Images use `imagePullPolicy: Never` with the `local` tag because they're
built directly into Docker Desktop's shared daemon
(`docker build -t auth-service:local ./backend/auth-service`). No registry, no
TLS certs, no `insecure-registries` config needed.

---

## Daily Workflows

### Edit code, see the change

```bash
# 1. Edit code (e.g. frontend/src/app/page.tsx)
# 2. Rebuild only the image you changed
docker build -t frontend:local ./frontend     # or: make rebuild (all)
# 3. Trigger a rolling restart
make restart
# 4. Watch the rollout
kubectl rollout status deployment/frontend --timeout=60s
```

### Edit a manifest, let ArgoCD pick it up

```bash
# 1. Edit infrastructure/auth-service.yaml
# 2. Commit + push
git add infrastructure/ && git commit -m "bump replicas" && git push
# 3. Either wait ~3 min or force-sync
make argo-sync
```

### Inspect what's running

```bash
make status              # full picture
make pods                # just the pods
make logs                # tail logs from all 3 deployments
```

---

## Observability Stack

```bash
make deploy-obs
make obs-status          # wait for all pods Running
```

| Service       | URL (after port-forward)             | Credentials          |
| ------------- | ------------------------------------ | -------------------- |
| Grafana       | `http://localhost:3003`              | `admin` / `admin`    |
| Prometheus    | `http://localhost:9090`              | —                    |
| RustFS console| `http://localhost:9001`              | `admin` / `admin123456` |
| ArgoCD UI     | `https://localhost:8080`             | `admin` / (see below)|

For ArgoCD's initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode; echo
```

The observability namespace is also managed by ArgoCD
(`observability-application.yaml`), so any change to a file under
`infrastructure/observability/` is reconciled automatically.

---

## Troubleshooting

### Dashboard shows `offline` for both services

The dashboard includes diagnostic text under each offline card. Read it:

- **`Failed to fetch` / `NetworkError`** — you opened `http://localhost/` which
  is being answered by **Laravel Herd** (or another process on port 80). Use
  **`http://localhost:8081/`** instead. To free port 80, stop Herd's nginx.
- **`HTTP 404`** — the path is wrong or the ingress didn't pick up the rule.
  Run `kubectl get ingress -o yaml` to confirm.
- **`HTTP 503`** — backend pods are not ready. Run `make status`.

### ArgoCD app stuck `OutOfSync` / `Progressing`

```bash
make argo-status             # check sync + health
make argo-sync               # force a sync
make argo-ui                 # see the diff visually
```

### A pod won't start

```bash
kubectl get pods                                    # find the failing pod
kubectl describe pod <pod-name>                     # events
kubectl logs <pod-name> --previous                  # last container's logs
```

### `ImagePullBackOff` after editing a manifest

The manifests use `imagePullPolicy: Never` and tag `local`. Make sure you
actually built the image (`make build`) **before** the pod tries to start.

### Port 80 already in use

```bash
sudo lsof -i :80
# Stop Herd's nginx, or just stick with make port-forward (8081).
```

---

## Cleanup

Three escalating levels:

```bash
make clean         # tear down app manifests + ArgoCD app
make clean-obs     # tear down observability stack + namespace
make nuke          # clean + clean-obs + argocd-down + ingress-down
```

`make nuke` returns the cluster to a pre-project state. Nothing on your laptop
outside Docker Desktop / kubectl context is touched.

---

## Limitations & Notes

- **Single-node cluster.** Docker Desktop runs a one-node K8s cluster — replicas
  >1 are useful for rolling-update testing only.
- **ArgoCD `repoURL` is hardcoded.** Update both
  `infrastructure/argocd/*.yaml` files to point at your fork.
- **RustFS is included but not wired to the apps.** It's there for you to
  experiment with object storage, not consumed by any current deployment.
- **`make port-forward` blocks the terminal.** Use a separate shell or
  background it (`make port-forward &`).

---

## License

MIT — do whatever you want with this.