//! The sidebar mirror's batch answers, pinned: the refused, ignored, early,
//! stale, gapped and applied paths of `apply_batch` and their `dropped`
//! list. The same answers before and after its reads stopped indexing a
//! JSON value (the panic ratchet, B9b).

use cmux_layout_reducer_ffi::sidebar_mirror::Mirror;
use serde_json::{Value, json};

fn batch(mirror: &mut Mirror, input: &Value) -> Value {
    mirror.apply_batch(&serde_json::to_vec(input).unwrap())
}

fn marker(revision: &str, previous: &str) -> Value {
    json!({"changes": [{"resource": "sidebar_doc", "value": {"revision": revision, "previous_revision": previous}}]})
}

#[test]
fn sidebar_mirror_batch_answers_before_a_load() {
    let mut mirror = Mirror::new();
    assert_eq!(batch(&mut mirror, &json!({"rejected": true})), json!({"ok": true, "dropped": []}));
    // Only a boolean true refuses.
    assert_eq!(
        batch(&mut mirror, &json!({"rejected": "true"})),
        json!({"ok": true, "ignored": true, "dropped": []})
    );
    assert_eq!(batch(&mut mirror, &json!({})), json!({"ok": true, "ignored": true, "dropped": []}));
    // Not an object: no changes, no revision.
    assert_eq!(
        batch(&mut mirror, &json!([1, 2])),
        json!({"ok": true, "ignored": true, "dropped": []})
    );
    // `changes` that is not a list reads as none.
    assert_eq!(
        batch(&mut mirror, &json!({"changes": {"resource": "sidebar_doc"}})),
        json!({"ok": true, "ignored": true, "dropped": []})
    );
    // A sidebar batch before the document is shown asks for a refetch.
    assert_eq!(batch(&mut mirror, &marker("5", "4")), json!({"refetch": true, "dropped": []}));
    // Not JSON: the error, with no `dropped`.
    let answer = mirror.apply_batch(b"{");
    assert!(answer.get("error").is_some_and(Value::is_string), "{answer}");
    assert!(answer.get("dropped").is_none(), "{answer}");
}

#[test]
fn sidebar_mirror_batch_answers_after_a_load() {
    let mut mirror = Mirror::new();
    assert_eq!(
        mirror.load(br#"{"revision": "3"}"#),
        json!({"ok": true, "revision": "3", "dropped": []})
    );
    // The next revision applies.
    assert_eq!(
        batch(&mut mirror, &marker("4", "3")),
        json!({"ok": true, "revision": "4", "dropped": []})
    );
    // The same revision again is stale; a gap asks for a refetch.
    assert_eq!(
        batch(&mut mirror, &marker("4", "3")),
        json!({"ok": true, "stale": true, "dropped": []})
    );
    assert_eq!(batch(&mut mirror, &marker("9", "7")), json!({"refetch": true, "dropped": []}));
    assert_eq!(
        batch(&mut mirror, &json!({"rejected": true, "revision": "5"})),
        json!({"ok": true, "dropped": []})
    );
}
