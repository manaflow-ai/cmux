//! The terminal publisher (`mux/terminal_publisher.rs`, #35413): an output reader queues the durable commits its
//! output asks for and never waits for the workspace registry; the publisher still commits each of them, in output
//! order, once the registry is free.

use std::sync::mpsc::sync_channel;

use super::*;

/// Holds `mux`'s workspace registry on another thread until the returned sender fires.
fn hold_registry(mux: &Arc<Mux>) -> (SyncSender<()>, std::thread::JoinHandle<()>) {
    let (entered, held) = sync_channel(1);
    let (release, released): (SyncSender<()>, Receiver<()>) = sync_channel(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.hold_workspace_registry_for_test(entered, released))
    };
    held.recv_timeout(Duration::from_secs(10)).expect("the holder took the workspace registry");
    (release, holder)
}

fn wait_for(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// A terminal's output made its "last output" fact due. Queuing the publication returns at once while the
/// registry is held, nothing commits until the registry is free, and then the publication commits a revision.
#[test]
fn a_queued_publication_commits_once_the_registry_is_free() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    // What the creation left pending (its launch directory) is published first.
    surface.publish_pending_directory();
    surface.publish_pending_progress();
    let before = mux.with_state(|state| state.resource_revision);
    surface.apply_stream_output_for_test(b"output").unwrap();

    let (release, holder) = hold_registry(&mux);
    let queued = Instant::now();
    surface.queue_pending_publications();
    let queue_time = queued.elapsed();
    std::thread::sleep(Duration::from_millis(50));
    let while_held = mux.with_state(|state| state.resource_revision);
    release.send(()).unwrap();
    holder.join().unwrap();

    assert!(queue_time < Duration::from_secs(1), "queuing waited {queue_time:?} for the registry");
    assert_eq!(while_held, before, "a publication committed while the registry was held");
    wait_for("the queued publication committed", || {
        mux.with_state(|state| state.resource_revision) > before
    });
    // The publisher took the change: nothing is due any more.
    surface.queue_pending_publications();
    let after = mux.with_state(|state| state.resource_revision);
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(
        mux.with_state(|state| state.resource_revision),
        after,
        "a publication with nothing due committed again"
    );
}

/// The notifications a terminal's output posts and a bell's attention mark are durable notifications too: the
/// reader queues them, and they post in output order once the registry is free.
#[test]
fn queued_terminal_notifications_post_in_order_once_the_registry_is_free() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let notification = |title: &str| crate::terminal_metadata::TerminalNotification {
        title: title.into(),
        body: String::new(),
        level: NotificationLevel::Info,
    };
    let titles = || {
        let mut titles = mux
            .resource_notifications(16)
            .into_iter()
            .map(|notification| notification.title)
            .collect::<Vec<_>>();
        titles.reverse();
        titles
    };

    let (release, holder) = hold_registry(&mux);
    let queued = Instant::now();
    // The bell first: a bell posts no mark while the terminal has an unread notification.
    mux.queue_bell_notification(surface.id);
    mux.queue_terminal_notifications(
        surface.id,
        vec![notification("first"), notification("second")],
    );
    mux.queue_terminal_notifications(surface.id, vec![notification("third")]);
    let queue_time = queued.elapsed();
    std::thread::sleep(Duration::from_millis(50));
    let while_held = titles();
    release.send(()).unwrap();
    holder.join().unwrap();

    assert!(queue_time < Duration::from_secs(1), "queuing waited {queue_time:?} for the registry");
    assert!(
        while_held.is_empty(),
        "notifications posted while the registry was held: {while_held:?}"
    );
    wait_for("the queued notifications posted", || titles().len() == 4);
    assert_eq!(titles(), ["Bell", "first", "second", "third"]);
}

/// #35765 review: a hosted terminal's exit commits the directory its shell reported last, as the reader did when it
/// published inline before it handled the host's Exit frame. A publication that the reader queued and the publisher
/// runs after the exit commits nothing (an ended terminal settles without publishing), so `cd x; exit` kept the old
/// directory on the exited tab, in its exit record and for its restart.
#[cfg(unix)]
#[test]
fn a_terminal_exit_commits_the_directory_its_shell_reported_last() {
    const TERMINAL: &str = "00000000000040008000000000035765";
    const INCARNATION: &str = "10000000000040008000000000035765";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("exit-cwd".into()),
            Some("018f6e21-7b70-7e70-8000-000000035765".into()),
            None,
        )
        .unwrap();
    let surface_id = mux
        .seed_running_terminal_with_on_exit_for_test(
            TERMINAL,
            INCARNATION,
            &workspace.key,
            TerminalOnExit::Keep,
        )
        .unwrap();
    let surface = mux.surface(surface_id).expect("the seeded terminal");
    let dir = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    let dir_text = dir.to_string_lossy().into_owned();
    {
        // The shell's last report reaches the reader, which queues its publication; the host's Exit frame is next.
        let _held = mux.hold_terminal_publisher_for_test();
        surface.set_test_pwd(Some(format!("file://localhost{dir_text}")));
        surface.queue_pending_publications();
        mux.surface_exited(surface_id);
    }
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(10)),
        "the publisher did not finish"
    );
    assert_eq!(
        surface.presented_directory().as_deref(),
        Some(dir_text.as_str()),
        "the exited terminal kept the directory from before its shell's last report"
    );
}

/// #35765 review 3 (should-fix 2): a notification a terminal's last output asked for posts before the terminal's
/// exit commits, as the reader posted it before it handled the exit, and once. Queued for the terminal publisher, it
/// posted after the exit (here: only once the held publisher ran), so a client saw the terminal end before the
/// notification its last output raised.
#[cfg(unix)]
#[test]
fn a_notification_queued_before_an_exit_posts_before_the_exit() {
    const TERMINAL: &str = "00000000000040008000000000357653";
    const INCARNATION: &str = "10000000000040008000000000357653";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("exit-notification".into()),
            Some("018f6e21-7b70-7e70-8000-000000357653".into()),
            None,
        )
        .unwrap();
    let surface_id =
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let posted = |mux: &Mux| {
        mux.resource_notifications(16)
            .into_iter()
            .filter(|notification| notification.title == "build done")
            .collect::<Vec<_>>()
    };
    let at_exit = {
        // The last output asks for a notification; the host's Exit frame is next. The publisher runs nothing until
        // the hold drops, so what posted by the end of the exit posted on the exit's own turn.
        let _held = mux.hold_terminal_publisher_for_test();
        mux.queue_terminal_notifications(
            surface_id,
            vec![crate::terminal_metadata::TerminalNotification {
                title: "build done".into(),
                body: String::new(),
                level: NotificationLevel::Info,
            }],
        );
        mux.surface_exited(surface_id);
        posted(&mux).len()
    };
    assert_eq!(
        at_exit, 1,
        "the notification its last output asked for did not post before the terminal's exit"
    );
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(10)),
        "the publisher did not finish"
    );
    let all = posted(&mux);
    assert_eq!(all.len(), 1, "the notification posted more than once");
    assert_eq!(all[0].terminal_id.as_ref(), Some(&terminal), "the notification names its terminal");
}
