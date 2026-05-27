# /opera-base:yaml-gen

Generates a YAML file from the operational rules defined in `references/rules.md`.

## Usage

```
/opera-base:yaml-gen
/opera-base:yaml-gen --rule <rule_id>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `--rule <id>` | Generate YAML for a single rule instead of all rules |

## Output

Prints the YAML block to stdout. Redirect to a file if needed:

```
/opera-base:yaml-gen > output.yaml
```

## Dependencies

- `references/rules.md` must be populated before running this command
- Skill: `skills/yaml-gen/SKILL.md`
