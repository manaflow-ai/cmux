use super::*;
use serde_json::json;

#[test]
fn only_a_plain_message_id_is_taken() {
    assert!(is_message_id("msg_01HZY:3.a-b"));
    for bad in ["", "Bearer eyJhbGci", "../ack", "a/b", "m?x=1", &"m".repeat(129)] {
        assert!(!is_message_id(bad), "{bad:?}");
    }
}

#[test]
fn records_read_and_write_the_hubs_field_names() {
    // An inbox message as the hub sends it (cmux-platform openapi.json 1.3.0 MeshInboxMessage).
    let message: InMessage = serde_json::from_value(json!({
        "messageId": "msg_0123", "kind": "prompt", "op": null, "mode": "now",
        "to": {"sessionId": null, "name": "dep-land"},
        "from": {"daemonId": "inst_1", "user": "u_1", "host": "gcp-codex-lane-3",
                 "name": "lane-a", "sessionId": null},
        "body": "hi", "attempt": 2, "createdAt": 1, "leasedUntil": 2,
    }))
    .unwrap();
    assert_eq!((message.kind, message.mode), (Kind::Prompt, Mode::Now));
    assert_eq!(message.to.name.as_deref(), Some("dep-land"));
    assert_eq!(message.from.session_id, None);
    let kindless = json!({"messageId": "m", "body": "hi"});
    assert!(serde_json::from_value::<InMessage>(kindless).is_err(), "no kind is no prompt");
    let kind = |k: &str| serde_json::from_value::<Kind>(json!(k)).unwrap();
    assert_eq!((kind("control"), kind("later")), (Kind::Control, Kind::Unknown));
    let ack = serde_json::to_value(Ack::delivered("m-1", None)).unwrap();
    assert_eq!(ack, json!({"state": "delivered", "promptId": "m-1"}));
    let ack = serde_json::to_value(Ack::refused("no")).unwrap();
    assert_eq!(ack, json!({"state": "refused", "detail": "no"}));
    let mode = serde_json::to_value(Mode::TurnEnd).unwrap();
    assert_eq!(mode, json!("turn-end"));
    let allowed: InMessage = serde_json::from_value(json!({
        "messageId": "m", "kind": "prompt", "startWork": "allowed"
    }))
    .unwrap();
    assert_eq!(allowed.start_work, Some(StartWork::Allowed));
    assert!(
        serde_json::from_value::<InMessage>(json!({
            "messageId": "m", "kind": "prompt", "startWork": true
        }))
        .is_err()
    );
}

#[test]
fn backoff_doubles_to_its_cap_and_starts_over_after_a_success() {
    let mut b = Backoff::new(Duration::from_secs(1), Duration::from_secs(8));
    let waits: Vec<_> = (0..6).map(|_| b.next_wait()).collect();
    let bounds = [1, 2, 4, 8, 8, 8];
    for (wait, top) in waits.iter().zip(bounds) {
        let top = Duration::from_secs(top);
        assert!(*wait <= top && *wait >= top * 4 / 5, "{wait:?} for {top:?}");
    }
    b.reset();
    assert!(b.next_wait() <= Duration::from_secs(1));
    // The cap bounds the first wait too, and a huge one never overflows.
    let mut b = Backoff::new(Duration::from_secs(10), Duration::from_secs(1));
    assert!(b.next_wait() <= Duration::from_secs(1));
    let mut b = Backoff::new(Duration::MAX, Duration::MAX);
    b.next_wait();
    assert!(b.next_wait() <= Duration::MAX);
}
