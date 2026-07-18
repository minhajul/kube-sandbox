# Kube Sandbox — Plan

---

## What "perfect GitOps" means here (success criteria)

If you can do all five, the platform is "perfect" for a sandbox:

1. **Git is the only source of truth.** No one runs `kubectl apply` on the
   cluster after init. (Bootstrap may apply the ArgoCD Application once; after
   that, all changes are Git-driven.)
2. **A manifest change causes an observable rollout.** Push `main`, see
   ArgoCD go `OutOfSync → Synced → Healthy` in the UI without manual sync.
3. **Self-heal is provable.** A manually-deleted pod or hand-edited
   `replicas` field on the cluster reverts to Git's value within minutes and
   ArgoCD logs the diff.
4. **Drift is detectable in CI.** A PR that touches `infrastructure/` gets
   rendered (Helm template or `kustomize build`), validated
   (`kubeconform`/`conftest`), and shows the resulting diff in the PR. Merge
   is gated on the check.
5. **Image promotion is GitOps-driven.** A code merge that produces a new
   image updates the image tag in Git, not `kubectl set image`. (See
   *Decisions → Image promotion*.)

---

## Top-of-stack: do these first (GitOps quick wins)

| # | Action | Time | Why |
|---|--------|------|-----|
| 1 | Make a render decision (Helm vs Kustomize) and write `docs/adr/0002-rendering.md` | 1 hour | Unblocks everything else; every later phase depends on it |
| 2 | Move all apps out of `default` into a `apps` namespace; update `frontend.yaml` env vars and `next.config.js` rewrites in lockstep | 30 min | Required for NetworkPolicies, ResourceQuotas, PodSecurityAdmission, and tenant isolation |
| 3 | Replace `imagePullPolicy: Never` + `image: name:local` with a renderable image ref (e.g. Kustomize `images:` transformer or Helm `.Values.image.tag`); set default to `v0.0.0` initially | 1 hour | Today, a Git change to a manifest is "Synced" but does **not** roll out a new image — GitOps lie |
| 4 | Rename `*-svc` Services to match workload names; update every cross-reference (env vars, rewrites, `kubectl exec` snippets) in one commit | 30 min | Repo hygiene, not GitOps, but it's a dependency of step 2 |
| 5 | Add ArgoCD Notifications + one webhook (Slack/matrix/local HTTP) with `OnAppDegraded`, `OnOutOfSync`, `OnHealthDeteriorated` triggers | 2 hours | Today you only know ArgoCD is broken by manually running `make argo-status` |
| 6 | Add a `Makefile` target `make render` that runs `helm template` or `kustomize build` over `infrastructure/` and prints diff | 30 min | This is your "CI drift check" before you wire up GitHub Actions |

Total: roughly one focused afternoon. After these six, the project genuinely
deserves the word "GitOps-driven."

---

## Decisions to make first

These are not tasks — they are choices that gate every later bullet. Each
needs a one-page ADR under `docs/adr/`.

### Decision 1 — Rendering: Helm, Kustomize, or raw

| Option | Pros | Cons | When it wins |
|--------|------|------|--------------|
| **Raw YAML** (today) | Zero learning curve; what you have | No env promotion, no DRY, no parameterization. We're already here. | Throwaway demos only |
| **Kustomize** | Built into `kubectl`, no extra binary for users to install; `kustomize edit set image` is the simplest tag-promotion story; overlays for envs are first-class | Templating is awkward for non-trivial config (no conditionals); lives mostly in `kubectl` ecosystem | **Default choice for this repo.** Recommended. |
| **Helm** | Industry-standard templates, real templating language, familiar to anyone who's touched a chart | Steeper learning curve; values need a structured schema; image promotion is "bump values.yaml" with no first-class tool | If you want to publish the chart externally, or if you have non-trivial templating |

