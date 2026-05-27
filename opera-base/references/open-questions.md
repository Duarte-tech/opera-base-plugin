# Open Questions

Updated: 2026-05-27
Status: **all critical questions resolved** — remaining items are low-risk defaults.

---

## Verify at first use

**ArgoCD Application CR template**
When generating the first ArgoCD `Application` CR, search the ArgoCD GitLab repo
(URL asked at runtime) for an existing multi-source Application CR to use as a template.
The multi-source pattern: source 1 = Helm chart repo; source 2 = app repo `values.yaml` on current branch.
