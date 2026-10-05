//! The typed control messages (rd change C7) against the shared golden
//! vectors in tests/vectors/control.json. The Swift viewer's copy
//! (CmuxNextRemoteView `RemoteRdControl`) reads the same file in
//! RemoteRdControlTests, so the two cannot drift.
#![cfg(feature = "serde")]

use cmux_rd_proto::control::{Control, SecretHex};

fn vectors() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!("vectors/control.json")).expect("vectors")
}

#[test]
fn every_vector_parses_and_round_trips() {
    for v in vectors() {
        let name = v["name"].as_str().expect("name");
        let control: Control = serde_json::from_value(v["json"].clone()).unwrap_or_else(|e| panic!("{name}: {e}"));
        let again = serde_json::to_value(&control).expect("encode");
        let back: Control = serde_json::from_value(again).expect("decode again");
        assert_eq!(format!("{control:?}"), format!("{back:?}"), "{name}");
    }
}

#[test]
fn a_hello_without_service_is_a_desktop_hello() {
    let v = vectors().into_iter().find(|v| v["name"] == "hello_before_c1").expect("vector");
    let Control::Hello { service, caps, .. } = serde_json::from_value(v["json"].clone()).expect("hello")
    else {
        panic!("not a hello");
    };
    assert_eq!(service, v["service"].as_str().expect("expected service"));
    assert!(caps.is_empty());
}

#[test]
fn a_secret_never_reaches_debug_output() {
    let token = SecretHex("ab".repeat(32));
    assert_eq!(format!("{token:?}"), "<redacted>");
    let v = vectors().into_iter().find(|v| v["name"] == "hello").expect("vector");
    let hello: Control = serde_json::from_value(v["json"].clone()).expect("hello");
    assert!(!format!("{hello:?}").contains("abab"));
}
