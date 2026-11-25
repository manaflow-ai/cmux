use super::*;

#[test]
fn care_passes_come_sooner_as_the_disk_fills() {
    assert!(spacing(Pressure::Normal) > spacing(Pressure::High));
    assert!(spacing(Pressure::High) > spacing(Pressure::Critical));
    assert_eq!(spacing(Pressure::Critical), 10 * MINUTE_MS);
}

#[test]
fn care_one_pass_at_a_time_and_the_flag_clears_on_unwind() {
    let flag = AtomicBool::new(false);
    let held = Running::claim(&flag).expect("free");
    assert!(Running::claim(&flag).is_none());
    drop(held);
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _held = Running::claim(&flag).expect("free again");
        panic!("a pass panics");
    }));
    assert!(caught.is_err());
    assert!(Running::claim(&flag).is_some(), "the panic cleared it");
}

/// #54378: a care pass that panicked ended the daemon's one cleanup worker for good. The
/// supervised worker starts again and takes a next wake (a second armed panic holds it there,
/// so the test runs no real pass over this machine's worktrees).
#[tokio::test]
async fn a_care_pass_that_panics_starts_the_worker_again() {
    let root = std::env::temp_dir().join(format!("acpmux-care-{}", uuid::Uuid::now_v7()));
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    crate::supervise::arm_panic("worktree care", "startup");
    crate::supervise::arm_panic("worktree care", "startup");
    let worker = hub.care_worker();
    // Each pass counts once per arming. The wake and its reason are process-wide, so a test
    // running beside this one may take the wake or change its reason: it is sent again until
    // the pass after the panic counts.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut again = false;
    while !again && std::time::Instant::now() < deadline {
        again = crate::supervise::passed(
            "worktree care",
            "startup",
            4,
            std::time::Duration::from_millis(200),
        )
        .await;
        if !again {
            *CARE.why.lock().unwrap_or_else(|e| e.into_inner()) = "startup";
            CARE.wake.notify_one();
        }
    }
    worker.abort();
    assert!(again, "the worker never ran again after its pass panicked");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
