---
name: operonix-deploy
description: Scaffolds Kubernetes manifests, Dockerfile and GitLab CI pipeline for an Operonix project. Triggers on "generate manifests", "scaffold project", "deploy project", "/opera-base:operonix-deploy". Generates manifests as Helm chart templates or Kustomize base+overlays from runtime inputs. Does NOT apply anything to the cluster.
---

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
| `output_format` | Output format: **`helm`** (Helm chart templates) or **`kustomize`** (base + overlays) |
| `stack` | Project stack — auto-detect from project root; confirm with user (`nodejs`, `go`, `java`, `python`) |
| `services` | Services and ports, e.g. `frontend:3000, api:8080` |
| `subdomain` | Subdomain for APISIX route → `<subdomain>.novlok.co` |
| `image_registry` | Image path, e.g. `registry.gitlab.com/<group>/<project>/app` |
| `gitlab_app_repo` | Application GitLab repo URL |
| `gitlab_helm_repo` | Helm chart GitLab repo URL (separate repo) — **only if `output_format = helm`** |
| `gitlab_argocd_repo` | ArgoCD GitLab repo URL (to fetch Application CR template) |
| `gitlab_access` | GitLab access for ArgoCD Secret — SSH key or HTTPS token |
| `vault_address` | Vault internal address, e.g. `https://vault.novlok.co` |
| `vault_mount_mode` | *(ask only if `has_secrets = true` after Step 1)* Vault KV mount: **`new`** (create a dedicated mount for this project) or **`default`** (reuse an existing mount) |
| `vault_mount_path` | *(ask only if `vault_mount_mode = default`)* Existing mount path, e.g. `kv/novlok` |
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

> **Format rule:** after Step 2, all manifest files are generated according to `output_format`.  
> Full directory structures and wrapping conventions are defined in `references/rules.md` Rule 11.  
> Use the table below as a quick reference:
>
> | | `helm` | `kustomize` |
> |-|--------|-------------|
> | Root | `helm/templates/<area>/` | `kubernetes/base/<area>/` |
> | Variable fields | `{{ .Values.<key> }}` | hardcoded (env diff via overlays) |
> | Env differentiation | `values.yaml` per branch in app repo | `kubernetes/overlays/<env>/` |
> | ArgoCD source | chart repo + values from app repo | `kubernetes/overlays/<env>` in app repo |
> | CI image tag patch | `yq` on `values.yaml` | `kustomize edit set image` on overlay |

### Step 1 — Scan and classify secrets

Scan: `.env`, `application.yml`, `application.properties`, `application-*.yml`, source files.

For each key-value pair found, classify as **confidential** or **non-sensitive**:

| → Vault (`confidential_secrets`) | → ConfigMap (`plain_config`) |
|----------------------------------|------------------------------|
| API keys, access/refresh tokens, OAuth secrets | Public URLs, hostnames, ports |
| Passwords, database credentials | Feature flags, log levels, timeouts |
| Private keys, encryption/signing keys, certificates | Environment names, non-secret identifiers |
| Webhook secrets, JWT secrets | Anything safe to store in plain text in Git |
| Any high-entropy random-looking string | — |

After classifying, **present both lists to the user for confirmation** and allow reclassification before proceeding.

- `confidential_secrets` non-empty → `has_secrets = true`; ask `vault_mount_mode` (and `vault_mount_path` if `default`)
- `confidential_secrets` empty → `has_secrets = false`; note in summary

### Step 2 — Check for existing ServiceMonitor

- `helm`: look in `helm/templates/prometheus/` for any `ServiceMonitor` template
- `kustomize`: look in `kubernetes/base/prometheus/` for any `ServiceMonitor` manifest

- Found → `has_monitor = true`
- Not found → `has_monitor = false`; will generate in Step 7

---

### Step 3 — App manifests (Deployment, Service, ConfigMap)

For each service in `services`:

**Deployment**
- `image`: `<image_registry>:<tag>` (helm: `{{ .Values.image.repository }}:{{ .Values.image.tag }}`) — use `latest` as placeholder
- `namespace`: `<project_name>`
- `labels`: `app: <service>`
- Resource requests/limits: sensible defaults — helm: `{{ .Values.resources.* }}`; kustomize: hardcoded (128Mi/256Mi, 100m/250m)
- Security context: apply the template from `references/rules.md` Rule 10 to every Deployment. Adjust `runAsUser` to match the Dockerfile `USER` directive if different from 1001.

**ConfigMap**
- Include `plain_config` values from Step 1 plus any other non-sensitive config
- Mount as env vars or volume depending on stack convention

