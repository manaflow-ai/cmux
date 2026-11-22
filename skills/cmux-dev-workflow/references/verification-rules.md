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
- **Wait on GitHub with one shared waiter, never a poll.** Team hosts: one background
  `glaeda-gh wait pr OWNER/REPO#N --sha FULL_SHA` (or `wait run OWNER/REPO/RUN_ID`) per PR or run,
  or the acpmux `run_wait` tool, which uses it. Its daemon waits on GitHub's PR events
  (`gh event listen`, gh 2.105.0+, where the account has Event Streams access) and polls otherwise.
  Never `gh pr checks --watch`, `gh run watch`, a sleep loop, or a `gh event listen` of your own
  (each listener holds one of the account's few subscriptions), and no `gh api` / `gh run view` /
  `gh pr view` re-read on a timer: on 2026-11-19 nine such loops in agents' background tasks made
  most of this host's ~800 gh calls an hour. A fleet test's Actions run: `glaeda-gh wait run`; a
  reply comment: `glaeda-gh wait comment OWNER/REPO#N --match RE --since URL`; a fleet job:
  `cmux-ci wait ID`; a file or a process: `glaeda-gh wait file PATH` / `glaeda-gh wait pid PID`.
  The Chief's `watch` tool routes such waits to glaeda-gh itself and refuses GitHub poll loops. Rules:
  [github-ci-wait](https://github.com/teamleaderleo/glaeda/blob/main/skills/github-ci-wait/SKILL.md).
- **Make worktrees with `python3 scripts/cmux_worktree.py add -b BRANCH PATH origin/feat-cmux-next`.**
  Its files are APFS clones of a clean seed checkout: about 4 s and almost no new disk, where a plain
  `git worktree add` writes 1.3 GiB in 17 s. `--cargo cmux-tui` also seeds `cmux-tui/target` from a
  sibling worktree's. Never symlink node_modules or point worktrees at one Cargo target dir; `bun
  install` already clones from bun's store. `gc` lists landed, clean, idle worktrees (and `--apply`
  removes only those); `dedupe` turns old worktrees' unchanged files into clones. See the
  [dev workflow skill](../SKILL.md#worktrees).
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
- On a shared GUI Mac (a capture mini), start what you run by hand over `ssh` (`open -n`,
  `xctrace`, `sample`, `workspace new`, `nohup` helpers) as `~/.local/bin/gui-run -- CMD`. It closes what the
  run opened when the run exits, fails or is cut off, and its sweep closes what a killed run left, by run tag.
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
  Never report raw `.app` paths or `file://` URLs.
- The app package needs Swift tools 6.2 and deploys to macOS 14; the old Swift 6.0 rule
  does not apply here. Check Release compiles and macOS 14 limits with
  [toolchain compatibility](../../cmux-architecture/references/swift-6-0-compatibility.md).
- No fleet Mac runs macOS 14 or 15 (they run 26 and 27). Check an
  OS-dependent bug or a launch on 14/15 in Tart VMs: `scripts/cmux-next/os-matrix.sh --build JOB
  --os 14,15` ([MATRIX.md](../../../scripts/fuzz/macos-matrix/MATRIX.md)). VM timing is not perf evidence.
