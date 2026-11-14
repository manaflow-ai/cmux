# Example extensions

Each sample below is built only on the public SDK (`cmux-extension-sdk`). Install one with the
single command next to it, run from the root of this repository with cmux open. Accept the install
card once; after that, every save to its `src/main.ts` reloads it. Ctrl-C stops the reload loop,
and the sample stays installed. `cmux ext remove ID` uninstalls it.

| Sample | What it shows | Install |
| --- | --- | --- |
| [Weather](weather) | The current conditions for a place you choose | `cmux ext dev examples/extensions/weather` |
| [World clock](world-clock) | The time in the places you work with | `cmux ext dev examples/extensions/world-clock` |
| [Recent PRs](recent-prs) | Your pull requests from the last 72 hours, in the sidebar | `cmux ext dev examples/extensions/recent-prs` |
| [Agent pet](agent-pet) | A cat that reacts as your agents work, wait or fail | `cmux ext dev examples/extensions/agent-pet` |
| [Standup](agent-standup) | What your agents did since yesterday, by project | `cmux ext dev examples/extensions/agent-standup` |
| [Workspace notes](workspace-notes) | A short to-do list for each workspace | `cmux ext dev examples/extensions/workspace-notes` |

`cmux ext dev` packs `src/main.ts` with `bun`, so `bun` must be on your PATH. `bun
examples/extensions/build.ts --check` packs every sample and validates its manifest.
