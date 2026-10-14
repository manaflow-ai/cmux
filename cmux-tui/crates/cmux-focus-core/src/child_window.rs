//! What a cmux window does when a window other than itself becomes key, and
//! whether it takes the keys back from a key Chromium page window. Pure, so
//! the input model runs the same rule as the app's applier.

use serde::{Deserialize, Serialize};

/// The key window's relation to this cmux window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Parent {
    ThisWindow {},
    /// No parent window: a page window Chromium showed or activated before
    /// (or while) the fork placed it as a child.
    None {},
    Other {},
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Facts {
    pub parent: Parent,
    pub is_panel: bool,
    /// A Chromium page window (or docked DevTools).
    pub is_chromium_page: bool,
    /// The window is a docked DevTools of a pane of this window.
    pub is_dev_tools: bool,
    /// A mouse press made it key.
    pub clicked: bool,
    /// Its frame is over a pane that shows a Chromium page.
    pub over_pane: bool,
    /// This cmux window is the active one (the last one the user used).
    pub this_window_is_active: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    /// Not this window's business.
    Ignore {},
    /// A click into docked DevTools: the tools have the keyboard.
    DevTools {},
    /// A page window took the keys without the user choosing it: the model
    /// re-applies its target.
    UnchosenPage {},
    /// A click into a placed page chose it.
    ChosenPage {},
    /// Another owned window over a pane became key without a click.
    Reapply {},
}

pub fn decide(facts: &Facts) -> Decision {
    if !is_ours(facts) {
        return Decision::Ignore {};
    }
    if facts.is_dev_tools {
        return Decision::DevTools {};
    }
    if facts.is_chromium_page && (!facts.clicked || !facts.over_pane) {
        return Decision::UnchosenPage {};
    }
    if !facts.over_pane {
        return Decision::Ignore {};
    }
    if facts.clicked { Decision::ChosenPage {} } else { Decision::Reapply {} }
}

/// Whether this window takes the keys back from the key window `facts`
/// describes, when its target is not a page.
pub fn should_reclaim(facts: &Facts) -> bool {
    is_ours(facts)
}

/// A child of this window, or a parentless Chromium page window while this
/// window is the active one (input-spec.md B13). Only the active window
/// answers for it, so two windows never both take the keys back.
fn is_ours(facts: &Facts) -> bool {
    if facts.is_panel {
        return false;
    }
    match facts.parent {
        Parent::ThisWindow {} => true,
        Parent::None {} => facts.is_chromium_page && facts.this_window_is_active,
        Parent::Other {} => false,
    }
}
