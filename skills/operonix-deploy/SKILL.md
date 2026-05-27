# Skill: operonix-deploy

## Trigger

Fire when the user asks to:
- generate Kubernetes manifests for a project
- scaffold a project for deployment
- `/opera-base:operonix-deploy <project>`

---

## Runtime inputs

Collect all of these before generating any file. Ask as a grouped checklist in one shot.

| Input | Question |
|-------|----------|
| `project_name` | Name of the project (used as namespace, resource names, Vault path) |
| `stack` | Project stack — auto-detect from project root; confirm with user (`nodejs`, `go`, `java`, `python`) |
| `services` | Services and ports, e.g. `frontend:3000, api:8080` |
| `subdomain` | Subdomain for APISIX route → `<subdomain>.novlok.co` |
| `image_registry` | Image path, e.g. `registry.gitlab.com/<group>/<project>/app` |
| `gitlab_app_repo` | Application GitLab repo URL |
| `gitlab_helm_repo` | Helm chart GitLab repo URL (separate repo) |
| `gitlab_argocd_repo` | ArgoCD GitLab repo URL (to fetch Application CR template) |
| `gitlab_access` | GitLab access for ArgoCD Secret — SSH key or HTTPS token |
| `vault_address` | Vault internal address, e.g. `https://vault.novlok.co` |
| `otel_endpoint` | OpenTelemetry collector endpoint (protocol varies per project; Node.js default: `otlp/http`) |

---

## Stack detection (auto, before asking)

| File in project root | Stack |
|---------------------|-------|
| `package.json` | `nodejs` |
| `go.mod` | `go` |
| `pom.xml` or `build.gradle` | `java` |
| `requirements.txt` or `pyproject.toml` | `python` |

Confirm the detected stack with the user before proceeding.

---

## Methodology

Execute steps in order. Steps 1 and 2 are read-only scans that inform later steps.

### Step 1 — Scan for secrets

Scan: `.env`, `application.yml`, `application.properties`, `application-*.yml`, source files.

- If secrets found → set `has_secrets = true`; list them for the user
- If none → `has_secrets = false`; note in summary

### Step 2 — Check for existing ServiceMonitor

Look in `kubernetes/prometheus/` for any `ServiceMonitor` CR.

- Found → `has_monitor = true`
- Not found → `has_monitor = false`; will generate in Step 7

---

### Step 3 — `kubernetes/app/`

For each service in `services`:

**Deployment**
- `image`: `<image_registry>:<tag>` — use `latest` as placeholder; `update-k8s-tag` CI job will update this
- `namespace`: `<project_name>`
- `labels`: `app: <service>`
- Resource requests/limits: sensible defaults (128Mi/256Mi, 100m/250m)

**ConfigMap**
- Non-sensitive config only
- Mount as env vars or volume depending on stack convention

**Service**
- Type: `ClusterIP`
- Port and `targetPort` from runtime input

**Secret**
- Only if `has_secrets = false`; otherwise omit — Vault handles it

---

### Step 4 — `kubernetes/vault/` and `kubernetes/crossplane/vault/`

Skip if `has_secrets = false`.

`kubernetes/vault/`:
```
VaultConnection  → address from runtime input (vault_address)
VaultAuth        → method: kubernetes, mount: kubernetes, role: <project>, sa: <project>-sa
VaultStaticSecret → mount: kv, type: kv-v2, path: novlok/<project>, destination: <project>-secrets
```

`kubernetes/crossplane/vault/`:
- Crossplane CRs for mount path, user, and policy provisioning
- Mount path: `kv/novlok/<project>/`
- Auth method: Kubernetes

Use the CR templates from `references/rules.md` Rule 2.
Verify API versions against cluster: `kubectl get crd | grep hashicorp`

---

### Step 5 — `kubernetes/apisix/`

One `ApisixRoute` CR with one `http` entry per service.
One `ApisixUpstream` CR per service.

- Domain: `<subdomain>.novlok.co`
- No plugins unless explicitly requested
- `resolveGranularity: service`
- Service names: `<service>-svc`

Use the CR templates from `references/rules.md` Rule 5.

---

### Step 6 — `kubernetes/crossplane/cloudflare/`

One `dns.cloudflare.crossplane.io/v1alpha1 Records` CR:

