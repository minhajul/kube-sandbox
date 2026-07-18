# Implementation Plan

A step-by-step sequence to take `kube-sandbox` from "raw manifests + one ArgoCD
Application" to an industry-standard GitOps pipeline. Each step lists
**what you change**, **the commands to run**, and **the evidence that it
worked**.

> Decisions locked in:
> - Renderer: **Helm**
> - Image promotion: **Tag-on-merge via GitHub Actions**
> - Env shape: **One `dev` overlay/env, structured so `stage`/`prod` are copy-paste later**
> - Scope: **Phases 1–4 only** (renderer, hygiene, namespace+tenancy, image promotion)

---

## Success criteria — what "industry-standard GitOps" means here

If you can do all five, the platform qualifies:

1. **Git is the only source of truth.** No one runs `kubectl apply` on the
   cluster after init. (Bootstrap may apply the ArgoCD Application once;
   after that, all changes are Git-driven.)
2. **A manifest change causes an observable rollout.** Push `main`, see
   ArgoCD go `OutOfSync → Synced → Healthy` in the UI without manual sync.
3. **Self-heal is provable.** A manually-deleted pod or hand-edited
   `replicas` field on the cluster reverts to Git's value within minutes
   and ArgoCD logs the diff.
4. **Drift is detectable in CI.** A PR that touches `infrastructure/` gets
   rendered (`helm template`), validated (`kubeconform`/`conftest`), and
   shows the resulting diff in the PR. Merge is gated on the check.
5. **Image promotion is GitOps-driven.** A code merge that produces a new
   image updates the image tag in Git, not `kubectl set image`.

---

## Decisions (locked)

Each was a fork; each would gate later work differently.

### D1 — Renderer: Helm

Considered: raw YAML (today), Helm, Kustomize.

| Option | Verdict |
|--------|---------|
| Raw YAML | Throwaway demos only. Cannot do env promotion or DRY. |
| Kustomize | Solid choice, lighter learning curve than Helm, image promotion via `kustomize edit set image` is first-class. Downside: templating is awkward (no conditionals); lives mostly in `kubectl` ecosystem. |
| **Helm (chosen)** | Industry-standard templates, real templating language, familiar. Trade-off: image promotion flows through `values.yaml` and CI glue (Phase 4). |

### D2 — Repo layout: monorepo

Considered: monorepo (one repo, app + manifests), split config repo.

| Option | Verdict |
|--------|---------|
| **Monorepo (chosen, today)** | One PR can change code + manifest in lockstep. Single deployment cadence. |
| Split repo (`app-repo` + `k8s-config`) | True GitOps purism — deploy cadence is independent. Trade-off: two PRs per code change (code → image → manifest bump). |

For a single-developer sandbox, monorepo wins. Plan for extraction via
`git subtree split` if it ever becomes painful.

### D3 — Secrets: SOPS + age (deferred)

Considered: plaintext in YAML, sealed `Secret`, SOPS in YAML decrypted by ArgoCD, External Secrets Operator.

No app secrets exist yet. **Lock now: no plaintext `Secret` objects in
Git.** When a secret is needed, SOPS-encrypted YAML decrypted by an ArgoCD
config-management-plugin. Defer install until something needs encrypting.

### D4 — Image promotion: tag-on-merge via GitHub Actions

Considered: tag-on-merge, digest pinning, ArgoCD Image Updater.

| Option | Verdict |
|--------|---------|
| **Tag-on-merge (chosen)** | CI builds image, bumps `image.tag` in `infrastructure/apps-values.yaml`, opens a PR. No registry write-credentials for ArgoCD. |
| ArgoCD Image Updater | Most "GitOps-pure" but needs GHCR credentials in ArgoCD and watch-back-to-Git setup. Upgrade later. |
| Digest pinning | Safest but humans can't read `@sha256:…`. |

### D5 — Namespaces: `apps` + platform

Considered: everything in `default`, one ns per workload, `apps` + platform split.

| Option | Verdict |
|--------|---------|
| Everything in `default` (today) | Bad: NetworkPolicies can't be per-workload, ResourceQuotas can't be per-team, PSA can't target. |
| **Apps split + platform namespaces (chosen)** | Move workloads to `apps`. Keep `argocd/`, `observability/`, `ingress-nginx/`, `kube-system` as platform namespaces. |
| One ns per workload | Noisy for a 3-service sandbox. |

---

## Current gaps this plan fixes

The following are real flaws in the current state, addressed in the phases below.

