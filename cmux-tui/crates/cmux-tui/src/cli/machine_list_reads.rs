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
#[path = "machine_list_reads_tests.rs"]
mod tests;
