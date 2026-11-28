# Agent index: every area file and topic page

The full list behind the short one in [CLAUDE.md](../CLAUDE.md). Read the matching file before changing an area.

## Area instructions

Read these before working in their scope; nested files may not load automatically:

- `Packages/iOS/`: [Packages/iOS/AGENTS.md](../Packages/iOS/AGENTS.md) (the Apple HIG rule for iPhone UI).
- Cloud backend code (control plane, VM API routes, provider drivers, billing, entitlements, the NEXT Worker):
  new code goes to the private manaflow-ai/cmux-platform repository, not here. Read
  [skills/cmux-backend/SKILL.md](../skills/cmux-backend/SKILL.md) first.
- `web/` or any cmux Cloud database work: [web/AGENTS.md](../web/AGENTS.md).
- `cmux-tui/`: [cmux-tui/AGENTS.md](../cmux-tui/AGENTS.md).
- `Packages/macOS/`, `App/`, `Native/` (the Mac app's Swift): [Packages/macOS/AGENTS.md](../Packages/macOS/AGENTS.md)
  (where a change goes, what Linux can check, the common reds).
- `backend/`, `workers/`, `services/`: [backend/AGENTS.md](../backend/AGENTS.md) (test one file, the migration and
  catalog reds).
- `scripts/`, `tests/`, `ci/`: [scripts/AGENTS.md](../scripts/AGENTS.md); `.github/workflows/`:
  [.github/AGENTS.md](../.github/AGENTS.md) (find and run one script's tests, add a workflow).
- `webviews/`: [webviews/README.md](../webviews/README.md).
- `cmux-next-ios/`: [cmux-next-ios/CLAUDE.md](../cmux-next-ios/CLAUDE.md) and
  [cmux-next-ios/SECURITY.md](../cmux-next-ios/SECURITY.md).

## Where the rest lives

| Touching | Read before editing |
| --- | --- |
| Setup, tagged builds, scoped verification | [CONTRIBUTING.md](../CONTRIBUTING.md#getting-started), [verification rules](../skills/cmux-dev-workflow/references/verification-rules.md), [tagged builds](../skills/cmux-dev-workflow/references/tagged-builds.md) |
| Hooks, lints, pushing | [hooks and lints](../skills/cmux-dev-workflow/references/hooks-and-lints.md), [pushing](../skills/cmux-dev-workflow/references/pushing.md) |
| Code rules, hot paths, crash classes, Swift namespaces | [code rules](../docs/cmux-next/code-rules.md), [PATTERNS.md](../plans/cmux-next/PATTERNS.md), [design-lessons.md](../docs/cmux-next/design-lessons.md) |
| Dev build backend data, local state and sign-in | [dev build spaces](../skills/cmux-dev-workflow/references/dev-build-spaces.md) |
| Finishing a task: dev build, simulator, iPhone hand-off | [finishing a task](../skills/cmux-dev-workflow/references/finishing-a-task.md) |
| Outside PRs, licenses, PR text, CI, review and merge | [landing](../docs/ci/landing.md), [STYLE.md](../STYLE.md), [risk tiers](../docs/ci/risk-tiers.md) |
| Screenshots and clips for a PR: crop, before/after, trim | [evidence](../skills/cmux-review/references/dogfood-and-merge.md) and `scripts/media/media_polish.py --help` |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](../skills/cmux-debugging/SKILL.md) |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](../skills/cmux-architecture/SKILL.md) |
| Submodules or GhosttyKit | [cmux-ghostty](../skills/cmux-ghostty/SKILL.md) |
| The cmux-next iPhone app (`cmux-next-ios/`, `Packages/iOS/`, the mobile Rust crates) | [cmux-ios](../skills/cmux-ios/SKILL.md): simulator tests, App Review gate, TestFlight, how iOS PRs merge |
| User-facing strings, docs or help | [cmux-localization](../skills/cmux-localization/SKILL.md); report the localization audit |
| A change people will notice (What's New, update card) | [release-notes/next/WRITING.md](../release-notes/next/WRITING.md); add one curated highlight file in the same commit, never a commit subject |
| New cmux shortcuts | [cmux-keyboard-shortcuts](../skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](../skills/cmux-testing/SKILL.md); [adding a test](../skills/cmux-testing/references/adding-a-test.md): CI finds it; Python tests take a lane entry; the `cmux` CLI is cmux-tui Rust |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](../skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |
| v2 socket methods, remote CLI relay (default deny) | [relay authorization](../skills/cmux-socket-policy/references/remote-relay-authorization.md) |
| Every task skill | [skills/README.md](../skills/README.md) |
