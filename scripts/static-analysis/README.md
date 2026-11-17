# Static analysis (report-only)

Each script installs its pinned tool (sha256-checked release binary), runs it over the
repository, writes the full report to `${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}/`
and ends with one line, `SA_SUMMARY tool=<tool> findings=<N> seconds=<S>`. A script exits 0
whenever its tool ran, whatever it found; nonzero only when the tool could not be installed or
crashed. Nothing here is a CI job or a gate: run them yourself on the fleet, never on a
person's Mac.

```bash
cmux-ci test -- bash scripts/static-analysis/run-all.sh            # every tool, one table
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

A finding becomes a gate only by a later, separate decision.
