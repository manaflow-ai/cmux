# First-party cmux apps

Official cmux apps built on the app platform with only the public app API (the generated `cmux` global, the view builders and `cmux-app.json`). They prove the platform: whatever they cannot do with the public API is a platform gap, recorded in `plans/cmux-next/first-party-apps.md` section 3.

| App | Id | What it does |
| --- | --- | --- |
| `search/` | `cmux/search` | finds workspaces, tabs, terminal text, browser pages, notes, inbox items and files, and opens the result |
| `inbox/` | `cmux/inbox` | one triage list of notifications, waiting agents and connected-service work items |
| `notes/` | `cmux/notes` | markdown notes, global and per workspace, readable by agents |
| `coderouter/` | `cmux/coderouter` | CodeRouter status, accounts, keys, usage and first-run onboarding |
| `usage/` | `cmux/usage` | usage and pace of every router account per provider, in the menu bar, a pane and the sidebar |
| `diffs/` | `cmux/diffs` | `cmux.diff.renderer/1`: working tree, refs, agent proposals and run diffs, with per-hunk decisions and comments |
| `codemirror/` | `cmux/codemirror` | `cmux.editor/1` on CodeMirror 6 in a web pane |
| `integrations/` | `cmux/integrations` | connections to GitHub, Linear, Slack, Calendar, Gmail and any OpenAPI, GraphQL or MCP API, with health, sharing and per-tool Allow / Ask / Block; generic import and tool policy from the MIT package `libs/integrations-core/` (`@cmux/integrations-core`), adapted from executor (MIT, `integrations/LICENSE-executor`) |
| `caffeinate/` | `cmux/caffeinate` | keeps the Mac awake (until stopped, for a time, or while a terminal's command runs) through the proposed host capability `power.assertion.*` |
| `agents/` | `cmux/agents` | agent CLIs (Claude Code, Codex, OpenCode, Pi, Chief, ...) on every machine: versions, updates, installs and sign-ins, run by cmux in a visible terminal |
| `skills/` | `cmux/skills` | skills and MCP servers per agent, project or everywhere; every config change is a reviewed diff before it is written |
| `memory/` | `cmux/memory` | agent memory files (CLAUDE.md, AGENTS.md, project memory) per machine and project; every edit shows a diff, deletes go to the Trash |
| `remote-desktop/` | `cmux/remote-desktop` | the native `remote_view` pane and the `rd.*` ops of the `cmux-rd` host engine (manifest v2 only, development only) |

Each app is `cmux-app.json` + `src/main.ts` (typed by `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`) + built `dist/main.js` + `test/` (bun) + `preview/` (fixtures for screenshots) + a README with its scopes, variants, proposed operations and gaps.

Apps with a web pane (`codemirror/`) also have `web-src/` bundled by their own `build-web.ts` into `web/`, pinned npm dependencies in the app directory (`package.json`, `bun.lock`, no `node_modules` in git) and a generated `THIRD_PARTY_NOTICES`.

Build and validate all: `bun first-party-apps/build.ts` (`--check` verifies that the built files are current). Test one: `bun test first-party-apps/<name>/test`.

Variants: each app has two or three designs, selected by the DEV/NIGHTLY app setting `variant` and the palette command "Next <App> Variant". These are prototypes; the pick happens after dogfood.

Operations an app needs that do not exist yet are called with `cmux.call("<family>.<verb>")` and answer `operation.unsupported` until their owner implements them; the app then shows what is missing.
