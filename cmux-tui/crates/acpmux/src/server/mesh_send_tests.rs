use super::*;

#[test]
fn host_and_a_session_id_name_that_session_by_id() {
    let id = "01a1acb2-5bb4-75a3-b5eb-a0eeea1d59d5";
    let to = recipient(&format!("machine-b/{id}"));
    assert_eq!(
        (to.session_id.as_deref(), to.name, to.host.as_deref()),
        (Some(id), None, Some("machine-b"))
    );
    let to = recipient("machine-b/own-e2e");
    assert_eq!((to.name.as_deref(), to.session_id), (Some("own-e2e"), None));
}

/// A send or prompt to a chat the hub lists, named by its given handle (`HOST/Mango`,
/// `Mango`), goes to its machine by id: the hub and the far daemon match names only. A name
/// still goes as a name. Leo, 2026-11-23: "the send/recieve messages are still only the
/// older names".
#[tokio::test]
async fn a_handle_the_hub_lists_is_sent_to_by_id() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let id = "01a1acb2-5bb4-75a3-b5eb-a0eeea1d59d5";
    let book = crate::mesh::AddressBook {
        daemons: vec![crate::mesh::BookDaemon {
            daemon_id: "d-b".into(),
            host: "machine-b".into(),
            user: "person-1".into(),
            last_seen_at: 5,
        }],
        sessions: vec![crate::mesh::BookSession {
            name: "claude-sr2-coord-old".into(),
            session_id: id.into(),
            host: "machine-b".into(),
            daemon_id: "d-b".into(),
            harness: "claude".into(),
            state: "idle".into(),
            handle: Some("Mango".into()),
            ..Default::default()
        }],
    };
    hub.apply_mesh_book(book, "person-1", Some("d-a"));
    for key in ["machine-b/Mango", "Mango"] {
        let to = recipient_in(&hub, key);
        assert_eq!(
            (to.session_id.as_deref(), to.name.as_deref(), to.host.as_deref()),
            (Some(id), None, Some("machine-b")),
            "{key}"
        );
        assert_eq!(
            super::super::mesh_relay::read::hub_prompt_target(&hub, key),
            Some(format!("machine-b/{id}")),
            "{key}"
        );
    }
    let to = recipient_in(&hub, "machine-b/claude-sr2-coord-old");
    assert_eq!(to.name.as_deref(), Some("claude-sr2-coord-old"));
    assert_eq!(recipient_in(&hub, "machine-b/Kiwi").name.as_deref(), Some("Kiwi"));
}

/// gap:surface:naming: a send no session made names its program in the relay record it
/// carries; one a session made carries none, and a name no relay record fits carries none.
#[test]
fn a_program_outside_any_session_carries_its_name_as_the_relay_record() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let from = sender(&hub, None, Some("glaeda-land".into()), None, None);
    let relay = from.relay.as_ref().and_then(crate::prompt_provenance::RelaySender::of);
    let relay = relay.expect("a relay record");
    assert_eq!(relay.by, "glaeda-land");
    assert_eq!(relay.machine, crate::pairing::mesh_host());
    assert_eq!(relay.session, None);
    // The hub's schema took `session: null` as a 400 (2026-11-24): no session is no key.
    assert!(from.relay.as_ref().unwrap().get("session").is_none(), "{:?}", from.relay);
    let broker = json!({"by": "lane-gh", "machine": "m", "session": "lane-7"});
    let from = sender(&hub, None, Some("glaeda-land".into()), None, Some(broker.clone()));
    assert_eq!(from.relay, Some(broker.clone()));
    assert_eq!(sender(&hub, Some("s-1"), None, None, Some(broker)).relay, None);
    assert_eq!(sender(&hub, None, Some("two words".into()), None, None).relay, None);
    assert_eq!(sender(&hub, None, None, None, None).relay, None);
}

