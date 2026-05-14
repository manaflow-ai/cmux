# PRD: Keyboard Accessibility for Sidebar and Titlebar Controls

## Problem Statement

Users who rely on macOS keyboard-based accessibility tools (Full Keyboard Access, keyboard navigation, switch control, and similar assistive technologies) cannot reach several interactive controls in the cmux UI. Specifically, the toggle sidebar button, notifications button, new workspace button, and the Help (question mark) button in the sidebar footer do not appear as keyboard-focusable targets. These controls have VoiceOver-accessible labels and identifiers, but they lack the `.focusable()` modifier needed to create Tab stops for keyboard navigation. This makes the app partially unusable for anyone who cannot use a mouse or trackpad.

## Solution

Add `.focusable()` to the shared `TitlebarControlButton` component and the sidebar footer Help button, making all four controls reachable via Tab/Arrow key navigation under macOS Full Keyboard Access. Group the titlebar buttons into a single Tab stop using `.accessibilityElement(children: .contain)` on the parent container so Tab navigation remains efficient. Add `accessibilityHint` values to all affected controls so assistive technologies can announce what each button does.

## User Stories

1. As a keyboard-only user, I want to Tab to the toggle sidebar button, so that I can show or hide the sidebar without a mouse
2. As a keyboard-only user, I want to Tab to the notifications button, so that I can open the notifications panel without a mouse
3. As a keyboard-only user, I want to Tab to the new workspace button, so that I can create a new workspace without a mouse
4. As a keyboard-only user, I want to Tab to the Help button in the sidebar footer, so that I can open the help menu without a mouse
5. As a VoiceOver user, I want to hear a hint describing what each titlebar button does, so that I understand its purpose before activating it
6. As a Full Keyboard Access user, I want the three titlebar buttons grouped into one Tab stop, so that Tab navigation through the window is not tedious
7. As a Full Keyboard Access user, I want to use Arrow keys to move between titlebar buttons within the group, so that I can reach each button efficiently
8. As a keyboard-only user, I want to activate any of these buttons with Space or Enter, so that the interaction matches standard macOS button behavior
9. As a keyboard-only user in minimal mode, I want the same controls to be keyboard-accessible, so that the experience is consistent regardless of display mode
10. As a keyboard-only user in fullscreen, I want the fullscreen titlebar controls to be keyboard-accessible, so that I am not locked out of features in fullscreen
11. As a VoiceOver user, I want to hear the unread notification count when focusing the notifications button, so that I know if I have pending notifications before opening the panel
12. As a keyboard-only user, I want focus rings to render correctly around these buttons when focused, so that I have visual confirmation of which control is focused

## Implementation Decisions

- **Shared component approach**: The fix targets `TitlebarControlButton` (the shared SwiftUI component in `UpdateTitlebarAccessory.swift`) so that all three titlebar buttons (toggle sidebar, notifications, new workspace) get keyboard focusability in a single change. This covers standard mode, fullscreen, and custom titlebar surfaces.
- **Sidebar footer Help button**: Fixed separately since it uses `SidebarFooterIconButtonStyle`, not `TitlebarControlButton`. The fix is the same pattern: add `.focusable()` and `.accessibilityHint()`.
- **`.focusable()` is the key missing piece**: All four controls already have `accessibilityLabel`, `accessibilityIdentifier`, and `accessibilityElement(children: .ignore)`. They appear in VoiceOver's accessibility tree. The gap is `.focusable()`, which creates a Tab stop for Full Keyboard Access.
- **Group titlebar buttons with `.accessibilityElement(children: .contain)`**: The parent `HStack` in `TitlebarControlsView` should wrap its children so Full Keyboard Access treats the toolbar as one Tab stop. Arrow keys navigate within the group. This matches Apple HIG guidance for toolbar grouping.
- **Add `accessibilityHint` to all four controls**: Currently none of these buttons have hints. Adding descriptive hints (e.g., "Shows or hides the sidebar") helps keyboard and VoiceOver users understand button purpose.
- **Add `accessibilityValue` to notifications button**: The unread count badge is visual-only. Exposing it as `accessibilityValue` lets VoiceOver announce "3 unread notifications."
- **Minimal mode is already handled**: The AppKit-side `MinimalModeSidebarControlActionView` already has proper `setAccessibilityElement(true)`, `setAccessibilityRole(.button)`, and `accessibilityPerformPress()`. No changes needed for minimal mode.
- **No AppKit bridging needed**: The `NSTitlebarAccessoryViewController` context automatically bridges SwiftUI accessibility to AppKit. Adding `.focusable()` in SwiftUI is sufficient.

## Testing Decisions

- **Behavioral verification**: Good tests should verify that controls are keyboard-reachable and activatable, not check for the presence of specific SwiftUI modifiers in source text.
- **Manual verification with Accessibility Inspector**: Use Xcode's Accessibility Inspector to confirm each control appears in the accessibility tree with the correct role, label, hint, and focusable state.
- **Manual verification with Full Keyboard Access**: Enable Full Keyboard Access in System Settings > Keyboard and Tab through the window to confirm each control is reachable and activatable with Space/Enter.
- **Focus ring visual check**: Verify that focus rings render correctly in the `NSTitlebarAccessoryViewController` hosting context and in the sidebar footer context.
- **Minimal mode regression**: Confirm that minimal mode controls (AppKit-side) continue to work correctly after the changes, since they are on a separate code path.
- **Fullscreen regression**: Confirm fullscreen titlebar controls are keyboard-accessible after the changes.

## Out of Scope

- Adding keyboard shortcuts for these buttons (they may already have shortcuts via keyboard shortcut settings — that is a separate concern)
- Restructuring the accessibility hierarchy of workspace rows, terminal panels, or other UI areas
- Adding `.focusable()` to all interactive controls app-wide (this PRD targets only the four specific controls identified)
- Changes to the AppKit-side `MinimalModeSidebarControlActionView` (already keyboard-accessible)
- Changes to the sidebar resizer accessibility (separate gap, tracked separately)
- Adding `accessibilityValue` to the notifications button is included but is a stretch goal — may be deferred if the badge state is not easily accessible from the button context

## Further Notes

- The codebase already has a strong accessibility pattern. `TitlebarControlButton` uses `.accessibilityElement(children: .ignore)` + `.accessibilityLabel` + `.accessibilityIdentifier`. The `.focusable()` addition is a small, targeted fix that follows existing conventions.
- `.focusable()` is extremely rare in the current codebase (only 3 usages). This fix will set a precedent — future interactive controls should include `.focusable()` by default.
- All user-facing strings must be localized using `String(localized:defaultValue:)` and added to `Resources/Localizable.xcstrings` for English and Japanese.

## Files to Modify

| File | Change |
|---|---|
| `Sources/Update/UpdateTitlebarAccessory.swift` (line ~359-371) | Add `.focusable()` and `.accessibilityHint()` to `TitlebarControlButton` |
| `Sources/Update/UpdateTitlebarAccessory.swift` (line ~426+) | Add `.accessibilityElement(children: .contain)` to `TitlebarControlsView` parent HStack |
| `Sources/ContentView.swift` (line ~11354-11396) | Add `.focusable()` and `.accessibilityHint()` to sidebar footer Help button |
| `Resources/Localizable.xcstrings` | Add localized hint strings for all four controls |
