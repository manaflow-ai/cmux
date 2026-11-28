use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

const READ: Duration = Duration::from_millis(300);

fn slow(reads: &AtomicUsize, rows: Value) -> SideRead {
    std::thread::sleep(READ);
    reads.fetch_add(1, Ordering::SeqCst);
    Some(Ok(vec![rows]))
}

/// Three reads of 300 ms each: the list waits about 300 ms (the slowest), not 900 ms.
#[test]
fn the_side_reads_wait_for_the_slowest_not_their_sum() {
    let reads = AtomicUsize::new(0);
    let started = Instant::now();
    let found = read_all(
        || slow(&reads, json!({"id": "cloud"})),
        || slow(&reads, json!({"id": "joined"})),
        || slow(&reads, json!({"id": "peer"})),
    );
    let waited = started.elapsed();
    assert_eq!(reads.load(Ordering::SeqCst), 3, "every side read ran once");
    eprintln!("machine list side reads: 3 x {READ:?} waited {waited:?}");
    assert!(
        waited < READ * 2,
        "the side reads waited {waited:?}, the sum of three {READ:?} reads, not the slowest"
    );
    assert_eq!(found.cloud, Some(Ok(vec![json!({"id": "cloud"})])));
    assert_eq!(found.joined, Some(Ok(vec![json!({"id": "joined"})])));
    assert_eq!(found.peers, Some(Ok(vec![json!({"id": "peer"})])));
}

/// The rows land in the order they did when the reads ran one after another; a read with
/// nothing to read and one that failed leave the list as it was.
#[test]
fn the_rows_land_in_their_order() {
    let global = GlobalArgs::default();
    let result = json!([{"id": "local"}]);
    let peer = json!({"name": "box", "connected": true});
    let reads = SideReads {
        cloud: None,
        joined: Some(Ok(vec![json!({"id": "joined"})])),
        peers: Some(Ok(vec![peer])),
    };
    let merged = apply(&global, result.clone(), reads);
    let ids: Vec<&str> =
        merged.as_array().unwrap().iter().map(|row| row["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["local", "joined", "box"]);

    let failed = SideReads {
        cloud: None,
        joined: Some(Err("platform down".into())),
        peers: Some(Err("acpmux did not answer".into())),
    };
    assert_eq!(apply(&global, result.clone(), failed), result);
}
