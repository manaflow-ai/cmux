# Config ideas compared: a browser with JSON-configured sidebars, and cmux NEXT

Leo, 2026-11-14: "[a link to a browser with JSON-configured sidebars] we can look at these guys"

We read the public docs of a browser with JSON-configured sidebars (GPL-3.0: ideas only, no code
copied) and set each of its config ideas beside cmux NEXT. Line numbers are at `feat-cmux-next`
43c729420dd. The edit-to-repaint numbers at the end are measured on a fleet-built app
(`scripts/measure/edit-repaint.sh`).

## The table

| Idea (theirs) | Ours (where) | Gap | Proposed Rust change |
| --- | --- | --- | --- |
| **One config file plus a JSON Schema the app writes next to it**, generated from the same settings table the validator reads, refreshed only when its content changes, and named by `$schema` in the file. | We have it. The schema is generated from the rows `cmux-config` validates with (`cmux-tui/crates/cmux-config/src/schema/json_schema.rs:2`). It carries a hash (`x-cmux-schema-hash`), and its drift is tested against the `accepts`/`refuses` samples (`cmux-tui/crates/cmux-config/tests/json_schema.rs`). A person or agent prints it with `cmux settings schema` (`cmux-tui/crates/cmux-tui/src/cli/app/settings.rs:83`). | Nothing writes the schema next to `~/.config/cmux/cmux-next.json`. An editor sees no completion unless the person runs `cmux settings schema > file` by hand and adds `$schema`. The file also goes stale after an upgrade. | When the daemon loads the config, `cmux-config` writes `cmux-next.schema.json` beside the file, but only when its `x-cmux-schema-hash` differs (temp file and rename, never writing through a symlink). `cmux settings init` adds `"$schema": "./cmux-next.schema.json"` to a new file. Defaults are unchanged: nothing else is written into the person's file. |
| **Theme files with their own schema**: `themes/NAME.json`, with `dark` and `light` sections of colour roles. | Partly. `appearance.themeFile` names `~/.config/cmux/themes/NAME.json` (`Packages/macOS/CmuxNext/Sources/CmuxNextSettings/ThemeFileSetting.swift:5`). A theme file is a partial overlay in cmux-next.json's own shape, plus `colors` and a `ghostty` block (`ThemeFileOverlay.swift:5-26`). It is capped at 256 KB (`ThemeFileSetting.swift:14`), keeps its last good text when a save does not parse (`ThemeFileOverlay.swift:33`), and repaints live. | The theme overlay is parsed and validated in Swift (`SettingsController.swift:410`, `ThemeFileOverlay`), so the CLI, the daemon and the phone cannot check a theme file. There is no theme schema, and there are no `cmux theme list/use/check` verbs. Light and dark come from the terminal theme pair, not from sections of the file. | Move theme-file reading into `cmux-config`, as `theme_file::read(name) -> (overlay, diagnostics)` over the same schema rows. Emit `cmux-theme.schema.json` beside the settings schema. Add `cmux theme list/use/check [--json]` on top. The Swift `ThemeFileOverlay` then reads the daemon's result, and the format stays the same. |
| **A file watcher where the file wins**: each change event means "read again and reconcile"; the app never writes the file; symlinks are followed; reads are capped at 1 MB and are FIFO-safe; a folder that appears after launch is noticed. | Mostly. The watcher is inotify or kqueue, with no polling. It coalesces 100 ms of quiet, with a 1 s cap (`cmux-tui/crates/cmux-config/src/watch.rs:63-65`), and follows rename, recreate and missing folders. A reload reports a change only when the effective settings differ (`store/state.rs:108`). Unlike theirs, the app and the daemon do write the file, under one advisory lock, as comment-preserving JSONC edits, published by temp file and rename (`owner.rs:92`). | Two readers: the daemon (`cmux-config`) and the Mac app (`SettingsController`, its own `ConfigFileWatcher` and `JSONC.parse`) each watch and parse cmux-next.json. They can disagree for a moment and validate differently. The daemon's read is unbounded and blocks on a FIFO (`cmux-tui/crates/cmux-config/src/fsio.rs:12`). | Make the read in `fsio.rs` bounded: open it non-blocking, accept only a regular file, cap it at 1 MB, and turn anything else into an `UnreadableFile` diagnostic. Longer term, the app takes the daemon's `settings.snapshot` and its `settings-changed` event instead of parsing the file itself. |
| **Per-key errors**: a bad value skips only that setting, and there is one toast per distinct problem ("config.json: key must be a, b or c"). A file that does not parse keeps what is showing. | We have it. A refused value becomes an `InvalidValue` diagnostic for its key while the other keys apply (`cmux-tui/crates/cmux-config/src/store/state.rs:153`). An unreadable file keeps the last good root (`state.rs:145`). The app shows a toast that names the key and the value, offers to open the row or the file, and announces each problem once until it is fixed (`SettingsDiagnosticToasts.swift:18`). `cmux settings validate` prints the same diagnostics offline. | The toast shows one problem at a time, with "and N more", and the Swift and Rust validators each produce their own diagnostics. | No new mechanism. The single-reader change above makes the toast's list the daemon's diagnostics, so the CLI, the toast and Settings all say the same thing. |
| **A control socket that streams named events** (`tab.opened`, `settings.changed`, ...) to outside clients. Events are built only while someone subscribes. Past 1,000 queued events the oldest are dropped and the next event carries `dropped: N`. | We have it. `subscribe` streams `settings-changed` (`{revision, keys, origin}`), `keybindings-changed`, tree, tab and agent events (`cmux-tui/spec/events.md:15`, `:50`). Each subscription holds 4,096 pending events (`cmux-tui-core/src/event_bus.rs:13`); `title-changed` coalesces. Extensions get scoped `<family>.changed` invalidations (`cmux-tui-core/src/apps/subscriptions.rs:39`). | Our overflow ends the subscription, and the client resubscribes and refetches (`events.md:131`). That is a deliberate, safer choice for state streams, so we keep it. The real gap is that extensions get no `settings.changed` or `theme.changed`, so an extension cannot redraw when cmux-next.json or the theme changes. | Publish `settings.changed` (keys only, no values) into the apps stream family from the same place that emits `settings-changed`, gated by a new `settings:read` scope. Add it to `schema/v2/events.json` so that the SDK tables pick it up. |
| **A CLI over the files** (`config path/init/get/set/unset/list/edit/check --json`, `theme new/use/list/check`) that needs no running app. | Mostly. `cmux settings get/set/reset/unset/list/schema/validate` exists (`cmux-tui/crates/cmux-tui/src/cli/app/settings.rs:33`); `cmux config` is an alias. Writes go through the daemon's lock, keep comments, and are atomic. `validate`, `schema` and `list --keys` need no daemon. | There are no `path`, `init` or `edit` verbs and no `theme` verbs. | `cmux settings path`, `cmux settings init` (writes `{"$schema": ...}` only if the file is missing) and `cmux settings edit` (`$VISUAL`/`$EDITOR`, then `validate`), all in `cmux-tui/src/cli/app/settings.rs`, plus the `theme` verbs above. |

