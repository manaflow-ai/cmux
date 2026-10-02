---
name: cmux-next-feature
description: "Lawrence's standing rules for every cmux-next feature, design or agent task. Use whenever you add or change any user-facing feature, action, setting, pane, sidebar item, daemon/store op, backend op, app/extension API, or agent capability in cmux-next (Swift app, Rust cmux-tui/CLI/MCP, backend, web), or when you plan or review such work."
---

# cmux-next feature rules

Lawrence states these repeatedly. Apply all of them without being asked; list in your report which ones you applied and any you could not.

## Every capability on every surface
- One operation catalog drives everything. A new action or op declares its surfaces: CLI verb, MCP tool, Cmd-Shift-P palette, right-click menu where it makes sense, keyboard shortcut if apt (KeyboardShortcutSettings), and the mux agent's tools (code mode). An omitted surface needs a reasoned exemption (`scripts/cmux-next/check-action-surfaces.sh`).
- Agents are first-class users: CLI and MCP must be ergonomic for agents (stable public ids, `--json`, idempotency keys, waits that block until done, clear errors). Browser use and similar runtimes also get a REPL in both CLI and MCP.
- Automation (CLI, MCP, scripts, agents, remote clients) never steals focus; only user-initiated actions change focus/selection/scroll (`origin` marker, central check).

## Customizable by default
- Every default is a user setting (Settings window + `~/.config/cmux/cmux.json`), documented, with a test that the default matches the docs. Fine-tuning values are Debug Settings tunables (DEV/NIGHTLY).
- Think about what users and agents will want to customize, list it, and handle the important cases. Prefer minimal, undesigned UI with few labels; Ghostty-derived colors, no blue; real Liquid Glass on macOS 26+ with clean fallbacks; respect Reduce Motion/Transparency; `appearance.borders = none` must work.
- Extensible where it makes sense: apps/extensions get the same API through the generated `cmux` JS/TS global and scopes (see the app platform spec).

## Prototypes, then pick
- For user-facing design, build several variants behind a DEV/NIGHTLY switch (Debug Settings or palette), with screenshots and a recommendation. Lawrence picks after dogfood. Never one variant presented as final.

## Ownership and correctness
- `plans/cmux-next/OWNERSHIP-PRINCIPLES.md` is binding: single writer per entity; typed ops with idempotency keys; clients are mirror + intent log; destructive policy at the owner; client view state stays client.
- Design data structures from first principles. Prove invariants: pure reducers with property tests; TLA+/exhaustive model checks for protocols, focus, scroll, drag; failing test before the fix.
- Move as much as possible into Rust (session host, workspace store, CLI, MCP, browser/CUA hosts) while keeping the native macOS app first-class quality.
- No polling in cmux runtime (events, one-shot timers); 0% idle CPU; no crashes; RAM/CPU/disk efficient. No god files (`check-no-godfiles.sh`; split by responsibility).

## Process
- Own worktree; land on feat-cmux-next with the full gate; review subagent before daemon/store/protocol landings; record shared-surface changes in `plans/cmux-next/COORDINATION.md`; clean up tags/worktrees.
- Only the coordinator writes the spec repo (manaflow-ai/cmux-next-spec). Put proposals in `plans/cmux-next/<area>.md` and send "spec proposal: <area>" to the coordinator (mailbox inbox/lawrence-coordinator or SendMessage). Everything Lawrence decides must reach the spec through the coordinator.
- Questions for Lawrence go through the coordinator (AskUserQuestion), never as prose at the end. Cross-team agents (Leo, Aziz, Austin) are reached through the agent mailbox on cmux-lawrence (`~/agent-mailbox/README.md`).
- Never poll the GitHub API in loops (the shared REST limit runs out): one blocking `gh run watch` or a foreground verify script, `gh api rate_limit` before batches, local git for repo data.
- Reports: short sentences, what landed (SHAs), what is verified, what is UNVERIFIED, decisions needed, and shortcuts you took.