| # | Gap | File(s) | Phase |
|---|-----|---------|-------|
| G1 | `imagePullPolicy: Never` + `image: name:local` — a Git-driven manifest change is "Synced" but doesn't roll a new image. **Push-to-deploy broken.** | All 3 app manifests | 1, 4 |
| G2 | `default` namespace used by everything; per-workload NetworkPolicy / ResourceQuota / PSA impossible | All app manifests, ingress, ArgoCD apps | 3 |
| G3 | ArgoCD Apps lack `ignoreDifferences`; controller-managed fields (Service `clusterIP`, etc.) cause false `OutOfSync` | `infrastructure/argocd/*.yaml` | 3 |
| G4 | No ArgoCD Notifications, no Triggers, no Templates — sync/health changes are silent | `Makefile` does not install `argocd-notifications` controller | 3 |
| G5 | No `AppProject` resource — both Apps use `project: default`, no team isolation | `infrastructure/argocd/*.yaml` | post-Phase-4 |
| G6 | No sync waves — apps don't declare dependency ordering | App manifests lack `argocd.argoproj.io/sync-wave` annotations | 3 |
| G7 | No `ServerSideApply=true` in `syncOptions`. SSA fixes ownership conflicts | `infrastructure/argocd/*.yaml` | 2 |
| G8 | Missing standard labels (`managed-by`, `part-of`, `component`, `version`) on every resource | All manifests | 1 (via `_helpers.tpl`) |
| G9 | Two ArgoCD `repoURL`s hardcoded to `minhajul/kube-sandbox` | `infrastructure/argocd/*.yaml` | Out of scope (already documented in README) |
| G10 | Service `clusterIP: None` not declared for headless services — moot (no headless services exist) | n/a | n/a |
| G11 | No `PodSecurityStandard` label on `default` | `infrastructure/argocd/*.yaml` | Phase 5 |

Already correct (do not regress): ArgoCD pinned to v2.9.5 with
`--server-side --force-conflicts`; sync policy has `prune + selfHeal`;
retry policy exponential backoff 5×/3m; sync options include
`CreateNamespace`, `PrunePropagationPolicy=foreground`, `PruneLast`;
probes on every Deployment; non-root UIDs 1001 verified in Dockerfiles;
Prometheus auto-discovers pod metrics via annotations.

---

## Pre-flight — install the tooling the steps assume

These should be installed before step 1, otherwise later steps fail silently.

```bash
# All have macOS brew formulas and Linux alternatives.
brew install helm                                    # already installed (helm v4.2.1) — verify
helm version --short

brew install kubeconform                             # required by Phase 4 CI check
kubeconform -v

brew install conftest opa                           # required by Phase 4 conftest job
conftest --version

brew install yq                                     # required by step 1c (diff) and step 4a (tag bump)
yq --version

# Optional but recommended for diff/quality of life
helm plugin install https://github.com/databus23/helm-diff
```

Verify everything works before continuing:

```bash
helm version --short
kubeconform -v
conftest --version
yq --version
```

**Evidence of success:** all four commands print versions; no `command not
found`.

---

## Phase 1 — Render the existing cluster state with Helm

The goal is to get `helm template` producing the same YAML you have today, so
nothing about runtime behavior changes. Touch nothing in production until step
1c is byte-equivalent (or, for known differences, byte-different for
*reasons*).

### Step 1a. Bootstrap the chart skeleton

```bash
cd /Users/minhajul/Code/DevOps/kube-sandbox
mkdir -p infrastructure/charts/kube-sandbox/templates
```

Create `infrastructure/charts/kube-sandbox/Chart.yaml`:

```yaml
apiVersion: v2
name: kube-sandbox
description: GitOps-driven microservices sandbox
type: application
version: 0.1.0       # chart version (bumped per release)
appVersion: "0.1.0"  # tracks the application code
```

Create `infrastructure/charts/kube-sandbox/values.yaml` with the **current
hardcoded values** as defaults (this is the critical bit):

```yaml
nameOverride: ""
fullnameOverride: ""

# Image defaults — overridden per-app below.
image:
  repository: ghcr.io/minhajul/kube-sandbox
  pullPolicy: IfNotPresent
  tag: v0.0.0       # safe default; CI will bump this

replicaCount: 2

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: localhost
      paths: [/]

namespace:
  name: apps                      # new namespace target
  create: true

# Per-app overrides. Each app has its own port, image name, and resources.
apps:
  auth:
    port: 3001
    image: auth-service
    replicaCount: 2
    resources:
      requests: { cpu: 50m,  memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }
  profile:
    port: 3002
    image: profile-service
    replicaCount: 2
    resources:
      requests: { cpu: 50m,  memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }
  frontend:
    port: 3000
    image: frontend
    replicaCount: 2
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
```

**Why per-app blocks:** the three apps currently have different resource
sizes and different container ports. A single chart-wide `resources` and
`service.port` would silently flatten them — the diff at Step 1c would
show unexplained resource/port changes and the cluster DNS names would
expose `:80` instead of `:3001/:3002/:3000`, breaking
`AUTH_SERVICE_URL`/`PROFILE_SERVICE_URL`.

**Why those values:** `apps.<name>.resources`, `apps.<name>.port`, and
`apps.<name>.replicaCount` become the **only place** a deploy-target needs
to change. After this step, "upgrading to v0.2.0" is a one-line
`values.yaml` PR.

### Step 1b. Move the three Deployments into the chart

For each of `auth-service.yaml`, `profile-service.yaml`, `frontend.yaml`:

1. Strip the literal `image:` field — it will be templated.
2. Strip `replicas:` (templated).
3. Strip `namespace: default` (templated to `apps`).
4. Strip the duplicated resource limits (templated).
5. Strip the literal service name suffix `-svc` (templated).

Save the resulting body as
`infrastructure/charts/kube-sandbox/templates/<app>.yaml`. **Do not** write
Helm template language yet; keep them as plain YAML for now.

Concrete example for `auth-service`. Note the per-app values — `port`, `replicaCount`, `resources`, and `image` all come from `.Values.apps.auth`, not the chart-wide `.Values`:

