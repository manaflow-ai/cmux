# Live code: change your own app's Swift while it runs

Labs > **Live Code** (`labs.liveCode`) is an opt-in, temporary switch. Turn it on in a live code build
and the Swift you edit in your own checkout applies to the running app in seconds, with no new build
and no relaunch. Turn it off and the next launch is the app as built. Nobody who leaves it off pays
anything: the shipped app is never built for live code, and only Debug and bench builds watch at all
until a patch's signer is checked (cmux#13742).

| You want | Do this |
|---|---|
| Live mode on, in a tagged build (once per commit it builds; then a restart, sessions kept) | `cmux live start --swift`, Cmd-Shift-P > **Start Swift Live Mode**, or the button at the end of Settings > Advanced |
| Live mode off: the normal build of the same commit, sessions kept | `cmux live stop --swift`, or **Stop Swift Live Mode** |
| Is it on | `cmux live status` (its Swift line); the window's top row shows **Live mode** |
| Apply your edits in live mode | `scripts/live-code/live-mode.py patch FILE.swift` (patch.py with the live build's log and folder) |
| A live code build of your checkout (once) | `scripts/live-code/build.sh ~/live-code-build mine` (Debug; add `bench` after the tag for the bench configuration) |
| Turn it on | Settings > Advanced > Labs > Live Code, or `cmux settings set labs.liveCode true`, then relaunch |
| Apply your edits | `scripts/live-code/patch.py --log ~/live-code-build/xcodebuild.log --module CmuxNextApp --live ~/Library/Caches/cmux-next/live-code FILE.swift` |
| Undo the newest patch | `touch ~/Library/Caches/cmux-next/live-code/undo-1.rollback` (each rollback a new name) |
| See what applied | `~/Library/Caches/cmux-next/live-code/live-code.log` |
| Back to normal | Turn Live Code off and relaunch, or install a regular build |

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

## Live mode: restart into the live code build and back

Leo (2026-11-05): "So caveat (for now?) is that toggling it on will slow things because the
functions become more… loose? But there should likely be a way to switch it on and off for when
you're hot-building". The live code build is slower and bigger than the normal one (CmuxNextApp
unoptimized, a file at a time, its calls interposable), and that cost is in how the app is built.
So live mode swaps builds instead of flipping a setting:

- **Start** (`cmux live start --swift`, `scripts/live-code/live-mode.py start`): the commit the tagged
  app runs (`CMUXCommit`, else the HEAD of the checkout that built it) must be the checkout's HEAD.
  The first time for that commit it builds the live code build with `build.sh`, build-only
  (`reload.sh --build-only --keep-app`), while the app keeps running. It turns Labs > Live Code on
  (from a terminal that is the user-only confirmation sheet in cmux; the app's own button is the
  person's click), quits the app keeping every session (SIGTERM, as `reload.sh`), renames the normal
  bundle aside and the live one into its place, and starts it again with the tag's own launchd job.
- **Stop**: Live Code off, the same quit, the two bundles renamed back, the same start.
- Both print the restart time (quit to the app answering with its layout loaded) and whether every
  workspace, tab and running terminal is still there.
- The cache is `~/Library/Caches/cmux-next/live-mode/<tag>/<commit>/`: `build/` (its
  `xcodebuild.log` is what patches compile with) and whichever app is not installed. The next start
  of the same commit is a restart, no build. A swap is two renames on one volume.

The build runs on the Mac that runs the app, because a patch is compiled with that build's own
intermediates (`patch.py` reads its `xcodebuild.log`): a build fetched from another Mac could not
take patches. On a fleet Mac that is the fleet's build.

## What a NIGHTLY can and can't do

- Can: Live Web Reload (`cmux live start`), and a pull request's Swift in a copy
  (`scripts/cmux-next/try-pr.sh <PR> --live-code <log>`).
- Can't: live mode. `cmux live start --swift` refuses a NIGHTLY, and so do the palette and Settings
  buttons: no live code build of its commit is built or signed for it to restart into, and a
  Release build may load only patches signed by the app's own team (cmux#13742), which a person's
  checkout cannot make. Unsigned, ad hoc patches stay Debug and bench only.
