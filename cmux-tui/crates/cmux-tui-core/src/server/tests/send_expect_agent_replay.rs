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
