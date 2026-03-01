# Alternatives Evaluated

## Decision: Fork cmux (now "crux")

This document records the alternatives we evaluated and why cmux was chosen.

## Candidates Compared

| | cmux (chosen) | WezTerm | Zellij | Alacritty | Ghostty (direct) | Custom (egui) |
|---|---|---|---|---|---|---|
| Language | Swift + Zig | Rust | Rust | Rust | Zig + Swift | Rust |
| Build tool | Xcode | cargo | cargo | cargo | Xcode | cargo |
| License | AGPL-3.0 | MIT | MIT | Apache/MIT | MIT | MIT |
| Sidebar | Already built | Must build | Via plugin | None | None | Trivial |
| Notifications | Already built | Must build | None | None | None | Must build |
| Socket API | 60+ commands | 62 PDU types | Plugin API | Basic IPC | Limited | Must build |
| Headless exec | Process only | Mux server | Via plugin | None | None | Must build |
| Scripting | None | Lua 5.4 | WASM plugins | None | None | Must build |
| Browser/WebView | WKWebView (disableable) | None | None | None | None | None |
| Time to MVP | ~1.5 weeks | ~3 weeks | ~1-2 weeks | ~6-8 weeks | ~4-6 weeks | ~3-6 months |

## Why cmux Won

1. **Sidebar + notifications already exist** — the two hardest UI components are done
2. **Rich socket API** — 60+ commands, v1+v2 protocol, well-patterned for extension
3. **Session persistence** — JSON snapshots with scrollback replay already work
4. **Notification system** — blue rings, badges, Cmd+Shift+U jump — free integration
5. **Browser is disableable** — 4 guard points verified, not a permanent liability

## Why Not WezTerm (Runner-Up)

WezTerm was the strongest Rust alternative. Its mux server is architecturally ideal for headless execution. However:

1. **No widget toolkit** — sidebar UI must be rendered with custom GPU quads (wgpu). No SwiftUI/AppKit layout system. This is the hardest single task.
2. **410k LOC** — large codebase to onboard to, even though modular (19 crates)
3. **Solo maintainer** — @wez's development has slowed since 2024
4. **~3 weeks to MVP** vs ~1.5 weeks for cmux

If Xcode were a hard blocker, WezTerm would be the pick. Since Xcode is acceptable, cmux's existing UI infrastructure saves significant time.

## Why Not Others

- **Zellij**: Multiplexer, not emulator. Runs inside another terminal. Plugin API is excellent but you don't control the outer experience.
- **Alacritty**: One terminal per window, no tabs/splits, custom OpenGL renderer with no widget toolkit. Its value is `alacritty_terminal` as a library crate, not as a fork base.
- **Ghostty direct**: 29k lines of Swift but no sidebar, no notifications, no socket API, no session persistence. You'd rebuild everything cmux already has.
- **Custom egui build**: `egui_term` is "under development" — missing basic features. 3-6 month yak-shave before you can start on the scheduler.
- **Kitty**: GPLv3, mixed C/Python/Go, solo maintainer resistant to architectural changes.
- **Rio**: No IPC, no scripting, no plugin system, no headless mode.

## Key Trade-Offs Accepted

1. **Xcode dependency** — required, no way around it. Acceptable for a macOS-only app.
2. **AGPL license** — must release source for any distributed version. Fine for personal/open-source use.
3. **Ghostty submodule** — must track manaflow-ai/ghostty fork. Minimal fork (2 changes), low maintenance.
4. **Large monolithic files** — ContentView.swift (9k), TerminalController.swift (3.5k). Merge conflicts likely if tracking upstream. Mitigated by surgical changes and extension files.
