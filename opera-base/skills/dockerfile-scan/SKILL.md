---
name: dockerfile-scan
description: Scans a Dockerfile and optionally a built image with Trivy for misconfigurations and vulnerabilities. Triggers on "scan dockerfile", "validate dockerfile", "trivy scan", "/opera-base:dockerfile-scan".
---

# Skill: dockerfile-scan

## Trigger

Fire when the user asks to:
- scan or validate a Dockerfile
- run a Trivy scan on a Dockerfile or image
- check a Dockerfile for security issues
- `/opera-base:dockerfile-scan`

---

## Runtime inputs

| Input | Source |
|-------|--------|
| `dockerfile_path` | `--path` argument or auto-detected |
| `image_name` | `--image` argument (optional) |
| `severity` | `--severity` argument (default: `HIGH,CRITICAL`) |

---

## Methodology

### Step 1 — Check Trivy is installed

```bash
trivy --version
```

If the command fails (not found), stop and instruct the user to install Trivy:
> Trivy is not installed. Install it from: https://aquasecurity.github.io/trivy/latest/getting-started/installation/

Do not proceed until Trivy is available.

---

### Step 2 — Resolve Dockerfile path

If `--path` was not provided, auto-detect in this order:
1. `docker-build/Dockerfile` — present in React/Vite projects
2. `Dockerfile` at the project root

Confirm the detected path with the user before running any scan.

If no Dockerfile is found, stop and ask the user to provide `--path`.

---

### Step 3 — Config scan (always run)

Scans the Dockerfile itself for misconfigurations (root USER, ADD instead of COPY, latest tags, exposed secrets, etc.):

```bash
trivy config --exit-code 0 --severity <severity> --format table <dockerfile_path>
```

Capture the full output.

---

### Step 4 — Image scan (only if `--image` provided)

Scans a built container image for OS package and library vulnerabilities:

```bash
trivy image --exit-code 0 --severity <severity> --format table <image_name>
```

If `--image` was not provided, skip this step. Do not build or pull images on behalf of the user.

---

### Step 5 — Parse and present results

Group findings from Steps 3 and 4 by severity in descending order: **CRITICAL → HIGH → MEDIUM → LOW**.

For each finding, show:
- **Severity** (coloured label if terminal supports it)
- **Rule ID** (e.g. `DS002`, `AVD-DS-0001`)
- **Description** — what the issue is
- **Location** — file and line number (config scan) or package name and version (image scan)
- **Remediation hint** — one-line fix suggestion

---

### Step 6 — Summary

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

Flag any finding that maps to the Dockerfile patterns in `references/rules.md` Rule 9 (e.g. running as root conflicts with Rule 10 security context requirements).

---

## Constraints

- Always use `--exit-code 0` — never `--exit-code 1`, which would terminate the shell session
- Never build or pull images; `trivy image` only works on already-available images
- `trivy config` scans the Dockerfile file itself; `trivy image` scans a runtime image — they are complementary, not interchangeable
- Default severity filter is `HIGH,CRITICAL`; respect the user's `--severity` override
