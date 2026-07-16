---
name: example-skill
description: A template example of a per-loop skill. Use this to describe custom scripts, tools, or runbooks specific to this loop that the agent can execute.
---
# Example Per-Loop Skill

This is a template example demonstrating how to author a custom, per-loop skill. 

Per-loop skills live inside `loops/<loop-name>/skills/<skill-name>/` and are automatically discovered and loaded into the agent's environment at runtime under `.claude/skills/<skill-name>/`.

## Usage

Describe how the agent should utilize this skill. You can include:
- Instructions on executing specific scripts within the skill directory.
- Code blocks showing how to import or call specific helpers.

```python
# Code example showing how the agent can interact with this skill
print("Hello from the example-skill!")
```

## Rules
- Define clear steps for the agent to achieve the skill's goal.
- Avoid placing credentials or secrets here; keep secrets in Google Secret Manager and use the auth proxy.
