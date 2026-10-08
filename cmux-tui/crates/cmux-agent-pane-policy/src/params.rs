//! The params rule (P1), the prompt `_meta` strip, the gesture ticket and the
//! session scope (CmuxNextAgentPane AcpmuxPaneMethods.swift
//! `breaksParamsRule`, `strippingPromptMeta`, `takeGestureTicket`,
//! `requestedSetting`; AgentPaneTransport+Check.swift `sessionRefusal`).

use crate::data::policy;
use crate::error::Refusal;
use crate::frame::{Refused, contains, raw_id};
use serde_json::{Map, Value};
use std::collections::BTreeSet;

/// P1: whether a page frame breaks the params rule. On every method: a
/// top-level param outside the method's known params; a `_meta` that is not
/// an object, or that holds a key other than `acpmux`; an `acpmux` key outside
/// the method's list. On every method except set_mode and set_config_option,
/// also a daemon `modeFields` name at the top of params or in `acpmux`. A
/// set_mode or set_config_option with the gesture ticket in `_meta` redeems
/// it: its `_meta` may hold nothing else (R1).
pub fn breaks_params_rule(
    object: &Map<String, Value>,
    mode_fields: Option<&BTreeSet<String>>,
) -> bool {
    let p = policy();
    let (Some(method), Some(raw_params)) =
        (object.get("method").and_then(Value::as_str), object.get("params"))
    else {
        return false;
    };
    let Some(params) = raw_params.as_object() else { return true };
    let Some(known) = p.known_params.get(method) else { return !params.is_empty() };
    if params.keys().any(|k| !contains(&known.params, k)) {
        return true;
    }
    let setting = contains(&p.setting_methods, method);
    let empty = BTreeSet::new();
    let denied = if setting { &empty } else { mode_fields.unwrap_or(&empty) };
    if params.keys().any(|k| contains(denied, k)) {
        return true;
    }
    let Some(raw_meta) = params.get("_meta") else { return false };
    let Some(meta) = raw_meta.as_object() else { return true };
    if setting && meta.contains_key(&p.gesture_ticket_key) {
        return meta.keys().any(|k| *k != p.gesture_ticket_key);
    }
    // A prompt held for the folder trust answer redeems its ticket beside its
    // acpmux.promptId (AcpmuxPaneMethods.swift `breaksParamsRule`).
    let prompt = method == "session/prompt";
    if meta.keys().any(|k| k != "acpmux" && !(prompt && *k == p.gesture_ticket_key)) {
        return true;
    }
    let Some(raw_acpmux) = meta.get("acpmux") else { return false };
    let Some(acpmux) = raw_acpmux.as_object() else { return true };
    acpmux.keys().any(|k| !contains(&known.acpmux, k) || contains(denied, k))
}

/// A session/prompt with every `_meta` inside its prompt blocks removed, at
/// any depth; None when there is none (the frame goes unchanged). The
/// request's own `params._meta` stays.
pub fn stripping_prompt_meta(object: &Map<String, Value>) -> Option<Map<String, Value>> {
    if object.get("method").and_then(Value::as_str) != Some("session/prompt") {
        return None;
    }
    let params = object.get("params")?.as_object()?;
    let prompt = params.get("prompt")?.as_array()?;
    fn strip(value: &Value, stripped: &mut bool) -> Value {
        match value {
            Value::Object(o) => {
                let mut o = o.clone();
                if o.remove("_meta").is_some() {
                    *stripped = true;
                }
                for child in o.values_mut() {
                    if child.is_object() || child.is_array() {
                        *child = strip(child, stripped);
                    }
                }
                Value::Object(o)
            }
            Value::Array(a) => Value::Array(a.iter().map(|v| strip(v, stripped)).collect()),
            other => other.clone(),
        }
    }
    let mut stripped = false;
    let blocks: Vec<Value> = prompt.iter().map(|b| strip(b, &mut stripped)).collect();
    if !stripped {
        return None;
    }
    let mut params = params.clone();
    params.insert("prompt".into(), Value::Array(blocks));
    let mut object = object.clone();
    object.insert("params".into(), Value::Object(params));
    Some(object)
}

/// A frame's gesture ticket taken out of `params._meta`.
#[derive(Clone, Debug, PartialEq)]
pub struct TakenTicket {
    /// The frame without the ticket (the daemon never sees it).
    pub object: Map<String, Value>,
    /// The ticket; an empty string when the key held no string; None when
    /// the frame carried no ticket.
    pub ticket: Option<String>,
    /// Whether `_meta` held anything besides the ticket (R1).
    pub other_meta: bool,
}

