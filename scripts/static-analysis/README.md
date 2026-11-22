# Static analysis (report-only)

Each script installs its pinned tool (sha256-checked release binary), runs it over the
repository, writes the full report to `${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}/`
and ends with one line, `SA_SUMMARY tool=<tool> findings=<N> seconds=<S>`. A script exits 0
whenever its tool ran, whatever it found; nonzero only when the tool could not be installed or
crashed. Run them yourself on the fleet, never on a person's Mac. Two are also a CI guard
(below); the rest are report-only.

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

## The CI guard: zizmor and gitleaks

`ratchet.py` runs `zizmor.sh` or `gitleaks.sh` and judges its report; ci-guards.yml's `ci` group runs both
(Linux only), so `scripts/ci/guards-local.sh` and the CI fast guards run them.

- `ratchet.py zizmor`: offline, persona regular. Fails when a file has more findings of an audit and severity
  than `zizmor/baseline.json` records, or zizmor cannot audit a file the baseline does not list. Counts are
  per file, not per line, so moving a line keeps its key. Fix a new finding; after fixing old ones, or for a
  reviewed exception (say why in the pull request), `python3 scripts/static-analysis/ratchet.py zizmor --update`.
- `ratchet.py gitleaks`: this change's commits only (a pull request's merge commit or a push, each against its
  first parent or `CMUX_GUARDS_BASE_SHA`), so it has no baseline: any finding fails. A known non-secret goes in
  `gitleaks/gitleaks.toml`'s allowlist; a real one is rotated.

Any other finding becomes a gate only by a later, separate decision.
