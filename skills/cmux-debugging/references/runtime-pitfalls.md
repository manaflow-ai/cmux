# Runtime Pitfalls

Why the rules in [../SKILL.md](../SKILL.md) exist, and what to check when one bites.

## Drag-and-drop UTTypes

Custom UTTypes are declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`, for example `com.cmux.sidebar-tab-reorder`. If drag/drop works in a narrow local test but fails across a process or extension boundary, check Info.plist before rewriting the drag model.

## Terminal rendering and typing latency

A second draw loop (a manual `ghostty_surface_draw` or an always-on display link) can make typing lag worse and hide the real invalidation source. cmux relies on Ghostty wakeups and renderer scheduling.

Code on the per-keystroke and per-event paths does no allocation-heavy formatting, file I/O, disk logging, hot-loop string interpolation, or layout work. Even "small" checks compound on typing paths.

## OS-version repros

Foundation, SwiftUI, AttributeGraph, and WebKit behavior changes silently between macOS majors. From https://github.com/manaflow-ai/cmux/issues/4529: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26, because Apple fixed CFURL normalization. The repo's `macos-26` CI and every maintainer's machine were on the fixed side; every reporter was on the broken side.

Test on the reporter's macOS before declaring a repro disproven. CI's `blacksmith-6vcpu-macos-15` pool runs macOS 15; the AWS M4 Pro Tart hosts were retired in #14427.
