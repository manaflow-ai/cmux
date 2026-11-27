use super::*;

#[test]
fn a_full_reading_keeps_only_the_keys_the_hub_names() {
    let reading = json!({
        "version": 3, "build": "0.1.0+abc", "os": "linux", "arch": "x86_64", "device": "linux-server",
        "cpus": 32, "liveSessions": 9, "uptimeSecs": 100,
        "disk": {"freeBytes": 80_000_000_000u64, "totalBytes": 200_000_000_000u64},
        "load": [1.5, 1.2, 0.9],
        "ram": {"totalBytes": 64_000_000_000u64, "freeBytes": 20_000_000_000u64},
        "swap": {"usedBytes": 0, "totalBytes": 8_000_000_000u64},
        "pressure": {"ok": false, "over": ["load", "swap"], "cores": 32.0, "load1": 40.0,
                     "available_ram_fraction": 0.3, "host": "big-blue"},
        "host": "big-blue", "problems": [{"check": "dns", "detail": "down"}],
        "autoCloud": {"enrolled": true}, "node": {"wgPublicKey": "k"},
    });
    assert_eq!(
        publishable(&reading),
        Some(json!({
            "build": "0.1.0+abc", "cpus": 32, "liveSessions": 9,
            "disk": {"freeBytes": 80_000_000_000u64},
            "load": [1.5, 1.2, 0.9],
            "ram": {"totalBytes": 64_000_000_000u64, "freeBytes": 20_000_000_000u64},
            "swap": {"usedBytes": 0, "totalBytes": 8_000_000_000u64},
            "pressure": {"ok": false, "over": ["load", "swap"], "cores": 32},
        }))
    );
}

#[test]
fn a_value_the_hub_would_refuse_is_left_out_never_sent() {
    let reading = json!({
        "build": "0.1.0 dirty tree",
        "cpus": 2_000_000,
        "liveSessions": -1,
        "load": [1.0, -2.0, 0.5],
        "ram": {"freeBytes": 1.5, "totalBytes": 1u64 << 60},
        "pressure": {"ok": "yes", "over": ["Load", "swap", "x".repeat(40)], "cores": 7.5},
    });
    // Only `pressure.over`'s one valid name survives.
    assert_eq!(publishable(&reading), Some(json!({"pressure": {"over": ["swap"]}})));
}

#[test]
fn a_reading_with_nothing_the_hub_takes_publishes_nothing() {
    assert_eq!(publishable(&json!({"os": "linux"})), None);
    assert_eq!(publishable(&json!({"unsupported": true})), None);
    assert_eq!(publishable(&Value::Null), None);
}

#[test]
fn the_largest_record_fits_the_hubs_byte_bound() {
    let big = MAX_BYTES;
    let reading = json!({
        "build": "b".repeat(64), "cpus": MAX_COUNT, "liveSessions": MAX_COUNT,
        "disk": {"freeBytes": big}, "load": [999_999.999_999, 999_999.999_999, 999_999.999_999],
        "ram": {"freeBytes": big, "totalBytes": big}, "swap": {"usedBytes": big, "totalBytes": big},
        "pressure": {"ok": true, "over": vec!["a".repeat(32); 12], "cores": MAX_COUNT},
    });
    let record = publishable(&reading).expect("every field in bounds");
    assert!(record.to_string().len() <= MAX_RECORD_BYTES, "{}", record.to_string().len());
    assert_eq!(record["pressure"]["over"].as_array().map(Vec::len), Some(MAX_OVER));
}

#[test]
fn placement_weighs_a_published_record_as_it_weighs_a_full_reading() {
    // `placement.rs` `weigh` reads only keys the record keeps: its room is the same either way.
    let reading = json!({
        "cpus": 16, "liveSessions": 2, "load": [4.0, 4.0, 4.0], "os": "linux",
        "disk": {"freeBytes": 300_000_000_000u64, "totalBytes": 500_000_000_000u64},
        "ram": {"totalBytes": 64_000_000_000u64, "freeBytes": 40_000_000_000u64},
        "swap": {"usedBytes": 0, "totalBytes": 0},
        "pressure": {"ok": true, "over": [], "cores": 16, "load1": 4.0},
    });
    let record = publishable(&reading).unwrap();
    for ptr in [
        "/ram/freeBytes",
        "/load/0",
        "/pressure/cores",
        "/cpus",
        "/disk/freeBytes",
        "/swap/usedBytes",
        "/pressure/ok",
        "/pressure/over",
        "/liveSessions",
    ] {
        assert_eq!(record.pointer(ptr), reading.pointer(ptr), "{ptr}");
    }
}
