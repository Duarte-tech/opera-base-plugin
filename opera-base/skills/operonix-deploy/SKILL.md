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
| `db_name` | *(ask only if `has_database = true` after Step 1)* Database name (default: `<project>_db`) |
| `postgres_version` | *(ask only if `has_database = true` after Step 1)* PostgreSQL version (default: `16`) |
| `persistence_mount_path` | *(ask only if `has_persistence = true` after Step 1)* Mount path inside the container (default: `/data`) |
| `persistence_size` | *(ask only if `has_persistence = true` after Step 1)* PVC storage size (default: `1Gi`) |
| `tls_enabled` | Enable HTTPS termination via APISIX + cert-manager (default: `false`) |
| `tls_cert_manager_enable` | *(ask only if `tls_enabled = true`)* Generate a cert-manager `Certificate` (`true`) or reuse an existing cluster certificate (`false`) — default: `true` |
| `tls_cluster_issuer` | *(ask only if `tls_cert_manager_enable = true`)* Name of the cert-manager `ClusterIssuer` |
| `tls_existing_secret_name` | *(ask only if `tls_cert_manager_enable = false`)* Name of the pre-existing TLS Secret to reference |
| `database_pooler_enable` | *(ask only if `has_database = true`)* Generate a CNPG `Pooler` (PgBouncer) (default: `false`) |
| `database_backup_enable` | *(ask only if `has_database = true`)* Generate CNPG `ScheduledBackup` + `ObjectStore` (default: `false`) |
| `backup_s3_bucket`, `backup_s3_endpoint`, `backup_credentials_secret_name`, `backup_retention_policy`, `backup_schedule` | *(ask only if `database_backup_enable = true`)* S3-compatible backend details for Barman Cloud Plugin |
| `database_monitoring_enable` | *(ask only if `has_database = true`)* Generate a CNPG `PodMonitor` (default: `true`) |
| `vault_dynamic_db_secrets_enable` | *(ask only if `has_database = true`)* Use Vault dynamic database credentials (`VaultDynamicSecret`) instead of/alongside static secrets (default: `false`) |
| `cron_jobs` | *(ask only if `has_scheduled_tasks = true` after Step 1)* List of `{job_name, schedule, invocation}` — one per detected/confirmed scheduled task |
| `grafana_dashboard_enable` | Generate a starter Grafana dashboard-as-code ConfigMap (default: `false`) |

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

> **Reconciliation rule:** "already exists" is not the same as "already correct". Before treating any file or directory as already satisfied, compare what's actually on disk against what these rules and this skill would generate *today*.
> - If it differs — wrong API group/kind, outdated field names, an obsolete directory layout (e.g. a leftover `crossplane/` folder from before the novlok-operator migration) — **update it in place** to match the current templates, and report it as `Updated` in the output summary (see Output summary below).
> - If a directory the current rules no longer produce still exists, remove it (after moving any still-relevant content to its new location) instead of leaving it alongside the new structure.
> - This applies on every run, not just first-time scaffolding — projects are expected to be re-scaffolded as these rules evolve.

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

**Database detection** — scan the project for PostgreSQL indicators (see `references/rules.md` Rule 13 for exact patterns per stack):
- `.env*` files: keys matching `DATABASE_URL`, `DB_HOST`, `DB_NAME`, `POSTGRES_*`, `PG_*`
- `package.json` dependencies: `pg`, `sequelize`, `prisma`, `typeorm`, `knex`, `drizzle-orm`
- `go.mod`: `gorm.io/gorm`, `github.com/lib/pq`, `github.com/jackc/pgx`
- `pom.xml` / `build.gradle`: `spring-data-jpa`, `spring-boot-starter-data-jpa`, `postgresql`
- `requirements.txt` / `pyproject.toml`: `psycopg2`, `asyncpg`, `SQLAlchemy`, `databases`

Present findings to the user for confirmation. If nothing is detected, ask explicitly: "Does this project connect to a PostgreSQL database?"

- `has_database = true` → ask `db_name` (default: `<project>_db`) and `postgres_version` (default: `16`)
- `has_database = false` → skip Step 3b

**Persistence detection** — scan the project for file upload libraries and local file storage indicators (see `references/rules.md` Rule 14 for exact patterns per stack and config files).

Present findings to the user for confirmation. If nothing is detected, ask explicitly: "Does this application write files to disk that must persist across pod restarts?"

- `has_persistence = true` → ask `persistence_mount_path` (default: `/data`) and `persistence_size` (default: `1Gi`)
- `has_persistence = false` → skip Step 3c

