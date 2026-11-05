# Live code: change your own app's Swift while it runs

Labs > **Live Code** (`labs.liveCode`) is an opt-in, temporary switch. Turn it on in a live code build
and the Swift you edit in your own checkout applies to the running app in seconds, with no new build
and no relaunch. Turn it off and the next launch is the app as built. Nobody who leaves it off pays
anything: the shipped app is never built for live code, and only Debug and bench builds watch at all
until a patch's signer is checked (cmux#13742).

| You want | Do this |
|---|---|
| A live code build of your checkout (once) | `scripts/live-code/build.sh ~/live-code-build mine` (Debug; add `bench` after the tag for the bench configuration) |
| Turn it on | Settings > Advanced > Labs > Live Code, or `cmux settings set labs.liveCode true`, then relaunch |
| Apply your edits | `scripts/live-code/patch.py --log ~/live-code-build/xcodebuild.log --module CmuxNextApp --live ~/Library/Caches/cmux-next/live-code FILE.swift` |
| See what is applied | `cmux live-code status` (each patch newest first: commit, files, functions; the last error) |
| Apply a built patch | `cmux live-code apply PATCH.dylib` (waits for the app's answer) |
| Undo the newest patch | `cmux live-code undo` (`--all`: back to the code as built) |
| Read the app's live code log | `cmux live-code log` |
| Back to normal | Turn Live Code off and relaunch, or install a regular build |
| Try a pull request's Swift in a copy | `scripts/cmux-next/try-pr.sh <PR> --from <the build>.app --live-code <the reload's log>` ([hot-reload.md](hot-reload.md#try-a-pull-request-without-knowing-what-it-changed)) |

`CMUX_LIVE_CODE_DIR=DIR` starts the same watcher on another folder with no switch (the fleet's
measurement, `scripts/measure/live-code-app.sh`, does this).

## How it works

- **The build** (`scripts/live-code/build.sh`), in two passes. The first, `CMUX_LIVE_CODE_BUILD=1`,
  compiles `CmuxNextApp` unoptimized, testable and a file at a time, and links the app with classic
  binds and its symbols exported. The second links it again with the `CmuxNextApp` symbols in its export trie made
  interposable (`CMUX_LIVE_CODE_INTERPOSABLE_LIST`), so the app's calls to its own functions go
  through pointers dyld can repoint. The first pass alone builds an app no patch can repoint, and a
  blanket `-interposable` stops the app at launch (a private type's symbol dyld cannot bind). The
  first pass's log, `xcodebuild.log`, is the one `patch.py` reads. That costs some speed and size,
  which is why only this build has it.
- **The patch.** `patch.py` compiles the edited files with the frontend command the build logged for
  their module, links their objects into a dylib, signs it and moves it into the live folder. It
  signs ad hoc unless `--sign IDENTITY` (or `CMUX_LIVE_CODE_SIGN_IDENTITY`) names a codesign
  identity: a Debug or bench build loads an ad hoc patch, any other build only one signed by its own
  team, so a Release live code build made and signed locally ad hoc refuses every patch.
- **The app** (`CmuxNextLiveCode`). It loads each new patch once and refuses it when a type changed
  size (a stored property added or removed). It repoints every function the patch defines, then
  invalidates and draws every window. A new `*.rollback` file in the folder undoes the newest patch:
  every function it replaced runs the code before it again, and every window redraws. Each line it
  applies, rolls back or refuses goes to `live-code.log` in the folder.

## Repairing a running app

`cmux live-code` (the app's own bundled `cmux`) and its MCP tools (`live_code_status`,
`live_code_apply`, `live_code_undo`, `live_code_log`, for an agent in an acpmux session or any
harness) work through the live folder, never the app's window or its main thread. A patch that
wedged the UI can still be undone: the app's engine is an actor off the main thread, and only the
redraw waits for the main thread. When the app does not answer at all (exit 4, or the tools'
`live_code.no_answer`), relaunch it: the next launch runs the code as built. Outside Debug and bench,
only a patch signed by the app's own team loads (cmux#13742); `status` says so as
`team_signed_only`. `--dir` (or `CMUX_LIVE_CODE_DIR`) names another live folder.

The folder's protocol, for tools of their own: a new `NAME.dylib` applies (with `NAME.json`, its
commit and files, written first); a new `*.rollback` undoes the newest patch and a new
`*.rollback-all` undoes them all; the app answers each by name in `live-code.log` (`applied NAME`,
`rolled back NAME`, `NAME refused: why`) and keeps `status.json`. Write a file under a hidden name
and rename it into place.

## What applies, and what needs a rebuild

Applies: changes inside functions and computed properties of `CmuxNextApp`, and AppKit drawing and
layout code, which runs again at once. Needs a rebuild: stored properties, enum cases, protocols,
resources, strings and `Package.swift`. leo-workspace `research/2026-11-04-hot-swap-architecture.md`
has the numbers and what would make more of them live.

## Not yet

- The installed nightly. The switch can't yet turn an installed nightly into a live code build: that
  needs a variant of the running commit, swapped in and back, and the signer check (cmux#13742).
