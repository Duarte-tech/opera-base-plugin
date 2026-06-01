---
name: image-scan
description: Scans a built container image with Trivy for OS, library, and secret vulnerabilities. Triggers on "scan image", "trivy image", "scan container", "/opera-base:image-scan".
---

# Skill: image-scan

## Trigger

Fire when the user asks to:
- scan a container image for vulnerabilities
- run Trivy against an image
- check an image for CVEs or secrets
- `/opera-base:image-scan`

---

## Runtime inputs

| Input | Source |
|-------|--------|
| `image` | First positional argument (required) |
| `severity` | `--severity` flag (default: `HIGH,CRITICAL`) |
| `format` | `--format` flag (default: `table`) |

If `image` is not provided, ask the user before proceeding.

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

### Step 2 — Run image scan

```bash
trivy image \
  --exit-code 0 \
  --scanners vuln,secret,misconfig \
  --severity <severity> \
  --format <format> \
  <image>
```

- `--exit-code 0`: never let Trivy exit non-zero (would terminate the shell session)
- `--scanners vuln,secret,misconfig`: covers CVEs, embedded secrets, and runtime misconfigs
- If the image is not found locally, Trivy will attempt to pull it from the registry; inform the user if pull fails

---

### Step 3 — Parse and present results

Group findings by scanner type, then by severity (CRITICAL → HIGH → MEDIUM → LOW):

**Vulnerabilities (`vuln`):**
- CVE ID, package name, installed version, fixed version (if available)
- NVD/OSV link
- Remediation: upgrade to fixed version or use a base image with a patch

**Secrets (`secret`):**
- Rule ID, file path inside the image, matched pattern
- Remediation: remove from image layers; rotate the exposed credential immediately

**Misconfigurations (`misconfig`):**
- Rule ID (e.g. `AVD-DS-0002`), title, description
- Remediation hint

---

### Step 4 — Summary

Print a summary table:

| Scanner | CRITICAL | HIGH | MEDIUM | LOW |
|---------|----------|------|--------|-----|
| vuln | N | N | N | N |
| secret | N | N | N | N |
| misconfig | N | N | N | N |

**Verdict:**
- `PASS` — no CRITICAL findings across all scanners
- `FAIL` — one or more CRITICAL findings present

If secrets are found, always flag as **FAIL** regardless of severity level and instruct the user to rotate the exposed credential.

---

## Constraints

- Always use `--exit-code 0`
- Do not build, tag, or push images on behalf of the user
- If the image requires registry authentication, instruct the user to run `docker login` or `trivy image --username / --password` before retrying
- `--format sarif` output can be uploaded to GitHub Advanced Security or GitLab Security Dashboard
