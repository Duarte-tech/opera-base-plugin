# Operational Rules — opera-base

Source: meeting with Duarte (2026-05-27)

---

## 1. Scope — what this plugin generates

Builds Kubernetes YAML manifests **and** a GitLab CI pipeline. No manual deploy steps.

### Output directory structure (inside the application repo)

```
kubernetes/
├── app/              → Deployment, ConfigMap, Service, Secret (only if no Vault), PVC (if has_persistence)
├── database/         → CNPG Cluster, Database, Pooler, ScheduledBackup+ObjectStore, PodMonitor (if has_database)
├── apisix/           → ApisixRoute, ApisixUpstream
├── tls/              → cert-manager Certificate, ApisixTls (if tls.enabled)
├── alertmanager/     → PrometheusRule (app cluster — Rule 19)
├── prometheus/       → ServiceMonitor, Grafana dashboard ConfigMap (optional)
├── cilium/           → CiliumNetworkPolicy
├── cloudflare/       → cloudflare.infra.novlok.com/v1 Record (novlok-operator)
├── cron/             → CronJob (if has_scheduled_tasks)
└── vault/            → VaultAuth, VaultStaticSecret (vault-secrets-operator)
                        + VaultAuth, VaultPolicy, VaultKubernetesRole (novlok-operator)
                        + VaultDynamicSecret (if vault_dynamic_db_secrets_enable)
```

Additionally, `ops/` at the **app repo root** (a sibling of `kubernetes/`, not inside it) holds plain-YAML manifests destined for the **ops cluster** — `AlertmanagerConfig` (Rule 20) and the Loki rules `ConfigMap` (Rule 21) — delivered by the ArgoCD `ApplicationSet` in Rule 22. Generated only when `alertmanager_config_enable` / `loki_rules_enable` are set.

> This structure is the *current* target — on every run, reconcile it against what's already in the project (see `SKILL.md` → Reconciliation rule) rather than assuming an existing file or folder is already correct.

### Repo model — one mono-repo per project

App code, the Helm chart (`helm/<project>/`), the Kustomize tree (`kubernetes/`), the ArgoCD manifests (`argocd/`) and the ops manifests (`ops/`) all live in **one GitLab repo per project**. One branch per environment. There is **no separate chart repo and no separate ArgoCD repo** — a single runtime input `gitlab_repo` covers all three (the old `gitlab_helm_repo` / `gitlab_argocd_repo` inputs are gone).

- **Chart templates**: `helm/<project>/` in the same repo.
- **`values-<env>.yaml`**: at the **repo root**, one per branch (kept at the root so the CI `update-k8s-tag` job patches them in place — Rule 8):

| Branch | Values file | Environment |
|--------|-------------|-------------|
| `dev`  | `values-dev.yaml` on `dev` branch | Development (not GitOps-managed by default) |
| `qua`  | `values-qua.yaml` on `qua` branch | Staging/QA  |
| `prd`  | `values-prd.yaml` on `prd` branch | Production  |

ArgoCD is driven by **one consolidated `ApplicationSet`** (Rule 22) that discovers every project repo in the GitLab group and, per `(repo, branch)`, produces an app-cluster `Application` (single source — chart or overlay from the same repo/branch) and an ops-cluster `Application` (`ops/` path). No per-project `Application`/repo-`Secret` files are generated. See Rule 4.

### Pipeline output

`.gitlab-ci.yml` at the application repo root — see Rule 8.

### Excluded — never generate

- Database manifests — unless `has_database = true` (see Rule 13)
- Minio manifests
- Keycloak manifests

---

## 2. Secrets → Vault (vault-secrets-operator)

Operator: **HashiCorp vault-secrets-operator**
API group: `secrets.hashicorp.com/v1beta1`

Before generating any `Secret` manifest:

1. Scan the project for secrets (`.env`, `application.yml`, `application.properties`, source files)
2. If secrets found → generate `VaultStaticSecret` + `VaultAuth` CRs instead of raw `Secret`
3. Mount path: `kv/novlok/<project>/`
4. Auth method: **Kubernetes auth**, service account: `<project>-sa`
5. Raw `Secret` only for non-sensitive metadata (e.g., a public URL)

Reference CR structure (verify version against cluster):

> `spec.mount` and `spec.path` in `VaultStaticSecret` depend on `vault_mount_mode` — see the mount path resolution table below. The values shown here (`mount: kv`, `path: novlok/<project>`) apply to `vault_mount_mode = new`.

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: <project>-vault-connection
  namespace: <project>
spec:
  address: <vault_address>   # ask at runtime
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: <project>-vault-auth
  namespace: <project>
spec:
  vaultConnectionRef: <project>-vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: <project>
    serviceAccount: <project>-sa
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: <project>-secrets
  namespace: <project>
spec:
  vaultAuthRef: <project>-vault-auth
  mount: kv                  # vault_mount_mode=new: "kv"; default: KV engine from vault_mount_path
  type: kv-v2
  path: novlok/<project>     # vault_mount_mode=new: "novlok/<project>"; default: "<vault_mount_path>/<project>"
  destination:
    name: <project>-secrets
    create: true
```

> **Note:** Verify exact CRD versions against the installed operator in the cluster (`kubectl get crd | grep hashicorp`).

**Mount path resolution (determined at runtime via `vault_mount_mode`):**

| `vault_mount_mode` | `spec.mount` | `spec.path` |
|--------------------|-------------|-------------|
| `new` | `kv` | `novlok/<project>` |
| `default` | KV engine from `vault_mount_path` | `<vault_mount_path>/<project>` |

> **Known gap:** novlok-operator has no generic CR to create a new KV secrets-engine mount (only `DatabaseMount` and `KubernetesMount` exist). In both `vault_mount_mode` values above, the KV mount is assumed to **already exist** — provision it out-of-band (e.g. `vault secrets enable -path=kv kv-v2`) until the operator adds a generic mount CR. `vault_mount_mode` only changes which path is used, not whether anything is generated to create the mount.

**Vault access resources (novlok-operator) — always generated** when `has_secrets = true`, regardless of mount mode. These replace the old Crossplane "Vault user and policy" CRs by giving the project's Kubernetes ServiceAccount a scoped Vault Kubernetes-auth role:

```yaml
apiVersion: vault.infra.novlok.com/v1
kind: VaultAuth
metadata:
  name: <project>-novlok-auth   # distinct name — do not collide with vault-secrets-operator's <project>-vault-auth below
  namespace: <project>
spec:
  address: <vault_address>       # ask at runtime
  kubernetes:
    role: novlok                 # org-wide bootstrap role the operator itself authenticates with
    mountPath: kubernetes
    serviceAccountName: vault-auth
---
apiVersion: vault.infra.novlok.com/v1
kind: VaultPolicy
metadata:
  name: <project>-policy
  namespace: <project>
spec:
  vaultAuthRef: <project>-novlok-auth
  rules: |
    path "<kv-mount>/data/<kv-path>/*" {   # <kv-mount>/<kv-path> from the mount-path resolution table above
      capabilities = ["read"]
    }
---
apiVersion: vault.infra.novlok.com/v1
kind: VaultKubernetesRole
metadata:
  name: <project>
  namespace: <project>
spec:
  backend: kubernetes             # writes directly to the already-mounted kubernetes auth engine
  vaultAuthRef: <project>-novlok-auth
  serviceAccountName: <project>-sa
  allowedKubernetesNamespaces:
    - <project>
  policies:
    - <project>-policy
  tokenDefaultTTL: "30m"
  tokenMaxTTL: "1h"
```

The `VaultKubernetesRole` name (`<project>`) is exactly the Vault role the vault-secrets-operator `VaultAuth` template above references via `spec.kubernetes.role: <project>`.

**Secret classification** — only `confidential_secrets` from Step 1 are stored in Vault:
- Confidential: API keys, tokens, passwords, private keys, encryption keys, certificates, webhook secrets, high-entropy strings
- Non-sensitive (`plain_config`): goes to ConfigMap — public URLs, hostnames, feature flags, log levels, timeouts

---

## 3. Observability

Prometheus and OTel generation is controlled by `values.yaml` flags: `prometheus.serviceMonitor.enable`, `prometheus.prometheusRules.enable`, and `otel.autoinstrumentation.enable`.  
Check for an existing `ServiceMonitor` in the prometheus dir before generating.

### 3a. Prometheus — ServiceMonitor

Generate only if `prometheus.serviceMonitor.enable = true` (default: true) and no existing `ServiceMonitor` found.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: <project>
  namespace: <project>
spec:
  selector:
    matchLabels:
      app: <service>
  endpoints:
  - port: http
    path: /metrics
```

### 3b. OTel — Instrumentation CR (auto-injection)

Generate only if `otel.autoinstrumentation.enable = true` (default: true).

Uses the **OpenTelemetry Operator** `Instrumentation` CR to auto-inject the SDK into pods — no manual SDK wiring required. The operator injects the agent via the pod annotation.

> **Before generating:** fetch per-language versions from the operator's `versions.txt` — each language has its own SDK version independent from the operator release:
> ```
> GET https://raw.githubusercontent.com/open-telemetry/opentelemetry-operator/main/versions.txt
> ```
> Parse the value for each key (format: `key=value`, one per line):
> - `autoinstrumentation-nodejs` → `<nodejs_version>`
> - `autoinstrumentation-java` → `<java_version>`
> - `autoinstrumentation-python` → `<python_version>`
> - `autoinstrumentation-go` → `<go_version>`
>
> Include **all four language blocks** — the operator picks the right one based on the pod annotation.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: <project>-instrumentation
  namespace: <project>
spec:
  exporter:
    endpoint: <otel_endpoint>   # from runtime input
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:<nodejs_version>
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:<java_version>
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:<python_version>
  go:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-go:<go_version>
```

**Deployment annotation** (added to every Deployment so the operator injects the agent):

| Stack | Annotation key |
|-------|---------------|
| `nodejs` | `instrumentation.opentelemetry.io/inject-nodejs: "true"` |
| `java` | `instrumentation.opentelemetry.io/inject-java: "true"` |
| `python` | `instrumentation.opentelemetry.io/inject-python: "true"` |
| `go` | `instrumentation.opentelemetry.io/inject-go: "true"` |

In Helm templates, wrap the annotation in a conditional:
```yaml
{{- if .Values.otel.autoinstrumentation.enable }}
annotations:
  instrumentation.opentelemetry.io/inject-{{ .Values.stack }}: "true"
{{- end }}
```

> **Prerequisite:** OpenTelemetry Operator must be running in the cluster. Verify: `kubectl get pods -n opentelemetry-operator-system`

---

## 4. ArgoCD

- ArgoCD lives in the **app-cluster** `argocd` namespace and manages both the app clusters (`qua`/`prd`) and the `ops` cluster (registered as an external cluster).
- One namespace per project on the app cluster (namespace name = project name); `<ops_namespace>` on the ops cluster.
- **Single-source `Application`s**, generated by one consolidated `ApplicationSet` (Rule 22) — no per-project `Application` or repo `Secret` files.
- GitLab access: **ask at runtime** (`gitlab_access` — SSH key or HTTPS token), used for one credential template.

**Delivery model (mono-repo):**

`argocd/` in each project repo holds exactly two reconciled singletons:

| File | Purpose |
|------|---------|
| `argocd/repo-creds.yaml` | ArgoCD `repository-credentials` Secret (`argocd.argoproj.io/secret-type: repo-creds`) scoped to the GitLab **group URL prefix** — covers every project repo in the group in one object. Credential from `gitlab_access`. |
| `argocd/applicationset.yaml` | One `ApplicationSet` (Rule 22): a **matrix** of an SCM-provider generator (the GitLab group, branches `^(qua\|prd)$`) × a list `{app, ops}`. Per `(repo, branch)` it emits `<repo>-<branch>-app` (app cluster) and `<repo>-<branch>-ops` (ops cluster). |

Both are **cross-project singletons** — apply the Reconciliation rule (create if missing; verify group coverage / template drift otherwise; never emit a second copy or a per-project `Application`).

**App-cluster `Application` source (set by the `ApplicationSet` template), single-source, same repo/branch:**
- `output_format = kustomize` → `source.path: kubernetes/overlays/<branch>`
- `output_format = helm` → `source.path: helm/<project>`, `source.helm.valueFiles: ["../../values-<branch>.yaml"]` (relative path within the same repo — no multi-source, no `$values` ref)

`dev` is intentionally outside the branch matcher — add `dev` to the regex only if development should be GitOps-managed.

---

## 5. APISIX routing

One `ApisixRoute` CR per project with **multiple `http` entries** (one per service).
One `ApisixUpstream` per service.

```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: <project>
  namespace: <project>
