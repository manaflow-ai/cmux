use super::*;
use serde_json::json;

#[test]
fn catalog_round_trip_and_session_edits_are_independent() {
    let raw = json!([{"id":"model", "currentValue":"a", "options":[
        {"value":"a", "name":"Model A", "future":{"unicode":"λ", "null":null}},
        {"value":"b", "name":"Model B"}
    ]}]);
    let original: SharedValue = serde_json::from_value(raw.clone()).unwrap();
    let mut edited: SharedValue = serde_json::from_value(raw.clone()).unwrap();
    assert!(Arc::ptr_eq(&original.0, &edited.0));
    edited[0]["currentValue"] = json!("b");
    assert!(!Arc::ptr_eq(&original.0, &edited.0));
    assert_eq!(serde_json::to_value(&original).unwrap(), raw);
    assert_eq!(edited[0]["currentValue"], "b");
    assert_eq!(original[0]["currentValue"], "a");
    let cloned = original.clone();
    assert!(Arc::ptr_eq(&original.0, &cloned.0));
}

fn chat(id: &str) -> super::super::SessionMeta {
    let mut meta: super::super::SessionMeta = serde_json::from_value(json!({
        "schema": super::super::META_SCHEMA, "id": id, "name": id, "harness": "codex",
        "cwd": "/repo", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap_or_else(|e| panic!("a test meta: {e}"));
    let cfg = crate::config::Config::default();
    let mut parts = crate::context_inventory::snapshot(&cfg, &meta.cwd);
    // A `String` made anew for each chat, as `agent_guidance::for_session` makes it.
    parts.push(crate::context_inventory::guidance_part(
        crate::agent_guidance::AGENT_GUIDANCE.to_owned(),
    ));
    meta.cmux_context = Some(parts);
    meta
}

fn texts(meta: &super::super::SessionMeta) -> Vec<&SharedText> {
    meta.cmux_context.iter().flatten().filter_map(|part| part.text.as_ref()).collect()
}

#[test]
fn chats_made_or_loaded_with_the_same_context_hold_its_text_once() {
    use super::super::{LocalStore, Store};
    let (first, second) = (chat("first"), chat("second"));
    let (made, other) = (texts(&first), texts(&second));
    assert_eq!(made.len(), 2);
    assert!(made.iter().zip(&other).all(|(a, b)| a.shares(b)), "made: one copy");

    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let root = home.path().join("sessions");
    let store = LocalStore::new(root.clone(), 64 * 1024)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    let session_json = |id: &str| {
        std::fs::read(root.join(id).join("session.json")).unwrap_or_else(|e| panic!("{e}"))
    };
    let mut written = Vec::new();
    for meta in [&first, &second] {
        store.save(meta).unwrap_or_else(|e| panic!("save: {e:#}"));
        written.push(session_json(&meta.id));
    }
    let load = |id: &str| {
        let meta = store.load(id).unwrap_or_else(|e| panic!("load: {e:#}"));
        meta.unwrap_or_else(|| panic!("no {id}"))
    };
    let (read_first, read_second) = (load("first"), load("second"));
    assert_eq!(read_first, first);
    assert_eq!(read_second, second);
    let read = texts(&read_first);
    assert!(read.iter().zip(texts(&read_second)).all(|(a, b)| a.shares(b)), "read: one copy");
    assert!(read.iter().zip(&made).all(|(a, b)| a.shares(b)), "read: the live chat's copy");

    // Written again from what was read: the same bytes.
    for (meta, before) in [&read_first, &read_second].into_iter().zip(&written) {
        store.save(meta).unwrap_or_else(|e| panic!("save: {e:#}"));
        assert_eq!(&session_json(&meta.id), before);
    }
}

#[test]
fn a_context_parts_text_reads_and_writes_as_the_string_it_was() {
    let raw = r#"{"id":"cmux-guidance","source":"cmux-guidance","label":"g","tokens":3,"included":true,"editable":false,"measurement":"estimated","channel":"user-context","text":"same words, λ \"quoted\"\n"}"#;
    let part: crate::context_inventory::ContextPart =
        serde_json::from_str(raw).unwrap_or_else(|e| panic!("read: {e}"));
    assert_eq!(part.text.as_deref(), Some("same words, λ \"quoted\"\n"));
    assert_eq!(serde_json::to_string(&part).unwrap_or_else(|e| panic!("{e}")), raw);
    let none = r#"{"id":"x","source":"harness","label":"x","tokens":0,"included":false,"editable":false,"measurement":"unavailable"}"#;
    let part: crate::context_inventory::ContextPart =
        serde_json::from_str(none).unwrap_or_else(|e| panic!("read: {e}"));
    assert!(part.text.is_none());
    assert_eq!(serde_json::to_string(&part).unwrap_or_else(|e| panic!("{e}")), none);
    // Equal texts compare equal whether or not they are one copy.
    let mut pool = Interner::<str>::default();
    let apart = SharedText(pool.insert(Arc::from("words"), 0));
    assert_eq!(apart, SharedText::from("words".to_owned()));
    assert_ne!(apart, SharedText::from("other"));
}

#[test]
fn collisions_do_not_share_different_catalogs() {
    let mut pool = Interner::default();
    let first = pool.intern(json!({"a":1}), 0);
    let second = pool.intern(json!({"a":2}), 0);
    assert!(!Arc::ptr_eq(&first, &second));
    assert_eq!(*first, json!({"a":1}));
    assert_eq!(*second, json!({"a":2}));
}

#[test]
fn no_op_updates_keep_sharing_and_real_edits_detach() {
    let original = SharedValue::from(json!([
        {"id":"model", "currentValue":"a"},
        {"id":"mode", "currentValue":"default"}
    ]));
    let mut edited = original.clone();
    assert!(!edited.update_matching(
        |item| item["currentValue"] == "bypassPermissions",
        |item| item["currentValue"] = Value::Null,
    ));
    assert!(Arc::ptr_eq(&original.0, &edited.0));
    assert!(
        edited.update_matching(
            |item| item["id"] == "mode",
            |item| item["currentValue"] = Value::Null,
        )
    );
    assert!(!Arc::ptr_eq(&original.0, &edited.0));
    assert_eq!(original[1]["currentValue"], "default");
    assert!(edited[1]["currentValue"].is_null());
    assert_eq!(edited[0], original[0]);
}

#[test]
fn bookkeeping_is_bounded_and_does_not_retain_catalogs() {
    let mut pool = Interner::default();
    let live: Vec<_> = (0..INTERN_SLOTS * 2).map(|n| pool.intern(json!(n), n as u64)).collect();
    assert!(pool.0.len() <= INTERN_SLOTS);
    assert_eq!(*live[0], json!(0));
    let weak = Arc::downgrade(&live[0]);
    drop(live);
    assert!(weak.upgrade().is_none());
    pool.intern(Value::Null, u64::MAX);
    assert_eq!(pool.0.len(), 1);
}
