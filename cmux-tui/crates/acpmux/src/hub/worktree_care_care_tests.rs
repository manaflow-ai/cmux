use super::*;

#[test]
fn care_passes_come_sooner_as_the_disk_fills() {
    use cmux_worktree_care::budget::spacing_ms;
    assert!(spacing_ms(0.5) > spacing_ms(0.75));
    assert!(spacing_ms(0.75) > spacing_ms(0.85));
    assert!(spacing_ms(0.85) > spacing_ms(0.95));
    assert_eq!(spacing_ms(0.95), 3 * 60_000);
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

/// hq#13316: the journal had only the pass's total for 14 removed
/// checkouts. Each removal is its own line, from the report as
/// `care_run` serializes it; what stays, is trimmed or failed to go
/// has none.
#[test]
fn care_each_removed_worktree_is_one_log_line_with_its_reason_idle_age_and_archive() {
    use cmux_worktree_care::pass::{Item, Outcome, Report};
    use cmux_worktree_care::{Action, Pressure, Verdict};
    let item = |path: &str, action, reason: &str, outcome| Item {
        path: path.into(),
        repository: "/m/cmux.git".into(),
        branch: None,
        verdict: Verdict { action, reason: reason.into(), idle_ms: Some(25 * 60 * MINUTE_MS) },
        facts: None,
        bytes: None,
        outcome,
    };
    let done = |archive: &str| {
        Some(Outcome { ok: true, freed: 1_359_519_744, archive: Some(archive.into()), error: None })
    };
    let report = Report {
        disk: None,
        pressure: Pressure::High,
        applied: true,
        items: vec![
            item(
                "/c/lane--a",
                Action::Reclaim,
                "everything pushed; idle 25 h",
                done("1794973645972-lane--a"),
            ),
            item("/c/lane--b", Action::Keep, "owner session loop is open", None),
            item("/c/lane--c", Action::Trim, "idle 25 h", done("unused")),
            item(
                "/c/lane--d",
                Action::Archive,
                "1 unpushed commits; idle 25 h",
                Some(Outcome {
                    ok: false,
                    freed: 0,
                    archive: None,
                    error: Some("it changed since the scan".into()),
                }),
            ),
        ],
        freed: 1_359_519_744,
        reclaimable: 0,
        errors: Vec::new(),
        expired: Vec::new(),
    };
    assert_eq!(
        removals(&serde_json::to_value(&report).unwrap()),
        vec![
            "worktree removed: /c/lane--a (reclaim: everything pushed; idle 25 h); idle 25 h; \
                 archive 1794973645972-lane--a; freed 1359519744 bytes"
                .to_string()
        ]
    );
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
