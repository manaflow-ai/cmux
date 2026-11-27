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

/// A create that panics still ends its slot (review of #32461): before, a
/// panic skipped the slot's end, so the connection never drained and every
/// later create of the connection waited for good to send its reply,
/// holding a terminal work worker.
#[test]
fn a_split_that_panics_still_ends_its_slot() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let (writer, _outbound) = captured_writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    // crash-allow: unit test only; the panic stands in for a defect inside a create.
    mux.set_creation_before_effect_hook_for_test(Box::new(|| panic!("a create panics")));
    for id in 20..22 {
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
    scheduler.finish();
    assert!(
        scheduler.wait_for_completion(Some(Duration::from_secs(10))),
        "the connection's creates did not all end after one of them panicked"
    );
}

/// A create that panics while a later create of its connection waits,
/// launched, to start (second review of #32461): the panic ended the
/// commit loop, nobody started the waiting create, and the connection
/// never drained. A `new-pane-right` is no split, so the split behind it
/// waits for it to end.
#[test]
fn a_create_that_panics_still_starts_the_next_one() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let (writer, outbound) = captured_writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    // The new-pane-right panics once the split behind it is launched and
    // waits to start.
    let waiting = scheduler.clone();
    let launched_behind = Arc::new(AtomicBool::new(false));
    let seen = launched_behind.clone();
    mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        seen.store(
            reaches(|| waiting.launched_creations_waiting_for_test() == 1),
            Ordering::SeqCst,
        );
        // crash-allow: unit test only; the panic stands in for a defect inside a create.
        panic!("a create panics");
    }));
    for request in [
        json!({"id": 30, "cmd": "new-pane-right", "pane": pane, "width": 0.5}),
        json!({"id": 31, "cmd": "split", "pane": pane, "dir": "down"}),
    ] {
        assert!(handle_connection_frame(
            &mux,
            client,
            ClientTransport::Unix,
            &request.to_string(),
            &writer,
            &scheduler,
        ));
    }
    scheduler.finish();
    assert!(
        scheduler.wait_for_completion(Some(Duration::from_secs(10))),
        "the split behind a create that panicked never started"
    );
    assert!(launched_behind.load(Ordering::SeqCst), "the split never waited, launched, behind");
    let replied = std::iter::from_fn(|| outbound.try_pop())
        .map(|line| serde_json::from_str::<Value>(&line).unwrap())
        .any(|reply| reply["id"] == json!(31) && reply["ok"] == json!(true));
    assert!(replied, "the split behind a create that panicked did not answer");
}

/// Nine splits on one connection: the first eight fill one group, and the
/// ninth commits after them, so the panes keep the request order. Group
/// leaders take the creation fence in group order; with the terminal pool's
/// 8 workers busy in the first group the ninth also starts only after it,
/// so this test guards the order rather than reproducing a race.
#[test]
fn a_split_that_leads_the_next_group_commits_after_the_open_group() {
    const SPLITS: u64 = 9;
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let before = mux.with_state(|state| state.resource_revision);
    let (writer, outbound) = captured_writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    // The first group's leader stops after it joined and before it takes
    // the creation fence, until its 7 other members wait in the group.
    let (release_tx, release_rx) = mpsc::channel::<()>();
    mux.set_creation_before_fence_hook_for_test(Box::new(move || {
        release_rx.recv().unwrap();
    }));
    for n in 0..SPLITS {
        let request = json!({"id": 40 + n, "cmd": "split", "pane": pane, "dir": "down"});
        assert!(handle_connection_frame(
            &mux,
            client,
            ClientTransport::Unix,
            &request.to_string(),
            &writer,
            &scheduler,
        ));
    }
    let joined = reaches(|| mux.creations_waiting_for_test() == 7);
    release_tx.send(()).unwrap();
    assert!(joined, "the first eight splits did not wait in one group");
    scheduler.finish_and_wait();

    let replies = std::iter::from_fn(|| outbound.try_pop())
        .map(|line| serde_json::from_str::<Value>(&line).unwrap())
        .filter(|reply| reply.get("id").is_some())
        .collect::<Vec<_>>();
    assert_eq!(replies.len(), SPLITS as usize, "{replies:?}");
    let panes = replies
        .iter()
        .map(|reply| reply["data"]["pane_id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    // The revision that first stored each new pane, in request order.
    let batches = mux.workspace_registry.lock().unwrap().resource_events_after(before).unwrap();
    let stored_at = |pane: &str| {
        batches.batches.iter().find_map(|batch| {
            let changes = batch.changes.as_array()?;
            changes
                .iter()
                .any(|change| change["resource"] == "pane" && change["id"].as_str() == Some(pane))
                .then_some(batch.revision)
        })
    };
    let revisions = panes.iter().map(|pane| stored_at(pane)).collect::<Vec<_>>();
    assert!(revisions.iter().all(Option::is_some), "a pane was never stored: {revisions:?}");
    let last = revisions[SPLITS as usize - 1];
    let earlier = revisions[..SPLITS as usize - 1].iter().max().copied().flatten();
    assert!(
        last > earlier,
        "the ninth split was stored at {last:?}, before the open group's panes at {revisions:?}"
    );
}

/// A create that panics gives input queued for its new terminal back at
/// once (fourth review of #32461): the panic skipped the end of the create,
/// so the input waited for the 10 s expiry and came back as "expired".
#[test]
fn a_create_that_panics_gives_queued_input_back_at_once() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let (writer, _outbound) = captured_writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let terminal_id = "5d0000000000400080000000000000a1";
    let (notice_tx, notice_rx) = mpsc::channel::<String>();
    let notice_tx = Mutex::new(notice_tx);
    let notice: crate::mux::creating_input::UnclaimedNotice =
        Arc::new(move |_: &str, _: &[u8], reason: &str| {
            let _ = notice_tx.lock().unwrap().send(reason.to_string());
        });
    let hook_mux = mux.clone();
    mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        // Input for the terminal arrives while it is being created, then the
        // create panics.
        let queued = hook_mux.write_terminal_input(terminal_id, client, b"ls\n", false, notice);
        assert!(matches!(queued, Ok(crate::mux::creating_input::TerminalInputTarget::Queued)));
        // crash-allow: unit test only; the panic stands in for a defect inside a create.
        panic!("a create panics");
    }));
    let request =
        json!({"id": 50, "cmd": "split", "pane": pane, "dir": "down", "terminal_id": terminal_id});
    assert!(handle_connection_frame(
        &mux,
        client,
        ClientTransport::Unix,
        &request.to_string(),
        &writer,
        &scheduler,
    ));
    let reason = notice_rx.recv_timeout(Duration::from_secs(30)).unwrap();
    scheduler.finish_and_wait();
    assert_eq!(reason, "failed", "the queued input came back late, as {reason:?}");
}
