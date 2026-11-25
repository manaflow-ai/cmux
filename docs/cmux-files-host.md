# cmux Files (dev): one Files and Folders grant for every DEV build

Every tagged DEV build of cmux NEXT has its own bundle id (`com.cmuxterm.app.debug.<tag>`) and,
when it is signed ad hoc, its own cdhash for every rebuild. macOS keys a Files and Folders answer
(Desktop, Documents, Downloads, iCloud Drive, removable and network volumes) to the *responsible
process* of the code that touched the folder, by that process's code identity. So each new tag,
and each ad-hoc rebuild, asked again: the first `ls ~/Downloads` in a terminal, the first agent
that read `~/Desktop`.

DEV builds now run their terminal daemon and their agent daemon under one pinned, team-signed
helper, **cmux Files (dev)** (`com.cmuxterm.files.dev`). It is the responsible process of
everything below it, so a person answers once for all DEV builds. It is dev only: no shipped
build embeds it, looks for it or spawns differently (see "Production").

## What asked, and why

| Who touches the folder | How it starts | Responsible process before | After (DEV with the helper) |
| --- | --- | --- | --- |
| A terminal's shell and what runs in it (`ls ~/Downloads`, `cd ~/Desktop`, a CLI agent) | app runs `cmux-tui server ensure`; it spawns the owner with `setsid` (`local_owner.rs` `spawn_detached_owner`). `setsid` changes the session, not responsibility | the DEV app (per tag) | cmux Files (dev) |
| Agents of the agent pane (acpmux and the Claude Code, Codex or other agent processes it starts) | app `posix_spawn`s `/bin/sh -c 'set -m; … &'` (`AcpmuxDaemonLauncher`); launchd adopts the daemon, responsibility stays | the DEV app | cmux Files (dev) |
| The Chief home's conversation owner | `DaemonLauncher.forChief`, same `server ensure` path | the DEV app that started it | cmux Files (dev) |
| The Chief's brain host (`optchat-chief host`) and the acpmux and agents it starts | `HomeBrainHost` `posix_spawn`s `/bin/sh -c 'set -m; "$@" … &'`, like acpmux | the DEV app | cmux Files (dev) |
| The Files pane's folder listing (`DirectoryLister`: the pane, its columns, the sidebar file tree) | in process (`getattrlistbulk`) | the DEV app | cmux Files (dev): read by `cmux-tui __files-lister` under the helper (see "The Files pane") |
| The app itself: Quick Look, thumbnails, Get Info folder sizes, copies, drag and drop, folder picker | in process | the DEV app | unchanged (see "What still asks") |
| Chromium downloads into `~/Downloads` | the Chromium host is spawned without a disclaim on purpose (camera, microphone, location name cmux; `cef-helper-app-DESIGN.md` row 7) | the DEV app | unchanged |
| Computer Use, Screen Sharing workers | already their own identities (cmux Remote, `docs/cmux-remote.md`) | cmux Remote | unchanged |

`scripts/cmux-next/tcc/responsible_pid.c` prints the responsible pid of any pid, and
`scripts/cmux-next/launch-no-tcc-prompts-live.py` streams tccd's `AUTHREQ_ATTRIBUTION` lines, if
you want to see it on a Mac.

## The pattern it follows

cmux Remote (`docs/cmux-remote.md`) already solved "one grant across builds" for Accessibility and
Screen Recording:

- a pinned, team-signed bundle whose bytes every DEV build embeds unchanged, so its designated
  requirement (bundle id plus team certificate) never changes until the pin does;
- a verified copy outside the app (`cmux-signed-bundle`: digest, `codesign` against the
  requirement, one slot per digest), because macOS checks code that runs inside another app's
  bundle as that outer app;
- a spawn with `responsibility_spawnattrs_setdisclaim`, so the helper is its own responsible
  process.

cmux Files (dev) reuses all three. The difference is who inherits the grant: cmux Remote keeps
its grants away from shells and agents, while this helper exists to hand Files and Folders to
them. So it holds only Files and Folders; it is never used for Accessibility, Screen Recording,
Automation or Full Disk Access, and cmux never asks for those on its behalf.

## How it runs

