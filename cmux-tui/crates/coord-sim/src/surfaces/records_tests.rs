use super::*;

fn plan() -> Plan {
    Plan {
        seed: 7,
        coordinators: 3,
        history: 500,
        live_s: 5.0,
        rate: 10.0,
        max_event_bytes: 8192,
        max_gap_ms: 5000,
    }
}

#[test]
fn same_seed_same_records() {
    let shape = Shape::load(None).unwrap();
    let a = chats(&shape, &plan());
    let b = chats(&shape, &plan());
    assert_eq!(a.len(), 3);
    for (x, y) in a.iter().zip(&b) {
        assert_eq!(x.history, y.history);
        assert_eq!(x.live.len(), y.live.len());
    }
}

#[test]
fn records_are_ordered_capped_and_shaped() {
    let shape = Shape::load(None).unwrap();
    for chat in chats(&shape, &plan()) {
        assert!(chat.history.len() >= 500);
        assert!(!chat.live.is_empty(), "a 5 s stream at 10x has records");
        let mut last = 0;
        for r in chat.history.iter().chain(chat.live.iter().map(|(_, r)| r)) {
            let seq = r["seq"].as_u64().unwrap();
            assert_eq!(seq, last + 1);
            last = seq;
            assert!(r.to_string().len() < 8192 + 2048);
            assert_eq!(r["sessionId"], chat.session_id.as_str());
        }
        assert!(chat.history.iter().any(|r| r["kind"] == "turn_started"));
        assert!(chat.history.iter().any(|r| r["kind"] == "tool_call"));
        assert!(chat.live.windows(2).all(|w| w[0].0 <= w[1].0));
    }
}
