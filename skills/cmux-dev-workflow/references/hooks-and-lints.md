# Hooks and lints before a push

Moved here unchanged from CLAUDE.md on 2026-11-08; CLAUDE.md keeps each rule as one sentence and links here.

## Web lints

- **Web lints before every commit and push.** If the change touches `webviews/` or `web/`, run
  that area's lints from its folder first (`bun install --frozen-lockfile` once per checkout) and
  fix every error.
  Never push with a lint failure; a base lint red skips the CI tests after it. These are the
  checks CI runs on every `feat-cmux-next` push:
  - `webviews/`: `bun run check` (Oxlint, Oxfmt, type check, layer and protocol checks).
    `bun run check:fix` repairs formatting.
  - `web/`: `bun run typecheck`, `bun run lint:complexity` and
    `bun tools/generate-managed-iroh-relay-catalog.ts --check`. Also run
    `bunx eslint <changed files>` and add no new ESLint errors (the full `bun run lint` has old errors).

### scripts/web-lint.sh

Run `scripts/web-lint.sh` before you push web or webviews changes; the pre-push
hook enforces it. It runs, on what you changed against `origin/feat-cmux-next`,
the `bun run check` that CI runs for `webviews/` and `cmux-tui/frontends/web/`
(Oxfmt, Oxlint with the type check, browser-lane and style checks) and ESLint on
changed `web/` files. `scripts/web-lint.sh --fix` autofixes what the tools can;
commit the result. The hook comes with `scripts/install-git-hooks.sh` (run by
`scripts/setup.sh`; one run covers every worktree of the clone). Skip it only with
`CMUX_WEB_LINT_SKIP_REASON="<failing check> is red on base <sha>"`; the
`web lint (fast)` job of cmux-next-web-lint.yml still checks every feat-cmux-next push.
A host that must not run heavy checks (a shared agent host) sets `CMUX_LOCAL_HEAVY_CHECKS=0`:
the type-aware lint and type check (`vp lint`, `vp check`) are left to CI there; the rest still run.

## cmux-next pre-push gate

Before every push, run `python3 scripts/cmux-next/prepush-gate.py` (the pre-push hook
runs it too; install once with `scripts/install-git-hooks.sh`). In a few seconds and
with no build, it runs the static checks of the `cmux-next checks` CI job, pinned
ast-grep rules, SwiftFormat `--lint` and syntax-only SwiftLint on the files you
changed, and refuses only violations your commits add; base debt does not block you.
Swift/Rust builds and tests stay on the fleet.

## Post-edit and pre-commit hooks

Claude Code and Codex post-edit hooks (`.claude/settings.json`, `.codex/hooks.json`)
run the same fixer on edited `Packages/**/*.swift` files; they print repairs and never fail an edit.
They also warn, for the edited files only, about workflow YAML that does not parse or that
actionlint rejects, a new `tests/test_*.py` missing from `tests/test-execution.d/`, and a
CmuxNext Swift or cmux-tui Rust file grown past its god-file cap (`scripts/ci/check-post-edit.sh`).

`scripts/ci/format-post-edit.sh` formats each edited file the way CI checks it:
`webviews/` and `cmux-tui/frontends/web/` with that package's own `vp fmt`
(reinstalled from its lockfile when stale), Rust with the pinned toolchain's
rustfmt. The pre-commit hook does the same for staged files and restages them.
Both touch only those files, so agents sharing a checkout never reformat each
other's work. `CMUX_SKIP_FORMAT_HOOKS=1` skips both in an emergency.