spec:
  http:
  - name: <service>-frontend
    match:
      hosts:
      - <subdomain>.novlok.co
      paths:
      - "/*"
    backends:
    - serviceName: <service>-frontend-svc
      servicePort: <port>
      resolveGranularity: service
  - name: <service>-api
    match:
      hosts:
      - <subdomain>.novlok.co
      paths:
      - "/api/*"
    backends:
    - serviceName: <service>-api-svc
      servicePort: <port>
      resolveGranularity: service
---
apiVersion: apisix.apache.org/v2
kind: ApisixUpstream
metadata:
  name: <service>-svc
spec:
  scheme: http
```

- Domain: `<subdomain>.novlok.co` — **ask at runtime**
- No standard plugins

---

## 6. Cloudflare DNS (novlok-operator)

```yaml
apiVersion: cloudflare.infra.novlok.com/v1
kind: Record
metadata:
  name: <project>              # Record is cluster-scoped — no namespace field
spec:
  zone: novlok.co
  name: <subdomain>
  type: A
  # content: <ip>              # optional — mutually exclusive with serviceRef
  serviceRef:                  # optional — references the APISIX gateway Service
    name: apisix-gateway
    namespace: apisix
  ttl: 1
  proxied: true
  credentialsSecretRef:        # Cloudflare API token — no ProviderConfig needed
    name: cloudflare-api-token-secret
    namespace: cert-manager
    key: api-token
```

---

## 7. Cilium

No cluster-wide default-deny. Required: **mutual TLS** between all pods in the namespace.
Ingress from the `apisix` namespace is always allowed (no mTLS required on that path).

Cilium mutual authentication (SPIFFE/SPIRE) must be enforced on **both directions** — ingress and egress — for full mTLS between intra-namespace pods.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: <project>-network-policy
  namespace: <project>
spec:
  endpointSelector: {}
  ingress:
  # Allow ingress from APISIX gateway (no mTLS — external entry point)
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: apisix
  # Allow intra-namespace traffic — mTLS required
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: <project>
    authentication:
      mode: required
  egress:
  # Allow egress to intra-namespace pods — mTLS required
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: <project>
    authentication:
      mode: required
  # Allow egress to CoreDNS
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s:k8s-app: coredns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*"
```

> **Prerequisites:** Cilium must be deployed with `authentication.mutual.spire.enabled: true` and a SPIRE server running in the cluster. Verify with `cilium config view | grep spire`.

Ref: https://docs.cilium.io/en/latest/network/servicemesh/mutual-authentication/mutual-authentication-example/

---

### 7b. Cilium — Auto-detected egress rules

Before generating the `CiliumNetworkPolicy`, the skill scans the project source code and config files to discover HTTP endpoints the application calls. Detected endpoints are appended to the base policy — the base rules (intra-namespace mTLS + CoreDNS) are never modified.

#### Scanning patterns (by language)

**Node.js / TypeScript** (`.js`, `.ts`, `.mjs`, `.cjs`)
- `axios.get/post/put/delete/request('http`
- `axios.create({.*baseURL.*http`
- `fetch('http` / `fetch("http`
- `http.get(` / `https.get(`
- `got(` / `got.get/post(`
- `superagent.get/post(`

**Python** (`.py`)
- `requests.get/post/put/delete/request(.*http`
- `httpx.get/post/put/delete/request(.*http`
- `aiohttp.*http`
- `urllib.request.urlopen(`

**Go** (`.go`)
- `http.Get(` / `http.Post(`
- `http.NewRequest(`
- `resty.*SetHostURL` / `.R().Get/Post(`
- `grpc.Dial(`

**Java** (`.java`)
- `@FeignClient.*url.*http`
- `RestTemplate.*getForObject/postForObject/exchange`
- `WebClient.*baseUrl.*http`
- `HttpClient.*send(`

**Config files** (all stacks — always scanned)
- `.env*` → values matching `*_URL=http`, `*_HOST=http`, `*_ENDPOINT=http`, `*_API=http`
- `application.yml` / `application.properties` → `url: http`, `base-url: http`, `uri: http`
- `values.yaml` / `values-*.yaml` → `url: http`, `endpoint: http`
- `appsettings.json` → `"Url": "http`, `"BaseAddress": "http`

#### Classification

| Type | Criteria | Cilium rule |
|------|----------|-------------|
| **Internal** | No TLD — matches `service-name`, `service.namespace`, `*.svc.cluster.local` | `toEndpoints` + `authentication.mode: required` |
| **External** | FQDN with real TLD (`.com`, `.io`, `.org`, `.net`, `.dev`, etc.) | `toFQDNs` |

#### Rule templates

**Internal K8s service:**
```yaml
# Auto-detected egress: <service> (<namespace>)
- toEndpoints:
  - matchLabels:
      io.kubernetes.pod.namespace: <target_namespace>
      app: <service_name>
  toPorts:
  - ports:
    - port: "<port>"
      protocol: TCP
  authentication:
    mode: required
```
If the target namespace cannot be determined from the code, assume the same project namespace and add a comment noting the assumption.

**External FQDN:**
```yaml
# Auto-detected egress: <fqdn>
- toFQDNs:
  - matchName: "<fqdn>"
  toPorts:
  - ports:
    - port: "443"
      protocol: TCP
```
Use port `80` for `http://`, `443` for `https://`. The existing CoreDNS rule already enables FQDN resolution.

> **Note:** Always present detected endpoints to the user for confirmation before generating rules — allow additions and removals. If nothing is detected, generate the base policy only and note it in the output summary.

---

### 7c. Cilium — CNPG cross-namespace rules

The base policy (intra-namespace mTLS) already covers app↔Pooler↔Postgres-instance traffic since CNPG runs in the same project namespace. It does **not** cover traffic that legitimately crosses namespace boundaries to reach the database — each rule below is appended only when the feature that needs it is active. Do not fragment into multiple `CiliumClusterwideNetworkPolicy` objects — append these as extra `ingress`/`egress` entries on the same per-project `CiliumNetworkPolicy` from Rule 7.

**Vault → DB instance** (dynamic secrets engine creating/rotating roles) — only when `vault_dynamic_db_secrets_enable = true` (Rule 16):
```yaml
ingress:
- fromEndpoints:
  - matchLabels:
      io.kubernetes.pod.namespace: vault
  toEndpoints:
  - matchLabels:
      cnpg.io/podRole: instance
  toPorts:
  - ports:
    - port: "5432"
      protocol: TCP
  authentication:
    mode: required
```

**CNPG operator → DB instance** (management/metrics) — always, whenever `has_database = true`:
```yaml
ingress:
- fromEndpoints:
  - matchLabels:
      io.kubernetes.pod.namespace: <cnpg_operator_namespace>   # ask at runtime, default: cnpg-system
  toEndpoints:
  - matchLabels:
      cnpg.io/podRole: instance
  toPorts:
  - ports:
    - port: "5432"
      protocol: TCP
    - port: "8000"
      protocol: TCP
    - port: "9187"
      protocol: TCP
  authentication:
    mode: required
```

**Prometheus → DB instance** (metrics scrape) — only when `database.cluster.monitoring.enable = true` (Rule 13c):
```yaml
ingress:
- fromEndpoints:
  - matchLabels:
      io.kubernetes.pod.namespace: <monitoring_namespace>       # ask at runtime
  toEndpoints:
  - matchLabels:
      cnpg.io/podRole: instance
  toPorts:
  - ports:
    - port: "9187"
      protocol: TCP
```
> Generating the `PodMonitor` (Rule 13c) without this rule leaves Prometheus unable to reach port 9187 — the scrape silently fails even though the PodMonitor object exists (a real gap found in production).

**DB instance → object storage** (WAL archiving) — only when `database.cluster.backup.enable = true` (Rule 13b):
```yaml
egress:
- toEntities:
  - world
  toPorts:
  - ports:
    - port: "443"
      protocol: TCP
```

---

## 8. GitLab CI Pipeline

### Stack detection (auto-detect from project root)

| File present | Stack |
|-------------|-------|
| `package.json` | Node.js |
| `pom.xml` / `build.gradle` | Java |
| `requirements.txt` / `pyproject.toml` | Python |
| `go.mod` | Go |

### Common pipeline structure (all stacks)

Stages: `test → lint → validate → tag → release → build → scan → deploy`

Always include:
- `Secret-Detection` (GitLab template)
- `SAST` (GitLab template)
- Trivy container scan (`aquasec/trivy:0.69.3`)
- `tag:define_tag` — reads `version: "1.0.0"` from `version.yaml` at project root
- `generate_changelog` — on `prd` branch only
- `release_job` — creates GitLab release + tag
- `build:app` — multi-arch (`linux/amd64,linux/arm64`), triggers on tag only
- `update-k8s-tag` — patches image tag in `values.yaml` **in the current branch of the app repo**, then pushes back

### Branch → tag mapping

| Branch | Tag pattern |
|--------|-------------|
| `dev`  | `v<version>-alpha.<n>` |
| `qua`  | `v<version>-rc.<n>` |
| `prd`  | `v<version>` |

### `version.yaml` format

```yaml
version: "1.0.0"
```

### Workflow rules — always skip CI on k8s manifest changes

```yaml
workflow:
  rules:
    - if: '$CI_COMMIT_MESSAGE =~ /^ci: update k8s tag to /'
      when: never
    - changes:
        - kubernetes/**/*
        - ops/**/*
      when: never
    - when: always
```

> `ops/**/*` is skipped for the same reason as `kubernetes/**/*` — editing a LogQL rule or an `AlertmanagerConfig` route must not trigger an application build. The ArgoCD `ApplicationSet` (Rule 22) syncs `ops/` to the ops cluster on its own.

### Stack-specific lint/test jobs

| Stack | Lint job | Test job |
|-------|----------|----------|
| Node.js | `eslint`, `tsc --noEmit` | `npm test` |
| Java | `checkstyle` / `spotbugs` | `mvn test` / `./gradlew test` |
| Python | `flake8` / `ruff` | `pytest` |
| Go | `golangci-lint` | `go test ./...` |

### `build:app` job — `moby/buildkit:rootless`

Docker image builds use `moby/buildkit:rootless` (rootless BuildKit, no Docker-in-Docker socket required).
**Never use `docker:*` images (including `docker:27`, `docker:dind`, etc.) — the only accepted build image is `moby/buildkit:rootless`.**

```yaml
build:app:
  stage: build
  image:
    name: moby/buildkit:rootless
    entrypoint: [""]
  variables:
    BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
  before_script:
    - mkdir -p ~/.docker
    - |
      printf '{"auths":{"%s":{"username":"%s","password":"%s"}}}' \
        "$CI_REGISTRY" "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" \
        > ~/.docker/config.json
  script:
    - |
      buildctl-daemonless.sh build \
        --frontend dockerfile.v0 \
        --local context=. \
        --local dockerfile=. \
        --output "type=image,name=${APP_IMAGE}:${IMAGE_TAG},push=true" \
        --opt "platform=linux/amd64,linux/arm64" \
        --import-cache "type=registry,ref=${APP_IMAGE}:cache" \
        --export-cache "type=registry,ref=${APP_IMAGE}:cache,mode=max"
  rules:
    - if: '$CI_COMMIT_TAG'
```

**Required CI/CD variables** (set in GitLab project settings — not in `.gitlab-ci.yml`):
- `CI_REGISTRY`, `CI_REGISTRY_USER`, `CI_REGISTRY_PASSWORD` — provided automatically by GitLab when using the GitLab container registry
- `APP_IMAGE` — full image path, e.g. `registry.gitlab.com/<group>/<project>/app`
- `IMAGE_TAG` — set by the `tag:define_tag` job

**React stack (`stack = react`):** the Dockerfile lives in `docker-build/`, so `--local dockerfile` must point to that directory instead of `.`:

```yaml
  script:
    - |
      buildctl-daemonless.sh build \
        --frontend dockerfile.v0 \
        --local context=. \
        --local dockerfile=docker-build \
        --output "type=image,name=${APP_IMAGE}:${IMAGE_TAG},push=true" \
        --opt "platform=linux/amd64,linux/arm64" \
        --import-cache "type=registry,ref=${APP_IMAGE}:cache" \
        --export-cache "type=registry,ref=${APP_IMAGE}:cache,mode=max"
```

The build context (`--local context=.`) stays at the project root so all `COPY docker-build/...` paths in the Dockerfile resolve correctly.

**Notes:**
- `BUILDKITD_FLAGS: --oci-worker-no-process-sandbox` is required for rootless BuildKit inside a container (no `privileged: true` needed)
- Registry auth is written to `~/.docker/config.json` in `before_script` — BuildKit reads this path automatically
- Registry layer caching uses `--import-cache` / `--export-cache`; first run is slower (cold cache), subsequent runs are fast
- Multi-arch is handled natively by BuildKit via `--opt platform=`; no `DOCKER_BUILDX_*` env vars needed

