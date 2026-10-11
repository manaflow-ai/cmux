# cmux next: CLI, daemon and app version skew

Status: plan approved by the coordinator 2026-10-09 (hq-6d). Owner: hq-6d.

## The failure

Lawrence ran `cmux chief` in a plain terminal and got "this session has no conversations (capability local-conversations-v1 is missing); update the cmux app or daemon". His `cmux` on PATH was the `scripts/reload.sh` dev shim. The shim reads `/tmp/cmux-last-cli-path`, which only `reload.sh` writes; fleet builds and the Tag Opener never write it, so the shim fell back to `/Applications/cmux.app` (0.65.0), an older CLI for the build he used. The same class hit the Chief (E17: a login shell put the shim ahead of the bundled CLI, and the shim ran an older CLI).

Three things make a skew a dead end today:

1. Which `cmux` runs is decided by PATH order and a pointer that one dev tool writes.
2. A CLI that meets an older or newer daemon has no way to find the matching CLI.
3. Capability errors tell the user to "update the app", which is wrong when a matching CLI is already installed.

## Rules

- One writer for the "last opened app" pointer: the app, at launch. A per-user file (`~/Library/Application Support/cmux/last-app-cli`), mode 0600, written to a temporary file in the same directory and renamed over the old one. Isolated agent launches (`CMUX_NEXT_NO_ACTIVATE`) never write it. The dev shim reads it before its legacy `/tmp/cmux-last-cli-path`. Inside an app terminal `CMUX_BUNDLED_CLI_PATH` wins over both (it already does).
- No dead ends: the daemon advertises its build id and the absolute path of its own CLI in `identify` (CORE). A CLI that lacks a command, or meets a daemon without a capability it needs, re-execs the daemon's CLI once. A newer CLI with an older daemon of the same install hands the daemon off (`daemon_handoff`) where supported, else prints one exact command that fixes it.
- Re-exec security (all required; a test for each refusal):
  - the daemon is local and its socket peer has this process's uid (`getpeereid`);
  - never for a remote, SSH, Cloud or `--remote` daemon;
  - the path is absolute, a regular file, inside a `.app/Contents/Resources/bin/` of a cmux bundle or the tagged DerivedData product of the same install family, and neither it nor its directories are writable by group or other;
  - on a signed build the target has the same Team ID as this binary;
  - never through a PATH lookup;
  - a loop guard (`CMUX_CLI_REEXEC=<build id>`): a process started with it never re-execs again;
  - one log line on stderr for each re-exec.
- Capability errors never say "update the app" (a lint in CI). They name the matching CLI, or the exact command.
- A CI skew matrix runs CLI N against daemon N-1 and N+1 for every capability-gated command; pass means the command works or execs the right CLI.

## Steps

1. App-written pointer and shim reader (this plan's first landing). Swift `LastAppCLIPointer` in CmuxNextDaemon/Launch, called from `AppDelegate` at launch; `scripts/reload.sh` shim reads it first. Tests: the Swift pointer writer (atomic, 0600, skipped for isolated launches) and the shim (`scripts/lib/reload-shim.test.mjs`: the app pointer wins over `/tmp`, a pointer owned by another uid or a symlink is ignored).
2. `identify` advertises `build_id` and `cli_path` (CORE token). Spec + bindings + count tests in the same commit.
3. CLI re-exec on a dead end with every security check above, and the handoff or exact-command path for a newer CLI. Red tests per refusal and a two-build test.
4. The capability-text lint and the rewrite of today's "update the app/cmux" capability errors (`chief/messages.rs`, `script/messages.rs`, `app_control.rs` skew text, `mcp/action_tools.rs`).
5. The CI skew matrix (hosted lane, two builds).
6. Live proof on cmux-lawrence-2 with two builds.
7. Retire the `/tmp/cmux-last-cli-path` writer in `reload.sh` once the app pointer has shipped in the dev builds that `reload.sh` makes. Status 2026-10-09: the app pointer ships in every cmux-next dev build. `git grep` still finds readers of `/tmp/cmux-last-cli-path`: in this repo `cleanup-dev-builds.sh` (safety skip) and `stress-cli-socket-api.py`, which now read `last-app-cli` first; in cmuxterm-hq the Tag Opener (`activeCLITag`), `tools/local-build-guards/cmux` and `keep-devs.sh`, and hq `reload-cloud.sh` also writes it. The dev shim keeps the `/tmp` fallback for an isolated launch (`CMUX_NEXT_NO_ACTIVATE`), which writes no app pointer. So the `reload.sh` writer stays for one release, marked legacy; remove it, and the shim fallback, after the cmuxterm-hq readers read `last-app-cli`.

## Known limits

- No automatic handoff of an older daemon (step 3). Builds have no order: every cmux-tui build is version 0.1.0 and `build_id` is a commit (with a dirty-tree hash), so a CLI cannot tell whether the daemon is older or newer than itself. At a dead end it runs the daemon's CLI when every check passes; when a check refuses, the error names one exact command that stops the daemon and starts it with this CLI (`cli/fix_command.rs`). A monotonic build order in `identify` (for example a build sequence number stamped by the release and tagged builds) would let a newer CLI hand an older daemon off by itself.
- The script error (`cmux script`) names the restart for the daemon the environment routes to, without `--socket`: its error path does not know the socket it used.
- On Linux and in an unbundled CLI (a `cargo` build, a copied binary) the CLI never re-execs: the target and this CLI must both be inside a cmux `.app` of the same install family.
