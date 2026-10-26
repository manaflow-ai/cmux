# cmux-next startup: libghostty init and config parse off the main thread

Status: spike p08-startup-112 (chrome-parity program p08-startup), 2026-10-26. Read only; no code
changes. Depends on p08-startup-026 (Ghostty config bytes prefetched), which is not on
`perf/chrome-parity` yet, so this answer is written against 026's spec in
[chrome-parity/p08-startup.md](chrome-parity/p08-startup.md) ("026 Q2 Ghostty config").

Sources: the `ghostty` submodule at the commit pinned on `perf/chrome-parity`
(`cb1ef7091cdef0b581ee2cbd83742b653253523e`); paths below are relative to that checkout. cmux
paths are relative to `Packages/macOS/CmuxNext/Sources/`.

## Question

Can `ghostty_init` and the Ghostty config parse (`ghostty_config_new` through
`ghostty_config_finalize`) run on the launch thread instead of the main thread, so
`GhosttyRuntime.init` on main does only `ghostty_app_new` and the observers?

## Answer

**Config parse: yes, after `ghostty_init` has returned and one input is supplied from main.
`ghostty_init`: not as it is, because it changes process-wide state that other launch threads
read. A small fork change makes it yes:** split the process-wide part (locale, environment
snapshot, signals, rlimit) from the rest. cmux then runs the process-wide part in `main()` before
any thread starts, and everything else on the launch thread. This is worth doing only if the
measured main-thread cost is at least 3 ms (see the follow-up task).

### Where the work runs today

- `CmuxNextTerminal/GhosttyRuntime.swift:66-111`: the first `GhosttyRuntime.shared` access
  (`ThemeBridge.start`, `CmuxNextApp/AppDelegate.swift:108`) runs `ghostty_init` (line 80), then
  `loadConfig` (line 86), then `ghostty_app_new` (line 103), all on main. The module is
  `defaultIsolation(MainActor.self)` (`Package.swift:151`).
- `TerminalTimings.runtimePhase` already records `ghostty_init`, `config_load` and `app_new`
  (`GhosttyRuntime.swift:67-84`). `debug.timings` reports them as `ghostty_runtime_ms`
  (`CmuxNextApp/Control/DebugTimings.swift:151`). No numbers are recorded in `plans/` yet.
- By the time `ThemeBridge.start` runs, other threads are already running: `LaunchWarmup.start`,
  the `BackgroundWork` prefetches and `DaemonService.prestart`
  (`CmuxNextApp/CmuxNextApp.swift:37-61`). After 026 and 014, the LaunchPrefetch thread runs too.
  Upstream Ghostty.app calls `ghostty_init` in `main.swift` before `NSApplicationMain`, on a
  single-threaded process (`macos/Sources/App/macOS/main.swift:8`). cmux already calls it later,
  with other threads alive.

### `ghostty_init`: step by step

`ghostty_init` (`src/main_c.zig:123-148`) calls `global.init` (`src/global.zig:132-320`). Each step:

| Step | Source | Safe off main, with other threads alive? |
| --- | --- | --- |
| Writes the process global `state` with no synchronization | `global.zig:112`, `146-168` | Yes, if every reader on main gets it through a handoff that orders memory (continuation resume, semaphore, actor hop). `global.alloc()`, `global.io()` and the others read `state.?` (`global.zig:355-465`). |
| Owned environment snapshot, temp dir | `global.zig:201-213` | Yes. It reads `environ`, but cmux froze environment writes in `main()` (`ProcessEnvironmentGuard`). |
| CLI action detect, `GHOSTTY_LOG` | `global.zig:218-244` | Yes. Pure reads of the snapshot. |
| `sigaction(SIGPIPE, SIG_IGN)` | `global.zig:247`, `504-522` | Yes on any thread (one process-wide syscall). It does change process state; cmux already sets its own signal policy in `main()` (`ChildSignalDefaults.installAppSignalPolicy`). |
| **`ensureLocale`, then `syncEnviron`** | `global.zig:282-283`; `src/os/locale.zig:12-77` | **No.** If `LANG` is unset or empty (every Finder, Dock and launchd launch of the .app), `setLangFromCocoa` calls `setenv("LANG")` and `setenv("LANGUAGE")` (`locale.zig:23-26`, `120`, `143`). On fallback it also calls `setenv`/`unsetenv` (`locale.zig:56-57`, `73`). Then `setlocale(LC_ALL, "")` changes the libc global locale (`locale.zig:30`). `setenv` can reallocate `environ` and free the old block while another thread reads it. That is the documented iOS SIGSEGV (`global.zig:269-281`; `src/crash/sentry.zig:59-67`). `docs/ghostty-fork.md`, "iOS startup locale before crash reporting", records a second crash: build `20260801151612` crashed in `ghostty_init + 1388` while main was in `setlocale` and another thread was running. POSIX does not require `setlocale` to be thread-safe. In cmux at that point, `ProcessInfo.environment`, `posix_spawn` (daemon prestart) and CEF all read `environ` on other threads. |
| `ResourceLimits.init` (`setrlimit` NOFILE) | `global.zig:286`, `530-536` | Yes, one syscall. cmux raises the same limit first (`OpenFileLimit().raise()`). |
| `crash.init` | `global.zig:289` | Not applicable. cmux builds GhosttyKit with `-Dsentry=false` (`scripts/ensure-ghosttykit.sh:283`, `scripts/build-sign-upload.sh:67`), so `sentry.init` returns at once (`sentry.zig:51`). |
| `glslang.init`, `oni.init` | `global.zig:306`, `309` | Yes. These are once-per-process inits. No other cmux code uses glslang or oniguruma before them. They must not run twice. |
| `resourcesDir` | `global.zig:313`; `src/os/resourcesdir.zig:41-120` | Yes. It reads the snapshot (`GHOSTTY_RESOURCES_DIR`, which cmux set before the freeze) and stats files. |
| `i18n.init` (`bindtextdomain`) | `global.zig:317`; `src/os/i18n.zig:28-52` | Yes, if nothing calls `ghostty_translate` at the same time. cmux does not call it during launch. |

