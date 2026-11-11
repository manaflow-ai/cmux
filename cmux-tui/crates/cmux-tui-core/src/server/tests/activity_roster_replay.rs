//! #39096 review F1: an `subscribe-activity` subscriber that connects while
//! the start's agent roster replay runs in the background reads its live
//! agent count from a roster still behind the journal. When the replay then
//! folds an agent's Stop, its records apply no deltas, so without a fresh
//! snapshot at the replay's end the subscriber would stay on "working".

use super::*;
use std::time::Instant;

fn hook(mux: &Arc<Mux>, terminal_id: &str, event: &str) {
    let ingress = crate::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal_id),
        serde_json::json!({ "session_id": "replay-session" }),
    )
    .unwrap();
    let key = format!("activity-replay-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

fn live_agents(value: &Value) -> u64 {
    value["activity"]["live_agents"].as_u64().unwrap_or_else(|| panic!("no live_agents: {value}"))
}

#[test]
fn an_activity_subscriber_from_mid_replay_ends_at_the_final_live_count() {
    let root = std::env::temp_dir()
        .join(format!("cmux-activity-roster-replay-{}", crate::workspace_registry::new_uuid_v4()));
    let mux =
        Mux::open_persistent("activity-roster-replay", SurfaceOptions::default(), &root).unwrap();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap().to_string();
    hook(&mux, &terminal_id, "SessionStart");
    hook(&mux, &terminal_id, "UserPromptSubmit");
    hook(&mux, &terminal_id, "Stop");
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("idle"));

    // A start after a reducer version bump: the roster replays from zero in
    // the background, one page per slice through the gate.
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    assert!(mux.agent_roster_replaying());

    // Until the replay has folded the prompt, not the Stop.
    let mut slices = 0;
    loop {
        entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
        if mux.agent_roster_state_now_for_test(&terminal_id).as_deref() == Some("working") {
            break;
        }
        slices += 1;
        assert!(slices < 10_000, "the replay never showed the agent working");
        release.send(()).unwrap();
    }

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let snapshot = handle_command(&mux, client, Command::SubscribeActivity, &writer).unwrap();
    assert_eq!(live_agents(&snapshot), 1, "mid-replay the roster says working: {snapshot}");

    // Open the gate: the replay folds the Stop and finishes.
    drop(release);
    drop(entered);
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut last = None;
    while Instant::now() < deadline {
        match outbound.try_pop() {
            Some(line) => {
                let value: Value = serde_json::from_str(&line).unwrap_or_default();
                if value["event"] == "activity-changed" {
                    last = Some(live_agents(&value));
                    if last == Some(0) && !mux.agent_roster_replaying() {
                        break;
                    }
                }
            }
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    }
    assert!(!mux.agent_roster_replaying(), "the replay finished");
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal_id).as_deref(), Some("idle"));
    assert_eq!(last, Some(0), "the subscriber ends at the final live count");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// The activity subscriber cap counts live subscribers only. A connection that
/// closed is dropped from the stream when the next one subscribes, not first
/// at the worker's next send: until then a new subscriber was refused "too
/// many activity subscribers" although none of the counted ones was open.
#[test]
fn closed_activity_subscribers_do_not_count_against_the_cap() {
    let mux = test_mux();
    let mut closed = Vec::new();
    for _ in 0..16 {
        let (writer, _outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(&mux, client, Command::SubscribeActivity, &writer).unwrap();
        closed.push(writer);
    }
    for writer in &closed {
        writer.close();
    }

    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let subscribed = handle_command(&mux, client, Command::SubscribeActivity, &writer);

    assert!(
        subscribed.is_ok(),
        "a subscriber was refused while every counted subscriber was closed: {:?}",
        subscribed.err()
    );
}