**Service**
- Type: `ClusterIP`
- Port and `targetPort` from runtime input

**Secret**
- Only if `has_secrets = false`; otherwise omit — Vault handles it

**Kustomize only:** generate `kubernetes/base/app/kustomization.yaml` listing all files in this directory.

---

### Step 4 — Vault manifests

Skip if `has_secrets = false`.

**Resolve mount path** from `vault_mount_mode`:
- `vault_mount_mode = new` → mount path: `kv/novlok/<project>/`; **generate Crossplane Vault mount CR** for this project
- `vault_mount_mode = default` → mount path: `<vault_mount_path>/<project>/`; **skip Crossplane Vault mount CR** (mount already exists)

Generate `VaultConnection`, `VaultAuth`, `VaultStaticSecret` CRs covering only `confidential_secrets` from Step 1:
- `vault_address` from runtime input (helm: `{{ .Values.vault.address }}`)
- Auth method: kubernetes, role: `<project>`, service account: `<project>-sa`
- `VaultStaticSecret.spec.mount`: KV engine name from the resolved mount path (e.g. `kv`)
- `VaultStaticSecret.spec.path`: path within the mount (e.g. `novlok/<project>` or `<vault_mount_path>/<project>`)

Also generate Crossplane Vault user and policy CRs (always, regardless of mount mode).

Output path:
- `helm`: `helm/templates/vault/`
- `kustomize`: `kubernetes/base/vault/` + `kustomization.yaml`

Use the CR templates from `references/rules.md` Rule 2.
Verify API versions against cluster: `kubectl get crd | grep hashicorp`

---

### Step 5 — APISIX manifests

One `ApisixRoute` CR with one `http` entry per service.
One `ApisixUpstream` CR per service.

- Domain: `<subdomain>.novlok.co` (helm: `{{ .Values.apisix.subdomain }}.novlok.co`)
- No plugins unless explicitly requested
- `resolveGranularity: service`
- Service names: `<service>-svc`

Output path:
- `helm`: `helm/templates/apisix/`
- `kustomize`: `kubernetes/base/apisix/` + `kustomization.yaml`

Use the CR templates from `references/rules.md` Rule 5.

---

### Step 6 — Cloudflare DNS manifest

One `dns.cloudflare.crossplane.io/v1alpha1 Records` CR (plural — this is the correct kind):

- `zoneName: novlok.co`
- `proxied: true`, `type: A`
- `loadbalancerRef: name: apisix-gateway, namespace: apisix`
- `providerConfigRef: name: cloudflare-config`

Output path:
- `helm`: `helm/templates/crossplane/cloudflare/`
- `kustomize`: `kubernetes/base/crossplane/cloudflare/` + `kustomization.yaml`

Use the CR template from `references/rules.md` Rule 6.

---

### Step 7 — Prometheus / Observability manifests

**ServiceMonitor** — skip if `has_monitor = true` or `prometheus.serviceMonitor.enable = false`.

Generate `ServiceMonitor` targeting `/metrics` on each service port.
No special labels required — selector: `app: <service>`.
Helm: wrap the whole resource in `{{- if .Values.prometheus.serviceMonitor.enable }}`.

**OTel Instrumentation CR** — skip if `otel.autoinstrumentation.enable = false`.

Generate the `opentelemetry.io/v1alpha1 Instrumentation` CR:
- Endpoint: `otel_endpoint` from runtime input (helm: `{{ .Values.otel.endpoint }}`)
- Include **only** the language block matching the project stack; remove the others
- Helm: wrap in `{{- if .Values.otel.autoinstrumentation.enable }}`

Add the stack-specific auto-injection annotation to every **Deployment** (from Step 3):
- Helm: `instrumentation.opentelemetry.io/inject-{{ .Values.stack }}: "true"` inside `{{- if .Values.otel.autoinstrumentation.enable }}`
- Kustomize: hardcode the annotation for the detected stack

Use the CR templates from `references/rules.md` Rule 3b.

Output path — ServiceMonitor:
- `helm`: `helm/templates/prometheus/`
- `kustomize`: `kubernetes/base/prometheus/` + `kustomization.yaml`

Output path — Instrumentation CR:
- `helm`: `helm/templates/otel/`
- `kustomize`: `kubernetes/base/otel/` + `kustomization.yaml`

> Prerequisite: OpenTelemetry Operator must be running. Flag in output summary if cluster state is unknown.

---

### Step 8 — Alertmanager manifests

Skip if `prometheus.prometheusRules.enable = false`.

