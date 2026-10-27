//! `current` in an agent's tool call means the agent's own place: the
//! workspace, screen, pane and tab of its chat, not the one the person looks
//! at. The daemon reads `current` as its active object, which is neither the
//! chat's place nor always the workspace the app shows, so a script that
//! split `current` split some other workspace (Lawrence 2026-10-25). The
//! server asks the app where its caller is (`system.identify`, which
//! resolves the agent session on every call, so a chat that moved is
//! followed) and puts those ids in place of `current` before the request
//! leaves. `focused` is the object the person looks at, from the app's
//! focus (`snapshot.get`). The CLI's `focused` uses the same rule
//! (resolve.rs `focused_scopes`).

#![cfg_attr(not(unix), allow(dead_code))]

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
pub(in crate::cli) fn wants_caller(params: &Map<String, Value>) -> bool {
    has(params, CURRENT)
}

/// Whether `params` has a `focused` selector.
pub(in crate::cli) fn wants_focus(params: &Map<String, Value>) -> bool {
    has(params, FOCUSED)
}

/// Whether the app's `caller` names a workspace the caller is in.
pub(in crate::cli) fn is_placed(caller: &Value) -> bool {
    caller.get("found").and_then(Value::as_bool) != Some(false)
        && caller.get("workspace").and_then(Value::as_str).is_some()
}

/// Rewrites the selectors of `params`, top down. `current` starts in the
/// caller's place and `focused` switches to the person's (while the
/// selectors above it are the person's objects too); each takes that
/// place's id at its level while every selector above it is in the same
/// place (or absent). Below an object of another place, or where the place
/// names no object at that level, the daemon's `current` is sent: the
/// active child of the object above. `caller` and `focus` are the app's
/// answers, `None` when unknown.
pub(in crate::cli) fn apply(
    params: &mut Map<String, Value>,
    caller: Option<&Value>,
    focus: Option<&Value>,
) {
    let mut place = caller;
    // The levels this call filled from the focus.
    let mut from_focus = [false; LEVELS.len()];
    for (index, (field, prefix)) in LEVELS.into_iter().enumerate() {
        let Some(value) = params.get(field).and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        if value == FOCUSED {
            // The person's place only below parents that are in it: a
            // focused pane is never sent under another workspace or screen.
            // A level the focus does not name (the app reports no screen)
            // passes only as a `focused` this call sent as `current`, under
            // the focused workspace.
            let parents_focused = |focus: &&Value| {
                let named = |level: usize| {
                    let (above, prefix) = LEVELS[level];
                    let parent = params.get(above).and_then(Value::as_str)?;
                    let own = focus.get(above).and_then(Value::as_str)?;
                    Some(names_object(parent, prefix, own))
                };
                (0..index).all(|level| {
                    let Some(parent) = params.get(LEVELS[level].0).and_then(Value::as_str) else {
                        return true;
                    };
                    named(level).unwrap_or_else(|| {
                        from_focus[level] && parent == CURRENT && named(0) == Some(true)
                    })
                })
            };
            place = focus.filter(parents_focused);
            from_focus[index] = true;
        } else if value != CURRENT {
            let names = |own: &str| names_object(&value, prefix, own);
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

/// Whether `selector` names the place's object `own`: its id or a unique
/// prefix of it.
fn names_object(selector: &str, prefix: &str, own: &str) -> bool {
    own == selector || (selector.starts_with(prefix) && own.starts_with(selector))
}

/// The error for a caller identity the app cannot place: the server will
/// not guess the focused workspace in its stead.
pub(in crate::cli) fn unresolved(detail: &str) -> Value {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focused_follows_the_focus_only_below_its_own_parents() {
        let caller = json!({"workspace": "ws_own", "screen": "screen_own", "pane": "pane_own"});
        // As the app reports it: no screen.
        let focus = json!({"workspace": "ws_front", "pane": "pane_front"});
        let place = |params: Value| {
            let mut params = params.as_object().cloned().unwrap();
            apply(&mut params, Some(&caller), Some(&focus));
            Value::Object(params)
        };
        assert_eq!(
            place(json!({"workspace": "focused", "pane": "focused"})),
            json!({"workspace": "ws_front", "pane": "pane_front"})
        );
        // Below the caller's workspace the focused pane is not there: the
        // daemon's active pane of that workspace.
        assert_eq!(
            place(json!({"workspace": "current", "pane": "focused"})),
            json!({"workspace": "ws_own", "pane": "current"})
        );
        assert_eq!(
            place(json!({"workspace": "ws_front", "pane": "focused"})),
            json!({"workspace": "ws_front", "pane": "pane_front"})
        );
        assert_eq!(
            place(json!({"workspace": "ws_fr", "pane": "focused"})),
            json!({"workspace": "ws_fr", "pane": "pane_front"}),
            "a unique prefix of the focused workspace"
        );
        // `pane focused` implies a focused screen, which the focus does not
        // name: the daemon's, and the pane is still the focused one.
        assert_eq!(
            place(json!({"workspace": "focused", "screen": "focused", "pane": "focused"})),
            json!({"workspace": "ws_front", "screen": "current", "pane": "pane_front"})
        );
        // A screen the focus does not name, other than the implied focused
        // one: the daemon's active pane under it, never the focused pane.
        assert_eq!(
            place(json!({"screen": "current", "pane": "focused"})),
            json!({"screen": "screen_own", "pane": "current"})
        );
        assert_eq!(
            place(json!({"workspace": "ws_front", "screen": "screen_x", "pane": "focused"})),
            json!({"workspace": "ws_front", "screen": "screen_x", "pane": "current"})
        );
        assert_eq!(
            place(json!({"screen": "focused", "pane": "focused"})),
            json!({"screen": "current", "pane": "current"}),
            "no workspace to check the focused pane against"
        );
        // No caller: an unresolved `current` workspace may not be the
        // focused one, so the pane is its active one.
        let mut params = json!({"workspace": "current", "pane": "focused"});
        apply(params.as_object_mut().unwrap(), None, Some(&focus));
        assert_eq!(params, json!({"workspace": "current", "pane": "current"}));
    }
}
