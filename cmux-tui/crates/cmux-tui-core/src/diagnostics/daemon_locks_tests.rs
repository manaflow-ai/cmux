//! Caller and op scopes, the fixed-bucket lock histograms and the table
//! snapshot of `debug-daemon-locks`.

use std::time::Duration;

use super::*;

fn name(op: LockOp) -> String {
    format!("op{}", op.0)
}

#[test]
fn daemon_locks_scopes_nest_and_restore_the_outer_caller_and_op() {
    assert_eq!(current_scope(), (LockCaller::Program, LockOp::NONE));
    {
        let _caller = LockCallerScope::enter(LockCaller::Automation);
        let _op = LockOpScope::enter(LockOp(3));
        assert_eq!(current_scope(), (LockCaller::Automation, LockOp(3)));
        {
            let _inner = LockOpScope::enter(LockOp(4));
            let _frontend = LockCallerScope::enter(LockCaller::Frontend);
            assert_eq!(current_scope(), (LockCaller::Frontend, LockOp(4)));
        }
        assert_eq!(current_scope(), (LockCaller::Automation, LockOp(3)));
    }
    assert_eq!(current_scope(), (LockCaller::Program, LockOp::NONE));
}

#[test]
fn daemon_locks_slots_follow_the_thread_scope() {
    let table = DaemonLockTable::new();
    table.current().held(Duration::from_micros(40));
    {
        let _caller = LockCallerScope::enter(LockCaller::Frontend);
        let _op = LockOpScope::enter(LockOp(2));
        table.current().waited(Duration::from_micros(300));
        table.current().held(Duration::from_micros(10));
    }
    {
        let _caller = LockCallerScope::enter(LockCaller::Frontend);
        let _op = LockOpScope::enter(LockOp(5));
        table.current().held(Duration::from_micros(900));
    }
    let snapshot = table.snapshot("mux.state", &name);
    assert_eq!(snapshot.lock, "mux.state");
    let ops: Vec<(&str, &str, u64)> =
        snapshot.ops.iter().map(|row| (row.caller, row.op.as_str(), row.hold_us.count)).collect();
    // By total hold, longest first.
    assert_eq!(ops, [("frontend", "op5", 1), ("program", "op0", 1), ("frontend", "op2", 1)]);
    let frontend = &snapshot.callers[LockCaller::Frontend as usize];
    assert_eq!(frontend.caller, "frontend");
    assert_eq!(frontend.hold_us.count, 2, "the caller row merges its ops");
    assert_eq!(frontend.hold_us.max, 900);
    assert_eq!(frontend.wait_us.count, 1);
    assert_eq!(snapshot.callers[LockCaller::Automation as usize].hold_us.count, 0);
}

#[test]
fn daemon_locks_an_op_past_the_table_counts_in_its_last_slot() {
    let table = DaemonLockTable::new();
    let _op = LockOpScope::enter(LockOp(u16::MAX));
    table.current().held(Duration::from_micros(1));
    let snapshot = table.snapshot("mux.state", &name);
    assert_eq!(snapshot.ops.len(), 1);
    assert_eq!(snapshot.ops[0].op, format!("op{}", LOCK_OPS - 1));
}

#[test]
fn daemon_locks_histogram_percentiles_are_bucket_bounds_capped_at_max() {
    let histogram = LockHistogram::default();
    for micros in 1..=100 {
        histogram.record(Duration::from_micros(micros));
    }
    let snapshot = histogram.snapshot();
    assert_eq!(snapshot.count, 100);
    assert_eq!(snapshot.max, 100);
    assert_eq!(snapshot.mean, 50);
    // At most 25% above the true value, never above max.
    assert!((50..=63).contains(&snapshot.p50), "{snapshot:?}");
    assert!((95..=100).contains(&snapshot.p95), "{snapshot:?}");
    assert!((99..=100).contains(&snapshot.p99), "{snapshot:?}");

    // A sample past the top octave counts in the top bucket.
    let long = LockHistogram::default();
    long.record(Duration::from_secs(10_000));
    let snapshot = long.snapshot();
    assert_eq!(snapshot.count, 1);
    assert_eq!(
        snapshot.p99,
        snapshot.max.min(LogLinearHistogram::bucket_upper_bound(LOCK_BUCKETS - 1))
    );
}

#[test]
fn daemon_locks_a_free_acquisition_waits_zero_with_one_clock_read() {
    let slot = LockSlot::default();
    let before = lock_clock_reads();
    let ((), _, waited) = timed_acquire(&slot, || Some(()), || ());
    assert_eq!(waited, Duration::ZERO);
    assert_eq!(lock_clock_reads() - before, 1);

    let before = lock_clock_reads();
    let ((), _, waited) =
        timed_acquire(&slot, || None, || std::thread::sleep(Duration::from_millis(2)));
    assert!(waited >= Duration::from_millis(2), "{waited:?}");
    assert_eq!(lock_clock_reads() - before, 2, "a held lock reads before it blocks");
    assert_eq!(slot.wait.count(), 2);
}
