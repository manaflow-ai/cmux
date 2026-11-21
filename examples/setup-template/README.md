# My Look

![My Look on an agent chat](screenshots/chat.png)

One paragraph: what it looks like and who it is for.

```sh
cmux setup install github.com/OWNER/REPO
cmux setup remove OWNER/my-look
```

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's type and width and the sidebar's density |
| `themes/my-look.json` | The colors, surfaces, borders and density |
| `agent-pane/theme.css` | The chat's paint, with `cmux.agentPane.style/1` tokens only |

## Making changes

```sh
cmux setup check .          # every finding at once; writes nothing
```

Release: bump `version` in `cmux-setup.json`, run `cmux setup check . --strict`, then tag the same
version and push. How looks like this one are made and kept working across cmux updates:
[customization-repos.md](https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/docs/cmux-next/customization-repos.md).
