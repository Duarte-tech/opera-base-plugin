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

Check `kubernetes/prometheus/` for an existing `ServiceMonitor` CR.

- If **not found**: generate a baseline `ServiceMonitor` — no special labels required
- Also configure OTel exporter — collector endpoint and protocol: **ask at runtime** (varies per project and language; for Node.js default to `otlp/http`)

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
    loadbalancerRef:
      name: apisix-gateway
      namespace: apisix
  providerConfigRef:
    name: cloudflare-config
```

---

## 7. Cilium

No cluster-wide default-deny. Required: **mutual TLS** between all pods in the namespace.
Ingress from the `apisix` namespace is always allowed (no mTLS required on that path).

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
  # Allow intra-namespace traffic with mTLS
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: <project>
    authentication:
      mode: required
```

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

## Open questions

See `references/open-questions.md`
