---
name: image-scan
description: Scans a built container image with Trivy for CVEs and secrets, outputting a GitLab Code Quality JSON report.
allowed-tools: Bash, Read
---

# /opera-base:image-scan

Runs `trivy image` against a built container image, scanning for OS and library CVEs, embedded secrets, and misconfigurations. Outputs a GitLab Code Quality JSON report (`gl-codeclimate-image.json`).

## Usage

```
/opera-base:image-scan <image>
/opera-base:image-scan <image> --output <file> --severity CRITICAL,HIGH,MEDIUM
```

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `<image>` | required | Image name and tag, e.g. `myapp:latest` or `registry.gitlab.com/org/app:v1.2.0` |
| `--output <file>` | `gl-codeclimate-image.json` | Output file for the GitLab Code Quality report |
| `--severity <levels>` | `HIGH,CRITICAL` | Comma-separated severity levels to report |

## Command used

```bash
trivy image \
  --exit-code 0 \
  --format template \
  --template "@/contrib/gitlab-codequality.tpl" \
  -o gl-codeclimate-image.json \
  $IMAGE
```

## What is scanned

| Scanner | What it finds |
|---------|---------------|
| `vuln` | OS package CVEs and language library vulnerabilities |
| `secret` | Hardcoded credentials and API keys in image layers |
| `misconfig` | Container runtime misconfigurations |

## Output

- `gl-codeclimate-image.json` — GitLab Code Quality artifact, upload in CI as `reports: codequality`
- Terminal summary grouped by scanner type and severity
- Pass/fail verdict: **FAIL** if any CRITICAL finding or any secret detected

## Dependencies

- Trivy `≥ 0.69.3` must be installed: `trivy --version`  
  Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
- The image must be built and available locally or in an accessible registry
- Skill: `skills/image-scan/SKILL.md`
