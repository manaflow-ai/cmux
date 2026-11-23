# Looks

A look is a folder that `cmux setup install` applies as one layer and `cmux setup remove` takes
back off. Whole looks sit at `looks/NAME/`; [basalt](basalt) is the reference. Looks that change
one feature of one app sit at `looks/APP/FEATURE/`. Small starters, one per part of the API, are
in [`../gallery`](../gallery). [`../gallery/gallery.json`](../gallery/gallery.json) indexes
the whole looks and the starters; add an entry for a new one.

## Looks written only on public surfaces

These five are written the way anyone outside the cmux team could write a look: a theme file, a few
settings, a stylesheet of public chat tokens (`cmux.agentPane.style/1`) and a sidebar view
([docs/cmux-next/look-addons.md](../../docs/cmux-next/look-addons.md)).

| Look | What it is |
| --- | --- |
| [`gel`](gel) | Soft sea-glass tonal surfaces, glass where layers float, the flush corner with goo fillets |
| [`grove`](grove) | A forest look: unbleached paper by day, night forest by dark, moss ink, frosted-air glass over a painted grove |
| [`aurora`](aurora) | Clear glass chrome over your desktop, a solid chat, a teal-to-violet accent used sparingly; light and dark |
| [`studio`](studio) | A dense workbench in dark, light and ember: quiet chrome, compact rows, a filled prompt with soft corners |
| [`paper`](paper) | A warm, roomy reading look: serif replies on paper, soft rounded prompts |

[`looks.json`](looks.json) lists them and the built-in preset each recreates, if any. Besides the
gallery test, CI installs each one (`cmux-customize` `tests/example_looks.rs`), holds its stylesheet
to the public token list (`bun run check:look-addons`), and draws it in the real chat to check that
nothing moves (`webviews/test/browser/look-addons.test.ts`).

## The folder

```
looks/APP/FEATURE/
  cmux-setup.json          id, name, tagline, screenshots, settings, actions (JSONC)
  README.md                what it does, its files, how to install it (never applied)
  screenshots/             the images cmux-setup.json lists (never applied)
  themes/*.json            theme files; settings pick one with appearance.themeFile
  customize/cmux-app.json  the customize app (local/customize): views of the look's own
  customize/main.js
  agent-pane/theme.css     cmux.agentPane.style/1 tokens for the agent chat
  markdown/theme.css       --cmux-md-* tokens for the Markdown viewer
  keybindings.json         shortcuts, for example to cmuxConfig.<action>
```

Install reads only the files above (`cmux-tui/crates/cmux-customize/src/setup.rs`, `repo_files`)
and ignores everything else. Every part is optional except `cmux-setup.json`. In `cmux-setup.json`:

