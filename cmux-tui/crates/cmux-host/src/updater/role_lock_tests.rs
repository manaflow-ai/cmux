use super::*;
use crate::updater::gate::tests::{end, forked_keeper};

/// The updater's lock is free once a commit or rollback lets go, also while a child the
/// service forked meanwhile still has the descriptor: else the next check fails with
/// "another update check runs".
#[test]
fn a_dropped_updater_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let lock = Lock::take(&paths, false).expect("a free updater lock");
    assert!(Lock::take(&paths, false).is_none(), "the lock is held");
    let child = forked_keeper();
    drop(lock);
    let again = Lock::take(&paths, false);
    end(child);
    assert!(again.is_some(), "a dropped updater lock stayed held through a forked child's copy");
}
