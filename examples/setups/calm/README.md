# Calm

Quiet cmux: few interruptions, nothing flashes. Touches only how cmux gets your attention. The Dock bounce is yours to set in Settings; a setup may not change it.

One axis: **interruption**. Nothing here is a default; it changes only what you install.

| Setting | Value |
| --- | --- |
| `notifications.desktop` | `"unlessFocused"` |
| `notifications.attention.flash` | `false` |
| `notifications.attention.flashOnTyping` | `false` |
| `notifications.dockBadge` | `true` |
| `notifications.sounds.volume` | `0.3` |
| `notifications.suppressWhileTypingSeconds` | `5` |
| `appearance.agentGlow` | `false` |
| `agentPane.display.thinking.shimmer` | `"cadenced"` |

It has no rival: it shares no key with any other setup here, so it stacks with all of them.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/setups/calm@feat-cmux-next
cmux setup remove manaflow-ai/calm-setup
```

`remove` puts back what you had on these keys.
