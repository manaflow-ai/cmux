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

#[test]
fn a_pushed_reading_keeps_what_the_hub_takes_and_nothing_else() {
    let full = json!({
        "build": "0.1.0", "os": "linux", "host": "secret", "cpus": 8, "liveSessions": 3,
        "load": [1.5, 1.2, 0.9], "ram": {"freeBytes": 5, "totalBytes": 9},
        "disk": {"freeBytes": 7, "totalBytes": 99}, "swap": {"usedBytes": 1, "totalBytes": 2},
        "pressure": {"ok": false, "over": ["load", "Bad Name"], "cores": 8, "load1": 2.0},
        "problems": ["a path /home/x"], "node": {"wgPublicKey": "k"},
    });
    let w = wire(&full);
    assert_eq!(w["disk"], json!({"freeBytes": 7}));
    assert_eq!(w["pressure"], json!({"ok": false, "over": ["load"], "cores": 8}));
    assert_eq!(w["liveSessions"], 3);
    assert!(w.get("host").is_none() && w.get("problems").is_none() && w.get("os").is_none());
    assert!(w.to_string().len() <= WIRE_BYTES);
    assert_eq!(wire(&json!({})), json!({}));
}
