# Secret scanning

cmux runs [`gitleaks`](https://github.com/gitleaks/gitleaks) over the repository to
catch credentials that get committed by accident. The scan is configured by
[`.gitleaks.toml`](../.gitleaks.toml) at the repo root and is reproducible both
locally and in CI.

## Run it locally

```bash
brew install gitleaks        # one-time
./scripts/secret-scan.sh
```

The script scans the working tree with the repo allowlist and exits non-zero if
it finds anything. It prints findings with the secret value redacted. CI uses the
same pinned `gitleaks` version and config semantics, but invokes `gitleaks`
directly from workflow YAML so the enforcement path does not depend on a
PR-modified wrapper script.

CI pins gitleaks to **8.30.1** (see
[`.github/workflows/secret-scan.yml`](../.github/workflows/secret-scan.yml)), and
the allowlist was validated against it. gitleaks' default rules can change
between releases, so the script warns when your local `gitleaks` version differs
— a brew install is fine for day-to-day use, but match the pinned version if a
local result disagrees with CI.

To run gitleaks directly (the script is a thin wrapper around this):

```bash
empty_ignore_path="$(mktemp)"
trap 'rm -f "$empty_ignore_path"' EXIT
gitleaks dir . --config .gitleaks.toml --redact --verbose \
  --ignore-gitleaks-allow \
  --gitleaks-ignore-path "$empty_ignore_path"
```

To scan a commit range, set `CMUX_GITLEAKS_LOG_OPTS` to the git-log range:

```bash
CMUX_GITLEAKS_LOG_OPTS="$(git merge-base origin/main HEAD)..HEAD" \
  ./scripts/secret-scan.sh
```

`gitleaks` also auto-loads `.gitleaks.toml` when it is at the scan root, so
external review tools that run a bare `gitleaks` over the checkout pick up the
same allowlist automatically.

## What the allowlist covers

The repo intentionally contains token-shaped strings that are **not** real
secrets. Without an allowlist they flood the scan and bury a genuine leak
(see [issue #5978](https://github.com/manaflow-ai/cmux/issues/5978)). The config
extends gitleaks' default rule set — so real credentials still fail — and
suppresses only these, each scoped to a specific file (and, for source files, to
the specific known-public value):

- **Sentry-scrubber redaction fixtures.** `ScrubberDenylistsTests.swift`,
  `SentryScrubberTests.swift`, and `cmuxTests/SentryEventScrubberTests.swift`
  feed PEM blocks, `ghp_`/`sk-`/JWT/AWS samples through the scrubber and assert
  the output is redacted. Plus the one `token=sk-…` example in
  `SentryScrubber.swift`'s doc comment.
- **Other synthetic test-only tokens.** An attach-ticket coding fixture, a
  diff-viewer URL token (a UUID), a websocket-lease fuzz seed (a sha256 hex
  literal), a command-palette focus probe marker, and the Sentry CLI checksum
  fixture used by the self-hosted CI guard.
- **Public-by-design keys.** The Stack Auth *publishable* client keys and the
  PostHog project API key are meant to ship in clients, plus an APNs key
  *env-var reference* (not a hardcoded secret).

Vendored, generated, and submodule trees (`ghostty/`, `node_modules/`, `.build/`,
`DerivedData/`, `vendor/`) are out of scope — the ghostty submodule is a separate
upstream repo with its own scanning.

## Adding a new allowlist entry

Keep entries **narrow** — never blanket-ignore a language or the whole test tree:

- For a file that is entirely fixtures (e.g. a scrubber test), allowlist it by
  `paths` with the exact path.
- For a known-public value inside a real source file, use a block with
  `condition = "AND"` plus both `paths` (the file) and `regexes` (the value), so
  a *different*, real secret added to that same file still fails.

After editing `.gitleaks.toml`, re-run `./scripts/secret-scan.sh` to confirm the
intended strings are suppressed and the scan is otherwise clean.

## CI

[`.github/workflows/secret-scan.yml`](../.github/workflows/secret-scan.yml) runs
`gitleaks` on every pull request and push to `main` (without checking out
submodules). Pull requests use `pull_request_target` so the workflow code comes
from the base branch, then check out the PR merge tree and scan the git range
from the PR base to `HEAD`; a secret added in one PR commit and removed before
merge is still caught. After the initial bootstrap PR, pull requests enforce
with the base branch's `.gitleaks.toml` so a PR cannot hide a committed secret by
relaxing its own allowlist. When a PR changes `.gitleaks.toml`, CI also runs the
same scan with the candidate config to catch syntax or semantic breakage before
merge; that candidate validation is additional and does not replace the blocking
base-config scan. CI also ignores inline `gitleaks:allow` comments and points
`.gitleaksignore` at an empty file, so suppressions must live in the reviewed
config. Pushes to `main` scan the pushed commit range.
