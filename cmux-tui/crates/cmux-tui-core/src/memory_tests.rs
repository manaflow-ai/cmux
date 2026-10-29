//! The app's memory limit in the daemon's registry: the
//! worse of the daemon's own level and the app's, the app's vote ending with
//! the client that set it, and the relay told once per change.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_memory::PressureLevel;

use super::*;

const APP: u64 = 7;

fn limit(level: PressureLevel) -> AppLimit {
    AppLimit { level, mode: SaverMode::Medium, pressure_override: None }
}

#[test]
fn memory_limit_packs_every_field_and_the_setter() {
    for level in [PressureLevel::Normal, PressureLevel::Warning, PressureLevel::Critical] {
        for mode in SaverMode::ALL {
            for pressure_override in [None, Some(PressureLevel::Warning)] {
                let limit = AppLimit { level, mode, pressure_override };
                let state = pack(APP << 20, limit);
                assert_eq!(unpack(state), Some(limit));
                assert_eq!(state >> SETTER_SHIFT, APP << 20);
            }
        }
    }
    assert_eq!(unpack(0), None, "zero is no limit");
}

#[test]
fn memory_limit_level_is_the_worse_of_the_daemons_and_the_apps() {
    let memory = DaemonMemory::with_stand_in_system_level(PressureLevel::Warning);
    memory.watch_system_pressure();
    assert_eq!(memory.registry().level(), PressureLevel::Warning);
    assert!(memory.set_app(APP, limit(PressureLevel::Normal)));
    assert_eq!(memory.registry().level(), PressureLevel::Warning, "the daemon's own level holds");
    assert!(memory.set_app(APP, limit(PressureLevel::Critical)));
    assert_eq!(memory.registry().level(), PressureLevel::Critical, "the app's is worse");
    assert!(!memory.set_app(APP, limit(PressureLevel::Critical)), "a repeat is no change");
    assert_eq!(memory.app_limit(), Some(limit(PressureLevel::Critical)));
}

#[test]
fn memory_limit_ends_with_the_client_that_set_it() {
    let memory = DaemonMemory::without_system_source();
    memory.set_app(APP, limit(PressureLevel::Critical));
    assert!(!memory.client_left(APP + 1), "another client's departure leaves it");
    assert_eq!(memory.registry().level(), PressureLevel::Critical);
    assert!(memory.client_left(APP));
    assert_eq!(memory.registry().level(), PressureLevel::Normal, "a daemon with no app");
    assert_eq!(memory.app_limit(), None);
    assert!(!memory.client_left(APP), "nothing left to clear");
}

#[test]
fn memory_limit_relay_hears_each_change_once() {
    let memory = DaemonMemory::without_system_source();
    let changes = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&changes);
    assert!(
        memory
            .relay_app_limit(Box::new(move || {
                counted.fetch_add(1, Ordering::SeqCst);
            }))
            .is_ok()
    );
    assert!(memory.relay_app_limit(Box::new(|| {})).is_err(), "one relay per registry");
    memory.set_app(APP, limit(PressureLevel::Warning));
    memory.set_app(APP, limit(PressureLevel::Warning));
    let aggressive = AppLimit { mode: SaverMode::Aggressive, ..limit(PressureLevel::Warning) };
    memory.set_app(APP, aggressive);
    memory.client_left(APP);
    assert_eq!(changes.load(Ordering::SeqCst), 3, "set, mode change, left; no repeat");
}