Basic `PrometheusRule` CR with alerts:
- `PodCrashLooping` — pod restarts > 3 in 5 min
- `HighCPU` — CPU > 80% for 10 min
- `HighMemory` — memory > 85% for 10 min

Helm: wrap the whole resource in `{{- if .Values.prometheus.prometheusRules.enable }}`.

Output path:
- `helm`: `helm/templates/alertmanager/`
- `kustomize`: `kubernetes/base/alertmanager/` + `kustomization.yaml`

---

### Step 8b — Autoscaling (HPA or KEDA)

**Always generate.** Do not skip and do not ask the user to choose the type — it is controlled by `autoscaling.type` in `values.yaml` (default: `hpa`). The `autoscaling.enabled` flag in `values.yaml` gates whether the autoscaler runs at runtime, but the manifest files are always written.

Generate one file per service containing **both** HPA and KEDA templates, each wrapped in the appropriate conditional:

```yaml
{{- if eq .Values.autoscaling.type "hpa" }}
# HorizontalPodAutoscaler manifest
{{- else if eq .Values.autoscaling.type "keda" }}
# ScaledObject manifest
{{- end }}
```

Both templates use `autoscaling.minReplicas`, `autoscaling.maxReplicas`, `autoscaling.cpu.targetUtilization`, `autoscaling.memory.targetUtilization` from values.

Kustomize: hardcode both templates in the same file separated by `---`; use comments to mark which block corresponds to HPA and which to KEDA — the operator choice is made by removing or commenting the unused block.

Output path:
- `helm`: `helm/templates/autoscaling/`
- `kustomize`: `kubernetes/base/autoscaling/` + `kustomization.yaml`

Use CR templates from `references/rules.md` Rule 12.

> Note: `replicaCount` acts only as the initial replica count when autoscaling is enabled.
> Flag prerequisites in the output summary: metrics-server for HPA, KEDA operator for KEDA.

---

### Step 9 — Cilium network policy

One `CiliumNetworkPolicy` per project (applies to all pods in namespace):

- Allow ingress from `apisix` namespace (no mTLS — external entry point)
- Allow intra-namespace traffic (ingress) with `authentication.mode: required`
- Allow intra-namespace traffic (egress) with `authentication.mode: required` — required for full mTLS
- Allow egress to kube-dns (port 53/UDP)

Output path:
- `helm`: `helm/templates/cilium/`
- `kustomize`: `kubernetes/base/cilium/` + `kustomization.yaml`

Use the CR template from `references/rules.md` Rule 7.

> mTLS requires Cilium deployed with `authentication.mutual.spire.enabled: true`. Note this prerequisite in the output summary if the cluster state is unknown.

---

### Step 10 — Format wrapping files

Generate the format-specific scaffold files that wrap all manifests produced in Steps 3–9.

**If `output_format = helm`:**

1. Run `helm create <project>` inside `helm/` to scaffold the base chart structure.
2. Delete the generic templates that helm create produces — they will be replaced by our custom CRs:
   ```
   helm/<project>/templates/deployment.yaml
   helm/<project>/templates/service.yaml
   helm/<project>/templates/serviceaccount.yaml
   helm/<project>/templates/ingress.yaml
   helm/<project>/templates/hpa.yaml
   helm/<project>/templates/NOTES.txt
   helm/<project>/templates/tests/
   ```
3. Keep (and customise):
   - `helm/<project>/Chart.yaml` — update `description`, set `version: 0.1.0`, `appVersion: latest`
   - `helm/<project>/templates/_helpers.tpl` — already generated by helm create; extend with project-specific helpers if needed
   - `helm/<project>/.helmignore`
4. Replace `helm/<project>/values.yaml` with the base schema from `references/rules.md` Rule 11.
5. Generate env-specific values files alongside `values.yaml` in the app repo root:
   - `values-dev.yaml` — dev overrides (replicas: 1, lower resources)
   - `values-qua.yaml` — qua overrides (replicas: 1, lower resources)
   - `values-prd.yaml` — prd overrides (replicas: 2, higher resources)
   Use the schemas from `references/rules.md` Rule 11.
6. Generate `helm/<project>/templates/namespace.yaml` and `helm/<project>/templates/serviceaccount.yaml` (ServiceAccount `<project>-sa`).

**If `output_format = kustomize`:**

