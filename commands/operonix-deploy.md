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
| `stack` | Auto-detected from project root; confirmed with user (`nodejs`, `go`, `java`, `python`) |
| `services` | Services and ports, e.g. `frontend:3000, api:8080` |
| `subdomain` | Subdomain → `<subdomain>.novlok.co` |
| `image_registry` | Image path, e.g. `registry.gitlab.com/<group>/<project>/app` |
| `gitlab_app_repo` | Application GitLab repo URL |
| `gitlab_helm_repo` | Helm chart GitLab repo URL (separate repo, branch per env) |
| `gitlab_argocd_repo` | ArgoCD GitLab repo URL (used to fetch Application CR template) |
| `gitlab_access` | GitLab access for ArgoCD Secret — SSH key or HTTPS token |
| `vault_address` | Vault address, e.g. `https://vault.novlok.co` |
| `otel_endpoint` | OTel collector endpoint (Node.js default: `otlp/http`) |

## Files generated

```
kubernetes/
├── app/              Deployment, ConfigMap, Service, Secret (if no Vault)
├── apisix/           ApisixRoute, ApisixUpstream
├── alertmanager/     PrometheusRule
├── prometheus/       ServiceMonitor (if not already present)
├── cilium/           CiliumNetworkPolicy (mTLS + allow apisix namespace)
├── crossplane/
│   ├── cloudflare/   Cloudflare DNS Records CR
│   └── vault/        Vault mount, user, policy CRs (Crossplane)
└── vault/            VaultConnection, VaultAuth, VaultStaticSecret
argocd/
├── application-<project>.yaml
└── secret-<project>-repo.yaml
Dockerfile
.gitlab-ci.yml
version.yaml          (created only if absent)
```

## Conditional generation

| Condition | Effect |
|-----------|--------|
| No secrets found in project | `kubernetes/vault/` and `kubernetes/crossplane/vault/` skipped |
| `ServiceMonitor` already in `kubernetes/prometheus/` | Step 7 skipped |

## Dependencies

- Skill: `skills/operonix-deploy/SKILL.md`
- Rules: `references/rules.md`
