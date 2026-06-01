---
name: dockerfile-scan
description: Scans the project filesystem with Trivy (misconfig + vuln) and outputs a GitLab Code Quality JSON report.
allowed-tools: Bash, Read, Glob
---

# /opera-base:dockerfile-scan

Runs `trivy filesystem` against the project directory, scanning for Dockerfile misconfigurations and dependency vulnerabilities. Outputs a GitLab Code Quality JSON report (`gl-codeclimate-fs.json`).

## Usage

```
/opera-base:dockerfile-scan
/opera-base:dockerfile-scan --output <file> --severity CRITICAL,HIGH,MEDIUM
```

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--output <file>` | `gl-codeclimate-fs.json` | Output file for the GitLab Code Quality report |
| `--severity <levels>` | `HIGH,CRITICAL` | Comma-separated severity levels to report |

## Command used

```bash
trivy filesystem \
  --scanners misconfig,vuln \
  --exit-code 0 \
  --format template \
  --template "@/contrib/gitlab-codequality.tpl" \
  -o gl-codeclimate-fs.json \
  .
```

## Output

- `gl-codeclimate-fs.json` — GitLab Code Quality artifact, upload in CI as `reports: codequality`
- Terminal summary grouped by severity with remediation hints
- Pass/fail verdict: **FAIL** if any CRITICAL finding

## Dependencies

- Trivy `≥ 0.69.3` must be installed: `trivy --version`  
  Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
- Skill: `skills/dockerfile-scan/SKILL.md`
