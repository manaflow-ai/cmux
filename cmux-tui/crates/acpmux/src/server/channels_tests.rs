use super::*;

#[test]
fn a_service_name_is_short_and_plain() {
    assert_eq!(service_of(&json!({"service": "review/notes.v1"})).unwrap(), "review/notes.v1");
    for bad in [
        json!({}),
        json!({"service": ""}),
        json!({"service": "a b"}),
        json!({"service": "x".repeat(129)}),
    ] {
        assert!(service_of(&bad).is_err(), "{bad}");
    }
}

#[test]
fn a_frame_carries_text_or_data_never_both() {
    assert_eq!(payload(&json!({"text": "hi"}), true).unwrap(), Some(("text", json!("hi"))));
    assert_eq!(payload(&json!({"data": "AAE="}), true).unwrap(), Some(("data", json!("AAE="))));
    assert_eq!(payload(&json!({}), false).unwrap(), None);
    assert!(payload(&json!({}), true).is_err());
    assert!(payload(&json!({"text": "a", "data": "AA=="}), true).is_err());
    assert!(payload(&json!({"text": 5}), true).is_err());
}

#[test]
fn either_side_finds_the_other() {
    let a = End::Conn { id: "a".into(), conn: Weak::new() };
    let b = End::Peer { name: "box".into(), generation: 3, epoch: 1 };
    let channel = Channel { opener: a, listener: b };
    assert!(matches!(channel.other(|e| e.is_conn("a")), Some(End::Peer { .. })));
    assert!(matches!(channel.other(|e| e.is_peer("box", 3)), Some(End::Conn { .. })));
    assert!(channel.other(|e| e.is_peer("box", 4)).is_none(), "a replaced peer is not the side");
    assert!(channel.other(|e| e.is_conn("z")).is_none());
}
