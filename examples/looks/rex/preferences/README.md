# Rex preferences

Get desktop banners while cmux is in the background, see agent activity on tabs, and use larger sidebar rows with 13-point terminal text. The pack follows the controls described in the [Rex Mac Settings reference](https://www.superlogical.com/rex/docs/reference/mac-settings). That reference gives no factory values for these controls. The table distinguishes this preset from cmux’s own defaults.

## Preview and install

From the repository root, preview the six settings on your current setup:

```sh
cmux customize use examples/looks/rex/preferences/profile.json
cmux customize check
```

Run `cmux customize discard` to restore your previous values, or `cmux customize apply` to keep the preview. To try a different text size, edit a copy of the preview profile before loading it.

Once the branch includes the pack, install it as a removable setup layer.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/preferences@feat-cmux-next
```

Remove that layer with `cmux setup remove manaflow-ai/rex-preferences`.

## What the pack sets

| cmux preference | cmux default | Pack value | Effect on Mac |
| --- | --- | --- | --- |
| `notifications.desktop` | `unlessFocused` | `whenInactive` | An eligible event produces a banner only if cmux is inactive when the event arrives. The default also allows a banner for an unviewed pane while cmux is active. This policy covers all eligible notification sources. Quiet hours, muted workspaces and macOS notification permission still apply. |
| `notifications.dockBadge` | `true` | `true` | The Dock icon counts unread tabs, manually marked workspaces with no unread tabs, and unread Home conversations, accounting for conversations already counted on tabs. Rex counts unseen blocked, failed or finished program tabs. |
| `appearance.statusIndicator.showAgentWorkingOnTabs` | `true` | `true` | A tab can show an agent’s working indicator in its icon slot while the agent reports activity. |
| `notifications.attention.showOnTab` | `true` | `true` | An unread tab can show its attention mark. Its shape follows the current cmux attention style. Rex separately configures Working, Blocked, Error and Done. |
| `sidebar.textSize` | `default` | `large` | Adds one point to sidebar list text and three points to row heights. Rex offers session and tab title sizing with vertical tabs. This cmux setting also sizes icons and headers and works with the current tab orientation. |
| `terminal.fontSize` | Unset, inherits terminal config | `13` | Sets the base terminal size in points while preserving the selected family and fallback fonts. The size is a preset choice. |

Compare the source controls for [program activity](https://www.superlogical.com/rex/docs/reference/mac-settings#setting-program-activity-show-activity-in-tabs), [window sidebar sizing](https://www.superlogical.com/rex/docs/reference/mac-settings#setting-window-sidebar-text-size) and [terminal typography](https://www.superlogical.com/rex/docs/reference/mac-settings#setting-typography-font-size). The cmux defaults and permitted values come from its [settings schema](../../../../schemas/settings/settings-schema.json).

## Selection and other differences

- **Copy on selection.** On this cmux NEXT revision, Ghostty owns mouse-selection copying. Its `copy-on-select = clipboard` option sends selected text to the system clipboard. Setup layers cannot manage the external Ghostty config, so installing this pack preserves your clipboard behavior. The NEXT schema has no setting for Rex’s copy animation or rounded selection corners. [Rex selection controls](https://www.superlogical.com/rex/docs/reference/mac-settings#setting-selection-copy-on-selection) · [cmux terminal pasteboards](../../../../Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalPasteboard.swift)
- **Selection colors.** Rex offers separate foreground and background colors. The [appearance pack](../appearance/) carries the measured palette pairs. cmux’s `appearance.highlightColor` would also recolor selected text in editors, the omnibar and other surfaces. [cmux highlight scope](../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettings/HighlightColorSetting.swift)
- **Typeface and shortcuts.** Choose an installed monospaced family with `terminal.fontFamily`. Leaving it unset inherits the terminal configuration. Advanced font features such as ligatures and line spacing belong to Ghostty. Focused zoom, copy and selection keys are in the [terminal pack](../terminal/). [cmux font overrides](../../../../Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/GhosttyRuntime+Font.swift)
- **Notifications and window behavior.** Rex offers in-window banner placement, per-state sounds and indicators, a sidebar swipe gesture and a fixed-width resize option. The pack leaves those choices alone. The desktop policy controls eligible macOS banners, independently of sound and working indicators. [cmux notification policy](../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettings/NotificationPolicy.swift) · [cmux Dock count](../../../../Packages/macOS/CmuxNext/Sources/CmuxNextApp/Notifications/NotificationCenterService+Lookup.swift)

![Source window with a three-pane layout](../new-tab/screenshots/source-window.webp)
