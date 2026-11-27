//! The binding rules (plans/cmux-next/focus.md section 5; the app's
//! `KeyRouter.allows` and its Ghostty rule), read against the key's own
//! target: the tab the focus is on its way to, else the focused target. The
//! rules and the key's sink so read one state (PR #34052 review, finding 8).

use super::key::{Binding, Tier};
use super::sink::{FieldKind, Sink};
use crate::state::Resolved;
use crate::topology::Kind;

/// The actions DevTools runs itself before its frontend sees the key; they run
/// from a page, its address bar, its find bar and DevTools (the app's
/// `KeyRouter.devToolsActions`). A page is never offered one.
pub(super) const DEV_TOOLS_ACTIONS: [&str; 3] =
    ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement"];

/// Page actions a browser's own chrome runs from its address bar and find bar
/// (R88; the app's `KeyRouter.browserChromeActions`).
const BROWSER_CHROME_ACTIONS: [&str; 7] = [
    "browserBack",
    "browserForward",
    "browserReload",
    "browserHardReload",
    "browserShowHistory",
    "browser.copyURL",
    "browser.findPrevious",
];

/// The system actions browser focus mode keeps from the page (the app's
/// `KeyRouter.focusModeKeptActions`).
const FOCUS_MODE_KEPT_ACTIONS: [&str; 2] = ["toggleBrowserFocusMode", "quit"];

/// A key's target as the binding rules read it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Class {
    /// A terminal.
    terminal: bool,
    /// A text field: editing chords belong to it.
    text_input: bool,
    /// A browser's developer tools.
    dev_tools: bool,
    /// A browser page, its address bar, its find bar or its developer tools.
    browser: bool,
    /// A browser's address bar or find bar.
    chrome_field: bool,
}

impl Class {
    /// The focused target's class.
    pub(super) fn of(resolved: &Resolved) -> Class {
        let chrome_field =
            matches!(resolved, Resolved::AddressBar { .. } | Resolved::FindBar { .. });
        let dev_tools = matches!(resolved, Resolved::DevTools { .. });
        Class {
            terminal: matches!(resolved, Resolved::Terminal { .. }),
            text_input: resolved.is_text_input(),
            dev_tools,
            browser: chrome_field || dev_tools || matches!(resolved, Resolved::BrowserPage { .. }),
            chrome_field,
        }
    }

    /// The class of `sink`, the target the focus is on its way to on a tab of
    /// `kind`.
    pub(super) fn expected(sink: &Sink, kind: Kind) -> Class {
        let chrome_field = matches!(
            sink,
            Sink::Field { field: FieldKind::AddressBar { .. } | FieldKind::FindBar { .. }, .. }
        );
        let dev_tools = matches!(sink, Sink::DevTools(_));
        let text_field = matches!(
            sink,
            Sink::Field { field: FieldKind::SidebarField | FieldKind::TextField, .. }
        );
        let page = matches!(sink, Sink::Content(_)) && kind == Kind::Browser;
        Class {
            terminal: matches!(sink, Sink::Terminal(_)),
            text_input: chrome_field || text_field,
            dev_tools,
            browser: chrome_field || dev_tools || page,
            chrome_field,
        }
    }
}

/// A Ghostty keybind goes to the terminal view, not to its action: a
/// terminal runs its own Ghostty keybinds (in copy mode the routed action
/// runs), and a Ghostty keybind never runs a content action from elsewhere.
pub(super) fn goes_to_view(binding: &Binding, class: Class, copy_mode: bool) -> bool {
    binding.ghostty && ((class.terminal && !copy_mode) || binding.tier == Tier::Content)
}

/// Whether `binding`'s action may take a key aimed at `class`, with browser
/// focus mode on or off (its tier rule).
pub(super) fn allows(binding: &Binding, class: Class, focus_mode: bool) -> bool {
    let action: &str = &binding.action;
    if focus_mode && binding.tier == Tier::System {
        return FOCUS_MODE_KEPT_ACTIONS.contains(&action);
    }
    if binding.tier == Tier::Content {
        if DEV_TOOLS_ACTIONS.contains(&action) && class.browser && !focus_mode {
            return true;
        }
        if BROWSER_CHROME_ACTIONS.contains(&action) && class.chrome_field {
            return true;
        }
    }
    match binding.tier {
        Tier::System => true,
        Tier::Navigation => !focus_mode,
        Tier::Content => !focus_mode && !class.text_input && !class.dev_tools,
    }
}