Also: `global.init` is not idempotent. A second call overwrites `state` and leaks the first
(`global.zig:146`). Off main, it must have exactly one owner. Every other path that needs it
(`GhosttyRuntime.shared`, and the tests that use `_ = shared // runs ghostty_init`, for example
`GhosttyRuntime+DefaultFiles.swift:47`) waits for that owner. Nothing may call it again.

### Config parse: step by step

The config C API is `src/config/CApi.zig`. A `Config` owns an arena and has no global mutable state
(`src/config/Config.zig:3896-3929`). The calls only read the global state that `ghostty_init` has
already set:

- Allocation: `global.alloc()` (`CApi.zig:16-29`). This is libc `malloc` in ReleaseFast
  (`global.zig:172-194`), which is thread-safe. It is `std.heap.DebugAllocator(.{})` in Debug, which
  is thread-safe when the build is not single-threaded (the default).
- File reads: `loadFile`, `loadRecursiveFiles` and theme files use `global.io()`, a
  `std.Io.Threaded` (`Config.zig:3989-4018`, `4315-4400`, `4520`). These are plain syscalls on a
  descriptor that only this config owns. After 026, the user's files arrive as bytes through
  `ghostty_config_load_string` (`CApi.zig:112-123`). Only `config-file` includes
  (`loadRecursiveFiles`) and `theme =` files still read the disk.
- `loadDefaultFiles` (`Config.zig:4134-4205`) uses `NSFileManager.defaultManager` through objc
  (`src/os/macos.zig:110-140`). Apple documents the shared `FileManager` as safe to call from more
  than one thread. It creates no autorelease pool, so the launch thread must wrap the call in
  `autoreleasepool {}`. If no file is found, this step can write a template file. That is file I/O
  and can run on any thread.
- `finalize` (`Config.zig:4618`): it reads `SHELL` from the snapshot (`4696`), calls `getpwuid_r`
  (reentrant; `src/os/passwd.zig:34-41`), and runs `probableCliEnvironment` (`5194`). These are
  safe. **One AppKit call:** if `click-repeat-interval` is 0, it calls
  `+[NSEvent doubleClickInterval]` (`Config.zig:4780`, `src/os/mouse.zig:8-25`). Apple gives no
  thread-safety guarantee for this call. cmux reads the value on main (it is cheap) and passes
  `click-repeat-interval = <ms>` as a `load_string` line before `finalize`. Then the config never
  makes the call off main, and the value is the same.
- Diagnostics (`CApi.zig:171-180`) belong to the config object.
- `ghostty_app_new` stays on main: the app gets `wakeup_cb`/`action_cb` callbacks and
  `ghostty_app_tick`, which are main-thread contracts. It is cheap. It sets up the shared font grid
  (`src/font/SharedGridSet.zig:53-62`) and clones the config (`src/apprt/embedded.zig:157-174`,
  `2393-2407`; `src/App.zig:202-216`). The keymap (TIS, main-only) is lazy (`embedded.zig:172`).