### `update-k8s-tag` job

Patches the image tag in the manifest repo after a successful build. The `git commit` line **must** be wrapped in YAML single quotes — without them, `ci:` is parsed as a YAML mapping key by schema validators.

```yaml
update-k8s-tag:
  stage: deploy
  script:
    - git config user.email "ci@novlok.co"
    - git config user.name "GitLab CI"
    # helm output_format:
    - yq e '.image.tag = strenv(IMAGE_TAG)' -i values-${CI_COMMIT_REF_NAME}.yaml
    # kustomize output_format (use instead of yq line above):
    # - kustomize edit set image ${APP_IMAGE}=${APP_IMAGE}:${IMAGE_TAG}
    - git add -A
    - 'git commit -m "ci: update k8s tag to ${IMAGE_TAG}"'
    - git push
  rules:
    - if: '$CI_COMMIT_TAG'
```

---

### `apply-argocd` job

Applies the two ArgoCD singletons in `argocd/` (the group `repo-creds` Secret and the consolidated `ApplicationSet`, Rule 22) to the app-cluster `argocd` namespace whenever files in `argocd/` change. Runs independently of the build/tag flow.

Required CI variable:
- `KUBE_CONFIG` — base64-encoded kubeconfig with permissions to create resources in the `argocd` namespace

```yaml
apply-argocd:
  stage: deploy
  image: bitnami/kubectl:latest
  before_script:
    - mkdir -p ~/.kube
    - echo "$KUBE_CONFIG" | base64 -d > ~/.kube/config
  script:
    - kubectl apply -f argocd/repo-creds.yaml       # credential first, so discovery/sync can authenticate
    - kubectl apply -f argocd/applicationset.yaml
  rules:
    - changes:
        - argocd/**/*
```

> Both files are cross-project singletons — re-applying them from any project's pipeline is idempotent. The `repo-creds` Secret is applied first so the `ApplicationSet` SCM generator and the generated `Application`s can authenticate against the GitLab group on first run.

---

## 9. Dockerfile patterns

### Stack detection — React vs Next.js

| Condition | Sub-stack |
|-----------|-----------|
| `package.json` has `"next"` dependency | `nextjs` |
| `package.json` has `"react"` + `vite.config.*` present (or `"vite"` in devDependencies), no `"next"` | `react` |

React projects always use **`nginxinc/nginx-unprivileged:alpine3.23-otel`** as the runtime image.

Keycloak detection: check `package.json` for `keycloak-js`, `@react-keycloak/web`, or `@react-keycloak/native` in `dependencies` or `devDependencies`. If found → `has_keycloak = true`.

---

### React / Vite (canonical)

For React projects the `Dockerfile` lives in **`docker-build/Dockerfile`** (together with `entrypoint.sh` when applicable). The build context passed to BuildKit is always the project root (`.`), so all `COPY` paths are relative to the root.

**Without Keycloak** — `docker-build/Dockerfile`:

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginxinc/nginx-unprivileged:alpine3.23-otel AS runner
COPY --from=builder /app/dist /usr/share/nginx/html
COPY docker-build/nginx.conf.template /etc/nginx/nginx.conf.template
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```

**With Keycloak** (`has_keycloak = true`) — `docker-build/Dockerfile`:

Vite bakes env vars into the JS bundle at build time. Set literal placeholder strings as ENV values so the bundle contains the placeholder text; the `entrypoint.sh` replaces them at container startup with the real runtime values.

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ENV VITE_KEYCLOAK_URL="KEYCLOAK_URL"
ENV VITE_KEYCLOAK_REALM="KEYCLOAK_REALM"
ENV VITE_KEYCLOAK_CLIENT_ID="KEYCLOAK_CLIENT_ID"
ENV VITE_API_URL="API_URL"
RUN npm run build

FROM nginxinc/nginx-unprivileged:alpine3.23-otel AS runner
COPY --from=builder /app/dist /usr/share/nginx/html
COPY docker-build/nginx.conf.template /etc/nginx/nginx.conf.template
COPY --chmod=755 docker-build/entrypoint.sh /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
```

Also generate `docker-build/entrypoint.sh`:

```sh
#!/bin/sh
sed -i "s|KEYCLOAK_URL|$VITE_KEYCLOAK_URL|g" /usr/share/nginx/html/assets/index*.js
sed -i "s|KEYCLOAK_REALM|$VITE_KEYCLOAK_REALM|g" /usr/share/nginx/html/assets/index*.js
sed -i "s|KEYCLOAK_CLIENT_ID|$VITE_KEYCLOAK_CLIENT_ID|g" /usr/share/nginx/html/assets/index*.js
sed -i "s|API_URL|$VITE_API_URL|g" /usr/share/nginx/html/assets/index*.js
export OTEL_COLLECTOR_HOST="${OTEL_COLLECTOR_HOST:-otel-collector}"
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-frontend}"
envsubst '${OTEL_COLLECTOR_HOST} ${OTEL_SERVICE_NAME}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

exec "$@"
```

> All files under `docker-build/` (`Dockerfile`, `entrypoint.sh`, `nginx.conf.template`) are referenced from the **project root** in `COPY` instructions because the BuildKit context is `.`.

> `--chmod=755` on the `COPY` requires BuildKit (always available in the CI pipeline via `moby/buildkit:rootless`). The image runs as UID 101 (`nginx`); the script must be executable before switching users.

> The `VITE_API_URL` placeholder is included by default alongside the Keycloak vars. Remove it if the project does not use a `VITE_API_URL` env var.

---

### Go (multi-stage — canonical)

```dockerfile
# Build stage
FROM golang:1.26.3-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -o /app-binary .

# Runtime stage
FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /app-binary /app-binary

EXPOSE 8080

ENTRYPOINT ["/app-binary"]
```

### Node.js / Next.js + Prisma (canonical)

```dockerfile
FROM node:24-alpine AS base
WORKDIR /app
RUN apk update && apk add --no-cache openssl

# Dev
FROM base AS dev
COPY package*.json ./
COPY prisma ./prisma/
RUN npm install
EXPOSE 3000
CMD ["npm", "run", "dev"]

# Migrator (Prisma CLI only — used by docker-compose.prod.yml)
FROM base AS migrator
COPY package*.json ./
COPY prisma ./prisma/
RUN npm ci
CMD ["npx", "prisma", "migrate", "deploy"]

# Builder
FROM base AS builder
COPY package*.json ./
COPY prisma ./prisma/
RUN npm ci
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# Runner
FROM base AS runner
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder --chown=nextjs:nodejs /app/node_modules/@prisma/client ./node_modules/@prisma/client
COPY --from=builder --chown=nextjs:nodejs /app/prisma ./prisma

USER nextjs
EXPOSE 3000
ENV PORT=3000
CMD ["node", "server.js"]
```

> `openssl` é obrigatório no alpine para o engine do Prisma. Se o projecto não usa Prisma, remove as camadas `migrator` e os `COPY --prisma`.

### Java / Maven (canonical)

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:21-jre-alpine AS runner
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### Python / gunicorn (canonical)

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.12-slim AS runner
WORKDIR /app
COPY --from=builder /root/.local /root/.local
COPY . .
ENV PATH=/root/.local/bin:$PATH
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "4", "app:app"]
```

---

## 11. Output format — Helm vs Kustomize

At runtime the user chooses one of two output formats. The manifests generated in Steps 3–9 are identical in content; only the layout and wrapping differ.

---

### `helm` — Helm chart templates

Output root: `helm/<project>/` in the **same mono-repo** as the app (no separate chart repo — Rule 1).
Per-environment values live as `values-<env>.yaml` at the **repo root**, one per branch. The ArgoCD `Application` is **single-source**: `source.path: helm/<project>` + `source.helm.valueFiles: ["../../values-<env>.yaml"]` on the same branch (Rule 4).

```
values-dev.yaml               # repo root — one complete file per env, on its branch
values-qua.yaml
values-prd.yaml
helm/<project>/
├── Chart.yaml
├── values.yaml                # minimal structural placeholder — real config is in values-<env>.yaml
└── templates/
    ├── _helpers.tpl
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── app/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── configmap.yaml
    ├── apisix/
    │   ├── route.yaml
    │   └── upstream.yaml
    ├── tls/
    │   ├── certificate.yaml
    │   └── apisixtls.yaml
    ├── vault/
    │   ├── connection.yaml
    │   ├── auth.yaml
    │   ├── staticsecret.yaml
    │   ├── novlok-auth.yaml
    │   ├── policy.yaml
    │   ├── role.yaml
    │   ├── databasemount.yaml       # if database.cluster.vaultDynamicSecrets.enable (Rule 16)
    │   ├── databaseconnection.yaml  # if database.cluster.vaultDynamicSecrets.enable (Rule 16)
    │   ├── databaserole.yaml        # if database.cluster.vaultDynamicSecrets.enable (Rule 16)
    │   └── dynamicsecret.yaml       # if database.cluster.vaultDynamicSecrets.enable (Rule 16)
    ├── cilium/
    │   └── networkpolicy.yaml
    ├── prometheus/
    │   ├── servicemonitor.yaml
    │   └── grafana-dashboard.yaml
    ├── otel/
    │   └── instrumentation.yaml
    ├── alertmanager/
    │   └── prometheusrule.yaml
    ├── autoscaling/
    │   └── autoscaling.yaml
    ├── cron/
    │   └── cronjob.yaml
    ├── database/
    │   ├── imagecatalog.yaml
    │   ├── cluster.yaml
    │   ├── database.yaml
    │   ├── pooler.yaml
    │   ├── backup.yaml
    │   ├── podmonitor.yaml
    │   ├── databaserole.yaml   # if database.cluster.roles.enable (Rule 13e)
    │   └── certificate.yaml    # if database.cluster.tls.enable (Rule 13g)
    └── cloudflare/
        └── record.yaml
argocd/                        # repo root — two reconciled singletons (Rule 4 / Rule 22)
├── repo-creds.yaml
└── applicationset.yaml
ops/                           # repo root — plain YAML, ops cluster (Rules 20–22)
├── alertmanagerconfig-<project>.yaml   # if alertmanager_config_enable
└── loki-rules-<project>.yaml           # if loki_rules_enable
```

**Helm conventions:**

- `Chart.yaml`: `apiVersion: v2`, `name: <project>`, `version: 0.1.0`, `appVersion: latest`
- `_helpers.tpl`: define `<project>.fullname`, `<project>.labels`, `<project>.selectorLabels`
- All variable fields use `{{ .Values.<key> }}` — never hardcode project-specific values

**Values files — one complete file per environment (all live in the app repo root):**

No shared base file. Each environment file is self-contained with the full schema.

`values-dev.yaml` — development (complete):
```yaml
replicaCount: 1
image:
  repository: <image_registry>
  tag: latest
  pullPolicy: IfNotPresent
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "250m"
service:
  type: ClusterIP
  port: <port>
vault:
  address: <vault_address>
apisix:
  subdomain: <subdomain>
tls:
  enabled: false
  certManager:
    enable: true
    clusterIssuer: prd-clusterissuer
    duration: 2160h
    renewBefore: 360h
  existingSecretName: ""
  hosts:
  - <subdomain>.novlok.co
prometheus:
  serviceMonitor:
    enable: true
  prometheusRules:
    enable: true
  grafanaDashboard:
    enable: false
  path: /metrics
  port: http
otel:
  enabled: true
  endpoint: <otel_endpoint>
  protocol: otlp/http
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  autoinstrumentation:
    enable: true
stack: <stack>   # nodejs | java | python | go
autoscaling:
  enabled: false
  type: hpa      # hpa | keda
  minReplicas: 1
  maxReplicas: 10
  cpu:
    targetUtilization: 70
  memory:
    targetUtilization: 80
database:
  cluster:
    enable: false
    instances: 1
    postgresVersion: "16"
    storage:
      size: 1Gi
      storageClass: ""
      resizeInUseVolumes: true
    walStorage:
      enable: false
      size: 2Gi
      storageClass: ""
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 1Gi
    dbName: <project>_db
    dbOwner: <project>_user
    superuser:
      enable: false
    roles:
      enable: false
    tls:
      enable: false
      clusterIssuer: prd-clusterissuer
      caSecretName: ""
    pooler:
      enable: false
      instances: 1
      poolMode: transaction
      maxClientConn: "1000"
      defaultPoolSize: "25"
    backup:
      enable: false
      schedule: "0 0 3 * * *"
      retentionPolicy: 3d
      destinationPath: s3://<bucket>/<project>/backup-pg/
      endpointURL: https://<s3-endpoint>
      credentialsSecretName: <project>-s3-credentials
    monitoring:
      enable: true
    vaultDynamicSecrets:
      enable: false
    migrationRole:
      enable: false
