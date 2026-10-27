//! Waits judged after they end: a lock or condition-variable wait over its
//! budget on a thread that may not make it ([`crate::sync`]).

use super::{BlockingKind, Cell, Location, SITES, STATE, note_violation, report};

/// Whether the current thread may not make a `kind` call now (its
/// allowance applied): one TLS read.
#[inline]
pub(crate) fn denies(kind: BlockingKind) -> bool {
    !STATE.with(Cell::get).permits(kind)
}

/// Records a `kind` site at `location` for a wait over its budget that
/// already ended on a thread that [`denies`] `kind` ([`crate::sync`] lock
/// and condition-variable waits). Record only, in every mode: the waiter
/// holds the guard now, and a panic would poison the lock for every thread.
#[cold]
#[inline(never)]
pub(crate) fn note_long_wait(kind: BlockingKind, location: &'static Location<'static>) {
    let lane_sync = !STATE.with(Cell::get).disallowed();
    note_violation(&SITES, report::site_report(), kind, location, lane_sync);
}