The cmux side of `loadConfig` (`GhosttyRuntime.swift:191-245`) is not ready to run off main as it
is. It reads main-actor statics (`themeOverride`, `themeEdits`, `colorSchemeIsDark`,
`fontOverride`, `terminalBackgroundOverridden`, and `seeThroughShown` through the
`seeThroughHosts` hash table), and it writes `seeThroughLoaded`. Because the module is
default-MainActor, calling it off main does not compile. That is the correct result. The fix is a
value input: main takes a `Sendable` snapshot of those statics, a `nonisolated` builder turns
snapshot + 026's bytes into a finalized config, and main adopts the result. After the handoff, the
`ghostty_config_t` has one owner. It moves across threads once, in a `~Copyable` or
`sending` box, not an `@unchecked Sendable` class that can be shared.

### What Chromium does

Chrome does process-wide setup (ICU and locale data, signal handlers, environment) once, on the
main thread, before it starts any thread: `ContentMainRunnerImpl::Initialize`
(`content/app/content_main_runner_impl.cc`). `base::Environment` documents that setting variables
is not thread-safe (`base/environment.h`). Expensive, isolated startup work then goes to the
`ThreadPool` from `BrowserMainLoop::CreateStartupTasks` (`content/browser/browser_main_loop.cc`).
The follow-up below does the same split: process-wide mutation in `main()` while the process has
one thread, then the rest on the launch thread.

## Follow-up task (proposed id p08-startup-115): libghostty runtime init off main

Size M, risk:high (a GhosttyKit fork change and launch ordering). It depends on 026 and 014.

- **Measure first.** On the fleet, run 5 warm and 5 cold launches at the base. Record
  `ghostty_runtime_ms.ghostty_init` and `config_load` after 026. If the main-thread sum is below 3 ms,
  close the task with the numbers (the same rule as 067 Sparkle). Do not move it.
- **Fork** (`ghostty`, per [cmux-ghostty](../../skills/cmux-ghostty/SKILL.md), with a conflict note in
  `docs/ghostty-fork.md`). Split `global.init` into
  `ghostty_init_process(argc, argv)`, which does the state allocation, environment snapshot,
  `initSignals`, `ensureLocale`, `syncEnviron` and rlimits, and
  `ghostty_init_runtime()`, which does `glslang.init`, `oni.init`, `resourcesDir`, `i18n.init` and
  `crash.init`. Each runs exactly once and returns an error if called again.
  `ghostty_init` stays as both calls in order, so upstream Ghostty.app and iOS do not change. Keep
  the ordering rule from "iOS startup locale before crash reporting": locale before any Ghostty
  thread.
- **cmux, files:** `CmuxNextApp/CmuxNextApp+LaunchEnvironment.swift`,
  `CmuxNextTerminal/GhosttyRuntime.swift`, a new `CmuxNextTerminal/GhosttyLaunchConfig.swift`,
  `CmuxNextApp/Startup/Startup+Terminal.swift` (which 001/026 create).
  `prepareLaunchEnvironment` calls `ghostty_init_process` just before `environmentGuard.freeze()`,
  while the process has one thread. Its `setenv` calls are then this process's last environment
  writes, as the guard requires. The launch thread (014) runs `ghostty_init_runtime`. Then, inside
  `autoreleasepool`, it builds the config from 026's bytes and a main-taken `GhosttyLaunchConfig.Input`
  (the statics above plus `NSEvent.doubleClickInterval`). It hands the result to main through 014's
  typed handoff. That handoff uses no new lock, no `DispatchQueue.main.async` and no polling. Main
  makes no blocking wait on it: `GhosttyRuntime` is created when the handoff arrives, and terminal
  surfaces that are requested earlier wait for that model state, as 026's surfaces already do for
  config bytes. `GhosttyRuntime.init` takes the built config, so tests inject one; the static
  `shared` path stays for tests that do not pass one. Default-off feature
  `startup.ghosttyRuntimeOffMain` in `schemas/features/features.d/` (the directory the chrome-parity
  program adds).
- **Acceptance:** with the feature on, `ghostty_init` and `config_load` show 0 ms on main (they run
  on the launch thread). Config diagnostics are identical on both paths (test). A test fails if
  `ghostty_init_process` comes after the environment freeze or after any thread start
  (`crash_ratchet.py env_write` covers the write side). Cold launch has no SIGSEGV in 50 Finder-style
  launches (`LANG` unset) under TSan on the fleet.
- **Test phase:** fleet `CmuxNextTerminal` tests (new `GhosttyLaunchConfigTests`: same diagnostics,
  same `click-repeat-interval`, one-owner init), relaunch-e2e with `LANG` unset, and
  `dfl.theme - dfl.settings_read` before and after.

## Not checked in this spike

- No numbers. This spike reads code only. Swift and zig were not built, and no launch was timed.
- `std.Io.Threaded` thread safety comes from its design (it is the threaded `Io` implementation).
  This spike did not audit it line by line in the Zig 0.16 standard library.
- The `NSEvent.doubleClickInterval` risk is a precaution. I did not prove that the call fails off
  main. Passing the value in from main removes the question at no measurable cost.