## What is ours and not theirs

- The extension platform: a sandboxed runtime that hot-reloads sidebar sections, panes and
  palette scopes (`docs/cmux-next/extensions/dev-loop.md`). In the other design, a "plugin" is a
  JSON setting.
- Managed (MDM) and team-policy layers merge over the user's file and keep applying while that
  file is broken.
- Comment-preserving writes, so the in-app Settings, the CLI and a hand edit can share one file.

## Edit to repaint, measured

We use the harness `scripts/measure/edit-repaint.sh` (#42813), which runs `scripts/cmux-next/edit-repaint.py` on a fleet
measure Mac against a tagged bench build:

```sh
cmux-ci run --class exclusive --label measure --measurement --script scripts/measure/edit-repaint.sh --ref <sha>
```

Each case runs 10 rounds. Before each write, the harness takes five `debug.window_snapshot` captures and masks the 32 px
blocks that change on their own. It then writes the file in place and captures back to back. `upper_ms` is the time to
the reply of the first capture with at least two changed blocks; `lower_ms` is the time to the request of the last capture
that had not changed yet.

The cases:
- `theme`: in cmux-next.json, `appearance.themeFile` changes.
- `sidebar`: in cmux-next.json, `sidebar.density` changes.
- `extension`: the customize folder's `main.js` is saved with a new section headline.

Results from fleet step c75cc10eacf394cd18e28d34: 9536f6f0436, bench build, aws-m4pro-7, 10 rounds per case.
Times are ms from the end of the write.

| Case | Upper bound, median | Upper bound, max | Last unchanged capture sent | Captures |
| --- | --- | --- | --- | --- |
| theme (`appearance.themeFile`) | 205 ms | 231 ms | 0 ms | 17.6 ms median |
| sidebar (`sidebar.density`) | 72 ms | 77 ms | 0 ms | 17.9 ms median |
| extension (customize `main.js`) | not seen | not seen | n/a | 17.4 ms median |

How to read the theme and sidebar rows:
- In every round, the first capture after the write still showed the old look. The second capture showed the new one.
- The ordinary capture takes 17 ms, but that first one took about 190 ms (theme) or 55 ms (sidebar) to reply, because
  it waited for the main actor while the app applied the change.
- So the repaint falls somewhere between the write and the upper bound. The main thread is busy for most of that
  window: about 190 ms for a theme switch and about 55 ms for a density change.

The extension case recorded no change in the window, in all 10 rounds, within 3 s of each save. The capture taken 3 s
after each save matched the one before it, so this is not a reload slower than 3 s: either the section never showed
in the sidebar, or the save did not reach it. The step keeps only the JSON, not the captures. The next run should keep
the last capture of each extension round and read `cmux apps list` to tell those two apart.