**Recommendation: Kustomize.** It pairs best with ArgoCD's
"Application for a path" model and gives you image promotion for free
(`kustomize edit set image` or the kustomize-controller's auto-bump).

### Decision 2 — Repo layout: monorepo or split config repo

| Option | Pros | Cons |
|--------|------|------|
| **Monorepo** (today — apps and manifests in one repo) | One PR can change app + manifest; simplest for a single-dev sandbox | Couples deploy cadence to code cadence; can't promote image without touching the same repo |
| **Split repo** — apps in `app-repo`, manifests in `k8s-config` | True GitOps: deploy cadence is independent, image promotion is a PR to `k8s-config` only, RBAC is per-repo | Two PRs to land a code change (code → image → manifest update); two repos to learn |

**Recommendation: stay monorepo for now**, but make `k8s-config` extraction
mechanical (it should be a `git subtree split` or a CI job away).

### Decision 3 — Secret strategy (no app secrets exist yet, lock this in before they do)

| Option | Pros | Cons |
|--------|------|------|
| **`kustomize` + sealed `Secret`/`envFrom` in YAML** | Simplest; no extra operator | Secrets are committed plaintext |
| **SOPS-encrypted secrets in YAML, decrypted by ArgoCD** | Encrypted in Git; decrypted in cluster; works with KMS, age, PGP | Needs ArgoCD config-management-plugin; pain at first run |
| **External Secrets Operator reading from a non-Git source** | Decouples secret source from Git | Needs an external store; overkill for sandbox |

**Recommendation: SOPS + age**, deferred until you actually have a secret.
Lock the decision now so you don't embed a `Secret` object in raw YAML by
accident.

### Decision 4 — Image promotion path

| Option | Push flow | Notes |
|--------|-----------|-------|
| **Tag-on-merge** | CI bumps `:v0.0.1` in `infrastructure/overlays/dev/kustomization.yaml` on `main` → PR | Simplest; suits monorepo |
| **Digest pinning** | CI bumps `@sha256:…` instead of tag | Safer but humans can't read it |
| **ArgoCD Image Updater** | ArgoCD watches image registries, writes back to Git | Most "GitOps-pure"; needs a registry and Git write-credentials |

**Recommendation: tag-on-merge to start.** Upgrade to Image Updater once you
have an actual registry.

### Decision 5 — Namespace strategy

| Option | Notes |
|--------|-------|
| **Everything in `default`** (today) | Bad: NetworkPolicies can't be per-workload, ResourceQuotas can't be per-team, PSA labels can't target. |
| **One namespace per workload** (`auth`, `profile`, `frontend`, `ingress-nginx`, `argocd`, `observability`) | Cleaner isolation; noisy YAML for a small sandbox |
| **`apps` + platform namespaces** — `apps/`, `ingress/`, `argocd/`, `observability/` | **Recommended.** Apps in one ns to share ingress/RBAC, observability in its own. |

---

## Current state of manifests (inventory before changes)

A "perfect GitOps-driven app" plan should know what it has. Current state:

**Already correct:**
- ArgoCD pinned at v2.9.5 via `--server-side --force-conflicts` install (line 24, 67 of `Makefile`). Avoids the CRD annotation-size bug.
- Sync policy: `automated.prune + selfHeal + allowEmpty=false` (root and observability Apps).
- Retry policy: exponential backoff, 5 attempts, max 3m.
- Sync options: `CreateNamespace=true`, `PrunePropagationPolicy=foreground`, `PruneLast=true`.
- DAG: root-app deploys `infrastructure/*.yaml` (top-level only, via `recurse: false` + `directory.include: '{*.yaml,*.yml}'`); observability-app deploys `infrastructure/observability/`. Two cleanly-separated Applications, no overlap.
- Probes: every Deployment has matching `livenessProbe` + `readinessProbe`.
- Non-root: Dockerfile UID 1001 (`nestjs` / `nextjs`), verified real.
- Observability path: Prometheus auto-discovers pod metrics via annotation
  relabeling (line 82–103 of `prometheus.yaml`), so workloads just need
  `prometheus.io/scrape: "true"` and a port annotation to be scraped.

**Currently broken or missing** (these are *the* GitOps gaps):

| # | Gap | File(s) | Severity |
|---|-----|---------|----------|
| G1 | `imagePullPolicy: Never` + `image: name:local` means a Git-driven change to `:local` is a no-op for pod rollout. **Push-to-deploy is broken.** | All 3 app manifests | High |
| G2 | `default` namespace used by everything; cannot apply NetworkPolicy / PodSecurityAdmission per workload | All app manifests, ingress, ArgoCD apps | High |
| G3 | ArgoCD Apps lack `ignoreDifferences`; any cluster-managed field (e.g., Service `clusterIP`, anything with a controller) will drift into `OutOfSync` | `infrastructure/argocd/*.yaml` | Medium |
| G4 | No ArgoCD Notifications, no Triggers, no Templates — sync/healthy-state changes are silent | `Makefile` does not install `argocd-notifications` controller | Medium |
| G5 | No `AppProject` resource — both Apps use `project: default`, no team/RBAC isolation | `infrastructure/argocd/*.yaml` | Low (single-dev) |
| G6 | No sync waves — apps don't declare ordering. OK today (all start independently), but blocks future DB-first ordering | App manifests lack `argocd.argoproj.io/sync-wave` annotations | Low |
| G7 | No `ServerSideApply=true` in `syncOptions`. SSA fixes one-source-of-truth conflicts with kubectl-similar tools | `infrastructure/argocd/*.yaml` | Medium |
| G8 | No `app.kubernetes.io/managed-by` / `app.kubernetes.io/part-of` labels on every resource — ArgoCD UI filtering and `kubectl get -l` queries are impaired | All manifests | Medium |
| G9 | Two ArgoCD `repoURL`s hardcoded to `minhajul/kube-sandbox`; must edit both before first sync (README already warns of this) | `infrastructure/argocd/*.yaml` | Low (already documented) |
| G10 | `Service` `clusterIP: None` not declared for headless services, but no headless services either — gap is moot | n/a | Skipped |
| G11 | No `PodSecurityStandard` label on `default` namespace. Default is `privileged`; no enforcement | `infrastructure/argocd/*.yaml` (or applied with `kubectl label`) | High (for hardening) |
| G12 | OTel Collector `hostPath: /var/lib/docker/containers` assumes Docker runtime — silent on containerd/CRI-O | `infrastructure/observability/otel-collector.yaml` line 169–171 | Low (Docker Desktop today) |

---

## Phase 1 — Renderable, declarative config

**Goal:** every Kubernetes manifest is rendered from a templated source. A
`make render` target produces the same YAML you would `kubectl apply`, byte-for-byte.

- [ ] **`docs/adr/0002-rendering.md`** — record Helm-vs-Kustomize decision (Decision 1).
- [ ] **`infrastructure/apps/kustomization.yaml`** (new) — root kustomization listing `bases/`, `components/`, `images:`.
- [ ] **`infrastructure/apps/bases/`** — move `auth-service.yaml`, `profile-service.yaml`, `frontend.yaml` here, strip `:local` literals, replace with `kustomize edit set image` placeholders.
- [ ] **`infrastructure/apps/components/defaults.yaml`** (new) — kustomize Component applying: labels (`app.kubernetes.io/managed-by: argocd`, `app.kubernetes.io/part-of: kube-sandbox`), `securityContext.runAsNonRoot: true`, common annotations.
- [ ] **`infrastructure/apps/overlays/`** (new) — overlay per env. Single `dev` for now (matches `apps` namespace).
- [ ] **`Makefile`** — add `render:` target that runs `kubectl kustomize infrastructure/apps/overlays/dev > /tmp/rendered.yaml`.
- [ ] **`infrastructure/argocd/root-application.yaml`** — change `path: infrastructure` to `path: infrastructure/apps/overlays/dev`, set `syncOptions: [ServerSideApply=true]`.

**Done when:** a manifest change in a base file shows up as a diff in
`/tmp/rendered.yaml`, and that diff is what gets pushed.

---

## Phase 2 — GitOps hygiene

**Goal:** every Git-driven change produces a real cluster change, and
non-Git changes are reverted.

- [ ] **`infrastructure/argocd/root-application.yaml` + `observability-application.yaml`** — add `syncOptions: [ServerSideApply=true, ApplyOutOfSyncOnly=true]`.
- [ ] **`infrastructure/argocd/root-application.yaml`** — add `ignoreDifferences` for fields that K8s controllers manage: `Service.clusterIP`, `Service.clusterIPs`, `Service.ports[*].nodePort`, `Service.ports[*].allocateLoadBalancerNodePorts`, `Service.healthCheckNodePort`, `EndpointSlice` endpoints, etc.
- [ ] **`Makefile`** — add `sync-waves` check: confirm apps declare `argocd.argoproj.io/sync-wave` annotations in dependency order (frontend = 3, both backends = 2, namespace = 0, secrets = 0).
- [ ] **`infrastructure/observability/argocd-notifications/`** (new dir) — install Notifications controller via the Makefile (split out from `argocd-up`); install `argocd-notifications-cm` (ConfigMap) with Triggers (`on-degraded`, `on-health-degraded`, `on-out-of-sync`) and Templates (`slack`, `webhook`).
- [ ] **`infrastructure/observability/notifications/services/webhook.yaml`** (new) — example webhook Service + receiver pod in cluster; same pattern for Slack secret.
- [ ] **App manifests** — add `app.kubernetes.io/managed-by: argocd`, `app.kubernetes.io/part-of: kube-sandbox`, `app.kubernetes.io/component: <app>`, `app.kubernetes.io/version: <semver>` labels (these become the Kustomize component's job).
- [ ] **`Makefile`** — add `drift-test:` target that mutates a workload out-of-band (`kubectl scale`), waits for self-heal, asserts cluster state matches Git.

**Done when:** `make drift-test` passes (mutation gets reverted); pushing a
manifest change produces a Synced→Healthy transition; out-of-sync events
hit a webhook.

---

## Phase 3 — Namespace + tenancy

**Goal:** workloads have namespaces, namespaces have boundaries.

- [ ] **`infrastructure/apps/bases/namespace.yaml`** (new) — declare `apps` namespace.
- [ ] **All app manifests** — move `metadata.namespace` from `default` → `apps`. Update `frontend.yaml` env vars (`auth-service-svc.default.svc.cluster.local` → `auth-service-svc.apps.svc.cluster.local`) and `next.config.js` `rewrites` in the same commit.
- [ ] **`infrastructure/apps/components/netpol-default-deny.yaml`** (new kustomize Component) — `NetworkPolicy` selector `{}` with no ingress/egress rules, applied to `apps` namespace.
- [ ] **`infrastructure/apps/components/netpol-allow-frontend.yaml`** (new) — explicit allow ingress from `ingress-nginx` namespace on port 3000; egress to `auth-service` + `profile-service` on their app ports.
- [ ] **`infrastructure/netpol-allow-argocd.yaml`** (new) — argocd namespace can read all namespaces (for sync).
- [ ] **`infrastructure/apps/bases/resourcequota.yaml`** (new) — namespace-wide quota: `requests.cpu: 4`, `requests.memory: 8Gi`, `limits.cpu: 8`, `limits.memory: 16Gi`, `pods: 20`.
- [ ] **`infrastructure/argocd/applicationset.yaml`** (new) — replace two hand-written Applications with an ApplicationSet generator that lists overlays (`dev` for now); each item gets its own `destination.namespace`.
- [ ] **`infrastructure/argocd/projects/kube-sandbox.yaml`** (new `AppProject`) — restricts source repos, destination namespaces, cluster resources, signature keys.

**Done when:** a netpol-violating pod in `apps` cannot reach the network; a
pod in `default` cannot reach the apps; HPA-style quota enforcement is
visible in `kubectl describe quota`.

---

## Phase 4 — Image promotion

**Goal:** a code change produces an image, the image lands in Git, the cluster rolls out — no human edits a tag.

- [ ] **`.github/workflows/build-and-promote.yaml`** (new) — on `main`: build three images with `docker buildx build --tag ghcr.io/$REPO/<svc>:${{ github.sha }} --push`; then `kustomize edit set image` per `infrastructure/apps/overlays/dev/`; then open a PR (or push directly to `main` after a manual approve step).
- [ ] **`.github/workflows/pr-render.yaml`** (new) — on PR: run `kustomize build infrastructure/apps/overlays/dev > /tmp/r.yaml`, run `kubeconform -strict -summary` against it, run `conftest` policies, post the diff as a PR comment.
- [ ] **`infrastructure/policies/`** (new) — Rego / `conftest` policies forbidding: `:latest` tags, missing `resources.limits`, missing `securityContext.runAsNonRoot`, `imagePullPolicy: Always` against `hostPath` mounts.
- [ ] **`kustomization.yaml`** — `images:` block per service pinned to a tag that flows from CI (e.g., `newTag: $GITHUB_SHA`).
- [ ] **Long-term: `argocd-image-updater`** (new) once you have a registry — annotations on each Deployment teach ArgoCD to watch GHCR and write image tags back to Git automatically. (See Decision 4.)

**Done when:** pushing a code change to `main` results in (a) a green PR-check
that shows a rendered diff, (b) a Git commit that bumps a tag, (c) an ArgoCD
sync that rolls the new image out.

---

## Phase 5 — Hardening (skip until Phases 1–4 are comfortable)

These are real but **should not compete with earlier phases for attention.**

- [ ] **`infrastructure/apps/components/security-context.yaml`** (new Component) — `runAsNonRoot: true`, `runAsUser: 1001`, `fsGroup: 1001`, `seccompProfile.type: RuntimeDefault`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true` with `emptyDir` writable mounts at `/tmp`, `/home/nestjs/.cache` etc.
- [ ] **PodSecurityAdmission** — label `apps` namespace with `pod-security.kubernetes.io/enforce: restricted`.
- [ ] **`infrastructure/observability/secrets/`** (new) — Sealed Secrets (one-time bootstrap) **or** an External Secrets Operator pointing at a file-backed secret store; encrypt `JWT_SECRET` and any future DB credentials. (See Decision 3.)
- [ ] **`infrastructure/policies/`** — extend with: `hostNetwork: true` forbidden, `hostPath: /` forbidden, ServiceAccount `automountServiceAccountToken: true` forbidden.
- [ ] **`infrastructure/apps/bases/pdb.yaml`** (new) — `PodDisruptionBudget: minAvailable: 1` per workload (learning artifact; meaningless on single-node).
- [ ] **`infrastructure/apps/bases/hpa.yaml`** (new) — `HorizontalPodAutoscaler` per workload CPU 70% / min 2 / max 5 (won't fire on single-node, document as such).
- [ ] **cert-manager** — install + `ClusterIssuer` for `selfsigned`/`mkcert` so the ingress can serve HTTPS on `localhost`. Pairs with a `tls:` section in `ingress.yaml`. (Be aware: mixing this with `kubectl port-forward` means the cert isn't trusted by the browser unless `mkcert` is run.)

**Done when:** a privileged pod cannot start in `apps`; an HPA exists and
is observable in ArgoCD; the ingress serves TLS without warnings.

---

## Operational / DX items deferred

These are not GitOps primitives — they're platform comfort features for a
sandbox. Pull them in *after* Phases 1–5 are stable.

- [ ] **`Makefile`** — add `live-logs:` that streams logs grouped by pod, not by deployment (the current `make logs` tails 3 deployments in parallel and the output intermingles badly).
- [ ] **`Makefile`** — add `render-diff:` that compares `/tmp/rendered.yaml` against `git show HEAD:infrastructure/<path>` — answers "what would a sync change?"
- [ ] **`Tiltfile`** (new, in root) — for live-reload of dev workflows; not a GitOps primitive (it's in-cluster live coding). Skip until the platform is settled.
- [ ] **`.editorconfig`**, **`.github/dependabot.yml`** for image tags, **`.pre-commit-config.yaml`** with `gitleaks` — repo hygiene, not GitOps.
- [ ] **`LICENSE`** file — repo hygiene. The README's "MIT" footer mentions it but the file doesn't exist.

---

## What to **not** do (out-of-scope by your focus)

These appear in earlier drafts of the plan and are explicitly cut here
because they pull attention from GitOps:

- ❌ Build a real auth flow with JWT, bcrypt, DTOs, validation pipes. The
  current `/health`-only endpoints are correct for the platform focus.
- ❌ Add `@opentelemetry/sdk-node` to the apps, wire traces from Nest/Next
  to the collector. The collector already has receivers; wiring apps to
  it is app-code work, not GitOps work. (If you want traces flowing, do
  it once, in one branch, after Phases 1–4 are green.)
- ❌ Add a real `LoginForm` page, profile editor, server actions, etc. Same
  reason.
- ❌ Full Playwright suite, Jest e2e, `supertest`. The README's smoke tests
  via `curl` are sufficient evidence the platform is working.
- ❌ Convert `Dockerfile` to multi-arch `--platform linux/amd64,linux/arm64`.
  Docker Desktop handles this transparently; the build-time flag is a
  CI concern, not a GitOps concern.
- ❌ Argo Rollouts, Argo Workflows, Argo Events. They're separate products
  and only relevant when the deployment story needs them.

---

## Appendix A — Current ArgoCD Application shape (so we can diff later)

```yaml
# root-application.yaml — what we have today
project: default
source:
  repoURL: https://github.com/minhajul/kube-sandbox.git     # hardcoded
  targetRevision: HEAD
  path: infrastructure                                       # top-level only, recurse: false
  directory:
    recurse: false
    include: '{*.yaml,*.yml}'
destination:
  server: https://kubernetes.default.svc
  namespace: default                                          # apps go to default
syncPolicy:
  automated: { prune: true, selfHeal: true, allowEmpty: false }
  syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true
  retry: { limit: 5, backoff: { duration: 5s, factor: 2, maxDuration: 3m } }
```

```yaml
# observability-application.yaml — same shape, different path/namespace
# (omitted; identical otherwise)
```

After Phase 1 the root Application's `path` will become
`infrastructure/apps/overlays/dev` and `syncOptions` will gain
`ServerSideApply=true`.

---

## Appendix B — Glossary

- **GitOps** — Kubernetes manifests live in Git; an in-cluster agent
  (ArgoCD here) reconciles the cluster to whatever Git says.
- **App-of-Apps** — an ArgoCD Application whose only job is to create
  other Applications. The repo currently uses two hand-written Applications,
  no App-of-Apps App. Phase 5 introduces an ApplicationSet instead.
- **ApplicationSet** — ArgoCD controller that generates multiple Applications
  from one template + a generator (list, git, cluster).
- **Sync wave** — `argocd.argoproj.io/sync-wave` annotation. ArgoCD syncs
  resources in ascending wave order. Use for dependency sequencing.
- **ServerSideApply** — `syncOptions: [ServerSideApply=true]`. ArgoCD uses
  the K8s API's server-side apply, which fixes ownership conflicts with
  other controllers. Recommended in Phase 2.
- **Helm/Kustomize/raw** — three ways to render manifests. See Decision 1.
- **PodSecurityAdmission** — K8s built-in admission controller that
  enforces `privileged`/`baseline`/`restricted` policies per namespace.
  Activated by a namespace label; no operator required.
- **SOPS / Sealed Secrets / External Secrets** — three secret strategies.
  See Decision 3.