- `id` is `manaflow-ai/NAME`. Install refuses an id whose owner is not the repo's owner.
- `cmuxSetup` and `cmuxProfile` are both `1`.
- Every key in `settings` must be one the running build knows and an agent may set. Install refuses
  the whole look otherwise. Write a key that is still in review as a comment naming its pull
  request, as [basalt's](basalt/cmux-setup.json) does.

## Apply it

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/APP/FEATURE@feat-cmux-next
cmux setup remove manaflow-ai/NAME
```

Keep `@feat-cmux-next` while these folders exist only on that branch: without `@REF`, install reads
the repo's default branch, `main`. `@REF` takes any branch, tag or commit. To try a look you are
still writing, push it to your lane branch and install `@lane/BRANCH`; install fetches only the
look's folder. Install shows what the look changes before it applies anything.

`cmux customize use FILE`, then `cmux customize apply` or `cmux customize discard`, previews a
profile file: one JSON file with `settings` and its `files` inline. A look folder is not one,
because its `cmux-setup.json` has comments and its files sit beside it. To preview a folder that
way, bundle it into one file first, as
[`../customize-showcase/bundle.py`](../customize-showcase/bundle.py) does for its folders.

## Check it

`cargo test -p cmux-customize --test gallery` (on the fleet:
`cmux-ci test -- cargo test -p cmux-customize --test gallery`) finds every folder with a
`cmux-setup.json` under `looks/` and `gallery/`, at any depth. For each one it plans, installs on a
fresh machine with nothing to fix, checks every file landed as written, and removes it back to
nothing. It also checks that each look in `gallery.json` names the surfaces its folder uses and
that its screenshots exist.

[`../customize-demo/looks/check`](../customize-demo/looks/check) does the same preview for
profile files (`cargo run --manifest-path examples/customize-demo/looks/check/Cargo.toml --
FILE.json ...`).

## Looks written on public surfaces

These whole looks are written the way anyone outside the cmux team could write one: a theme file, a
few settings, a stylesheet of public chat tokens and a sidebar view, in one setup
([docs/cmux-next/look-addons.md](../../docs/cmux-next/look-addons.md)). Each also lives in a small
repo of its own, like dotfiles; the folder here is a copy that cmux's own tests check, and its setup,
theme, stylesheet and view files are the repo's. Change a look in its repo.

| Look | Its repo | What it is |
| --- | --- | --- |
| [`studio`](studio) | [manaflow-ai/cmux-studio-look](https://github.com/manaflow-ai/cmux-studio-look) | A quiet black workbench for agent threads: New thread and Search rows, thread cards by project with their age, settled chats folded away, the Studio composer, filled prompt bubbles, one bright blue; dark, light and ember variants |
| [`paper`](paper) | [manaflow-ai/cmux-paper-look](https://github.com/manaflow-ai/cmux-paper-look) | A warm, roomy reading look: serif replies on paper, soft rounded prompts |

```sh
cmux setup install github.com/manaflow-ai/cmux-studio-look   # on, as one layer
cmux setup remove manaflow-ai/studio-look                     # off; yours comes back
```

Keys still in review sit in these folders as comments naming their pull request, as in basalt.
[`looks.json`](looks.json) lists these looks and the built-in preset each recreates. CI installs
each one (`cmux-customize` `tests/example_looks.rs`), holds its stylesheet to the public token list
(`bun run check:look-addons`), and draws it in the real chat to check that nothing moves
(`webviews/test/browser/look-addons.test.ts`). Like every whole look, each is in
[`../gallery/gallery.json`](../gallery/gallery.json).

## What a look can change today

Settings (any key an agent may set; `cmux settings list` prints them all):

| Area | Keys |
| --- | --- |
| Sidebar proportions | `appearance.metrics.sidebarWidth`, `appearance.metrics.sidebarRowHeight`, `sidebar.density`, `sidebar.textSize` |
| Sidebar content | `sidebar.groupBy`, `sidebar.groupHeader.*`, `sidebar.workspaceRow.*` (also per kind: `.agent.*`, `.terminal.*`, `.browser.*`, `.mixed.*`), `sidebar.showTimestamps`, `sidebar.settleFinished` (seen, finished chats fold behind a Settled row), `sidebar.sessionTree`, `sidebar.priorityView.enabled` |
| Hover cards | `sidebar.hoverCards.*` |
| Chrome | `appearance.chromeStyle`, `appearance.borders`, `appearance.density`, `appearance.metrics.*` (tab and chrome font sizes, column gap, dividers) |
| The agent chat | `agentPane.display.*` (font, size, line height, code scale, width, minimap), `agentPane.composerRing` |
| New tab | `tabs.newTabApp` (`local/customize` draws your own page) |
| Layout and behaviour | `layout.*` (main pane, where links and new terminals open, split sizing, docked columns), `tabs.barPosition`, `tabs.barOrder`, `tabs.toolbarButtons`, `browser.toolbarPosition`, `sidebar.workspacesAsTabs`, `sidebar.sideBySide`, `home.chiefDock.edge`; with `keybindings.json` and `actions`, a keyboard mode or a review layout: [leader](leader), [review-desk](review-desk), [bottom-deck](bottom-deck), [workspace-tabs](workspace-tabs) |

Interfaces a look's `customize/` app can implement (`cmux-tui/crates/cmux-app-host/interfaces/`;
all are drafts):

| Interface | What it draws |
| --- | --- |
| `cmux.section/1` | A sidebar section the person places in a sidebar region |
| `cmux.sidebar.rows/1` | Decorations of the workspace rows: icon, weight, indicator, badge (only from `local/customize`) |
| `cmux.session.info.section/1` | A section in the agent's Session Info panel |
| `cmux.newtab/1` | A whole New Tab page, when `tabs.newTabApp` names the app |
| `cmux.widget/1` | A tile on the New Tab widget grid or in the sidebar |
| `cmux.hovercard/1` | The hover card of a sidebar row (only from `local/customize`) |
| `cmux.palette.scope/1` | A Command Palette scope: items, actions, detail views |
| `cmux.opener/1` | Opens links whose URL or scheme matches before cmux does |
| `cmux.composer.command/1` | Slash commands in the chat composer's / menu |

From a click in its views, a customize app can run an action with the host op `action.run`. That
includes the person's own `cmuxConfig.<name>` actions, which need the `actions:run` scope and a
live gesture (`cmux-tui/crates/cmux-app-host/js/ABI.md`).

Not possible yet:

- Buttons in the composer's toolbar. The composer takes slash commands (`cmux.composer.command/1`)
  and mentions (`cmux.composer.mention/1`), but no interface or setting adds a button to it.
- A model picker. No interface or setting draws or replaces it.
