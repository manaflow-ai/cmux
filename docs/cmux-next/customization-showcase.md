# Customization samples

These are the small cmux NEXT examples Leo described: real app state in a view you can copy,
save, and watch reload. The source catalog is [`skills/cmux-customization/showcase.json`](../../skills/cmux-customization/showcase.json).

Open **Settings → Customize → Examples** to see the same list. App samples have an **App Store**
button; templates are copied into `~/.config/cmux/customize` and reload when `main.js` is saved.

| Sample | What it shows | Source |
| --- | --- | --- |
| **My PRs** | Keep your pull requests and review requests in the sidebar. Open one in a cmux browser tab. | [`templates/my-prs`](../../skills/cmux-customization/templates/my-prs) |
| **Agent threads** | Group live agents by state and jump to the terminal behind a chat. | [`templates/threads`](../../skills/cmux-customization/templates/threads) |
| **Quick links** | A saved Figma, docs, or dashboard list that also renders as a pane. | [`samples/apps/quick-links`](../../samples/apps/quick-links) |
| **GitHub PRs** | A `cmux.watch("github.pulls")` sidebar with real rows and browser actions. | [`samples/apps/github-prs`](../../samples/apps/github-prs) |
| **Session branch PRs** | A Session Info section that receives the current chat's branch. | [`samples/apps/session-prs`](../../samples/apps/session-prs) |
| **Running agents** | Agent state grouped in the sidebar; click a row to focus its terminal. | [`samples/apps/running-agents`](../../samples/apps/running-agents) |
| **Command buttons** | Buttons backed by the same `cmux-next.json` actions used by Cmd+K and shortcuts. | [`templates/command-button`](../../skills/cmux-customization/templates/command-button) |
| **Design links** | Paste and save Figma, FigJam, Linear, Notion, and Docs links. | [`templates/design-links`](../../skills/cmux-customization/templates/design-links) |
| **Clock and weather** | Timers, local storage, network scopes, and a live view in one small section. | [`templates/clock-weather`](../../skills/cmux-customization/templates/clock-weather) |
| **Standup notes** | Storage-backed add/list/clear commands exposed in the palette and CLI. | [`samples/apps/standup`](../../samples/apps/standup) |

## Install and reload

For a template, open **Settings → Customize → Examples** and choose **Copy install command**.
Paste the command in a terminal; it downloads the two checked-in files into
`~/.config/cmux/customize`, where every save hot-reloads the view. The command is intentionally
small enough to read and edit before running.

For an app sample, choose **Install**. The native consent card installs the packaged sample in
NIGHTLY without opening the Labs-gated App Store. The supervisor keeps it disabled until its
scopes are granted.

## Gallery captures

Each card has three short states in [`customization-showcase.gallery.md`](customization-showcase.gallery.md).
Capture a real local view with `cmux ext shot --json` (or `cmux ext shot --out /tmp/sample.png`),
then compare the default, empty, and error/permission state before reporting it as working.

## API gaps kept visible

The catalog deliberately does not promise CI badges, “Review this diff with Codex”, toolbar
buttons, a declarative Morning layout, or per-chat token cost. Those need a richer GitHub signal,
prompt/attachment arguments on new-agent actions, a toolbar host, a NEXT layout action, and a
per-session usage signal respectively. They are recorded in the catalog so a future SDK change
has an explicit acceptance target.
