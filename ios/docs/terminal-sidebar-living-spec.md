# iOS Sidebar Terminal Living Spec

Last updated: 2026-02-23
Owners: iOS app team

## Goal
Build a stack-auth-gated iOS main screen that mirrors the cmux desktop sidebar mental model:
- left list of workspaces/sessions (iMessage-like list affordance),
- right/detail pane showing the terminal for the selected session,
- terminals powered by libghostty.

Convex conversation/task flows stay in repo as legacy code paths and can be reactivated later.

## Non-Goals (current phase)
- Full parity with desktop tab/workspace protocol behavior.
- Replacing all legacy Convex view models.
- Advanced terminal actions (split tree management, command palette, etc.).

## Architecture (phase 1 toy)
1. Auth gate:
   - Keep existing Stack Auth sign-in flow as the only default entry into the app.
2. Main surface:
   - `TerminalSidebarRootView` is now the authenticated root.
   - Sidebar list contains `TerminalWorkspace` models and selection state.
3. Terminal runtime:
   - `GhosttyToyRuntime` wraps `ghostty_init`, `ghostty_app_new`, and wakeup->tick routing.
   - Clipboard and open-url are minimally wired for iOS.
4. Terminal view:
   - `GhosttyToySurfaceView` is a `UIView` with `CAMetalLayer` backing.
   - Surface creation uses `GHOSTTY_PLATFORM_IOS` with `uiview` handle and dynamic size sync.

## Milestones

### M1: Toy libghostty embed (implemented)
- [x] Link `../GhosttyKit.xcframework` into `ios/project.yml`.
- [x] Add iOS runtime wrapper (`GhosttyToyRuntime`).
- [x] Add iOS metal-backed surface view (`GhosttyToySurfaceView`).
- [x] Render terminal in detail pane of sidebar root view.

### M2: Sidebar UX hardening (next)
- [ ] Persist session ordering/selection across launches.
- [ ] Add unread/activity status model and pinning affordances.
- [ ] Improve compact-width behavior (iPhone) for quick switching.

### M3: Input and interaction parity (next)
- [ ] Add robust iOS text input pipeline for terminal typing/IME.
- [ ] Add per-session launch templates (cwd/command/provider).
- [ ] Add crash-safe recovery for failed terminal surface creation.

### M4: Desktop model convergence (future)
- [ ] Map sidebar sessions to real backend workspace/session identities.
- [ ] Reintroduce Convex-backed session metadata as opt-in non-legacy path.
- [ ] Share model contracts with desktop.

## Risks / Open Questions
- iOS process sandboxing can constrain shell/process behavior across device/simulator.
- Current toy action callback only handles URL opens; more runtime actions need handling.
- Keyboard and IME behavior need dedicated implementation for production readiness.

## Validation Checklist
- [x] `xcodegen generate` succeeds after adding GhosttyKit dependency.
- [ ] iPhone build/install run with sidebar + terminal visible.
- [ ] Terminal input works on software/hardware keyboard.
- [ ] Session switching preserves terminal surfaces without leaks.