```yaml
# infrastructure/charts/kube-sandbox/templates/auth-service.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "kube-sandbox.fullname" . }}-auth
  labels:
    {{- include "kube-sandbox.labels" . | nindent 4 }}
    app.kubernetes.io/component: auth
spec:
  replicas: {{ .Values.apps.auth.replicaCount }}
  selector:
    matchLabels:
      {{- include "kube-sandbox.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: auth
  template:
    metadata:
      labels:
        {{- include "kube-sandbox.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: auth
    spec:
      serviceAccountName: {{ include "kube-sandbox.fullname" . }}-auth
      containers:
        - name: auth
          image: "{{ .Values.image.repository }}/{{ .Values.apps.auth.image }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports: [{ containerPort: {{ .Values.apps.auth.port }}, name: http }]
          env:
            - { name: PORT, value: "{{ .Values.apps.auth.port }}" }
          readinessProbe:
            httpGet: { path: /health, port: {{ .Values.apps.auth.port }} }
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health, port: {{ .Values.apps.auth.port }} }
            initialDelaySeconds: 20
            periodSeconds: 20
          resources: {{- toYaml .Values.apps.auth.resources | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "kube-sandbox.fullname" . }}-auth
  labels:
    {{- include "kube-sandbox.labels" . | nindent 4 }}
    app.kubernetes.io/component: auth
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.apps.auth.port }}
      targetPort: {{ .Values.apps.auth.port }}
      protocol: TCP
      name: http
  selector:
    {{- include "kube-sandbox.selectorLabels" . | nindent 6 }}
    app.kubernetes.io/component: auth
```

> **Cluster DNS warning.** With `helm install apps ...` the chart renders
> resource names like `apps-kube-sandbox-auth`, so cluster DNS is
> `apps-kube-sandbox-auth.apps.svc.cluster.local`. The frontend's
> `AUTH_SERVICE_URL` env var must point there, not at the legacy
> `auth-service-svc.default.svc.cluster.local` name. Step 1b's
> `frontend.yaml` env values must use the new naming scheme. Do not
> hardcode `auth-service-svc` anywhere in the templates — the chart
> emits the actual service name.

Repeat for `profile-service.yaml` (use `.Values.apps.profile`) and
`frontend.yaml` (use `.Values.apps.frontend`). The frontend template must
also set:

```yaml
env:
  - name: AUTH_SERVICE_URL
    value: "http://{{ include "kube-sandbox.fullname" . }}-auth.{{ .Values.namespace.name }}.svc.cluster.local:{{ .Values.apps.auth.port }}"
  - name: PROFILE_SERVICE_URL
    value: "http://{{ include "kube-sandbox.fullname" . }}-profile.{{ .Values.namespace.name }}.svc.cluster.local:{{ .Values.apps.profile.port }}"
```

This way the env var URLs follow the Helm release name — no hardcoded
service names.

Create `infrastructure/charts/kube-sandbox/templates/_helpers.tpl`:

```gotemplate
{{/* Standard `name`, `fullname`, `labels`, `selectorLabels` helpers. */}}
{{- define "kube-sandbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kube-sandbox.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "kube-sandbox.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "kube-sandbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kube-sandbox
{{- end -}}

{{- define "kube-sandbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kube-sandbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

Create `infrastructure/charts/kube-sandbox/templates/namespace.yaml`:

```yaml
{{- if .Values.namespace.create -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace.name }}
  labels:
    {{- include "kube-sandbox.labels" . | nindent 4 }}
{{- end }}
```

### Step 1c. Verify Helm renders to (near-)equivalent YAML

```bash
cd /Users/minhajul/Code/DevOps/kube-sandbox
helm template apps infrastructure/charts/kube-sandbox \
  --namespace apps > /tmp/rendered.yaml

# Diff against what you have today (rendered via kubectl on what's deployed).
kubectl get -o yaml -n default deploy,svc,ingress > /tmp/live.yaml 2>/dev/null
diff -u <(yq -P 'sort_keys(..)' /tmp/rendered.yaml) \
        <(yq -P 'sort_keys(..)' /tmp/live.yaml) | head -100
```

**Expected result:** the diff is mostly namespace, image refs (`:local` →
`ghcr.io/...:v0.0.0`), label additions (`app.kubernetes.io/managed-by:
Helm`), and service name suffixes. **No structural surprises.**

If there are surprises, fix them in the chart and re-render. Iterate until
diff is boring.

**Evidence of success:** `helm template apps infrastructure/charts/kube-sandbox`
exits 0 and the diff to live is short and explainable.

### Step 1d. Move ingress into the chart too

The same drill for `ingress.yaml`:

```yaml
# infrastructure/charts/kube-sandbox/templates/ingress.yaml
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "kube-sandbox.fullname" . }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | default "" | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ . }}
            pathType: Prefix
            backend:
              service:
                name: {{ include "kube-sandbox.fullname" $ }}-frontend
                port:
                  number: 3000
          {{- end }}
    {{- end }}
{{- end }}
```

Re-render. Diff is now boring.

**Evidence of success:** `helm template` includes an `Ingress` of kind
`networking.k8s.io/v1` with class `nginx`.

---

## Phase 2 — Install on the cluster, prove the render parity, retire the raw YAML

### Step 2a. Dry-run install

```bash
helm install apps infrastructure/charts/kube-sandbox \
  --namespace apps --create-namespace \
  --dry-run --debug > /tmp/install.yaml
