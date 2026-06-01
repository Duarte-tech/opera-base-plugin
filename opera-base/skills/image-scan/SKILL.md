---
name: image-scan
description: Scans a built container image with Trivy for CVEs and secrets, outputting a GitLab Code Quality report. Triggers on "scan image", "trivy image", "scan container", "/opera-base:image-scan".
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
| `output_file` | `--output` flag (default: `gl-codeclimate-image.json`) |
| `severity` | `--severity` flag (default: `HIGH,CRITICAL`) |

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
  --format template \
  --template "@/contrib/gitlab-codequality.tpl" \
  -o gl-codeclimate-image.json \
  <image>
```

- `--exit-code 0`: never let Trivy exit non-zero (would terminate the shell session)
- `--format template --template "@/contrib/gitlab-codequality.tpl"`: outputs GitLab Code Quality JSON, uploadable as a CI artifact
- `-o gl-codeclimate-image.json`: output file (default name aligns with GitLab CI artifact convention)
- If the image is not found locally, Trivy will attempt to pull it from the registry; inform the user if pull fails

---

### Step 3 — Parse and present results

Read `gl-codeclimate-image.json` and present findings grouped by severity (CRITICAL → HIGH → MEDIUM → LOW):

**Vulnerabilities (`vuln`):**
- CVE ID, package name, installed version, fixed version (if available)
- Remediation: upgrade to fixed version or use a patched base image

**Secrets (`secret`):**
- Rule ID, file path inside the image, matched pattern
- Remediation: remove from image layers; **rotate the exposed credential immediately**

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

If secrets are found, always flag as **FAIL** regardless of severity and instruct the user to rotate the credential.

Inform the user that `gl-codeclimate-image.json` can be uploaded as a GitLab CI artifact under `reports: codequality`.

---

## Constraints

- Always use `--exit-code 0`
- Do not build, tag, or push images on behalf of the user
- If the image requires registry authentication, instruct the user to run `docker login` or use `trivy image --username / --password` before retrying
- The `@/contrib/gitlab-codequality.tpl` template is bundled with the Trivy binary; no extra download needed
- Default output file is `gl-codeclimate-image.json`; respect the user's `--output` override
