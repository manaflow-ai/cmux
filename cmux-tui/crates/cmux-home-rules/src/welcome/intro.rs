//! Which intro an empty Chief conversation shows (`ChiefIntroStore`, `ChiefIntroKind`) and whether the
//! first-run Switching card shows (`HomeSwitchKeysSource`). Swift reads and writes the defaults.

use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeSet;

pub const SHOWN_KEY: &str = "home.firstRun.chiefIntroShown";
pub const ASKED_KEY: &str = "home.firstRun.chiefIntroAsked";
pub const SWITCH_KEYS_HIDDEN_KEY: &str = "home.firstRun.switchKeysHidden";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum IntroKind {
    Welcome,
    AskFocus,
}

/// The two defaults the intro reads.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IntroState {
    pub shown: bool,
    pub asked: Vec<String>,
}

/// `ChiefIntroStore.intro(for:otherChiefs:)`.
pub fn intro(state: &IntroState, conversation: &str, other_chiefs: i64) -> Option<IntroKind> {
    if other_chiefs == 0 {
        return (!state.shown).then_some(IntroKind::Welcome);
    }
    (!state.asked.iter().any(|c| c == conversation)).then_some(IntroKind::AskFocus)
}

/// `ChiefIntroStore.markShown(_:for:)`: the new state (asked stays sorted and unique).
pub fn mark_shown(state: &IntroState, kind: IntroKind, conversation: &str) -> IntroState {
    match kind {
        IntroKind::Welcome => IntroState { shown: true, asked: state.asked.clone() },
        IntroKind::AskFocus => {
            let mut set: BTreeSet<String> = state.asked.iter().cloned().collect();
            set.insert(conversation.to_string());
            IntroState { shown: state.shown, asked: set.into_iter().collect() }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IntroRequest {
    #[serde(default)]
    state: IntroState,
    conversation: String,
    #[serde(default)]
    other_chiefs: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarkRequest {
    #[serde(default)]
    state: IntroState,
    kind: IntroKind,
    conversation: String,
}

/// `HomeSwitchKeysSource.keys(registry:)`'s rule: hidden shows nothing; the desktop conflict counts only
/// when the tab-by-number shortcut has modifiers to compare.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwitchKeysRequest {
    #[serde(default)]
    hidden: bool,
    #[serde(default)]
    has_tab_by_number_modifiers: bool,
    #[serde(default)]
    mission_control_conflicts: bool,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "intro" => {
            let req: IntroRequest = parse(request)?;
            reply(&json!({
                "kind": intro(&req.state, &req.conversation, req.other_chiefs),
                "welcomePending": !req.state.shown,
            }))
        }
        "markShown" => {
            let req: MarkRequest = parse(request)?;
            let next = mark_shown(&req.state, req.kind, &req.conversation);
            let write = match req.kind {
                IntroKind::Welcome => json!({"key": SHOWN_KEY, "value": true}),
                IntroKind::AskFocus => json!({"key": ASKED_KEY, "value": next.asked}),
            };
            reply(&json!({"state": next, "write": write}))
        }
        "switchKeys" => {
            let req: SwitchKeysRequest = parse(request)?;
            reply(&json!({
                "shows": !req.hidden,
                "desktopConflict": !req.hidden && req.has_tab_by_number_modifiers && req.mission_control_conflicts,
                "hiddenKey": SWITCH_KEYS_HIDDEN_KEY,
            }))
        }
        _ => Err(OpError::Unknown),
    }
}
