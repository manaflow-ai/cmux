//! `_acpmux/host_health`'s `problems` follow the machine health loop's file
//! (`/run/cmux/machine-health.json`, here `HEALTH_FILE`) as it changes: fresh,
//! stale, not valid, gone. Its own test binary, so no other test reads the
//! file while this one rewrites it.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts here; the hub reads the file below instead of /run/cmux.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().with_env(&[("ACPMUX_MACHINE_HEALTH_FILE", HEALTH_FILE)]);
const HEALTH_FILE: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/machine-health-test.json");

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

/// `host_health` on a fresh in-memory hub's local socket.
async fn host_health() -> Value {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let (in_tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut out_rx) = mpsc::channel(64);
    tokio::spawn(serve_connection(Hub::new(cfg, store), in_rx, out_tx));
    let init = json!({"protocolVersion": 1});
    in_tx.send(Message::request(1, method::INITIALIZE, init).to_line()).await.unwrap();
    in_tx.send(Message::request(2, "_acpmux/host_health", json!({})).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), out_rx.recv())
            .await
            .expect("timeout")
            .expect("closed");
        if let Message::Response { id, result, error } = Message::parse(&line).unwrap()
            && id == 2
        {
            assert!(error.is_none(), "{line}");
            return result.unwrap_or(Value::Null);
        }
    }
}

/// RFC 3339 for `secs` since the epoch (UTC), as the health loop writes it.
fn rfc3339(secs: u64) -> String {
    let (days, rem) = ((secs / 86_400) as i64 + 719_468, secs % 86_400);
    let (era, doe) = (days.div_euclid(146_097), days.rem_euclid(146_097));
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let (d, m) = (doy - (153 * mp + 2) / 5 + 1, if mp < 10 { mp + 3 } else { mp - 9 });
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

#[tokio::test]
async fn host_health_follows_the_file_fresh_stale_invalid_and_gone() {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let fresh = json!({"schema": 1, "checkedAt": rfc3339(now), "problems": [
        {"check": "peer", "detail": "peer cosmic-gray: handshake not finished"}]});
    std::fs::write(HEALTH_FILE, fresh.to_string()).unwrap();
    let health = host_health().await;
    assert_eq!(
        health["problems"],
        json!([{"check": "peer", "detail": "peer cosmic-gray: handshake not finished"}]),
        "{health}"
    );

    // The loop stopped 10 minutes ago: one `loop` problem, whatever its list said.
    let stale = json!({"schema": 1, "checkedAt": rfc3339(now - 600), "problems": []});
    std::fs::write(HEALTH_FILE, stale.to_string()).unwrap();
    let health = host_health().await;
    let only = health["problems"].as_array().unwrap_or_else(|| panic!("{health}"));
    assert_eq!(only.len(), 1, "{health}");
    assert_eq!(only[0]["check"], "loop", "{health}");
    assert!(
        only[0]["detail"].as_str().is_some_and(|d| d.contains("has not run since")),
        "{health}"
    );

    std::fs::write(HEALTH_FILE, "{not json").unwrap();
    let health = host_health().await;
    assert_eq!(
        health["problems"],
        json!([{"check": "loop", "detail": "machine health file is not valid"}]),
        "{health}"
    );

    // No file: no loop on this machine, no field.
    std::fs::remove_file(HEALTH_FILE).unwrap();
    let health = host_health().await;
    assert!(health.get("problems").is_none(), "{health}");
}
