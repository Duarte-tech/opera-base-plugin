# Open Questions

Updated: 2026-05-27
Status: **all critical questions resolved** — remaining items are low-risk defaults.

---

## Verify at first use

**ArgoCD delivery — mono-repo, consolidated ApplicationSet** (Rules 1, 4, 22)
Each project is a single GitLab repo (app + `helm/<project>/` or `kubernetes/` + `argocd/` + `ops/`).
Delivery is one cross-project `ApplicationSet` (`argocd/applicationset.yaml`) + one group `repo-creds`
Secret (`argocd/repo-creds.yaml`) — a matrix of an SCM-provider generator (GitLab group, branches
`qua`/`prd`) × a list `{app, ops}`, emitting a single-source app-cluster `Application` and an
ops-cluster `Application` per `(repo, branch)`. No per-project `Application`/`Secret`, no separate
chart or ArgoCD repo, no multi-source. Verify at first use: ArgoCD ≥ 2.6 with SCM provider
generators enabled; app clusters registered as `qua`/`prd` and ops as `<ops_cluster_name>`;
helm `valueFiles: ["../../values-<env>.yaml"]` resolves (path outside chart dir, within repo).
