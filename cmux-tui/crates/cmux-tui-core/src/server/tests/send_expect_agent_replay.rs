//! #39096 review F2 (guarded sends): while the start's agent roster replay runs in the
//! background, the roster can show an agent's older `idle` next to its current session id. A
//! `send` with `expect_agent` checked against that would type a Feed reply into an agent that is
//! working. Such a send is refused, retryably, until the replay is done.

use super::*;

fn hook(mux: &Arc<Mux>, terminal_id: &str, event: &str) {
    let ingress = crate::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal_id),
        serde_json::json!({ "session_id": "replay-session" }),
    )
    .unwrap();
    let key = format!("send-replay-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

fn reply(surface: SurfaceId) -> Command {
    Command::Send(cmd_terminal_io::SendParams {
        surface: Some(surface),
        terminal_id: None,
        text: Some("yes".into()),
        bytes: None,
        paste: false,
        expect_foreground: None,
        expect_agent: Some(cmd_terminal_io::ExpectAgent { session: Some("replay-session".into()) }),
        submit: false,
        flow: None,
    })
}

#[cfg(unix)]
#[test]
fn an_expect_agent_send_is_refused_while_the_roster_replays() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &terminal_id, "SessionStart");
    hook(&mux, &terminal_id, "UserPromptSubmit");
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("working"));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    assert!(
        handle_command(&mux, client, reply(surface.id), &writer).is_err(),
        "a working agent takes no reply"
    );

    // A replay from zero, one page per slice: hold it where the roster shows the session's
    // start (`idle`) and not yet its prompt.
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    let mut slices = 0;
    loop {
        entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
        if mux.agent_roster_state_now_for_test(&terminal_id).as_deref() == Some("idle") {
            break;
        }
        slices += 1;
        assert!(slices < 10_000, "the replay never showed the agent idle");
        release.send(()).unwrap();
    }
    let refused = handle_command(&mux, client, reply(surface.id), &writer)
        .expect_err("a send mid-replay is refused, not typed into the working agent");
    assert!(format!("{refused:#}").contains("replay in progress"), "{refused:#}");

    drop(release);
    drop(entered);
    assert!(mux.settle_agent_roster_for_test());
    assert!(mux.settle_agent_roster_for_test());
    assert!(!mux.agent_roster_replaying(), "the replay finished");
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("working"));
    let after = handle_command(&mux, client, reply(surface.id), &writer)
        .expect_err("still working after the replay");
    assert!(!format!("{after:#}").contains("replay in progress"), "{after:#}");
    mux.shutdown();
}

/// #39830 review (next-review F2): a direct report during the replay commits its row (here
/// `working`), and its journal echo, the record the roster folds, comes after. The replay's
/// reconcile kept the row but cleared the guard before the echo was folded, so the roster still
/// said `idle` next to the report's session, and a send expecting that session was typed into
/// the working agent. The guard holds until the echo is folded.
#[cfg(unix)]
#[test]
fn an_expect_agent_send_waits_for_a_direct_reports_echo_after_the_replay() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &terminal_id, "SessionStart");
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("idle"));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
    let (committed_tx, committed) = std::sync::mpsc::channel();
    let (echo_tx, echo) = std::sync::mpsc::channel::<()>();
    mux.hold_agent_report_echo_for_test(Box::new(move || {
        let _ = committed_tx.send(());
        let _ = echo.recv_timeout(Duration::from_secs(30));
    }));
    let reporter = {
        let mux = Arc::clone(&mux);
        let surface = surface.id;
        std::thread::spawn(move || {
            mux.report_agent(
                surface,
                crate::AgentState::Working,
                crate::AgentSource::Hook,
                Some("replay-session".into()),
            )
            .unwrap();
        })
    };
    committed.recv_timeout(Duration::from_secs(30)).expect("the report committed");
    drop(release);
    drop(entered);
    for _ in 0..5 {
        assert!(mux.settle_agent_roster_for_test());
    }
    let refused = handle_command(&mux, client, reply(surface.id), &writer);
    drop(echo_tx);
    reporter.join().unwrap();
    assert!(
        refused.is_err(),
        "a send expecting the session went into the agent its report made busy"
    );

    for _ in 0..100 {
        assert!(mux.settle_agent_roster_for_test());
        if !mux.agent_roster_settling() {
            break;
        }
    }
    assert!(!mux.agent_roster_settling(), "the replay reconciled after the echo");
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("working"));
    let after = handle_command(&mux, client, reply(surface.id), &writer)
        .expect_err("still working after the echo");
    assert!(!format!("{after:#}").contains("replay in progress"), "{after:#}");
    mux.shutdown();
}

/// #39830 review round 3 (router F2): a direct report's echo whose append failed still let the
/// replay's reconcile clear the guard. The roster held the hook's `idle` next to the report's
/// session, never folding its `working`, and a send expecting that session went into the
/// working agent. The failed echo is appended again, and the terminal's guarded sends stay
/// refused until it is.
#[cfg(unix)]
#[test]
fn an_expect_agent_send_waits_for_a_failed_echo_after_the_replay() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &terminal_id, "SessionStart");
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("idle"));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
    mux.fail_agent_report_echoes_for_test(1);
    mux.report_agent(
        surface.id,
        crate::AgentState::Working,
        crate::AgentSource::Hook,
        Some("replay-session".into()),
    )
    .unwrap();
    drop(release);
    drop(entered);
    for _ in 0..100 {
        assert!(mux.settle_agent_roster_for_test());
        if !mux.agent_roster_settling() {
            break;
        }
    }
    let sent = handle_command(&mux, client, reply(surface.id), &writer);
    assert!(sent.is_err(), "a send expecting the session went into the agent its report made busy");
    // The owner appends the failed echo again after its backoff.
    let terminal = surface.terminal_public_id().cloned().unwrap();
    wait_for_the_echo(&mux, &terminal);
    mux.fail_agent_report_echoes_for_test(0);
    assert!(!mux.agent_roster_settling(), "the replay reconciled after the echo");
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("working"));
    mux.shutdown();
}

