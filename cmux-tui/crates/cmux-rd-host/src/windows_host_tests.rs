use super::*;
use serde_json::json;

#[test]
fn session_pushes_are_ended_and_others_ignored() {
    let request = json!({"type": "session.request", "session": {"id": "s1", "scope": "view"}});
    assert_eq!(unserved(&request), Some(("s1".into(), Close::Deny)));
    let ticket = json!({"type": "session.ticket", "role": "host", "sessionId": "s2"});
    assert_eq!(unserved(&ticket), Some(("s2".into(), Close::End)));
    let viewer = json!({"type": "session.ticket", "role": "viewer", "sessionId": "s3"});
    assert_eq!(unserved(&viewer), None);
    assert_eq!(unserved(&json!({"type": "devices.changed"})), None);
    assert_eq!(unserved(&json!({"type": "session.request", "session": {"id": ""}})), None);
}

#[test]
fn a_uniform_frame_reads_as_one_color() {
    assert_eq!(distinct_pixels(&[0u8; 64]), 1);
    assert_eq!(distinct_pixels(&[]), 0);
    let mixed: Vec<u8> = (0..64u8).flat_map(|i| [i, i, i, 0]).collect();
    assert_eq!(distinct_pixels(&mixed), 64);
    let black = CaptureCheck {
        backend: "gdi".into(),
        width: 4,
        height: 2,
        distinct: 1,
        at_ms: 0,
        error: None,
    };
    assert!(capture_line(&black).contains("one color"));
}

#[test]
fn share_on_is_refused_with_the_reason() {
    assert_eq!(run_cli(&["share".into(), "on".into()]), 1);
    assert_eq!(run_cli(&["bogus".into()]), 2);
    assert_eq!(run_cli(&["status".into(), "--nope".into(), "x".into()]), 1);
}
