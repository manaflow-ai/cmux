# Leader

A keyboard mode for the window, the way a terminal multiplexer's prefix key works: press Command-J, let go,
then one key. Command-J is cmux's own leader already (Command-J T opens the Quick Terminal,
Command-J S a new chat), so the look takes no key a terminal, a chat or a page types. Hold
Command to see the keys.

| After Command-J | Does |
| --- | --- |
| `V` / `-` | Split right / split down |
| `Z` | Zoom the pane (again to unzoom) |
| `E` | Even out the splits |
| `O` | Float the pane over the others |
| `X` | Close the tab |
| `C` | New terminal tab |
| `A` | New agent chat to the right |
| `D` | Open the diff viewer |
| `B` | Hide or show the sidebar |
| `]` / `[` | Next / previous workspace |
| `W` then `H` `J` `K` `L` | Focus the pane left, below, above, right |
| `R` then `H` `J` `K` `L` | Resize the pane that way |
| `M` then `H` `J` `K` `L` | Move the tab to the pane that way |

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Shows the shortcut hints while you hold a modifier (`shortcuts.showModifierHoldHints`) and keeps Vim keys in pages (`browser.vimKeys`: `f` clicks a link, `j` and `k` scroll) |
| `keybindings.json` | The 24 leader keys above |

The look's `keybindings.json` takes the place of yours while it is installed; `remove` puts yours
back. To keep yours, ask an agent to add these keys to it instead.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/leader@feat-cmux-next
cmux setup remove manaflow-ai/leader
```

Or try it as a preview: `cmux customize recipes --open`, then the Leader recipe's Run button.
