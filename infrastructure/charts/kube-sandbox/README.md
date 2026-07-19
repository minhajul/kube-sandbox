# kube-sandbox Helm chart

Renders Deployments, Services, and an Ingress for the three apps (auth,
profile, frontend) using per-app values under `apps.<name>`.

## Install locally (without ArgoCD)

```bash
helm template apps . --namespace default    # render only, no install
helm install apps . --namespace default --create-namespace   # real install
```

## Per-app values

Each app follows the same schema. To change a setting, edit `values.yaml`:

```yaml
apps:
  auth:
    port: 3001
    replicaCount: 2
    image:
      repository: auth-service
      tag: ""              # ← filled by promote.yaml
      pullPolicy: IfNotPresent
    resources:
      requests: { cpu: 50m,  memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }
```

## Image promotion

The chart's `apps.<svc>.image.tag` is intentionally **empty**. Two paths
to fill it:

1. **CI (production path):** merge a PR opened by `promote.yaml`.
2. **Local dev:** `make push-ghcr` pushes a `0.0.0` tag; manually set
   `apps.<svc>.image.tag: "0.0.0"` in `values.yaml` for the first deploy.

## Rendered service names

| App | Service (cluster-internal) |
| --- | --- |
| auth     | `apps-kube-sandbox-auth.default.svc.cluster.local:3001` |
| profile  | `apps-kube-sandbox-profile.default.svc.cluster.local:3002` |
| frontend | `apps-kube-sandbox-frontend.default.svc.cluster.local:3000` |

Format: `<release>-<chart>-<app>.<ns>.svc.cluster.local`.
`release=apps`, `chart=kube-sandbox`, app names = `auth`/`profile`/`frontend`.

## Adding a 4th app

1. Add an entry under `apps:` in `values.yaml` (copy an existing block).
2. Create `templates/<app>-deployment.yaml` mirroring one of the three existing files.
3. Wire any new env vars via `templates/_helpers.tpl::serviceURL`.
4. Run `make render` — should still produce all-green kubeconform output.
5. Push; CI builds the image; promote auto-bumps the tag.