```

Inspect: this should be near-equivalent to what `make deploy` currently
applies. **Do not run for real yet.**

### Step 2b. Tear down the raw-managed workloads

ArgoCD sees a resource it doesn't manage; if we just `helm install`, we get
duplicates. Stage the transition:

```bash
# Disable ArgoCD self-heal temporarily so it doesn't fight us.
kubectl -n argocd patch application root-application --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'

# Delete the directly-`kubectl apply`-ed resources. Let helm install them.
kubectl delete -f infrastructure/auth-service.yaml -n default --ignore-not-found
kubectl delete -f infrastructure/profile-service.yaml -n default --ignore-not-found
kubectl delete -f infrastructure/frontend.yaml -n default --ignore-not-found
kubectl delete -f infrastructure/ingress.yaml -n default --ignore-not-found
```

### Step 2c. Install via Helm

```bash
helm install apps infrastructure/charts/kube-sandbox \
  --namespace apps --create-namespace
```

Check that the apps rolled out into the **`apps` namespace**:

```bash
kubectl get deploy,svc,ingress -n apps
```

**Expected:** `auth`, `profile`, `frontend` deployments with 2 replicas
each, plus a `ClusterIP` Service and a `networking.k8s.io/v1` Ingress.

### Step 2d. Smoke-test the running app

```bash
make port-forward
make test        # should still return 200s for /api/auth/health etc.
```

**Evidence of success:** Dashboard at `http://localhost:8081` shows
both services `online`. This is the proof that step 1's render was faithful.

### Step 2e. Make Helm release name deterministic

A re-install with a different `--release-name` produces different resource
names. Pick a stable release name (use the Makefile):

```bash
# infrastructure/apps-values.yaml (new) — values for the live cluster
replicaCount: 2
namespace:
  name: apps
  create: true
```

```bash
# In Makefile, replace `make deploy` with:
helm upgrade --install apps infrastructure/charts/kube-sandbox \
  -n apps --create-namespace \
  -f infrastructure/apps-values.yaml
```

Wire this into the Makefile now (replaces the existing `make deploy`):

```makefile
# Makefile — replace the existing `deploy:` target
HELM_RELEASE ?= apps
APPS_VALUES  := infrastructure/apps-values.yaml

.PHONY: deploy
deploy: ## Install or upgrade the kube-sandbox chart
	helm upgrade --install $(HELM_RELEASE) infrastructure/charts/kube-sandbox \
	  --namespace apps --create-namespace \
	  -f $(APPS_VALUES)

.PHONY: render
render: ## Render the chart locally to /tmp/rendered.yaml (drift check)
	@helm template $(HELM_RELEASE) infrastructure/charts/kube-sandbox \
	  -f $(APPS_VALUES) > /tmp/rendered.yaml
	@echo "→ Rendered to /tmp/rendered.yaml"
```

### Step 2f. Delete the now-obsolete raw manifests

```bash
git rm infrastructure/auth-service.yaml infrastructure/profile-service.yaml \
       infrastructure/frontend.yaml infrastructure/ingress.yaml
```

ArgoCD will notice that root-app's path `infrastructure/*.yaml` (top-level
files only) no longer matches the removed files. Update the root
Application's `path` to point at the chart instead:

```yaml
# infrastructure/argocd/root-application.yaml
spec:
  source:
    repoURL: ...
    targetRevision: HEAD
    path: infrastructure/charts/kube-sandbox        # NEW
    # The directory: block goes away — ArgoCD will use Helm.
  syncPolicy:
    automated:
      selfHeal: true          # re-enable
      prune: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true   # NEW (gap G7)
```

Commit, push, watch ArgoCD sync.

**Evidence of success:** cluster state matches what Helm installs; no
`OutOfSync` in ArgoCD; the dashboard is still green.

---

## Phase 3 — GitOps hygiene: notifications, drift, and self-heal proof

### Step 3a. Install ArgoCD Notifications

The Notifications controller ships with ArgoCD in v2.9.5 but isn't enabled
by default. Enable it:

```bash
kubectl -n argocd get deploy argocd-notifications-controller
# If not present:
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.5/manifests/install.yaml
```

The install manifest includes the controller; restart the existing
Manifests from step 2 to bring it up:

```bash
kubectl -n argocd rollout restart deployment argocd-notifications-controller
```

### Step 3b. Add a local webhook receiver

For now, drop a Service + Pod into the cluster that receives ArgoCD's POST
and logs the body. This proves notifications work; later you swap to Slack
or whatever.

```yaml
# infrastructure/observability/notifications/webhook-receiver.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notify-receiver
  namespace: observability
  labels: { app: notify-receiver }
spec:
  replicas: 1
  selector: { matchLabels: { app: notify-receiver } }
  template:
    metadata: { labels: { app: notify-receiver } }
    spec:
      containers:
        - name: receiver
          image: mendhak/http-https-echo:31
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: notify-receiver
  namespace: observability
spec:
  selector: { app: notify-receiver }
  ports: [{ port: 8080, targetPort: 8080 }]
```

