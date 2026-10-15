#![cfg(unix)]
//! Agent message delivery and unsend at the daemon boundary (bead cx-55d27,
//! PR 4): the daemon's pump hands a queued message to its acpmux recipient
//! as a prompt (with the sender's provenance) and records it delivered; a
//! held message waits for the person's release; `agent.message.unsend`
//! takes a message back before delivery (`unsent`) and asks acpmux to
//! withdraw a delivered one (`retracted` mid-turn, `too_late` once its turn
//! ended); only the sender or the person unsends. The daemon is the one
//! delivery path: a CLI send waits for the pump instead of handing over
//! itself, an unsend never takes back what acpmux may hold without asking
//! it, and one refusing recipient does not undo the others.

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test agent_message_pump` selects these tests.
mod agent_message_pump {
    use super::harness::{Daemon, delivery, refusal};
    use serde_json::{Value, json};
    use std::time::{Duration, Instant};

    fn to(recipient: &str, body: &str) -> Value {
        json!({"recipients": [recipient], "body": body})
    }

    fn id(message: &Value) -> String {
        message["id"].as_str().unwrap_or_else(|| panic!("no id: {message}")).to_owned()
    }

    fn state(message: &Value, recipient: &str) -> String {
        delivery(message, recipient)["state"].as_str().unwrap_or_default().to_owned()
    }

    /// A daemon whose fake acpmux runs sessions `a` and `b` in one
    /// workspace, and `a`'s launch credential.
    fn two_agents(name: &str) -> (Daemon, String) {
        let (daemon, a, _) = two_agents_in(name);
        (daemon, a)
    }

    /// [`two_agents`] and their workspace's `(public id, key)`.
    fn two_agents_in(name: &str) -> (Daemon, String, (String, String)) {
        let daemon = Daemon::start(name, &[]);
        let alpha = daemon.workspace("alpha");
        daemon.place_session("a", &alpha.1);
        daemon.place_session("b", &alpha.1);
        let a = daemon.acp_credential("a");
        (daemon, a, alpha)
    }

    /// `a` sends to `b`; the message once the pump delivered it.
    fn delivered_to_b(daemon: &Daemon, a: &str, body: &str) -> Value {
        let message = id(&daemon.sent(Some(a), to("acp:b", body)));
        daemon.wait_for(&message, "delivery", |m| state(m, "acp:b") == "delivered")
    }

    fn unsend(daemon: &Daemon, credential: Option<&str>, message: &str) -> Value {
        daemon.mutate("agent.message.unsend", json!({"message_id": message}), credential)
    }

    /// The outcome of an accepted unsend for `recipient`.
    fn outcome(reply: &Value, recipient: &str) -> String {
        entry(reply, recipient)["outcome"].as_str().unwrap_or_default().to_owned()
    }

    /// The `outcomes` entry of an accepted unsend for `recipient`.
    fn entry(reply: &Value, recipient: &str) -> Value {
        assert_eq!(reply["ok"], true, "the unsend was refused: {reply}");
        let value = &reply["result"]["value"];
        let outcomes = value["outcomes"].as_array().unwrap_or_else(|| panic!("{reply}"));
        let found = outcomes.iter().find(|o| o["recipient"] == recipient);
        found.unwrap_or_else(|| panic!("no outcome for {recipient}: {reply}")).clone()
    }

    /// The prompts the fake acpmux took for message `id`.
    fn prompts_of(daemon: &Daemon, id: &str) -> usize {
        daemon.prompts().iter().filter(|p| p["_meta"]["acpmux"]["promptId"] == id).count()
    }

    #[test]
    fn the_pump_delivers_a_queued_message_and_records_it() {
        let (daemon, a) = two_agents("pump");
        let message = delivered_to_b(&daemon, &a, "hello b");
        let receipt = delivery(&message, "acp:b");
        assert_eq!(receipt["attempts"], "1", "{message}");
        assert_eq!(receipt["via"], "acp.prompt", "{message}");
        assert!(receipt["delivered_at_ms"].is_string(), "{message}");

        let prompts = daemon.prompts();
        assert_eq!(prompts.len(), 1, "one prompt per message: {prompts:?}");
        let prompt = &prompts[0];
        assert_eq!(prompt["sessionId"], "b");
        let meta = &prompt["_meta"]["acpmux"];
        assert_eq!(meta["promptId"], message["id"], "the message id is the prompt id");
        assert_eq!(meta["provenance"]["msgId"], message["id"]);
        assert_eq!(meta["provenance"]["from"], "acp:a");
        assert_eq!(meta["provenance"]["to"], "acp:b");
        let text = prompt["prompt"][0]["text"].as_str().unwrap_or_default();
        assert!(text.contains("hello b"), "{text}");
    }

    #[test]
    fn a_held_message_is_pumped_only_once_released() {
        let daemon = Daemon::start_owner_with_acpmux("pump-held");
        let (_, alpha) = daemon.workspace("alpha");
        let (_, beta) = daemon.workspace("beta");
        daemon.place_session("a", &alpha);
        daemon.place_session("b", &beta);
        let a = daemon.acp_credential("a");
        let message = id(&daemon.sent(Some(&a), to("acp:b", "across workspaces")));
        // Another message to the same session goes out meanwhile; the held
        // one does not.
        daemon.place_session("c", &alpha);
        let other = id(&daemon.sent(Some(&a), to("acp:c", "same workspace")));
        daemon.wait_for(&other, "the other delivery", |m| state(m, "acp:c") == "delivered");
        let listed = daemon.wait_for(&message, "a hold", |m| state(m, "acp:b") == "held");
        assert_eq!(delivery(&listed, "acp:b")["attempts"], "0", "{listed}");
        assert!(daemon.prompts().iter().all(|p| p["sessionId"] != "b"), "a held message was sent");

        let approved = daemon.app().mutate(
            "agent.message.release",
            json!({"message_id": message, "recipient": "acp:b", "decision": "approve"}),
        );
        assert_eq!(approved["ok"], true, "{approved}");
        daemon.wait_for(&message, "the released delivery", |m| state(m, "acp:b") == "delivered");
        let to_b: Vec<Value> =
            daemon.prompts().into_iter().filter(|p| p["sessionId"] == "b").collect();
        assert_eq!(to_b.len(), 1, "{to_b:?}");
        assert_eq!(to_b[0]["_meta"]["acpmux"]["promptId"], message.as_str());
    }

    #[test]
    fn unsend_before_delivery_takes_the_message_back() {
        let (daemon, a) = two_agents("unsend-early");
        // No acpmux session `gone`: the pump leaves the message queued.
        let queued = id(&daemon.sent(None, to("acp:gone", "never mind")));
        let reply = unsend(&daemon, None, &queued);
        assert_eq!(outcome(&reply, "acp:gone"), "unsent");
        assert_eq!(reply["result"]["value"]["outcome"], "unsent", "{reply}");
        let message = &reply["result"]["value"]["message"];
        assert_eq!(state(message, "acp:gone"), "unsent", "{reply}");
        // Again: still unsent, and nothing reaches the session.
        assert_eq!(outcome(&unsend(&daemon, None, &queued), "acp:gone"), "unsent");
        assert!(daemon.prompts().is_empty(), "an unsent message was delivered");

        // A held message, by its agent sender; and through the CLI.
        let held = id(&daemon.sent(Some(&a), to("acp:elsewhere", "held")));
        assert_eq!(outcome(&unsend(&daemon, Some(&a), &held), "acp:elsewhere"), "unsent");
        let listed = daemon.wait_for(&held, "unsend", |m| state(m, "acp:elsewhere") == "unsent");
        assert_eq!(delivery(&listed, "acp:elsewhere")["reason"], "unsent", "{listed}");
        let by_cli = id(&daemon.sent(None, to("acp:gone", "from the cli")));
        let printed = daemon.cli_ok(&["agent", "message", "unsend", &by_cli]);
        assert_eq!(printed["value"]["outcome"], "unsent", "{printed}");
    }

    #[test]
    fn unsend_after_delivery_retracts_a_running_turn() {
        let (daemon, a) = two_agents("unsend-retract");
        let message = id(&delivered_to_b(&daemon, &a, "take this back"));
        daemon.withdraw_answers("b", "retracted");
        let reply = unsend(&daemon, Some(&a), &message);
        assert_eq!(outcome(&reply, "acp:b"), "retracted");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:b"), "retracted", "{reply}");
        let withdrawals = daemon.withdrawals();
        assert_eq!(withdrawals.len(), 1, "{withdrawals:?}");
        assert_eq!(withdrawals[0]["sessionId"], "b");
        assert_eq!(withdrawals[0]["msgId"], message.as_str());
    }

    #[test]
    fn unsend_after_the_turn_ended_is_too_late() {
        let (daemon, a) = two_agents("unsend-late");
        let message = id(&delivered_to_b(&daemon, &a, "already read"));
        daemon.withdraw_answers("b", "too_late");
        let reply = unsend(&daemon, Some(&a), &message);
        assert_eq!(outcome(&reply, "acp:b"), "too_late");
        assert_eq!(reply["result"]["value"]["outcome"], "too_late", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:b"), "delivered", "{reply}");
    }

    #[test]
    fn only_the_sender_or_the_person_unsends() {
        let (daemon, a) = two_agents("unsend-who");
        let (_, beta) = daemon.workspace("beta");
        daemon.place_session("c", &beta);
        let c = daemon.acp_credential("c");
        let message = id(&delivered_to_b(&daemon, &a, "mine"));
        daemon.withdraw_answers("b", "retracted");
        let refused = unsend(&daemon, Some(&c), &message);
        assert_eq!(refusal(&refused), ("operation.failed".into(), "unsend_not_sender".into()));
        assert!(daemon.withdrawals().is_empty(), "a refused unsend asked acpmux");
        let missing = unsend(&daemon, None, "msg_00000000000000000000000000000000");
        assert_eq!(refusal(&missing).0, "resource.not_found", "{missing}");
        // The person may take back any message.
        assert_eq!(outcome(&unsend(&daemon, None, &message), "acp:b"), "retracted");
    }

    #[test]
    fn a_cli_send_racing_an_unsend_is_handed_over_once_and_withdrawn() {
        let (daemon, _) = two_agents("unsend-race");
        daemon.gate("b");
        daemon.withdraw_answers("b", "retracted");
        let cli = daemon.cli_started(&["agent", "message", "acp:b", "racing"]);
        // The first hand-over waits at the gate: the message is acpmux's now.
        let deadline = Instant::now() + Duration::from_secs(20);
        let message = loop {
            let found = daemon.prompts().first().map(|p| p["_meta"]["acpmux"]["promptId"].clone());
            if let Some(Value::String(found)) = found {
                break found;
            }
            assert!(Instant::now() < deadline, "nothing reached acpmux");
            std::thread::sleep(Duration::from_millis(20));
        };
        let unsending = std::thread::scope(|scope| {
            let unsending = scope.spawn(|| unsend(&daemon, None, &message));
            std::thread::sleep(Duration::from_millis(500));
            daemon.open_gate("b");
            unsending.join().unwrap()
        });
        let output = cli.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "the CLI send failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        // acpmux had it, so acpmux decided: withdrawn, never just marked unsent.
        assert_eq!(outcome(&unsending, "acp:b"), "retracted", "{unsending}");
        let listed = daemon.wait_for(&message, "the retraction", |m| state(m, "acp:b") != "queued");
        assert_eq!(state(&listed, "acp:b"), "retracted", "{listed}");
        assert_eq!(prompts_of(&daemon, &message), 1, "handed over twice: {:?}", daemon.prompts());
        assert_eq!(daemon.withdrawals().len(), 1, "{:?}", daemon.withdrawals());
    }

    #[test]
    fn one_refusing_recipient_does_not_undo_the_others() {
        let (daemon, a, (_, alpha)) = two_agents_in("unsend-partial");
        daemon.place_session("c", &alpha);
        let both = json!({"recipients": ["acp:b", "acp:c"], "body": "both"});
        let message = id(&daemon.sent(Some(&a), both));
        daemon.wait_for(&message, "both deliveries", |m| {
            state(m, "acp:b") == "delivered" && state(m, "acp:c") == "delivered"
        });
        daemon.withdraw_answers("b", "retracted");
        daemon.withdraw_answers("c", "refuse:withdraw.edited");
        let reply = unsend(&daemon, Some(&a), &message);
        assert_eq!(outcome(&reply, "acp:b"), "retracted", "{reply}");
        let refused = entry(&reply, "acp:c");
        assert_eq!(refused["outcome"], "failed", "{reply}");
        assert_eq!(refused["error"]["reason"], "withdraw_refused", "{reply}");
        assert_eq!(refused["error"]["acpmux_reason"], "withdraw.edited", "{reply}");
        assert_eq!(reply["result"]["value"]["outcome"], "failed", "{reply}");
        let stored = daemon.wait_for(&message, "the unsend", |m| state(m, "acp:b") != "delivered");
        assert_eq!(state(&stored, "acp:b"), "retracted", "{stored}");
        assert_eq!(state(&stored, "acp:c"), "delivered", "{stored}");
    }

    #[test]
    fn a_retried_unsend_replays_without_asking_acpmux_again() {
        let (daemon, a) = two_agents("unsend-replay");
        let message = id(&delivered_to_b(&daemon, &a, "once"));
        daemon.withdraw_answers("b", "retracted");
        let params = json!({"message_id": message});
        let first =
            daemon.mutate_keyed("agent.message.unsend", params.clone(), Some(&a), "k-replay");
        assert_eq!(outcome(&first, "acp:b"), "retracted");
        let again = daemon.mutate_keyed("agent.message.unsend", params, Some(&a), "k-replay");
        assert_eq!(again["result"]["value"], first["result"]["value"], "{again}");
        assert_eq!(daemon.withdrawals().len(), 1, "a replay asked acpmux again");
        // The same key for other input is refused before acpmux is asked.
        let other = json!({"message_id": message, "recipient": "acp:b"});
        let conflict = daemon.mutate_keyed("agent.message.unsend", other, Some(&a), "k-replay");
        assert_eq!(conflict["ok"], false, "{conflict}");
        assert!(conflict.to_string().contains("idempotency"), "{conflict}");
        assert_eq!(daemon.withdrawals().len(), 1, "a conflicting retry asked acpmux");
    }

    #[test]
    fn without_an_answer_a_delivered_message_is_never_called_unsent() {
        let (daemon, a) = two_agents("unsend-silent");
        let message = id(&delivered_to_b(&daemon, &a, "mid flight"));
        daemon.withdraw_answers("b", "hang-up");
        let reply = unsend(&daemon, Some(&a), &message);
        let silent = entry(&reply, "acp:b");
        assert_eq!(silent["outcome"], "failed", "{reply}");
        assert_eq!(silent["error"]["reason"], "acpmux_unavailable", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:b"), "delivered", "{reply}");
    }

    #[test]
    fn a_prompt_acpmux_never_accepts_stays_queued_and_is_not_unsent() {
        let (daemon, a, (_, alpha)) = two_agents_in("pump-unsettled");
        daemon.place_session("slow", &alpha);
        daemon.gate("slow");
        let message = id(&daemon.sent(Some(&a), to("acp:slow", "are you there")));
        // The pump gave up waiting: it may still run, so it stays queued for
        // another try (acpmux runs a prompt id once), with the attempt noted.
        let waited = daemon.wait_for(&message, "a noted attempt", |m| {
            delivery(m, "acp:slow")["attempts"] != "0" || state(m, "acp:slow") != "queued"
        });
        assert_eq!(state(&waited, "acp:slow"), "queued", "{waited}");
        assert!(delivery(&waited, "acp:slow")["error"].is_string(), "{waited}");
        daemon.withdraw_answers("slow", "hang-up");
        let reply = unsend(&daemon, Some(&a), &message);
        let silent = entry(&reply, "acp:slow");
        assert_eq!(silent["outcome"], "failed", "{reply}");
        assert_eq!(silent["error"]["reason"], "acpmux_unavailable", "{reply}");
        daemon.open_gate("slow");
    }

    #[test]
    fn queued_terminal_messages_never_hide_an_acpmux_delivery() {
        let (daemon, a, (workspace, _)) = two_agents_in("pump-window");
        let terminals: Vec<String> =
            (0..5).map(|_| daemon.terminal(&workspace, "exec sleep 600")).collect();
        // More queued terminal messages than one pass reads, oldest first,
        // inside every send limit (the clock moves past each burst window).
        for n in 0..205 {
            if n % 5 == 0 {
                daemon.set_clock_offset(i64::from(n / 5) * 10_001);
            }
            let terminal = &terminals[usize::try_from(n % 5).unwrap()];
            let sent = daemon.sent(Some(&a), to(terminal, &format!("idle {n}")));
            assert_eq!(state(&sent, terminal), "queued", "{sent}");
        }
        daemon.set_clock_offset(42 * 10_001);
        let message = id(&daemon.sent(Some(&a), to("acp:b", "behind the terminals")));
        daemon.wait_for(&message, "the acpmux delivery", |m| state(m, "acp:b") == "delivered");
    }

    #[test]
    fn the_pump_retries_a_session_acpmux_starts_later() {
        let (daemon, a, (_, alpha)) = two_agents_in("pump-retry");
        let message = id(&daemon.sent(Some(&a), to("acp:late", "when you start")));
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(prompts_of(&daemon, &message), 0, "a prompt to a session acpmux does not run");
        // Nothing else happens: no send, no release, no acpmux reconnect.
        daemon.place_session("late", &alpha);
        daemon.wait_for(&message, "the retried delivery", |m| state(m, "acp:late") == "delivered");
    }
}
