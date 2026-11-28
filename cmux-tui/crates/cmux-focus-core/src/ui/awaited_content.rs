//! The focused content that a key typed now would miss (Swift
//! `AwaitedContent`, REOPEN-F4): the focus names it, but its pane does not
//! show it yet. The window's key hold waits for it.

use serde::{Deserialize, Serialize};

/// What the focus names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Terminal,
    /// A page: a browser tab's, an agent chat's or an internal page tab's.
    Browser,
}

/// The awaited content.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AwaitedContent {
    pub tab: String,
    pub kind: Kind,
}

impl AwaitedContent {
    /// Its held keys go to its terminal by a lane.
    pub fn has_terminal_lane(&self) -> bool {
        self.kind == Kind::Terminal
    }
}

/// The focused pane's controller now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pane {
    /// The tab its strip selects.
    pub selected_tab: Option<String>,
    /// The tab whose content it shows, and that content's kind.
    pub shown_tab: Option<String>,
    pub shown_kind: Option<Kind>,
    /// The selected tab is a terminal that will draw.
    pub selected_is_live_terminal: bool,
    /// The shown browser content's page is ready for keys.
    #[serde(default = "yes")]
    pub shown_page_ready: bool,
}

fn yes() -> bool {
    true
}

/// Whether a key typed now reaches the shown page: a browser tab's page, or
/// the page window of a cmux page or agent chat; neither: a native page.
pub fn page_ready(browser: Option<bool>, page_window: Option<bool>) -> bool {
    browser.or(page_window).unwrap_or(true)
}

/// What [`awaited`] reads: `awaited` (or `awaited_no_pane`) when the hold
/// waits for the content, else the first condition that fails.
pub fn reading(kind: Kind, tab: &str, pane: Option<&Pane>, pane_in_topology: bool) -> &'static str {
    let Some(pane) = pane else {
        return if pane_in_topology { "awaited_no_pane" } else { "pane_not_in_topology" };
    };
    if pane.shown_tab.as_deref() == Some(tab)
        && pane.shown_kind == Some(kind)
        && (kind != Kind::Browser || pane.shown_page_ready)
    {
        return "shown";
    }
    match pane.selected_tab.as_deref() {
        None => "none_selected",
        Some(selected) if selected != tab => "other_selected",
        Some(_) if kind == Kind::Browser || pane.selected_is_live_terminal => "awaited",
        Some(_) => "not_live_terminal",
    }
}

/// The content a key typed now would miss, or None.
pub fn awaited(
    kind: Kind,
    tab: &str,
    pane: Option<&Pane>,
    pane_in_topology: bool,
) -> Option<AwaitedContent> {
    reading(kind, tab, pane, pane_in_topology)
        .starts_with("awaited")
        .then(|| AwaitedContent { tab: tab.to_owned(), kind })
}

/// The app actions that need the focused page itself (its address bar).
pub const PAGE_ACTIONS: [&str; 3] =
    ["focusLocation", "focusBrowserAddressBar", "browser.focusSearch"];

