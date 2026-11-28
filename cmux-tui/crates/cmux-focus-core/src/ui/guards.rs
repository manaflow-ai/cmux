//! The keyboard guards' decisions over view and window facts the app reads
//! from AppKit (Swift `UnseenKeyboardGuard`, `ResponderMoveGate`,
//! `CrossWindowInputGuard`):
//!
//! - [`unseen_refuses`]: a programmatic first-responder move from a view the
//!   person sees to one they cannot see is refused.
//! - [`takes_from_typing`]: a system move off the view the person is typing
//!   into (typed within the grace) is refused.
//! - [`drops_key`]: a key typed into one cmux window that would reach
//!   another window's keyboard is dropped.

use serde::{Deserialize, Serialize};

/// How recent typing into a view keeps a system move off it (seconds).
pub const TYPING_GRACE_SECONDS: f64 = 1.0;

/// One view's facts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ViewFacts {
    /// `isHiddenOrHasHiddenAncestor`.
    pub hidden: bool,
    pub bounds_empty: bool,
    /// The view has a window.
    pub in_window: bool,
    /// The view has a window and that window has a content view.
    pub in_window_with_content: bool,
    /// The view's rect in the window meets the content view's.
    pub intersects_content: bool,
    pub visible_rect_empty: bool,
}

/// Whether the person can see the view.
pub fn shows(view: &ViewFacts) -> bool {
    if view.hidden {
        return false;
    }
    if view.bounds_empty || !view.in_window_with_content {
        return true;
    }
    view.intersects_content && !view.visible_rect_empty
}

/// A first-responder move's facts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ResponderMove {
    /// The new responder, when it is a view.
    pub target: Option<ViewFacts>,
    /// The window's current first responder, when it is a view.
    pub current: Option<ViewFacts>,
    pub current_is_target: bool,
    /// The current responder is in the target's window.
    pub current_in_target_window: bool,
    pub in_input_event: bool,
    pub focus_model_applies: bool,
    /// The move's route came from the system (not the person or the app).
    pub system_origin: bool,
    /// The new responder is the one the gate saw first.
    pub responder_is_before: bool,
    /// The responder the gate saw first is a typing target.
    pub before_is_typing_target: bool,
    /// The person typed into that responder within [`TYPING_GRACE_SECONDS`].
    pub typed_within_grace: bool,
}

pub fn unseen_refuses(facts: &ResponderMove) -> bool {
    if facts.in_input_event || facts.focus_model_applies {
        return false;
    }
    let Some(target) = facts.target.filter(|t| t.in_window) else { return false };
    let Some(current) = facts.current else { return false };
    if facts.current_is_target || !facts.current_in_target_window || !shows(&current) {
        return false;
    }
    !shows(&target)
}

pub fn takes_from_typing(facts: &ResponderMove) -> bool {
    facts.system_origin
        && !facts.in_input_event
        && !facts.focus_model_applies
        && !facts.responder_is_before
        && facts.before_is_typing_target
        && facts.typed_within_grace
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResponderMoveAnswer {
    pub unseen: bool,
    pub takes_from_typing: bool,
}

pub fn responder_move(facts: &ResponderMove) -> ResponderMoveAnswer {
    ResponderMoveAnswer {
        unseen: unseen_refuses(facts),
        takes_from_typing: takes_from_typing(facts),
    }
}

/// A key's windows: `source` and `target` are the cmux windows owning the
/// event's window and the key window.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KeyWindows {
    pub event_window: bool,
    pub key_window: bool,
    pub same_window: bool,
    pub source: Option<String>,
    pub target: Option<String>,
    /// For a held key's run: whether the run's key window is the key
    /// window now (`None`: no run).
    pub held_run_key_window_is_key: Option<bool>,
}

pub fn drops_key(facts: &KeyWindows) -> bool {
    if !facts.event_window || !facts.key_window || facts.same_window {
        return false;
    }
    let Some(source) = &facts.source else { return false };
    match &facts.target {
        None => facts.held_run_key_window_is_key.unwrap_or(false),
        Some(target) => target != source,
    }
}

#[cfg(test)]
#[path = "guards_tests.rs"]
mod tests;
