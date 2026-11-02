//! SPLIT BURST on one connection (lead, after #32364): the app sends its
//! Cmd-D splits on one connection, and the connection committed its
//! creations one after another, so splits that arrived together never
//! met in one creation group. They now join one group: one projection
//! write for the burst, and the replies still go out in the order sent.

use super::tests::{captured_writer, test_mux};
use super::*;
use std::sync::mpsc;

/// Waits, bounded and with no sleep, until `ready` holds; false at the
/// deadline.
fn reaches(ready: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready() {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::yield_now();
    }
    true
}

#[test]
fn splits_sent_on_one_connection_commit_in_one_group_and_reply_in_order() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let before = mux.with_state(|state| state.resource_revision);
    let (writer, outbound) = captured_writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    // The first split stops right before its effect, inside its creation
    // group, until the other three wait in that group.
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    }));
    for id in 10..14 {
        let request = json!({"id": id, "cmd": "split", "pane": pane, "dir": "down"});
        assert!(handle_connection_frame(
            &mux,
            client,
            ClientTransport::Unix,
            &request.to_string(),
            &writer,
            &scheduler,
        ));
    }
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let joined = reaches(|| mux.creations_waiting_for_test() == 3);
    release_tx.send(()).unwrap();
    scheduler.finish_and_wait();
    assert!(joined, "the other three splits of the connection did not join the first one's group");

    // Each split answered, in the order it was sent, with its own pane.
    let replies = std::iter::from_fn(|| outbound.try_pop())
        .map(|line| serde_json::from_str::<Value>(&line).unwrap())
        .filter(|reply| reply.get("id").is_some())
        .collect::<Vec<_>>();
    let ids = replies.iter().map(|reply| reply["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids, [json!(10), json!(11), json!(12), json!(13)], "{replies:?}");
    for reply in &replies {
        assert_ne!(reply["ok"], json!(false), "{reply}");
    }
    let surfaces =
        replies.iter().map(|reply| reply["data"]["surface"].clone()).collect::<HashSet<_>>();
    assert_eq!(surfaces.len(), 4, "{replies:?}");
    // One projection write with changes for the four new panes.
    let registry = mux.workspace_registry.lock().unwrap();
    let revisions = registry
        .resource_events_after(before)
        .unwrap()
        .batches
        .iter()
        .filter(|batch| batch.changes.as_array().is_some_and(|changes| !changes.is_empty()))
        .map(|batch| batch.revision)
        .collect::<Vec<_>>();
    assert_eq!(revisions.len(), 1, "the four splits wrote projections at {revisions:?}");
}
