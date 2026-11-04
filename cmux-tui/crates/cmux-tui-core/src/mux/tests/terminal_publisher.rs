//! The terminal publisher (`mux/terminal_publisher.rs`, #35413): an output reader queues the durable commits its
//! output asks for and never waits for the workspace registry; the publisher still commits each of them, in output
//! order, once the registry is free.

use std::sync::mpsc::{Receiver, SyncSender, sync_channel};

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
