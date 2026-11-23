# Widgets

Leo, 2026-11-18: "those are extremely lame customizations. we want to show the claude/codex/studio
ones. plus the previous ones that were made for the last demo, looking better. plus glass stuff.
plus the widgets. this is not enough as a demo"

**"Widgets" is our reading.** cmux NEXT defines no single widget surface. `cmux.widget/1` is
validated, laid out and ticked by the daemon, but no page draws it yet
(`docs/cmux-next/extensions/state-of-the-sdk.md`). So these widgets are cards drawn by the customize
app (`local/customize`), in the places that do draw today: the sidebar, each chat's Session Info
and the New Tab page. The customize recipes already call such cards widgets
(`docs/cmux-next/customize-recipes.md`, "Widgets": `pr-widget`, `clock-weather`).

## Try it

```sh
cmux customize use examples/customize-demo/widgets/widgets.json
cmux customize apply      # keep it
cmux customize discard    # put your setup back
```

## What shows where

| Place | Cards |
| --- | --- |
| Sidebar (bottom, cards look) | **Today**: a big clock, the weather icon and temperature, the city's high and low. **Agents**: Byte the cat, whose color and line follow your agents (a click opens the chat that waits), Working / Waiting / Done (finished today) counters and the latest chats. **Usage**: Claude and Codex, the weekly percent left counting up, a bar, the session left, pace and extra spend. **Pull requests**: your open PRs with a checks icon, +/− lines, passed/total checks and a review badge. |
| Session Info (every chat) | **Agent**: this chat's state, harness, folder and age. **Usage** for this chat's provider only. **Branch**: the chat branch's PR with a checks bar (passed / running / failed). |
| New Tab (`tabs.newTabApp`) | The same cards two a row (Today and the World clock beside Agents, then Usage beside Pull requests; Pull requests take the whole row where Usage is left out), plus a **World clock** (LA, New York, London, Tokyo, day or night) and six chats in Agents. The page has no wrap, so two a row is what fits a pane from 600 pt up. |

The code comes from the tested examples: Today and Usage from `customize-showcase/collection`,
the mood from `extensions/agent-pet`, the day summary from `extensions/agent-standup`, the zones
from `extensions/world-clock`. PRs read the runtime's shared `github.changes` signal. Each card
uses only the kit in `skills/cmux-customization/references/local-app-views.md`: theme tones and
font names, no hex colors or point sizes. So the cards follow every theme, including the glass
and studio looks.

On a cmux whose views cannot reach the Usage app yet (`usage_app.status` answers
`operation.unsupported`, as in the 2026-11-19 NIGHTLY), the Usage cards are left out, not drawn as
an error. The Pull requests card needs the network: until you turn off Run sandboxed for Widgets it
says so in words ("Pull requests need the network"), as it does when you are not signed in.

The New Tab page and Session Info are web pages that draw only cmux's icon pack, so every icon
the cards use is a pack name (`notification`, `history`, `status.complete`); the sidebar draws
those too, and keeps SF Symbols only for the weather and Byte the cat.

## Scopes

Reads are granted at install: `agent:read`, `agent_chat:read`, `usage_app:read`,
`integration:github:read`, `storage:local`. The app installs sandboxed (no network), so the
weather and the pull requests need Run sandboxed turned off in Settings > Apps > Widgets. Turn the
rest on there: `net:geocoding-api.open-meteo.com` and `net:api.open-meteo.com` for the weather, and
`actions:run` so a click opens a chat or a PR. With GitHub not connected, the PR card says so.

## Change it

Edit `widgets/customize/main.js` or `cmux-app.json`, then `python3 examples/customize-demo/widgets/bundle.py`
(it uses the showcase bundler; `--check` fails while `widgets.json` is stale).

`bun examples/customize-demo/widgets/render/render.ts` mounts the three places in the reference
fake host (`cmux-tui/crates/cmux-app-host/js/test/fake-host.ts`) with fixture agents, usage, weather
and PRs. It prints each scene tree; `shots/scene-trees.txt` is its output. These are not pixel
screenshots: drawing the scenes needs the Mac app.
