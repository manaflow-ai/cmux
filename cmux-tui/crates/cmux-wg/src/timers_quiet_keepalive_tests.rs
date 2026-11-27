use super::*;

const EVERY: Duration = Duration::from_secs(10);
const TICK: Duration = Duration::from_secs(1);

#[test]
fn an_idle_session_keeps_the_interval() {
    let start = Instant::now();
    let mut keepalive = QuietKeepalive::new(EVERY, start);
    assert!(!keepalive.due(0, start + EVERY - TICK));
    assert!(keepalive.due(0, start + EVERY));
    keepalive.sent(start + EVERY);
    assert!(!keepalive.due(0, start + EVERY * 2 - TICK));
    assert!(keepalive.due(0, start + EVERY * 2));
}

#[test]
fn other_traffic_holds_it_and_the_gap_never_passes_the_interval() {
    let start = Instant::now();
    let mut keepalive = QuietKeepalive::new(EVERY, start);
    // Something leaves every 5 s: no keepalive ever.
    let mut tx = 0;
    for second in 1..=60 {
        if second % 5 == 0 {
            tx += 100;
        }
        assert!(!keepalive.due(tx, start + TICK * second), "second {second}");
    }
    // Then silence: the send seen at 60 s may have left just after the
    // 59 s run, so the keepalive is due by 69 s.
    assert!(!keepalive.due(tx, start + TICK * 68));
    assert!(keepalive.due(tx, start + TICK * 69));
}

#[test]
fn an_air_floor_shortens_the_gap_from_the_last_send() {
    const FLOOR: Duration = Duration::from_secs(4);
    let start = Instant::now();
    let mut keepalive = QuietKeepalive::new(EVERY, start);
    assert!(!keepalive.due(0, start + TICK * 3));
    keepalive.set_every(FLOOR);
    assert!(!keepalive.due(0, start + FLOOR - TICK));
    assert!(keepalive.due(0, start + FLOOR));
    keepalive.sent(start + FLOOR);
    assert!(!keepalive.due(0, start + FLOOR * 2 - TICK));
    assert!(keepalive.due(0, start + FLOOR * 2));
    // Back to the persistent interval.
    keepalive.sent(start + FLOOR * 2);
    keepalive.set_every(EVERY);
    assert!(!keepalive.due(0, start + FLOOR * 2 + EVERY - TICK));
    assert!(keepalive.due(0, start + FLOOR * 2 + EVERY));
}