/// cmuxterm-hq#17418: `class: question` to 9 sessions reached only through the relay sent 0
/// of 9 ("cannot carry --class"). The class now goes as the text's first line, the sender's
/// row says so, and a send with no class (or result) is the text it always was.
#[test]
fn a_class_the_relay_cannot_carry_goes_as_the_first_line() {
    let request = |class: Option<&str>| {
        json!({"sessionId": "host-b/lane-a", "prompt": [{"type": "text", "text": "ship it?"}],
            "_meta": {"acpmux": {"class": class, "promptId": "0190f2a4-7c1e-7d3a-9f00-0123456789ab"}}})
    };
    let sent = carried(&request(Some("question")), "host-b/lane-a").unwrap();
    assert_eq!(sent.body, "[question]\n\nship it?");
    assert_eq!(sent.inline, Some(PromptClass::Question));
    let sent = carried(&request(Some("blocker")), "host-b/lane-a").unwrap();
    assert!(sent.body.starts_with("[block]\n\n"), "{}", sent.body);
    for class in [None, Some("result"), Some("action")] {
        let sent = carried(&request(class), "host-b/lane-a").unwrap();
        assert_eq!((sent.body.as_str(), sent.inline), ("ship it?", None), "{class:?}");
    }
    let mut row = json!({"status": "queued"});
    class_note(&mut row, Some(PromptClass::Question), false);
    assert_eq!(row["classInline"], "question");
    assert!(row["note"].as_str().unwrap().contains("[question]"), "{row}");
    // A supersede key is dropped, and the row says so, with the class's note.
    let mut keyed = request(Some("question"));
    keyed["_meta"]["acpmux"]["supersede"] = json!("status");
    let sent = carried(&keyed, "host-b/lane-a").unwrap();
    assert!(sent.dropped_supersede && sent.body.starts_with("[question]"), "{}", sent.body);
    assert!(!carried(&request(None), "host-b/lane-a").unwrap().dropped_supersede);
    let mut row = json!({"status": "queued"});
    class_note(&mut row, sent.inline, sent.dropped_supersede);
    let note = row["note"].as_str().unwrap();
    assert!(note.contains("[question]") && note.contains("no supersede key"), "{row}");
    assert_eq!(row["supersedeDropped"], true);
    // What it still cannot carry is still refused, by name.
    let mut attach = request(None);
    attach["prompt"] = json!([{"type": "image", "data": "x"}]);
    assert!(carried(&attach, "host-b/lane-a").is_err());
}

/// The census of 2026-11-23 (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md)
/// replayed: its sends refused by the relay, 29 with a class and 3 with a supersede key.
/// Prints how many still bounce; the same test on the code before gives the before number.
#[test]
fn census_replay_mesh_relay() {
    let request = |key: &str, value: &str| {
        json!({"sessionId": "host-b/lane-a", "prompt": [{"type": "text", "text": "t"}],
            "_meta": {"acpmux": {key: value}}})
    };
    let (mut n, mut bad) = (0, 0);
    for (sent, weight) in [(request("class", "question"), 29), (request("supersede", "s"), 3)] {
        n += weight;
        bad += if carried(&sent, "host-b/lane-a").is_err() { weight } else { 0 };
    }
    eprintln!("census replay: send (mesh relay): {bad} of {n} bounce");
}

#[test]
fn a_prompt_id_the_hub_would_refuse_as_a_key_is_digested() {
    let id = "0190f2a4-7c1e-7d3a-9f00-0123456789ab";
    assert_eq!(idempotency_key(id), id);
    let short = idempotency_key("abc");
    assert!(short.starts_with("p:") && short.len() == 42, "{short}");
    assert_eq!(idempotency_key("has space in it"), idempotency_key("has space in it"));
    assert_eq!(recipient("huge-blue/dep-land").host.as_deref(), Some("huge-blue"));
    assert_eq!(recipient("dep-land").host, None);
    assert_eq!(
        recipient("@lawrence/coordinator").team_address.as_deref(),
        Some("@lawrence/coordinator")
    );
    assert!(valid_team_address("@team/role"));
    assert!(valid_team_address("@member/reviewer:backend"));
    assert!(!valid_team_address("@team"));
}
