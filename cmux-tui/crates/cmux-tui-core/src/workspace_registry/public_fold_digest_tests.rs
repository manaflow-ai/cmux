use super::*;
use serde_json::json;

/// A folded workspace value without `extra.key`, as the fold compared it when it kept the
/// value (the reference for [`without_key_digest`]).
fn without_workspace_key(value: &Value) -> Value {
    let mut value = value.clone();
    if let Some(object) = value.as_object_mut()
        && let Some(extra) = object.get_mut("extra").and_then(Value::as_object_mut)
    {
        extra.remove("key");
        if extra.is_empty() {
            object.remove("extra");
        }
    }
    value
}

/// `PublicTopologyFold::states` when it kept the value.
fn states_by_value(resource: &str, held: &Value, value: &Value) -> bool {
    held == value
        || (resource == "workspace" && without_workspace_key(held) == without_workspace_key(value))
}

/// `PublicTopologyFold::may_state_decorated` when it kept the value.
fn may_state_decorated_by_value(resource: &str, held: &Value, value: &Value) -> bool {
    if !matches!(resource, "workspace" | "tab" | "screen") {
        return false;
    }
    let (Some(held), Some(raw)) = (held.as_object(), value.as_object()) else {
        return false;
    };
    let decorated_only = |key: &String| key == "content_kind" || key == "extra";
    held.iter()
        .filter(|(key, _)| !decorated_only(key))
        .all(|(key, value)| raw.get(key) == Some(value))
        && raw.keys().filter(|key| !decorated_only(key)).all(|key| held.contains_key(key))
}

/// `projection_crosscheck.rs` `stable_value` of a value.
fn stable(resource: &str, value: &Value) -> Value {
    let mut value = value.clone();
    if let Some(fields) = value.as_object_mut() {
        for field in volatile_fields(resource) {
            fields.remove(*field);
        }
    }
    value
}

/// `workspace_commit_intent.rs` `raw_upsert_stated`'s field compare when the fold kept the
/// value.
fn holds_fields_by_value(stated: &Value, raw: &serde_json::Map<String, Value>) -> bool {
    raw.iter().all(|(field, raw)| match (field.as_str(), raw) {
        ("extra", Value::Object(extra)) => extra.iter().all(|(name, raw)| {
            stated.get("extra").and_then(|stated| stated.get(name)) == Some(raw)
        }),
        _ => stated.get(field) == Some(raw),
    })
}

fn values() -> Vec<Value> {
    vec![
        json!({"id": "w", "name": "a"}),
        json!({"id": "w", "name": "b"}),
        json!({"id": "w", "name": "a", "extra": {}}),
        json!({"id": "w", "name": "a", "extra": {"key": "k"}}),
        json!({"id": "w", "name": "a", "extra": {"key": "k2"}}),
        json!({"id": "w", "name": "a", "extra": {"key": "k", "title": "t"}}),
        json!({"id": "w", "name": "a", "extra": {"title": "t"}}),
        json!({"id": "w", "name": "a", "extra": {"title": "u"}}),
        json!({"id": "w", "name": "a", "extra": {"title": "t", "color": "c"}}),
        json!({"id": "w", "name": "a", "extra": {"key": 7}}),
        json!({"id": "w", "name": "a", "focused": true}),
        json!({"id": "w", "extra": {"key": "k"}}),
        json!({"id": "w", "name": "a", "extra": "odd"}),
        json!({"id": "w", "name": "a", "extra": ["key"]}),
        json!({"id": "w", "name": "a", "content_kind": "chat"}),
        json!({"id": "w", "name": "a", "content_kind": "chat", "extra": {"key": "k"}}),
        json!({"id": "w", "name": "b", "content_kind": "chat"}),
        json!({"id": "w", "index": 0, "tabs": ["a", "b"]}),
        json!({"id": "w", "index": 0, "tabs": ["b", "a"]}),
        json!({"id": "w", "index": 1, "tabs": ["a", "b"]}),
        json!({"id": "w", "index": 1.0, "tabs": ["a", "b"]}),
        json!({"id": "w", "title": "x", "cols": 80, "rows": 24, "cwd": "/"}),
        json!({"id": "w", "title": "y", "cols": 81, "rows": 24, "cwd": "/tmp"}),
        json!({"id": "w", "title": "x", "loading": true, "size": {"w": 1}}),
        json!({"id": "w", "nested": {"a": {"b": [1, null, false]}}}),
        json!({"id": "w", "nested": {"a": {"b": [1, null, true]}}}),
        json!({}),
        json!(null),
        json!("not an object"),
    ]
}

fn upsert(resource: &str, value: &Value) -> Value {
    upsert_id(resource, "x", value)
}

fn upsert_id(resource: &str, id: &str, value: &Value) -> Value {
    json!({"kind": "upsert", "resource": resource, "id": id, "value": value})
}

fn delete(resource: &str, id: &str) -> Value {
    json!({"kind": "delete", "resource": resource, "id": id})
}

