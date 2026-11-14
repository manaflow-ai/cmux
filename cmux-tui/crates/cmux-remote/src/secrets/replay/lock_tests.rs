use std::os::fd::AsFd as _;

use super::*;
use crate::lock_keeper_tests::{Keeper, free, scratch};

/// A request lets go of the state folder's lock, also while a child another daemon thread
/// started meanwhile keeps its descriptor: else the next request (or a new daemon's) waits
/// until that child exits.
#[test]
fn a_dropped_request_lock_is_free_while_a_child_keeps_its_descriptor() {
    let state = scratch("request");
    let held = lock(&state).unwrap();
    let keeper = Keeper::keep(held.0.as_fd());
    drop(held);
    let free = free(&state.join(FOLDER).join(".lock"));
    drop(keeper);
    let _ = std::fs::remove_dir_all(&state);
    assert!(free, "a dropped request lock stayed held through a child's copy");
}

/// A machine secrets write lets go of the applier's lock, also while a child another daemon
/// thread started meanwhile keeps its descriptor: else the next apply or request waits for
/// that child and past its budget answers `busy`.
#[test]
fn a_dropped_machine_config_lock_is_free_while_a_child_keeps_its_descriptor() {
    let home = scratch("machine-config");
    std::fs::create_dir_all(home.join(CONFIG_LOCK).parent().unwrap()).unwrap();
    let held = lock_machine_config(&home, std::time::Duration::from_secs(1)).unwrap().unwrap();
    let keeper = Keeper::keep(held.as_fd());
    drop(held);
    let free = free(&home.join(CONFIG_LOCK));
    drop(keeper);
    let _ = std::fs::remove_dir_all(&home);
    assert!(free, "a dropped machine config lock stayed held through a child's copy");
}
