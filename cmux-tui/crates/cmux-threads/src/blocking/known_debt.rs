//! Known debt: blocking calls a planned task removes, tolerated where they
//! run today. Inside [`tolerate_known_debt`], a disallowed thread's call
//! that the row names is still a violation: it is recorded in the site table
//! like any other (the `server.blocking` list and the sweep keep it), but it
//! never panics, in any mode, as a lane-sync site never does. Every other
//! call is checked as before. Each row names the tasks that delete it; a new
//! row needs the same review as an [`super::AllowReason`].

use super::{BlockingKind, RestoreState, STATE, ThreadState, scoped_state};
use std::cell::Cell;

/// The rows: each is one kind of blocking work that is known to run on a
/// thread that disallows blocking, and the tasks that remove it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum KnownDebt {
    /// The daemon's durable stores (mutation receipts, registries, the
    /// session journal) on a connection's request handlers: a SQLite
    /// statement ([`BlockingKind::Sqlite`]), or the wait for the journal
    /// writer's commit of one ([`BlockingKind::Recv`] inside a
    /// [`store_receipt_wait`] only). p05-ipc-135 turns request-side writes
    /// into registry intents and p05-ipc-136 serves request-path reads from
    /// in-memory projections; this row goes with them.
    RequestPathStore,
}

impl KnownDebt {
    /// The stable report name.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::RequestPathStore => "request-path-store",
        }
    }
}

impl ThreadState {
    const fn tolerating(self, debt: KnownDebt) -> Self {
        match debt {
            KnownDebt::RequestPathStore => Self(self.0 | Self::TOLERATES_REQUEST_PATH_STORE),
        }
    }

    const fn in_store_receipt_wait(self) -> Self {
        Self(self.0 | Self::IN_STORE_RECEIPT_WAIT)
    }

    /// Whether a violation of `kind` here is tolerated known debt.
    pub(super) const fn tolerates(self, kind: BlockingKind) -> bool {
        if self.0 & Self::TOLERATES_REQUEST_PATH_STORE == 0 {
            return false;
        }
        match kind {
            BlockingKind::Sqlite => true,
            BlockingKind::Recv => self.0 & Self::IN_STORE_RECEIPT_WAIT != 0,
            _ => false,
        }
    }
}

/// Runs `f` with `debt` tolerated on this thread, then restores the previous
/// state. A [`super::with_blocking_disallowed`] or work-item scope inside `f`
/// does not keep it: the innermost scope wins.
pub fn tolerate_known_debt<R>(debt: KnownDebt, f: impl FnOnce() -> R) -> R {
    scoped_state(|state| state.tolerating(debt), f)
}

/// A wait for the journal writer's commit of a store write (its receipt),
/// until this drops: [`KnownDebt::RequestPathStore`] covers that wait and no
/// other receive. Outside that row's scope it changes nothing. A guard, not
/// a closure, so the wait's `#[track_caller]` site stays its caller's.
#[must_use = "the scope ends when the guard drops"]
pub struct StoreReceiptWait {
    _restore: RestoreState,
    _thread: std::marker::PhantomData<*const ()>,
}

impl StoreReceiptWait {
    pub fn enter() -> Self {
        let previous = STATE.with(Cell::get);
        STATE.with(|state| state.set(previous.in_store_receipt_wait()));
        Self { _restore: RestoreState(previous), _thread: std::marker::PhantomData }
    }
}

/// Whether `kind` is tolerated known debt on the current thread now.
#[cfg(test)]
fn is_tolerated(kind: BlockingKind) -> bool {
    STATE.with(Cell::get).tolerates(kind)
}

#[cfg(test)]
mod tests {
    use super::super::{
        AllowReason, BlockingMode, allow_blocking, assert_blocking_allowed, disallow_blocking,
        set_mode, snapshot, with_blocking_disallowed, with_mode,
    };
    use super::*;

    /// Runs `check` and returns whether it panicked.
    fn panics(check: impl FnOnce() + std::panic::UnwindSafe) -> bool {
        std::panic::catch_unwind(check).is_err()
    }

    /// In panic mode on a disallowed thread: a tolerated SQLite call and a
    /// store receipt wait are recorded as disallowed-thread sites and do not
    /// panic; a file call and a receive outside a store receipt wait in the
    /// same scope still panic; after the scope, SQLite panics again.
    #[test]
    fn known_debt_records_its_kinds_without_panicking_and_checks_the_rest() {
        set_mode(BlockingMode::Record);
        let (sqlite, receipt, panicked) = std::thread::spawn(|| {
            disallow_blocking();
            with_mode(BlockingMode::Panic, || {
                let (sqlite, receipt, fs, recv) =
                    tolerate_known_debt(KnownDebt::RequestPathStore, || {
                        let sqlite = line!() + 1;
                        assert_blocking_allowed(BlockingKind::Sqlite);
                        let wait = StoreReceiptWait::enter();
                        let receipt = line!() + 1;
                        assert_blocking_allowed(BlockingKind::Recv);
                        drop(wait);
                        let fs = panics(|| assert_blocking_allowed(BlockingKind::Fs));
                        let recv = panics(|| assert_blocking_allowed(BlockingKind::Recv));
                        (sqlite, receipt, fs, recv)
                    });
                let after = panics(|| assert_blocking_allowed(BlockingKind::Sqlite));
                (sqlite, receipt, [fs, recv, after])
            })
        })
        .join()
        .expect("tolerated debt does not panic");
        let snapshot = snapshot();
        for (line, kind) in [(sqlite, BlockingKind::Sqlite), (receipt, BlockingKind::Recv)] {
            let site = snapshot.site(file!(), line).expect("the tolerated call is recorded");
            assert_eq!(site.count, 1);
            assert!(!site.lane_sync, "a disallowed-thread violation, not a lane-sync wait");
            assert!(site.kinds.contains(kind));
        }
        if cfg!(debug_assertions) {
            assert_eq!(panicked, [true; 3], "file, bare receive, SQLite after the scope");
        }
    }

    /// Allowances and disallowing inside the scope keep the tolerance; an
    /// innermost disallowed scope drops it; a store receipt wait alone
    /// tolerates nothing.
    #[test]
    fn known_debt_survives_allowances_and_ends_in_a_disallowed_scope() {
        std::thread::spawn(|| {
            let wait = StoreReceiptWait::enter();
            assert!(!is_tolerated(BlockingKind::Recv), "no row, no tolerance");
            drop(wait);
            tolerate_known_debt(KnownDebt::RequestPathStore, || {
                disallow_blocking();
                assert!(is_tolerated(BlockingKind::Sqlite), "disallowing keeps it");
                allow_blocking(AllowReason::Shutdown, || {
                    assert!(is_tolerated(BlockingKind::Sqlite), "an allowance keeps it");
                });
                with_blocking_disallowed(|| {
                    assert!(!is_tolerated(BlockingKind::Sqlite), "the innermost scope wins");
                });
                assert!(!is_tolerated(BlockingKind::Fs), "only its own kinds");
                assert!(!is_tolerated(BlockingKind::Recv), "a receive only in a receipt wait");
            });
        })
        .join()
        .expect("test thread");
    }
}
