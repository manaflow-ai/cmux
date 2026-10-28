#![cfg(unix)]
//! Agent message delivery and unsend at the daemon boundary (bead cx-55d27,
//! PR 4): the daemon's pump hands a queued message to its acpmux recipient
//! as a prompt (with the sender's provenance) and records it delivered; a
//! held message waits for the person's release; `agent.message.unsend`
//! takes a message back before delivery (`unsent`) and asks acpmux to
//! withdraw a delivered one (`retracted` mid-turn, `too_late` once its turn
//! ended); only the verified sender or the person, in the cmux app, unsends. The daemon is the one
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
        let daemon = Daemon::start_owner_with_acpmux(name);
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

    /// The person's unsend, from the verified cmux app.
    fn app_unsend(daemon: &Daemon, message: &str) -> Value {
        daemon.app().mutate("agent.message.unsend", json!({"message_id": message}))
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
        // It reaches a running turn at once when the agent steers, else it queues.
        assert_eq!(meta["steer"], true, "a message steers by default: {meta}");
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
        let reply = app_unsend(&daemon, &queued);
        assert_eq!(outcome(&reply, "acp:gone"), "unsent");
        assert_eq!(reply["result"]["value"]["outcome"], "unsent", "{reply}");
        let message = &reply["result"]["value"]["message"];
        assert_eq!(state(message, "acp:gone"), "unsent", "{reply}");
        // Again: still unsent, and nothing reaches the session.
        assert_eq!(outcome(&app_unsend(&daemon, &queued), "acp:gone"), "unsent");
        assert!(daemon.prompts().is_empty(), "an unsent message was delivered");

        // A held message, by its agent sender.
        let held = id(&daemon.sent(Some(&a), to("acp:elsewhere", "held")));
        assert_eq!(outcome(&unsend(&daemon, Some(&a), &held), "acp:elsewhere"), "unsent");
        let listed = daemon.wait_for(&held, "unsend", |m| state(m, "acp:elsewhere") == "unsent");
        assert_eq!(delivery(&listed, "acp:elsewhere")["reason"], "unsent", "{listed}");
    }

    #[test]
    fn an_unverified_local_caller_cannot_unsend() {
        let (daemon, a) = two_agents("unsend-unverified");
        // Any local connection may be an agent that left out its credential.
        let mine = id(&daemon.sent(Some(&a), to("acp:gone", "mine")));
        let plain = unsend(&daemon, None, &mine);
        assert_eq!(refusal(&plain), ("operation.failed".into(), "unsend_needs_app".into()));
        let by_cli = daemon.cli(&["agent", "message", "unsend", &mine]);
        assert!(!by_cli.status.success(), "the plain CLI took a message back");
        let stderr = String::from_utf8_lossy(&by_cli.stderr);
        assert!(stderr.contains("unsend_needs_app") || stderr.contains("cmux app"), "{stderr}");
        assert!(daemon.withdrawals().is_empty(), "a refused unsend asked acpmux");
        let listed = daemon.wait_for(&mine, "the queued message", |_| true);
        assert_ne!(state(&listed, "acp:gone"), "unsent", "{listed}");
        // Its verified sender may, and the person in the app may.
        assert_eq!(outcome(&unsend(&daemon, Some(&a), &mine), "acp:gone"), "unsent");
        let theirs = id(&daemon.sent(None, to("acp:gone", "the person's")));
        assert_eq!(outcome(&app_unsend(&daemon, &theirs), "acp:gone"), "unsent");
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
        let missing = app_unsend(&daemon, "msg_00000000000000000000000000000000");
        assert_eq!(refusal(&missing).0, "resource.not_found", "{missing}");
        // The person, in the app, may take back any message.
        assert_eq!(outcome(&app_unsend(&daemon, &message), "acp:b"), "retracted");
    }

    #[test]
    fn a_cli_send_racing_an_unsend_is_handed_over_once_and_withdrawn() {
        let (daemon, a) = two_agents("unsend-race");
        // a's CLI answers b's message: its recipient is b, by the daemon.
        let b = daemon.acp_credential("b");
        let parent = id(&daemon.sent(Some(&b), to("acp:a", "question")));
        daemon.wait_for(&parent, "the question", |m| state(m, "acp:a") == "delivered");
        daemon.gate("b");
        daemon.withdraw_answers("b", "retracted");
        let args = ["agent", "message", "--reply-to", parent.as_str(), "racing"];
        let mut cli = daemon.cli_started(&args, &a);
        // The first hand-over waits at the gate: the message is acpmux's now.
        let deadline = Instant::now() + Duration::from_secs(20);
        let message = loop {
            let to_b = daemon.prompts().into_iter().find(|p| p["sessionId"] == "b");
            let found = to_b.map(|p| p["_meta"]["acpmux"]["promptId"].clone());
            if let Some(Value::String(found)) = found {
                break found;
            }
            if cli.try_wait().unwrap().is_some() {
                let output = cli.wait_with_output().unwrap();
                panic!(
                    "the CLI ended before acpmux had the message: {}{}",
                    String::from_utf8_lossy(&output.stdout),
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            assert!(Instant::now() < deadline, "nothing reached acpmux");
            std::thread::sleep(Duration::from_millis(20));
        };
        let unsending = std::thread::scope(|scope| {
            let unsending = scope.spawn(|| app_unsend(&daemon, &message));
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
        // Too late: the delivery stays delivered, so acpmux would be asked again.
        daemon.withdraw_answers("b", "too_late");
        let params = json!({"message_id": message});
        let first =
            daemon.mutate_keyed("agent.message.unsend", params.clone(), Some(&a), "k-replay");
        assert_eq!(outcome(&first, "acp:b"), "too_late");
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
    fn the_pump_retries_a_session_acpmux_is_moving() {
        let (daemon, a) = two_agents("pump-retry");
        daemon.moving("b", 1);
        let message = id(&daemon.sent(Some(&a), to("acp:b", "once you have moved")));
        // Nothing else happens: no send, no release, no acpmux reconnect.
        let delivered =
            daemon.wait_for(&message, "the retried delivery", |m| state(m, "acp:b") != "queued");
        assert_eq!(state(&delivered, "acp:b"), "delivered", "{delivered}");
        assert_eq!(prompts_of(&daemon, &message), 2, "one refused, one taken");
    }

    #[test]
    fn an_unsend_commits_acpmux_answer_after_an_unrelated_change() {
        let (daemon, a) = two_agents("unsend-revision");
        let message = id(&delivered_to_b(&daemon, &a, "take it back"));
        daemon.withdraw_answers("b", "retracted");
        daemon.hold_withdraws("b");
        // The person's message to a session acpmux does not run: the pump
        // commits nothing for it, so this is the current revision.
        let before = daemon.send(None, to("acp:gone", "first"));
        let revision = before["result"]["revision"].as_str().unwrap().to_owned();
        let params = json!({"message_id": message, "expected_revision": revision});
        let reply = std::thread::scope(|scope| {
            let unsending = scope.spawn(|| daemon.mutate("agent.message.unsend", params, Some(&a)));
            let deadline = Instant::now() + Duration::from_secs(20);
            while daemon.withdrawals().is_empty() {
                assert!(Instant::now() < deadline, "acpmux was never asked");
                std::thread::sleep(Duration::from_millis(20));
            }
            // Another change commits while acpmux withdraws the message.
            let other = daemon.send(None, to("acp:gone", "meanwhile"));
            assert_ne!(other["result"]["revision"], json!(revision), "{other}");
            daemon.release_withdraws("b");
            unsending.join().unwrap()
        });
        // acpmux withdrew it: that answer commits.
        assert_eq!(outcome(&reply, "acp:b"), "retracted", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:b"), "retracted", "{reply}");
    }

    #[test]
    fn a_prompt_acpmux_may_still_take_is_never_called_unsent() {
        let (daemon, a, (_, alpha)) = two_agents_in("unsend-in-flight");
        daemon.place_session("slow", &alpha);
        daemon.silent("slow", 1000);
        let message = id(&daemon.sent(Some(&a), to("acp:slow", "are you there")));
        let waited = daemon.wait_for(&message, "a noted attempt", |m| {
            delivery(m, "acp:slow")["attempts"] != "0" || state(m, "acp:slow") != "queued"
        });
        assert_eq!(state(&waited, "acp:slow"), "queued", "{waited}");
        // acpmux holds no such prompt yet, but a hand-over may still reach it.
        let reply = unsend(&daemon, Some(&a), &message);
        let pending = entry(&reply, "acp:slow");
        assert_eq!(pending["outcome"], "failed", "{reply}");
        assert_eq!(pending["error"]["reason"], "acpmux_unavailable", "{reply}");
        assert_eq!(reply["result"]["value"]["outcome"], "failed", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:slow"), "queued", "{reply}");
        assert!(!daemon.withdrawals().is_empty(), "acpmux was never asked");
    }

    #[test]
    fn a_session_waiting_on_one_prompt_gets_no_later_message_first() {
        let daemon = Daemon::start_owner_with_acpmux("pump-order");
        let (_, alpha) = daemon.workspace("alpha");
        // The person's messages wait: acpmux runs no session `slow` yet.
        let first = id(&daemon.sent(None, to("acp:slow", "first")));
        let second = id(&daemon.sent(None, to("acp:slow", "second")));
        // Then it does, and never accepts the first hand-over.
        daemon.silent("slow", 1);
        daemon.place_session("slow", &alpha);
        daemon.wait_for(&first, "a noted attempt", |m| delivery(m, "acp:slow")["attempts"] != "0");
        daemon.wait_for(&second, "the second delivery", |m| state(m, "acp:slow") == "delivered");
        daemon.wait_for(&first, "the first delivery", |m| state(m, "acp:slow") == "delivered");
        let order: Vec<String> = daemon
            .prompts()
            .iter()
            .filter_map(|p| p["_meta"]["acpmux"]["promptId"].as_str().map(str::to_owned))
            .collect();
        let last_first = order.iter().rposition(|p| *p == first);
        let first_second = order.iter().position(|p| *p == second);
        assert!(last_first < first_second, "the second went out before the first: {order:?}");
    }

    /// The pump hands a message over while acpmux still reads its chat logs
    /// after a restart: naming the recipient (`_acpmux/info`) does not wait
    /// for them (`waitLogs: false`), as a large log store outlasts its 2 s.
    #[test]
    fn a_message_is_delivered_while_acpmux_reads_its_chat_logs() {
        let daemon = Daemon::start_owner_with_acpmux("pump-logs");
        let (_, alpha) = daemon.workspace("alpha");
        daemon.place_session("b", &alpha);
        daemon.reading_chat_logs();
        let message = id(&daemon.sent(None, to("acp:b", "while the logs load")));
        daemon.wait_for(&message, "the delivery", |m| state(m, "acp:b") == "delivered");
        assert_eq!(daemon.prompts().len(), 1, "{:?}", daemon.prompts());
    }

    /// A hand-over acpmux is slow to take (it still reads its chat logs, so
    /// its `session/prompt` waits for them) holds up no other session's
    /// message, and still goes out once when acpmux takes it.
    #[test]
    fn a_slow_hand_over_holds_up_no_other_delivery_while_acpmux_reads_its_chat_logs() {
        let daemon = Daemon::start_owner_with_acpmux("pump-slow-logs");
        let (_, alpha) = daemon.workspace("alpha");
        daemon.place_session("slow", &alpha);
        daemon.place_session("b", &alpha);
        daemon.reading_chat_logs();
        // `slow`'s prompt waits, unanswered, until the test opens its gate.
        daemon.gate("slow");
        let slow = id(&daemon.sent(None, to("acp:slow", "first, slow")));
        let deadline = Instant::now() + Duration::from_secs(20);
        while prompts_of(&daemon, &slow) == 0 {
            assert!(Instant::now() < deadline, "the slow hand-over never reached acpmux");
            std::thread::sleep(Duration::from_millis(20));
        }
        let other = id(&daemon.sent(None, to("acp:b", "second, to another session")));
        daemon.wait_for(&other, "the other delivery", |m| state(m, "acp:b") == "delivered");
        // The slow hand-over is still out: the pump neither gave up on it nor
        // made the other delivery wait for it.
        let waiting = daemon.wait_for(&slow, "the slow message", |_| true);
        assert_eq!(state(&waiting, "acp:slow"), "queued", "{waiting}");
        assert_eq!(
            delivery(&waiting, "acp:slow")["attempts"],
            "0",
            "the other delivery waited for the slow hand-over to time out: {waiting}"
        );
        daemon.open_gate("slow");
        daemon.wait_for(&slow, "the slow delivery", |m| state(m, "acp:slow") == "delivered");
        assert_eq!(prompts_of(&daemon, &slow), 1, "handed over twice: {:?}", daemon.prompts());
        assert_eq!(prompts_of(&daemon, &other), 1, "handed over twice: {:?}", daemon.prompts());
    }

    #[test]
    fn a_long_acpmux_refusal_fits_the_unsend_result() {
        let (daemon, a) = two_agents("unsend-long-reason");
        let message = id(&delivered_to_b(&daemon, &a, "long"));
        let reason = format!("withdraw.{}", "\u{e9}".repeat(300));
        daemon.withdraw_answers("b", &format!("refuse:{reason}"));
        let reply = unsend(&daemon, Some(&a), &message);
        let refused = entry(&reply, "acp:b");
        assert_eq!(refused["outcome"], "failed", "{reply}");
        let acpmux_reason = refused["error"]["acpmux_reason"].as_str().unwrap_or_default();
        // The catalog's limits count UTF-8 bytes; the cut keeps whole characters.
        assert!((125..=128).contains(&acpmux_reason.len()), "{reply}");
        assert!(reason.starts_with(acpmux_reason), "{reply}");
        let text = refused["error"]["message"].as_str().unwrap_or_default();
        assert!(!text.is_empty() && text.len() <= 1024, "{reply}");
    }

    #[test]
    fn the_cli_unsend_exits_1_when_it_failed() {
        let (daemon, a) = two_agents("unsend-cli-exit");
        let message = id(&delivered_to_b(&daemon, &a, "from the cli"));
        let args = ["agent", "message", "unsend", message.as_str()];
        let run = |expected: i32, outcome: &str| {
            let output = daemon.cli_started(&args, &a).wait_with_output().unwrap();
            let shown = format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert_eq!(output.status.code(), Some(expected), "{shown}");
            let printed: Value = serde_json::from_slice(&output.stdout)
                .unwrap_or_else(|error| panic!("{error}: {shown}"));
            assert_eq!(printed["value"]["outcome"], outcome, "{shown}");
        };
        // acpmux hangs up: failed, still printed, and the command fails.
        daemon.withdraw_answers("b", "hang-up");
        run(1, "failed");
        daemon.withdraw_answers("b", "too_late");
        run(0, "too_late");
    }

    #[test]
    fn an_unsettled_delivery_to_a_deleted_session_is_unsent() {
        let (daemon, a, (_, alpha)) = two_agents_in("unsend-deleted");
        daemon.place_session("slow", &alpha);
        daemon.silent("slow", 1000);
        let message = id(&daemon.sent(Some(&a), to("acp:slow", "are you there")));
        let waited = daemon.wait_for(&message, "a noted attempt", |m| {
            delivery(m, "acp:slow")["attempts"] != "0" || state(m, "acp:slow") != "queued"
        });
        assert_eq!(state(&waited, "acp:slow"), "queued", "{waited}");
        // The session is deleted; the pump finds no such session and keeps trying.
        daemon.delete_session("slow");
        let before = daemon.lookups_of("slow");
        let deadline = Instant::now() + Duration::from_secs(40);
        while daemon.lookups_of("slow") == before {
            assert!(Instant::now() < deadline, "the pump never looked for the deleted session");
            std::thread::sleep(Duration::from_millis(50));
        }
        // No running session can take a late prompt: it never reached the agent.
        let reply = unsend(&daemon, Some(&a), &message);
        assert_eq!(outcome(&reply, "acp:slow"), "unsent", "{reply}");
        assert_eq!(reply["result"]["value"]["outcome"], "unsent", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:slow"), "unsent", "{reply}");
        assert!(!daemon.withdrawals().is_empty(), "acpmux was never asked");
        // A later pass (a send wakes the pump) no longer looks for it.
        let after = daemon.lookups_of("slow");
        delivered_to_b(&daemon, &a, "after the unsend");
        assert_eq!(daemon.lookups_of("slow"), after, "the pump still retries an unsent delivery");
    }

    #[test]
    fn a_blank_acpmux_refusal_reason_reads_withdraw_refused() {
        let (daemon, a) = two_agents("unsend-blank-reason");
        let message = id(&delivered_to_b(&daemon, &a, "blank"));
        daemon.withdraw_answers("b", "refuse:   ");
        let reply = unsend(&daemon, Some(&a), &message);
        let refused = entry(&reply, "acp:b");
        assert_eq!(refused["outcome"], "failed", "{reply}");
        assert_eq!(refused["error"]["reason"], "withdraw_refused", "{reply}");
        assert_eq!(refused["error"]["acpmux_reason"], "withdraw.refused", "{reply}");
    }

    #[test]
    fn an_unsettled_delivery_to_a_peer_session_is_never_called_unsent() {
        let (daemon, a, (_, alpha)) = two_agents_in("unsend-peer");
        // A peer daemon runs `far`: acpmux forwards its prompts there, but a
        // withdraw is answered here, where no session matches.
        daemon.place_peer_session("far", &alpha);
        daemon.silent("far", 1000);
        let message = id(&daemon.sent(Some(&a), to("acp:far", "over there")));
        let waited = daemon.wait_for(&message, "a noted attempt", |m| {
            delivery(m, "acp:far")["attempts"] != "0" || state(m, "acp:far") != "queued"
        });
        assert_eq!(state(&waited, "acp:far"), "queued", "{waited}");
        // The peer's session may still run the hand-over: not unsent.
        let reply = unsend(&daemon, Some(&a), &message);
        let pending = entry(&reply, "acp:far");
        assert_eq!(pending["outcome"], "failed", "{reply}");
        assert_eq!(pending["error"]["reason"], "acpmux_unavailable", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:far"), "queued", "{reply}");
        assert!(!daemon.withdrawals().is_empty(), "acpmux was never asked");
    }

    #[test]
    fn an_unsettled_delivery_to_an_unreachable_peer_is_never_called_unsent() {
        let (daemon, a, (_, alpha)) = two_agents_in("unsend-peer-down");
        // A peer daemon runs `far` and stops answering once the prompt went
        // out: acpmux cannot say whether the peer holds it.
        daemon.place_unreachable_peer_session("far", &alpha);
        daemon.silent("far", 1000);
        let message = id(&daemon.sent(Some(&a), to("acp:far", "over there")));
        let waited = daemon.wait_for(&message, "a noted attempt", |m| {
            delivery(m, "acp:far")["attempts"] != "0" || state(m, "acp:far") != "queued"
        });
        assert_eq!(state(&waited, "acp:far"), "queued", "{waited}");
        let reply = unsend(&daemon, Some(&a), &message);
        let pending = entry(&reply, "acp:far");
        assert_eq!(pending["outcome"], "failed", "{reply}");
        assert_eq!(pending["error"]["reason"], "acpmux_unavailable", "{reply}");
        assert_eq!(state(&reply["result"]["value"]["message"], "acp:far"), "queued", "{reply}");
    }
}