```bash
kubectl apply -f infrastructure/observability/notifications/webhook-receiver.yaml
make port-forward-obs
```

Add this Makefile target before the next step:

```makefile
.PHONY: port-forward-obs
port-forward-obs: ## Port-forward the notification receiver to localhost:8089
	@kubectl port-forward -n observability svc/notify-receiver 8089:8080
```

### Step 3c. Configure triggers + templates

```yaml
# infrastructure/argocd/notifications-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.webhook.local: |
    url: http://notify-receiver.observability.svc.cluster.local:8080/argocd-event
  template.app-degraded: |
    message: |
      Application {{.app.metadata.name}} is now Degraded.
      Sync: {{.app.status.sync.status}}, Health: {{.app.status.health.status}}.
      revision: {{.app.status.sync.revision}}
  template.app-out-of-sync: |
    message: |
      Application {{.app.metadata.name}} is OutOfSync.
      Diff: {{.app.status.operationState.syncResult.resources | toJson}}
  # Subscriptions are required — without these, triggers fire but never
  # route to any service. Subscriptions live in the same ConfigMap.
  subscriptions: |
    - recipients:
        - local
      triggers:
        - on-degraded
        - on-out-of-sync
  trigger.on-degraded: |
    - when: app.status.health.status == 'Degraded'
      send: [app-degraded]
  trigger.on-out-of-sync: |
    - when: app.status.sync.status == 'OutOfSync'
      send: [app-out-of-sync]
```

> **URL path caveat.** The webhook URL ends in `/argocd-event` (not
> `/argocd`) to match the path the receiver accepts. The image used in
> Step 3b (`mendhak/http-https-echo`) responds on `/` by default; if you
> switch to a different receiver, update the path or remove it from the
> URL. The receiver **does not log POST bodies by default** — to see
> what ArgoCD sent, use `--access-log` mode (pass it as an arg to the
> receiver container) or proxy to a logging sidecar.

Apply:

```bash
kubectl apply -f infrastructure/argocd/notifications-cm.yaml
```

Re-apply the trigger ConfigMap. Trigger a notification by manually
scaling a deployment:

```bash
kubectl scale deploy/$(HELM_RELEASE)-auth -n apps --replicas=99
# Watch the notification receiver logs:
kubectl logs -n observability -l app=notify-receiver -f
# (You should see an OutOfSync event arrive.)
```

**Evidence of success:** `kubectl logs -n observability -l app=notify-receiver`
shows an HTTP request line (if `--access-log` is enabled on the
receiver) — without that flag the request is silently 200'd and won't
appear in logs. As a fallback, check ArgoCD's notifier controller logs:
`kubectl logs -n argocd -l app.kubernetes.io/name=argocd-notifications-controller`
should show the webhook delivery attempt.

### Step 3d. Add a `make drift-test` target

The Makefile variable is `HELM_RELEASE` (from Step 2e). The ArgoCD
Application that owns the Helm release is named to match the chart's
`name` plus `-application` — for our setup the ArgoCD Application is
called `apps-application`. Verify the actual name in the ArgoCD UI
before patching.

```makefile
# Makefile — add to your existing variable section
ARGO_APP_NAME ?= apps-application

.PHONY: drift-test
drift-test: ## Out-of-band mutation; expect ArgoCD self-heal to revert.
	@echo "→ Confirming selfHeal is enabled on $(ARGO_APP_NAME)"
	kubectl -n argocd patch application $(ARGO_APP_NAME) --type merge \
	  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'
	@echo "→ Mutating auth replicas out-of-band"
	kubectl scale deploy/$(HELM_RELEASE)-auth -n apps --replicas=1
	@echo "→ Waiting 30s for self-heal…"
	sleep 30
	@echo "→ Replicas after self-heal:"
	kubectl get deploy/$(HELM_RELEASE)-auth -n apps
	@echo "→ If replicas == 2 (or whatever your chart says), self-heal works."
```

> **ARGO_APP_NAME caveat.** After Step 2f the ArgoCD Application owns the
> Helm chart, not individual manifest files. The Application's `metadata.name`
> is whatever `root-application.yaml` declares — currently
> `apps-application` for the dev chart. If your ArgoCD UI shows a different
> name (e.g., you renamed it during Step 2f), update `ARGO_APP_NAME` to
> match. Running with the wrong name fails silently and the drift-test
> appears to "succeed" (because nothing patches).

**Evidence of success:** `make drift-test` shows `replicas=2/2` (or whatever
your chart says) after 30s, not `1/1`.

### Step 3e. `ignoreDifferences` to silence false OutOfSync

```yaml
# infrastructure/argocd/root-application.yaml — additions
spec:
  ignoreDifferences:
    - group: networking.k8s.io
      kind: Ingress
      jsonPointers:
        # Status field is managed by the ingress controller; we
        # don't declare it in Git but ArgoCD sees it on the live object.
        - /status
    - group: ""
      kind: Service
      jsonPointers:
        # clusterIP / clusterIPs are assigned by the kube-controller-manager
        # and are immutable per Service — they will never match what's in Git.
        - /spec/clusterIP
        - /spec/clusterIPs
        # nodePort is only relevant for NodePort/LoadBalancer, but harmless to ignore.
        - /spec/ports/0/nodePort
    - group: apps/v1
      kind: Deployment
      jsonPointers:
        # metadata.generation is incremented by the API server on spec changes;
        # it's a controller-managed field.
        - /metadata/generation
        # status is fully managed by the deployment controller.
        - /status
    - group: ""
      kind: Endpoints
      jsonPointers:
        # subsets are managed by the Endpoints controller, not by us.
        - /subsets
```

