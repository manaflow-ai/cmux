//! Terminal stream revision, snapshot pairing and resource-wait wake tests.

use super::*;

#[test]
fn read_only_terminal_access_does_not_signal_stream_progress() {
    let mux = Mux::new_for_test("terminal-read-progress", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let progress = &surface.as_pty().unwrap().stream_progress;
    let revision_before = progress.revision();

    assert_eq!(surface.with_terminal(|term| term.history_rows()), Some(0));
    assert_eq!(surface.try_with_terminal(|term| term.history_rows()).unwrap(), 0);

    assert_eq!(progress.revision(), revision_before);
}

#[test]
fn terminal_snapshot_cannot_pair_new_text_with_an_old_revision() {
    let mux = Mux::new_for_test("terminal-snapshot-boundary", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let progress = &surface.as_pty().unwrap().stream_progress;
    let revision_before = progress.revision();
    let (notify_started_tx, notify_started_rx) = sync_channel(1);
    let (release_notify_tx, release_notify_rx) = sync_channel(1);
    let release_notify = Arc::new(Mutex::new(release_notify_rx));
    progress.set_before_notify_hook(Some(Arc::new(move || {
        notify_started_tx.send(()).unwrap();
        release_notify
            .lock()
            .unwrap()
            .recv_timeout(Duration::from_secs(2))
            .expect("snapshot test did not release the notification boundary");
    })));

    let update_surface = surface.clone();
    let update = std::thread::spawn(move || {
        update_surface.apply_stream_output_for_test(b"new-output").unwrap();
    });
    notify_started_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("output did not reach the notification boundary");

    let (snapshot_entered_tx, snapshot_entered_rx) = sync_channel(1);
    let (snapshot_tx, snapshot_rx) = sync_channel(1);
    let snapshot_surface = surface.clone();
    let snapshot_revision_surface = snapshot_surface.clone();
    std::thread::spawn(move || {
        let snapshot = snapshot_surface
            .try_with_terminal(|terminal| {
                snapshot_entered_tx.send(()).unwrap();
                let text = terminal.viewport_text().unwrap();
                let revision = snapshot_revision_surface.terminal_stream_revision().unwrap();
                (text, revision)
            })
            .unwrap();
        snapshot_tx.send(snapshot).unwrap();
    });

    assert!(
        snapshot_entered_rx.recv_timeout(Duration::from_millis(250)).is_err(),
        "snapshot entered while output revision notification was still pending"
    );
    assert!(
        snapshot_rx.try_recv().is_err(),
        "snapshot returned while output revision notification was still pending"
    );

    release_notify_tx.send(()).unwrap();
    update.join().unwrap();
    snapshot_entered_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("snapshot did not run after the output boundary");
    let (text, revision) = snapshot_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("snapshot result was not delivered");
    assert!(text.contains("new-output"), "snapshot omitted applied output: {text:?}");
    assert!(revision > revision_before, "snapshot returned stale revision {revision}");
    progress.set_before_notify_hook(None);
}

#[cfg(unix)]
#[test]
fn hosted_replacement_publishes_revision_before_unlocking_terminal() {
    let mux = Mux::new_for_test("hosted-replacement-snapshot-boundary", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let progress = &surface.as_pty().unwrap().stream_progress;
    let revision_before = progress.revision();
    let (notify_started_tx, notify_started_rx) = sync_channel(1);
    let (release_notify_tx, release_notify_rx) = sync_channel(1);
    let release_notify_hook = Arc::new(Mutex::new(release_notify_rx));
    progress.set_before_notify_hook(Some(Arc::new(move || {
        notify_started_tx.send(()).unwrap();
        release_notify_hook
            .lock()
            .unwrap()
            .recv_timeout(Duration::from_secs(2))
            .expect("hosted replacement test did not release the notification boundary");
    })));

    let mut replacement = Terminal::new(81, 24, 10_000, Callbacks::default()).unwrap();
    replacement.resize(81, 24, 8, 16).unwrap();
    let update_surface = surface.clone();
    let update = std::thread::spawn(move || {
        let pty = update_surface.as_pty().unwrap();
        let mut geometry = pty.geometry.lock().unwrap();
        let next_geometry = PtyGeometry { cols: 81, ..*geometry };
        pty.with_terminal_stream_update(|term| {
            *term = replacement;
            *geometry = next_geometry;
            term.vt_write(b"host-replacement");
        });
    });
    notify_started_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("hosted replacement did not reach the notification boundary");

    let (snapshot_entered_tx, snapshot_entered_rx) = sync_channel(1);
    let (snapshot_tx, snapshot_rx) = sync_channel(1);
    let snapshot_surface = surface.clone();
    let snapshot_thread = std::thread::spawn(move || {
        let snapshot = snapshot_surface.terminal_screen_snapshot().unwrap();
        snapshot_entered_tx.send(()).unwrap();
        snapshot_tx.send((snapshot.text, snapshot.revision)).unwrap();
    });
    let entered_during_notify =
        snapshot_entered_rx.recv_timeout(Duration::from_millis(250)).is_ok();

    release_notify_tx.send(()).unwrap();
    update.join().unwrap();
    snapshot_thread.join().unwrap();
    assert!(
        !entered_during_notify,
        "hosted replacement unlocked terminal before revision publication"
    );
    let (text, revision) = snapshot_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("hosted replacement snapshot was not delivered");
    assert!(text.contains("host-replacement"), "snapshot omitted replacement text: {text:?}");
    assert!(revision > revision_before, "snapshot returned stale revision {revision}");
    progress.set_before_notify_hook(None);
}

#[test]
fn resource_wait_subscription_wakes_for_output_resize_reconnect_and_clear() {
    let mux = Mux::new_for_test("terminal-resource-progress", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let wake_deadline = || Some(Instant::now() + Duration::from_secs(1));

    let output = surface.subscribe_terminal_stream_change().unwrap();
    surface.apply_stream_output_for_test(b"progress-output").unwrap();
    assert!(output.wait_until(wake_deadline()), "terminal output did not wake the subscription");

    let resize = surface.subscribe_terminal_stream_change().unwrap();
    assert!(surface.resize(91, 37).unwrap(), "test resize did not change the surface");
    assert!(resize.wait_until(wake_deadline()), "terminal resize did not wake the subscription");

    let reconnect = surface.subscribe_terminal_stream_change().unwrap();
    surface.as_pty().unwrap().stream_progress.notify_reconnect();
    assert!(
        reconnect.wait_until(wake_deadline()),
        "authoritative reconnect progress did not wake the subscription"
    );

    surface.with_terminal(|term| {
        term.vt_write(b"\x1b]133;C\x07");
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"active-command");
    });
    let clear = surface.subscribe_terminal_stream_change().unwrap();
    surface.clear_history().unwrap();
    assert!(clear.wait_until(wake_deadline()), "terminal clear did not wake the subscription");
}

#[test]
fn stream_progress_rearms_expired_wait_when_output_races_final_release() {
    let progress = TerminalStreamProgress::default();
    let observed = progress.revision();
    let mut expired = progress.begin_clear_history_wait(Duration::ZERO);

    assert_eq!(progress.wait_for_change(observed, expired.deadline()), None);
    progress.notify();
    expired.mark_timed_out();
    drop(expired);

    let rearmed = progress.begin_clear_history_wait(Duration::from_secs(1));
    assert!(
        rearmed.deadline() > Instant::now(),
        "stream progress left the expired clear-history wait latched"
    );
}