cronJobs:
  enabled: false
  jobs: []
  # - name: quotas
  #   schedule: "0 8 * * *"
  #   path: /api/cron/quotas
```

`values-qua.yaml` — staging/QA (complete, same resource profile as dev):
```yaml
replicaCount: 1
image:
  repository: <image_registry>
  tag: latest
  pullPolicy: IfNotPresent
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "250m"
service:
  type: ClusterIP
  port: <port>
vault:
  address: <vault_address>
apisix:
  subdomain: <subdomain>
tls:
  enabled: false
  certManager:
    enable: true
    clusterIssuer: prd-clusterissuer
    duration: 2160h
    renewBefore: 360h
  existingSecretName: ""
  hosts:
  - <subdomain>.novlok.co
prometheus:
  serviceMonitor:
    enable: true
  prometheusRules:
    enable: true
  grafanaDashboard:
    enable: false
  path: /metrics
  port: http
otel:
  enabled: true
  endpoint: <otel_endpoint>
  protocol: otlp/http
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  autoinstrumentation:
    enable: true
stack: <stack>
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 1
  maxReplicas: 10
  cpu:
    targetUtilization: 70
  memory:
    targetUtilization: 80
database:
  cluster:
    enable: false
    instances: 1
    postgresVersion: "16"
    storage:
      size: 1Gi
      storageClass: ""
      resizeInUseVolumes: true
    walStorage:
      enable: false
      size: 2Gi
      storageClass: ""
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 1Gi
    dbName: <project>_db
    dbOwner: <project>_user
    superuser:
      enable: false
    roles:
      enable: false
    tls:
      enable: false
      clusterIssuer: prd-clusterissuer
      caSecretName: ""
    pooler:
      enable: false
      instances: 1
      poolMode: transaction
      maxClientConn: "1000"
      defaultPoolSize: "25"
    backup:
      enable: false
      schedule: "0 0 3 * * *"
      retentionPolicy: 3d
      destinationPath: s3://<bucket>/<project>/backup-pg/
      endpointURL: https://<s3-endpoint>
      credentialsSecretName: <project>-s3-credentials
    monitoring:
      enable: true
    vaultDynamicSecrets:
      enable: false
    migrationRole:
      enable: false
cronJobs:
  enabled: false
  jobs: []
  # - name: quotas
  #   schedule: "0 8 * * *"
  #   path: /api/cron/quotas
```

`values-prd.yaml` — production (complete, higher resources and replicas):
```yaml
replicaCount: 2
image:
  repository: <image_registry>
  tag: latest
  pullPolicy: IfNotPresent
resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "512Mi"
    cpu: "500m"
service:
  type: ClusterIP
  port: <port>
vault:
  address: <vault_address>
apisix:
  subdomain: <subdomain>
tls:
  enabled: false
  certManager:
    enable: true
    clusterIssuer: prd-clusterissuer
    duration: 2160h
    renewBefore: 360h
  existingSecretName: ""
  hosts:
  - <subdomain>.novlok.co
prometheus:
  serviceMonitor:
    enable: true
  prometheusRules:
    enable: true
  grafanaDashboard:
    enable: false
  path: /metrics
  port: http
otel:
  enabled: true
  endpoint: <otel_endpoint>
  protocol: otlp/http
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  autoinstrumentation:
    enable: true
stack: <stack>
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 20
  cpu:
    targetUtilization: 70
  memory:
    targetUtilization: 80
database:
  cluster:
    enable: false
    instances: 3
    postgresVersion: "16"
    storage:
      size: 10Gi
      storageClass: ""
      resizeInUseVolumes: true
    walStorage:
      enable: false
      size: 20Gi
      storageClass: ""
    resources:
      requests:
        cpu: "1"
        memory: 1Gi
      limits:
        cpu: "1"
        memory: 1Gi
    dbName: <project>_db
    dbOwner: <project>_user
    superuser:
      enable: false
    roles:
      enable: false
    tls:
      enable: false
      clusterIssuer: prd-clusterissuer
      caSecretName: ""
    pooler:
      enable: false
      instances: 2
      poolMode: transaction
      maxClientConn: "1000"
      defaultPoolSize: "25"
    backup:
      enable: false
      schedule: "0 0 3 * * *"
      retentionPolicy: 3d
      destinationPath: s3://<bucket>/<project>/backup-pg/
      endpointURL: https://<s3-endpoint>
      credentialsSecretName: <project>-s3-credentials
    monitoring:
      enable: true
    vaultDynamicSecrets:
      enable: false
    migrationRole:
      enable: false
cronJobs:
  enabled: false
  jobs: []
  # - name: quotas
  #   schedule: "0 8 * * *"
  #   path: /api/cron/quotas
```

The `ApplicationSet` template (Rule 22) points the single source at the chart and the env values file **in the same repo/branch** — no `$values` multi-source ref:
```yaml
source:
  repoURL: "{{ .url }}"
  targetRevision: "{{ .branch }}"   # qua | prd
  path: helm/<project>
  helm:
    valueFiles:
    - ../../values-{{ .branch }}.yaml   # repo root, relative to the chart path
```

- Image tag patching by CI (`update-k8s-tag`) targets `values-<env>.yaml` at the repo root on the current branch: `yq e '.image.tag = "<tag>"' -i values-<env>.yaml`

---

### `kustomize` — Kustomize base + overlays

Output root: `kubernetes/`.

```
kubernetes/
├── base/
│   ├── kustomization.yaml         # lists all resources
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── app/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   ├── pvc.yaml               # if has_persistence
│   │   └── kustomization.yaml
│   ├── database/                  # kind: Component — if has_database (Rule 13)
│   │   ├── imagecatalog.yaml
│   │   ├── cluster.yaml
│   │   ├── database.yaml
│   │   ├── pooler.yaml            # if database.cluster.pooler.enable (Rule 13a)
│   │   ├── backup.yaml            # if database.cluster.backup.enable (Rule 13b)
│   │   ├── podmonitor.yaml        # if database.cluster.monitoring.enable (Rule 13c)
│   │   ├── databaserole.yaml      # if database.cluster.roles.enable (Rule 13e)
│   │   ├── certificate.yaml       # if database.cluster.tls.enable (Rule 13g)
│   │   └── kustomization.yaml
│   ├── apisix/
│   │   ├── route.yaml
│   │   ├── upstream.yaml
│   │   └── kustomization.yaml
│   ├── tls/                       # kind: Component — if tls.enabled (Rule 15)
│   │   ├── certificate.yaml       # omitted if tls.certManager.enable=false
│   │   ├── apisixtls.yaml
│   │   └── kustomization.yaml
│   ├── vault/
│   │   ├── connection.yaml
│   │   ├── auth.yaml
│   │   ├── staticsecret.yaml
│   │   ├── novlok-auth.yaml
│   │   ├── policy.yaml
│   │   ├── role.yaml
│   │   ├── databasemount.yaml     # if vault_dynamic_db_secrets_enable (Rule 16)
│   │   ├── databaseconnection.yaml # if vault_dynamic_db_secrets_enable (Rule 16)
│   │   ├── databaserole.yaml      # if vault_dynamic_db_secrets_enable (Rule 16)
│   │   ├── dynamicsecret.yaml     # if vault_dynamic_db_secrets_enable (Rule 16)
│   │   └── kustomization.yaml
│   ├── cilium/
│   │   ├── networkpolicy.yaml
│   │   └── kustomization.yaml
│   ├── prometheus/
│   │   ├── servicemonitor.yaml
│   │   ├── grafana-dashboard.yaml # if prometheus.grafanaDashboard.enable (Rule 18)
│   │   └── kustomization.yaml
│   ├── otel/
│   │   ├── instrumentation.yaml
│   │   └── kustomization.yaml
│   ├── alertmanager/
│   │   ├── prometheusrule.yaml
│   │   └── kustomization.yaml
│   ├── autoscaling/
│   │   ├── autoscaling.yaml
│   │   └── kustomization.yaml
│   ├── cron/                      # if has_scheduled_tasks (Rule 17)
│   │   ├── cronjob-<job_name>.yaml
│   │   └── kustomization.yaml
│   └── cloudflare/
│       ├── record.yaml
│       └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patches/
    │       └── replicas.yaml
    ├── qua/
    │   ├── kustomization.yaml
    │   └── patches/
    │       └── replicas.yaml
    └── prd/
        ├── kustomization.yaml
        └── patches/
            └── replicas.yaml
```

**Kustomize conventions:**

- `base/kustomization.yaml` lists every resource file across all sub-directories
- Each overlay `kustomization.yaml` references `../../base` and applies env patches:

```yaml
# overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
patches:
- path: patches/replicas.yaml
images:
- name: <image_registry>
  newTag: latest   # patched by CI update-k8s-tag job
```

- `patches/replicas.yaml` sets replica count per environment (dev: 1, qua: 1, prd: 2+)
- Image tag patching by CI (`update-k8s-tag`) targets the overlay `kustomization.yaml`: `kustomize edit set image <registry>=<registry>:<tag>`
- ArgoCD: the `ApplicationSet` template (Rule 22) sets the app-cluster source to `path: kubernetes/overlays/<branch>` on the same repo/branch — single-source, no chart repo in this mode

---

### `argocd/` and `ops/` — repo-root, format-independent

Both directories sit at the **mono-repo root** (siblings of `helm/` / `kubernetes/`), plain YAML, identical for both `output_format` values. Values are substituted at generation time (`<project>`, `<ops_namespace>`, `<ops_cluster_name>`, `<gitlab_group>`).

```
argocd/
├── repo-creds.yaml                     # ArgoCD repo-creds Secret for the GitLab group (Rule 4)
└── applicationset.yaml                 # consolidated app+ops ApplicationSet (Rule 22)
ops/
├── alertmanagerconfig-<project>.yaml   # if alertmanager_config_enable (Rule 20)
└── loki-rules-<project>.yaml           # if loki_rules_enable (Rule 21)
```

- `argocd/repo-creds.yaml` and `argocd/applicationset.yaml` are **always generated** (they carry the whole delivery model); `ops/*` files only when their enable input is set.
- Delivery: `argocd/*` is applied to the app-cluster `argocd` namespace by the `apply-argocd` CI job (Rule 8). The `ApplicationSet` then produces per-`(repo, branch)` app-cluster and ops-cluster `Application`s (Rule 22).
- `ops/**/*` is excluded from CI (`workflow.rules`, Rule 8) so rule edits don't trigger a build. `argocd/**/*` triggers only `apply-argocd`.

---

## 12. Autoscaling — HPA or KEDA

Controlled by `autoscaling.enabled` and `autoscaling.type` in `values.yaml`.  
When enabled, `replicaCount` is used only as the initial replica count — the autoscaler takes over.

---

### `hpa` — Kubernetes HorizontalPodAutoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: <service>-hpa
  namespace: <project>
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <service>
  minReplicas: 1    # from autoscaling.minReplicas
  maxReplicas: 10   # from autoscaling.maxReplicas
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70   # from autoscaling.cpu.targetUtilization
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80   # from autoscaling.memory.targetUtilization
```

---

### `keda` — KEDA ScaledObject

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: <service>-scaledobject
  namespace: <project>
spec:
  scaleTargetRef:
    name: <service>
  minReplicaCount: 1    # from autoscaling.minReplicas
  maxReplicaCount: 10   # from autoscaling.maxReplicas
  triggers:
  - type: cpu
    metricType: Utilization
    metadata:
      value: "70"   # from autoscaling.cpu.targetUtilization
  - type: memory
    metricType: Utilization
    metadata:
      value: "80"   # from autoscaling.memory.targetUtilization
```

> **Prerequisites:**
> - `hpa`: metrics-server must be running (`kubectl get deployment metrics-server -n kube-system`)
> - `keda`: KEDA operator must be running (`kubectl get pods -n keda`)

**values.yaml autoscaling schema:**

```yaml
autoscaling:
  enabled: false
  type: hpa      # hpa | keda
  minReplicas: 1
  maxReplicas: 10
  cpu:
    targetUtilization: 70
  memory:
    targetUtilization: 80