/// Whether a page hold keeps a key: every key once one is held, a plain key
/// and a chord no app binding takes, and a page action (unless the page was
/// created and nothing is held).
pub fn page_hold_keeps(
    is_chord: bool,
    hold_is_empty: bool,
    command: Option<&str>,
    page_created: bool,
) -> bool {
    !hold_is_empty
        || !is_chord
        || command.is_none_or(|command| PAGE_ACTIONS.contains(&command) && !page_created)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane(selected: Option<&str>, shown: Option<&str>, kind: Option<Kind>, live: bool) -> Pane {
        Pane {
            selected_tab: selected.map(Into::into),
            shown_tab: shown.map(Into::into),
            shown_kind: kind,
            selected_is_live_terminal: live,
            shown_page_ready: true,
        }
    }

    fn content(tab: &str, kind: Kind) -> Option<AwaitedContent> {
        Some(AwaitedContent { tab: tab.into(), kind })
    }

    #[test]
    fn a_focused_terminal_is_awaited_until_its_surface_shows() {
        let t = Kind::Terminal;
        assert_eq!(
            awaited(t, "t", Some(&pane(Some("t"), None, None, true)), true),
            content("t", t)
        );
        assert_eq!(awaited(t, "t", Some(&pane(Some("t"), Some("t"), Some(t), true)), true), None);
        assert_eq!(awaited(t, "t", None, true), content("t", t));
        assert_eq!(awaited(t, "t", None, false), None);
    }

    #[test]
    fn a_dead_or_unselected_terminal_is_not_awaited() {
        let t = Kind::Terminal;
        assert_eq!(awaited(t, "t", Some(&pane(Some("t"), None, None, false)), true), None);
        assert_eq!(awaited(t, "t", Some(&pane(Some("other"), None, None, true)), true), None);
        assert_eq!(reading(t, "t", Some(&pane(None, None, None, true)), true), "none_selected");
    }

    #[test]
    fn a_restored_browser_tab_is_awaited_until_its_page_exists() {
        let b = Kind::Browser;
        assert_eq!(
            awaited(b, "b", Some(&pane(Some("b"), Some("b"), None, false)), true),
            content("b", b)
        );
        assert_eq!(awaited(b, "b", Some(&pane(Some("b"), Some("b"), Some(b), false)), true), None);
        assert_eq!(awaited(b, "b", Some(&pane(Some("other"), None, None, false)), true), None);
        assert!(!AwaitedContent { tab: "b".into(), kind: b }.has_terminal_lane());
        assert!(AwaitedContent { tab: "t".into(), kind: Kind::Terminal }.has_terminal_lane());
    }

    #[test]
    fn a_shown_browser_tab_is_awaited_until_its_page_is_ready() {
        let b = Kind::Browser;
        let mut shown = pane(Some("b"), Some("b"), Some(b), false);
        shown.shown_page_ready = false;
        assert_eq!(awaited(b, "b", Some(&shown), true), content("b", b));
        shown.shown_page_ready = true;
        assert_eq!(awaited(b, "b", Some(&shown), true), None);
        assert!(page_ready(None, None));
        assert!(!page_ready(Some(false), Some(true)));
        assert!(page_ready(None, Some(true)));
    }

    #[test]
    fn a_page_hold_lets_app_shortcuts_pass_while_empty_but_keeps_page_actions() {
        assert!(
            !page_hold_keeps(true, true, Some("nextTab"), false),
            "Ctrl-Tab waited for a cold tab's page"
        );
        assert!(page_hold_keeps(true, true, Some("focusLocation"), false));
        assert!(page_hold_keeps(true, true, None, false));
        assert!(page_hold_keeps(false, true, None, false));
        assert!(
            page_hold_keeps(true, false, Some("nextTab"), false),
            "a shortcut passed a held key"
        );
    }

    #[test]
    fn a_page_action_passes_an_empty_page_hold_once_the_page_exists() {
        assert!(!page_hold_keeps(true, true, Some("focusLocation"), true));
        assert!(page_hold_keeps(true, true, Some("focusLocation"), false));
        assert!(
            page_hold_keeps(true, false, Some("focusLocation"), true),
            "Cmd-L passed held keys"
        );
        assert!(page_hold_keeps(true, true, None, true));
        assert!(page_hold_keeps(false, true, None, true));
    }

    #[test]
    fn a_focused_agent_or_page_tab_is_awaited_as_a_page_until_it_shows() {
        let b = Kind::Browser;
        assert_eq!(
            awaited(b, "a", Some(&pane(Some("a"), None, None, false)), true),
            content("a", b)
        );
        assert_eq!(awaited(b, "a", Some(&pane(Some("a"), Some("a"), Some(b), false)), true), None);
    }
}
