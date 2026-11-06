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
| Live mode on, in a tagged build: a restart into the live code build (built once per commit), sessions kept, your edits patched in, then every save | `cmux live start --swift`, Cmd-Shift-P > **Start Swift Live Mode**, or the button at the end of Settings > Advanced |
| Live mode off: a restart into the optimized build of your edited checkout (made in the background while you edit), sessions kept | `cmux live stop --swift`, or **Stop Swift Live Mode**; `--discard` restarts into the build from before live mode |
| Is it on | `cmux live status` (its Swift line); the window's top row shows **Live mode** |
| Apply an edit by hand in live mode (saves already apply) | `scripts/live-code/live-mode.py patch FILE.swift` (patch.py with the live build's log and folder) |
| A live code build of your checkout (once) | `scripts/live-code/build.sh ~/live-code-build mine` (Debug; add `bench` after the tag for the bench configuration) |
| Turn it on | Settings > Advanced > Labs > Live Code, or `cmux settings set labs.liveCode true`, then relaunch |
| Apply your edits | `scripts/live-code/patch.py --log ~/live-code-build/xcodebuild.log --live ~/Library/Caches/cmux-next/live-code FILE.swift` (each file compiles with its own module's command) |
| Hot optimize: make the build you edited fast, no rebuild or relaunch | `scripts/live-code/patch.py --log ~/live-code-build/xcodebuild.log --module CmuxNextApp --live ~/Library/Caches/cmux-next/live-code --optimize --all` ([below](#hot-optimize)) |
| See what is applied | `cmux live-code status` (each patch newest first: commit, files, functions; the last error) |
| Apply a built patch | `cmux live-code apply PATCH.dylib` (waits for the app's answer) |
| Undo the newest patch | `cmux live-code undo` (`--all`: back to the code as built) |
| Read the app's live code log | `cmux live-code log` |
| Back to normal | `scripts/live-code/switch.sh off TAG`. Live Code off alone stops the watching, but the slower build keeps running |
| Try a pull request's Swift in a copy | `scripts/cmux-next/try-pr.sh <PR> --from <the build>.app --live-code <the reload's log>` ([hot-reload.md](hot-reload.md#try-a-pull-request-without-knowing-what-it-changed)) |

`CMUX_LIVE_CODE_DIR=DIR` starts the same watcher on another folder with no switch (the fleet's
measurement, `scripts/measure/live-code-app.sh`, does this).

What the live code build costs while it runs, against a regular build of the same commit:
`scripts/measure/live-code-cost.sh` on a fleet Mac (build seconds, binary and app size, and the
instant-create bench of both apps interleaved, compared with `scripts/measure/bench-ab/bench_ab.py`).

## How it works

- **The build** (`scripts/live-code/build.sh`), in two passes. The first, `CMUX_LIVE_CODE_BUILD=1`,
  compiles every CmuxNext module (all link into the one app executable) unoptimized, testable and a
  file at a time, and links the app with classic binds and its symbols exported. Third-party packages
  keep the configuration's optimization. The second links it again with the Swift symbols in its export
  trie that name a CmuxNext module made
  interposable (`CMUX_LIVE_CODE_INTERPOSABLE_LIST`), so the app's calls to its own functions go
  through pointers dyld can repoint. The first pass alone builds an app no patch can repoint, and a
  blanket `-interposable` stops the app at launch (a private type's symbol dyld cannot bind). The
  first pass's log, `xcodebuild.log`, is the one `patch.py` reads. That costs some speed and size,
  which is why only this build has it: every call between the CmuxNext modules' functions goes
  through a pointer and is never inlined, and nothing is stripped as unused. `build.sh` writes the
  build's size and symbol counts to `cost.json`. `switch.sh` builds into its own DerivedData
  (`CMUX_DERIVED_DATA`), so the tag's regular build is never overwritten.
- **The patch.** `patch.py` compiles each edited file with the frontend command the build logged for
  its module (its folder under `Sources/`), links their objects into a dylib, signs it and moves it
  into the live folder. It signs ad hoc unless `--sign IDENTITY` (or `CMUX_LIVE_CODE_SIGN_IDENTITY`)
  names a codesign identity: a Debug or bench build loads an ad hoc patch, any other build signed by
  a team only one signed by that team, so a Release live code build signed by a team refuses an ad
  hoc patch.
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
redraw waits for the main thread. `status` exits 3 when no app watches the folder, its last status still shown. When the app does not answer at all (exit 4, or the tools'
`live_code.no_answer`), relaunch it: the next launch runs the code as built. Outside Debug and bench,
an app signed by a team loads only a patch signed by that team (cmux#13742), and `status` says so
as `team_signed_only`. It loads one only while macOS enforces library validation on it (the hardened
runtime, without the disable-library-validation entitlement), so the file dyld maps is checked too,
not just the copy the app checked; without it, every patch is refused and the log says why. An app with no team (unsigned or ad hoc, so never notarized or distributed)
loads any validly signed patch, ad hoc included, and its log says so when it starts watching.
Whether the app has a team comes from its own running code signature only. `--dir` (or `CMUX_LIVE_CODE_DIR`) names another live folder.

The folder's protocol, for tools of their own: a new `NAME.dylib` applies (with `NAME.json`, its
commit and files, written first); a new `*.rollback` undoes the newest patch and a new
`*.rollback-all` undoes them all; the app answers each by name in `live-code.log` (`applied NAME`,
`rolled back NAME`, `NAME refused: why`) and keeps `status.json`. Write a file under a hidden name
and rename it into place.

## Hot optimize

A live code build runs `CmuxNextApp` at `-Onone`. `--optimize --all` compiles every file of the
module again at `-O`, your edits on disk included, against the running build, and applies the
result as one patch: the app you live edited keeps running, now on optimized code. It is the same
patch path as an edit, so it shows in `live-code.log` and one `*.rollback` undoes it.

- It leaves out each file that defines a stored global or static (`static let`, `static var`, a
  file-level `let` or `var`). A patch would bring its own empty copy of that state, and the app's
  would be lost. Those files keep the code they run now.
- What stays slower than a regular build: calls between the app's own functions still go through a
  pointer, so the optimizer inlines only within a file, and the other modules are as built.
- The patch's last line says how many files it optimized (`files=`), how many it left out
  (`kept_for_state=`) and how long the compile took. The compiles run in parallel (`--jobs`,
  default: every core).

## What applies, and what needs a rebuild

Applies: changes inside functions and computed properties of any CmuxNext module, and AppKit drawing and
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
