# cmux-next and cmux-tui Linux checks audit

The Linux lanes own repository checks and cross-platform behavior. macOS stays
only where the compiler, SDK, or operating-system behavior is part of the
assertion.

| Area | Linux lane | macOS lane and reason |
| --- | --- | --- |
| cmux-next god-file, concurrency, crash-safety, localization, and module-resource checks | `cmux-next / checks` | None. These inspect source and catalogs. |
| cmux-next action-surface export and catalog compilation | `cmux-next / swift-test` runs the package-required generation | The package declares macOS 26 and the generated resource bundles use Xcode's `xcstringstool`; the package build and resource compile stay together on macOS. |
| cmux-next Swift package tests | None moved | `CmuxNext` declares macOS 26 and includes AppKit, WebKit, and other SDK targets. |
| cmux-next Release and app scheme compiles | None moved | Xcode 26, macOS SDK, AppKit/WebKit, and the CEF shim are required. |
| cmux-tui formatting, web frontend, bindings, inventory, generated SDK checks, and Valgrind | `lint`, `web-frontend`, `bindings-e2e`, `cmux-tui-spec`, and `valgrind-leak-check` | None. These are Linux-capable and remain off the minis. |
| cmux-tui Rust workspace clippy and platform tests | Linux runs the full workspace; macOS runs the reduced platform set | macOS keeps cfg-specific discovery, socket, process, PTY, launchd, and layout assertions. |
| Browser and web-pane smoke | `cdp-browser-smoke (linux)` | The same headless Chromium protocol tests are covered on Linux; the duplicate macOS matrix entry was removed. |

The macOS job no longer repeats `cargo fmt`; Linux `lint` remains its owner.