**Scheduled-task detection** — scan the project for scheduling library usage and internal cron-style routes (see `references/rules.md` Rule 17 for exact patterns per stack):
- `package.json` dependencies: `node-cron`, `node-schedule`, `agenda`, `bull`, `bullmq`; source routes matching `/api/cron/*`
- `requirements.txt` / `pyproject.toml`: `celery` with `beat_schedule`, `APScheduler`
- `go.mod`: `github.com/robfig/cron`
- Source code: `@Scheduled` / `@EnableScheduling` annotations (Java)

Present findings to the user for confirmation. If nothing is detected, ask explicitly: "Does this project have scheduled/cron tasks?"

- `has_scheduled_tasks = true` → ask, for each job: `job_name`, `schedule` (cron expression), invocation mechanism (`http:<path>` or `command:<command>`)
- `has_scheduled_tasks = false` → skip Step 3d

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

### Step 3b — CNPG database manifests

Skip if `has_database = false`.

Generate an **ImageCatalog CR**, a **Cluster CR**, and a **Database CR** using the schemas from `references/rules.md` Rule 13.

**ImageCatalog CR** (`postgresql.cnpg.io/v1`, kind `ImageCatalog` — namespaced, one per project, no cross-project collision risk):
- `metadata.name`: `<project>-postgresql`
- `spec.images`: single entry — `major`/`image` tag from `postgres_version` (helm: `{{ .Values.database.cluster.postgresVersion | int }}` / `{{ .Values.database.cluster.postgresVersion }}`)

**Cluster CR** (`postgresql.cnpg.io/v1`, kind `Cluster`):
- `metadata.name`: `<project>-db`
- `spec.instances`: helm `{{ .Values.database.cluster.instances }}`; kustomize hardcode per env (dev/qua: `1`, prd: `3`)
- `spec.imageCatalogRef`: references the `ImageCatalog` CR above (`apiGroup: postgresql.cnpg.io`, `kind: ImageCatalog`, `name: <project>-postgresql`, `major` = `postgres_version`) — replaces the old `spec.imageName` shorthand
- `spec.storage.size`: helm `{{ .Values.database.cluster.storage.size }}`; kustomize hardcode (dev/qua: `1Gi`, prd: `10Gi`)
- `spec.bootstrap.initdb.database`: helm `{{ .Values.database.cluster.dbName }}`; kustomize hardcode `<db_name>`
- `spec.bootstrap.initdb.owner`: helm `{{ .Values.database.cluster.dbOwner }}`; kustomize hardcode `<project>_user`
- `spec.bootstrap.initdb.secret.name`: `<project>-db-credentials` (pre-existing Secret — document as manual prerequisite in output summary)

**Database CR** (`postgresql.cnpg.io/v1`, kind `Database` — requires CNPG v1.22+):
- `metadata.name`: `<project>-db-<db_name>`
- `spec.name`: helm `{{ .Values.database.cluster.dbName }}`; kustomize hardcode `<db_name>`
- `spec.owner`: helm `{{ .Values.database.cluster.dbOwner }}`; kustomize hardcode `<project>_user`
- `spec.cluster.name`: `<project>-db`

**Helm:** wrap all three CRs (ImageCatalog, Cluster, Database) in `{{- if .Values.database.cluster.enable }}` … `{{- end }}`.

**Kustomize:**
- Generate `kubernetes/base/database/kustomization.yaml` with `kind: Component` (not `kind: Kustomization`) — this prevents it from being auto-included by the base.
- Do **not** add `database/` to `kubernetes/base/kustomization.yaml`.
- Add a commented opt-in block to every overlay `kustomization.yaml`:
  ```yaml
  # components:
  # - ../../base/database   # uncomment to enable CNPG database cluster in this environment
  ```

Use CR templates from `references/rules.md` Rule 13.

**Also generate, per their own flags (all default `false` except monitoring, which defaults `true`):**
- `database_pooler_enable = true` → generate the `Pooler` CR (Rule 13a)
- `database_backup_enable = true` → generate `ObjectStore` + `ScheduledBackup` CRs (Rule 13b), and add the `spec.backup`/`spec.plugins` block to the Cluster CR from this step
- `database_monitoring_enable = true` (default) → generate the `PodMonitor` CR (Rule 13c)

Do **not** generate a `ClusterImageCatalog` — see Rule 13d for why (cluster-scoped, shared across projects, out of scope for per-project scaffolding). The namespaced `ImageCatalog` generated above is a different kind and has no such restriction.

