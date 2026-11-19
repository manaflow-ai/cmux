# Verification and isolation

Moved here from the root CLAUDE.md on 2026-11-19 (docs audit); the root keeps a one-line pointer.

- Before committing, setup or a native build, [choose scoped verification](../../cmux-testing/references/local-vs-ci-validation.md).
  Start with `python3 scripts/verify-local.py`; docs and portable tooling need no app build.
  Run repository commands only in a [trusted checkout](../../../docs/contributor-verification.md#trust-boundary),
  including `verify-local.py --help`, `--list` and `--repo`. Push does not run checks for you.
- **Web lints before every commit and push.** A change to `webviews/` or `web/` runs
  `scripts/web-lint.sh` (the pre-push hook enforces it) and fixes every error; never push
  with a lint failure, because a base lint red skips the CI tests after it. Commands, skip
  reason and shared-host mode: [hooks and lints](hooks-and-lints.md).
- Use [CONTRIBUTING.md](../../../CONTRIBUTING.md#getting-started) for setup. Tagged reloads default to
  `CMUX_DEV_BACKEND_MODE=local`; cmux-next needs no shared backend. Follow [tagged builds](tagged-builds.md)
  for commands and cache reuse; team fleet tasks start at
  [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md).
  Never use bare `xcodebuild` or an untagged `cmux DEV.app`. Clean up only your own tags.
- **Agents never compile or test on the person's Mac.** No local `swift build`/`swift test`,
  `xcodebuild build|test`, `cargo build|test|clippy` or `scripts/reload.sh`: run them as a
  fleet step (`cmux-ci run --class CLASS --script ... --ref SHA`, `cmux-ci build cmux --ref SHA`).
  CLASS is the script's own class: `light` for Swift suites (`scripts/ci/package-test-lane.sh`,
  `run-swift-testing-suites.sh`), lints and the Rust check; `isolated` only for the scripts that
  say so. Any other class is refused with `runs as class X` and no step is made.
  Several agents' local SwiftPM test runs pegged the Mac at 100% CPU (2026-10-20). The PATH
  guards (`~/.local/lib/cmux-local-build-guards`) queue or refuse these; never bypass them.
- **Scope every search.** `rg`/`find`/`fd` only inside your worktree or a named subfolder, never
  `..`, `~`, `~/fun`, `/`, `$TMPDIR` or `/var/folders` (worktrees and caches there hold millions of
  files). Prefer `git grep` or `rg` with a path; prefix long scans with `nice -n 10`.
- A same-repo app PR gets a fleet dogfood build and link comment only while it has the
  `dev-build` label. Add it when someone will dogfood the PR, not by default; under load
  the fleet builds the newest push, and the comment says how to build a skipped commit.
- Never quit, kill, relaunch, replace or launch-profile the user's running cmux
  (`/Applications/cmux.app`, `com.cmuxterm.app`), including through a Release build or
  another bundle with that ID. Never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`; only the
  user may. Reproduce in a tagged build and attach profiling to its PID.
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
  Never report raw `.app` paths or `file://` URLs.
- The app package needs Swift tools 6.2 and deploys to macOS 14; the old Swift 6.0 rule
  does not apply here. Check Release compiles and macOS 14 limits with
  [toolchain compatibility](../../cmux-architecture/references/swift-6-0-compatibility.md).
- No fleet Mac runs macOS 14 or 15 (they run 26 and 27). Check an
  OS-dependent bug or a launch on 14/15 in Tart VMs: `scripts/cmux-next/os-matrix.sh --build JOB
  --os 14,15` ([MATRIX.md](../../../scripts/fuzz/macos-matrix/MATRIX.md)). VM timing is not perf evidence.
