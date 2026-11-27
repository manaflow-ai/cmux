//! Where each action's shortcut sits in the key routing order (plans/cmux-next/focus.md section
//! 5; the app's `ActionKeyTier`). Lower tiers run first: `system` always runs, `navigation` beats
//! terminal keybinds, page shortcuts and text fields, `content` runs only when its content has
//! the keyboard. A person's `cmux.json` `shortcuts.tiers` overrides these defaults.

use crate::model::Action;

/// Actions that must always work, even in a text field. In browser focus mode only the exit
/// chord and Quit keep their keys.
pub const SYSTEM_ACTIONS: &[&str] = &[
    "quit",
    "closeTab",
    "closeWorkspace",
    "closeWindow",
    "newWindow",
    "newIncognitoWindow",
    "commandPalette",
    "toggleBrowserFocusMode",
    "openSettings",
    "showHideAllWindows",
    "toggleFullScreen",
];

/// Navigation actions that need a content context to be available (Cmd-L needs a selected
/// browser tab) but still beat text fields.
pub const NAVIGATION_ACTIONS: &[&str] = &["focusBrowserAddressBar", "browser.focusSearch"];

/// Content actions that need no focus fact to be listed: the web inspector chords (Cmd-Opt-I,
/// Cmd-Opt-J, Cmd-Opt-C) act on any focused web view, and a text field keeps them.
pub const CONTENT_ACTIONS: &[&str] =
    &["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement"];

/// Context facts (`when` key names) that mean "this action acts on focused content".
pub const CONTENT_CONTEXTS: &[&str] = &[
    "terminalFocused",
    "browserFocused",
    "simulatorFocused",
    "diffViewerFocused",
    "filePreviewFocused",
    "codeEditorFocused",
    "markdownFocused",
    "rightSidebarFocused",
    "fileExplorerFocused",
    "textBoxFocused",
    "paletteOpen",
    "agentPaneFocused",
    "markdownReadOnlyFocused",
    "markdownEditorFocused",
    "webViewFocused",
];

/// The catalog default tier of `action`: `system`, `navigation` or `content`.
pub fn default_tier(action: &Action) -> &'static str {
    if SYSTEM_ACTIONS.contains(&action.id) {
        "system"
    } else if NAVIGATION_ACTIONS.contains(&action.id) {
        "navigation"
    } else if CONTENT_ACTIONS.contains(&action.id)
        || action.requires.iter().any(|r| CONTENT_CONTEXTS.contains(r))
    {
        "content"
    } else {
        "navigation"
    }
}
