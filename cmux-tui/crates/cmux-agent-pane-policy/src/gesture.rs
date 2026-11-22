//! The frames that grant something and so need a fresh user gesture
//! (CmuxNextAgentPane AcpmuxPaneMethods.swift `gestureRules`, `needsGesture`)
//! and the permission options that tell a deny from an allow
//! (AgentPaneUserGestures.swift `AcpmuxPermissionOptions`).

use crate::data::{GestureRule, policy};
use crate::frame::contains;
use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;

/// Whether `object` (a page frame the allowlist passed) grants and needs a
/// gesture. `is_deny(permission, option)` is true only for a known deny.
pub fn needs_gesture(object: &Map<String, Value>, is_deny: impl Fn(&str, &str) -> bool) -> bool {
    let p = policy();
    let Some(method) = object.get("method").and_then(Value::as_str) else { return false };
    let Some(rule) = p.gesture_rules.get(method) else { return false };
    let empty = Map::new();
    let params = object.get("params").and_then(Value::as_object).unwrap_or(&empty);
    let text = |k: &str| params.get(k).and_then(Value::as_str);
    match rule {
        GestureRule::Always => true,
        GestureRule::WhenTrusting => {
            !text("level").is_some_and(|l| contains(&p.non_trusting_levels, l))
        }
        GestureRule::WhenOptionAllows => match (text("permissionId"), text("optionId")) {
            (Some(permission), Some(option)) => !is_deny(permission, option),
            _ => true,
        },
        GestureRule::WhenDecisionAllows => text("decision") != Some("deny"),
    }
}

/// The permission options the daemon sent, read only from their fixed places
/// (never by walking the frame): `_acpmux/permission_pending` params, a
/// `permission_request` event the daemon recorded (`dir` "mux") in an
/// `_acpmux/event`, or in `result.events` of a reply to a history request.
/// An option seen with two kinds counts as allow.
///
/// A request whose `request.toolCall._meta.acpmux.question` (the daemon's
/// normalized question) is an object is a question; its items' ids and
/// prompts are the keys its `answers` may use ([`Self::question_keys`]). A
/// permission seen once without a question is no question.
#[derive(Default)]
pub struct PermissionOptions {
    denies: Mutex<HashMap<String, HashMap<String, bool>>>,
    /// permissionId -> the item ids and prompts of its question; None once a
    /// request without a question was seen for it.
    questions: Mutex<HashMap<String, Option<BTreeSet<String>>>>,
}

impl PermissionOptions {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records the options in a parsed daemon frame; `reply_to` is the
    /// request a reply answers.
    pub fn observe(&self, object: &Map<String, Value>, reply_to: Option<&str>) {
        type Asked = Vec<(String, Option<BTreeSet<String>>)>;
        let mut found: Vec<(String, String, bool)> = Vec::new();
        let mut asked: Asked = Vec::new();
        fn request(
            record: Option<&Map<String, Value>>,
            found: &mut Vec<(String, String, bool)>,
            asked: &mut Asked,
        ) {
            let Some(record) = record else { return };
            let Some(permission) = record.get("permissionId").and_then(Value::as_str) else {
                return;
            };
            let request = record.get("request").and_then(Value::as_object);
            asked.push((permission.to_owned(), request.and_then(question_keys)));
            let Some(options) = request.and_then(|r| r.get("options")).and_then(Value::as_array)
            else {
                return;
            };
            for option in options.iter().filter_map(Value::as_object) {
                let (Some(id), Some(kind)) = (
                    option.get("optionId").and_then(Value::as_str),
                    option.get("kind").and_then(Value::as_str),
                ) else {
                    continue;
                };
                found.push((permission.to_owned(), id.to_owned(), kind.starts_with("reject")));
            }
        }
        fn event(
            value: Option<&Value>,
            found: &mut Vec<(String, String, bool)>,
            asked: &mut Asked,
        ) {
            let Some(event) = value.and_then(Value::as_object) else { return };
            if event.get("kind").and_then(Value::as_str) != Some("permission_request")
                || event.get("dir").and_then(Value::as_str) != Some("mux")
            {
                return;
            }
            request(event.get("msg").and_then(Value::as_object), found, asked);
        }
        match object.get("method").and_then(Value::as_str) {
            Some("_acpmux/permission_pending") => {
                request(object.get("params").and_then(Value::as_object), &mut found, &mut asked);
            }
            Some("_acpmux/event") => event(object.get("params"), &mut found, &mut asked),
            None => {
                let Some(method) = reply_to else { return };
                if !contains(&policy().history_replies, method) {
                    return;
                }
                let Some(events) = object
                    .get("result")
                    .and_then(Value::as_object)
                    .and_then(|r| r.get("events"))
                    .and_then(Value::as_array)
                else {
                    return;
                };
                for e in events {
                    event(Some(e), &mut found, &mut asked);
                }
            }
            Some(_) => return,
        }
        if !asked.is_empty() {
            let mut questions =
                self.questions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for (permission, keys) in asked {
                let before = questions.get(&permission).cloned().unwrap_or(Some(BTreeSet::new()));
                let merged = before.and_then(|old| keys.map(|new| &old | &new));
                questions.insert(permission, merged);
            }
        }
        if found.is_empty() {
            return;
        }
        let mut denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for (permission, option, deny) in found {
            let options = denies.entry(permission).or_default();
            let before = options.get(&option).copied().unwrap_or(true);
            options.insert(option, before && deny);
        }
    }

    /// The keys `answers` may use for `permission`: its question's item ids
    /// and prompts; None when the pane never saw it as a question (a tool
    /// permission, or an unknown one).
    pub fn question_keys(&self, permission: &str) -> Option<BTreeSet<String>> {
        let questions = self.questions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        questions.get(permission).cloned().flatten()
    }

    /// True only when `option` is a known deny of `permission`.
    pub fn is_deny(&self, permission: &str, option: &str) -> bool {
        let denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        denies.get(permission).and_then(|o| o.get(option)).copied() == Some(true)
    }
}

/// The item ids and prompts of `request.toolCall._meta.acpmux.question`,
/// when it is an object.
fn question_keys(request: &Map<String, Value>) -> Option<BTreeSet<String>> {
    let question = request.get("toolCall")?.get("_meta")?.get("acpmux")?.get("question")?;
    let question = question.as_object()?;
    let mut keys = BTreeSet::new();
    for item in question.get("items").and_then(Value::as_array).into_iter().flatten() {
        for key in ["id", "prompt"] {
            if let Some(value) = item.get(key).and_then(Value::as_str) {
                keys.insert(value.to_owned());
            }
        }
    }
    Some(keys)
}
