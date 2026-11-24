# Autopilot

Agents run unattended: full access, auto retry, prompt suggestions. Touches only agent autonomy; pair it with Calm or leave notifications alone.

One axis: **agent autonomy**. Nothing here is a default; it changes only what you install.

| Setting | Value |
| --- | --- |
| `agents.defaultPermissionMode` | `"fullAccess"` |
| `agents.autoRetry.enabled` | `true` |
| `agents.promptSuggestions` | `true` |

Its rival is [safe-agents](../safe-agents/README.md): the two set the same keys, so installing one after the other replaces the earlier one on those keys.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/setups/autopilot@feat-cmux-next
cmux setup remove manaflow-ai/autopilot-setup
```

`remove` puts back what you had on these keys.
