# My Look

![My Look on an agent chat](screenshots/chat.png)

One paragraph: what it looks like and who it is for.

Before installing or publishing, replace `OWNER` and `REPO` here and in `cmux-setup.json`.
Use a lowercase setup id whose owner matches the repository owner, set `engines.cmux` to the
oldest version you tested, and add your screenshots.

```sh
cmux setup install github.com/OWNER/REPO
cmux setup remove OWNER/my-look
```

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's type and width and the sidebar's density |
| `themes/my-look.json` | The colors, surfaces, borders and density |
| `agent-pane/theme.css` | Optional chat paint; inspect it in the app because token validation is not available |

## Making changes

```sh
cmux setup check .          # every finding at once; writes nothing
```

Release: bump `version` in `cmux-setup.json`, run `cmux setup check . --strict`, then tag the same
version (for example, `v0.1.0` for `0.1.0`) and push. Updates follow the installed source ref,
not automatically the latest release tag. How looks like this one are made and kept working across cmux updates:
[customization-repos.md](https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/docs/cmux-next/customization-repos.md).
