//! Loom model of control-socket admission: the real
//! `cmux-tui-core/src/diagnostics/connection_leases.rs` (`try_claim`,
//! `release`, `ConnectionLease`, `reclaim_hung_up`), included through
//! `#[path]` and built with loom's atomics under `--cfg loom`. The
//! `ConnectionStats` fields here are those of `diagnostics.rs`.
//!
//! Invariants, in every interleaving loom runs:
//! - no more than `limit` slots are held (`active <= limit`), and the
//!   hung-up pool never passes the limit;
//! - claims that succeed while every lease is held never pass the limit;
//! - a hung-up client's slot is taken back once, never twice, when two
//!   accept loops reclaim it at once;
//! - when every lease is gone, `active == 0` and `hung_up == 0`: no slot
//!   leaks and no count wraps below zero, whichever thread drops a lease last
//!   (its owner, or a reclaim that upgraded it).
//!
//! Run: `RUSTFLAGS='--cfg loom' cargo test --release -p cmux-tui-loom --test admission`.
#![cfg(loom)]

use loom::sync::atomic::AtomicU64;

/// `diagnostics.rs` `ConnectionStats`: the fields connection_leases.rs uses.
pub struct ConnectionStats {
    active: AtomicU64,
    peak: AtomicU64,
    refused: AtomicU64,
    accepted: AtomicU64,
    hung_up: AtomicU64,
    reclaimed: AtomicU64,
    leases: std::sync::Mutex<Vec<std::sync::Weak<ConnectionLease>>>,
}

impl ConnectionStats {
    fn new() -> Self {
        Self {
            active: AtomicU64::new(0),
            peak: AtomicU64::new(0),
            refused: AtomicU64::new(0),
            accepted: AtomicU64::new(0),
            hung_up: AtomicU64::new(0),
            reclaimed: AtomicU64::new(0),
            leases: std::sync::Mutex::new(Vec::new()),
        }
    }
}

#[path = "../../../crates/cmux-tui-core/src/diagnostics/connection_leases.rs"]
#[allow(dead_code)]
mod connection_leases;
use connection_leases::{ConnectionLease, PeerClosed};

use std::sync::Arc;

use loom::sync::atomic::{AtomicBool, Ordering};
use loom::thread;

fn explore(model: impl Fn() + Sync + Send + 'static) {
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(3);
    builder.check(model);
}

/// A claim as the accept loop makes it (`bounded_outbound.rs`
/// `claim_connection_watching`): the lease only when `try_claim` gave a slot.
fn claim(
    stats: &Arc<ConnectionStats>,
    limit: u64,
    peer: Option<PeerClosed>,
) -> Option<Arc<ConnectionLease>> {
    stats.try_claim(limit).then(|| ConnectionLease::new(stats.clone(), peer))
}

fn check_bounds(stats: &ConnectionStats, limit: u64) {
    let active = stats.active.load(Ordering::SeqCst);
    let hung_up = stats.hung_up.load(Ordering::SeqCst);
    assert!(active <= limit, "active {active} past the limit {limit}");
    assert!(hung_up <= limit, "hung_up {hung_up} past the limit {limit}");
}

fn check_drained(stats: &ConnectionStats) {
    assert_eq!(stats.active.load(Ordering::SeqCst), 0, "a slot leaked or wrapped");
    assert_eq!(stats.hung_up.load(Ordering::SeqCst), 0, "a hung-up place leaked or wrapped");
}

#[test]
fn concurrent_claims_never_pass_the_limit() {
    explore(|| {
        let limit = 2;
        let stats = Arc::new(ConnectionStats::new());
        let threads: Vec<_> = (0..3)
            .map(|_| {
                let stats = stats.clone();
                thread::spawn(move || {
                    let lease = claim(&stats, limit, None);
                    check_bounds(&stats, limit);
                    lease
                })
            })
            .collect();
        let leases: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
        // Every lease is still held at the join, so exactly `limit` claims win.
        let held = leases.iter().filter(|l| l.is_some()).count() as u64;
        assert_eq!(held, limit, "{held} leases held at once with the limit {limit}");
        let refused = stats.refused.load(Ordering::SeqCst);
        assert_eq!(held + refused, 3, "a claim was neither served nor refused");
        drop(leases);
        check_drained(&stats);
    });
}

#[test]
fn two_accept_loops_take_back_one_hung_up_slot_once() {
    explore(|| {
        let limit = 1;
        let stats = Arc::new(ConnectionStats::new());
        let closed = Arc::new(AtomicBool::new(false));
        let peer: PeerClosed = {
            let closed = closed.clone();
            Box::new(move || closed.load(Ordering::SeqCst))
        };
        let first = claim(&stats, limit, Some(peer)).expect("an empty session serves");
        // The client hangs up; its thread (this lease) still runs.
        closed.store(true, Ordering::SeqCst);
        let threads: Vec<_> = (0..2)
            .map(|_| {
                let stats = stats.clone();
                thread::spawn(move || {
                    let lease = claim(&stats, limit, None);
                    check_bounds(&stats, limit);
                    lease
                })
            })
            .collect();
        let leases: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
        let served = leases.iter().filter(|l| l.is_some()).count();
        assert_eq!(served, 1, "one hung-up slot served {served} clients");
        assert!(first.is_hung_up(), "the served client did not take the hung-up slot");
        assert_eq!(stats.reclaimed.load(Ordering::SeqCst), 1, "the slot was taken back twice");
        drop(leases);
        drop(first);
        check_drained(&stats);
    });
}

#[test]
fn a_lease_dropped_during_its_reclaim_frees_one_place() {
    explore(|| {
        let limit = 1;
        let stats = Arc::new(ConnectionStats::new());
        let closed = Arc::new(AtomicBool::new(true));
        let peer: PeerClosed = {
            let closed = closed.clone();
            Box::new(move || closed.load(Ordering::SeqCst))
        };
        let first = claim(&stats, limit, Some(peer)).expect("an empty session serves");
        // The owner's thread ends while an accept loop reclaims its slot.
        let owner = thread::spawn(move || drop(first));
        let accept = {
            let stats = stats.clone();
            thread::spawn(move || {
                let lease = claim(&stats, limit, None);
                check_bounds(&stats, limit);
                lease
            })
        };
        owner.join().unwrap();
        let lease = accept.join().unwrap();
        check_bounds(&stats, limit);
        drop(lease);
        check_drained(&stats);
    });
}
