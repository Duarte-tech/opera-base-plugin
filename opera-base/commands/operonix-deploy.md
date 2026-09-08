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
| `gitlab_repo` | Project **mono-repo** URL — app code + `helm/<project>/` (or `kubernetes/`) + `argocd/` + `ops/`. No separate chart or ArgoCD repo. |
| `gitlab_group_url` | GitLab group holding the project repos — for the `ApplicationSet` SCM generator and the group `repo-creds` Secret (default: derived from `gitlab_repo`) |
| `gitlab_access` | GitLab access for the ArgoCD `repo-creds` Secret — SSH key or HTTPS token |
| `vault_address` | Vault address, e.g. `https://vault.novlok.co` |
| `otel_endpoint` | OTel collector endpoint (Node.js default: `otlp/http`) |
| `db_name` | *(only if database detected)* Database name (default: `<project>_db`) |
| `postgres_version` | *(only if database detected)* PostgreSQL version (default: `16`) |
| `persistence_mount_path`, `persistence_size` | *(only if persistence detected)* PVC mount path and size |
| `tls_enabled`, `tls_cert_manager_enable`, `tls_cluster_issuer`, `tls_existing_secret_name` | HTTPS termination via APISIX + cert-manager (default: disabled) |
| `database_pooler_enable`, `database_backup_enable` (+ S3 fields), `database_monitoring_enable` | *(only if database detected)* CNPG Pooler / ScheduledBackup+ObjectStore / PodMonitor |
| `vault_dynamic_db_secrets_enable` | *(only if database detected)* Vault dynamic DB credentials instead of static |
| `cron_jobs` | *(only if scheduled tasks detected)* List of `{job_name, schedule, invocation}` |
| `grafana_dashboard_enable` | Starter Grafana dashboard-as-code ConfigMap (default: disabled) |
| `alertmanager_config_enable`, `loki_rules_enable` | Ops-cluster observability: `AlertmanagerConfig` CR and/or starter Loki rules `ConfigMap` under `ops/` (both default: disabled). The consolidated `ApplicationSet` always delivers the `ops` target — these just fill it. |
| `ops_namespace`, `ops_cluster_name` | Ops-cluster namespace (default `monitoring`) and its name as registered in ArgoCD (default `ops`) — used by the `ApplicationSet` `ops` target |
| `alertmanager_config_selector_label` | *(only if `alertmanager_config_enable`)* Label the ops Alertmanager's `alertmanagerConfigSelector` matches (default: `alertmanagerConfig: enabled`) |

## Files generated — Helm

Bootstrapped with `helm create <project>` — generic templates are removed; custom CRs replace them.

All in one mono-repo (no separate chart repo).