1. `kubernetes/base/kustomization.yaml` — lists every resource file across all sub-directories
2. `kubernetes/base/namespace.yaml` — Namespace CR
3. `kubernetes/base/serviceaccount.yaml` — ServiceAccount `<project>-sa`
4. Overlays for each environment (dev, qua, prd) — see structure in `references/rules.md` Rule 11
5. Each overlay includes a `patches/replicas.yaml`: dev=1, qua=1, prd=2

---

### Step 11 — ArgoCD resources

1. Fetch the ArgoCD Application CR template from `gitlab_argocd_repo` (find existing multi-source `Application` CR; use as base).

2. Generate `argocd/application-<project>.yaml` — source depends on `output_format`:

   **`helm`:**
   - Source 1: Helm chart repo (`gitlab_helm_repo`), branch = current env
   - Source 2: App repo (`gitlab_app_repo`), ref = `values`, branch = current env
   - `helm.valueFiles`: `["$values/values.yaml", "$values/values-<env>.yaml"]` — both base and env-specific file

   **`kustomize`:**
   - Single source: App repo (`gitlab_app_repo`), path = `kubernetes/overlays/<env>`, branch = current env
   - `gitlab_helm_repo` not used

   Destination: `namespace: <project_name>`, `server: https://kubernetes.default.svc`

3. Generate `argocd/secret-<project>-repo.yaml`:
   - Type: `repository`, GitLab access from `gitlab_access`, namespace: `argocd`

---

### Step 12 — `Dockerfile`

Generate based on detected `stack`. Use the canonical patterns from `references/rules.md` Rule 9:

| Stack | Builder image | Runtime image |
|-------|--------------|---------------|
| `react` | `node:24-alpine` | `nginxinc/nginx-unprivileged:alpine3.23-otel` |
| `nextjs` | `node:24-alpine` | `node:24-alpine` (standalone runner) |
| `go` | `golang:1.26.3-alpine` | `scratch` |
| `java` | `maven:3.9-eclipse-temurin-21` | `eclipse-temurin:21-jre-alpine` |
| `python` | `python:3.12-slim` | `python:3.12-slim` |

**React sub-stack detection** (auto, before asking):

| Condition | Sub-stack |
|-----------|-----------|
| `package.json` has `"next"` in dependencies | `nextjs` |
| `package.json` has `"react"` + (`vite.config.*` present OR `"vite"` in devDependencies), no `"next"` | `react` |

**Keycloak detection** (`has_keycloak`): scan `package.json` dependencies and devDependencies for any of: `keycloak-js`, `@react-keycloak/web`, `@react-keycloak/native`. Also scan source files for `KEYCLOAK_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID` appearing as literal placeholder strings or as `VITE_KEYCLOAK_*` env var references — either pattern triggers `has_keycloak = true`.

**Dockerfile path for React projects:** always generate as `docker-build/Dockerfile` (not at project root). Use the canonical pattern from `references/rules.md` Rule 9.

If `stack = react` and `has_keycloak = true`:
- Add placeholder `ENV` directives in the builder stage (`VITE_KEYCLOAK_URL="KEYCLOAK_URL"`, etc.) so Vite bakes the literal strings into the bundle
- Generate `docker-build/entrypoint.sh` (see Rule 9) — replaces placeholders with real env var values at container startup via `sed`, then renders `nginx.conf` from template via `envsubst`
- Use `COPY --chmod=755 docker-build/entrypoint.sh /entrypoint.sh` in the Dockerfile and set `ENTRYPOINT ["/entrypoint.sh"]`

For Next.js projects with Prisma: include `openssl` apk package and copy Prisma engine layers.

---

### Step 13 — `.gitlab-ci.yml`

Generate based on `stack`. Use `references/rules.md` Rule 8 as the base template.

Adapt per stack:
- `BASE_IMAGE_NODE` / build image variable
- Lint and test jobs (see stack table in Rule 8)
- `APP_IMAGE`: `<image_registry>`
- `workflow.rules`: skip changes to manifests dirs

The `build:app` job **must** use `moby/buildkit:rootless` — use the exact template from `references/rules.md` Rule 8 (`build:app` section). Do not use `docker:dind`, `docker:27`, any `docker:*` image, `docker build`, or any Docker-in-Docker approach.

When `stack = react`, set `--local dockerfile=docker-build` in the `buildctl-daemonless.sh` command (Dockerfile is at `docker-build/Dockerfile`, not project root). Build context stays `--local context=.`. See Rule 8 React variant.

CI image tag patch job (`update-k8s-tag`) — depends on `output_format`:
- `helm`: `yq e '.image.tag = "<tag>"' -i values-<env>.yaml` on app repo branch (`dev` → `values-dev.yaml`, etc.)
- `kustomize`: `kustomize edit set image <registry>=<registry>:<tag>` on `kubernetes/overlays/<env>/kustomization.yaml`

