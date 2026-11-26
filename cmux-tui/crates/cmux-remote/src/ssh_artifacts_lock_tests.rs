//! The download cache's lock is let go by an unlock, not only by a close.

use std::os::fd::AsFd as _;

use super::*;
use crate::lock_keeper_tests::{Keeper, free, scratch};

/// A download lets go of the cache lock, also while a child another thread started meanwhile
/// keeps its descriptor: else another cmux-tui process's fetch of the same build waits until
/// that child exits.
#[test]
fn a_dropped_download_lock_is_free_while_a_child_keeps_its_descriptor() {
    let dir = scratch("download");
    let path = dir.join("cmux-tui-build.lock");
    let held = lock_download(&path).unwrap();
    let keeper = Keeper::keep(held.as_fd());
    drop(held);
    let free = free(&path);
    drop(keeper);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(free, "a dropped download lock stayed held through a child's copy");
}
