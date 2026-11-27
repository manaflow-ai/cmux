use super::*;

#[test]
fn health_is_asked_once_a_minute_whatever_the_ping() {
    let start = tokio::time::Instant::now();
    // The first ready tick asks.
    assert!(health_due(None, start));
    // A 2 s ping ticks 29 more times before the next ask, not 2.
    let mut asks = 1;
    let mut last = start;
    for tick in 1..=150u32 {
        let now = start + Duration::from_secs(2) * tick;
        if health_due(Some(last), now) {
            asks += 1;
            last = now;
        }
    }
    // 300 s of 2 s pings: one ask a minute (at 0, 60, 120, 180, 240, 300 s).
    assert_eq!(asks, 6);
}
