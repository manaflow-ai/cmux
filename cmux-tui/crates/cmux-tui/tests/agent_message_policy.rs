#![cfg(unix)]
//! Agent message policy at the daemon boundary (bead cx-55d27, PR 3): the
//! sender is the request's verified actor, each recipient's delivery starts
//! queued or held by the workspace rule, a person releases or declines a held
//! delivery, an unanswered hold expires after 24 hours, every limit refuses
//! with a typed reason and survives a restart, and a registry with the first
//! four-state delivery table keeps its messages.

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test agent_message_policy` selects these tests.
mod agent_message_policy {
    use super::harness::{Daemon, delivery, refusal};
    use serde_json::{Value, json};

    const DAY_MS: i64 = 24 * 60 * 60 * 1000;

    fn to(recipient: &str, body: &str) -> Value {
        json!({"recipients": [recipient], "body": body})
    }

    fn id(message: &Value) -> String {
        message["id"].as_str().unwrap_or_else(|| panic!("no id: {message}")).to_owned()
    }

    /// The listed message `id`.
    fn listed(daemon: &Daemon, id: &str) -> Value {
        daemon
            .list(json!({}))
            .into_iter()
            .find(|message| message["id"] == id)
            .unwrap_or_else(|| panic!("{id} is not listed"))
    }

    fn state_and_reason(message: &Value, recipient: &str) -> (String, Value) {
        let delivery = delivery(message, recipient);
        (delivery["state"].as_str().unwrap_or_default().to_owned(), delivery["reason"].clone())
    }

    /// Sends `count` messages from `credential`'s holder to `recipient`, moving
    /// the clock 11 s after every fifth so the burst limit never trips, and
    /// 61 s after every twentieth so the pair limit never trips.
    fn send_many(daemon: &Daemon, credential: Option<&str>, recipient: &str, count: usize) -> i64 {
        let mut offset = 0;
        for index in 0..count {
            if index > 0 && index % 5 == 0 {
                offset += 11_000;
            }
            if index > 0 && index % 20 == 0 {
                offset += 61_000;
            }
            daemon.set_clock_offset(offset);
            daemon.sent(credential, to(recipient, &format!("message {index}")));
        }
        offset
    }

    #[test]
    fn the_sender_is_the_verified_actor() {
        let daemon = Daemon::start_owner_with("sender", &[], true);
        // The person sends as the local user, and may say so.
        let message = daemon.sent(None, to("acp:reader", "hello"));
        assert_eq!(message["sender"], "cli", "{message}");
        daemon.sent(None, json!({"recipients": ["acp:reader"], "body": "again", "sender": "cli"}));

        // The person never claims to be an agent.
        let claimed = daemon.send(
            None,
            json!({"recipients": ["acp:reader"], "body": "x",
        "sender": "acp:someone"}),
        );
        assert_eq!(refusal(&claimed), ("validation.invalid".into(), "sender_mismatch".into()));

        // An agent never claims to be another agent.
        let credential = daemon.acp_credential("writer");
        let claimed = daemon.send(
            Some(&credential),
            json!({"recipients": ["acp:reader"],
        "body": "x", "sender": "acp:other"}),
        );
        assert_eq!(refusal(&claimed), ("validation.invalid".into(), "sender_mismatch".into()));
        let own = daemon.sent(
            Some(&credential),
            json!({"recipients": ["acp:reader"],
        "body": "mine", "sender": "acp:writer"}),
        );
        assert_eq!(own["sender"], "acp:writer", "{own}");
        assert_eq!(daemon.list(json!({})).len(), 3, "a refused send stored a message");
    }

    #[test]
    fn deliveries_start_queued_in_a_shared_workspace_and_held_otherwise() {
        let daemon = Daemon::start_owner_with("workspaces", &[], true);
        let (alpha, alpha_key) = daemon.workspace("alpha");
        let (beta, _) = daemon.workspace("beta");
        let (reader, _) = daemon.agent_terminal(&alpha, "true");
        let (other, _) = daemon.agent_terminal(&beta, "true");
        let cli = env!("CARGO_BIN_EXE_cmux-tui");
        // The child sends once `run` has placed its terminal in a tab: a
        // terminal with no view yet has no workspace, so it would be held.
        let go = daemon.dir.join("go");
        let (writer, credential) = daemon.agent_terminal(
            &alpha,
            &format!(
                "while [ ! -e '{}' ]; do sleep 0.05; done; \
                 '{cli}' --json agent message {reader} from-the-child",
                go.display()
            ),
        );
        std::fs::write(&go, "").unwrap();
        daemon.place_session("near", &alpha_key);

        // A terminal child's own CLI sends as its terminal.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        let from_child = loop {
            let found = daemon.list(json!({})).into_iter().find(|m| m["body"] == "from-the-child");
            if let Some(found) = found {
                break found;
            }
            assert!(std::time::Instant::now() < deadline, "the child's CLI never sent");
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        assert_eq!(from_child["sender"], writer.as_str(), "{from_child}");
        assert_eq!(state_and_reason(&from_child, &reader).0, "queued", "{from_child}");

        // Same workspace: queued. Another workspace: held for the person.
        let sent = daemon.sent(
            Some(&credential),
            json!({"recipients": [reader, other],
        "body": "two workspaces"}),
        );
        assert_eq!(sent["sender"], writer.as_str());
        assert_eq!(state_and_reason(&sent, &reader), ("queued".into(), Value::Null));
        assert_eq!(state_and_reason(&sent, &other), ("held".into(), json!("cross_workspace")));
        let held = delivery(&sent, &other);
        assert!(held["held_until_ms"].is_string() && held["queued_at_ms"].is_null(), "{held}");
        assert!(delivery(&sent, &reader)["queued_at_ms"].is_string(), "{sent}");

        // An acpmux session acpmux places in the workspace: queued both ways.
        let near = daemon.acp_credential("near");
        let sent = daemon.sent(Some(&near), to(&reader, "from near"));
        assert_eq!(state_and_reason(&sent, &reader), ("queued".into(), Value::Null));
        let sent = daemon.sent(Some(&credential), to("acp:near", "to near"));
        assert_eq!(state_and_reason(&sent, "acp:near").0, "queued");

        // A session acpmux does not place: held, its workspace unknown.
        let stray = daemon.acp_credential("stray");
        let sent = daemon.sent(Some(&stray), to(&reader, "from stray"));
        assert_eq!(state_and_reason(&sent, &reader), ("held".into(), json!("workspace_unknown")));
        let sent = daemon.sent(Some(&credential), to("acp:stray", "to stray"));
        assert_eq!(
            state_and_reason(&sent, "acp:stray"),
            ("held".into(), json!("workspace_unknown"))
        );

        // The person's messages are never held.
        let sent = daemon.sent(
            None,
            json!({"recipients": [reader, other, "acp:stray"],
        "body": "from the person"}),
        );
        for recipient in [reader.as_str(), other.as_str(), "acp:stray"] {
            assert_eq!(state_and_reason(&sent, recipient).0, "queued", "{sent}");
        }

        // The list names each delivery's state, and filters by it.
        let held = daemon.list(json!({"state": "held"}));
        assert_eq!(held.len(), 3, "{held:?}");
    }

    #[test]
    fn the_cross_workspace_setting_refuses_or_allows() {
        let refuse = Daemon::start_owner_with(
            "refuse",
            &[("CMUX_AGENT_MESSAGE_CROSS_WORKSPACE", "refuse")],
            true,
        );
        let (_, alpha) = refuse.workspace("alpha");
        let (_, beta) = refuse.workspace("beta");
        refuse.place_session("a", &alpha);
        refuse.place_session("a2", &alpha);
        refuse.place_session("b", &beta);
        let a = refuse.acp_credential("a");
        let refused =
            refuse.send(Some(&a), json!({"recipients": ["acp:a2", "acp:b"], "body": "x"}));
        assert_eq!(refusal(&refused), ("operation.failed".into(), "cross_workspace".into()));
        assert!(refuse.list(json!({})).is_empty(), "a refused send stored a message");
        let sent = refuse.sent(Some(&a), to("acp:a2", "same workspace"));
        assert_eq!(state_and_reason(&sent, "acp:a2").0, "queued");
        // An unknown workspace is held, not refused.
        let sent = refuse.sent(Some(&a), to("acp:nowhere", "unknown"));
        assert_eq!(
            state_and_reason(&sent, "acp:nowhere"),
            ("held".into(), json!("workspace_unknown"))
        );
        drop(refuse);

        let allow = Daemon::start_owner_with(
            "allow",
            &[("CMUX_AGENT_MESSAGE_CROSS_WORKSPACE", "allow")],
            true,
        );
        let (_, alpha) = allow.workspace("alpha");
        let (_, beta) = allow.workspace("beta");
        allow.place_session("a", &alpha);
        allow.place_session("b", &beta);
        let a = allow.acp_credential("a");
        let sent = allow.sent(Some(&a), to("acp:b", "across"));
        assert_eq!(state_and_reason(&sent, "acp:b"), ("queued".into(), Value::Null));
        let sent = allow.sent(Some(&a), to("acp:nowhere", "unknown"));
        assert_eq!(state_and_reason(&sent, "acp:nowhere").0, "held");
        drop(allow);

        // Without acpmux no session's workspace is known: held, never refused.
        let alone = Daemon::start_owner_with(
            "no-acpmux",
            &[("CMUX_AGENT_MESSAGE_CROSS_WORKSPACE", "refuse")],
            false,
        );
        let a = alone.acp_credential("a");
        let sent = alone.sent(Some(&a), to("acp:b", "nobody knows"));
        assert_eq!(state_and_reason(&sent, "acp:b"), ("held".into(), json!("workspace_unknown")));
    }

    #[test]
    fn only_the_app_releases_or_declines_a_held_delivery() {
        let daemon = Daemon::start_owner("release");
        // No acpmux: the session's workspace is unknown, so both are held.
        let a = daemon.acp_credential("a");
        let first = id(&daemon.sent(
            Some(&a),
            json!({"recipients": ["acp:b", "acp:c"],
            "body": "held twice"}),
        ));
        let release = |recipient: &str, decision: &str| json!({"message_id": first, "recipient": recipient, "decision": decision});

        // A plain local connection may be an agent that left out its launch
        // credential: it is refused, over the protocol and through the CLI.
        let plain = daemon.mutate("agent.message.release", release("acp:b", "approve"), None);
        assert_eq!(refusal(&plain), ("operation.failed".into(), "release_needs_app".into()));
        let cli = daemon.cli(&[
            "agent",
            "message",
            "release",
            &first,
            "--recipient",
            "acp:b",
            "--approve",
        ]);
        assert!(!cli.status.success(), "the CLI released a held delivery");
        let stderr = String::from_utf8_lossy(&cli.stderr);
        assert!(stderr.contains("release_needs_app"), "{stderr}");
        let agent = daemon.mutate("agent.message.release", release("acp:b", "approve"), Some(&a));
        assert_eq!(refusal(&agent), ("operation.failed".into(), "release_needs_app".into()));
        assert_eq!(state_and_reason(&listed(&daemon, &first), "acp:b").0, "held");

        // The app approves and declines.
        let mut app = daemon.app();
        let approved = app.mutate("agent.message.release", release("acp:b", "approve"));
        assert_eq!(approved["ok"], true, "{approved}");
        let message = listed(&daemon, &first);
        assert_eq!(state_and_reason(&message, "acp:b"), ("queued".into(), json!("approved")));
        assert!(delivery(&message, "acp:b")["held_until_ms"].is_null(), "{message}");
        assert!(delivery(&message, "acp:b")["queued_at_ms"].is_string(), "{message}");
        let declined = app.mutate("agent.message.release", release("acp:c", "decline"));
        assert_eq!(declined["ok"], true, "{declined}");
        let message = listed(&daemon, &first);
        assert_eq!(state_and_reason(&message, "acp:c"), ("declined".into(), json!("declined")));

        // Only a held delivery takes a decision.
        let again = app.mutate("agent.message.release", release("acp:b", "decline"));
        assert_eq!(refusal(&again), ("operation.failed".into(), "not_held".into()));
        let missing = app.mutate("agent.message.release", release("acp:z", "approve"));
        assert_eq!(missing["ok"], false, "{missing}");
    }

    #[test]
    fn a_held_delivery_expires_after_a_day() {
        let daemon = Daemon::start_owner("expiry");
        let a = daemon.acp_credential("a");
        let message = id(&daemon.sent(Some(&a), to("acp:elsewhere", "waiting")));
        daemon.set_clock_offset(DAY_MS - 1_000);
        assert_eq!(state_and_reason(&listed(&daemon, &message), "acp:elsewhere").0, "held");

        daemon.set_clock_offset(DAY_MS + 1_000);
        let expired = listed(&daemon, &message);
        assert_eq!(
            state_and_reason(&expired, "acp:elsewhere"),
            ("declined".into(), json!("expired"))
        );
        assert_eq!(daemon.list(json!({"state": "held"})).len(), 0);
        let late = daemon.app().mutate(
            "agent.message.release",
            json!({"message_id": message,
            "recipient": "acp:elsewhere", "decision": "approve"}),
        );
        assert_eq!(refusal(&late), ("operation.failed".into(), "expired".into()));
        // The refused release stored nothing; the delivery still reads expired.
        let stored = listed(&daemon, &message);
        assert_eq!(
            state_and_reason(&stored, "acp:elsewhere"),
            ("declined".into(), json!("expired"))
        );
    }

    #[test]
    fn a_refused_send_never_asks_acpmux() {
        let daemon = Daemon::start_owner_with("lookups", &[], true);
        let (_, alpha) = daemon.workspace("alpha");
        daemon.place_session("a", &alpha);
        let a = daemon.acp_credential("a");
        for index in 0..5 {
            daemon.sent(Some(&a), to(&format!("acp:r{index}"), "hello"));
        }
        let asked = daemon.acpmux_lookups();
        let burst = daemon.send(Some(&a), to("acp:r5", "hello"));
        assert_eq!(refusal(&burst), ("operation.failed".into(), "rate_limited".into()));
        let address = daemon.send(Some(&a), to("not-an-agent", "hello"));
        assert_eq!(address["ok"], false, "{address}");
        let large = daemon.send(Some(&a), to("acp:r6", &"x".repeat(32 * 1024 + 1)));
        assert_eq!(refusal(&large), ("validation.invalid".into(), "body_too_large".into()));
        assert_eq!(daemon.acpmux_lookups(), asked, "a refused send asked acpmux");
    }

    #[test]
    fn a_sender_joins_only_a_thread_it_is_part_of() {
        let daemon = Daemon::start_owner_with("join", &[], true);
        let (_, alpha) = daemon.workspace("alpha");
        for session in ["a", "b", "c"] {
            daemon.place_session(session, &alpha);
        }
        let a = daemon.acp_credential("a");
        let b = daemon.acp_credential("b");
        let c = daemon.acp_credential("c");
        let first = id(&daemon.sent(
            Some(&a),
            json!({"recipients": ["acp:b"], "body": "start",
            "thread_id": "plan"}),
        ));

        // An outsider can neither start a message in the thread nor reply in it.
        let joined = daemon.send(
            Some(&c),
            json!({"recipients": ["acp:a"], "body": "me too",
            "thread_id": "plan"}),
        );
        assert_eq!(refusal(&joined), ("operation.failed".into(), "thread_not_joined".into()));
        let replied = daemon.send(
            Some(&c),
            json!({"recipients": ["acp:a"], "body": "me too",
            "in_reply_to": first}),
        );
        assert_eq!(refusal(&replied), ("operation.failed".into(), "thread_not_joined".into()));

        // Its sender and its recipients take part.
        daemon.sent(Some(&b), json!({"recipients": ["acp:a"], "body": "ok", "thread_id": "plan"}));
        daemon.sent(
            Some(&a),
            json!({"recipients": ["acp:c"], "body": "join us",
            "thread_id": "plan"}),
        );
        daemon.sent(
            Some(&c),
            json!({"recipients": ["acp:a"], "body": "joined",
            "thread_id": "plan"}),
        );
    }

    #[test]
    fn a_sender_may_burst_five_messages_in_ten_seconds() {
        let daemon = Daemon::start_owner_with("burst", &[], true);
        for index in 0..5 {
            daemon.sent(None, to(&format!("acp:r{index}"), "hello"));
        }
        let sixth = daemon.send(None, to("acp:r5", "hello"));
        assert_eq!(refusal(&sixth), ("operation.failed".into(), "rate_limited".into()));
        assert_eq!(sixth["error"]["details"]["extra"]["limit"], "burst", "{sixth}");
        // Another sender has its own budget.
        let other = daemon.acp_credential("other");
        daemon.sent(Some(&other), to("acp:r5", "hello"));
        daemon.set_clock_offset(11_000);
        daemon.sent(None, to("acp:r5", "hello"));
    }

    #[test]
    fn a_sender_may_address_one_recipient_twenty_times_a_minute() {
        let daemon = Daemon::start("pair", &[]);
        let mut offset = 0;
        for index in 0..20 {
            if index > 0 && index % 5 == 0 {
                offset += 11_000;
            }
            daemon.set_clock_offset(offset);
            daemon.sent(None, to("acp:busy", &format!("message {index}")));
        }
        daemon.set_clock_offset(offset + 11_000);
        let refused = daemon.send(None, to("acp:busy", "one more"));
        assert_eq!(refusal(&refused), ("operation.failed".into(), "rate_limited".into()));
        assert_eq!(refused["error"]["details"]["extra"]["limit"], "pair", "{refused}");
        daemon.sent(None, to("acp:quiet", "one more"));
        daemon.set_clock_offset(offset + 61_000);
        daemon.sent(None, to("acp:busy", "a minute later"));
    }

    #[test]
    fn a_recipient_has_at_most_fifty_messages_waiting() {
        let daemon = Daemon::start("queue", &[]);
        let offset = send_many(&daemon, None, "acp:full", 50);
        daemon.set_clock_offset(offset + 11_000);
        let refused = daemon.send(None, to("acp:full", "one more"));
        assert_eq!(refusal(&refused), ("operation.failed".into(), "queue_full".into()));

        // A delivered message no longer waits.
        let oldest = daemon.list(json!({"recipient": "acp:full", "limit": 1000}));
        let oldest = id(oldest.last().unwrap());
        let marked = daemon.mutate(
            "agent.message.mark",
            json!({"ids": [oldest],
        "recipient": "acp:full", "state": "delivered"}),
            None,
        );
        assert_eq!(marked["ok"], true, "{marked}");
        daemon.sent(None, to("acp:full", "one more"));
    }

    #[test]
    fn a_reply_may_be_eight_levels_deep() {
        let daemon = Daemon::start("depth", &[]);
        let mut parent = id(&daemon.sent(None, to("acp:peer", "root")));
        for depth in 1..=8 {
            daemon.set_clock_offset(i64::from(depth) * 11_000);
            let reply = daemon.sent(
                None,
                json!({"recipients": ["acp:peer"],
            "body": format!("reply {depth}"), "in_reply_to": parent}),
            );
            parent = id(&reply);
        }
        daemon.set_clock_offset(9 * 11_000);
        let deep = daemon.send(
            None,
            json!({"recipients": ["acp:peer"], "body": "reply 9",
        "in_reply_to": parent}),
        );
        assert_eq!(refusal(&deep), ("operation.failed".into(), "reply_depth".into()));
    }

    #[test]
    fn a_thread_holds_at_most_forty_messages() {
        let daemon = Daemon::start("thread", &[]);
        let mut offset = 0;
        for index in 0..40 {
            if index > 0 && index % 5 == 0 {
                offset += 11_000;
            }
            daemon.set_clock_offset(offset);
            daemon.sent(
                None,
                json!({"recipients": [format!("acp:r{}", index % 4)],
            "body": format!("message {index}"), "thread_id": "thread-one"}),
            );
        }
        daemon.set_clock_offset(offset + 11_000);
        let refused = daemon.send(
            None,
            json!({"recipients": ["acp:r9"], "body": "one more",
        "thread_id": "thread-one"}),
        );
        assert_eq!(refusal(&refused), ("operation.failed".into(), "thread_budget".into()));
        daemon.sent(
            None,
            json!({"recipients": ["acp:r9"], "body": "one more",
        "thread_id": "thread-two"}),
        );
    }

    #[test]
    fn a_body_is_at_most_32_kilobytes() {
        let daemon = Daemon::start("body", &[]);
        let refused = daemon.send(None, to("acp:reader", &"x".repeat(32 * 1024 + 1)));
        assert_eq!(refusal(&refused), ("validation.invalid".into(), "body_too_large".into()));
        daemon.sent(None, to("acp:reader", &"x".repeat(32 * 1024)));
    }

    #[test]
    fn the_same_message_twice_in_ten_seconds_is_dropped() {
        let daemon = Daemon::start("duplicate", &[]);
        daemon.sent(None, to("acp:reader", "same words"));
        let again = daemon.send(None, to("acp:reader", "same words"));
        assert_eq!(refusal(&again), ("operation.failed".into(), "duplicate".into()));
        daemon.sent(None, to("acp:someone-else", "same words"));
        daemon.set_clock_offset(11_000);
        daemon.sent(None, to("acp:reader", "same words"));
        assert_eq!(daemon.list(json!({})).len(), 3);
    }

    #[test]
    fn limits_survive_a_daemon_restart() {
        let mut daemon = Daemon::start("restart", &[]);
        for index in 0..5 {
            daemon.sent(None, to("acp:reader", &format!("message {index}")));
        }
        let sent_at = std::time::Instant::now();
        daemon.restart();
        // Turn the clock back by the restart's own time: the windows are 10 s.
        daemon.set_clock_offset(-i64::try_from(sent_at.elapsed().as_millis()).unwrap());
        let refused = daemon.send(None, to("acp:reader", "after the restart"));
        assert_eq!(refusal(&refused), ("operation.failed".into(), "rate_limited".into()));
        let duplicate = daemon.send(None, to("acp:reader", "message 4"));
        assert_eq!(refusal(&duplicate), ("operation.failed".into(), "duplicate".into()));
    }

    #[test]
    fn a_registry_with_the_first_delivery_table_keeps_its_messages() {
        let mut daemon = Daemon::start_owner_with("migration", &[], true);
        let first = id(&daemon.sent(
            None,
            json!({"recipients": ["acp:one", "acp:two"],
        "body": "before the upgrade"}),
        ));
        let marked = daemon.mutate(
            "agent.message.mark",
            json!({"ids": [first],
        "recipient": "acp:two", "state": "delivered", "via": "acp"}),
            None,
        );
        assert_eq!(marked["ok"], true, "{marked}");
        daemon.stop();

        // Put back the four-state table an older daemon wrote.
        let connection = rusqlite::Connection::open(daemon.registry()).unwrap();
        connection
            .execute_batch(
                "DROP INDEX IF EXISTS agent_message_deliveries_recipient;
             ALTER TABLE agent_message_deliveries RENAME TO current_deliveries;
             CREATE TABLE agent_message_deliveries (
               message_id TEXT NOT NULL,
               recipient TEXT NOT NULL,
               position INTEGER NOT NULL CHECK(position >= 0),
               state TEXT NOT NULL
                 CHECK(state IN ('queued','delivered','acknowledged','failed')),
               attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
               updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
               via TEXT,
               error TEXT,
               PRIMARY KEY(message_id, recipient)
             );
             CREATE INDEX agent_message_deliveries_recipient
               ON agent_message_deliveries(recipient, state);
             INSERT INTO agent_message_deliveries
               SELECT message_id, recipient, position, state, attempts, updated_at_ms, via, error
               FROM current_deliveries;
             DROP TABLE current_deliveries;",
            )
            .unwrap();
        drop(connection);

        daemon.restart();
        let message = listed(&daemon, &first);
        assert_eq!(message["body"], "before the upgrade");
        let one = delivery(&message, "acp:one");
        assert_eq!(one["state"], "queued", "{message}");
        assert!(one["queued_at_ms"].is_string() && one["created_at_ms"].is_string(), "{message}");
        let two = delivery(&message, "acp:two");
        assert_eq!(two["state"], "delivered", "{message}");
        assert_eq!(two["via"], "acp", "{message}");
        assert!(two["delivered_at_ms"].is_string(), "{message}");

        // The rebuilt table takes the new states.
        let (_, alpha) = daemon.workspace("alpha");
        daemon.place_session("a", &alpha);
        let a = daemon.acp_credential("a");
        let held = daemon.sent(Some(&a), to("acp:elsewhere", "after the upgrade"));
        assert_eq!(state_and_reason(&held, "acp:elsewhere").0, "held");
        daemon.stop();
        let connection = rusqlite::Connection::open(daemon.registry()).unwrap();
        let sql: String = connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE name = 'agent_message_deliveries'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(sql.contains("'held'") && sql.contains("held_until_ms"), "{sql}");
    }
}
