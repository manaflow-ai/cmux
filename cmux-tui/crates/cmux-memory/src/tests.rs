//! The registry: change-only delivery, lossless before lossy, a new consumer
//! hears the current level, a dropped registration hears nothing more, the
//! level is the worst live vote.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use super::*;

type Log = Arc<Mutex<Vec<(String, PressureLevel)>>>;

fn consumer(name: &str, retention: Retention, log: &Log) -> MemoryConsumer {
    let (log, label) = (log.clone(), name.to_owned());
    MemoryConsumer::new(
        name,
        retention,
        || None,
        move |level| {
            log.lock().unwrap().push((label.clone(), level));
        },
    )
}

fn taken(log: &Log) -> Vec<(String, PressureLevel)> {
    std::mem::take(&mut *log.lock().unwrap())
}

fn entry(name: &str, level: PressureLevel) -> (String, PressureLevel) {
    (name.to_owned(), level)
}

#[test]
fn a_level_change_reaches_lossless_consumers_before_lossy_ones() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let voter = registry.voter();
    let _a = registry.register(consumer("lossy-a", Retention::Lossy, &log));
    let _b = registry.register(consumer("lossless-b", Retention::Lossless, &log));
    let _c = registry.register(consumer("lossless-c", Retention::Lossless, &log));
    assert!(taken(&log).is_empty(), "registering at normal delivers nothing");

    voter.set_level(PressureLevel::Critical);
    assert_eq!(
        taken(&log),
        [
            entry("lossless-b", PressureLevel::Critical),
            entry("lossless-c", PressureLevel::Critical),
            entry("lossy-a", PressureLevel::Critical),
        ]
    );
    assert_eq!(registry.level(), PressureLevel::Critical);
}

#[test]
fn a_repeated_level_delivers_nothing() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let voter = registry.voter();
    let _a = registry.register(consumer("a", Retention::Lossless, &log));
    voter.set_level(PressureLevel::Normal);
    voter.set_level(PressureLevel::Warning);
    voter.set_level(PressureLevel::Warning);
    voter.set_level(PressureLevel::Normal);
    voter.set_level(PressureLevel::Normal);
    assert_eq!(
        taken(&log),
        [entry("a", PressureLevel::Warning), entry("a", PressureLevel::Normal)]
    );
}

#[test]
fn a_consumer_that_registers_under_pressure_hears_the_level_at_once() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let voter = registry.voter();
    voter.set_level(PressureLevel::Warning);
    let _a = registry.register(consumer("a", Retention::Lossless, &log));
    assert_eq!(taken(&log), [entry("a", PressureLevel::Warning)]);
}

#[test]
fn a_dropped_registration_hears_nothing_more_and_leaves_the_report() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let voter = registry.voter();
    let a = registry.register(consumer("a", Retention::Lossless, &log));
    let _b = registry.register(consumer("b", Retention::Lossy, &log));
    drop(a);
    voter.set_level(PressureLevel::Critical);
    assert_eq!(taken(&log), [entry("b", PressureLevel::Critical)]);
    let names: Vec<_> = registry.report().into_iter().map(|line| line.name).collect();
    assert_eq!(names, ["b"]);
}

#[test]
fn the_report_reads_each_consumers_bytes_now() {
    let registry = MemoryRegistry::new();
    let voter = registry.voter();
    let bytes = Arc::new(AtomicU64::new(10));
    let _cache = registry.register(MemoryConsumer::new(
        "cache",
        Retention::Lossless,
        {
            let bytes = bytes.clone();
            move || Some(bytes.load(Ordering::Relaxed))
        },
        move |level| {
            if level != PressureLevel::Normal {
                bytes.store(0, Ordering::Relaxed);
            }
        },
    ));
    let _spare = registry.register(MemoryConsumer::new("spare", Retention::Lossy, || None, |_| {}));
    assert_eq!(
        registry.report(),
        [
            ConsumerReport {
                name: "cache".into(),
                retention: Retention::Lossless,
                bytes: Some(10)
            },
            ConsumerReport { name: "spare".into(), retention: Retention::Lossy, bytes: None },
        ]
    );
    voter.set_level(PressureLevel::Warning);
    assert_eq!(registry.report()[0].bytes, Some(0));
}