> **Why these specific paths.** `Ingress.spec.rules` is user-defined
> (we own it in Git) — ignoring it would silence *real* drift.
> `Ingress.status.loadBalancer` is controller-managed — that's what we
> actually want to ignore. Same shape for Deployment: ignore `status`,
> not `spec`. The full `jsonPointers` list above is a starting point;
> ArgoCD will tell you (in the diff view) when you've missed a field.
> Iterate as new false-OutOfSync cases appear.

Push, verify ArgoCD stays `Synced` for a few sync ticks.

**Evidence of success:** ArgoCD Application detail page shows no
`OutOfSync` for the difference categories above.

### Step 3f. Add sync waves for ordered rollout

When apps grow dependencies (DB before backend before frontend), ArgoCD
respects `argocd.argoproj.io/sync-wave` annotations. Today none are needed
because all three are independent, but wire them in for the future.

In each `templates/<app>.yaml`, add the annotation:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"
```

Conventions:

| Wave | Resource | Reason |
|------|----------|--------|
| 0 | `Namespace` | Namespace must exist before namespaced resources |
| 0 | `ConfigMap`, `Secret` | Often referenced by workloads |
| 1 | (reserved for DBs / caches when added) | Dependency layer |
| 2 | Backend Deployments (`auth`, `profile`) | Independent services |
| 3 | `frontend` Deployment | May depend on backend DNS resolution at boot |
| 4 | `Ingress` | Last — refers to Service names that must exist |

**Evidence of success:** ArgoCD UI's "Sync Status" panel lists resources in
ascending wave order during a sync.

---

## Phase 4 — Image promotion via GitHub Actions

This is where GitOps becomes end-to-end. **Code → image → tag bump → synced.**

### Step 4a. Add a registry-less, tag-only pipeline

For a single-dev sandbox, you don't need GHCR. The pipeline writes a tag
into `infrastructure/apps-values.yaml` and lets you push a real image
separately (or use a stub). Concrete shape:

```yaml
# .github/workflows/build-images.yaml
name: build-and-promote
on:
  push:
    branches: [main]
    paths:
      - 'backend/**'
      - 'frontend/**'
      - 'infrastructure/charts/**'

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write        # required by docker/login-action to push to GHCR
    steps:
      - uses: actions/checkout@v4

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push auth-service
        uses: docker/build-push-action@v5
        with:
          context: ./backend/auth-service
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/kube-sandbox/auth-service:${{ github.sha }}

      - name: Build and push profile-service
        uses: docker/build-push-action@v5
        with:
          context: ./backend/profile-service
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/kube-sandbox/profile-service:${{ github.sha }}

      - name: Build and push frontend
        uses: docker/build-push-action@v5
        with:
          context: ./frontend
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/kube-sandbox/frontend:${{ github.sha }}

  promote:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write         # commit back to the repo (apps-values.yaml bump)
      pull-requests: write    # required by peter-evans/create-pull-request
    steps:
      - uses: actions/checkout@v4

      - name: Bump image tag in apps-values.yaml
        run: |
          yq -i '.image.tag = "${{ github.sha }}"' infrastructure/apps-values.yaml

      - name: Open PR
        uses: peter-evans/create-pull-request@v5
        with:
          commit-message: "promote: ${{ github.sha }}"
          title: "promote ${{ github.sha }}"
          body: |
            Automated promotion. Image tag bumped to `${{ github.sha }}`.
            Once merged, ArgoCD will roll out the new image.
```

**Why this shape:**
- The pipeline **never touches the cluster directly**. It writes to Git and
  opens a PR. The merge is the production event.
- ArgoCD (running in-cluster) detects the change via the next repo poll
  (default 3 min) or via a webhook.
- A human review on the promotion PR is the gate. **Required for any
  real deploy.**

### Step 4b. Add a PR render-and-validate check

```yaml
# .github/workflows/render-check.yaml
name: render-check
on: pull_request
  paths:
    - 'infrastructure/charts/**'
    - 'infrastructure/apps-values.yaml'
    - 'infrastructure/argocd/**'

jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install helm, kubeconform, conftest
        run: |
          curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm.sh | bash
          curl -fsSL -o /tmp/kc.tgz https://github.com/sigs.k8s.io/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz
          tar -C /usr/local/bin -xzf /tmp/kc.tgz kubeconform
          # conftest: pre-installed via OpenTofu or brew; in CI use the official install script
          curl -fsSL https://raw.githubusercontent.com/open-policy-agent/conftest/main/install.sh | sh -s -- -b /usr/local/bin

      - name: Render
        run: |
          helm template apps infrastructure/charts/kube-sandbox \
            -f infrastructure/apps-values.yaml > /tmp/rendered.yaml

      - name: kubeconform
        run: kubeconform -strict -summary /tmp/rendered.yaml

      - name: conftest
        run: conftest test /tmp/rendered.yaml -p infrastructure/policies/

      - name: Post rendered diff to PR
        run: |
          if [ "${{ github.event_name }}" == "pull_request" ]; then
            echo "Rendered manifest attached as artifact"
            # Optionally use github-script to post a comment.
          fi

      - name: Upload rendered manifest
        uses: actions/upload-artifact@v4
        with:
          name: rendered-manifest
          path: /tmp/rendered.yaml
