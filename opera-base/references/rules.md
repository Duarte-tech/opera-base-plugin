# Operational Rules — opera-base

Source: meeting with Duarte (2026-05-27)

---

## 1. Scope — what this plugin generates

Builds Kubernetes YAML manifests **and** a GitLab CI pipeline. No manual deploy steps.

### Output directory structure (inside the application repo)

```
kubernetes/
├── app/              → Deployment, ConfigMap, Service, Secret (only if no Vault)
├── apisix/           → ApisixRoute, ApisixUpstream
├── alertmanager/     → Alert rules
├── prometheus/       → ServiceMonitor
├── cilium/           → CiliumNetworkPolicy
├── crossplane/
│   ├── cloudflare/   → dns.cloudflare.crossplane.io/v1alpha1 Records CR
│   └── vault/        → Vault Crossplane CRs (mount, user, policy)
└── vault/            → VaultAuth, VaultStaticSecret (vault-secrets-operator)
```

### Helm chart layout

- **Chart templates** live in a **separate GitLab repo** (name: **ask at runtime**)
- **`values.yaml`** lives in the **application repo**, one per branch:

| Branch | `values.yaml` | Environment |
|--------|--------------|-------------|
| `dev`  | `values.yaml` on `dev` branch | Development |
| `qua`  | `values.yaml` on `qua` branch | Staging/QA  |
| `prd`  | `values.yaml` on `prd` branch | Production  |

ArgoCD `Application` CR: chart from the separate repo; values from the app repo branch.
(Exact CR structure: see open questions — Q1)

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

| `vault_mount_mode` | `spec.mount` | `spec.path` | Crossplane mount CR |
|--------------------|-------------|-------------|---------------------|
| `new` | `kv` | `novlok/<project>` | Generated |
| `default` | KV engine from `vault_mount_path` | `<vault_mount_path>/<project>` | Skipped (mount exists) |

Crossplane Vault user and policy CRs are always generated regardless of mount mode.

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

- ArgoCD namespace: **`argocd`**
- One namespace per project (namespace name = project name)
- Helm chart source: separate GitLab repo (name: **ask at runtime**), branch per environment
- `values.yaml` source: application repo, same branch as current environment
- GitLab access: **ask at runtime** (SSH key or HTTPS token)

**Application CR pattern:** multi-source — one source for the chart repo, one for the values file.
At generation time, search the ArgoCD GitLab repo for an existing `Application` CR as the template.
ArgoCD git repo URL: **ask at runtime**.

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

## 6. Cloudflare DNS (Crossplane)

```yaml
apiVersion: dns.cloudflare.crossplane.io/v1alpha1
kind: Records
metadata:
  name: <project>
spec:
  forProvider:
    zoneName: novlok.co
    proxied: true
    type: A
    # ipAddress: <ip>  # optional — use if no LoadBalancer reference
    loadbalancerRef:   # optional — references the APISIX gateway LoadBalancer
      name: apisix-gateway
      namespace: apisix
  providerConfigRef:
    name: cloudflare-config
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
      when: never
    - when: always
```

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

Applies the ArgoCD repository secret and Application CR to the cluster whenever files in `argocd/` change. Runs independently of the build/tag flow — triggered only by changes to the ArgoCD manifests.

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
    - kubectl apply -f argocd/secret-<project>-repo.yaml
    - kubectl apply -f argocd/application-<project>.yaml
  rules:
    - changes:
        - argocd/**/*
```

> `<project>` is replaced with the actual project name at generation time. The secret is applied before the Application CR to ensure ArgoCD can access the repository when it first syncs.

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

Output root: `helm/` (intended to be committed to the separate Helm chart repo).  
Per-environment values live in `values.yaml` in the **app repo** per branch (ArgoCD multi-source, as per Rule 4).

```
helm/
├── Chart.yaml
├── values.yaml                # base defaults used by all environments
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
    ├── vault/
    │   ├── connection.yaml
    │   ├── auth.yaml
    │   └── staticsecret.yaml
    ├── cilium/
    │   └── networkpolicy.yaml
    ├── prometheus/
    │   └── servicemonitor.yaml
    ├── otel/
    │   └── instrumentation.yaml
    ├── alertmanager/
    │   └── prometheusrule.yaml
    ├── autoscaling/
    │   └── autoscaling.yaml
    └── crossplane/
        ├── cloudflare/
        │   └── records.yaml
        └── vault/
            └── policy.yaml
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
prometheus:
  serviceMonitor:
    enable: true
  prometheusRules:
    enable: true
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
    dbName: <project>_db
    dbOwner: <project>_user
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
prometheus:
  serviceMonitor:
    enable: true
  prometheusRules:
    enable: true
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
    dbName: <project>_db
    dbOwner: <project>_user
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
prometheus:
  serviceMonitor:
    enable: true
  prometheusRules:
    enable: true
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
    dbName: <project>_db
    dbOwner: <project>_user
```

ArgoCD Application CR references only the env-specific file via `valueFiles`:
```yaml
helm:
  valueFiles:
  - $values/values-<env>.yaml   # dev | qua | prd
```

- Image tag patching by CI (`update-k8s-tag`) targets `values-<env>.yaml` on the current branch: `yq e '.image.tag = "<tag>"' -i values-<env>.yaml`

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
│   │   └── kustomization.yaml
│   ├── apisix/
│   │   ├── route.yaml
│   │   ├── upstream.yaml
│   │   └── kustomization.yaml
│   ├── vault/
│   │   ├── connection.yaml
│   │   ├── auth.yaml
│   │   ├── staticsecret.yaml
│   │   └── kustomization.yaml
│   ├── cilium/
│   │   ├── networkpolicy.yaml
│   │   └── kustomization.yaml
│   ├── prometheus/
│   │   ├── servicemonitor.yaml
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
│   └── crossplane/
│       ├── cloudflare/
│       │   ├── records.yaml
│       │   └── kustomization.yaml
│       └── vault/
│           ├── policy.yaml
│           └── kustomization.yaml
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
- ArgoCD Application CR: source path set to `kubernetes/overlays/<env>`; no separate Helm chart repo needed in this mode

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

### Cluster CR

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <project>-db
  namespace: <project>
spec:
  instances: 1                                        # helm: {{ .Values.database.cluster.instances }}
  imageName: ghcr.io/cloudnative-pg/postgresql:16    # helm: ghcr.io/cloudnative-pg/postgresql:{{ .Values.database.cluster.postgresVersion }}
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
| `helm` | `helm/templates/database/cluster.yaml`, `helm/templates/database/database.yaml` |
| `kustomize` | `kubernetes/base/database/cluster.yaml`, `kubernetes/base/database/database.yaml`, `kubernetes/base/database/kustomization.yaml` |

### Helm — enable/disable

Wrap both CRs in a single conditional:

```yaml
{{- if .Values.database.cluster.enable }}
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
- cluster.yaml
- database.yaml
```

The top-level `kubernetes/base/kustomization.yaml` does **not** reference the database component.

Each overlay `kustomization.yaml` gets a commented-out opt-in block:

```yaml
# components:
# - ../../base/database   # uncomment to enable CNPG database cluster in this environment
```

> Kustomize components require kustomize v4.1.0+ or `kubectl` v1.21+.

---

## Open questions

See `references/open-questions.md`