- `zoneName: novlok.co`
- `proxied: true`, `type: A`
- `loadbalancerRef: name: apisix-gateway, namespace: apisix`
- `providerConfigRef: name: cloudflare-config`

Use the CR template from `references/rules.md` Rule 6.

---

### Step 7 — `kubernetes/prometheus/`

Skip if `has_monitor = true`.

Generate `ServiceMonitor` targeting `/metrics` on each service port.
No special labels required — selector: `app: <service>`.

Also generate OTel exporter config:
- Endpoint: `otel_endpoint` from runtime input
- Protocol: `otlp/http` for Node.js; ask for other stacks

Use the CR template from `references/rules.md` Rule 3.

---

### Step 8 — `kubernetes/alertmanager/`

Basic `PrometheusRule` CR with alerts:
- `PodCrashLooping` — pod restarts > 3 in 5 min
- `HighCPU` — CPU > 80% for 10 min
- `HighMemory` — memory > 85% for 10 min

---

### Step 9 — `kubernetes/cilium/`

One `CiliumNetworkPolicy` per project (applies to all pods in namespace):

- Allow ingress from `apisix` namespace (no mTLS)
- Allow intra-namespace traffic with `authentication.mode: required`

Use the CR template from `references/rules.md` Rule 7.

---

### Step 10 — ArgoCD resources

1. Fetch the ArgoCD Application CR template:
   - Clone/read the ArgoCD GitLab repo (`gitlab_argocd_repo`)
   - Find an existing multi-source `Application` CR
   - Use it as the base; substitute `project_name`, repo URLs, namespace

2. Generate `argocd/application-<project>.yaml`:
   - Source 1: Helm chart repo (`gitlab_helm_repo`), branch = current env
   - Source 2: App repo (`gitlab_app_repo`), path = `values.yaml`, branch = current env
   - Destination: `namespace: <project_name>`, `server: https://kubernetes.default.svc`

3. Generate `argocd/secret-<project>-repo.yaml`:
   - Type: `repository`
   - GitLab access from `gitlab_access`
   - Namespace: `argocd`

---

### Step 11 — `Dockerfile`

Generate based on detected `stack`. Use the canonical patterns from `references/rules.md` Rule 9:

| Stack | Builder image | Runtime image |
|-------|--------------|---------------|
| `nodejs` | `node:24-alpine` | `node:24-alpine` (standalone runner) |
| `go` | `golang:1.26.3-alpine` | `scratch` |
| `java` | `maven:3.9-eclipse-temurin-21` | `eclipse-temurin:21-jre-alpine` |
| `python` | `python:3.12-slim` | `python:3.12-slim` |

For Node.js projects with Prisma: include `openssl` apk package and copy Prisma engine layers.

---

### Step 12 — `.gitlab-ci.yml`

Generate based on `stack`. Use `references/rules.md` Rule 8 as the base template.

Adapt per stack:
- `BASE_IMAGE_NODE` / build image variable
- Lint and test jobs (see stack table in Rule 8)
- `APP_IMAGE`: `<image_registry>`
- `workflow.rules`: skip `kubernetes/**/*` changes

The `update-k8s-tag` job patches `values.yaml` in the current branch of the app repo and pushes back.

---

### Step 13 — `version.yaml`

If not present in the project root, generate it:

```yaml
version: "0.1.0"
```

---

## Output summary

After all steps, report a table:

| Directory / File | Action | Notes |
|-----------------|--------|-------|
| `kubernetes/app/` | Created | N deployments, N services, N configmaps |
| `kubernetes/vault/` | Created / Skipped | Secrets found: yes/no |
| `kubernetes/apisix/` | Created | Route + N upstreams |
| `kubernetes/crossplane/cloudflare/` | Created | — |
| `kubernetes/prometheus/` | Created / Already existed | — |
| `kubernetes/alertmanager/` | Created | — |
| `kubernetes/cilium/` | Created | — |
| `argocd/` | Created | Application + Secret |
| `Dockerfile` | Created | Stack: <stack> |
| `.gitlab-ci.yml` | Created | Stack: <stack> |
| `version.yaml` | Created / Already existed | — |

List any secrets moved to Vault.
Flag any item that requires manual follow-up (e.g., ArgoCD CR template not found in repo).