```

### Step 4c. Add the first Rego policy

```rego
# infrastructure/policies/required.rego
package main

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.containers[0].resources.limits
  msg = sprintf("Deployment %s missing resources.limits", input.metadata.name)
}

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot
  msg = sprintf("Deployment %s missing runAsNonRoot: true", input.metadata.name)
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.image == ""
  msg = sprintf("Container in %s has empty image", input.metadata.name)
}
```

Run `conftest` locally to make sure it works:

```bash
conftest test /tmp/rendered.yaml -p infrastructure/policies/
# Should exit non-zero on the chart's current output (because we haven't
# set resources.limits in the template yet). That's actually a useful
# failure — it forces us to fix the chart before promoting.
```

**Fix the chart** so all `containers[*].resources.limits` is set in
`values.yaml` (or in the `_helpers.tpl` `resources` template). Re-render,
re-run `conftest`, expect zero failures.

**Evidence of success:** `conftest test` exits 0 against the rendered
manifest; the GitHub Actions PR check passes; the chart's Helm templates
declare `resources.limits`.

> **Bootstrap the initial image.** After the first time `apps-values.yaml`
> is bumped to a real SHA, the chart-rendered Deployments will have
> `imagePullPolicy: IfNotPresent` and will look for that exact tag. Until
> the first promotion runs end-to-end, the cluster will fail with
> `ErrImagePull` / `ImagePullBackOff`. Two safe bootstrap options:
>
> 1. **Push a placeholder.** Before merging the chart's first install,
>    build any image and tag it `v0.0.0` locally, then push to GHCR:
>    `docker buildx build --tag ghcr.io/<owner>/kube-sandbox/auth-service:v0.0.0 --push ./backend/auth-service`.
>    Repeat for the other two services. The chart renders this tag by
>    default and pods will start.
> 2. **Add `imagePullPolicy: Never` for the `v0.0.0` default** (chart-level
>    conditional: `{{ if eq .Values.image.tag "v0.0.0" }}imagePullPolicy: Never{{ end }}`).
>    Once you promote past `v0.0.0` the policy reverts to `IfNotPresent`.
>    **Use this option only for a sandbox where no image registry exists yet.**
>
> Without one of these, the first `make deploy` will land successfully
> but pods will be stuck in `ImagePullBackOff` until the first promotion
> PR merges — which itself requires the cluster to be healthy. Chicken
> and egg.

### Step 4d. Branch protection

In GitHub repo settings → Branches → `main`:
- Require a pull request before merging.
- Require status checks: `render-check`.
- (Optional) Require approval: 1 reviewer.

**Evidence of success:** attempting to push directly to `main` is rejected;
only PRs land changes.

### Step 4e. End-to-end smoke test

The actual GitOps loop:

1. Make a small code change to `backend/auth-service/src/health.controller.ts`
   (e.g., add a new field).
2. Open a PR.
3. **Expected:** `render-check` runs, validates, posts artifact.
4. Merge the PR.
5. **Expected:** `build-and-promote` runs, builds images, opens
   a "promote XXXXXXX" PR with `apps-values.yaml` updated.
6. Review and merge the promotion PR.
7. **Expected:** within ~3 minutes, ArgoCD goes `OutOfSync → Synced → Healthy`,
   and the deployment shows the new image.

**Evidence of success:** `kubectl rollout history deploy/$(HELM_RELEASE)-auth -n apps` shows
two revisions; the second has the SHA tag from step 2.

---

## Phase 5 prep (do only after 1–4 are stable)

Listed but not executed here. Per your scope decision:

- Hardening: `readOnlyRootFilesystem`, `seccompProfile`, PodSecurityAdmission `restricted` on `apps`.
- PodDisruptionBudgets.
- HPA `min 2 / max 5 / CPU 70%` per workload.
- Sealed Secrets or SOPS for any real secret.
- cert-manager + `mkcert` for TLS on `localhost`.

Each of these is at most a half-day of work once Phases 1–4 are stable.

---

## Recap — the 4 numbered phases

| Phase | What it proves | Time (rough) |
|-------|---------------|--------------|
| 1. Helm-render parity | YAML you ship equals YAML cluster sees | 1 day |
| 2. Helm install + ArgoCD handoff | Helm-installed cluster passes dashboard test, raw manifests deleted | 0.5 day |
| 3. GitOps hygiene | Drift heals; notifications fire; ignoreDifferences silences controller-managed fields | 0.5 day |
| 4. Image promotion end-to-end | Code change → image → tag in Git → rolled cluster, all without human editing tags | 1–2 days |

After Phase 4, you've built the platform. The Phase 5 hardening is what makes it
production-shaped.

---

## Things to NOT do while you execute this

- Don't add new apps. Stay on the existing 3.
- Don't change the Dockerfile structure; Phase 4 builds images as-is.
- Don't introduce Sealed Secrets yet. You have no secrets that need them.
- Don't move to multi-env overlays yet. One `dev` overlay, no `apps-values-prod.yaml`.
- Don't add cert-manager. The port-forward flow covers local testing.
- Don't add HPA. Won't fire on a single-node cluster; document as Phase 5.
- Don't `kubectl apply` anything to the cluster after phase 2 finishes. If
  you do, the next sync will revert it (that's the point).

---

## What you should expect to fail

- **First `conftest` run** — chart's container templates will fail the
  `resources.limits` check. Fix by tightening `_helpers.tpl` or by adding
  defaults in `values.yaml`.
- **First promotion PR** — the build job needs `permissions: write` to push
  to GHCR. If you forget the workflow permission, builds fail with cryptic
  auth errors.
- **First ArgoCD `OutOfSync` after a Controller touch** — your
  `ignoreDifferences` list (3e) won't cover everything. Iterate.
- **ImagePullBackOff** — after switching from `:local` to `ghcr.io/...` and
  no image has been published yet. To recover, push a dummy image to
  GHCR or revert to `:local` for one release.

---

## Definition of done for "industry standard"

Check yourself when you finish Phase 4:

- [ ] No one runs `kubectl apply` to change workloads.
- [ ] A code change reaches the cluster without any human touching a YAML tag.
- [ ] The PR CI renders the manifest and shows the diff that ArgoCD will apply.
- [ ] ArgoCD self-heals an out-of-band mutation within minutes.
- [ ] ArgoCD sends a notification when sync or health changes.
- [ ] All containers have `resources.limits` (Rego-enforced).
- [ ] All Deployments run as non-root (Rego-enforced).
- [ ] All resources live in the `apps` namespace (or `observability`/`argocd`/`ingress-nginx`).
- [ ] Render and promotion both run through GitHub Actions.
- [ ] Branch protection prevents direct pushes to `main`.

If all ten are checked, the platform is industry-standard for a sandbox and
Phase 5 hardening is genuine incremental improvement, not cargo-culting.

---

## Guardrails — what this plan explicitly excludes

Phase 1–4 is the platform. These are app-level work that pulls attention
away; deferred until the platform is stable.

- ❌ Build a real auth flow with JWT, bcrypt, DTOs, validation pipes. The
  current `/health`-only endpoints are correct for the platform focus.
- ❌ Add `@opentelemetry/sdk-node` to the apps, wire traces from Nest/Next
  to the collector. The collector already has receivers; wiring apps is
  app-code work, not GitOps work. If you want traces, do it once, in one
  branch, after Phases 1–4 are green.
- ❌ Add a real `LoginForm` page, profile editor, server actions, etc. Same
  reason.
- ❌ Full Playwright suite, Jest e2e, `supertest`. The README's smoke
  tests via `curl` are sufficient evidence the platform is working.
- ❌ Convert Dockerfiles to multi-arch `--platform linux/amd64,linux/arm64`.
  Docker Desktop handles this transparently; the build-time flag is a CI
  concern, not a GitOps concern.
- ❌ Argo Rollouts, Argo Workflows, Argo Events. They're separate products
  and only relevant when the deployment story needs them.

---

## Operational / DX items deferred

Not GitOps primitives — platform comfort features for a sandbox. Pull
them in *after* Phases 1–5 are stable.

- [ ] **`Makefile`** — add `live-logs:` that streams logs grouped by pod, not
  by deployment (the current `make logs` tails 3 deployments in parallel and
  the output intermingles badly).
- [ ] **`Makefile`** — add `render-diff:` that compares `/tmp/rendered.yaml`
  against the last committed render.
- [ ] **`Tiltfile`** (new, in root) — live-reload of dev workflows; in-cluster
  live coding. Skip until the platform is settled.
- [ ] **`.editorconfig`**, **`.github/dependabot.yml`**, **`.pre-commit-config.yaml`** —
  repo hygiene.
- [ ] **`LICENSE`** file — repo hygiene. README's "MIT" footer mentions it
  but the file doesn't exist.

---

## Glossary

- **GitOps** — Kubernetes manifests live in Git; an in-cluster agent
  (ArgoCD here) reconciles the cluster to whatever Git says.
- **App-of-Apps** — an ArgoCD Application whose only job is to create
  other Applications. The repo currently uses two hand-written Applications,
  no App-of-Apps App.
- **ApplicationSet** — ArgoCD controller that generates multiple Applications
  from one template + a generator (list, git, cluster).
- **Sync wave** — `argocd.argoproj.io/sync-wave` annotation. ArgoCD syncs
  resources in ascending wave order; use for dependency sequencing.
- **ServerSideApply** — `syncOptions: [ServerSideApply=true]`. ArgoCD uses
  the K8s API's server-side apply, which fixes ownership conflicts with
  other controllers.
- **Helm/Kustomize/raw** — three ways to render manifests. See D1.
- **PodSecurityAdmission** — K8s built-in admission controller that
  enforces `privileged`/`baseline`/`restricted` policies per namespace.
  Activated by a namespace label; no operator required.
- **SOPS / Sealed Secrets / External Secrets** — three secret strategies.
  See D3.
- **Rego / conftest** — Rego is the policy language; conftest runs Rego
  policies against rendered manifests in CI. Used in Phase 4.
- **Drift** — the cluster state diverges from Git. Self-heal reverts it;
  ArgoCD flags it as `OutOfSync`.
