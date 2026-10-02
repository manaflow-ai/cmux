# Sample cmux apps

| App | Contribution | Shows |
| --- | --- | --- |
| `github-prs` | sidebar section + command | your open pull requests (integration gateway, else `net:api.github.com`) |
| `running-agents` | sidebar section | agents grouped by state; click shows the agent's tab |
| `agent-status` | status item | "2 working · 1 waiting" with a menu |
| `palette-notes` | palette scopes + commands | `notes` (snapshot over app storage, detail, ActionRefs) and `search` (streamed query) scopes, a `mode: form` command; tested with `@cmux/app-test` (`bun test`). Not bundled into CmuxNextApps yet (`NOT_BUNDLED`) |

Each app is `cmux-app.json` + `src/main.ts` (typed by `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`) + built `dist/main.js`. Rebuild and validate all: `bun samples/apps/build.ts` (`--check` verifies the built files are current). Spec: cmux-next-spec `spec/app-platform.md`; plan: `plans/cmux-next/app-platform.md`.
