//! The next log append on this thread writes only its first `kept` bytes and then fails as a
//! full disk does (`ENOSPC`), the partial write a full disk or a killed process leaves.

use std::cell::Cell;

thread_local!(static NEXT: Cell<Option<usize>> = const { Cell::new(None) });
thread_local!(static FAIL_CUT: Cell<bool> = const { Cell::new(false) });

pub(crate) fn partial(kept: usize) {
    NEXT.with(|n| n.set(Some(kept)));
}

/// `partial`, and the cut back after it fails too (the disk refuses the truncate).
pub(crate) fn partial_and_failed_cut(kept: usize) {
    partial(kept);
    FAIL_CUT.with(|f| f.set(true));
}

pub(super) fn take() -> Option<usize> {
    NEXT.with(Cell::take)
}

pub(super) fn take_cut_failure() -> bool {
    FAIL_CUT.with(|f| f.replace(false))
}
