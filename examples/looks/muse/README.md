# Muse

cmux as a Muse bot. Install it and cmux opens like a Muse app: every New Tab is the Muse home, Command-N
starts a Muse chat, and the window takes Muse's colors and chat shape. Under it, each chat is a real
Muse Code (Meta's coding agent, the `muse` harness) session in cmux, with its tools, files and terminal.

![Muse, dark](screenshots/muse-dark.png)

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/muse@feat-cmux-next
cmux setup remove manaflow-ai/muse-look   # everything you had comes back
```

It needs the Muse harness installed and signed in (Settings > Agents). Without it, the prompt box
says why the chat did not start.

## What it sets

| Surface | File | What |
| --- | --- | --- |
| Theme file | [themes/muse.json](themes/muse.json) | A deep ink page (#0b0f1a), a navy sidebar and Meta blue (#0866ff) for marks |
| Settings | [cmux-setup.json](cmux-setup.json) | The Muse home as the New Tab app, messages presentation, prompts in bubbles, a pill message box centered in an empty chat, a quiet header, a sidebar of titles only, no tab strip for a lone chat |
| View | [customize/](customize) | `cmux.newtab/1`: a greeting, one prompt box that starts a Muse chat (`palette.newAgentChat` with `harness: "muse"`), suggestion chips (Explain this repo, Plan a feature, Review my diff) and your recent Muse chats |
| Chat paint | [agent-pane/theme.css](agent-pane/theme.css) | `cmux.agentPane.style/1` tokens only: bubble tint and corners, card ring, link color |
| Keys | [keybindings.json](keybindings.json) | Command-N: new Muse chat |

## Make your own bot

Copy this folder and change three things: the harness id (`HARNESS` in customize/main.js and the
`harness` in keybindings.json), the words (`agentPane.composerPlaceholder`, the greeting) and the
theme file's colors. Every other key is shared with the other chat-assistant looks
([halo](../halo)).

## What this look could not set

- The bot's own name and avatar beside replies: the sender icon follows the harness's family
  (`agentPane.display.senderIcon.lead`), and no key renames it.
- Its colors are picked to evoke the Muse app, not measured from a capture of it.
- A default harness for the palette's New Agent Chat: `agent.defaultHarness` is refused to looks, so
  only Command-N and the New Tab home start Muse.
