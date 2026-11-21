# Claude Code transcript width

Install this look to open chats with a 640 pt reading column and the Normal transcript view.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code/transcript-width@feat-cmux-next
```

In Settings → Agents → Chat Layout → More Options, choose Narrow (640 pt), Medium (800 pt), Wide (960 pt), or a custom Chat Text Width. The profile stores Narrow as 640 points so builds that already support numeric widths can install it too. The transcript and composer share the cap and fit smaller panes. Chat Full Width lets both fill the pane.

The Transcript View setting offers Normal, Thinking (opens thoughts), and Verbose (also opens tool output). A view chosen in a chat’s menu takes precedence for that chat.

```sh
cmux setup remove manaflow-ai/claude-code-transcript-width
```
