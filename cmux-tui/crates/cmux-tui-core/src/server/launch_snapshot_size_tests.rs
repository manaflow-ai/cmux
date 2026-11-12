//! A launch snapshot over its bound keeps the window state (P-AUSTIN B9 row
//! 15). Before, a snapshot over 8 MiB was written again with no projections
//! and no sidebar document, and nothing said so: the app's first frame lost
//! the last layout although the window state was small.

use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

fn put(mux: &Arc<Mux>, subject: &str, projection: Value) {
    run(
        mux,
        json!({"cmd":"put-frontend-projection","frontend":"cmux-next","scope":"personal",
               "subject_key":subject,"schema_version":1,"projection":projection,
               "origin":"test","mutation_id":format!("size-{subject}")}),
    );
}

#[test]
fn an_oversized_launch_snapshot_keeps_the_window_state() {
    let root = std::env::temp_dir().join(format!(
        "cmux-launch-snapshot-size-{}-{}",
        std::process::id(),
        unique_nanos()
    ));
    let mux =
        Mux::open_persistent("launch-snapshot-size", SurfaceOptions::default(), &root).unwrap();
    put(&mux, "windows", json!({"windows":[{"id":"w1","workspace_keys":[]}]}));
    // Nine other projections just under 1 MiB each: together over the 8 MiB bound.
    for index in 0..9 {
        put(&mux, &format!("bulk-{index}"), json!({"pad":"x".repeat(1_000_000)}));
    }
    let path = root.join(LAUNCH_SNAPSHOT_FILE);
    let _written = write_launch_snapshot(&mux, &path).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    assert!(bytes.len() <= MAX_LAUNCH_SNAPSHOT_BYTES);
    let snapshot: Value = serde_json::from_slice(&bytes).unwrap();
    let subjects: Vec<&str> = snapshot["frontend_projections"]
        .as_array()
        .map(|projections| {
            projections.iter().filter_map(|projection| projection["subject_key"].as_str()).collect()
        })
        .unwrap_or_default();
    assert!(
        subjects.contains(&"windows"),
        "the window state is left out of an oversized snapshot: {subjects:?}"
    );
    assert!(subjects.len() > 1, "only as many projections as needed are left out: {subjects:?}");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// A stamp for a temporary name that no other call in this process gets: the clock's nanoseconds,
/// moved past the last stamp when two calls read the same nanosecond. Parallel tests did, and one
/// then used or deleted the other's folder ("File exists", a fixture gone mid-test).
fn unique_nanos() -> u128 {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX));
    let (Ok(last) | Err(last)) =
        LAST.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| Some(now.max(last + 1)));
    u128::from(now.max(last + 1))
}
