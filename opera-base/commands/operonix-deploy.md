---
name: operonix-deploy
description: Scaffolds all Kubernetes manifests, Dockerfile and GitLab CI pipeline for a project. Output is YAML only — nothing is applied to the cluster.
allowed-tools: Read, Write, Glob, Grep, Bash
---

# /opera-base:operonix-deploy

Scaffolds all Kubernetes manifests, Dockerfile, and GitLab CI pipeline for a project.
No files are applied to the cluster — output is YAML only.

## Usage

```
/opera-base:operonix-deploy <project>
/opera-base:operonix-deploy <project> --dry-run
```

## Arguments

| Argument | Description |
|----------|-------------|
| `<project>` | Project name — used as K8s namespace, resource names, and Vault path |
| `--dry-run` | List files that would be generated without writing them |

## Runtime inputs (collected interactively)

| Input | Description |
|-------|-------------|
| `output_format` | **`helm`** (Helm chart templates) or **`kustomize`** (base + overlays) |
| `stack` | Auto-detected from project root; confirmed with user (`nodejs`, `go`, `java`, `python`) |
| `services` | Services and ports, e.g. `frontend:3000, api:8080` |
| `subdomain` | Subdomain → `<subdomain>.novlok.co` |
| `image_registry` | Image path, e.g. `registry.gitlab.com/<group>/<project>/app` |
| `gitlab_app_repo` | Application GitLab repo URL |
| `gitlab_helm_repo` | Helm chart GitLab repo URL — **only if `output_format = helm`** |
| `gitlab_argocd_repo` | ArgoCD GitLab repo URL (used to fetch Application CR template) |
| `gitlab_access` | GitLab access for ArgoCD Secret — SSH key or HTTPS token |
| `vault_address` | Vault address, e.g. `https://vault.novlok.co` |
| `otel_endpoint` | OTel collector endpoint (Node.js default: `otlp/http`) |

## Files generated — Helm

Bootstrapped with `helm create <project>` — generic templates are removed; custom CRs replace them.

```
values.yaml               (base defaults — app repo root)
values-dev.yaml           (dev overrides — app repo root)
values-qua.yaml           (qua overrides — app repo root)
values-prd.yaml           (prd overrides, replicas: 2 — app repo root)
helm/<project>/
├── Chart.yaml
├── .helmignore
└── templates/
    ├── _helpers.tpl      (from helm create, extended if needed)
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── app/              Deployment (securityContext), Service, ConfigMap
    ├── vault/            VaultConnection, VaultAuth, VaultStaticSecret (if secrets found)
    ├── apisix/           ApisixRoute, ApisixUpstream
    ├── alertmanager/     PrometheusRule
    ├── prometheus/       ServiceMonitor (if prometheus.serviceMonitor.enable)
    ├── otel/             Instrumentation CR (if otel.autoinstrumentation.enable)
    ├── autoscaling/      HPA or KEDA ScaledObject (if autoscaling.enabled)
    ├── cilium/           CiliumNetworkPolicy (mTLS ingress+egress)
    └── crossplane/
        ├── cloudflare/   Cloudflare DNS Records CR
        └── vault/        Vault mount, user, policy CRs (Crossplane)
argocd/
├── application-<project>.yaml   (multi-source: chart repo + values.yaml + values-<env>.yaml)
└── secret-<project>-repo.yaml
Dockerfile                       (non-React stacks only)
docker-build/
├── Dockerfile                   (React only)
└── entrypoint.sh                (React + Keycloak only)
.gitlab-ci.yml
version.yaml                     (created only if absent)
```

## Files generated — Kustomize

```
kubernetes/
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── app/              Deployment (securityContext), Service, ConfigMap
│   ├── vault/            VaultConnection, VaultAuth, VaultStaticSecret (if secrets found)
│   ├── apisix/           ApisixRoute, ApisixUpstream
│   ├── alertmanager/     PrometheusRule
│   ├── prometheus/       ServiceMonitor (if prometheus.serviceMonitor.enable)
│   ├── otel/             Instrumentation CR (if otel.autoinstrumentation.enable)
│   ├── autoscaling/      HPA or KEDA ScaledObject (if autoscaling.enabled)
│   ├── cilium/           CiliumNetworkPolicy (mTLS ingress+egress)
│   └── crossplane/
│       ├── cloudflare/   Cloudflare DNS Records CR
│       └── vault/        Vault CRs (Crossplane)
└── overlays/
    ├── dev/              kustomization.yaml + patches/replicas.yaml
    ├── qua/
    └── prd/
argocd/
├── application-<project>.yaml   (single source: overlays/<env>)
└── secret-<project>-repo.yaml
Dockerfile                       (non-React stacks only)
docker-build/
├── Dockerfile                   (React only)
└── entrypoint.sh                (React + Keycloak only)
.gitlab-ci.yml
version.yaml                     (created only if absent)
```

## Conditional generation

| Condition | Effect |
|-----------|--------|
| No secrets found in project | vault manifests skipped |
| `ServiceMonitor` already present | Step 7 skipped |

## Dependencies

- Skill: `skills/operonix-deploy/SKILL.md`
- Rules: `references/rules.md` (Rules 1–12)
