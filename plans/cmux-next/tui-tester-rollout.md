# cmux-tui tester rollout: actionables for Rex parity

Status: 2026-10-19, Chief subagent "cmux-tui tester rollout" (user msg 2785).
Base: origin/feat-cmux-next. Sibling: the cmux-tui API-compat agent owns the
version handshake and wire translation (Rex-style JSON-pointer rules).

Rex runs a Mac tester program (+1,000 invites this week) and starts a Linux
program in separate invite waves, gated on forward+backward API compatibility.
This is what cmux-tui needs to do the same, what exists, and what is missing.

## What exists today (read from code, not assumed)

| Area | State |
|---|---|
| Packages | npm `cmux` launcher + `cmux-tui-{darwin-arm64,darwin-x64,linux-x64,linux-arm64}`; PyPI `cmux` (6 wheels, manylinux + musllinux). Linux binaries are static musl, x86_64 and arm64. `cmux-tui-release.yml` runs a glibc/musl distro matrix on both arches before publish. |
| Latest release | 0.13.4, 2026-09-17: a month behind feat-cmux-next. `cmux-tui registry delivery` (every 6 h) is green, so what is published is delivered. |
| Fresh builds for testers | `cmux-tui-nightly.yml` is dispatch-only ("CI pause"); its last runs (July) all failed. No `next`/nightly npm dist-tag exists. A Linux tester today can only get 0.13.4. |
| Version reporting | The published 0.13.4 binary prints `cmux 0.1.0 (...)` (the crate version), so a tester's report cannot name its release. **Fixed in this work.** |
| Mac app | Bundles its own cmux-tui and updates it with Sparkle (NIGHTLY channel). Mac nightlies are arm64 only; the x86_64 nightly download 404s. |
| Remote hosts | `cmux-tui remote update-need` orders two builds by capability set, then build time, and the app replaces an older remote build over SSH. |
| Standalone update | npm/PyPI installs get no update notice. **Fixed in this work (#8).** |
| Wire compatibility | Per-feature capabilities in `identify` / `set-client-info` (good). But the remote TUI requires exactly protocol 12 and rejects 11 with "restart the cmux-tui server". No test runs an old published client against a new daemon or the reverse. |
| Crash telemetry | The session owner writes `owner-panics-<session>.jsonl`; only the Mac app forwards it to Sentry (`OwnerPanicForwarder.swift`). A Linux or npm/PyPI tester's crash never leaves the machine. Lines carried only the crate version 0.1.0. **Fields and forwarding fixed in this work (#3, #7).** |
| Memory telemetry | `server-stats-v1` exists; nothing reports RSS growth. Classic reports of 30-70+ GB (a156) show unbounded growth is a real risk at tester scale. **Memory guard added (#9).** |
| Invite waves / flags | No remote flag service for cmux-tui. MDM `DisabledFeatures` exists (enterprise lane only). Mac has nightly-next canary/rollback workflows for the app. **Signed flag feed added (#10).** |

## Actionables

P0 blocks a Linux tester wave. "Money/login" marks items I did not do.

| # | P | Actionable | Owner | Money/login? | State |
|---|---|---|---|---|---|
| 1 | P0 | `cmux --version` names the release; `cmux --version --json` gives version, build, both protocols, os/arch, install channel and update command (one paste for bug reports). | this agent | no | **landed** |
| 2 | P0 | npm package contract refuses a binary that reports another release, so the 0.1.0 bug cannot ship again. | this agent | no | **landed** |
| 3 | P0 | Owner panic lines carry release, build identity, os, arch, so crashes group by release and platform. | this agent | no | **landed** |
| 4 | P0 | Version handshake: the client sends its version and capability set; the daemon answers with the range it can translate; a client outside the range gets the exact update command (from #1's install channel) instead of "restart the server". | API-compat agent | no | **landed**: `identify` sends `version` (release), `install`, `update_command`, `api_revision`/`min_api_revision`; `set-client-info` takes `api_revision`, `version`, `install`; daemon refusals name the client's update command, the CLI's refusals name its own or the server's (`cmux_tui_core::release`) |
| 5 | P0 | Cross-version compatibility matrix in CI: last 3 published releases (npm tarballs, public) x HEAD, both directions (old client/new daemon, new client/old daemon), `identify` + attach + one command per capability; Linux x86_64 and arm64 in Docker, macOS on a fleet mini. Fails on any unexpected refusal; an expected refusal must name the update command. | API-compat agent builds the fixtures; matrix job next | no (runs on existing runners) | fixtures **landed**: `cmux-tui/spec/api-compat-fixtures.json` (one case per rule and direction, enforced by `api-compat-check` and `api_compat_fixtures_*` tests); matrix job not started |
| 6 | P0 | Tester channel: publish a `next` npm dist-tag and PyPI pre-releases from feat-cmux-next on a schedule, so Linux testers get builds newer than 0.13.4. Fix the July nightly failure first. | a176 | no (no Blacksmith: nightlies move to the Mac minis, Linux jobs to ubuntu-latest) | owned by a176 |
| 7 | P0 | Standalone crash forwarding: a headless/npm/PyPI owner sends unsent owner-panic lines to Sentry at start, each line once (byte offset in `<log>.sent`), never a test line, home dir scrubbed to `~`. | this agent | no: reuses the app's public DSN with tag `process=cmux-tui` | **done** (`owner_start/crash_forward.rs`). Off for the app's bundled binary (the app forwards), managed `DisableTelemetry`, `DO_NOT_TRACK`, `CMUX_TUI_TELEMETRY=off`, `app.sendAnonymousTelemetry: false`, `CI`, local builds |
| 8 | P1 | Update notice for npm/PyPI installs: at most once a day the owner asks the registry (npm `cmux/latest`, PyPI `cmux`) and caches the answer; the interactive client prints one line with the update command from #1 on exit. | this agent | no | **done** (`update_notice.rs`, en + ja). Off with `updates.checkAutomatically: false`, managed `DisableAutoUpdate`, `CMUX_TUI_UPDATE_CHECK=off`, `CI`, the app's bundled binary, local builds. It checks `latest` only, so testers on a `next` tag (#6) see nothing until a176 publishes one |
| 9 | P1 | Memory guard: the owner samples its memory every 5 min; past 4 GiB, then each doubling, it writes one line to `owner-memory-<session>.jsonl` and sends a `MemoryGrowth` warning to Sentry under #7's consent. | this agent | no (same DSN as #7) | **done** (`owner_start/memory_guard.rs`). No per-subsystem breakdown yet: that needs allocation accounting |
| 10 | P1 | Invite waves: a signed flag document (policy keys per cohort, `managed/policy.rs` shape) that the owner fetches at start and caches only when the signature verifies; readers verify again. | this agent | no: the nightly signs `release-notes/next/flags.json` with the existing content-signing key and uploads it beside the release notes on R2 | **done** (`feature_flags.rs`). Cohort from `CMUX_TUI_COHORT` or cmux.json `tester.cohort`; `--version --json` shows `cohort` and `disabled_features`. No feature reads `feature_flags::disables` yet: wire the first risky feature when a wave needs it. Cohort assignment is by setting, not by server-side identity |
| 11 | P1 | Mac x86_64: either build the x86_64 nightly or state arm64-only on the download page; the TUI `cmux-tui-darwin-x64` npm package already exists. | decided | no | decided: arm64 only. The cmux NEXT nightly release notes already say "Apple silicon only"; the stale x86_64 DMG names are a176's nightly cleanup |
| 12 | P2 | Mac app crash tag: `OwnerPanicForwarder.swift` also tags `build_identity`, `os`, `arch` from the new panic fields. | this agent | no | **landed** |
| 13 | P2 | Version agreement across the three build paths (`build-cmux-tui-client.sh`/nightly, the R2 tree artifacts, HQ's fleet recipe). | this agent | no | **done, no code needed**: `cmux --version` shows the release only for a real npm/PyPI stamp; the placeholders (`0.0.0-nightly-…`, `0.0.0-r2.sha-…`, unstamped HQ recipe) all show the workspace version 1.0.0, which `check-version-surfaces.sh` enforces. `remote-probe`'s `distribution_version` keeps the raw stamp on purpose: SSH bootstrap compares it as the install identity (`ssh_bootstrap.rs` `same_build`) |

## Coordination with the API-compat agent (version handshake)

- #1 gives a stable, machine-readable self-description: `cmux --version --json`
  fields `version`, `build_identity`, `build_time`, `protocol`,
  `remote_protocol`, `install`, `update_command`. Use `install` +
  `update_command` in every refusal text, so a tester told "too old" gets the
  exact command for how they installed (npm, PyPI, app).
- `version` is the npm/PyPI release, not the crate version, and is the value
  the handshake should send and log.
- I did not touch `identify`, `set-client-info`, `SUPPORTED_PROTOCOL_VERSION`
  or `remote_runtime.rs`: those are the handshake agent's.
- The compat matrix (#5) should consume the agent's rule fixtures, so a new
  rule without a matrix case fails CI.

## Defaults I picked

- Release version in `--version`; crate version moved to `crate_version` in JSON.
- Install channel from the binary's own path (`node_modules` = npm,
  `site-packages`/`dist-packages` = PyPI, `*.app` = app), no env var, so nested
  shells inherit nothing.
- PyPI update command `uv tool upgrade cmux` (the docs' install path).
- No scheduled nightly (a176 owns it) and no new Sentry project: crash and memory events reuse the app's DSN, tagged `process=cmux-tui`.
- Flags ride the existing signed release-notes feed, not a new Worker: no new key, no new spend.
- Update notice checks `latest` only and prints on client exit, never inside the TUI.