```

**Helm template conditional:**

The autoscaling file is always generated. `autoscaling.type` selects which autoscaler is rendered; `autoscaling.enabled` in `values.yaml` is available for runtime documentation but does not gate the template.

```yaml
{{- if eq .Values.autoscaling.type "hpa" }}
# HPA manifest
{{- else if eq .Values.autoscaling.type "keda" }}
# ScaledObject manifest
{{- end }}
```

---

## 10. Deployment security context

Every generated `Deployment` must include the following security hardening. These defaults follow the Kubernetes restricted Pod Security Standard.

```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: <service>
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
```

Exceptions:
- `readOnlyRootFilesystem: false` — only if the process requires writing to the local filesystem at runtime (e.g., temp files, Prisma engine). Document the reason in a comment.
- `runAsUser` — override per stack if the base image enforces a different UID (e.g., `node:24-alpine` uses UID 1000 by default; align with the Dockerfile `USER` directive).

### Rollout strategy (zero-downtime rollouts and secret-rotation restarts)

Every generated `Deployment` also gets this `strategy` block, unconditionally — it is harmless at `replicaCount: 1` (the rollout briefly runs a second pod, then scales the old one down) and is a prerequisite for the `rolloutRestartTargets` wiring used by Vault Dynamic Secrets (Rule 16):

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
```

> **Note:** only guarantees zero downtime when `replicas >= 2`. Dev environments typically run `replicaCount: 1` — mention this caveat in the output summary whenever `has_database=true` and `vault_dynamic_db_secrets_enable=true` but the target environment's `replicaCount` is `1`.

---

---

## 13. Database — CloudNativePG (CNPG)

Generated only when `has_database = true` (see Step 1 detection in the skill).
Operator: **CloudNativePG**, API group: `postgresql.cnpg.io/v1`

> **Prerequisite:** CNPG operator must be running in the cluster. Verify: `kubectl get pods -n cnpg-system`
> The `Database` CR requires CNPG v1.22+. Verify: `kubectl get crd databases.postgresql.cnpg.io`

### Detection patterns (Step 1 — before asking the user)

Scan the project for database indicators and set `has_database = true` if any match:

| File | Patterns |
|------|----------|
| `.env*` | `DATABASE_URL=`, `DB_HOST=`, `DB_NAME=`, `POSTGRES_*=`, `PG_*=` |
| `package.json` | `dependencies` or `devDependencies`: `pg`, `sequelize`, `prisma`, `typeorm`, `knex`, `drizzle-orm` |
| `go.mod` | `gorm.io/gorm`, `github.com/lib/pq`, `github.com/jackc/pgx` |
| `pom.xml` / `build.gradle` | `spring-data-jpa`, `spring-boot-starter-data-jpa`, `postgresql` |
| `requirements.txt` / `pyproject.toml` | `psycopg2`, `asyncpg`, `SQLAlchemy`, `databases` |

Always confirm the detected result with the user. If nothing is detected, ask explicitly: "Does this project connect to a PostgreSQL database?"

If `has_database = true`, ask:
- `db_name` — database name (default: `<project>_db`)
- `postgres_version` — PostgreSQL version (default: `16`)

### ImageCatalog CR

Namespaced (not `ClusterImageCatalog` — see Rule 13d), so it's scoped to this project alone and carries no cross-project collision risk. Generated automatically alongside the Cluster/Database CRs below.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ImageCatalog
metadata:
  name: <project>-postgresql
  namespace: <project>
spec:
  images:
    - major: 16                                        # helm: {{ .Values.database.cluster.postgresVersion | int }}
      image: ghcr.io/cloudnative-pg/postgresql:16       # helm: ghcr.io/cloudnative-pg/postgresql:{{ .Values.database.cluster.postgresVersion }}
      # add another `- major: <n>` entry here for future Postgres major-version upgrades
```

### Cluster CR

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <project>-db
  namespace: <project>
spec:
  instances: 1                                        # helm: {{ .Values.database.cluster.instances }}
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ImageCatalog
    name: <project>-postgresql
    major: 16                                         # helm: {{ .Values.database.cluster.postgresVersion | int }}
  storage:
    size: 1Gi                                         # helm: {{ .Values.database.cluster.storage.size }}
  bootstrap:
    initdb:
      database: <project>_db                          # helm: {{ .Values.database.cluster.dbName }}
      owner: <project>_user                           # helm: {{ .Values.database.cluster.dbOwner }}
      secret:
        name: <project>-db-credentials
```

> `bootstrap.initdb.secret` must be a pre-existing Kubernetes `Secret` in the project namespace with keys `username` and `password`. Route it through Vault (VaultStaticSecret) if the project uses Vault for secrets; otherwise document it as a manual prerequisite in the output summary.

### Cluster CR — advanced/production fields (opt-in)

The base Cluster CR above is the safe minimum. Each block below is additive, independently gated by its own `values.yaml` key (default `false` unless noted), and only rendered when enabled — a project that leaves everything off gets exactly the base CR above, no behavior change.

**Superuser access** — gated `database.cluster.superuser.enable` (default `false`):
```yaml
spec:
  enableSuperuserAccess: true
  superuserSecret:
    name: <project>-db-superuser     # pre-existing Secret, keys username/password — same conventions as bootstrap.initdb.secret
```

**Storage tuning** — `resizeInUseVolumes` always rendered (`true`, no gate); `storageClass` asked at runtime or defaults to the cluster's default StorageClass:
```yaml
spec:
  storage:
    size: 1Gi                                          # helm: {{ .Values.database.cluster.storage.size }}
    storageClass: <storage_class>                      # helm: {{ .Values.database.cluster.storage.storageClass }}
    resizeInUseVolumes: true
```

**Separate WAL volume** — gated `database.cluster.walStorage.enable` (default `false`):
```yaml
spec:
  walStorage:
    size: 2Gi                                          # helm: {{ .Values.database.cluster.walStorage.size }}
    storageClass: <storage_class>                      # helm: {{ .Values.database.cluster.walStorage.storageClass }}
    resizeInUseVolumes: true
```

**Resources** — always rendered with sensible defaults (`database.cluster.resources.*`):
```yaml
spec:
  resources:
    requests:
      cpu: 500m                                        # helm: {{ .Values.database.cluster.resources.requests.cpu }}
      memory: 512Mi                                     # helm: {{ .Values.database.cluster.resources.requests.memory }}
    limits:
      cpu: "1"                                          # helm: {{ .Values.database.cluster.resources.limits.cpu }}
      memory: 1Gi                                       # helm: {{ .Values.database.cluster.resources.limits.memory }}
```

**PostgreSQL tuning parameters** — always rendered with a safe baseline; two entries are conditional:
```yaml
spec:
  postgresql:
    parameters:
      shared_buffers: 256MB
      max_wal_size: 1GB
      wal_level: logical
      dynamic_shared_memory_type: posix
      log_destination: csvlog
      logging_collector: "on"
      shared_preload_libraries: ""                     # see note below
```
> If `database.cluster.monitoring.enable = true` (Rule 13c), append `pg_stat_statements` to `shared_preload_libraries` and add `pg_stat_statements.max: "10000"` / `pg_stat_statements.track: all` to `parameters`. Never enable `pg_stat_statements.*` parameters while `shared_preload_libraries` is empty — the extension will not load and the settings are inert (a real misconfiguration found in production).
> If `database.cluster.tls.enable = true` (Rule 13g below), add `ssl_min_protocol_version: TLSv1.3` / `ssl_max_protocol_version: TLSv1.3` to `parameters`.

**High availability (only when `instances > 1`)**:
```yaml
spec:
  enablePDB: true
  primaryUpdateStrategy: unsupervised
  minSyncReplicas: 1                                   # helm: {{ .Values.database.cluster.minSyncReplicas }}
  maxSyncReplicas: 1                                    # helm: {{ .Values.database.cluster.maxSyncReplicas }}
  replicationSlots:
    highAvailability:
      enabled: true
```
`enablePDB` defaults to `true` whenever `instances > 1`; omit entirely for single-instance clusters (a PDB with one instance blocks all voluntary disruption).

### Database CR (CNPG v1.22+)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: <project>-db-<dbname>                        # e.g. myapp-db-myapp_db
  namespace: <project>
spec:
  name: <project>_db                                 # helm: {{ .Values.database.cluster.dbName }}
  owner: <project>_user                              # helm: {{ .Values.database.cluster.dbOwner }}
  cluster:
    name: <project>-db
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/database/imagecatalog.yaml`, `helm/templates/database/cluster.yaml`, `helm/templates/database/database.yaml` |
| `kustomize` | `kubernetes/base/database/imagecatalog.yaml`, `kubernetes/base/database/cluster.yaml`, `kubernetes/base/database/database.yaml`, `kubernetes/base/database/kustomization.yaml` |

### Helm — enable/disable

Wrap all three CRs in a single conditional:

```yaml
{{- if .Values.database.cluster.enable }}
# ImageCatalog CR here
---
# Cluster CR here
---
# Database CR here
{{- end }}
```

**values.yaml schema** (all three env files — default `enable: false`; user opts in per environment):

| Key | dev | qua | prd |
|-----|-----|-----|-----|
| `database.cluster.enable` | `false` | `false` | `false` |
| `database.cluster.instances` | `1` | `1` | `3` |
| `database.cluster.storage.size` | `1Gi` | `1Gi` | `10Gi` |
| `database.cluster.postgresVersion` | `"16"` | `"16"` | `"16"` |
| `database.cluster.dbName` | `<project>_db` | `<project>_db` | `<project>_db` |
| `database.cluster.dbOwner` | `<project>_user` | `<project>_user` | `<project>_user` |

### Kustomize — enable/disable via Component

`kubernetes/base/database/kustomization.yaml` must use `kind: Component` so overlays can opt in selectively:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
- imagecatalog.yaml
- cluster.yaml
- database.yaml
# - pooler.yaml       # remove this entry if the pooler is not needed (Rule 13a)
# - backup.yaml       # remove this entry if scheduled backups are not needed (Rule 13b)
# - podmonitor.yaml   # remove this entry if Postgres metrics scraping is not needed (Rule 13c)
# - databaserole.yaml # remove this entry if declarative role management is not needed (Rule 13e)
# - certificate.yaml  # remove this entry if internal TLS is not needed (Rule 13g)
```

The top-level `kubernetes/base/kustomization.yaml` does **not** reference the database component.

Each overlay `kustomization.yaml` gets a commented-out opt-in block:

```yaml
# components:
# - ../../base/database   # uncomment to enable CNPG database cluster in this environment
```

> Kustomize components require kustomize v4.1.0+ or `kubectl` v1.21+.

---

## 13a. Pooler (PgBouncer connection pooling)

Generated only when `database.cluster.enable = true` **and** `database.cluster.pooler.enable = true` (default `false` in all three env files).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: <project>-pg-pooler-rw
  namespace: <project>
spec:
  cluster:
    name: <project>-pg
  instances: 1                 # helm: {{ .Values.database.cluster.pooler.instances }}
  type: rw
  pgbouncer:
    poolMode: transaction      # helm: {{ .Values.database.cluster.pooler.poolMode }}
    parameters:
      max_client_conn: "1000"  # helm: {{ .Values.database.cluster.pooler.maxClientConn | quote }}
      default_pool_size: "25"  # helm: {{ .Values.database.cluster.pooler.defaultPoolSize | quote }}
```

Helm wraps this CR in `{{- if and .Values.database.cluster.enable .Values.database.cluster.pooler.enable }} ... {{- end }}`.

**values.yaml schema addition** (inside `database.cluster`, default `enable: false` in all three env files):

```yaml
pooler:
  enable: false
  instances: 1
  poolMode: transaction
  maxClientConn: "1000"
  defaultPoolSize: "25"
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/database/pooler.yaml` |
| `kustomize` | `kubernetes/base/database/pooler.yaml` (listed in the database Component, see comment above) |

---

## 13b. ScheduledBackup + ObjectStore (Barman Cloud Plugin)

Generated only when `database.cluster.backup.enable = true` (default `false`). Requires an S3-compatible bucket and a pre-existing Secret with credentials — document as a manual prerequisite in the output summary, same style as the existing `<project>-db-credentials` note in Rule 13.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: <project>-pg-store
  namespace: <project>
spec:
  retentionPolicy: 3d                       # helm: {{ .Values.database.cluster.backup.retentionPolicy }}
  configuration:
    destinationPath: s3://<bucket>/<project>/backup-pg/   # helm: {{ .Values.database.cluster.backup.destinationPath }}
    endpointURL: https://<s3-endpoint>       # helm: {{ .Values.database.cluster.backup.endpointURL }}
    s3Credentials:
      accessKeyId:
        key: ACCESS_KEY_ID
        name: <project>-s3-credentials       # helm: {{ .Values.database.cluster.backup.credentialsSecretName }}
      secretAccessKey:
        key: ACCESS_SECRET_KEY
        name: <project>-s3-credentials
    data:
      compression: gzip
      immediateCheckpoint: false
    wal:
      compression: gzip
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: <project>-pg-backup
  namespace: <project>
spec:
  schedule: "0 0 3 * * *"          # helm: {{ .Values.database.cluster.backup.schedule | quote }}
  cluster:
    name: <project>-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  backupOwnerReference: cluster
  immediate: true
```

