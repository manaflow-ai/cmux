# cmux-next product spec

Living spec, kept by Chief with the user. Last update: 2026-10-20.

This file says what cmux-next is and what the user decided for each area. Each
requirement has the decision (short quote where possible), the status, and the
open questions. The detailed designs stay in the `*-DESIGN.md` files in this
folder; this file links to them. The older canonical spec is the
`manaflow-ai/cmux-next-spec` repo (`decisions.md`, `spec/*.md`); see
[spec-coverage.md](spec-coverage.md) for the audit against it.

Status words:

- **Shipped**: the code is on `feat-cmux-next` (a sha is given). It is not
  necessarily in a nightly yet, and often not seen in the running app.
- **In progress (aN)**: a Chief subagent owns it and works on it now.
- **Not started**: a decision exists, but nobody builds it.

The private prompt history (every prompt and its status) is in the Chief
board at `~/fun/cmux-chief-board/`, outside the repo.

## 0. What cmux-next is

cmux-next is the rewrite of cmux: a native macOS app (Swift, AppKit/SwiftUI)
for people who run many coding agents at once. It has terminals (Ghostty), a
browser (Chromium and WebKit), Markdown and file viewers, and an agent layer.
One persistent agent, **Chief**, works for one user in one chat that never
ends ("Home"). Chief starts subagents, puts each in its own workspace, and
reports back. A daemon, **cmux-tui**, owns terminals and state; **acpmux**
keeps agent sessions (Claude Code, Codex, OpenCode) alive; the iOS app and
cmux cloud reach the same state.

Product rules from the user:

- "main" for cmux-next means `feat-cmux-next`. Every agent's work lands there
  with a rebase and a plain push. No PRs unless asked. No force push.
- Chief decides almost everything itself. It asks only about money, legal,
  destructive or credential steps. It picks a sensible default and says so.
- Heavy builds and tests run on the Mac mini fleet, never on this Mac.
- Every behavior is one shared action, reachable from right-click,
  Cmd+Shift+P, CLI and MCP (parity).
- Every user-facing string is localized (21 locales now).
- Bug fixes come with a failing-first test.
- Speed is a feature: the user often asks for "10x" or "100x" and for numbers.

## 1. Home, Chief and agents

