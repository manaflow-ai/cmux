//! The pushed state's rules (moved from the app's CloudMachineStatePushTests).

use serde_json::json;

use super::*;

const VM: &str = "vm_aaaaaaaaaaaaaaaaaaaa";

#[test]
fn only_worker_machine_ids_get_a_socket() {
    assert!(valid_id(VM));
    assert!(valid_id("vm_0123456789abcdefghij"));
    for id in [
        "vm_aaaa",
        "vm-aaaaaaaaaaaaaaaaaaaa",
        "vm_AAAAAAAAAAAAAAAAAAAA",
        "vm_aaaaaaaaaaaaaaaaaaaaa",
        "vm_aaaaaaaaaaaaaaaaaaa/",
        "",
    ] {
        assert!(!valid_id(id), "{id}");
    }
}

#[test]
fn the_socket_url_is_under_the_platform_origin() {
    assert_eq!(
        state_url("https://platform.invalid", VM).unwrap(),
        format!("wss://platform.invalid/v1/cloud/machines/{VM}/state")
    );
    assert_eq!(
        state_url("https://platform.invalid/", VM).unwrap(),
        format!("wss://platform.invalid/v1/cloud/machines/{VM}/state")
    );
    assert_eq!(
        state_url("http://127.0.0.1:8787", VM).unwrap(),
        format!("ws://127.0.0.1:8787/v1/cloud/machines/{VM}/state")
    );
    assert!(state_url("https://platform.invalid", "vm-1").is_none());
    assert!(state_url("platform.invalid", VM).is_none());
}

#[test]
fn a_reply_with_no_cloud_server_is_not_a_hand_off() {
    assert!(handed_off(Some(&json!({"servers": 1}))));
    assert!(handed_off(Some(&json!({"servers": 2}))));
    // No Cloud app server took it: the machine stays on reads.
    assert!(!handed_off(Some(&json!({"servers": 0}))));
    assert!(!handed_off(Some(&json!({}))));
    assert!(!handed_off(None));
}

fn state(revision: &str, status: &str) -> String {
    json!({"v": 1, "t": "state", "machine": VM, "revision": 1, "state": {"record": {"id": VM, "status": status, "revision": revision}}}).to_string()
}

#[test]
fn a_state_frame_shows_its_record_unless_an_older_one() {
    let Frame::State { record, forward } = frame(VM, &state("5", "paused"), None) else {
        panic!("not a state")
    };
    assert_eq!(record.status, Status::Paused);
    assert_eq!(forward["t"], "state");
    let mut known = Machine::new(VM, Status::Running);
    known.server_revision = Some("6".into());
    assert_eq!(frame(VM, &state("5", "paused"), Some(&known)), Frame::Ignore);
    assert!(
        matches!(frame(VM, &state("6", "paused"), Some(&known)), Frame::State { .. }),
        "the same revision shows"
    );
    assert!(matches!(frame(VM, &state("7", "paused"), Some(&known)), Frame::State { .. }));
}

#[test]
fn another_machines_or_an_unreadable_frame_is_ignored() {
    assert_eq!(frame("vm_bbbbbbbbbbbbbbbbbbbb", &state("1", "running"), None), Frame::Ignore);
    assert_eq!(frame(VM, "not json", None), Frame::Ignore);
    assert_eq!(frame(VM, &json!({"t": "pong", "machine": VM}).to_string(), None), Frame::Ignore);
    assert_eq!(
        frame(VM, &json!({"t": "state", "machine": VM, "state": {}}).to_string(), None),
        Frame::Ignore
    );
}

#[test]
fn a_removal_shows_the_last_record_destroyed() {
    let removed = json!({"v": 1, "t": "removed", "machine": VM}).to_string();
    let known = Machine::new(VM, Status::Running);
    let Frame::Removed { record, .. } = frame(VM, &removed, Some(&known)) else {
        panic!("not a removal")
    };
    assert_eq!(record.unwrap().status, Status::Destroyed);
    assert!(matches!(frame(VM, &removed, None), Frame::Removed { record: None, .. }));
}

#[test]
fn a_listed_record_replaces_the_last_one_unless_that_is_newer() {
    let mut newer = Machine::new(VM, Status::Running);
    newer.server_revision = Some("9".into());
    let mut listed = Machine::new(VM, Status::Paused);
    listed.server_revision = Some("8".into());
    assert!(!keeps_listed(Some(&newer), &listed));
    assert!(keeps_listed(Some(&listed), &newer));
    assert!(keeps_listed(None, &listed));
}

#[test]
fn a_closed_socket_waits_and_never_spins() {
    assert_eq!(backoff(FIRST_BACKOFF_MS, false), (500, 1_000));
    assert_eq!(backoff(16_000, false), (16_000, MAX_BACKOFF_MS));
    // A socket that delivered frames waits the first backoff again.
    assert_eq!(backoff(MAX_BACKOFF_MS, true), (500, 1_000));
}