/// Settles the roster until `terminal`'s direct report is folded, within 20 s.
fn wait_for_the_echo(mux: &Arc<Mux>, terminal: &TerminalPublicId) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while mux.agent_report_unsettled(terminal) && Instant::now() < deadline {
        assert!(mux.settle_agent_roster_for_test());
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!mux.agent_report_unsettled(terminal), "the echo was folded");
}

/// The same echo with no replay: until it is in the journal, the roster holds the agent's
/// older `idle`, so the terminal's guarded sends are refused, and the owner appends it again
/// (two failed appends, within its bound).
#[cfg(unix)]
#[test]
fn an_expect_agent_send_is_refused_while_a_direct_reports_echo_is_not_in_the_journal() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &terminal_id, "SessionStart");
    assert!(mux.settle_agent_roster_for_test());
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.fail_agent_report_echoes_for_test(2);
    mux.report_agent(
        surface.id,
        crate::AgentState::Working,
        crate::AgentSource::Hook,
        Some("replay-session".into()),
    )
    .unwrap();
    let sent = handle_command(&mux, client, reply(surface.id), &writer);
    let roster = mux.agent_roster_state_now_for_test(&terminal_id);
    assert_eq!(roster.as_deref(), Some("idle"), "the echo is not in the journal");
    assert!(sent.is_err(), "a send expecting the session went into the agent its report made busy");

    wait_for_the_echo(&mux, surface.terminal_public_id().unwrap());
    mux.fail_agent_report_echoes_for_test(0);
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("working"));
    let after = handle_command(&mux, client, reply(surface.id), &writer)
        .expect_err("working once the echo is folded");
    assert!(format!("{after:#}").contains("agent not waiting"), "{after:#}");
    mux.shutdown();
}

/// #39830 review round 4 (item 1): the guard checked that a direct report's echo was in the
/// journal, not that the roster had folded it. Between the append and the owner's fold the
/// roster still said `idle` next to the report's session, and a send expecting that session went
/// into the working agent. Refused until the roster folded the echo.
#[cfg(unix)]
#[test]
fn an_expect_agent_send_waits_for_the_roster_to_fold_a_direct_reports_echo() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &terminal_id, "SessionStart");
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("idle"));
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.pause_agent_roster_fold_after_head_for_test(entered_tx, release_rx);
    mux.report_agent(
        surface.id,
        crate::AgentState::Working,
        crate::AgentSource::Hook,
        Some("replay-session".into()),
    )
    .unwrap();
    entered.recv_timeout(Duration::from_secs(30)).expect("the owner holds before the echo's fold");
    let roster = mux.agent_roster_state_now_for_test(&terminal_id);
    let sent = handle_command(&mux, client, reply(surface.id), &writer);
    drop(release);
    assert_eq!(roster.as_deref(), Some("idle"), "the echo is not folded yet");
    assert!(sent.is_err(), "a send expecting the session went into the agent its report made busy");

    assert!(mux.settle_agent_roster_for_test());
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("working"));
    let after = handle_command(&mux, client, reply(surface.id), &writer)
        .expect_err("working once the echo is folded");
    assert!(format!("{after:#}").contains("agent not waiting"), "{after:#}");
    mux.shutdown();
}

/// #39830 review round 4 (item 3): an echo whose append always fails was retried forever, and
/// while the replay's reconcile waited for it every terminal's guarded sends were refused until
/// a restart. The retries are bounded; the echo is dropped, its terminal's row (the report's)
/// stays, and the other terminals' guarded sends go through.
#[cfg(unix)]
#[test]
fn an_echo_that_always_fails_is_given_up_and_releases_other_terminals_sends() {
    let mux = test_mux();
    let waiting = mux.new_workspace(None, None).unwrap();
    let waiting_id = waiting.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &waiting_id, "SessionStart");
    let failing = mux.new_workspace(None, None).unwrap();
    let failing_id = failing.terminal_public_id().cloned().unwrap();
    assert!(mux.settle_agent_roster_for_test());
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
    mux.fail_agent_report_echoes_for_test(1_000_000);
    mux.report_agent(failing.id, crate::AgentState::Working, crate::AgentSource::Hook, None)
        .unwrap();
    drop(release);
    drop(entered);
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut left = mux.agent_report_echo_failures_left_for_test();
    let mut given_up = false;
    while Instant::now() < deadline {
        assert!(mux.settle_agent_roster_for_test());
        std::thread::sleep(Duration::from_millis(300));
        let now = mux.agent_report_echo_failures_left_for_test();
        if now == left && !mux.agent_roster_settling() {
            given_up = true;
            break;
        }
        left = now;
    }
    let tries = 1_000_000 - mux.agent_report_echo_failures_left_for_test();
    let sent = handle_command(&mux, client, reply(waiting.id), &writer);
    mux.fail_agent_report_echoes_for_test(0);
    assert!(
        given_up,
        "the echo was retried {tries} times with no end, or the roster stayed settling"
    );
    assert!(sent.is_ok(), "another terminal's guarded send went through: {:?}", sent.err());
    let row = mux
        .workspace_registry
        .lock()
        .unwrap()
        .public_agent_projections(Some(&failing_id), None)
        .unwrap();
    assert_eq!(row[0].source, "hook", "the report's row stays: {row:?}");
    assert_eq!(row[0].state, "working", "{row:?}");
    mux.shutdown();
}