```
values-dev.yaml           (dev — complete, repo root)
values-qua.yaml           (qua — complete, repo root)
values-prd.yaml           (prd — complete, replicas: 2, repo root)
helm/<project>/
├── Chart.yaml
├── values.yaml           (minimal structural placeholder)
├── .helmignore
└── templates/
    ├── _helpers.tpl      (from helm create, extended if needed)
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── app/              Deployment (securityContext, RollingUpdate strategy), Service, ConfigMap, PVC (if persistence detected)
    ├── vault/            VaultConnection, VaultAuth, VaultStaticSecret + novlok-operator VaultAuth, VaultPolicy, VaultKubernetesRole (if secrets found); VaultDynamicSecret (if vault_dynamic_db_secrets_enable)
    ├── database/         CNPG ImageCatalog + Cluster + Database CR (if database detected; enable per env via values); Pooler, ScheduledBackup+ObjectStore, PodMonitor (per their own flags)
    ├── apisix/           ApisixRoute, ApisixUpstream
    ├── tls/              cert-manager Certificate + ApisixTls (if tls.enabled)
    ├── alertmanager/     PrometheusRule (app cluster — Rule 19)
    ├── prometheus/       ServiceMonitor (if prometheus.serviceMonitor.enable); Grafana dashboard ConfigMap (if prometheus.grafanaDashboard.enable)
    ├── otel/             Instrumentation CR (if otel.autoinstrumentation.enable)
    ├── autoscaling/      HPA or KEDA ScaledObject (if autoscaling.enabled)
    ├── cilium/           CiliumNetworkPolicy (mTLS ingress+egress)
    ├── cron/             CronJob (if scheduled tasks detected)
    └── cloudflare/       Cloudflare DNS Record CR (novlok-operator)
ops/                             (plain YAML — ops cluster, synced by the ApplicationSet)
├── alertmanagerconfig-<project>.yaml   (if alertmanager_config_enable — Rule 20)
└── loki-rules-<project>.yaml           (if loki_rules_enable — Rule 21)
argocd/                          (repo root — two cross-project singletons, always generated — Rule 22)
├── repo-creds.yaml              (group-scoped ArgoCD repo-creds Secret)
└── applicationset.yaml          (consolidated app+ops ApplicationSet: SCM generator × {app, ops})
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
│   ├── app/              Deployment (securityContext, RollingUpdate strategy), Service, ConfigMap, PVC (if persistence detected)
│   ├── vault/            VaultConnection, VaultAuth, VaultStaticSecret + novlok-operator VaultAuth, VaultPolicy, VaultKubernetesRole (if secrets found); VaultDynamicSecret (if vault_dynamic_db_secrets_enable)
│   ├── database/         CNPG ImageCatalog + Cluster + Database CR as Kustomize Component (if database detected; overlays opt in); Pooler, ScheduledBackup+ObjectStore, PodMonitor (per their own flags, same Component)
│   ├── apisix/           ApisixRoute, ApisixUpstream
│   ├── tls/              cert-manager Certificate + ApisixTls as Kustomize Component (if tls.enabled; overlays opt in)
│   ├── alertmanager/     PrometheusRule (app cluster — Rule 19)
│   ├── prometheus/       ServiceMonitor (if prometheus.serviceMonitor.enable); Grafana dashboard ConfigMap (if prometheus.grafanaDashboard.enable)
│   ├── otel/             Instrumentation CR (if otel.autoinstrumentation.enable)
│   ├── autoscaling/      HPA or KEDA ScaledObject (if autoscaling.enabled)
│   ├── cilium/           CiliumNetworkPolicy (mTLS ingress+egress)
│   ├── cron/             CronJob, one file per job (if scheduled tasks detected)
│   └── cloudflare/       Cloudflare DNS Record CR (novlok-operator)
└── overlays/
    ├── dev/              kustomization.yaml + patches/replicas.yaml
    ├── qua/
    └── prd/
ops/                             (plain YAML — ops cluster, synced by the ApplicationSet; repo root, NOT under kubernetes/)
├── alertmanagerconfig-<project>.yaml   (if alertmanager_config_enable — Rule 20)
└── loki-rules-<project>.yaml           (if loki_rules_enable — Rule 21)
argocd/                          (repo root — two cross-project singletons, always generated — Rule 22)
├── repo-creds.yaml              (group-scoped ArgoCD repo-creds Secret)
└── applicationset.yaml          (consolidated app+ops ApplicationSet: SCM generator × {app, ops})
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
| No database indicators detected and user says no | database manifests skipped (Step 3b skipped) |
| `has_database = true` | CNPG Cluster + Database CR generated; `database.cluster.enable: false` in all values files (Helm) or Component opt-in comment in overlays (Kustomize) |
| No persistence indicators detected and user says no | PVC skipped (Step 3c skipped) |
| No scheduled-task indicators detected and user says no | CronJob manifests skipped (Step 3d skipped) |
| `tls_enabled = false` (default) | TLS manifests skipped (Step 5b skipped) — current HTTP-only behavior preserved |
| `vault_dynamic_db_secrets_enable = false` (default) | VaultDynamicSecret skipped (Step 4b skipped); VaultStaticSecret (Rule 2) still used for other confidential secrets |
| always | `argocd/repo-creds.yaml` + `argocd/applicationset.yaml` generated/reconciled as cross-project singletons (Rule 22) — no per-project `Application`/`Secret` |
| `alertmanager_config_enable = false` **and** `loki_rules_enable = false` (default) | `ops/*` files skipped (Step 8a skipped); the `ApplicationSet` `ops` target still renders but has nothing to sync |
| `alertmanager_config_enable = true` or `loki_rules_enable = true` | corresponding `ops/*.yaml` generated (plain YAML, repo root) |
| `prometheus.prometheusRules.enable = false` | PrometheusRule skipped (Step 8 skipped) — app-cluster alert rules only |

## Dependencies

- Skill: `skills/operonix-deploy/SKILL.md`
- Rules: `references/rules.md` (Rules 1–22)
