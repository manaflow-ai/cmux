//! The frames that grant something and so need a fresh user gesture
//! (CmuxNextAgentPane AcpmuxPaneMethods.swift `gestureRules`, `needsGesture`)
//! and the permission options that tell a deny from an allow
//! (AgentPaneUserGestures.swift `AcpmuxPermissionOptions`), and which pending
//! permissions are questions (a stricter crate rule: only a question's
//! `_acpmux/permission_respond` may carry `answers`, see
//! [`crate::params::answers_refusal`]).

use crate::data::{GestureRule, policy};
use crate::frame::contains;
use serde_json::{Map, Value};
use std::collections::HashMap;
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
/// An option seen with two kinds counts as allow. A permission is a question
/// when its request's `toolCall._meta.acpmux.question` is an object (the
/// acpmux hub sets it on every AskUserQuestion-style request,
/// plans/cmux-next/agent-questions.md section 3); a permission seen once
/// without it is not a question.
#[derive(Default)]
pub struct PermissionOptions {
    denies: Mutex<HashMap<String, HashMap<String, bool>>>,
    questions: Mutex<HashMap<String, bool>>,
}

type Found = (Vec<(String, String, bool)>, Vec<(String, bool)>);

impl PermissionOptions {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records the options in a parsed daemon frame; `reply_to` is the
    /// request a reply answers.
    pub fn observe(&self, object: &Map<String, Value>, reply_to: Option<&str>) {
        let mut found: Found = (Vec::new(), Vec::new());
        fn request(record: Option<&Map<String, Value>>, found: &mut Found) {
            let Some(record) = record else { return };
            let Some(permission) = record.get("permissionId").and_then(Value::as_str) else {
                return;
            };
            let request = record.get("request").and_then(Value::as_object);
            let question = request
                .and_then(|r| r.get("toolCall"))
                .and_then(|t| t.get("_meta"))
                .and_then(|m| m.get("acpmux"))
                .and_then(|a| a.get("question"))
                .is_some_and(Value::is_object);
            found.1.push((permission.to_owned(), question));
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
                found.0.push((permission.to_owned(), id.to_owned(), kind.starts_with("reject")));
            }
        }
        fn event(value: Option<&Value>, found: &mut Found) {
            let Some(event) = value.and_then(Value::as_object) else { return };
            if event.get("kind").and_then(Value::as_str) != Some("permission_request")
                || event.get("dir").and_then(Value::as_str) != Some("mux")
            {
                return;
            }
            request(event.get("msg").and_then(Value::as_object), found);
        }
        match object.get("method").and_then(Value::as_str) {
            Some("_acpmux/permission_pending") => {
                request(object.get("params").and_then(Value::as_object), &mut found);
            }
            Some("_acpmux/event") => event(object.get("params"), &mut found),
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
                    event(Some(e), &mut found);
                }
            }
            Some(_) => return,
        }
        let (options_found, questions_found) = found;
        if !questions_found.is_empty() {
            let mut questions =
                self.questions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for (permission, question) in questions_found {
                let before = questions.get(&permission).copied().unwrap_or(true);
                questions.insert(permission, before && question);
            }
        }
        if options_found.is_empty() {
            return;
        }
        let mut denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for (permission, option, deny) in options_found {
            let options = denies.entry(permission).or_default();
            let before = options.get(&option).copied().unwrap_or(true);
            options.insert(option, before && deny);
        }
    }

    /// True only when every request seen for `permission` was a question; an
    /// unseen permission is not one.
    pub fn is_question(&self, permission: &str) -> bool {
        let questions = self.questions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        questions.get(permission).copied() == Some(true)
    }

    /// True only when `option` is a known deny of `permission`.
    pub fn is_deny(&self, permission: &str, option: &str) -> bool {
        let denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        denies.get(permission).and_then(|o| o.get(option)).copied() == Some(true)
    }
}
