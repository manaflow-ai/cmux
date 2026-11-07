# Sample cmux apps

| App | Contribution | Shows |
| --- | --- | --- |
| `github-prs` | two sidebar sections + command | your open pull requests, and "PRs · last 24h" (`recent`, `defaultRegion: bottom`): PRs you authored, were asked to review or are assigned, created or updated in the last 24 hours, open and merged, newest first (integration gateway, else `net:api.github.com`). Manifest v2 has one `cmux.section/1`, so its v2 file keeps only `prs` |
| `session-prs` | Session Info section (`cmux.session.info.section/1`) | the pull requests whose head is the chat's branch (`head:<branch>`), read from the mount context the render export gets (`{session_id, cwd, branch?, harness?}`); an empty state when the chat has no branch. Manifest v2 only (`cmux-app.v2.json`) |
| `running-agents` | sidebar section | agents grouped by state; click shows the agent's tab |
| `agent-status` | status item | "2 working · 1 waiting" with a menu |
| `palette-notes` | palette scopes + commands | `notes` (snapshot over app storage, detail, ActionRefs) and `search` (streamed query) scopes, a `mode: form` command; tested with `@cmux/app-test` (`bun test`). Not bundled into CmuxNextApps yet (`NOT_BUNDLED`) |
| `priority-view` | sidebar section | agents ranked by what needs you (needs you, finished, working; idle hidden); the prototype for `plans/cmux-next/extensibility-DESIGN.md`. Not bundled (`NOT_BUNDLED`) |
| `ssh-terminal` | `cmux.terminal.backend/1` (Rust server, own Cargo workspace) | a third-party terminal backend: plain SSH to any host, host key check through the connection handle; manifest v2 only (`cmux-app.v2.json`), not packed by `build.ts` |

Each app is `cmux-app.json` + `src/main.ts` (typed by `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`) + built `dist/main.js`. Rebuild and validate all: `bun samples/apps/build.ts` (`--check` verifies the built files are current). Spec: cmux-next-spec `spec/app-platform.md`; plan: `plans/cmux-next/app-platform.md`.

An app contribution mounted in Session Info receives the mount context as the
argument to its render export. The context contains the page's
`session_id` and `cwd`, plus `branch` and `harness` when known; inside that
render or one of its event handlers the same object is available as
`cmux.app.context()`. Sidebar and Session Info sections use the same scene
runtime and typed `render` export shape.

`github-prs`, `running-agents` and `agent-status` also carry `cmux-app.v2.json`, the same app on manifest v2 (`runtime.main`, `implements` with a scene `export`; `github-prs` adds the catalog op `github_prs.refresh` in `catalog.json`). `cmux-app.json` stays v1 for the CmuxNextApps prototype. The Rust validator checks the v2 files (`cargo test -p cmux-app-manifest`) and the native app host renders them (`cargo test -p cmux-app-host`).
