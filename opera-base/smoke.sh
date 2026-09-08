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
    ERRORS=$((ERRORS + 1))
  fi
}

fail() {
  echo "  [FAIL] $1"
  ERRORS=$((ERRORS + 1))
}

warn() {
  echo "  [warn] $1"
}

echo "opera-base smoke test"
echo "---------------------"

echo "manifest"
check "plugin.json" "$PLUGIN_ROOT/.claude-plugin/plugin.json"

# Claude Code plugins auto-discover skills/*/SKILL.md and commands/*.md by
# convention — plugin.json carries no skills/commands arrays, so check the
# discovery files directly rather than grepping the manifest.
COMPONENTS=(yaml-gen operonix-deploy dockerfile-scan image-scan)

echo "skills"
for s in "${COMPONENTS[@]}"; do
  check "$s/SKILL.md" "$PLUGIN_ROOT/skills/$s/SKILL.md"
done

echo "commands"
for c in "${COMPONENTS[@]}"; do
  check "$c.md" "$PLUGIN_ROOT/commands/$c.md"
done

echo "references"
check "rules.md"           "$PLUGIN_ROOT/references/rules.md"
check "open-questions.md"  "$PLUGIN_ROOT/references/open-questions.md"

echo "plugin.json"
MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -q '"name"[[:space:]]*:[[:space:]]*"opera-base"' "$MANIFEST" \
  && echo "  [ok] name = opera-base" || fail "plugin.json missing name \"opera-base\""
grep -Eq '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$MANIFEST" \
  && echo "  [ok] semver version present" || fail "plugin.json missing/invalid version"

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
