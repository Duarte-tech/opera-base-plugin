---
name: image-scan
description: Scans a built container image with Trivy for OS package and library vulnerabilities.
allowed-tools: Bash, Read
---

# /opera-base:image-scan

Runs a Trivy vulnerability scan against a built container image. Covers OS packages, language libraries, and exposed secrets inside the image layers.

## Usage

```
/opera-base:image-scan <image>
/opera-base:image-scan <image> --severity CRITICAL,HIGH,MEDIUM
/opera-base:image-scan <image> --format json
```

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `<image>` | required | Image name and tag to scan, e.g. `myapp:latest` or `registry.gitlab.com/org/app:v1.2.0` |
| `--severity <levels>` | `HIGH,CRITICAL` | Comma-separated severity levels to report |
| `--format <fmt>` | `table` | Output format: `table`, `json`, `sarif` |

## What is scanned

| Scanner | What it finds |
|---------|---------------|
| `vuln` | OS package CVEs (Alpine, Debian, Ubuntu, RHEL, …) and language library vulnerabilities (npm, Maven, pip, Go modules) |
| `secret` | Hardcoded credentials, API keys, tokens embedded in image layers |
| `misconfig` | Container runtime misconfigurations (e.g. running as root, writable root filesystem) |

## Output

Results grouped by severity (CRITICAL → HIGH → MEDIUM → LOW):
- CVE ID / rule ID
- Package name and installed vs fixed version
- Description and remediation hint

Ends with a pass/fail summary: **FAIL** if any CRITICAL vulnerability is present.

## Dependencies

- Trivy `≥ 0.69.3` must be installed: `trivy --version`  
  Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
- The image must already be built and available locally or in an accessible registry
- Skill: `skills/image-scan/SKILL.md`
