# Live code: change your own app's Swift while it runs

Labs > **Live Code** (`labs.liveCode`) is an opt-in, temporary switch. Turn it on in a live code build
and the Swift you edit in your own checkout applies to the running app in seconds, with no new build
and no relaunch. Turn it off and the next launch is the app as built. Nobody who leaves it off pays
anything: the shipped app is never built for live code, and only Debug and bench builds watch at all
until a patch's signer is checked (cmux#13742).

A live code build is slower than the regular build of the same tag the whole time it runs, whether
the switch is on or off (see [How it works](#how-it-works)). So for hot-building, switch the build,
not just the setting: `scripts/live-code/switch.sh on TAG` before you start, and
`scripts/live-code/switch.sh off TAG` when you're done. The two builds stay side by side, each in its
own DerivedData, so each switch compiles only what changed since that build was last used.

| You want | Do this |
|---|---|
| Switch a tag to its live code build, Live Code on | `scripts/live-code/switch.sh on mine` (builds it the first time, in `~/Library/Caches/cmux-next/live-code-builds/mine`) |
| Switch back to the regular build, Live Code off | `scripts/live-code/switch.sh off mine` |
| Which build and setting a tag has | `scripts/live-code/switch.sh status mine` |
| A live code build of your checkout (once) | `scripts/live-code/build.sh ~/live-code-build mine` (Debug; add `bench` after the tag for the bench configuration) |
| Turn it on | Settings > Advanced > Labs > Live Code, or `cmux settings set labs.liveCode true`, then relaunch |
| Apply your edits | `scripts/live-code/patch.py --log ~/live-code-build/xcodebuild.log --module CmuxNextApp --live ~/Library/Caches/cmux-next/live-code FILE.swift` |
| Undo the newest patch | `touch ~/Library/Caches/cmux-next/live-code/undo-1.rollback` (each rollback a new name) |
| See what applied | `~/Library/Caches/cmux-next/live-code/live-code.log` |
| Back to normal | `scripts/live-code/switch.sh off TAG`. Live Code off alone stops the watching, but the slower build keeps running |
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
  which is why only this build has it: every call between `CmuxNextApp`'s functions goes through a
  pointer and is never inlined, and nothing is stripped as unused. The cost has not been measured
  yet. `switch.sh` builds into its own DerivedData (`CMUX_DERIVED_DATA`), so the tag's regular build
  is never overwritten.
- **The patch.** `patch.py` compiles the edited files with the frontend command the build logged for
  their module, links their objects into a dylib, signs it ad hoc and moves it into the live folder.
- **The app** (`CmuxNextLiveCode`). It loads each new patch once and refuses it when a type changed
  size (a stored property added or removed). It repoints every function the patch defines, then
  invalidates and draws every window. A new `*.rollback` file in the folder undoes the newest patch:
  every function it replaced runs the code before it again, and every window redraws. Each line it
  applies, rolls back or refuses goes to `live-code.log` in the folder.

## What applies, and what needs a rebuild

Applies: changes inside functions and computed properties of `CmuxNextApp`, and AppKit drawing and
layout code, which runs again at once. Needs a rebuild: stored properties, enum cases, protocols,
resources, strings and `Package.swift`. leo-workspace `research/2026-11-04-hot-swap-architecture.md`
has the numbers and what would make more of them live.

## Not yet

- The installed nightly. The switch can't yet turn an installed nightly into a live code build: that
  needs a variant of the running commit, swapped in and back, and the signer check (cmux#13742).
