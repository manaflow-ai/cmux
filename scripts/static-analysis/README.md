# Static analysis (report-only)

Each script installs its pinned tool (sha256-checked release binary), runs it over the
repository, writes the full report to `${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}/`
and ends with one line, `SA_SUMMARY tool=<tool> findings=<N> seconds=<S>`. A script exits 0
whenever its tool ran, whatever it found; nonzero only when the tool could not be installed or
crashed. None of them is a gate or a pull request check: run them yourself on the fleet, never on a
person's Mac. The one scheduled run, [Daily run](#daily-run), only files issues.

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

A finding becomes a gate only by a later, separate decision.

## Daily run

`daily.sh` runs osv-scanner, cargo-deny, cargo-machete and knip, then `daily_findings.py` gives each
finding a stable key and files ONE issue per key that is new since `daily-baseline.txt` (the tree's
findings when the baseline was written). The key sits in the issue body
(`<!-- static-analysis-key: ... -->`), so a finding with an open issue, or one closed as not planned,
is never filed again; one closed as completed that comes back is filed again, naming the old issue.
At most 10 issues per run (`SA_MAX_NEW`). Issues carry `static-analysis-daily`, `needs-triage`,
`follow-up` and `area: build-and-ci`.

`.github/workflows/static-analysis-daily.yml` runs it on feat-cmux-next (main's
`static-analysis-daily-dispatch.yml` starts it once a day, since schedules run only from the default
branch). It is never a pull request check and nothing requires it: a new advisory or license reaches
the repo as an issue, never as a red on an unrelated pull request.

| Script | Tool | What it reports |
| --- | --- | --- |
| `cargo-deny.sh` | cargo-deny | Licenses and advisories in every Cargo workspace with a Cargo.lock, against the repo-root `deny.toml`. |

`deny.toml` is cargo-deny's baseline: every license in use and every advisory known when it was
written, so only new ones are findings. Rewrite both baselines after a deliberate cleanup:

```bash
cmux-ci test --setup webviews -- bash scripts/static-analysis/daily.sh   # what would be filed
SA_CARGO_DENY_CONFIG=scripts/static-analysis/cargo-deny/deny-seed.toml bash scripts/static-analysis/cargo-deny.sh
python3 scripts/static-analysis/daily_findings.py "$FAST_CHECKS_OUT" --write-deny-toml deny.toml
bash scripts/static-analysis/daily.sh && python3 scripts/static-analysis/daily_findings.py "$FAST_CHECKS_OUT" \
  --write-baseline scripts/static-analysis/daily-baseline.txt
```
