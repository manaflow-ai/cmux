# Safe agents

Agents ask before they act and cmux asks before closing an agent session. Touches only agent autonomy.

One axis: **agent autonomy**. Nothing here is a default; it changes only what you install.

| Setting | Value |
| --- | --- |
| `agents.defaultPermissionMode` | `"ask"` |
| `app.warnBeforeClosingAgentSession` | `true` |
| `agents.autoRetry.enabled` | `false` |

Its rival is [autopilot](../autopilot/README.md): the two set the same keys, so installing one after the other replaces the earlier one on those keys.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/setups/safe-agents@feat-cmux-next
cmux setup remove manaflow-ai/safe-agents-setup
```

`remove` puts back what you had on these keys.
