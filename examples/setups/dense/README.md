# Dense

Everything small and in view: ultra-compact chrome, a sidebar rail, the tab bar at the bottom. For people on a small laptop screen or who run many workspaces.

One axis: **density**. Nothing here is a default; it changes only what you install.

| Setting | Value |
| --- | --- |
| `appearance.density` | `"ultraCompact"` |
| `sidebar.style` | `"rail"` |
| `sidebar.density` | `"compact"` |
| `tabs.barPosition` | `"bottom"` |
| `agentPane.display.minimap` | `"off"` |
| `layout.panePadding` | `2` |

It has no rival: it shares no key with any other setup here, so it stacks with all of them.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/setups/dense@feat-cmux-next
cmux setup remove manaflow-ai/dense-setup
```

`remove` puts back what you had on these keys.
