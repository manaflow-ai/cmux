# Terminal-first

A terminal multiplexer that happens to host agents: no chat main pane, new panes split, focus follows the mouse. Touches only where the agent lives and the pane model.

One axis: **where the agent lives, and the pane model**. Nothing here is a default; it changes only what you install.

| Setting | Value |
| --- | --- |
| `layout.mainPane` | `"off"` |
| `layout.newPanePlacement` | `"split"` |
| `layout.focusFollowsMouse` | `true` |
| `layout.splitSizing` | `"even"` |

Its rival is [chat-first](../chat-first/README.md): the two set the same keys, so installing one after the other replaces the earlier one on those keys.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/setups/terminal-first@feat-cmux-next
cmux setup remove manaflow-ai/terminal-first-setup
```

`remove` puts back what you had on these keys.