#[test]
fn a_panicking_consumer_does_not_stop_the_others() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let voter = registry.voter();
    let _bad = registry.register(MemoryConsumer::new(
        "bad",
        Retention::Lossless,
        || None,
        |_| panic!("consumer bug"),
    ));
    let _good = registry.register(consumer("good", Retention::Lossy, &log));
    voter.set_level(PressureLevel::Critical);
    assert_eq!(taken(&log), [entry("good", PressureLevel::Critical)]);
}

#[test]
fn a_consumer_may_drop_a_registration_while_it_hears_a_level() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let voter = registry.voter();
    let held: Arc<Mutex<Option<Registration>>> = Arc::default();
    let _dropper =
        registry.register(MemoryConsumer::new("dropper", Retention::Lossless, || None, {
            let held = held.clone();
            move |_| drop(held.lock().unwrap().take())
        }));
    *held.lock().unwrap() = Some(registry.register(consumer("victim", Retention::Lossy, &log)));
    voter.set_level(PressureLevel::Warning);
    // The victim was in this delivery's list; later levels skip it.
    taken(&log);
    voter.set_level(PressureLevel::Normal);
    assert!(taken(&log).is_empty());
    assert_eq!(registry.report().len(), 1);
}

#[test]
fn the_registry_outlives_nothing_it_does_not_own() {
    let registry = MemoryRegistry::new();
    let registration =
        registry.register(MemoryConsumer::new("a", Retention::Lossless, || None, |_| {}));
    drop(registry);
    // Dropping a registration after its registry is a no-op.
    drop(registration);
}

#[test]
fn the_level_is_the_worst_live_vote() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let _a = registry.register(consumer("a", Retention::Lossless, &log));
    let (kernel, app) = (registry.voter(), registry.voter());
    kernel.set_level(PressureLevel::Warning);
    app.set_level(PressureLevel::Critical);
    assert_eq!(registry.level(), PressureLevel::Critical);
    // The kernel's next change does not undo the app's critical vote.
    kernel.set_level(PressureLevel::Normal);
    assert_eq!(registry.level(), PressureLevel::Critical);
    kernel.set_level(PressureLevel::Warning);
    // The app's normal does not hide the kernel's warning.
    app.set_level(PressureLevel::Normal);
    assert_eq!(registry.level(), PressureLevel::Warning);
    assert_eq!(
        taken(&log),
        [
            entry("a", PressureLevel::Warning),
            entry("a", PressureLevel::Critical),
            entry("a", PressureLevel::Warning),
        ]
    );
}

#[test]
fn a_dropped_voter_withdraws_its_vote() {
    let (registry, log) = (MemoryRegistry::new(), Log::default());
    let _a = registry.register(consumer("a", Retention::Lossless, &log));
    let (kernel, app) = (registry.voter(), registry.voter());
    kernel.set_level(PressureLevel::Critical);
    app.set_level(PressureLevel::Warning);
    drop(kernel);
    assert_eq!(registry.level(), PressureLevel::Warning);
    drop(app);
    assert_eq!(registry.level(), PressureLevel::Normal);
    assert_eq!(
        taken(&log),
        [
            entry("a", PressureLevel::Critical),
            entry("a", PressureLevel::Warning),
            entry("a", PressureLevel::Normal),
        ]
    );
}

#[test]
fn a_voter_outlives_its_registry_harmlessly() {
    let registry = MemoryRegistry::new();
    let voter = registry.voter();
    drop(registry);
    voter.set_level(PressureLevel::Critical);
    drop(voter);
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
#[test]
fn other_systems_have_no_kernel_source() {
    assert!(matches!(MemoryRegistry::new().watch_system_pressure(), Err(WatchError::Unsupported)));
}
