# Sample cmux apps

| App | Implements | Shows |
| --- | --- | --- |
| `github-prs` | `cmux.section/1` + catalog op `github-prs.refresh` | your open pull requests (integration gateway, else `net:api.github.com`) |
| `running-agents` | `cmux.section/1` | agents grouped by state; click shows the agent's tab |
| `agent-status` | `cmux.status/1` | "2 working · 1 waiting" with a menu |
| `palette-notes` | palette scopes + commands (manifest v1) | `notes` (snapshot over app storage, detail, ActionRefs) and `search` (streamed query) scopes, a `mode: form` command; tested with `@cmux/app-test` (`bun test`). Not bundled into CmuxNextApps yet (`NOT_BUNDLED`) |

The first three are manifest v2 `cmux-app.json` (`runtime.main`, `implements` with a scene `export`) + `src/main.ts` (typed by `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`) + built `dist/main.js`. Rebuild all: `bun samples/apps/build.ts` (`--check` verifies the built files are current; it validates v1 manifests with `tools/validate-manifest.ts`). The v2 manifests are validated by the Rust validator (`cargo test -p cmux-app-manifest` loads every v2 sample) and rendered by the native app host (`cargo test -p cmux-app-host`), both in the hosted cmux-tui verification. Plan: `plans/cmux-next/app-platform.md` sections 12 and 13.