/// For each pair of representative values, of each tracked resource, the fold's digests
/// answer each question as the fold that kept the value did: whether an upsert is stated
/// (whole, or a workspace without its key), may be stated decorated, is stated without its
/// volatile fields (the debug cross-check), and, of a workspace, whether a raw upsert's
/// fields are held and what its key is.
#[test]
fn the_digests_answer_as_the_held_values_did() {
    let values = values();
    for resource in TRACKED_RESOURCES {
        for held in &values {
            let mut fold = PublicTopologyFold::default();
            fold.apply(&json!([upsert(resource, held)]));
            let digests = &fold.values[&(resource.to_string(), "x".to_string())];
            for value in &values {
                let what = format!("{resource}: held {held}, upsert {value}");
                let change = upsert(resource, value);
                assert_eq!(fold.states(&change), states_by_value(resource, held, value), "{what}");
                assert_eq!(
                    fold.may_state_decorated(&change),
                    may_state_decorated_by_value(resource, held, value),
                    "{what}"
                );
                let stable_value = stable(resource, value);
                assert_eq!(
                    digests.is_stable(&stable_value),
                    stable(resource, held) == stable_value,
                    "{what}"
                );
                if resource != "workspace" {
                    continue;
                }
                assert_eq!(
                    workspace_value_stated(digests, value),
                    states_by_value(resource, held, value),
                    "{what}"
                );
                if let Some(raw) = value.as_object() {
                    assert_eq!(
                        digests.holds_fields(raw),
                        holds_fields_by_value(held, raw),
                        "{what}"
                    );
                }
            }
            if resource == "workspace" {
                for key in ["k", "k2", "t", "7"] {
                    assert_eq!(
                        digests.has_workspace_key(key),
                        held.pointer("/extra/key").and_then(Value::as_str) == Some(key),
                        "held {held}, key {key}"
                    );
                }
            }
        }
    }
}

/// A value's digest does not depend on the order in which its map was built.
#[test]
fn a_digest_does_not_depend_on_the_order_of_a_map() {
    let mut forward = serde_json::Map::new();
    let mut backward = serde_json::Map::new();
    for name in ["a", "b", "c"] {
        forward.insert(name.into(), json!({"x": name, "y": [name]}));
    }
    for name in ["c", "b", "a"] {
        backward.insert(name.into(), json!({"y": [name], "x": name}));
    }
    let (forward, backward) = (Value::Object(forward), Value::Object(backward));
    assert_eq!(value_digest(&forward), value_digest(&backward));
    assert_eq!(without_key_digest(&forward), without_key_digest(&backward));
    assert_eq!(digest_without(&forward, &["b"]), digest_without(&backward, &["b"]));
}

/// THE FOLD KEEPS NO VALUE. A value of each tracked resource with a 1 MB field (and a
/// workspace with 40 `extra` fields): the fold keeps a few hundred bytes for each, not
/// its value. Before, it kept a copy of every value (9.2 MB at 1,000 workspaces).
#[test]
fn the_fold_keeps_no_copy_of_a_value() {
    let large = "x".repeat(1 << 20);
    let mut fold = PublicTopologyFold::default();
    let mut changes = Vec::new();
    for resource in TRACKED_RESOURCES {
        let mut value = json!({"id": resource, "name": large, "title": large, "cwd": large});
        if resource == "workspace" {
            let extra = (0..40)
                .map(|n| (format!("field-{n}"), json!(large)))
                .collect::<serde_json::Map<_, _>>();
            value["extra"] = Value::Object(extra);
        }
        changes.push(upsert(resource, &value));
    }
    fold.apply(&Value::Array(changes));
    assert_eq!(fold.values.len(), TRACKED_RESOURCES.len());
    for ((resource, _), held) in &fold.values {
        let bound = if resource == "workspace" { 1024 } else { 128 };
        assert!(
            held.retained_bytes() <= bound,
            "the fold keeps {} bytes for a {resource}",
            held.retained_bytes()
        );
    }
}

/// A complete fold can prune a delete for an item that is already absent. A partial fold keeps
/// that delete because the missing entry may simply be outside the records it has folded.
#[test]
fn a_complete_fold_prunes_deletes_of_dead_items() {
    let mut complete = PublicTopologyFold::default();
    complete.apply(&json!([upsert("workspace", &json!({"id": "live"}))]));
    complete.completed();
    assert!(complete.states(&delete("workspace", "closed")));
    assert!(!complete.states(&delete("workspace", "live")));

    let partial = PublicTopologyFold::default();
    assert!(!partial.states(&delete("workspace", "closed")));
}

/// Folding a retained delete removes the value and keeps a complete fold complete, so a later
/// duplicate delete remains safe to prune.
#[test]
fn folding_a_delete_keeps_completeness_and_prunes_duplicates() {
    let mut fold = PublicTopologyFold::default();
    fold.apply(&json!([upsert("workspace", &json!({"id": "live"}))]));
    fold.completed();
    fold.apply(&json!([delete("workspace", "live")]));
    assert!(fold.complete);
    assert!(fold.values.is_empty());
    assert!(fold.states(&delete("workspace", "live")));
}

#[test]
fn an_exited_terminal_is_not_retained_by_the_fold() {
    let mut fold = PublicTopologyFold::default();
    fold.apply(&json!([
        upsert_id("terminal", "running", &json!({"lifecycle": "running"})),
        upsert_id("terminal", "exited", &json!({"lifecycle": "exited"})),
    ]));

    assert!(fold.values.contains_key(&("terminal".into(), "running".into())));
    assert!(!fold.values.contains_key(&("terminal".into(), "exited".into())));
    assert!(!fold.complete);
}

#[test]
fn a_complete_projection_with_an_exited_terminal_stays_conservative() {
    let mut fold = PublicTopologyFold::default();
    fold.apply(&json!([
        upsert_id("workspace", "workspace", &json!({"id": "workspace"})),
        upsert_id("terminal", "exited", &json!({"lifecycle": "exited"})),
    ]));
    fold.completed();

    assert!(!fold.complete);
    assert!(!fold.holds_every_resource());
}
