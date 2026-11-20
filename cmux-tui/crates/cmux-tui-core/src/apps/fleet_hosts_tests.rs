use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{FRESH, FleetHosts, shape};

fn status() -> Value {
    json!({"hosts": [
        {"name": "mac-mini", "self": true, "reachable": true, "device": "mac-mini",
         "deviceSymbol": "macmini", "cpus": 10, "liveSessions": 3, "load": [4.0, 3.0, 2.0],
         "pressure": {"ok": true, "load1": 4.0, "load_limit": 8.0, "cores": 8,
                      "pressure": "normal", "available_ram_fraction": 0.42}},
        {"name": "big-box", "self": false, "reachable": true, "device": "linux-server",
         "deviceSymbol": "server.rack", "cpus": 64, "liveSessions": 0, "load": [90.0, 80.0, 70.0],
         "pressure": {"ok": false, "load1": 90.0, "load_limit": 60.0,
                      "pressure": "warn", "available_ram_fraction": 0.05}},
        {"name": "laptop", "self": false, "reachable": false, "state": "down",
         "error": "not connected; `acpmux machine doctor laptop` checks it step by step"},
        {"name": "old-build", "self": false, "reachable": true, "healthUnsupported": true},
        {"self": false, "reachable": true}
    ]})
}

#[test]
fn rows_carry_what_acpmux_said_and_busy_is_load_over_its_limit() {
    let rows = shape(&status());
    let rows = rows.as_array().unwrap();
    assert_eq!(rows.len(), 4, "a row without a name is left out");
    assert_eq!(
        rows[0],
        json!({"name": "mac-mini", "self": true, "reachable": true, "device": "mac-mini",
               "deviceSymbol": "macmini", "cpus": 10, "load1": 4.0, "loadLimit": 8.0,
               "busy": 0.5, "pressure": "normal", "overBudget": false, "liveSessions": 3,
               "ramFreeFraction": 0.42})
    );
    assert_eq!(rows[1]["busy"], json!(1.0), "busy is clamped to 1");
    assert_eq!(rows[1]["overBudget"], json!(true));
    assert_eq!(rows[1]["pressure"], json!("warn"));
    assert_eq!(rows[1]["liveSessions"], json!(0), "a real zero stays zero");
}

#[test]
fn unknown_numbers_are_null_never_zero() {
    let rows = shape(&status());
    for row in [&rows[2], &rows[3]] {
        for key in [
            "device",
            "deviceSymbol",
            "cpus",
            "load1",
            "loadLimit",
            "busy",
            "pressure",
            "overBudget",
            "liveSessions",
            "ramFreeFraction",
        ] {
            assert_eq!(row[key], Value::Null, "{} {key}", row["name"]);
        }
    }
    assert_eq!(rows[2]["reachable"], json!(false));
    assert_eq!(rows[3]["reachable"], json!(true), "an older build answers, with no numbers");
}

#[test]
fn load1_falls_back_to_the_kernel_average_and_busy_needs_a_limit() {
    let rows = shape(&json!({"hosts": [
        {"name": "a", "reachable": true, "load": [2.5, 1.0, 1.0]},
        {"name": "b", "reachable": true, "load": [2.5], "pressure": {"load_limit": 0.0}}
    ]}));
    assert_eq!(rows[0]["load1"], json!(2.5));
    assert_eq!(rows[0]["busy"], Value::Null);
    assert_eq!(rows[1]["loadLimit"], Value::Null, "a zero limit is no limit");
    assert_eq!(rows[1]["busy"], Value::Null);
}

#[test]
fn a_status_without_hosts_is_an_empty_list() {
    assert_eq!(shape(&json!({})), json!([]));
    assert_eq!(shape(&json!({"hosts": "x"})), json!([]));
}

/// The cache: reads inside the window make no call; the next read after it makes one.
#[test]
fn many_reads_in_the_window_cost_one_call() {
    let cache = FleetHosts::default();
    let calls = AtomicUsize::new(0);
    let call = || {
        calls.fetch_add(1, Ordering::SeqCst);
        Ok(status())
    };
    let t0 = Instant::now() + Duration::from_secs(3600);
    for i in 0..100 {
        let rows = cache.get(t0 + Duration::from_millis(i * 250), call).unwrap();
        assert_eq!(rows.as_array().unwrap().len(), 4);
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    cache.get(t0 + FRESH, call).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 2, "a read past the window calls again");
}

/// Idle: nothing calls acpmux unless a read asks, however long the cache sits.
#[test]
fn no_reader_means_no_call() {
    let cache = FleetHosts::default();
    let calls = AtomicUsize::new(0);
    let t0 = Instant::now() + Duration::from_secs(3600);
    cache
        .get(t0, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(status())
        })
        .unwrap();
    // An hour with no reader: no thread, no timer, so the count cannot move.
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    cache
        .get(t0 + Duration::from_secs(3600), || {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(status())
        })
        .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 2, "the next read makes exactly one call");
}

/// Readers that arrive while a call runs wait for it instead of starting their own.
#[test]
fn concurrent_readers_share_one_call() {
    let cache = Arc::new(FleetHosts::default());
    let calls = Arc::new(AtomicUsize::new(0));
    let start = Arc::new(Barrier::new(16));
    let t0 = Instant::now() + Duration::from_secs(3600);
    let readers: Vec<_> = (0..16)
        .map(|_| {
            let (cache, calls, start) = (cache.clone(), calls.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                cache.get(t0, || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    std::thread::sleep(Duration::from_millis(100));
                    Ok(status())
                })
            })
        })
        .collect();
    for reader in readers {
        assert!(reader.join().unwrap().is_ok());
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

/// A failed call is remembered for the window: a down acpmux is asked once per window.
#[test]
fn a_failure_is_remembered_for_the_window() {
    let cache = FleetHosts::default();
    let calls = AtomicUsize::new(0);
    let t0 = Instant::now() + Duration::from_secs(3600);
    for i in 0..10 {
        let answer = cache.get(t0 + Duration::from_secs(i), || {
            calls.fetch_add(1, Ordering::SeqCst);
            Err("acpmux is not running here".to_string())
        });
        assert_eq!(answer.unwrap_err(), "acpmux is not running here");
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let rows = cache.get(t0 + FRESH, || Ok(status())).unwrap();
    assert_eq!(rows.as_array().unwrap().len(), 4, "after the window the next read calls again");
}
