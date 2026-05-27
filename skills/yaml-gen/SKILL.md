# Skill: yaml-gen

## Trigger

Fire this skill when the user asks to:
- generate YAML from operational rules
- convert rules to YAML
- produce configuration from the Operonix rule set
- `/opera-base:yaml-gen`

## Context

Read `references/rules.md` before generating any output. The rules file is the authoritative source of truth — do not invent conditions or actions not present there.

## Methodology

1. Load `references/rules.md`
2. Parse each rule block (ID, condition, action, output)
3. Map each rule to a YAML structure (see schema below)
4. Validate: every required field must be present; warn if any rule is incomplete
5. Output the final YAML block

## Output schema

<!-- TO BE DEFINED after the Operonix meeting -->
<!-- Placeholder — replace with the agreed YAML schema -->

```yaml
rules:
  - id: <rule_id>
    condition: <condition>
    action: <action>
    output: <output>
```

## Constraints

- Do not add fields not present in the rule definition
- Preserve rule IDs exactly as written in rules.md
- Output must be valid YAML (no tabs, consistent indentation of 2 spaces)
