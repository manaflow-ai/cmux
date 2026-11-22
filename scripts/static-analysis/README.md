# Static analysis

Each script installs its pinned tool (sha256-checked release binary), runs it over the
repository, writes the full report to `${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}/`
and ends with one line, `SA_SUMMARY tool=<tool> findings=<N> seconds=<S>`. A script exits 0
whenever its tool ran, whatever it found; nonzero only when the tool could not be installed or
crashed. Run them yourself on the fleet, never on a person's Mac. Two also run in CI
(below: they fail a change only on a security hole it adds); the rest run only by hand.

```bash
cmux-ci test --setup webviews -- bash scripts/static-analysis/run-all.sh  # every tool, one table (knip needs bun)
cmux-ci test -- bash scripts/static-analysis/ast-grep.sh           # one tool
SA_ONLY="zizmor gitleaks" bash scripts/static-analysis/run-all.sh  # a subset
```

| Script | Tool | What it reports |
| --- | --- | --- |
| `ast-grep.sh` | ast-grep | Structural rules in `ast-grep/rules/` (Rust, Swift, TS). Each rule's `note` names the existing detector it mirrors; the originals stay as they are. |
| `cargo-machete.sh` | cargo-machete | Unused dependencies in every Cargo workspace. Deps whose `[lib] name` differs from the package name are re-checked by lib name. |
| `knip.sh` | knip | Unused files, exports and dependencies in every TS package with a lockfile. Entry points come from `knip/gen-config.mjs` and `knip/webviews.entries`. |
| `periphery.sh` | Periphery | Unused Swift code in the SwiftPM packages; the app project needs a Mac (`SA_PERIPHERY_XCODE=1`). `run-all.sh` skips it unless `SA_ONLY` names it. |
| `zizmor.sh` | zizmor | GitHub Actions security (template injection, token permissions, unpinned actions, cache poisoning). Online audits only with `GH_TOKEN`. |
| `gitleaks.sh` | gitleaks | Secrets in new commits (`origin/<base>..HEAD`; `GITLEAKS_RANGE`, `SA_BASE`, `GITLEAKS_FULL=1`), always redacted. Allowlist in `gitleaks/gitleaks.toml`. |
| `osv-scanner.sh` | osv-scanner | Known vulnerabilities in every lockfile (Cargo, bun, npm, Go, SwiftPM). |

## The CI check: zizmor and gitleaks

`ratchet.py` runs `zizmor.sh` or `gitleaks.sh` on a change and judges what the change adds. It fails a
change only on a real security hole that change introduces; everything already on the base, and every
lower-severity finding, is a `::warning` and a step-summary row. The decision (the interim
coordinator, for Leo, 2026-11-22): "make them fail a PR only on findings that PR introduces
and that are a real security hole: a leaked secret, untrusted input reaching a privileged workflow, a
poisoned cache that later jobs trust. Everything already on base, and lower-severity findings, stays
report-only."

Where it runs: cmux-next-guards.yml's `security-holes` job on every feat-cmux-next pull request (its merge
commit against its first parent), and ci-guards.yml's `ci` group (Linux only) on pushes, on PRs into main and
in `scripts/ci/guards-local.sh`. `CMUX_STATIC_ANALYSIS_BLOCKING: "0"` in either workflow's `env` turns the
failures back into warnings.

- `ratchet.py zizmor`: offline, persona regular, over only the workflows and composite actions the change adds
  or edits, at its base and at its head. A finding is new when the head has more of its file, audit, severity
  and confidence than the base (per file, not per line, so moving a line keeps it; renames are followed). A
  new finding fails only when it is in `ZIZMOR_HOLES` (template-injection, dangerous-triggers that check out
  the pull request's head, cache-poisoning, artipacked at High confidence, insecure-commands,
  hardcoded-container-credentials, bot-conditions), at severity High, in the repository's own `.github/`.
  A reviewed false positive: `# zizmor: ignore[<audit>]` on its line, with the reason.
- `ratchet.py gitleaks`: this change's commits only (`-m --first-parent base..head`), values redacted. Every
  finding is a secret the change commits, so every one fails. A known non-secret goes in
  `gitleaks/gitleaks.toml`'s allowlist; a real one is rotated.
- `--base SHA --head REV` judges any pair of commits (how the 100-PR backtest in cmux#50013 ran).

Widening `ZIZMOR_HOLES` is a separate decision; `tests/test_static_analysis_ratchet.py` pins the set.