```
cmux DEV <tag>.app                        (responsible for itself)
  └─ cmux-tui server ensure               (CMUX_TUI_OWNER_LAUNCHER = the embedded helper)
       └─ cmux-files-host run -- <cmux-tui> --headless …      (bundled copy, launcher)
            │  stages its bundle to ~/Library/Application Support/cmux/files-host/app/<digest>/
            └─ cmux-files-host host -- <cmux-tui> …            (staged copy, spawned disclaimed:
                 │                                              responsible for itself)
                 └─ cmux-tui owner → holders → shells, agents    (responsible: cmux Files (dev))
```

acpmux is the same with `/bin/sh -c 'set -m; "$@" …' acpmux-launch <helper> run -- <acpmux> …`.

- **Two roles, one executable.** `run` stages and spawns `host` disclaimed, then waits. `host`
  spawns the program as an ordinary child (in its own session, as the owner had), then waits.
  Both pass every inherited descriptor above 2 on at the same number (the owner's readiness pipe
  and install key, acpmux's ready fd 3 and person key fd 4) and close their own copies, so end of
  file still means the program exited. Both forward TERM, INT, HUP, QUIT, USR1 and USR2 and exit
  with the program's status. `host` kills the program when `run` dies first (the client's
  `terminate` kills the pid it spawned).
- **Which program.** `host` runs a program only from an app that embeds byte-identical helper
  bytes (`Contents/Library/cmux Files (dev).app`), that is a DEV build of the same pin. Anything
  else exits 126. `run` checks the same before it stages.
- **Never worse than before.** When `run` cannot stage a verified copy (an ad-hoc or modified
  bundle, no `codesign`, a full disk) or the program is outside the app (`CMUX_NEXT_TUI_BIN`, a
  live swap), it `exec`s the program in place: the build's terminals run as they did before, and
  ask as the app.
- **Who turns it on.** The app sets `CMUX_TUI_OWNER_LAUNCHER` for `server ensure` and prefixes
  acpmux's argv only in a Debug compile (`#if DEBUG`) whose bundle id is DEV
  (`com.cmuxterm.app.debug[.<tag>]`) and that embeds the helper (`FilesHost`). cmux-tui removes
  the variable from the owner's environment, so shells never inherit it. An owner or acpmux
  already running keeps its old responsible process until it restarts.
  `CMUX_NEXT_FILES_HOST=0` in the app's environment turns it off.
- **Launch Services.** Opened with no arguments (or only `-psn_*`), it exits at once.

## Security

- The grant reaches exactly what the per-tag DEV app's grant reached before: the shells and agents
  of DEV builds. It no longer carries the DEV app's other grants (Accessibility, Screen
  Recording) to shells, which is a narrowing.
- The helper is a launcher anyone of this user can run. `host` refuses programs that are not
  from a DEV build embedding the same bytes, which stops `cmux-files-host host -- /bin/cat`.
  It is not a boundary against code already running as this user: such code can build a fake
  bundle with a copy of the helper, as it can already talk to an unsigned DEV daemon with the
  install key in the tag's state folder (`plans/cmux-next/identity.md`, "Accepted limit").
- An ad-hoc copy is never staged or run as the host: its grant would be keyed to a cdhash, and a
  person could be asked to grant something that is not the pinned helper.
- No Full Disk Access is asked for or suggested.
- Shipped builds never embed or use it (see "Production").

## Production

The helper never reaches a shipped build: stable, NIGHTLY, RC, staging, the NEXT DEV daily
(`com.cmuxterm.app.debug.next`, a Release build), `--release` dogfood tags, TestFlight and the App
Store. Two independent gates, with no override:

| Gate | Where | Rule |
| --- | --- | --- |
| Build | `embed-files-host-dev.sh` (the "Embed cmux Remote (dev)" phase) | embeds only when `CONFIGURATION` is `Debug` **and** `PRODUCT_BUNDLE_IDENTIFIER` is `com.cmuxterm.app.debug[.<tag>]`; otherwise it embeds nothing and removes a stale copy |
| App | `FilesHost` (CmuxNextCompat) | `isDebugBuild` is `#if DEBUG`, checked first, so a Release compile returns nil before it reads the disk; the bundle id must be `com.cmuxterm.app.debug[.<tag>]` |

