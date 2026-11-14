//! SignaledMutex hold and wait telemetry.

use super::*;

#[test]
fn signaled_mutex_records_holder_site_wait_and_hold() {
    let mutex = SignaledMutex::new(0u32);
    assert!(mutex.stats().snapshot().holder.is_none());
    {
        let lock_line = line!() + 1;
        let mut guard = mutex.lock().unwrap();
        *guard += 1;
        let snapshot = mutex.stats().snapshot();
        let holder = snapshot.holder.expect("held lock reports its holder");
        assert!(
            holder.site.ends_with(&format!("signaled_mutex.rs:{lock_line}")),
            "{}",
            holder.site
        );
    }
    let snapshot = mutex.stats().snapshot();
    assert!(snapshot.holder.is_none());
    assert_eq!(snapshot.hold_us.count, 1);
    assert_eq!(snapshot.wait_us.count, 1);
    assert_eq!(snapshot.top_sites.len(), 1);
    assert_eq!(snapshot.top_sites[0].acquisitions, 1);

    // A waiter that outlasts the stall threshold names the site that
    // held the lock when its wait began.
    let mutex = Arc::new(SignaledMutex::new(0u32));
    let held = mutex.clone();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
    let holder = std::thread::spawn(move || {
        let _guard = held.lock().unwrap();
        held_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    held_rx.recv().unwrap();
    let waiter = mutex.clone();
    let waiting = std::thread::spawn(move || {
        let _guard = waiter.lock_until(Instant::now() + Duration::from_secs(5)).unwrap();
    });
    std::thread::sleep(crate::diagnostics::LOCK_STALL_THRESHOLD + Duration::from_millis(20));
    release_tx.send(()).unwrap();
    holder.join().unwrap();
    waiting.join().unwrap();
    let snapshot = mutex.stats().snapshot();
    assert_eq!(snapshot.stalls, 1, "{snapshot:?}");
    let stall = snapshot.last_stall.expect("stall recorded");
    assert!(
        stall.blocker.as_deref().is_some_and(|site| site.contains("signaled_mutex.rs:")),
        "{stall:?}"
    );
    assert!(stall.waited_us >= 100_000);
}

#[test]
fn signaled_mutex_records_failed_wait_telemetry() {
    let mutex = Arc::new(SignaledMutex::new(0u32));
    let held = mutex.clone();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
    let holder = std::thread::spawn(move || {
        let _guard = held.lock().unwrap();
        held_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    held_rx.recv().unwrap();

    let deadline =
        Instant::now() + crate::diagnostics::LOCK_STALL_THRESHOLD + Duration::from_millis(20);
    assert!(mutex.lock_until(deadline).is_err());
    release_tx.send(()).unwrap();
    holder.join().unwrap();

    let snapshot = mutex.stats().snapshot();
    assert_eq!(snapshot.wait_us.count, 2, "failed wait must enter wait histogram");
    assert_eq!(snapshot.hold_us.count, 1, "failed wait must not report a hold");
    assert_eq!(snapshot.stalls, 1, "failed stall must be visible");
    assert!(snapshot.last_stall.is_some());
}

#[test]
fn lock_detail_reports_per_site_hold_and_wait_percentiles() {
    let mutex = SignaledMutex::new(0u32);
    let short_line = line!() + 2;
    for _ in 0..99 {
        drop(mutex.lock().unwrap());
    }
    let long_line = line!() + 1;
    let guard = mutex.lock().unwrap();
    std::thread::sleep(Duration::from_millis(20));
    drop(guard);

    let detail = mutex.stats().detail();
    assert_eq!(detail.sites, 2, "{detail:?}");
    let short = detail
        .by_hold_total
        .iter()
        .find(|site| site.site.ends_with(&format!("signaled_mutex.rs:{short_line}")))
        .expect("short site listed");
    assert_eq!(short.acquisitions, 99);
    let long = &detail.by_hold_p99[0];
    assert!(long.site.ends_with(&format!("signaled_mutex.rs:{long_line}")), "{detail:?}");
    assert_eq!(long.acquisitions, 1);
    assert!(long.hold_p99_us >= 10_000 && long.hold_p99_us <= long.hold_max_us, "{long:?}");
    assert!(long.hold_max_us >= 20_000, "{long:?}");
}

/// A pass that takes the registry lock many times in a row (the journal retention pass) gives a waiting locker its
/// turn at each gap. The mutex alone does not: the thread that released it takes it again before the locker that the
/// release woke. No timing: the test asks at each gap how many lockers waited, and when one did, its hold is the
/// last one before the pass has the lock again. It proves that for the gaps where `give_way_to_waiters` reports a
/// waiter: a run in which no gap had one (the count it prints is 0) proves only the order of the holds.
#[test]
fn a_waiter_that_give_way_reports_gets_the_registry_lock_before_the_next_hold() {
    const ROUNDS: usize = 200;
    let mutex = Arc::new(SignaledMutex::new(Vec::<(&'static str, usize)>::new()));
    assert_eq!(mutex.give_way_to_waiters(), 0, "no locker waits, so the pass does not wait");
    let (go, rounds) = std::sync::mpsc::channel::<usize>();
    let waiter = {
        let mutex = mutex.clone();
        std::thread::spawn(move || {
            for round in rounds {
                mutex.lock().unwrap().push(("waiter", round));
            }
        })
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut gaps_with_a_waiter = 0;
    let mut guard = mutex.lock().unwrap();
    for round in 0..ROUNDS {
        guard.push(("pass", round));
        // The pass holds the lock, so the waiter of this round does not have it yet.
        go.send(round).unwrap();
        loop {
            drop(guard);
            let waited = mutex.give_way_to_waiters();
            guard = mutex.lock().unwrap();
            let had_its_turn = guard.last() == Some(&("waiter", round));
            if waited > 0 {
                gaps_with_a_waiter += 1;
                assert!(
                    had_its_turn,
                    "round {round}: a locker waited at the gap and the pass took the lock again before it: {:?}",
                    &guard[guard.len().saturating_sub(4)..]
                );
            }
            if had_its_turn {
                break;
            }
            // The other thread did not ask for the lock yet.
            assert!(Instant::now() < deadline, "round {round}: the waiter never got the lock");
            std::thread::yield_now();
        }
    }
    let holds = guard.clone();
    drop(guard);
    drop(go);
    waiter.join().unwrap();
    let expected =
        (0..ROUNDS).flat_map(|round| [("pass", round), ("waiter", round)]).collect::<Vec<_>>();
    assert_eq!(holds, expected, "each hold of the pass has one hold of the waiter after it");
    // On a host with one core the waiter can take its turn while the pass does not run; the gaps where it did wait
    // are the ones this test is about.
    eprintln!("GIVE_WAY gaps_with_a_waiter={gaps_with_a_waiter} of {ROUNDS}");
}

/// A writer that panics in the middle of a change leaves half-made routing tables. They are never published (the
/// guard drops during the unwind, then the mutex is poisoned), so the input lane keeps routing by the last finished
/// change (R-DAEMON-STATE stage S1).
#[test]
fn routes_of_a_change_cut_short_by_a_panic_are_never_published() {
    let state = test_mux().with_state(State::clone);
    let mutex = super::super::signaled_mutex::StateMutex::new(state, true);
    let before = arc_swap::Guard::into_inner(mutex.routes());
    let terminal = TerminalPublicId::parse("term_00000000000000000000000000000077").unwrap();
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut state = mutex.lock().unwrap_or_else(PoisonError::into_inner);
        state.terminal_catalog_by_runtime.insert(9_999_999, terminal);
        panic!("a writer panics in the middle of a change");
    }));
    let after = arc_swap::Guard::into_inner(mutex.routes());
    assert!(Arc::ptr_eq(&before, &after), "the routes of the half-made change were published");
}

/// On a poisoned session state the creating-input checks answer from the state, as the old path did, never from the
/// published routes: a create whose commit panicked after it put its terminal in the state publishes no routes, so
/// the routes would call that terminal unknown (#34174 review: the poison check of 3b2e29f1389 had no test).
#[cfg(unix)]
#[test]
fn a_poisoned_session_state_answers_the_creating_input_checks_from_the_state() {
    let mux = test_mux();
    mux.set_input_lane_for_test(true);
    let identity = TerminalHostIdentity {
        terminal_id: TerminalId::random().unwrap().to_hex(),
        incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
    };
    let terminal = Surface::exited_terminal_placeholder(
        9_999_998,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        identity.clone(),
    )
    .unwrap();
    assert!(!mux.knows_terminal_input_target(&identity.terminal_id), "known before its commit");
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut state = mux.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.surfaces.insert(terminal.id, terminal.clone());
        // crash-allow: test-only panic to poison the session state in the middle of a change.
        panic!("a create's commit panics after it put its terminal in the state");
    }));
    assert!(mux.state.is_poisoned(), "the session state is poisoned");
    assert!(
        mux.knows_terminal_input_target(&identity.terminal_id),
        "a poisoned state answered from the published routes, which lack the terminal its state holds"
    );
}
