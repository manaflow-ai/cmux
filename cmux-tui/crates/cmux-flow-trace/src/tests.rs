use super::*;

#[test]
fn hex_matches_the_daemon_terminal_id() {
    assert_eq!(hex(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
}

#[test]
fn json_safe_keeps_ids_and_drops_the_rest() {
    assert_eq!(json_safe("ab12.x_y-z"), "ab12.x_y-z");
    assert_eq!(json_safe("a\"b\\c\nd"), "abcd");
}

#[test]
fn the_clock_moves_forward() {
    let first = now_ns();
    let second = now_ns();
    assert!(first > 0 && second >= first);
}

#[test]
fn the_ring_keeps_order_and_refuses_when_full() {
    let ring = Ring::new();
    let record = |flow| Record {
        name: "x",
        flow,
        terminal: [0; TERMINAL_BYTES],
        terminal_len: 0,
        tid: 0,
        t_ns: 0,
    };
    for flow in 0..RING_SLOTS as u64 {
        assert!(ring.push(record(flow)));
    }
    assert!(!ring.push(record(u64::MAX)), "a full ring took a record");
    assert_eq!(ring.pop().map(|r| r.flow), Some(0));
    assert!(ring.push(record(7)), "a freed slot was not reused");
    let mut last = 0;
    while let Some(r) = ring.pop() {
        last = r.flow;
    }
    assert_eq!(last, 7);
    assert_eq!(ring.waiting(), 0);
}
