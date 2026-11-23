# Example extensions

Each sample below is built only on the public SDK (`cmux-extension-sdk`). Install one with the
single command next to it, run from the root of this repository with cmux open. Accept the install
card once; after that, every save to its `src/main.ts` reloads it. Ctrl-C stops the reload loop,
and the sample stays installed. `cmux ext remove ID` uninstalls it.

| Sample | What it shows | Install |
| --- | --- | --- |
| [Widgets](widgets) | Clock, weather, calendar and to-do cards in small, medium and large sizes, each added on its own | `examples/extensions/widgets/install.sh` |
| [Weather](weather) | The current conditions for a place you choose | `cmux ext dev examples/extensions/weather` |
| [World clock](world-clock) | The time in the places you work with | `cmux ext dev examples/extensions/world-clock` |
| [Changes](changes) | A live pull request list: lines added and removed, checks, review; your branch, yours, mentions or a saved search | `cmux ext dev examples/extensions/changes` |
| [Recent PRs](recent-prs) | Your pull requests from the last 72 hours, in the sidebar | `cmux ext dev examples/extensions/recent-prs` |
| [Agent pet](agent-pet) | A cat that reacts as your agents work, wait or fail | `cmux ext dev examples/extensions/agent-pet` |
| [Standup](agent-standup) | What your agents did since yesterday, by project | `cmux ext dev examples/extensions/agent-standup` |
| [Workspace notes](workspace-notes) | A short to-do list for each workspace | `cmux ext dev examples/extensions/workspace-notes` |
| [json-render widgets](json-render) | A widget an agent writes as a json-render spec from a fixed catalog, drawn with the kit in the sidebar and in chat | `cmux ext dev examples/extensions/json-render` |
| [Design system](design-system) | A design system of your own on top of cmux's, and a pane that shows its type, spacing, colors and components | `cmux ext dev examples/extensions/design-system` |
| [The Leo collection](leo-collection) | Clock, weather, gacha and usage, riced up, with a look that ties them together | `examples/extensions/leo-collection/install.sh` |

`cmux ext dev` packs `src/main.ts` with `bun`, so `bun` must be on your PATH. `bun
examples/extensions/build.ts --check` packs every sample and validates its manifest.
