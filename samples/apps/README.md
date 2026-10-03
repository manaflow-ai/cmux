# Sample cmux apps

| App | Contribution | Shows |
| --- | --- | --- |
| `github-prs` | sidebar section + command | your open pull requests (integration gateway, else `net:api.github.com`) |
| `running-agents` | sidebar section | agents grouped by state; click shows the agent's tab |
| `agent-status` | status item | "2 working · 1 waiting" with a menu |
| `palette-notes` | palette scopes + commands | `notes` (snapshot over app storage, detail, ActionRefs) and `search` (streamed query) scopes, a `mode: form` command; tested with `@cmux/app-test` (`bun test`). Not bundled into CmuxNextApps yet (`NOT_BUNDLED`) |
| `ssh-terminal` | `cmux.terminal.backend/1` (Rust server, own Cargo workspace) | a third-party terminal backend: plain SSH to any host, host key check through the connection handle; manifest v2 only (`cmux-app.v2.json`), not packed by `build.ts` |

Each app is `cmux-app.json` + `src/main.ts` (typed by `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`) + built `dist/main.js`. Rebuild and validate all: `bun samples/apps/build.ts` (`--check` verifies the built files are current). Spec: cmux-next-spec `spec/app-platform.md`; plan: `plans/cmux-next/app-platform.md`.

`github-prs`, `running-agents` and `agent-status` also carry `cmux-app.v2.json`, the same app on manifest v2 (`runtime.main`, `implements` with a scene `export`; `github-prs` adds the catalog op `github-prs.refresh` in `catalog.json`). `cmux-app.json` stays v1 for the CmuxNextApps prototype. The Rust validator checks the v2 files (`cargo test -p cmux-app-manifest`) and the native app host renders them (`cargo test -p cmux-app-host`).
