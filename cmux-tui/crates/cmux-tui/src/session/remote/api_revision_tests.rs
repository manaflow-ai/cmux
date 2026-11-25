use super::*;
use cmux_api_compat::{Change, MessageChange, Schema};
use serde_json::json;
use std::sync::LazyLock;

static COMPAT: LazyLock<Compat> = LazyLock::new(|| {
    let mut schema = Schema::new("test", 12);
    schema.push(
        "rename a field",
        ["request:demo", "response:demo", "event:demo"]
            .map(|message| MessageChange {
                message: message.into(),
                change: Change::Rename { path: "/data/name".into(), to: "title".into() },
            })
            .to_vec(),
    );
    Compat::new(schema).unwrap()
});

fn older_peer() -> RemoteApiRevision {
    RemoteApiRevision::with_compat(&COMPAT, &json!({"api_revision": 12, "min_api_revision": 12}))
        .unwrap()
        .unwrap()
}

#[test]
fn remote_api_revision_translates_request_response_and_event() {
    let revision = older_peer();
    let current = r#"{"id":7,"data":{"title":"x"},"raw":[ 1,  2 ]}"#;
    let old = r#"{"id":7,"data":{"name":"x"},"raw":[ 1,  2 ]}"#;
    assert_eq!(revision.outgoing(7, "demo", current).unwrap(), old);
    assert_eq!(revision.incoming(old).unwrap(), current);
    assert_eq!(
        revision.incoming(r#"{"event":"demo","data":{"name":"x"}}"#).unwrap(),
        r#"{"event":"demo","data":{"title":"x"}}"#
    );
}

#[test]
fn remote_api_revision_no_reply_never_retains_commands() {
    let revision = older_peer();
    for _ in 0..4_097 {
        assert_eq!(
            revision.outgoing_no_reply("demo", r#"{"data":{"title":"x"}}"#).unwrap(),
            r#"{"data":{"name":"x"}}"#
        );
    }
    assert!(revision.commands.lock().unwrap().is_empty());
}

#[test]
fn remote_api_revision_has_no_pending_cap_and_forgets_every_request() {
    // Past the 4096 pending requests the client once refused at.
    let revision = older_peer();
    let past_old_cap = 4_097u64;
    for id in 0..past_old_cap {
        revision.outgoing(id, "demo", "{}").unwrap();
    }
    assert_eq!(revision.commands.lock().unwrap().len(), past_old_cap as usize);
    assert_eq!(
        revision.incoming(r#"{"id":0,"data":{"name":"x"}}"#).unwrap(),
        r#"{"id":0,"data":{"title":"x"}}"#
    );
    for id in 1..past_old_cap {
        revision.forget(id);
    }
    assert!(revision.commands.lock().unwrap().is_empty());
}

#[test]
fn remote_api_revision_rejects_invalid_or_disjoint_ranges() {
    for ident in [
        json!({"api_revision": null}),
        json!({"api_revision": "12"}),
        json!({"api_revision": 12, "min_api_revision": 13}),
        json!({"api_revision": 12, "min_api_revision": "12"}),
        json!({"api_revision": 11}),
        json!({"api_revision": 14, "min_api_revision": 14}),
    ] {
        assert!(RemoteApiRevision::with_compat(&COMPAT, &ident).is_err(), "{ident}");
    }
}

#[test]
fn remote_api_revision_native_and_newer_peers_keep_native_wire() {
    for ident in [json!({"api_revision": 13}), json!({"api_revision": 14, "min_api_revision": 12})]
    {
        let revision = RemoteApiRevision::with_compat(&COMPAT, &ident).unwrap().unwrap();
        let message = r#"{"id":7,"data":{"title":"x"}}"#;
        assert_eq!(revision.outgoing(7, "demo", message).unwrap(), message);
        assert_eq!(revision.incoming(message).unwrap(), message);
        assert!(revision.commands.lock().unwrap().is_empty());
    }
    assert!(RemoteApiRevision::with_compat(&COMPAT, &json!({})).unwrap().is_none());
}
