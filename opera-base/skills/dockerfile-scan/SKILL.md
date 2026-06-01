---
name: dockerfile-scan
description: Scans the project filesystem (misconfig + vuln) with Trivy, outputting a GitLab Code Quality report. Triggers on "scan dockerfile", "validate dockerfile", "trivy scan", "/opera-base:dockerfile-scan".
---

# Skill: dockerfile-scan

## Trigger

Fire when the user asks to:
- scan or validate a Dockerfile
- run a Trivy filesystem scan
- check a Dockerfile for security issues
- `/opera-base:dockerfile-scan`

---

## Runtime inputs

| Input | Source |
|-------|--------|
| `output_file` | `--output` flag (default: `gl-codeclimate-fs.json`) |
| `severity` | `--severity` flag (default: `HIGH,CRITICAL`) |

---

## Methodology

### Step 1 — Check Trivy is installed

```bash
trivy --version
```

If not found, stop and instruct the user to install:
> Trivy is not installed. Install it from: https://aquasecurity.github.io/trivy/latest/getting-started/installation/

> **Version alignment:** the CI pipeline uses `aquasec/trivy:0.69.3`. Warn the user if the detected local version is older.

---

### Step 2 — Run filesystem scan

Scans the project filesystem for misconfigurations (Dockerfile issues, IaC problems) and vulnerabilities (dependency manifests). Run from the project root:

```bash
trivy filesystem \
  --scanners misconfig,vuln \
  --exit-code 0 \
  --format template \
  --template "@/contrib/gitlab-codequality.tpl" \
  -o gl-codeclimate-fs.json \
  .
```

- `--scanners misconfig,vuln`: catches Dockerfile misconfigs (root USER, ADD vs COPY, latest tags) and dependency CVEs
- `--format template --template "@/contrib/gitlab-codequality.tpl"`: outputs GitLab Code Quality JSON, uploadable as a CI artifact
- `-o gl-codeclimate-fs.json`: output file (default name aligns with GitLab CI artifact convention)
- `.`: scan the entire project directory from the current working directory

---

### Step 3 — Parse and present results

Read `gl-codeclimate-fs.json` and present findings grouped by severity (CRITICAL → HIGH → MEDIUM → LOW):

For each finding show:
- **Severity**
- **Rule ID** (e.g. `DS002`, `AVD-DS-0001`)
- **Description** — what the issue is
- **Location** — file and line number
- **Remediation hint**

---

### Step 4 — Summary

Print a summary table:

| Severity | Count |
|----------|-------|
| CRITICAL | N |
| HIGH | N |
| MEDIUM | N |
| LOW | N |

**Verdict:**
- `PASS` — no CRITICAL findings
- `FAIL` — one or more CRITICAL findings present

Flag any finding that maps to the Dockerfile patterns in `references/rules.md` Rule 9 or the securityContext requirements in Rule 10.

Inform the user that `gl-codeclimate-fs.json` can be uploaded as a GitLab CI artifact under `reports: codequality`.

---

## Constraints

- Always use `--exit-code 0` — never `--exit-code 1`
- Default output file is `gl-codeclimate-fs.json`; respect the user's `--output` override
- The `@/contrib/gitlab-codequality.tpl` template is bundled with the Trivy binary; no extra download needed
