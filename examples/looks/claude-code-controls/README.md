# Claude Code controls

Install the pieces you use. Each folder is an independent setup. For example, to add the model and composer shortcuts, run

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code-controls/composer@feat-cmux-next
```

Use another folder name from the table for another piece. To remove the composer piece, run `cmux setup remove manaflow-ai/claude-code-composer`. For a pull request, replace `feat-cmux-next` with its commit SHA.

| Folder | What to do |
| --- | --- |
| `cli` | In the palette choose **Start Claude Code CLI** or **Resume Claude Code CLI Session…**. Each opens a new terminal tab. Resume opens Claude’s session picker. |
| `modes` | With a cmux chat focused, press ⌘J then M to open the access menu, or ⌘J then P to toggle Plan. For the CLI’s Shift-Tab mode cycle, choose **Start Claude Code CLI in Plan Mode** from the palette. Claude handles available modes and approval prompts. |
| `composer` | With a chat focused, press ⌥P to open the model picker with your draft in place. Press ⌘J then A to open the attachment and command menu. The picker shows the models and options available to that harness. |
| `side-question` | In a chat with side sessions available, press ⌘J then B. The composer opens with `/btw ` ready for your question. Send it when ready. |
| `cloud` | With a chat focused, press ⌘J then C to open cmux’s computer picker. To bring a Claude-hosted conversation into a local CLI tab, choose **Resume Claude Cloud Session in CLI…** from the palette, then select the session. Claude handles sign-in and availability. |
| `export` | With a cmux conversation focused, press ⌘J then X to copy it as Markdown. For a Claude CLI conversation, run `/export` in its terminal for the copy or save dialog, or `/export filename.txt` to write plain text. |

The CLI actions use the installed `claude` executable. Shortcuts go to cmux’s existing chat controls. The ⌘J chords are cmux bindings supplied by these setups.

[Claude Code keyboard controls](https://code.claude.com/docs/en/interactive-mode) · [Permission modes](https://code.claude.com/docs/en/permission-modes) · [Slash commands](https://code.claude.com/docs/en/commands) · [CLI flags](https://code.claude.com/docs/en/cli-reference)
