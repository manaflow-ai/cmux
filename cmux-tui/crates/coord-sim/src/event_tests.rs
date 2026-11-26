use super::*;

#[test]
fn filler_is_exact_and_json_safe() {
    for n in [0usize, 1, 7, 1000, 65_537] {
        let f = filler(42, n);
        assert_eq!(f.len(), n);
        assert!(f.bytes().all(|b| (0x20..0x7f).contains(&b) && b != b'"' && b != b'\\'));
    }
}

#[test]
fn event_round_trips() {
    let e = SimEvent { seq: 3, at_ms: 10, bytes: 99, op: Op::SendTo { to: 2 } };
    let line = serde_json::to_string(&e).unwrap();
    assert_eq!(serde_json::from_str::<SimEvent>(&line).unwrap(), e);
}
