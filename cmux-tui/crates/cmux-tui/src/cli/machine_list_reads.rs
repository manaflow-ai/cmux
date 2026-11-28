//! `machine list`'s three side reads, which join the daemon's rows: the app's Cloud
//! machines (up to 1 s), the team's joined machines from the platform (up to 3 s) and
//! the machines acpmux reaches itself (up to 5 s). None needs another's answer, so they
//! run at once: the list waits for the slowest, never for their sum. Their rows and
//! notes land in the same order as when they ran one after another.

use serde_json::Value;

use super::GlobalArgs;

/// One side read: its rows, why they could not be read, or `None` (nothing to read here).
pub(super) type SideRead = Option<Result<Vec<Value>, String>>;

/// What the three side reads found.
pub(super) struct SideReads {
    pub(super) cloud: SideRead,
    pub(super) joined: SideRead,
    pub(super) peers: SideRead,
}

/// The daemon's `machine.list` result with the app's Cloud machines, the team's joined
/// machines and acpmux's own machines added (each a `cmux chat --on` target).
pub(super) fn merge(global: &GlobalArgs, result: Value) -> Value {
    let reads = read_all(
        || super::cloud_machines::read(global),
        super::machine_join::read_joined,
        super::machine_join::read_peers,
    );
    apply(global, result, reads)
}

/// Runs the three reads at once and waits for all of them: two on scoped threads, the
/// third on this one. Each read keeps its own bound, so the wait is the slowest's.
pub(super) fn read_all<C, J, P>(cloud: C, joined: J, peers: P) -> SideReads
where
    C: FnOnce() -> SideRead + Send,
    J: FnOnce() -> SideRead + Send,
    P: FnOnce() -> SideRead,
{
    std::thread::scope(|scope| {
        let cloud = scope.spawn(cloud);
        let joined = scope.spawn(joined);
        let peers = peers();
        // A read that panicked panics the list, as it did when the reads ran in turn.
        let cloud = cloud.join().unwrap_or_else(|panic| std::panic::resume_unwind(panic));
        let joined = joined.join().unwrap_or_else(|panic| std::panic::resume_unwind(panic));
        SideReads { cloud, joined, peers }
    })
}

/// `result` with each read's rows added, in the order they always were.
fn apply(global: &GlobalArgs, mut result: Value, reads: SideReads) -> Value {
    if let Some(cloud) = reads.cloud {
        result = super::cloud_machines::apply(global, result, cloud);
    }
    if let Some(joined) = reads.joined {
        result = super::machine_join::apply_joined(result, joined);
    }
    if let Some(peers) = reads.peers {
        result = super::machine_join::apply_peers(global, result, peers);
    }
    result
}

#[cfg(test)]
mod tests {
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
}
