# Projects (`cmux/projects`)

A widget (`cmux.widget/1`) with your recent projects for New Tab and the sidebar, each with a tile of
its own, and the name of the machine they are on. A store app: listed in the App Store, installed with
one click, not bundled (a `STORE` marker, no `BUNDLED`).

| Size | Shows |
| --- | --- |
| small | the machine's name after its colored dot, then four project tiles in a 2x2 grid |
| medium | `PROJECTS` and the machine's name, then eight tiles in two rows of four |
| large | a list of eight: tile, name over its short path (`~/code/cmux`), and how long ago it was used (`2m`, `3h`, `5d`) |

A tile is the project's first letter in white on a color of its own, a hash of its path, so a project
keeps its color everywhere and over time. The machine's dot is colored the same way from its id, so two
machines never look alike at a glance. Pinned projects come first, in their order, then the most
recently used; hidden and missing ones are left out, and a rename shows in place of the folder's name.
Tapping a project opens a new workspace with its folder as the working directory.

## Data

Only the public SDK (`cmux-extension-sdk`): `project.list` (scope `project:read`, the daemon's project
index, read through `cmux.live`), `machine.get` (scope `machine:read`, this machine's name) and
`workspace.create` (scope `workspace:write`, on a tap). The index has no change stream yet, so the list
re-reads on the host's minute tick (`refresh.everySeconds: 60`), only while the tile is shown. The Add
Widget gallery's preview (`ctx.preview`) draws sample projects and writes nothing.

## Development

```bash
bun test first-party-apps/widget-projects                 # logic and the packed widget in the fake host
bun first-party-apps/widget-projects/preview/build.ts     # preview/scenes.json
bun first-party-apps/build.ts widget-projects             # dist/main.js and the manifest check
cmux ext dev first-party-apps/widget-projects             # live in a running cmux
```

Gallery: `apps.projects-widget` draws `preview/scenes.json` (busy, few, empty, denied, sidebar, another
machine, every size) with the real scene renderer, light and dark.

## Gaps

- No favicons yet: the project's own icon (`favicon.svg`, `apple-touch-icon.png`, a repository's cmux
  icon) is read by the Mac app's `project.icon` agent-bridge method for the New Tab folder strip, which
  apps cannot call. Exposing it as an app op (read, `project:read`) lets the tile draw it in place of the letter.
- One machine: `project.list` answers this machine's index (the daemon resolves `machine` to itself
  only), so projects on other machines do not show yet; the header names the machine they are on.
- The screenshots are drawn from the gallery fixtures' data, not captured from a running cmux.