Helm wraps both CRs in `{{- if and .Values.database.cluster.enable .Values.database.cluster.backup.enable }} ... {{- end }}`.

**Cluster CR addition** — when `backup.enable = true`, also add this block to the base Cluster CR template (Rule 13):

```yaml
spec:
  backup:
    target: prefer-standby
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: <project>-pg-store
      serverName: <project>-pg
```

**values.yaml schema addition** (inside `database.cluster`, default `enable: false` in all three env files):

```yaml
backup:
  enable: false
  schedule: "0 0 3 * * *"
  retentionPolicy: 3d
  destinationPath: s3://<bucket>/<project>/backup-pg/
  endpointURL: https://<s3-endpoint>
  credentialsSecretName: <project>-s3-credentials
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/database/backup.yaml` |
| `kustomize` | `kubernetes/base/database/backup.yaml` (listed in the database Component, see comment above) |

---

## 13c. PodMonitor (Postgres metrics — Prometheus Operator)

Distinct from the app's `ServiceMonitor` (Rule 3a) — this is CNPG's own recommended way to scrape Postgres instance metrics. Default `database.cluster.monitoring.enable = true` (cheap, no real cost, consistent with the "observability on by default" convention already used for `prometheus.serviceMonitor.enable`). Generated only when `database.cluster.enable = true`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: <project>-pg
  namespace: <project>
  labels:
    app.kubernetes.io/component: database
    app.kubernetes.io/instance: <project>-pg
    app.kubernetes.io/managed-by: cloudnative-pg
    app.kubernetes.io/name: postgresql
    cnpg.io/cluster: <project>-pg
spec:
  namespaceSelector: {}
  podMetricsEndpoints:
  - port: metrics
  selector:
    matchLabels:
      cnpg.io/cluster: <project>-pg
      cnpg.io/podRole: instance
```

Helm wraps this CR in `{{- if and .Values.database.cluster.enable .Values.database.cluster.monitoring.enable }} ... {{- end }}`.

> **Consistency rule:** whenever this standalone `PodMonitor` is generated (`database.cluster.monitoring.enable = true`), the Cluster CR's own `spec.monitoring.enablePodMonitor` must be set to `false`. CNPG can generate its own PodMonitor from that field — leaving both active produces two PodMonitors scraping the same targets (a duplicate-scrape misconfiguration found in production). Add `enablePodMonitor: false` under `spec.monitoring` in the base Cluster CR (Rule 13) whenever this rule is active.

**values.yaml schema addition** (inside `database.cluster`, default `enable: true` in all three env files):

```yaml
monitoring:
  enable: true
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/database/podmonitor.yaml` |
| `kustomize` | `kubernetes/base/database/podmonitor.yaml` (listed in the database Component, see comment above) |

---

## 13d. Note — ClusterImageCatalog (documented, not generated)

`ClusterImageCatalog` (`postgresql.cnpg.io/v1`) is **cluster-scoped** and meant to be shared by every CNPG cluster in a multi-tenant cluster — generating one per project would be wrong and would create naming collisions/duplication across projects. The plugin does not generate it, and assumes one is provisioned out-of-band at the cluster level if a project wants to reference a shared, cluster-wide catalog instead of its own per-project one.

The namespaced `ImageCatalog` kind is a different story — it's scoped to the project's own namespace, so it carries none of the collision risk above. It **is** generated by default (see the ImageCatalog CR template in Rule 13), with `Cluster.spec.imageCatalogRef` wired to it instead of the older `spec.imageName` shorthand. This is the only thing left that changed here: `imageName` is no longer the default, `imageCatalogRef` → per-project `ImageCatalog` is.

---

## 13e. `DatabaseRole` — declarative Postgres role management (CNPG)

> **Naming note:** this is `postgresql.cnpg.io/v1 DatabaseRole` — CNPG's own CR for managing Postgres roles declaratively. Do not confuse with the `vault.infra.novlok.com/v1 DatabaseRole` generated by Rule 16, which configures a role inside Vault's `database` secrets engine. Always spell out the full `apiVersion` when referring to either in generated output or documentation.

Generated only when `database.cluster.roles.enable = true` (default `false`) and `has_database = true`. Replaces ad-hoc role management with two declarative `DatabaseRole` CRs:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: <project>_user                                # same as bootstrap.initdb.owner (Rule 13)
  namespace: <project>
spec:
  cluster:
    name: <project>-db
  name: <project>_user
  ensure: present
  login: true
  superuser: false                                     # helm: {{ .Values.database.cluster.superuser.enable }}
  createrole: false                                     # helm: {{ .Values.database.cluster.superuser.enable }} — true only if Vault dynamic secrets (Rule 16) need this role to create/drop other roles
  passwordSecret:
    name: <project>-db-credentials                     # same secret as bootstrap.initdb.secret (Rule 13)
  databaseRoleReclaimPolicy: retain                     # never delete the bootstrap owner
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: migration-role-<project>
  namespace: <project>
spec:
  cluster:
    name: <project>-db
  name: migration-role-<project>
  ensure: present
  login: true
  superuser: false
  databaseRoleReclaimPolicy: delete                     # safe to reclaim — not the bootstrap owner
```

Helm wraps both CRs in `{{- if and .Values.database.cluster.enable .Values.database.cluster.roles.enable }} ... {{- end }}`.

**values.yaml schema addition** (inside `database.cluster`, default `enable: false` in all three env files):

```yaml
roles:
  enable: false
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/database/databaserole.yaml` |
| `kustomize` | `kubernetes/base/database/databaserole.yaml` (listed in the database Component, see Rule 13) |

---

## 13g. TLS (cert-manager Certificate — CNPG internal traffic)

Generated only when `database.cluster.tls.enable = true` (default `false`). Distinct from Rule 15 (APISIX ingress TLS) — this secures traffic between the app, the Pooler (Rule 13a), and the CNPG instances themselves, wired via `Cluster.spec.certificates` (see Rule 13's advanced fields).

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: <project>-db-cert
  namespace: <project>
spec:
  secretName: <project>-db-cert
  usages:
  - server auth
  dnsNames:
  - <project>-db-rw
  - <project>-db-rw.<project>
  - <project>-db-rw.<project>.svc
  - <project>-db-rw.<project>.svc.cluster.local
  - <project>-db-r
  - <project>-db-r.<project>
  - <project>-db-r.<project>.svc
  - <project>-db-r.<project>.svc.cluster.local
  - <project>-db-ro
  - <project>-db-ro.<project>
  - <project>-db-ro.<project>.svc
  - <project>-db-ro.<project>.svc.cluster.local
  # Add pooler DNS names below only if database.cluster.pooler.enable = true (Rule 13a):
  - <project>-pg-pooler-rw
  - <project>-pg-pooler-rw.<project>
  - <project>-pg-pooler-rw.<project>.svc
  - <project>-pg-pooler-rw.<project>.svc.cluster.local
  issuerRef:
    name: <cluster_issuer>                              # helm: {{ .Values.database.cluster.tls.clusterIssuer }} — ask at runtime
    kind: ClusterIssuer
    group: cert-manager.io
```

**Cluster CR wiring** (add to `spec.certificates` in Rule 13's Cluster CR):
```yaml
spec:
  certificates:
    serverTLSSecret: <project>-db-cert
    serverCASecret: <ca_secret>                         # helm: {{ .Values.database.cluster.tls.caSecretName }} — pre-existing, shared cluster-wide CA, out of scope for this plugin to generate
```

> **Prerequisite:** cert-manager must be running with the named `ClusterIssuer` already configured, and the CA Secret referenced by `serverCASecret` must already exist in the project namespace (shared/copied from a cluster-wide CA — provisioning that copy is out of scope for this plugin). Flag both in the output summary if unconfirmed.

**Pooler wiring** (add to `spec.pgbouncer` in Rule 13a's Pooler CR, only if both `database.cluster.pooler.enable` and `database.cluster.tls.enable` are `true`):
```yaml
spec:
  pgbouncer:
    serverTLSSecret: <project>-db-cert
    serverCASecret: <ca_secret>
```
> A Pooler generated without this block while `database.cluster.tls.enable = true` leaves PgBouncer↔Postgres traffic unencrypted despite the Cluster itself being TLS-configured — a real gap found in production. Always add it when both flags are on.

**values.yaml schema addition** (inside `database.cluster`, default `enable: false` in all three env files):

```yaml
tls:
  enable: false
  clusterIssuer: prd-clusterissuer      # ask at runtime
  caSecretName: ""                      # ask at runtime — pre-existing shared CA secret
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/database/certificate.yaml` |
| `kustomize` | `kubernetes/base/database/certificate.yaml` (listed in the database Component, see Rule 13) |

---

## 14. Application Persistent Storage (PVC)

Generated only when `has_persistence = true` (see Step 1 detection in the skill).

### Detection patterns (Step 1 — before asking the user)

Scan for indicators that the application writes files that must survive pod restarts:

| File | Patterns |
|------|----------|
| `package.json` | `dependencies` or `devDependencies`: `multer`, `formidable`, `busboy`, `better-sqlite3`, `sqlite3` |
| `requirements.txt` / `pyproject.toml` | `python-multipart`, `aiofiles`, `sqlite`, `pysqlite` |
| `pom.xml` / `build.gradle` | `commons-fileupload`, `multipart` |
| `go.mod` | `mime/multipart` |
| `.env*` | Values matching `UPLOAD_PATH=`, `STORAGE_PATH=`, `DATA_DIR=`, `FILE_PATH=`, `UPLOAD_DIR=` |

Always confirm the detected result with the user. If nothing is detected, ask explicitly: "Does this application write files to disk that must persist across pod restarts?"

If `has_persistence = true`, ask:
- `persistence_mount_path` — mount path inside the container (default: `/data`)
- `persistence_size` — PVC storage size (default: `1Gi`)

### PVC template

**Helm** (`helm/templates/app/pvc.yaml`):

```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "<project>.fullname" . }}-pvc
  namespace: {{ .Release.Namespace }}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
  storageClassName: {{ .Values.persistence.storageClassName }}
{{- end }}
```

**Kustomize** (`kubernetes/base/app/pvc.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <project>-<service>-pvc
  namespace: <project>
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi           # override per env via kustomize patch if needed
  storageClassName: standard
```

### Deployment additions

Add to every Deployment when `has_persistence = true`. Insert `volumeMounts` after the container `securityContext` block and `volumes` after the `containers` list.

**Helm:**

```yaml
spec:
  template:
    spec:
      containers:
      - name: <service>
        # ... existing fields ...
        volumeMounts:
        {{- if .Values.persistence.enabled }}
        - name: data
          mountPath: {{ .Values.persistence.mountPath }}
        {{- end }}
      {{- if .Values.persistence.enabled }}
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: {{ include "<project>.fullname" . }}-pvc
      {{- end }}
```

**Kustomize:**

```yaml
spec:
  template:
    spec:
      containers:
      - name: <service>
        # ... existing fields ...
        volumeMounts:
        - name: data
          mountPath: /data    # persistence_mount_path from runtime input
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: <project>-<service>-pvc
```

### values.yaml persistence schema

Add to all three env files (default `enabled: false`; user opts in per environment):

```yaml
persistence:
  enabled: false
  size: 1Gi                  # persistence_size from runtime input
  storageClassName: standard
  mountPath: /data           # persistence_mount_path from runtime input
```

> **Note:** `readOnlyRootFilesystem: true` is compatible with PVC mounts — the mounted volume is writable regardless of the root filesystem restriction. `fsGroup: 1001` in the pod security context (Rule 10) ensures the PVC is owned by the app's GID at mount time.

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/app/pvc.yaml` |
| `kustomize` | `kubernetes/base/app/pvc.yaml` (add to `kubernetes/base/app/kustomization.yaml`) |

---

## 15. TLS (cert-manager Certificate + ApisixTls)

Generated only when `tls.enabled = true` (default `false` — preserves current HTTP-only behavior). Extends Rule 5 (APISIX) with HTTPS termination; kept as its own rule because it involves a second operator (cert-manager).

Two sub-modes, controlled by `tls.certManager.enable`:

| `tls.certManager.enable` | Behavior |
|---|---|
| `true` (default when `tls.enabled=true`) | Plugin generates a cert-manager `Certificate` CR; `ApisixTls` references the Secret it produces (`<project>-tls-secret`). |
| `false` | No `Certificate` CR generated — the project reuses a certificate that already exists in the cluster. `ApisixTls` references `tls.existingSecretName` directly. |