Output path:
- `helm`: `helm/templates/database/`
- `kustomize`: `kubernetes/base/database/` + `kustomization.yaml` (kind: Component)

---

### Step 3c — PVC manifest

Skip if `has_persistence = false`.

Generate `pvc.yaml` using the template from `references/rules.md` Rule 14.

Also update every Deployment from Step 3 to add `volumeMounts` (container level) and `volumes` (pod spec level) referencing this PVC — see Rule 14 for exact YAML structure per output format.

Output path:
- `helm`: `helm/templates/app/pvc.yaml`
- `kustomize`: `kubernetes/base/app/pvc.yaml` — add to `kubernetes/base/app/kustomization.yaml`

---

### Step 3d — CronJob manifests

Skip if `has_scheduled_tasks = false`.

Generate one `CronJob` per confirmed job using the template from `references/rules.md` Rule 17. Use the `http:<path>` variant (calls the app's own Service) by default; if the user specified `command:<command>` instead, replace the container image/command accordingly.

Output path:
- `helm`: `helm/templates/cron/cronjob.yaml` (single template, `{{- range .Values.cronJobs.jobs }}`)
- `kustomize`: `kubernetes/base/cron/cronjob-<job_name>.yaml` (one file per job) + `kustomization.yaml`

---

### Step 4 — Vault manifests

Skip if `has_secrets = false`.

**Resolve mount path** from `vault_mount_mode` (the KV mount itself is assumed to already exist in both cases — novlok-operator has no generic CR to create one; see Rule 2 gap note):
- `vault_mount_mode = new` → mount path: `kv/novlok/<project>/`
- `vault_mount_mode = default` → mount path: `<vault_mount_path>/<project>/`

Generate `VaultConnection`, `VaultAuth`, `VaultStaticSecret` CRs covering only `confidential_secrets` from Step 1:
- `vault_address` from runtime input (helm: `{{ .Values.vault.address }}`)
- Auth method: kubernetes, role: `<project>`, service account: `<project>-sa`
- `VaultStaticSecret.spec.mount`: KV engine name from the resolved mount path (e.g. `kv`)
- `VaultStaticSecret.spec.path`: path within the mount (e.g. `novlok/<project>` or `<vault_mount_path>/<project>`)

Also generate the novlok-operator `VaultAuth`, `VaultPolicy`, and `VaultKubernetesRole` CRs (always, regardless of mount mode) — these grant `<project>-sa` scoped read access to the resolved KV path and back the `role: <project>` referenced above.

Output path:
- `helm`: `helm/templates/vault/`
- `kustomize`: `kubernetes/base/vault/` + `kustomization.yaml`

Use the CR templates from `references/rules.md` Rule 2.
Verify API versions against cluster: `kubectl get crd | grep hashicorp` (vault-secrets-operator) and `kubectl get crd | grep infra.novlok.com` (novlok-operator)

---

### Step 4b — Vault Dynamic Secrets (database credentials)

Skip if `has_database = false` or `vault_dynamic_db_secrets_enable = false`.

Generate a `VaultDynamicSecret` CR (Rule 16) that issues dynamic database credentials via Vault's `database` secrets engine, with `rolloutRestartTargets` pointing at every Deployment from Step 3 that connects to the database.

> Prerequisite (out-of-cluster): Vault's `database` secrets engine must already be mounted with a role issuing credentials at `creds/<project>`. Flag this in the output summary if unconfirmed.

Also ensure every Deployment generated in Step 3 uses the `RollingUpdate{maxUnavailable: 0, maxSurge: 1}` strategy from Rule 10/16 — this applies regardless of whether this step runs, but is especially relevant here since it makes the rollout triggered by `rolloutRestartTargets` safe.

Output path:
- `helm`: `helm/templates/vault/dynamicsecret.yaml`
- `kustomize`: `kubernetes/base/vault/dynamicsecret.yaml`

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

### Step 5b — TLS manifests

Skip if `tls_enabled = false` (default — preserves current HTTP-only behavior).

Generate `ApisixTls` always (when `tls_enabled = true`); generate the cert-manager `Certificate` CR only if `tls_cert_manager_enable = true` — otherwise `ApisixTls` references `tls_existing_secret_name` directly. Use the templates from `references/rules.md` Rule 15. Keep `ApisixTls.spec.hosts` in sync with the `ApisixRoute.spec.http[].match.hosts` generated in Step 5.

> Prerequisite (cert-manager mode): cert-manager must be running with the named `ClusterIssuer` already configured. Flag in the output summary if unconfirmed.
> Prerequisite (existing-secret mode): the named Secret must already exist in the project namespace. Flag in the output summary if unconfirmed.

Output path:
- `helm`: `helm/templates/tls/`
- `kustomize`: `kubernetes/base/tls/` + `kustomization.yaml` (kind: Component)

---

### Step 6 — Cloudflare DNS manifest

One `cloudflare.infra.novlok.com/v1 Record` CR (novlok-operator; cluster-scoped):

- `zone: novlok.co`
- `proxied: true`, `type: A`
- `serviceRef: name: apisix-gateway, namespace: apisix`
- `credentialsSecretRef: name: cloudflare-api-token-secret, namespace: cert-manager, key: api-token`

Output path:
- `helm`: `helm/templates/cloudflare/`
- `kustomize`: `kubernetes/base/cloudflare/` + `kustomization.yaml`

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
- **Before generating**, fetch per-language versions from `GET https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/main/versions.txt` — parse `autoinstrumentation-nodejs`, `autoinstrumentation-java`, `autoinstrumentation-python`, `autoinstrumentation-go` (format: `key=value`). Each language uses its own independent SDK version tag.
- Include **all four language blocks** (nodejs, java, python, go) — the operator selects the right one via the pod annotation
- Helm: wrap in `{{- if .Values.otel.autoinstrumentation.enable }}`

Add the stack-specific auto-injection annotation to every **Deployment** (from Step 3):
- Helm: `instrumentation.opentelemetry.io/inject-{{ .Values.stack }}: "true"` inside `{{- if .Values.otel.autoinstrumentation.enable }}`
- Kustomize: hardcode the annotation for the detected stack

Use the CR templates from `references/rules.md` Rule 3b.

**Grafana dashboard** — skip if `grafana_dashboard_enable = false` (default). Generate the starter ConfigMap from `references/rules.md` Rule 18 and flag in the output summary that the user must customize the panels before relying on it.

Output path — ServiceMonitor / Grafana dashboard:
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

One `CiliumNetworkPolicy` per project (applies to all pods in namespace).

#### Sub-step 9a — Scan source code for HTTP endpoints

Before generating the policy, scan the project for HTTP calls using Grep:

1. Run grep patterns for the detected `stack` **and** always scan all config files (`.env*`, `application.yml`, `values.yaml`, etc.) — see `references/rules.md` Rule 7b for exact patterns per language.
2. Extract all unique URLs/hostnames found.
3. Classify each as **internal** (K8s service — no TLD) or **external** (FQDN with real TLD).
4. **Present both lists to the user for confirmation**, grouped as:
   - `Internal services detected: [...]` — allow additions/removals
   - `External FQDNs detected: [...]` — allow additions/removals
5. If nothing is detected, proceed with base policy only and note it in the summary.

#### Sub-step 9b — Generate policy

Base rules (always included):
- Allow ingress from `apisix` namespace (no mTLS — external entry point)
- Allow intra-namespace traffic (ingress + egress) with `authentication.mode: required`
- Allow egress to CoreDNS (port 53/UDP)

Auto-detected rules (appended after CoreDNS rule, based on confirmed endpoints from 9a):
- For each confirmed **internal service**: add `toEndpoints` rule with `authentication.mode: required` (see Rule 7b template)
- For each confirmed **external FQDN**: add `toFQDNs` rule on port 443 (HTTPS) or 80 (HTTP) (see Rule 7b template)

Output path:
- `helm`: `helm/templates/cilium/`
- `kustomize`: `kubernetes/base/cilium/` + `kustomization.yaml`

Use the CR template from `references/rules.md` Rule 7. Append auto-detected egress rules per Rule 7b.

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
4. Update `helm/<project>/values.yaml` (chart defaults) — keep it as a minimal structural placeholder; all runtime config lives in the per-env files.
5. Generate three complete values files in the app repo root (no shared base):
   - `values-dev.yaml` — full schema, dev profile (replicas: 1, lower resources)
   - `values-qua.yaml` — full schema, qua profile (replicas: 1, lower resources)
   - `values-prd.yaml` — full schema, prd profile (replicas: 2, higher resources, minReplicas: 2)
   Use the complete schemas from `references/rules.md` Rule 11.
   If `has_persistence = true`, add the `persistence` block from Rule 14 to all three files, using `persistence_mount_path` and `persistence_size` from runtime inputs (default `enabled: false` in all environments).
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
   - `helm.valueFiles`: `["$values/values-<env>.yaml"]` — single complete env-specific file (no shared base)

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
| `nodejs` | `node:24-alpine` | `node:24-alpine` |
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

**Keycloak detection** (`has_keycloak`): check `package.json` `dependencies` and `devDependencies` for any of: `keycloak-js`, `@react-keycloak/web`, `@react-keycloak/native`. If found → `has_keycloak = true`.

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
- `helm`: `yq e '.image.tag = strenv(IMAGE_TAG)' -i values-${CI_COMMIT_REF_NAME}.yaml` on app repo branch (`dev` → `values-dev.yaml`, etc.)
- `kustomize`: `kustomize edit set image <registry>=<registry>:${IMAGE_TAG}` on `kubernetes/overlays/${CI_COMMIT_REF_NAME}/kustomization.yaml`

The `git commit` line in this job **must** use YAML single-quote wrapping to prevent validators from interpreting `ci:` as a YAML mapping key:
```yaml
    - 'git commit -m "ci: update k8s tag to ${IMAGE_TAG}"'
```

ArgoCD apply job (`apply-argocd`) — always include:
- Use the template from `references/rules.md` Rule 8 (`apply-argocd` section)
- Replace `<project>` in the filenames with the actual project name
- Required CI variable to document: `KUBE_CONFIG` (base64-encoded kubeconfig)

---

### Step 14 — `version.yaml`

If not present in the project root, generate it:

```yaml
version: "0.1.0"
```

---

## Output summary

After all steps, report a table. Adapt paths to `output_format`.

Actions: `Created` (new), `Skipped` (correctly absent — e.g. an optional area disabled by runtime inputs), `Already existed` (present and already matches current rules), `Updated` (present but didn't match current rules — content or path was corrected per the Reconciliation rule above; briefly note what changed).

**If `output_format = helm`:**

| File / Directory | Action | Notes |
|-----------------|--------|-------|
| `helm/Chart.yaml` | Created | — |
| `helm/values.yaml` | Created | Base defaults (all envs) |
| `values-dev.yaml` | Created | Dev overrides (app repo root) |
| `values-qua.yaml` | Created | QA overrides (app repo root) |
| `values-prd.yaml` | Created | Prod overrides, replicas: 2 (app repo root) |
| `helm/templates/_helpers.tpl` | Created | — |
| `helm/templates/app/` | Created | N deployments (securityContext, volumeMounts/volumes if persistence), N services, N configmaps |
| `helm/templates/app/pvc.yaml` | Created / Skipped | PVC (if has_persistence); gated by `persistence.enabled` in values |
| `helm/templates/vault/` | Created / Skipped | Secrets found: yes/no; includes novlok-operator VaultAuth/VaultPolicy/VaultKubernetesRole |
| `helm/templates/vault/dynamicsecret.yaml` | Created / Skipped | VaultDynamicSecret + rolloutRestartTargets (if vault_dynamic_db_secrets_enable) |
| `helm/templates/database/` | Created / Skipped | CNPG ImageCatalog + Cluster + Database CR (if has_database); `database.cluster.enable: false` in all values files |
| `helm/templates/database/pooler.yaml` | Created / Skipped | Pooler/PgBouncer (if database.cluster.pooler.enable) |
| `helm/templates/database/backup.yaml` | Created / Skipped | ObjectStore + ScheduledBackup (if database.cluster.backup.enable) |
| `helm/templates/database/podmonitor.yaml` | Created / Skipped | Postgres PodMonitor (if database.cluster.monitoring.enable, default true) |
| `helm/templates/apisix/` | Created | Route + N upstreams |
| `helm/templates/tls/` | Created / Skipped | Certificate (if tls.certManager.enable) + ApisixTls (if tls.enabled) |
| `helm/templates/cloudflare/` | Created | kind: Record, serviceRef: apisix-gateway |
| `helm/templates/prometheus/` | Created / Already existed | ServiceMonitor (if prometheus.serviceMonitor.enable) |
| `helm/templates/prometheus/grafana-dashboard.yaml` | Created / Skipped | Starter dashboard ConfigMap (if prometheus.grafanaDashboard.enable) — customize panels before relying on it |
| `helm/templates/otel/` | Created / Skipped | Instrumentation CR (if otel.autoinstrumentation.enable) |
| `helm/templates/alertmanager/` | Created | — |
| `helm/templates/autoscaling/` | Created | HPA + KEDA templates; active type set by `autoscaling.type` in values.yaml |
| `helm/templates/cilium/` | Created | mTLS ingress+egress; SPIRE required |
| `helm/templates/cron/` | Created / Skipped | N CronJobs (if has_scheduled_tasks) |
| `argocd/` | Created | Application (multi-source) + Secret |
| `Dockerfile` / `docker-build/Dockerfile` | Created | React → `docker-build/Dockerfile`; all other stacks → project root |
| `docker-build/entrypoint.sh` | Created / Skipped | React + Keycloak only; replaces KEYCLOAK_URL/REALM/CLIENT_ID/API_URL placeholders at startup |
| `.gitlab-ci.yml` | Created | Stack: <stack>; tag via yq; React uses `--local dockerfile=docker-build` |
| `version.yaml` | Created / Already existed | — |

**If `output_format = kustomize`:**

| File / Directory | Action | Notes |
|-----------------|--------|-------|
| `kubernetes/base/` | Created | All manifests + kustomization.yaml per dir |
| `kubernetes/base/app/` | Created | N deployments (securityContext, volumeMounts/volumes if persistence), N services, N configmaps |
| `kubernetes/base/app/pvc.yaml` | Created / Skipped | PVC (if has_persistence); listed in app/kustomization.yaml |
| `kubernetes/base/vault/` | Created / Skipped | Secrets found: yes/no; includes novlok-operator VaultAuth/VaultPolicy/VaultKubernetesRole |
| `kubernetes/base/vault/dynamicsecret.yaml` | Created / Skipped | VaultDynamicSecret + rolloutRestartTargets (if vault_dynamic_db_secrets_enable) |
| `kubernetes/base/database/` | Created / Skipped | CNPG ImageCatalog + Cluster + Database CR as Kustomize Component (if has_database); overlays opt in by uncommenting `components` block |
| `kubernetes/base/database/pooler.yaml` | Created / Skipped | Pooler/PgBouncer (if database.cluster.pooler.enable); listed in database Component |
| `kubernetes/base/database/backup.yaml` | Created / Skipped | ObjectStore + ScheduledBackup (if database.cluster.backup.enable); listed in database Component |
| `kubernetes/base/database/podmonitor.yaml` | Created / Skipped | Postgres PodMonitor (if database.cluster.monitoring.enable, default true); listed in database Component |
| `kubernetes/base/apisix/` | Created | Route + N upstreams |
| `kubernetes/base/tls/` | Created / Skipped | Certificate (if tls.certManager.enable) + ApisixTls as Kustomize Component (if tls.enabled); overlays opt in by uncommenting `components` block |
| `kubernetes/base/cloudflare/` | Created | kind: Record, serviceRef: apisix-gateway |
| `kubernetes/base/prometheus/` | Created / Already existed | ServiceMonitor (if prometheus.serviceMonitor.enable) |
| `kubernetes/base/prometheus/grafana-dashboard.yaml` | Created / Skipped | Starter dashboard ConfigMap (if prometheus.grafanaDashboard.enable) — customize panels before relying on it |
| `kubernetes/base/otel/` | Created / Skipped | Instrumentation CR (stack-specific, if otel.autoinstrumentation.enable) |
| `kubernetes/base/alertmanager/` | Created | — |
| `kubernetes/base/autoscaling/` | Created | HPA + KEDA templates; active type set by `autoscaling.type` in values.yaml |
| `kubernetes/base/cilium/` | Created | mTLS ingress+egress; SPIRE required |
| `kubernetes/base/cron/` | Created / Skipped | N CronJobs, one file per job (if has_scheduled_tasks) |
| `kubernetes/overlays/dev|qua|prd/` | Created | replicas patch + image tag placeholder |
| `argocd/` | Created | Application (single source, overlay path) + Secret |
| `Dockerfile` / `docker-build/Dockerfile` | Created | React → `docker-build/Dockerfile`; all other stacks → project root |
| `docker-build/entrypoint.sh` | Created / Skipped | React + Keycloak only; replaces KEYCLOAK_URL/REALM/CLIENT_ID/API_URL placeholders at startup |
| `.gitlab-ci.yml` | Created | Stack: <stack>; tag via kustomize edit; React uses `--local dockerfile=docker-build` |
| `version.yaml` | Created / Already existed | — |

List any secrets moved to Vault.
Flag any item that requires manual follow-up (e.g., ArgoCD CR template not found in repo, SPIRE not confirmed running).
