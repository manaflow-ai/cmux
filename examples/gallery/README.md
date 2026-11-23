# Customization gallery

Five starter looks, each using one part of the customization API, and `gallery.json`, an index of
every example in this repository: these five, the ten whole looks in [`../looks`](../looks), the
showcase profiles in [`../customize-showcase`](../customize-showcase) and the extensions in
[`../extensions`](../extensions). The index is in the shape a customization repo of its own would
publish, so a gallery page or `cmux customize` can list it.

| Starter | What it uses | Install |
| --- | --- | --- |
| [Starter Dusk](theme-file) | A theme file (`themes/*.json`) and `appearance.themeFile` | `cmux setup install github.com/manaflow-ai/cmux/examples/gallery/theme-file@feat-cmux-next` |
| [Starter Actions](actions-and-keys) | `actions` in the setup and a `keybindings.json` | `cmux setup install github.com/manaflow-ai/cmux/examples/gallery/actions-and-keys@feat-cmux-next` |
| [Starter Sidebar View](sidebar-view) | A Scene SDK customize app: `cmux.hovercard/1` and `cmux.sidebar.rows/1` | `cmux setup install github.com/manaflow-ai/cmux/examples/gallery/sidebar-view@feat-cmux-next` |
| [Starter Chat Style](chat-style) | Chat and Markdown settings, `agent-pane/theme.css`, `markdown/theme.css` | `cmux setup install github.com/manaflow-ai/cmux/examples/gallery/chat-style@feat-cmux-next` |
| [Starter Thinking Dots](thinking-dots) | A `cmux.particles/1` thinking glyph kept as a file (`{"$file": PATH}`); needs cmux#47525 | `cmux setup install github.com/manaflow-ai/cmux/examples/gallery/thinking-dots@feat-cmux-next` |

`cmux setup install` shows what the look changes before it applies anything. `cmux setup remove
OWNER/NAME` (the look's `id`) puts back what you had. To try a look you are still writing, push
its folder to a branch and install from that branch: `@REF` takes any branch, tag or commit, and
the install fetches only the look's folder.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/gallery/chat-style@lane/my-branch
cmux setup remove manaflow-ai/starter-chat-style
```

`cmux customize use FILE` (then `apply` or `discard`) takes a profile file, not a look folder. A
look's `cmux-setup.json` has comments and keeps its files beside it, so `use` cannot read it
directly. [`../customize-showcase/bundle.py`](../customize-showcase/bundle.py) shows how a folder
becomes one profile file.

## Make your own

Copy a starter folder into a repo of your own and change three things in `cmux-setup.json`:

- `id`, `OWNER/NAME`: OWNER must be the GitHub owner of the repo. Install refuses any other id.
- `name` and `tagline`: what a gallery shows.
- `screenshots`: paths in the folder. A look in `../looks` shows the convention: one Dark and one Light image.

A look's folder holds only these files. Install ignores anything else, such as the README:

| File | Goes to | Surface in `gallery.json` |
| --- | --- | --- |
| `cmux-setup.json` `settings` | `cmux-next.json` | `settings` |
| `cmux-setup.json` `actions` | `cmux-next.json` `actions` | `actions` |
| `themes/*.json` | `~/.config/cmux/themes/` | `theme-file` |
| `customize/cmux-app.json`, `customize/main.js` | `~/.config/cmux/customize/` | `view` |
| `agent-pane/theme.css` | the agent chat's stylesheet | `agent-pane-css` |
| `markdown/theme.css` | the Markdown viewer's stylesheet | `markdown-css` |
| `keybindings.json` | `~/.config/cmux/keybindings.json` | `keybindings` |
| `{"$file": PATH}` as a setting's value | that setting, with the file's JSON as its value (needs cmux#47525) | `particles` for the thinking glyph |

## `gallery.json`

```jsonc
{
  "$schema": "cmux.gallery/1",
  "repository": "github.com/manaflow-ai/cmux",   // HOST/OWNER/REPO
  "ref": "feat-cmux-next",                       // the branch or tag to install from
  "root": "examples",                            // where entry paths start
  "entries": [
    // kind: look (a folder with cmux-setup.json), profile (a profile file for `cmux customize use`)
    // or extension (a folder with cmux-app.json for `cmux ext dev`).
    // surfaces: which parts of the API the look uses, as in the table above.
    // needs: a change the entry waits for; installing it fails until that change ships.
    {"kind": "look", "path": "gallery/thinking-dots", "surfaces": ["settings", "particles"], "needs": "cmux#47525"}
  ]
}
```

Names, taglines and screenshots stay in each look's own `cmux-setup.json`, so the index cannot
drift from the looks. A look's install line is `cmux setup install
REPOSITORY/ROOT/PATH@REF`.

## Checks

`cargo test -p cmux-customize --test gallery` checks the following:

- Every entry exists.
- Every look folder in `looks/` and `gallery/` is listed.
- Each look's `surfaces` match what its folder holds, and its screenshots exist.
- Its install line resolves to its folder.
- Each look without `needs` plans, installs on a fresh machine with nothing to fix, and removes back to nothing.
- The thinking dots document holds together: frames are in order, no frame has more dots than `particle.max`, scales are 0 to 4, and every trigger names a phase.

After cmux#47525, install checks that document with the full `cmux.particles/1` validator.