> **Prerequisite (cert-manager mode):** cert-manager must be running with a `ClusterIssuer` already configured. Verify: `kubectl get clusterissuer`.
> **Prerequisite (existing-secret mode):** the named Secret (`tls.existingSecretName`) must already exist in the project namespace, of type `kubernetes.io/tls`.

### Certificate CR (cert-manager, only if `tls.certManager.enable = true`)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: <project>-certificate
  namespace: <project>
spec:
  secretName: <project>-tls-secret
  commonName: <subdomain>.novlok.co        # helm: {{ .Values.apisix.subdomain }}.novlok.co
  dnsNames:
  - <subdomain>.novlok.co                  # helm: {{- range .Values.tls.hosts }} - {{ . | quote }} {{- end }}
  duration: 2160h                          # helm: {{ .Values.tls.certManager.duration }}
  renewBefore: 360h                        # helm: {{ .Values.tls.certManager.renewBefore }}
  privateKey:
    rotationPolicy: Always
  issuerRef:
    name: <cluster_issuer>                 # helm: {{ .Values.tls.certManager.clusterIssuer }} — ask at runtime
    kind: ClusterIssuer
    group: cert-manager.io
```

Helm wraps this CR in `{{- if and .Values.tls.enabled .Values.tls.certManager.enable }} ... {{- end }}`.

### ApisixTls CR (always, if `tls.enabled = true`)

```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixTls
metadata:
  name: <project>-tls
  namespace: <project>
spec:
  hosts:
  - <subdomain>.novlok.co                  # helm: {{- range .Values.tls.hosts }} - {{ . | quote }} {{- end }} — must match ApisixRoute match.hosts (Rule 5)
  secret:
    name: <project>-tls-secret             # if certManager.enable=false: {{ .Values.tls.existingSecretName }}
    namespace: <project>
```

Helm wraps this CR in `{{- if .Values.tls.enabled }} ... {{- end }}`; the `secret.name` value is chosen with:
```yaml
secret:
  name: {{ if .Values.tls.certManager.enable }}{{ include "<project>.fullname" . }}-tls-secret{{ else }}{{ .Values.tls.existingSecretName }}{{ end }}
  namespace: {{ .Release.Namespace }}
```

### values.yaml schema (all three env files — default `enabled: false`)

```yaml
tls:
  enabled: false
  certManager:
    enable: true
    clusterIssuer: prd-clusterissuer   # ask at runtime
    duration: 2160h
    renewBefore: 360h
  existingSecretName: ""              # used only when certManager.enable=false
  hosts:
  - <subdomain>.novlok.co             # keep in sync with ApisixRoute match.hosts (Rule 5)
```

### Kustomize — enable/disable via Component

`kubernetes/base/tls/kustomization.yaml` must use `kind: Component` (same pattern as Rule 13's database Component):

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
- certificate.yaml   # omit this line entirely if reusing an existing certificate (certManager.enable=false)
- apisixtls.yaml
```

The top-level `kubernetes/base/kustomization.yaml` does **not** reference the `tls` component. Each overlay gets a commented-out opt-in block:

```yaml
# components:
# - ../../base/tls   # uncomment to enable TLS termination in this environment
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/tls/certificate.yaml`, `helm/templates/tls/apisixtls.yaml` |
| `kustomize` | `kubernetes/base/tls/certificate.yaml`, `kubernetes/base/tls/apisixtls.yaml`, `kubernetes/base/tls/kustomization.yaml` (kind: Component) |

---

## 16. Vault Dynamic Secrets (database credentials) + zero-downtime rollout

Scope: **specifically for CNPG database credentials** via Vault's `database` secrets engine — not a generic replacement for `VaultStaticSecret` (Rule 2), which remains the default for all other confidential secrets. Generated only when `has_database = true` and `vault_dynamic_db_secrets_enable = true` (default `false`).

> **Naming note:** the CRs below are `vault.infra.novlok.com/v1 DatabaseMount`/`DatabaseConnection`/`DatabaseRole` — the novlok-operator's own Vault `database` secrets engine management. Do not confuse `DatabaseRole` here with `postgresql.cnpg.io/v1 DatabaseRole` (Rule 13e), which manages Postgres roles inside the CNPG cluster itself. Always spell out the full `apiVersion` when referring to either.

### Provisioning the Vault `database` secrets engine (novlok-operator)

Unlike the Rule 2 KV-mount gap (no generic CR exists there), novlok-operator **does** ship CRDs for the `database` secrets engine — `DatabaseMount`, `DatabaseConnection`, `DatabaseRole` (all `vault.infra.novlok.com/v1`, namespaced). Generate all three instead of assuming out-of-band provisioning:

```yaml
apiVersion: vault.infra.novlok.com/v1
kind: DatabaseMount
metadata:
  name: <project>-db-mount
  namespace: <project>
spec:
  mountPath: database                    # shared path across projects — idempotent, same pattern as the Rule 2 KV mount
  vaultAuthRef: <project>-novlok-auth     # reuses the novlok-operator VaultAuth already generated in Rule 2
---
apiVersion: vault.infra.novlok.com/v1
kind: DatabaseConnection
metadata:
  name: <project>-db-connection
  namespace: <project>
spec:
  databaseMountRef: <project>-db-mount
  pluginName: postgresql-database-plugin
  connectionURL: "postgresql://{{username}}:{{password}}@<project>-db-rw.<project>.svc.cluster.local:5432/<db_name>"   # helm: {{ .Values.database.cluster.dbName }}
  credentialsSecretRef:
    name: <project>-db-credentials        # same privileged secret as bootstrap.initdb.secret (Rule 13) / passwordSecret (Rule 13e owner role) — must have createrole:true if the dynamic role below needs to create/drop other roles
    namespace: <project>
  allowedRoles:
  - <project>
  - migration-role-<project>
  verifyConnection: true
---
apiVersion: vault.infra.novlok.com/v1
kind: DatabaseRole
metadata:
  name: <project>                         # Vault role name — exposed at creds/<project>, matching VaultDynamicSecret.spec.path below
  namespace: <project>
spec:
  databaseConnectionRef: <project>-db-connection
  roleType: dynamic
  dynamic:
    creationStatements:
    - "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';"
    - "GRANT ALL PRIVILEGES ON SCHEMA public TO \"{{name}}\";"
    - "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
    - "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";"
    revocationStatements:
    - "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";"
    - "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\";"
    - "REVOKE ALL PRIVILEGES ON SCHEMA public FROM \"{{name}}\";"
    - "DROP ROLE \"{{name}}\";"
    defaultTTL: 1h
    maxTTL: 24h
```

Helm wraps all three CRs in `{{- if and .Values.database.cluster.enable .Values.database.cluster.vaultDynamicSecrets.enable }} ... {{- end }}`.

**Optional static role** — gated `database.cluster.migrationRole.enable` (default `false`), for CI/migration jobs that need a stable (non-rotating-on-every-request) user, e.g. `migration-role-<project>` created by Rule 13e's app `DatabaseRole`:

```yaml
apiVersion: vault.infra.novlok.com/v1
kind: DatabaseRole
metadata:
  name: migration-role-<project>          # exposed at static-creds/migration-role-<project>
  namespace: <project>
spec:
  databaseConnectionRef: <project>-db-connection
  roleType: static
  static:
    username: migration-role-<project>    # must already exist as a Postgres role — see Rule 13e
    rotationPeriod: 3600
```

### VaultDynamicSecret CR (consumes the role above)

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: <project>-database-secret
  namespace: <project>
spec:
  destination:
    create: true
    name: db-<project>-secret
    overwrite: false
  mount: database
  path: creds/<project>
  vaultAuthRef: <project>-vault-auth      # reuses the vault-secrets-operator VaultAuth already generated in Rule 2
  rolloutRestartTargets:
  - kind: Deployment
    name: <service>                      # one entry per service that connects to the database
```

Helm wraps this CR in the same conditional as above, with one `rolloutRestartTargets` entry per service via `{{- range .Values.services }}`.

### App env wiring (Deployment)

Not optional — without this, `db-<project>-secret` is created but never reaches the app container. Add to every Deployment referenced in `rolloutRestartTargets`:

```yaml
env:
- name: DATABASE_HOST
  value: <project>-pg-pooler-rw.<project>.svc.cluster.local   # if database.cluster.pooler.enable (Rule 13a) — otherwise <project>-db-rw.<project>.svc.cluster.local
- name: DATABASE_USERNAME
  valueFrom:
    secretKeyRef:
      name: db-<project>-secret
      key: username
- name: DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-<project>-secret
      key: password
- name: DATABASE_NAME
  value: <db_name>                                              # helm: {{ .Values.database.cluster.dbName }}
- name: DATABASE_URL
  value: "postgresql://$(DATABASE_USERNAME):$(DATABASE_PASSWORD)@$(DATABASE_HOST):5432/$(DATABASE_NAME)"
```

### Zero-downtime rollout strategy

The `rolloutRestartTargets` above relies on every Deployment already using the `RollingUpdate{maxUnavailable: 0, maxSurge: 1}` strategy defined in Rule 10 — that strategy is applied unconditionally to all Deployments, not just when this rule is active, since without it a Vault-triggered restart would never be safe.

### values.yaml schema (inside `database.cluster`)

```yaml
vaultDynamicSecrets:
  enable: false
