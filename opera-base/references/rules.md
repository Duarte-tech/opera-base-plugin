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

- Database manifests
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
  mount: kv
  type: kv-v2
  path: novlok/<project>
  destination:
    name: <project>-secrets
    create: true
```

> **Note:** Verify exact CRD versions against the installed operator in the cluster (`kubectl get crd | grep hashicorp`).

---

## 3. Observability

Both Prometheus and OTel are opt-in via `values.yaml` flags (`prometheus.enabled`, `otel.enabled`).  
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
  nodejs:                        # include only the block matching the project stack
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:latest
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:latest
  go:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-go:latest
```

> Include **only** the language block that matches the project stack. Remove the others.

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
  # Allow egress to kube-dns
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s:k8s-app: kube-dns
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

---

## 9. Dockerfile patterns

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
    ├── alertmanager/
    │   └── prometheusrule.yaml
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

**Values files — one base + one per environment (all live in the app repo):**

`values.yaml` — base defaults shared by all environments:
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
    enable: true   # controls ServiceMonitor generation
  prometheusRules:
    enable: true   # controls PrometheusRule (alerting rules) generation
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
    enable: true   # controls Instrumentation CR generation and Deployment annotation
stack: <stack>   # nodejs | java | python | go — used for OTel injection annotation
```

`values-dev.yaml` — development overrides:
```yaml
replicaCount: 1
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "250m"
```

`values-qua.yaml` — staging/QA overrides:
```yaml
replicaCount: 1
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "250m"
```

`values-prd.yaml` — production overrides:
```yaml
replicaCount: 2
resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

ArgoCD Application CR references both files via `valueFiles` in the multi-source config:
```yaml
helm:
  valueFiles:
  - $values/values.yaml
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
│   ├── alertmanager/
│   │   ├── prometheusrule.yaml
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

## Open questions

See `references/open-questions.md`
