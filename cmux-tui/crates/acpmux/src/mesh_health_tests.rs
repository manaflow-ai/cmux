use super::*;

/// A `_acpmux/host_health` reply as `server/peer_status.rs` builds it, with the text a heartbeat
/// must never carry.
fn reading() -> Value {
    json!({
        "version": "0.1.0",
        "build": "abc1234 2026-11-18",
        "os": "linux",
        "device": "linux-server",
        "host": "box-a",
        "cpus": 16,
        "liveSessions": 3,
        "uptimeSecs": 99,
        "disk": {"freeBytes": 400_000_000_000u64, "totalBytes": 500_000_000_000u64},
        "load": [9.5, 4.0, 2.0],
        "ram": {"totalBytes": 68_000_000_000u64, "freeBytes": 34_000_000_000u64},
        "swap": {"usedBytes": 0, "totalBytes": 8_000_000_000u64},
        "power": {"lidClosed": false},
        "network": {"up": true},
        "pressureAgeMs": 1200,
        "pressure": {
            "ok": false,
            "over": ["load1 9.5 >= 8 (8 cores)", "memory pressure critical", "available RAM 4% < 10%",
                     "swap +900 MB/min", "load1 again"],
            "cores": 8,
            "load1": 9.5,
            "pressure": "critical",
            "top": [{"name": "secret-session"}],
            "warning": "host-budget: box-a over its CPU/RAM budget",
        },
        "problems": [{"check": "disk", "detail": "/home/someone is full"}],
    })
}

#[test]
fn a_heartbeat_carries_numbers_and_short_limit_names_only() {
    let h = heartbeat_health(&reading()).unwrap();
    assert_eq!(
        h,
        json!({
            "ram": {"freeBytes": 34_000_000_000u64, "totalBytes": 68_000_000_000u64},
            "swap": {"usedBytes": 0, "totalBytes": 8_000_000_000u64},
            "disk": {"freeBytes": 400_000_000_000u64},
            "load": [9.5, 4.0, 2.0],
            "cpus": 16,
            "liveSessions": 3,
            "pressure": {"ok": false, "over": ["load", "memory", "ram", "swap"], "cores": 8},
            "build": "0.1.0",
        })
    );
    let text = h.to_string();
    for word in ["secret", "home", "box-a", "critical", "linux"] {
        assert!(!text.contains(word), "{word} leaked into {text}");
    }
    assert!(text.len() <= MAX_HEALTH_BYTES);
}

#[test]
fn a_reading_with_nothing_usable_sends_none() {
    assert_eq!(heartbeat_health(&json!({"os": "linux"})), None);
    assert_eq!(heartbeat_health(&Value::Null), None);
    assert_eq!(book_health(&Value::Null), None);
}

#[test]
fn the_book_keeps_the_same_field_set_whatever_the_hub_sent() {
    let sent = heartbeat_health(&reading()).unwrap();
    assert_eq!(book_health(&sent), Some(sent.clone()));
    let mut extra = sent.clone();
    extra["path"] = json!("/home/someone");
    extra["cpus"] = json!("16");
    extra["pressure"]["over"] = json!(["load", "Memory Pressure", 7]);
    extra["build"] = json!("/bin/sh");
    let kept = book_health(&extra).unwrap();
    assert_eq!(kept.get("path"), None);
    assert_eq!(kept.get("cpus"), None);
    assert_eq!(kept.get("build"), None);
    assert_eq!(kept["pressure"]["over"], json!(["load"]));
}

/// The bound's value is a contract with `placement.rs` and `machine ls`'s unknown line: three
/// of the hub's 30 s row windows.
#[test]
fn a_hub_reading_counts_as_unread_past_ninety_seconds() {
    assert_eq!(HUB_HEALTH_STALE_MS, 90_000);
}
