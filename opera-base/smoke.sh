#!/usr/bin/env bash
# smoke.sh — health check for opera-base plugin

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERRORS=0

check() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    echo "  [ok] $label"
  else
    echo "  [FAIL] $label — missing: $path"
    ((ERRORS++))
  fi
}

warn() {
  echo "  [warn] $1"
}

echo "opera-base smoke test"
echo "---------------------"

echo "manifest"
check "plugin.json" "$PLUGIN_ROOT/.claude-plugin/plugin.json"

echo "skills"
check "yaml-gen/SKILL.md"        "$PLUGIN_ROOT/skills/yaml-gen/SKILL.md"
check "operonix-deploy/SKILL.md" "$PLUGIN_ROOT/skills/operonix-deploy/SKILL.md"

echo "commands"
check "yaml-gen.md"        "$PLUGIN_ROOT/commands/yaml-gen.md"
check "operonix-deploy.md" "$PLUGIN_ROOT/commands/operonix-deploy.md"

echo "references"
check "rules.md"           "$PLUGIN_ROOT/references/rules.md"
check "open-questions.md"  "$PLUGIN_ROOT/references/open-questions.md"

echo "plugin.json registrations"
for skill in yaml-gen operonix-deploy; do
  if grep -q "\"$skill\"" "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
    echo "  [ok] skill $skill registered"
  else
    echo "  [FAIL] skill $skill not in plugin.json"
    ((ERRORS++))
  fi
done
for cmd in yaml-gen operonix-deploy; do
  if grep -q "\"$cmd\"" "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
    echo "  [ok] command $cmd registered"
  else
    echo "  [FAIL] command $cmd not in plugin.json"
    ((ERRORS++))
  fi
done

echo "content checks"
if grep -q "TO BE FILLED" "$PLUGIN_ROOT/references/rules.md" 2>/dev/null; then
  warn "references/rules.md still has placeholder sections"
fi
if grep -q "TBD" "$PLUGIN_ROOT/references/rules.md" 2>/dev/null; then
  warn "references/rules.md still has TBD entries"
fi
if grep -q "CRITICAL" "$PLUGIN_ROOT/references/open-questions.md" 2>/dev/null; then
  warn "open-questions.md has unresolved CRITICAL items"
fi

echo "---------------------"
if [[ $ERRORS -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$ERRORS check(s) failed."
  exit 1
fi
