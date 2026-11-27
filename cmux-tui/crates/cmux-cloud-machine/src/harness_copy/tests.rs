//! The off switch (moved from the app's CloudHarnessLoginCopySwitchTests).

use serde_json::json;

use super::*;

#[test]
fn the_routes_answer_reads_plain_or_wrapped() {
    assert_eq!(
        read(&json!({"enabled": true, "ttlSeconds": 120})).unwrap(),
        Copy { enabled: true, ttl_seconds: 120 }
    );
    assert_eq!(
        read(&json!({"ok": true, "value": {"enabled": false, "ttlSeconds": 60}})).unwrap(),
        Copy { enabled: false, ttl_seconds: 60 }
    );
    // A ttl longer than five minutes is cut to five: the switch always takes effect within that.
    assert_eq!(read(&json!({"enabled": true, "ttlSeconds": 86400})).unwrap().ttl_seconds, 300);
    assert_eq!(read(&json!({"enabled": true, "ttlSeconds": -5})).unwrap().ttl_seconds, 0);
    assert!(read(&json!({"enabled": "yes"})).is_err());
    assert!(read(&json!({"enabled": true})).is_err());
}

#[test]
fn never_read_or_stale_is_off() {
    assert_eq!(current(None, 300, 0), None);
    assert_eq!(current(Some(true), 300, 0), Some(true));
    assert_eq!(current(Some(false), 300, 0), Some(false));
    assert_eq!(current(Some(true), 300, 300_000), Some(true));
    assert_eq!(current(Some(true), 300, 301_000), None);
}
