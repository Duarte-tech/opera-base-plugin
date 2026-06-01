---
name: dockerfile-scan
description: Scans a Dockerfile (and optionally a built image) with Trivy for misconfigurations and vulnerabilities.
allowed-tools: Bash, Read, Glob
---

# /opera-base:dockerfile-scan

Runs a Trivy security scan against a project's Dockerfile and, optionally, a built container image.

## Usage

```
/opera-base:dockerfile-scan
/opera-base:dockerfile-scan --path <dockerfile_path>
/opera-base:dockerfile-scan --image <image_name>
/opera-base:dockerfile-scan --path <dockerfile_path> --image <image_name> --severity CRITICAL,HIGH,MEDIUM
```

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--path <path>` | auto-detect | Path to the Dockerfile to scan for misconfigurations |
| `--image <image>` | — | Built image name/tag to scan for OS and library vulnerabilities |
| `--severity <levels>` | `HIGH,CRITICAL` | Comma-separated severity levels to report |

## Auto-detection order

If `--path` is not provided:
1. `docker-build/Dockerfile` (React/Vite projects)
2. `Dockerfile` at project root

## Output

Structured report grouped by severity (CRITICAL → HIGH → MEDIUM → LOW):
- Rule ID and description
- File and line number (config scan)
- Remediation hint

Ends with a pass/fail summary: **FAIL** if any CRITICAL finding is present.

## Dependencies

- Trivy must be installed: `trivy --version`  
  Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
- Skill: `skills/dockerfile-scan/SKILL.md`
