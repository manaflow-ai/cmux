#![cfg(unix)]
//! Agent message delivery and unsend at the daemon boundary (bead cx-55d27,
//! PR 4): the daemon's pump hands a queued message to its acpmux recipient
//! as a prompt (with the sender's provenance) and records it delivered; a
//! held message waits for the person's release; `agent.message.unsend`
//! takes a message back before delivery (`unsent`) and asks acpmux to
//! withdraw a delivered one (`retracted` mid-turn, `too_late` once its turn
//! ended); only the sender or the person unsends.

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test agent_message_pump` selects these tests.
mod agent_message_pump {
    use super::harness::{Daemon, delivery, refusal};
    use serde_json::{Value, json};

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
        let daemon = Daemon::start(name, &[]);
        let (_, alpha) = daemon.workspace("alpha");
        daemon.place_session("a", &alpha);
        daemon.place_session("b", &alpha);
        let a = daemon.acp_credential("a");
        (daemon, a)
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
        assert_eq!(reply["ok"], true, "the unsend was refused: {reply}");
        let value = &reply["result"]["value"];
        let outcomes = value["outcomes"].as_array().unwrap_or_else(|| panic!("{reply}"));
        let found = outcomes.iter().find(|o| o["recipient"] == recipient);
        let found = found.unwrap_or_else(|| panic!("no outcome for {recipient}: {reply}"));
        found["outcome"].as_str().unwrap_or_default().to_owned()
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
}