pub fn take_gesture_ticket(object: &Map<String, Value>) -> TakenTicket {
    let key = &policy().gesture_ticket_key;
    let none = || TakenTicket { object: object.clone(), ticket: None, other_meta: false };
    let Some(params) = object.get("params").and_then(Value::as_object) else { return none() };
    let Some(meta) = params.get("_meta").and_then(Value::as_object) else { return none() };
    let Some(value) = meta.get(key) else { return none() };
    let mut meta = meta.clone();
    meta.remove(key);
    // A prompt's acpmux (its promptId, which a held prompt's ticket is bound
    // to) is not other meta (AcpmuxPaneMethods+GestureTicket.swift).
    let prompt = object.get("method").and_then(Value::as_str) == Some("session/prompt");
    let other_meta = meta.keys().any(|k| !(prompt && k == "acpmux"));
    let mut params = params.clone();
    if meta.is_empty() {
        params.remove("_meta");
    } else {
        params.insert("_meta".into(), Value::Object(meta));
    }
    let mut object = object.clone();
    object.insert("params".into(), Value::Object(params));
    TakenTicket { object, ticket: Some(value.as_str().unwrap_or_default().to_owned()), other_meta }
}

/// What a session/set_mode or session/set_config_option asks for: set_mode is
/// the `mode` option. `value` is None when it is not a string.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestedSetting {
    pub session_id: Option<String>,
    pub config_id: String,
    pub value: Option<String>,
}

pub fn requested_setting(object: &Map<String, Value>) -> Option<RequestedSetting> {
    let params = object.get("params")?.as_object()?;
    let text = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
    match object.get("method").and_then(Value::as_str) {
        Some("session/set_mode") => Some(RequestedSetting {
            session_id: text("sessionId"),
            config_id: "mode".into(),
            value: text("modeId"),
        }),
        Some("session/set_config_option") => Some(RequestedSetting {
            session_id: text("sessionId"),
            config_id: text("configId").unwrap_or_default(),
            value: text("value"),
        }),
        _ => None,
    }
}

/// The refusal of a session-scoped frame for a session that is not the
/// pane's (`holds` answers whether the pane started or shows a session).
pub fn session_refusal(
    object: &Map<String, Value>,
    holds: impl Fn(&str) -> bool,
) -> Option<Refused> {
    let p = policy();
    let method = object.get("method").and_then(Value::as_str)?;
    let named = object.get("params").and_then(Value::as_object).and_then(|p| p.get("sessionId"));
    let optional = contains(&p.optionally_session_scoped, method);
    // A frame that may name a session and names none is not session-scoped
    // (a JSON null names one that is not a string: refused).
    if optional && named.is_none() {
        return None;
    }
    if !optional && !contains(&p.session_scoped, method) {
        return None;
    }
    let session = named.and_then(Value::as_str);
    match session {
        Some(s) if holds(s) => None,
        _ => Some(Refused {
            refusal: Refusal::SessionNotInPane,
            method: Some(method.to_owned()),
            request_id: object.get("id").and_then(raw_id),
        }),
    }
}

/// The question answers rule shared with the Swift host (`policy.json`
/// `question_answers`): a frame of that method that
/// carries the answers param breaks it unless its `permissionId` is a pending
/// question (`is_question`, the host's [`crate::gesture::PermissionOptions`])
/// and the answers are an object of 1 to `maximum_items` item ids, each id and
/// each value at most `maximum_value_bytes` UTF-8 bytes, each value a string
/// or a list of strings (a list's strings counted together). Swift also accepts
/// Codex's `{answers: [string]}` wrapper; that remains the documented gap.
pub fn breaks_answers_rule(
    object: &Map<String, Value>,
    is_question: impl Fn(&str) -> bool,
) -> bool {
    let rule = &policy().question_answers;
    if object.get("method").and_then(Value::as_str) != Some(rule.method.as_str()) {
        return false;
    }
    let Some(params) = object.get("params").and_then(Value::as_object) else { return false };
    let Some(answers) = params.get(&rule.param) else { return false };
    if !params.get("permissionId").and_then(Value::as_str).is_some_and(is_question) {
        return true;
    }
    let Some(answers) = answers.as_object() else { return true };
    if answers.is_empty() || answers.len() > rule.maximum_items {
        return true;
    }
    let bytes = |value: &Value| -> Option<usize> {
        match value {
            Value::String(s) => Some(s.len()),
            Value::Array(items) => {
                items.iter().map(|i| i.as_str().map(str::len)).sum::<Option<usize>>()
            }
            _ => None,
        }
    };
    answers.iter().any(|(id, value)| {
        id.len() > rule.maximum_value_bytes
            || bytes(value).is_none_or(|n| n > rule.maximum_value_bytes)
    })
}