| Requirement | Decision | Status |
|---|---|---|
| Home is an iMessage-style chat with Chief | Chief is the user's one agent; subagents report to it | Shipped |
| Subagent links | Every agent id and workspace in a reply is a clickable link (cmux:// deep links, link chips) | Shipped (a222, `ee853a7d04e..f29008525b2`) |
| Tell interrupts | A message to a busy agent interrupts it; queuing is opt-in, "We do not like queuing" | In progress (a224, a298) |
| acpmux has zero overhead | acpmux vs raw Claude/Codex/OpenCode timings "match exactly", bench guard in CI | In progress (a298) |
| Chief prompt cache | Reuse one subrouter session per Chief | Shipped (a226, `79b9709f52d`; hit 39%→98.5%, $1.87→$0.59 per 6 turns). Next: keep one Claude Code process per Chief (a226) |
| No agent cap by default | "no limits"; `control cap N` stays opt-in | In progress (a253) |
| Usage analytics | Tokens, cost, cache and latency per Chief/subagent/model over time | In progress (a292) |
| Default Chief avatar | User rejected all designed icons; 🫡 is the default, per Chief id | In progress (a259, a260) |
| Background tasks | Click a background task to see a read-only terminal with its output | Shipped (a228, `b317b41..c1f9b64`) |
| Attachments | Any file type attaches; only size limit refuses | In progress (a285) |
| Attachments open right | Click opens in the right pane, right-click Open With any app | In progress (a290) |
| Product spec and prompt board | Chief shows this spec and the prompt history in the right pane | In progress (this file + board) |
| Chief uses the Home right pane | "open stuff on the right" for everything Chief shows | Shipped as a rule |

Open questions:

- Should Chief ever queue a message on its own, or always interrupt?
- Should usage analytics show cost in dollars from list price, or from the
  real subrouter bill?

## 2. iMessage-style chats and group chats

| Requirement | Decision | Status |
|---|---|---|
| Rebuild from first principles | "fix all from first principles": one ordered log per chat, server numbers messages, sends keep position, one streamed reply per message, one reducer | In progress (a293, [home-chat-pipeline-DESIGN.md](home-chat-pipeline-DESIGN.md)) |
| No lag while streaming | Home chat must not lag while a reply streams; resize fast path | In progress (a197) |
| No clipped bubbles | Bubbles never clip after resize | Cause not found; guard `d813fc1` (a102); fix with a197 |
| Avatar and label overlap | "C" avatar and "Chief >" must not cover the transcript top | In progress (a102) |
| Long-press menu | Bubble long-press menu not upside down | In progress (a231) |
| Composer colors and typing | Colors not too dark (`62b789edcef`); typing under 8 ms per key at 100 agents | Colors shipped; typing lag in progress (a264) |
| Group chats with Chief | Add Chiefs, subagents and humans; Chief replies when @mentioned or the only agent | In progress (a287, built on a132's group chats) |
| Media, replies, reactions | Chief sends images/videos inline, quotes a specific message, sends tapbacks | In progress (a287, [chief-replies-reactions-DESIGN.md](chief-replies-reactions-DESIGN.md)) |
| Chat display settings | Width, fonts, code font in the ACP ··· menu | In progress (a276) |

Open questions:

- In group chats, should Chief also reply when no one @mentions it but a
  question is clearly for it?
- Which reactions should Chief use, and how often?

## 3. Sidebar, groups, pinning and density

| Requirement | Decision | Status |
|---|---|---|
| Group header click | A plain click only expands or collapses; menu on right-click and ··· | In progress (a109) |
| Group count | Hide "13" by default; optional small, regular-weight, lighter text | In progress (a109) |
| Group spinner | Spinner at far right until hover, then slides left | In progress (a109) |
| One trailing column | Every dot and spinner centered on the group chevron's x | In progress (a296) |
| Pinning everywhere | Workspaces (top and in groups), groups, tabs; right-click, Cmd+Shift+P, CLI, MCP | In progress (a294, [pinning-DESIGN.md](pinning-DESIGN.md) planned) |
| Density | Compact stays pixel-identical; more presets; font scales; custom densities | In progress (a289) |
| Density commands | One palette entry per density, current one checked, Enter applies | In progress (a289) |
| Comfortable overflow / Home width | Pinned rows match group header insets at every width | In progress (a288) |
| Calm sidebar | No needless animation or reorder while the pointer is over it | In progress (a273) |
| Scroll lag | Sidebar scrolling must not lag | In progress (a207) |
| Search button | Sidebar search magnifier | Riding in a270's push (a247) |
| No timestamps | Sidebar rows show no timestamps | Shipped (`12789dcd087`) |
| Hover card history | Workspace hover card shows history | Shipped (a186, `20e76758fe8`) |

Open questions:

- Should the group count be removed completely instead of opt-in?
- Which density presets beyond Compact and Comfortable are worth keeping?

## 4. Tabs, panes and focus

| Requirement | Decision | Status |
|---|---|---|
| Mouse-down tab focus | A tab focuses on mouse-down, not mouse-up | Shipped (`95b9bbe0a44`), user to verify press-and-hold |
| Cmd+T | New tab opens after the current tab by default; end/start options; Cmd+Shift+P actions | In progress (a281) |
| Focus follows mouse | Off by default; scroll and hover never steal focus; opt-in setting | In progress (a297) |
| Pane focus model | One central focus model (Monaco first) | Design shipped (`8cee5dbe1aa`, [pane-focus-DESIGN.md](pane-focus-DESIGN.md)); in progress (a255) |
| Cmd+Opt+Arrow | Ghostty pane navigation in four directions; Ghostty default keys change only with user OK | In progress (a246) |
| Shortcuts | Cmd-=/-/0 font; Ctrl-Cmd-= equalize; Ctrl-Shift-Cmd-=/-/0 interface scale | Shipped (a177, `c0c5a386537`) |
| Tab mute | The speaker is a real toggle | Shipped (a192, `452b69e3612`) |
| Move pane to new window | Right-click, Cmd+Shift+P, CLI, MCP | Shipped (a174, `fcead3db649..b60c5a6ee75`) |
| Close and split animations | Instant unless last tab/window; follow Reduce Motion | In progress (a121) |
| Zoom lag | Cmd+Shift+Enter is instant | In progress (a252) |
| Cmd+Opt+U | Toggle unread is instant | Shipped (a254, `3fba7d95714`) |
| Tab-spam race | Cmd-T/Cmd-W spam never breaks | Shipped (a86, `412403f1eaf..092650db471`) |
| Cmd-click links | Open in the right pane | In progress (a272) |

Open questions:

- Should Cmd+T group new tabs with their opener, Chrome-style?

## 5. Terminal, Ghostty, cmux-tui and acpmux

| Requirement | Decision | Status |
|---|---|---|
| Ghostty parity | Terminals look and act exactly like plain Ghostty | In progress (a229) |
| Codex composer background | Codex input row has its gray band like in Ghostty | In progress (a291) |
| Wheel never types escapes | Mouse wheel in Codex does not type escape codes (#22265) | In progress (a277) |
| Restore at launch | Terminals restore at launch (#21088, #22292) | #21088 fixed (`039bb41`); #22292 in progress (a278) |
| Scrollback resize | Resize keeps scrollback right | Shipped (a163, `466516f5d30`) |
| Updates keep sessions | An app update keeps terminals and acpmux alive | Shipped (a248, `f79c51f0fd1`); Chief turn resume in progress (a185) |
| cmux-tui API compat | Old clients keep working | Shipped (a157, `0c1d7d03f9c..165b18c8acd`) |
| `cmux version` | CLI shows app, daemon and CLI versions | In progress (a256) |
| CLI papercuts | Agent shells never shadow `cmux` | In progress (a258) |

## 6. Browser, omnibar and extensions

| Requirement | Decision | Status |
|---|---|---|
| Omnibar Chrome parity | Cmd-L, keywords, http fallback, also in popups | In progress (a146); popups use the tab omnibar (a127, shipped) |
| Search All Windows | Opt-Cmd-F | Owned by a180 |
| Extensions menu | Chrome-style, unhighlight on close, pin fade | Shipped (a106, `ae426b6..afa69b8`) |
| Inspect Element | Cmd+Shift+P "Inspect Element" for web views | In progress (a208) |
| Hidden-tab power | Freeze hidden tabs after 30 s; titles max 4/s | Shipped (a154, `182c3416c6f`); 20-hidden-tab power rise in progress |
| Shared web processes | New Tab pages share web processes | Shipped (a251, `8e335f6582f..479e2a8d2f3`) |
| Agent cursor | Gray glassy pill "Clear gray glass" | Shipped (a201, `8d2bcf6476c`); real blur in progress |
| Default search engine | Google (DuckDuckGo was tried and reverted) | Shipped |
| Email autofill | Mail first, fail closed | Shipped (a108, `9d06b973462`) |

## 7. Markdown and Files

| Requirement | Decision | Status |
|---|---|---|
| Obsidian parity | Tables, column resize, highlight, transparency | In progress (a169) |
| Table widths remembered | Per-file xattr, app copy as fallback | In progress (a280) |
| Resize cursor | Hovered column line always shows the resize cursor | In progress (a280) |
| Wide tables scroll | Wide tables scroll horizontally | In progress (a217) |
| Markdown omnibar | Path, open, Cmd-L, git chip, Share; `~/` paths | Shipped v1 (a216, `4453f1f..a70ed5c`) |
| Mermaid | Diagrams render | Shipped (a138, `b195823..964010b`) |
| Files pane | Finder look, 100x faster than Finder incl. search | In progress (a290; a123 ~45% parity, [finder.md](finder.md)) |

## 8. Search (Cmd+P and Cmd+Shift+A)

| Requirement | Decision | Status |
|---|---|---|
| One search window | Cmd+P and Cmd+Shift+A open one merged search; Cmd+Shift+P stays the palette | In progress (a270, [search-everything-DESIGN.md](search-everything-DESIGN.md)) |
| Search everything | Titles, workspaces, chats, ACP, scrollback, TUIs, all Chief chats | In progress (a269) |
| Smart order | Rank by title, workspace, group, chat, path, cwd, branch, recency, frequency | In progress (a269) |
| Speed | Under 16 ms per key at 100 workspaces; 100x faster than ripgrep; bounded memory | In progress (a269) |
| Contrast | Scope chips at WCAG AA in light, dark, Increase Contrast | In progress (a270) |

Open question:

- Default picked: Cmd+Shift+A opens the merged window with "Chats & agents".
  Keep it, or keep Cmd+Shift+A for tabs?

## 9. Updates and server restart

| Requirement | Decision | Status |
|---|---|---|
| Background downloads | Keep them as today; no "Preparing update" pill | Decision |
| Restart server prompt | "Restart the server to use new features" when cmux-tui/acpmux protocol is old; confirm says what survives; never auto-restart | In progress (a286, server-updates-DESIGN.md planned) |
| Update card | Show "Downloading Update" only for updates the user started | In progress (a240) |
| Changelog | Shows on every hover (`cf73f56dd1d`); new Conductor-style designs | Fix shipped; designs in progress (a279) |
| Version | cmux-next is 1.0.0 | Shipped (a170, `c942abba9dc`) |
| Classic migration | Transparent one-time move from classic cmux, never mutates classic data | Shipped (a187, `1ae9df83ea8`) |

Open question:

- Auto-update today checks hourly, downloads and installs on quit. Keep it,
  or "check only"?

## 10. Motion and Liquid Glass

| Requirement | Decision | Status |
|---|---|---|
| Motion settings | One motion gate, per-category toggles (sidebar, tabs, panes, menus, chat, cursor, hover, spinners, web), CLI and palette | In progress (a274) |
| Reduce Motion | Every animation is instant under Reduce Motion | Rule |
| Liquid Glass | Shared style for toasts, confirms, bottom-left tips, cursor pill | In progress (a286, a201) |
| Spinners | One shared clock, no half-faded frames | In progress (a263, a296) |
| Backgrounds | Per pane/window/tab/workspace, one store; opacity works | In progress (a245, a249) |

## 11. iOS app and Action Button

| Requirement | Decision | Status |
|---|---|---|
| Base | Build on Aziz's latest iOS work (`feat-cnx-ios`) merged into feat-cmux-next | In progress (a191, ~20 conflicts) |
| Action Button | Hold to talk to Chief (voice mode); keeps Shortcuts | In progress (a191) |
| TestFlight | Continuous internal builds like the Mac nightly | In progress (a282) |
| Phone pane | Live simulator screen in a tab, `cmux phone` | In progress (a261) |
| Mobile pairing | Pair phone from the Mac | Shipped (a167, `3a085adb4ea`) |

## 12. Cloud and remote

| Requirement | Decision | Status |
|---|---|---|
| Cloud Chief | Chief runs in the cloud; Chief pairs it itself ("do it for me") | Paired (a196); app tools and redeploy gap in progress (a235) |
| Freestyle VMs | Chief makes VMs and runs cloud sessions; org automation | In progress (a205, [org-workflows-DESIGN.md](org-workflows-DESIGN.md)) |
| Remote groups | Host-bound sidebar groups, nested groups, better than T3 Code and Rex | In progress (a283) |
| Chief moves hosts | Move Chief between this Mac, a Mac mini, a GCP VM, cmux cloud | In progress (a284, chief-migration-DESIGN.md planned) |
| Add Server UI | Floating glass pairing card, Approve/Deny, no focus steal | In progress (a202) |
| Database | PlanetScale; staging first; zero-downtime migrations | Shipped (a214, [db-migrations-DESIGN.md](db-migrations-DESIGN.md)) |

Open question:

- How should cloud costs be shown and capped per user?

## 13. Performance targets

| Target | Decision | Status |
|---|---|---|
| Everything 10x | Memory, CPU, tabs, panes, drag, settings, CLI; measured on the fleet | In progress (a153 bench, BENCH.md) |
| Tab switch 100x | Lower latency, CPU, memory | In progress (a168) |
| Space switch | 500 workspaces 772→40 ms | Shipped (a98, `352dc9e`) |
| Old macOS | No lag on Sonoma/Sequoia; per-version guards on Tart VMs | Shipped (a251) |
| Full-screen lag | Fix | In progress (a195) |
| Bundle size | Cut the bundle 100x | In progress (a188) |
| Idle | Near-zero idle CPU and wakeups | In progress (a154) |

## 14. Nightlies and CI

| Requirement | Decision | Status |
|---|---|---|
| Nightly every night | No Blacksmith; Mac minis for Mac, GitHub for Linux | Pushed (`1adad047017`, `29d5304eb8a`); PR #22385 merge by a176 |
| Fleet builds | `cmux-ci` controller jobs, no maclease | Rule |
| Pre-push gate | Fast static checks on changed files | Shipped (a199, `bc95e0e9c2c`) |
| Base red | Known-failing tests are fixed or renewed with owner | In progress (a145) |

## 15. Pricing

| Requirement | Decision | Status |
|---|---|---|
| Pricing page | Free $0, Pro $50, Max $200, Team $60/seat, sandbox $0.148/h | Preview at /next/pricing (a218), no Stripe |

Open question:

- Are these prices final? Stripe is not wired.

## Top open questions for the user

1. Auto-update: keep "check hourly, download, install on quit", or "check only"?
2. Cmd+Shift+A: keep the default "opens merged search, Chats & agents", or keep it for tabs?
3. Pricing: are Free/Pro $50/Max $200/Team $60 final, so Stripe can be wired?
4. Group chats: should Chief reply only when @mentioned, or also when a message is clearly for it?
5. Group count: hide it completely, or keep it as an opt-in setting?
