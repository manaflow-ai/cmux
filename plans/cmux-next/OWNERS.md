# cmux-next owners: who owns which area, and what to read first

Dozens of agents push straight to feat-cmux-next with no review. When two agents change one area
without talking, they undo each other (233 sidebar commits in four days; the indent changed four
times, [sidebar-owner.md](sidebar-owner.md)). Before you change an area below: read its doc, keep
its contract, and tell its owner what you changed (through the Performance Lead or Chief, or in
your report). The pre-push hook (`scripts/cmux-next/guardrails.py`) prints one warning line per
owned area a push touches. It never refuses.

Owners are agent names (a590), workstreams (PL-*, plans/cmux-next/perf-lead.md section 4) or
people. When a workstream ends, its row goes back to the Performance Lead. Change a row in the
same commit that changes ownership, and name who decided it.

| Area | Paths | Owner | Read first |
|---|---|---|---|
| Sidebar (rows, groups, rail, hover card, drag, density) | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/` | a590 (sidebar-owner agent) | [sidebar-owner.md](sidebar-owner.md) |
| acpmux agent-session daemon | `cmux-tui/crates/acpmux/` | session cmux-4f PL-acpmux (lead decision 2026-10-23) | [acpmux-audit.md](acpmux-audit.md) |
| Chromium hosting (page layer, host view, clip, shim) | `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFHostView*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFClipShape.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/` | PL-cef-layer (clip memo: Leo, c22a10712b6) | [browser.md](browser.md) |
| New Chromium tab path | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneBrowserTabOpener.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/TabContentCache*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSpareWindow.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPaneHost*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextChromiumWarmup/` | PL-cef-tab | [instant-new-surfaces.md](instant-new-surfaces.md) |
| Chromium side of motion (overlays, catchers, page tab) | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Windows/WindowOverlayLayer.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Overlay/WindowOverlayHost*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/DividerMouseCatchers.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFTab.swift` | PL-motion-cef | [perf-lead.md](perf-lead.md) |
| Layout motion (springs, panes, display link) | `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Motion*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Dock*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/LayoutRootView*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/PaneHostView.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/DisplayLinkDriver.swift` | PL-motion-core | [split-spring-animation/BASELINE.md](split-spring-animation/BASELINE.md) |
| Workspace, tab and space switch | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugTabSwitch.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugWorkspaceSwitch.swift` | PL-switch | [perf-lead.md](perf-lead.md) |
| Typing (key router, Home composer, typing probe) | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/KeyRouter*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeComposer.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/TypingLatencyProbe.swift` | PL-typing | [home-mac.md](home-mac.md) |
| Motion gate and animation switches | `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/`, `scripts/cmux-next/check-motion.sh` | Performance Lead | [motion-DESIGN.md](motion-DESIGN.md) |
| Wakeup primitives (FrameScheduler, DemandTimer, Backoff) | `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/` | Performance Lead | [idle-wakeups.md](idle-wakeups.md) |
| Perf gate and budgets (CI runs them; do not add rows) | `scripts/cmux-next/perf-gate.py`, `scripts/cmux-next/perf-budgets.json`, `scripts/cmux-next/perf-budgets-baseline/` | Aziz's agent and the Performance Lead | [perf-lead.md](perf-lead.md) |
| Guardrails, pre-push gate, codebase health | `scripts/cmux-next/guardrails.py`, `scripts/cmux-next/prepush-gate.py`, `scripts/cmux-next/perf-hot-benches.json`, `scripts/git-hooks/`, `plans/cmux-next/OWNERS.md` | Performance Lead (PL-guardrails) | [codebase-health.md](codebase-health.md) |
| Package layering, signpost catalog (CmuxNextSignposts names; app moves out of CmuxNextApp) | `Packages/macOS/CmuxNext/Sources/CmuxNextSignposts/`, `plans/cmux-next/architecture-layers.json`, `plans/cmux-next/architecture-refactor-DESIGN.md`, `scripts/cmux-next/arch-layers.py`, `scripts/cmux-next/perf-signposts.py` | PL-arch (Performance Lead, 2026-10-23); new signpost names: PL-arch + PL-telemetry | [architecture-refactor-DESIGN.md](architecture-refactor-DESIGN.md) |
| Ghostty-default keys | `schemas/keybindings/ghostty-reserved-keys.json` | Lawrence (explicit OK only, `Ghostty-defaults-OK:` trailer) | `CLAUDE.md` "cmux-next checks before every push" |

Not listed: no owner yet. Before a large change there, ask the Performance Lead to add a row.
