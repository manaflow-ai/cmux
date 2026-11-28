//! `current` in an agent's tool call means the agent's own place: the
//! workspace, screen, pane and tab of its chat, not the one the person looks
//! at. The daemon reads `current` as its active object, which is neither the
//! chat's place nor always the workspace the app shows, so a script that
//! split `current` split some other workspace (Lawrence 2026-10-25). The
//! server asks the app where its caller is (`system.identify`, which
//! resolves the agent session on every call, so a chat that moved is
//! followed) and puts those ids in place of `current` before the request
//! leaves. `focused` is the object the person looks at, from the app's
//! focus (`snapshot.get`).

use serde_json::{Map, Value, json};

/// The selector levels, outermost first, with their public id prefix. The
/// app's `caller` and `focus` objects name each level with the same key.
const LEVELS: [(&str, &str); 4] =
    [("workspace", "ws_"), ("screen", "screen_"), ("pane", "pane_"), ("tab", "tab_")];

/// The selector word for the object the person looks at.
const FOCUSED: &str = "focused";
/// The selector word for the caller's own object, and the daemon's word
/// for its active one.
const CURRENT: &str = "current";

/// Whether `params` has a selector `word`, so its place must be found.
fn has(params: &Map<String, Value>, word: &str) -> bool {
    LEVELS.iter().any(|(field, _)| params.get(*field).and_then(Value::as_str) == Some(word))
}

/// Whether `params` has a `current` selector.
pub(super) fn wants_caller(params: &Map<String, Value>) -> bool {
    has(params, CURRENT)
}

/// Whether `params` has a `focused` selector.
pub(super) fn wants_focus(params: &Map<String, Value>) -> bool {
    has(params, FOCUSED)
}

/// Whether the app's `caller` names a workspace the caller is in.
pub(super) fn is_placed(caller: &Value) -> bool {
    caller.get("found").and_then(Value::as_bool) != Some(false)
        && caller.get("workspace").and_then(Value::as_str).is_some()
}

/// Rewrites the selectors of `params`, top down. `current` starts in the
/// caller's place and `focused` switches to the person's; each takes that
/// place's id at its level while every selector above it is in the same
/// place (or absent). Below an object of another place, or where the place
/// names no object at that level, the daemon's `current` is sent: the
/// active child of the object above. `caller` and `focus` are the app's
/// answers, `None` when unknown.
pub(super) fn apply(
    params: &mut Map<String, Value>,
    caller: Option<&Value>,
    focus: Option<&Value>,
) {
    let mut place = caller;
    for (field, prefix) in LEVELS {
        let Some(value) = params.get(field).and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        if value == FOCUSED {
            place = focus;
        } else if value != CURRENT {
            // The place's own object, by id or a unique prefix of it.
            let names = |own: &str| {
                own == value || (value.starts_with(prefix) && own.starts_with(value.as_str()))
            };
            place =
                place.filter(|place| place.get(field).and_then(Value::as_str).is_some_and(names));
            continue;
        }
        match place.and_then(|place| place.get(field)).and_then(Value::as_str) {
            Some(own) => {
                params.insert(field.into(), Value::String(own.to_owned()));
            }
            None => {
                params.insert(field.into(), Value::String(CURRENT.into()));
                place = None;
            }
        }
    }
}

/// The error for a caller identity the app cannot place: the server will
/// not guess the focused workspace in its stead.
pub(super) fn unresolved(detail: &str) -> Value {
    json!({
        "code": "caller.unresolved",
        "message": format!(
            "cmux cannot find where this chat is ({detail}), so `current` has no meaning; \
             name the object by id, or pass `focused` for the one the person looks at"
        ),
        "details": {},
        "retryable": true,
    })
}
