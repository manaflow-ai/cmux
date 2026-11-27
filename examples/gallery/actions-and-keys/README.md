# Starter Actions

Actions and shortcuts with no colors. Teams share this shape so every machine has the same
commands.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Three `actions`: Run Tests and Start Dev Server (`type: command`, each in a new tab) and Claude in a New Tab (`type: agent`). Each one registers as `cmuxConfig.<name>` in the Command Palette and for `cmux action run` |
| `keybindings.json` | Cmd-Shift-T runs `cmuxConfig.starter-tests`. Cmd-Shift-D runs `cmuxConfig.starter-dev` |

Your own actions and shortcuts stay. If the setup replaces one of your actions with the same name,
`remove` puts yours back.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/gallery/actions-and-keys@feat-cmux-next
cmux action run cmuxConfig.starter-tests
cmux setup remove manaflow-ai/starter-actions
```
