use super::*;
use serde_json::json;

fn hello(abi: Option<u64>, min: Option<u64>) -> Value {
    let mut meta = serde_json::Map::new();
    if let Some(abi) = abi {
        meta.insert("abi".into(), json!(abi));
    }
    if let Some(min) = min {
        meta.insert("abiMin".into(), json!(min));
    }
    json!({"_meta": {"acpmux": meta}})
}

#[test]
fn the_window_keeps_n_minus_1() {
    // The build before this one (N-1) still talks to it: the floor never passes ABI - 1.
    assert!(ABI_MIN < crate::protocol::ABI.max(1));
    let ours = AbiRange::ours();
    let n_minus_1 = AbiRange { min: ABI_MIN.saturating_sub(1), max: crate::protocol::ABI - 1 };
    assert_eq!(ours.common(n_minus_1), Some(crate::protocol::ABI - 1));
}

#[test]
fn n_plus_1_that_still_serves_us_talks_at_ours() {
    // A newer daemon (N+1) whose floor is at or under our ABI talks at our ABI.
    let ours = AbiRange::ours();
    let next = AbiRange { min: crate::protocol::ABI, max: crate::protocol::ABI + 1 };
    assert_eq!(ours.common(next), Some(crate::protocol::ABI));
}

#[test]
fn a_peer_from_before_the_fields_is_abi_0_and_still_served() {
    let old = AbiRange::of(&hello(None, None));
    assert_eq!(old, AbiRange { min: 0, max: 0 });
    assert_eq!(AbiRange::ours().common(old), Some(0), "ABI_MIN 0 serves pre-field peers");
}

#[test]
fn a_missing_or_bad_floor_is_the_peers_one_revision() {
    assert_eq!(AbiRange::of(&hello(Some(2), None)), AbiRange { min: 2, max: 2 });
    assert_eq!(AbiRange::of(&hello(Some(2), Some(5))), AbiRange { min: 2, max: 2 });
    assert_eq!(AbiRange::of(&hello(Some(3), Some(1))), AbiRange { min: 1, max: 3 });
}

#[test]
fn no_overlap_is_refused_typed_naming_the_side_to_update() {
    let ours = AbiRange { min: 2, max: 3 };
    let older = AbiRange { min: 0, max: 1 };
    let newer = AbiRange { min: 4, max: 5 };
    assert_eq!(ours.common(older), None);
    assert_eq!(ours.common(newer), None);
    assert_eq!(update_side(ours, older), "peer");
    assert_eq!(update_side(ours, newer), "self");
    let refused = refusal(ours, older);
    let data = refused.data.clone().expect("typed");
    assert_eq!(data["errorKind"], json!(crate::recovery::kind::VERSION_INCOMPATIBLE));
    assert_eq!(data["details"]["update"], json!("peer"));
    assert!(data["recovery"].as_str().unwrap().starts_with("this client is older"), "{data}");
}

fn reply(abi: u32, min: u32) -> Value {
    json!({"_meta": {"acpmux": {"abi": abi, "abiMin": min}}})
}

#[test]
fn a_peer_reply_from_n_minus_1_n_plus_1_or_before_the_fields_is_served() {
    let n = crate::protocol::ABI;
    // N-1: a far daemon one revision behind, its floor at or under it.
    assert!(check_reply(&reply(n - 1, ABI_MIN), "the peer daemon").is_ok());
    // N+1: a far daemon one revision ahead that still serves ours.
    assert!(check_reply(&reply(n + 1, n), "the peer daemon").is_ok());
    // A daemon from before the fields names no `abi`: served as before.
    assert!(check_reply(&json!({"_meta": {"acpmux": {"version": "0.1"}}}), "x").is_ok());
    assert!(check_reply(&json!({}), "x").is_ok());
}

#[test]
fn a_peer_reply_with_no_overlap_is_refused_typed() {
    let n = crate::protocol::ABI;
    let refused = check_reply(&reply(n + 5, n + 1), "the peer daemon").expect_err("no overlap");
    let data = refused.data.clone().expect("typed");
    assert_eq!(data["errorKind"], json!(crate::recovery::kind::VERSION_INCOMPATIBLE));
    assert_eq!(data["details"]["update"], json!("self"), "the far daemon is newer: update here");
    assert_eq!(data["details"]["theirs"], json!({"min": n + 1, "max": n + 5}));
    let line = describe(&refused);
    assert!(line.contains("version.incompatible"), "{line}");
    assert!(line.contains("acpmux host self-update"), "{line}");
    // An untyped error reads as its message alone.
    assert_eq!(describe(&crate::rpc::RpcError::new(-1, "nope")), "nope");
}

#[test]
fn an_incompatible_agent_host_names_the_side_and_keeps_its_build() {
    let (message, data) = agent_host_incompatible((2, 3), (1, 1), "abc");
    assert!(message.contains("build abc"), "{message}");
    assert_eq!(data["errorKind"], json!(crate::recovery::kind::VERSION_INCOMPATIBLE));
    assert_eq!(data["details"]["update"], json!("peer"));
    assert_eq!(data["details"]["link"], json!("agent-host"));
    assert!(data["recovery"].as_str().unwrap().contains("restart the chat"), "{data}");
    let (_, newer) = agent_host_incompatible((1, 3), (4, 5), "def");
    assert_eq!(newer["details"]["update"], json!("self"));
    assert!(newer["recovery"].as_str().unwrap().contains("self-update"), "{newer}");
}

#[test]
fn every_hello_stamp_carries_the_floor() {
    let mut meta = serde_json::Map::new();
    crate::abi_hello::stamp(&mut meta);
    assert_eq!(meta.get(ABI_MIN_FIELD), Some(&json!(ABI_MIN)));
    assert_eq!(meta.get("abi"), Some(&json!(crate::protocol::ABI)));
}