The `git commit` line in this job **must** use YAML single-quote wrapping to prevent validators from interpreting `ci:` as a YAML mapping key:
```yaml
    - 'git commit -m "ci: update k8s tag to ${IMAGE_TAG}"'
```

---

### Step 14 — `version.yaml`

If not present in the project root, generate it:

```yaml
version: "0.1.0"
```

---

## Output summary

After all steps, report a table. Adapt paths to `output_format`.

**If `output_format = helm`:**

| File / Directory | Action | Notes |
|-----------------|--------|-------|
| `helm/Chart.yaml` | Created | — |
| `helm/values.yaml` | Created | Base defaults (all envs) |
| `values-dev.yaml` | Created | Dev overrides (app repo root) |
| `values-qua.yaml` | Created | QA overrides (app repo root) |
| `values-prd.yaml` | Created | Prod overrides, replicas: 2 (app repo root) |
| `helm/templates/_helpers.tpl` | Created | — |
| `helm/templates/app/` | Created | N deployments (securityContext), N services, N configmaps |
| `helm/templates/vault/` | Created / Skipped | Secrets found: yes/no |
| `helm/templates/apisix/` | Created | Route + N upstreams |
| `helm/templates/crossplane/cloudflare/` | Created | kind: Records, loadbalancerRef: apisix-gateway |
| `helm/templates/prometheus/` | Created / Already existed | ServiceMonitor (if prometheus.serviceMonitor.enable) |
| `helm/templates/otel/` | Created / Skipped | Instrumentation CR (if otel.autoinstrumentation.enable) |
| `helm/templates/alertmanager/` | Created | — |
| `helm/templates/autoscaling/` | Created | HPA + KEDA templates; active type set by `autoscaling.type` in values.yaml |
| `helm/templates/cilium/` | Created | mTLS ingress+egress; SPIRE required |
| `argocd/` | Created | Application (multi-source) + Secret |
| `Dockerfile` / `docker-build/Dockerfile` | Created | React → `docker-build/Dockerfile`; all other stacks → project root |
| `docker-build/entrypoint.sh` | Created / Skipped | React + Keycloak only; replaces KEYCLOAK_URL/REALM/CLIENT_ID/API_URL placeholders at startup |
| `.gitlab-ci.yml` | Created | Stack: <stack>; tag via yq; React uses `--local dockerfile=docker-build` |
| `version.yaml` | Created / Already existed | — |

**If `output_format = kustomize`:**

| File / Directory | Action | Notes |
|-----------------|--------|-------|
| `kubernetes/base/` | Created | All manifests + kustomization.yaml per dir |
| `kubernetes/base/app/` | Created | N deployments (securityContext), N services, N configmaps |
| `kubernetes/base/vault/` | Created / Skipped | Secrets found: yes/no |
| `kubernetes/base/apisix/` | Created | Route + N upstreams |
| `kubernetes/base/crossplane/cloudflare/` | Created | kind: Records, loadbalancerRef: apisix-gateway |
| `kubernetes/base/prometheus/` | Created / Already existed | ServiceMonitor (if prometheus.serviceMonitor.enable) |
| `kubernetes/base/otel/` | Created / Skipped | Instrumentation CR (stack-specific, if otel.autoinstrumentation.enable) |
| `kubernetes/base/alertmanager/` | Created | — |
| `kubernetes/base/autoscaling/` | Created | HPA + KEDA templates; active type set by `autoscaling.type` in values.yaml |
| `kubernetes/base/cilium/` | Created | mTLS ingress+egress; SPIRE required |
| `kubernetes/overlays/dev|qua|prd/` | Created | replicas patch + image tag placeholder |
| `argocd/` | Created | Application (single source, overlay path) + Secret |
| `Dockerfile` / `docker-build/Dockerfile` | Created | React → `docker-build/Dockerfile`; all other stacks → project root |
| `docker-build/entrypoint.sh` | Created / Skipped | React + Keycloak only; replaces KEYCLOAK_URL/REALM/CLIENT_ID/API_URL placeholders at startup |
| `.gitlab-ci.yml` | Created | Stack: <stack>; tag via kustomize edit; React uses `--local dockerfile=docker-build` |
| `version.yaml` | Created / Already existed | — |

List any secrets moved to Vault.
Flag any item that requires manual follow-up (e.g., ArgoCD CR template not found in repo, SPIRE not confirmed running).