migrationRole:
  enable: false
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/vault/databasemount.yaml`, `helm/templates/vault/databaseconnection.yaml`, `helm/templates/vault/databaserole.yaml`, `helm/templates/vault/dynamicsecret.yaml` |
| `kustomize` | `kubernetes/base/vault/databasemount.yaml`, `kubernetes/base/vault/databaseconnection.yaml`, `kubernetes/base/vault/databaserole.yaml`, `kubernetes/base/vault/dynamicsecret.yaml` |

---

## 17. CronJob (scheduled tasks)

Generated only when `has_scheduled_tasks = true` (see Step 1 detection in the skill). Supports multiple jobs per project.

### Detection patterns (Step 1 — before asking the user)

Scan the project for scheduling library usage and internal cron-style routes:

| Stack | Patterns |
|-------|----------|
| Node.js | `package.json` dependencies: `node-cron`, `node-schedule`, `agenda`, `bull`, `bullmq` (repeatable jobs); source code routes matching `/api/cron/*` or similar |
| Python | `requirements.txt` / `pyproject.toml`: `celery` with a `beat_schedule` config; `APScheduler` |
| Go | `go.mod`: `github.com/robfig/cron` |
| Java | Source code: `@Scheduled` or `@EnableScheduling` annotations |

Always confirm the detected result with the user. If nothing is detected, ask explicitly: "Does this project have scheduled/cron tasks?"

If `has_scheduled_tasks = true`, ask for each job:
- `job_name`
- `schedule` — cron expression
- invocation mechanism: `http:<path>` (calls the app's own Service) or `command:<command>` (runs a standalone command in the CronJob container)

### CronJob template (HTTP-trigger variant — canonical)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: <project>-<job_name>
  namespace: <project>
spec:
  schedule: "<cron_expression>"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: <project>-<job_name>
        spec:
          securityContext:              # reuse the pod-level securityContext from Rule 10
            runAsNonRoot: true
            runAsUser: 1001
            runAsGroup: 1001
            seccompProfile:
              type: RuntimeDefault
          restartPolicy: OnFailure
          containers:
          - name: <project>-<job_name>
            image: curlimages/curl:latest
            securityContext:            # reuse the container-level securityContext from Rule 10
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop: ["ALL"]
            command:
            - sh
            - -c
            - |
              curl -sf -X POST -H "Authorization: Bearer $CRON_SECRET" \
                http://<service>:<port>/<endpoint_path>
            env:
            - name: CRON_SECRET
              valueFrom:
                secretKeyRef:
                  name: <project>-secrets     # the Vault-managed Secret from Rule 2, if present
                  key: CRON_SECRET
            resources:
              requests:
                cpu: 50m
                memory: 32Mi
              limits:
                cpu: 100m
                memory: 64Mi
```

For the `command:<command>` invocation mechanism, replace the `containers[0].image`/`command` with the project's own application image and the given command instead of `curlimages/curl` + `curl`.

### values.yaml schema (Helm uses `range` over the jobs list)

```yaml
cronJobs:
  enabled: false
  jobs: []
  # - name: quotas
  #   schedule: "0 8 * * *"
  #   path: /api/cron/quotas
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/cron/cronjob.yaml` (single template, `{{- range .Values.cronJobs.jobs }}`) |
| `kustomize` | `kubernetes/base/cron/cronjob-<job_name>.yaml` (one file per job, hardcoded) + `kubernetes/base/cron/kustomization.yaml` |

---

## 18. Grafana dashboard-as-code (optional observability extra)

Generated only when `prometheus.grafanaDashboard.enable = true` (default `false`). Since the plugin cannot know the application's actual custom metrics in advance, this generates only a **starter skeleton** with generic panels — flag in the output summary that the user must customize it.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <project>-dashboard
  namespace: <project>
  labels:
    app: <project>
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "<project>"
data:
  <project>-dashboard.json: |
    {
      "title": "<project> — Overview",
      "uid": "<project>-overview",
      "schemaVersion": 39,
      "version": 1,
      "refresh": "30s",
      "time": { "from": "now-6h", "to": "now" },
      "panels": [
        { "id": 1, "type": "stat", "title": "Pod restarts",
          "gridPos": { "x": 0, "y": 0, "w": 8, "h": 4 },
          "targets": [{ "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"<project>\"})", "refId": "A" }] },
        { "id": 2, "type": "timeseries", "title": "CPU usage",
          "gridPos": { "x": 8, "y": 0, "w": 8, "h": 4 },
          "targets": [{ "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"<project>\"}[5m]))", "refId": "A" }] },
        { "id": 3, "type": "timeseries", "title": "HTTP request rate",
          "gridPos": { "x": 16, "y": 0, "w": 8, "h": 4 },
          "targets": [{ "expr": "sum(rate(http_requests_total{namespace=\"<project>\"}[5m]))", "refId": "A" }] }
      ]
    }
```

Helm wraps the whole resource in `{{- if .Values.prometheus.grafanaDashboard.enable }} ... {{- end }}`.

> **Prerequisite:** the Grafana sidecar dashboard-discovery convention must be active in the cluster (watches for ConfigMaps labeled `grafana_dashboard: "1"`).

### values.yaml schema (inside `prometheus`)

```yaml
grafanaDashboard:
  enable: false
```

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/prometheus/grafana-dashboard.yaml` |
| `kustomize` | `kubernetes/base/prometheus/grafana-dashboard.yaml` |

---

## 19. Alertmanager — PrometheusRule (app cluster)

Generated by Step 8. Gated `prometheus.prometheusRules.enable` (default `true`). Deployed to the **app cluster** (qua/prd) in the project namespace by the project's own ArgoCD `Application` — Prometheus runs per app-cluster, so the rules stay namespace-local to the workload they watch. Only the `AlertmanagerConfig` (Rule 20) and the Loki rules (Rule 21) go to the ops cluster.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: <project>
  namespace: <project>
  labels:
    app: <project>
    role: alert-rules
spec:
  groups:
  - name: <project>.rules
    rules:
    - alert: PodCrashLooping
      expr: increase(kube_pod_container_status_restarts_total{namespace="<project>"}[5m]) > 3
      for: 5m
      labels:
        severity: critical
        namespace: <project>
      annotations:
        summary: "Pod {{ $labels.pod }} is crash-looping"
        description: "{{ $labels.pod }} restarted more than 3 times in 5 minutes."
    - alert: HighCPU
      expr: |
        (sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="<project>"}[5m]))
         / sum by (pod) (kube_pod_container_resource_limits{namespace="<project>",resource="cpu"})) > 0.8
      for: 10m
      labels:
        severity: warning
        namespace: <project>
      annotations:
        summary: "High CPU on {{ $labels.pod }}"
        description: "CPU usage above 80% of the configured limit for 10 minutes."
    - alert: HighMemory
      expr: |
        (sum by (pod) (container_memory_working_set_bytes{namespace="<project>"})
         / sum by (pod) (kube_pod_container_resource_limits{namespace="<project>",resource="memory"})) > 0.85
      for: 10m
      labels:
        severity: warning
        namespace: <project>
      annotations:
        summary: "High memory on {{ $labels.pod }}"
        description: "Memory working set above 85% of the configured limit for 10 minutes."
```

Helm wraps the whole resource in `{{- if .Values.prometheus.prometheusRules.enable }} ... {{- end }}`.

> Every alert carries a `namespace="<project>"` label — this is what the ops-cluster `AlertmanagerConfig` route in Rule 20 matches on. Keep it on all rules, including any the user adds later.

### Output paths

| Format | Files |
|--------|-------|
| `helm` | `helm/templates/alertmanager/prometheusrule.yaml` |
| `kustomize` | `kubernetes/base/alertmanager/prometheusrule.yaml` + `kubernetes/base/alertmanager/kustomization.yaml` |

---

## 20. AlertmanagerConfig (ops cluster)

Generated only when `alertmanager_config_enable = true` (runtime input, default `false`). Written as **plain YAML** to `ops/alertmanagerconfig-<project>.yaml` at the app repo root — never into the app chart or kustomize base — and **delivered to the ops cluster** by the ArgoCD `ApplicationSet` in Rule 22. The app's own ArgoCD `Application` targets the project namespace in the app cluster and must not carry this object.

Operator: **Prometheus Operator**, API group `monitoring.coreos.com/v1alpha1`.

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: <project>
  namespace: <ops_namespace>              # runtime input, default: monitoring
  labels:
    alertmanagerConfig: enabled           # runtime input alertmanager_config_selector_label — must match the ops Alertmanager's spec.alertmanagerConfigSelector
spec:
  route:
    receiver: <project>-webhook
    groupBy: [alertname, severity, namespace]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
    - name: namespace
      value: <project>
      matchType: "="
  receivers:
  - name: <project>-webhook
    webhookConfigs:
    - urlSecret:
        name: <project>-alerting          # pre-existing Secret IN THE OPS NAMESPACE, key: webhook-url
        key: webhook-url
      sendResolved: true
```

> **Manual prerequisites (ops cluster) — flag all in the output summary; the plugin creates none of them:**
> - The `<project>-alerting` Secret with key `webhook-url` must exist in `<ops_namespace>` on the ops cluster.
> - The ops Alertmanager's `spec.alertmanagerConfigSelector` must select the `alertmanagerConfig: enabled` label, and its `alertmanagerConfigNamespaceSelector` must include `<ops_namespace>`.
> - `route.matchers` relies on every alert carrying a `namespace="<project>"` label — Rule 19 sets it; alerts from other sources must set it too or they will not route here.

### Output path

| Format | File |
|--------|------|
| both | `ops/alertmanagerconfig-<project>.yaml` (app repo root; synced to the ops cluster by Rule 22) |

---

## 21. Loki rules ConfigMap (ops cluster)

Generated only when `loki_rules_enable = true` (runtime input, default `false`) — a **starter skeleton only**; flag in the output summary that the LogQL must be customized for the app's real log format. Written as **plain YAML** to `ops/loki-rules-<project>.yaml` at the app repo root and delivered to the ops cluster by Rule 22. The ops-cluster Loki ruler discovers it via the Grafana-style sidecar convention — a `ConfigMap` labeled `loki_rule: "1"` — mirroring the `grafana_dashboard: "1"` convention in Rule 18.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <project>-loki-rules
  namespace: <ops_namespace>            # runtime input, default: monitoring
  labels:
    loki_rule: "1"                       # sidecar discovery — do not change unless the ops Loki sidecar watches a different label
data:
  <project>-rules.yaml: |
    groups:
    - name: <project>-logs
      rules:
      - alert: <project>HighLogErrorRate
        expr: |
          sum(rate({namespace="<project>"} |~ `(?i)(level=error|"level":"error"|\bERROR\b)` [5m])) > 0.2
        for: 10m
        labels:
          severity: warning
          namespace: <project>
        annotations:
          summary: "Elevated error-log rate in <project>"
          description: "More than 0.2 error lines/s over 10m in namespace <project>. Tune the matcher and threshold for this app's log format."
      # Add project-specific LogQL alerting / recording rules here.
```

> **Manual prerequisites (ops cluster) — flag in the output summary:**
> - The Loki ruler must load ConfigMaps labeled `loki_rule: "1"` from `<ops_namespace>` (sidecar or equivalent).
> - The ruler must have an Alertmanager target so these alerts reach the `AlertmanagerConfig` route in Rule 20.
> - Alerts carry `namespace="<project>"` so the Rule 20 route matches them.

### Output path

| Format | File |
|--------|------|
| both | `ops/loki-rules-<project>.yaml` (app repo root; synced to the ops cluster by Rule 22) |

---

## 22. Consolidated delivery — ArgoCD ApplicationSet (app cluster + ops cluster)

**Always generated** (`argocd/applicationset.yaml` + `argocd/repo-creds.yaml`) — it carries the entire delivery model, so it is written even when both ops enables are off (the `{ops}` list element still renders, it just has no `ops/` files to sync until enabled). It **replaces** the old per-project `application-<project>.yaml` / `secret-<project>-repo.yaml` and the earlier ops-only `applicationset-ops.yaml`.

One `ApplicationSet` in the app-cluster `argocd` namespace. A **matrix generator** crosses:
1. an **SCM-provider generator** — discovers every project repo in the GitLab group, on branches `qua`/`prd`;
2. a **list generator** — two deploy targets: `app` (→ app cluster) and `ops` (→ ops cluster).

Per `(repo, branch, target)` it emits one `Application`. The template branches on `.name`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: operonix
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - matrix:
      generators:
      - scmProvider:
          gitlab:
            group: "<gitlab_group>"              # runtime input gitlab_group_url
            api: https://gitlab.com               # adjust for self-managed GitLab
            allBranches: true
            tokenRef:
              secretName: argocd-gitlab-scm       # same token as repo-creds; read_api scope
              key: token
          filters:
          - branchMatch: "^(qua|prd)$"
            pathsExist: [kubernetes/overlays]     # kustomize; use [helm] for helm output_format
      - list:
          elements:
          - name: app
          - name: ops
  template:
    metadata:
      name: "{{ .repository }}-{{ .branch }}-{{ .name }}"
    spec:
      project: default
      source:
        repoURL: "{{ .url }}"
        targetRevision: "{{ .branch }}"
        # --- kustomize output_format ---
        path: '{{ if eq .name "app" }}kubernetes/overlays/{{ .branch }}{{ else }}ops{{ end }}'
        # --- helm output_format — generate this instead of the line above ---
        # path: '{{ if eq .name "app" }}helm/<project>{{ else }}ops{{ end }}'
        # {{- if eq .name "app" }}
        # helm:
        #   valueFiles:
        #   - ../../values-{{ .branch }}.yaml
        # {{- end }}
      destination:
        name: '{{ if eq .name "app" }}{{ .branch }}{{ else }}<ops_cluster_name>{{ end }}'   # app clusters registered as "qua"/"prd"; ops as <ops_cluster_name> (default: ops)
        namespace: '{{ if eq .name "app" }}{{ .repository }}{{ else }}<ops_namespace>{{ end }}'  # <ops_namespace> default: monitoring
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=false]
```

Companion credential (`argocd/repo-creds.yaml`) — one `repo-creds` Secret for the whole group, from `gitlab_access`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-gitlab-group
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: "<gitlab_group_url>"        # URL prefix — matches every repo under the group
  password: "<gitlab_access>"       # HTTPS token (or use sshPrivateKey for SSH)
  username: "oauth2"
```

This `ApplicationSet` and Secret are **cross-project singletons** — apply the Reconciliation rule:
- Missing → create from the templates above, report `Created`.
- Present, covers this project's group, template matches → `Already existed`.
- Present but drifted (generator, branch matcher, `pathsExist`, template) or this group not covered → update (add another `scmProvider` under the matrix's first generator if the group differs) and report `Updated`, noting what changed.
- Never emit a second `applicationset.yaml`, nor any per-project `Application`.

> **Prerequisites — flag all in the output summary:**
> - App clusters registered in ArgoCD as `qua` / `prd`, and the ops cluster as `<ops_cluster_name>` (`argocd cluster add`).
> - The `argocd-gitlab-scm` Secret in `argocd` with a `token` key (GitLab PAT, `read_api`) — may be the same token used in `repo-creds`.
> - ArgoCD ≥ 2.6 with the SCM provider generator enabled (`--enable-scm-providers` / allowed-SCM-providers list on the ApplicationSet controller). Helm `valueFiles` with a `../..` path outside the chart dir requires ArgoCD ≥ 2.6.
>
> **`dev`** is intentionally excluded by `branchMatch` — widen the regex to `^(dev|qua|prd)$` (and register a `dev` cluster) if development should be GitOps-managed.
>
> **Fallback (no SCM generator):** replace the SCM-provider generator with a `git` generator (directory/file), or fall back to a per-project pair `argocd/application-<project>-<env>.yaml` (app) + `argocd/application-<project>-<env>-ops.yaml` (ops). Note the substitution in the output summary.

### Output path

| Format | Files |
|--------|-------|
| both | `argocd/applicationset.yaml`, `argocd/repo-creds.yaml` (repo root; applied to the app-cluster `argocd` namespace by `apply-argocd`, Rule 8) |

---

## Open questions

See `references/open-questions.md`