Staging (`com.cmuxterm.app.staging`) does not count as dev: it is a shipping channel (the classic
migration lists it with stable, NIGHTLY and RC). In a Release build `CMUX_TUI_OWNER_LAUNCHER` is
never set, so `server ensure` spawns the owner exactly as before, and acpmux's argv is unchanged.
cmux-tui also refuses the variable unless it names the helper embedded in the owner's own app
(`<app>/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host`) and that file is
there (`local_owner/owner_launcher.rs`), so a shipped app, which has no such file, starts the
owner directly even when the variable reaches it.
iOS never embeds it (macOS only). `tests/test_files_host_dev_only.py` runs the real embed script
for every shipped configuration and bundle id and fails if any would embed it; run it yourself
after changing the phase, `FilesHost` or the pin (it is not a CI gate).

## The Files pane

The Files pane reads folders in the app's own process, and a process cannot disclaim itself, so
a DEV build reads them in a child instead: `ProcessDirectoryLister` (CmuxNextFiles) starts
`cmux Files (dev).app/…/cmux-files-host run -- <app>/Contents/Resources/bin/cmux-tui __files-lister`
at the first listing and keeps it for the app's life. The child (cmux-tui `files_lister.rs`)
answers one JSON line per request on its stdin (`list` a folder, `entry` for one item) with the
names, kinds, sizes, dates and hidden flags `DirectoryLister` reads itself; the app keeps its
package check and order. The pipe is private to the app: no socket, no new daemon method, no
relay.

The app makes one (`FilesPaneService.directoryLister`, from
`ProcessDirectoryLister.forThisBuild()`) and hands it to the Files pane, its columns view and the
sidebar file tree. Making it touches no disk; the helper is looked up at the first listing, with
the same `FilesHost` gates, so a Release build never finds one and reads in process. A child that cannot start, exits, or answers with an error makes that read happen in
process as before, and three failures in a row without an answer stop it trying.

Naming a folder can be a read too: `FileManager.displayName(atPath:)` asks Launch Services, which
looks inside the folder for its `.localized` marker, so the pane's tab title and its sidebar's
Favorites asked macOS for Downloads in the app's name before any listing. `FolderDisplayName`
names the home's standard folders (Desktop, Documents, Downloads, ...) from the system's own table
(`SystemFolderLocalizations`) instead, in every build: the same name, with no read.

## What still asks

- The DEV app's own reads, once per tag: Quick Look and thumbnails of a file in `~/Downloads`,
  Get Info's size of a folder there, copies and compression in the Files pane, a browser download
  saved to `~/Downloads`. The Files pane's listing no longer asks per tag ("The Files pane"). Open and save panels and drag and drop are
  the person's own choice and never ask.
- cmux Files (dev) itself asks once per folder kind (Desktop, Documents, Downloads, …), and again
  after the pin changes to a new certificate.
- Terminals that were already running when the build changed keep their old responsible process
  until their daemon restarts.

## The pinned asset

| Step | Script |
| --- | --- |
| Build (release `cmux-files-host`, bundle, unsigned zip) on a fleet Mac | `cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --os macos --arg files-host --artifact .build/artifacts/cmux-files-host-dev-unsigned.zip` |
| Sign with an Apple Development or Developer ID identity of team 7WLXT3NR37 and write the pin | `scripts/cmux-next/sign-files-host-dev.sh UNSIGNED.zip` |
| Publish for builds | `cmux-ci artifact-put` (fleet store) and, with R2 write credentials, `scripts/cmux-next/publish-signed-pinned-asset.sh --prefix files-host-dev` |
| Embed in DEV builds (Xcode "Embed cmux Remote (dev)" phase) | `scripts/cmux-next/embed-files-host-dev.sh` |

Without the pin file or the asset a DEV build embeds nothing and prints one note line; it then
works as before.

## Checking it on a Mac

1. Install two DEV builds with different tags that embed the helper.
2. In the first, open a terminal and run `ls ~/Downloads`. macOS asks for **cmux Files (dev)**.
   Allow it.
3. In the second, run `ls ~/Downloads`. Nothing asks. System Settings > Privacy & Security >
   Files and Folders lists cmux Files (dev) once, not either tag.
4. `cmux-files-host` shows in Activity Monitor as the parent of each build's `cmux-tui` owner.
