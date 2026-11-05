# Live code: change your own app's Swift while it runs

Labs > **Live Code** (`labs.liveCode`) is an opt-in, temporary switch. Turn it on in a live code build
and the Swift you edit in your own checkout applies to the running app in seconds, with no new build
and no relaunch. Turn it off and the next launch is the app as built. Nobody who leaves it off pays
anything: the shipped app is never built for live code, and only Debug and bench builds watch at all
until a patch's signer is checked (cmux#13742).

| You want | Do this |
|---|---|
| Live mode on, in a tagged build: a restart into the live code build (built once per commit), sessions kept, your edits patched in, then every save | `cmux live start --swift`, Cmd-Shift-P > **Start Swift Live Mode**, or the button at the end of Settings > Advanced |
| Live mode off: a restart into the optimized build of your edited checkout (made in the background while you edit), sessions kept | `cmux live stop --swift`, or **Stop Swift Live Mode**; `--discard` restarts into the build from before live mode |
| Is it on | `cmux live status` (its Swift line); the window's top row shows **Live mode** |
| Apply an edit by hand in live mode (saves already apply) | `scripts/live-code/live-mode.py patch FILE.swift` (patch.py with the live build's log and folder) |
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

Leo then: "For the swift bit why can't we simply apply after switching the build?" So it is one flow:

- **Start** (`cmux live start --swift`, `scripts/live-code/live-mode.py start`). The first time for the
  checkout's HEAD it builds the live code build with `build.sh`, build-only
  (`reload.sh --build-only --keep-app`), while the app keeps running, and records the Swift it
  compiled. It turns Labs > Live Code on (from a terminal that is the user-only confirmation sheet in
  cmux; the app's own button is the person's click), quits the app keeping every session (SIGTERM,
  as `reload.sh`), renames the running bundle aside and the live one into its place, and starts it
  with the tag's own launchd job. Then every CmuxNextApp file that differs from what the live build
  compiled is patched in at once: your edits are in right away.
- **While on**, a watcher (`live-mode.py watch`, in the background) patches each saved CmuxNextApp
  file in, and once saves stop for 20 s it makes the optimized build of the edited checkout
  (`reload.sh --tag TAG --build-only`, the tag's own warm derived data, at background priority).
  It stops when live mode does.
- **Stop** restarts into that optimized build, so the edits are kept and fast. If saves came after
  it, stop builds the rest first (incremental). `--discard` restarts into the build that ran before
  live mode instead; your files are not touched.
- Both print the restart time (quit to the app answering with its layout loaded) and whether every
  workspace, tab and running terminal is still there. A launch that fails puts the old build back
  and starts it.
- **Edits that can't apply live** wait for the stop build, and `cmux live status` counts them: a
  stored property or any other change of a type's layout (the app refuses that patch and says so),
  a file of another module, a new file, a deleted file. The function bodies, computed properties
  and methods of existing CmuxNextApp files apply.
- The cache is `~/Library/Caches/cmux-next/live-mode/<tag>/`: per commit, `build/` (its
  `xcodebuild.log` is what patches compile with), the Swift it compiled and `live.app` while it is
  not installed; `before.app`, the build that ran before live mode; `edited.app`, the optimized
  build of the edited checkout. The next start of the same commit is a restart and a patch, no
  build. A swap is two renames on one volume.
- The "Live mode" mark shows only in a live code build (its Info.plist has `CMUXLiveCodeBuild`): a
  normal build with Labs > Live Code on watches the folder but cannot be patched.

The builds run on the Mac that runs the app, because a patch is compiled with the live build's own
intermediates (`patch.py` reads its `xcodebuild.log`), and the stop build is the incremental build
of that checkout: a build fetched from another Mac could not take patches. On a fleet Mac that is
the fleet's build. The fleet run is `scripts/measure/live-mode-swift.sh`: an edit before start,
a save while on, and a stop into the optimized build, counted in pixels.

## What a NIGHTLY can and can't do

- Can: Live Web Reload (`cmux live start`), and a pull request's Swift in a copy
  (`scripts/cmux-next/try-pr.sh <PR> --live-code <log>`).
- Can't: live mode. `cmux live start --swift` refuses a NIGHTLY, and so do the palette and Settings
  buttons: no live code build of its commit is built or signed for it to restart into, and a
  Release build may load only patches signed by the app's own team (cmux#13742), which a person's
  checkout cannot make. Unsigned, ad hoc patches stay Debug and bench only.
