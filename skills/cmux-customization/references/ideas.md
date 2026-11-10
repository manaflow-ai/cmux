# Ideas: what people make for cmux, from a first widget to a whole pane

Use this page when someone asks "what could I add to cmux?", or asks for one of the
things below. Each idea names the place it lives, the primitive it stands on, and
whether it works today. "Template" means a folder in [`../templates/`](../templates/)
that works as written ([install one](extensions.md#start-from-a-template)).

Leo, 2026-11-10, on what people asked for: "somebody wanted to customize their own
like pane ... what if somebody wanted to customize the new tab page itself? Like say
if somebody wants to make widgets for them, like the time, the weather ... somebody
could have their pull requests like somewhere in their sidebar, perhaps like
draggable up and down ... somebody in CMUX Classic made a thing which was like, you
know, they added a Figma thing to CMUX itself ... how would we make stuff where
someone goes, oh, that's compelling. Oh, I'd want to make my own. Oh, I'd want to
use somebody else's thing for that as well."

## Casual: one glance, no setup

| Idea | Place | Built on | Today |
|---|---|---|---|
| The time, the date and the weather | sidebar section | `cmux.timer`, `cmux.net.fetch` (Open-Meteo, no key) | Template `clock-weather` |
| Design links: Figma, FigJam, Linear, Notion, opened in a cmux tab beside the code | sidebar section | `cmux.storage`, `openBrowser` | Template `design-links` |
| Buttons for the commands I run all day | sidebar section | `cmux.actions.run("cmuxConfig.<name>")` | Template `command-button` |
| A scratch checklist | pane + sidebar row | `cmux.pane/1`, `cmux.storage` | Template `pane` |
| A focus timer with a slider | sidebar section | `Slider`, `cmux.timer`, `cmux.toast` | [Recipe](local-app-views.md#matching-the-app) |
| Quote, word or photo of the day | sidebar section | `cmux.net.fetch` | Buildable now |
| The same widgets on the new tab page | new tab page | a new-tab widget interface | Missing: see [Gaps](#gaps) |

## Everyday: follows my work, live

| Idea | Place | Built on | Today |
|---|---|---|---|
| My PRs and the reviews I owe, in the order I keep them, read again when an agent changes | sidebar section | `cmux.integrations.github` (else `net:api.github.com`), `agent_chat.changed`, `cmux.storage` | Template `my-prs` |
| PRs of this chat's branch | Session Info section | `cmux.session.info.section/1` | Sample `samples/apps/session-prs` |
| My agent chats as threads, needs-you first | sidebar section | `agent_chat.list`, `agent_chat.changed` | Template `threads` |
| The tabs of the workspace I am in | sidebar section | `cmux.events.on("tab.changed")` | Template `sidebar-section` |
| CI status of my branch, deploy status, on-call | sidebar section | `cmux.net.fetch` with `net:<host>`, `cmux.timer.every` | Buildable now |
| Calendar: next meeting and a Join button | sidebar section | `cmux.net.fetch`, `openBrowser` | Buildable now (needs the person's own token) |
| Linear or Jira issues assigned to me | sidebar section | `cmux.net.fetch` | Buildable now |
| A card in a Home chat (PR, deploy, poll) | chat bubble | `cmux.chat.widget/1` | Sample `samples/apps/pr-card` |

## Hardcore: a pane of my own, a tool other people install

| Idea | Place | Built on | Today |
|---|---|---|---|
| Figma, Excalidraw or a dashboard as a real pane, not a browser tab | pane | `cmux.pane/1` with `render: web` | Missing: web panes are designed, not built |
| A PR board I drag rows around in | sidebar section | `Reorderable` with drag | Missing: `Reorderable` draws, drag is not wired in either renderer (Move up/down menu entries today) |
| A whole new tab page of my own (widgets, launchers, a search) | new tab page | a new-tab widget interface | Missing |
| A sidebar that replaces the workspace list | sidebar | `cmux.sidebar/1` | Designed (`plans/cmux-next/extensibility-DESIGN.md`) |
| A palette scope: search my notes, my bookmarks, my servers | Command Palette | `cmux.palette.scope/1` | Sample `samples/apps/palette-notes` |
| A terminal backend (SSH, a container, a cloud box) | terminals | `cmux.terminal.backend/1` | Sample `samples/apps/ssh-terminal` |
| Push events from a server of my own into the sidebar | sidebar section | an app server | Buildable with `server` in the manifest; no webhook relay yet |

## Gaps

These are the pieces between what people asked for and what an extension can do today.
All five are tracked in https://github.com/manaflow-ai/cmux/issues/40249; until each lands, the workaround is in the last column.

| Gap | Asked for | Until then |
|---|---|---|
| New tab page widgets: an app interface whose views the new tab page draws (the web `SceneRenderer` Session Info already uses), with the person choosing which widgets and where | the time, the weather, PRs on the new tab page; a new tab page of one's own | the same widget as a sidebar section |
| Drag to reorder in `Reorderable` (both renderers), with a `move` event to the app | PRs "draggable up and down" | Move to top, Move up, Move down in the row's menu (`my-prs`) |
| `render: web` panes for the customize app, with no build step | Figma and other web tools as a pane | `openBrowser` into a cmux browser tab (`design-links`) |
| Push instead of a timer for GitHub (a `github.changed` event from the integration) | "real time or close enough" | a 60 s read plus a read when an agent chat changes (`my-prs`) |
| Share and install someone else's view: `cmux apps install <git url or folder>` for a local view, and more than one view per customize app | "I'd want to use somebody else's thing" | copy their folder into `~/.config/cmux/customize` |
