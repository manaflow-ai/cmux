use super::*;

#[test]
fn a_named_local_sender_may_say_its_harness_and_nothing_else() {
    let sent = |mux: Value| json!({"_meta": {"acpmux": mux}});
    let named = sent(json!({"fromAgent": "codex@workstation", "fromHarness": "codex"}));
    let harness = declared_harness(&named);
    assert_eq!(
        harness,
        Some(BoundSender { session_id: None, harness: Some("codex".into()), relay: None })
    );
    let stamped = stamp_sender(named_sender("codex@workstation", "s-2"), harness.as_ref());
    assert_eq!(stamped["kind"], "agent_message");
    assert_eq!(sender_of(Some(&stamped)), (None, Some("codex".into())));
    // No name, or a harness that is not a family name: no label.
    assert_eq!(declared_harness(&sent(json!({"fromHarness": "codex"}))), None);
    assert_eq!(declared_harness(&sent(json!({"fromAgent": "a", "fromHarness": "co dex"}))), None);
}

#[test]
fn a_peer_link_names_a_sender_only_for_its_own_prompt_and_only_well_formed() {
    let sent = |mux: Value| json!({"_meta": {"acpmux": mux}});
    let both = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude"}));
    let bound =
        BoundSender { session_id: Some("s-1".into()), harness: Some("claude".into()), relay: None };
    assert_eq!(peer_sender(&both), Some(bound.clone()));
    assert_eq!(sent(bound.mux_fields())["_meta"]["acpmux"], both["_meta"]["acpmux"]);
    // Forwarded for the peer's own Web, app or device client: no sender.
    let via = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude", "via": "web"}));
    assert_eq!(peer_sender(&via), None);
    // Malformed fields are dropped one by one, never refused.
    let odd = sent(json!({"fromSessionId": "s-1\nx", "fromHarness": "co dex"}));
    assert_eq!(peer_sender(&odd), None);
    let half = sent(json!({"fromSessionId": "s-2", "fromHarness": 7}));
    assert_eq!(peer_sender(&half).and_then(|s| s.session_id).as_deref(), Some("s-2"));
    assert_eq!(peer_sender(&json!({})), None);
}

#[test]
fn a_chief_turn_session_signs_with_the_chief_name_and_id() {
    let tag = |v: &str| crate::store::Tag { value: v.into(), expires_at: None };
    let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": "acpmux.session.v1", "id": "s-1", "name": "optchat-b902d10e-2991",
        "harness": "claude", "family": "claude", "cwd": "/tmp", "status": "idle",
        "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap();
    let found = |meta: &crate::store::SessionMeta| {
        let meta = meta.clone();
        move |id: &str| (id == "s-1").then(|| meta.clone())
    };
    let pumped = json!({"kind": "agent_message", "from": "acp:s-1", "to": "acp:s-2", "msgId": "m", "threadId": "t"});
    let sent = session_message("s-1", "optchat-b902d10e-2991", "s-2");
    // A session no Chief made: as it was.
    meta.tags.insert(LABEL_TAG.into(), tag("lane"));
    assert_eq!(stamp_chief(sent.clone(), found(&meta)), sent);
    assert_eq!(stamp_chief(pumped.clone(), found(&meta)), pumped);
    // A Chief's turn: the Chief's name and participant id, on both kinds.
    meta.tags.insert(LABEL_TAG.into(), tag("Ops Chief"));
    meta.tags.insert(CHIEF_PARTICIPANT_TAG.into(), tag("agent_ops"));
    for given in [sent, pumped] {
        let stamped = stamp_chief(given.clone(), found(&meta));
        assert_eq!(stamped["fromName"], "Ops Chief");
        assert_eq!(stamped[FROM_CHIEF], "agent_ops");
        assert_eq!(stamped["from"], given["from"]);
    }
    // Another sender, a person's prompt, or a sender this daemon does not have: untouched.
    let other = json!({"kind": "agent_message", "from": "acp:s-9", "to": "acp:s-2", "msgId": "m", "threadId": "t"});
    assert_eq!(stamp_chief(other.clone(), found(&meta)), other);
    let person = json!({"kind": "person_message", "from": "s-1", "fromName": "Ana"});
    assert_eq!(stamp_chief(person.clone(), found(&meta)), person);
}

#[test]
fn a_stamp_replaces_what_the_provenance_had_and_reads_back() {
    let given = json!({"kind": "agent_message", "from": "fromAgent", "fromHarness": "fake"});
    let bound =
        BoundSender { session_id: Some("s-1".into()), harness: Some("codex".into()), relay: None };
    let stamped = stamp_sender(given.clone(), Some(&bound));
    assert_eq!(sender_of(Some(&stamped)), (Some("s-1".into()), Some("codex".into())));
    assert_eq!(stamp_sender(given.clone(), None), given);
    assert_eq!(sender_of(None), (None, None));
    let mut params =
        json!({"_meta": {"acpmux": {"fromSessionId": "x", "fromHarness": "y", "promptId": "p"}}});
    drop_sender_fields(&mut params);
    assert_eq!(params, json!({"_meta": {"acpmux": {"promptId": "p"}}}));
}

#[test]
fn sender_records_accept_peer_stamps_but_not_client_written_sender_fields() {
    let raw = json!({
        "_meta": {"acpmux": {
            "provenance": {"kind": "agent_message", "from": "fromAgent", "fromName": "dot",
                "to": "target", "msgId": "m", "threadId": "t"},
            "fromSessionId": "claimed", "fromHarness": "codex"
        }}
    });
    let parsed = of(&raw, Sender::Local).unwrap().unwrap();
    assert_eq!(sender_of(Some(&parsed)), (None, None));
    assert_eq!(sender_record(Some(&parsed), None, None)["authenticated"], false);

    let peer = json!({
        "_meta": {"acpmux": {
            "fromSessionId": "peer-session", "fromHarness": "codex",
            "provenance": parsed
        }}
    });
    let stamped =
        stamp_sender(peer["_meta"]["acpmux"]["provenance"].clone(), peer_sender(&peer).as_ref());
    let record = sender_record(Some(&stamped), None, None);
    assert_eq!(record["session"], "peer-session");
    assert_eq!(record["authenticated"], true);
    assert_eq!(record["verification"], "verified");
}

#[test]
fn sender_records_keep_declared_labels_separate_from_authenticated_sessions() {
    let declared = named_sender("dot", "target");
    let record = sender_record(Some(&declared), None, None);
    assert_eq!(record["session"], Value::Null);
    assert_eq!(record["authenticated"], false);
    assert_eq!(record["label"], "dot");
    assert_eq!(record["labelDeclared"], true);
    assert_eq!(record["verification"], "declared");

    let authenticated = stamp_declared(
        stamp_sender(
            session_message("s-1", "worker", "target"),
            Some(&BoundSender {
                session_id: Some("s-1".into()),
                harness: Some("codex".into()),
                relay: None,
            }),
        ),
        Some("dot"),
    );
    let record = sender_record(Some(&authenticated), None, None);
    assert_eq!(record["session"], "s-1");
    assert_eq!(record["authenticated"], true);
    assert_eq!(record["label"], "dot");
    assert_eq!(record["verification"], "verified");
    assert_eq!(declared_label(Some(&authenticated)).as_deref(), Some("dot"));

    let person =
        json!({"kind": crate::author::PERSON_MESSAGE, "from": "user-1", "fromName": "Ana"});
    let unproven = sender_record(Some(&person), None, None);
    assert_eq!(unproven["authenticated"], false);
    assert_eq!(unproven["actorId"], Value::Null);
    let proven = sender_record_with_auth(Some(&person), None, None, true);
    assert_eq!(proven["actorKind"], "authenticated_human");
    assert_eq!(proven["actorId"], "user-1");
}

/// A relay's MACHINE/SESSION past `fromAgent`'s length (review of #37652, F1): the record
/// keeps the whole name and is a verified relay sender; the name it gives the sender label
/// fits `fromAgent`, so the send is never refused for it.
#[test]
fn a_long_relayed_name_is_recorded_whole_and_named_within_from_agent() {
    let relayed = |session: &str| json!({"_meta": {"acpmux": {"fromRelay": {"by": "lane-gh", "machine": "vm-1", "session": session}}}});
    let session = format!("cloud-start-matrix-{}", "x".repeat(60));
    let bound = relay_sender(&relayed(&session)).unwrap();
    let relay = bound.relay.clone().unwrap();
    assert_eq!(relay.session.as_deref(), Some(session.as_str()));
    let name = relay.name();
    assert_eq!(name.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
    assert!(format!("vm-1/{session}").starts_with(&name), "{name}");
    let label = json!({"_meta": {"acpmux": {"fromAgent": name}}});
    assert_eq!(crate::hub::declared_sender(&label).unwrap(), Some(name.clone()));
    let stamped = stamp_sender(stamp_declared(named_sender(&name, "t"), Some(&name)), Some(&bound));
    let record = sender_record(Some(&stamped), None, None);
    assert_eq!(
        (&record["verification"], &record["relay"]["session"]),
        (&json!("verified"), &json!(session))
    );
    // A short one is named whole; a session past what a relay record holds is no record.
    assert_eq!(relay_sender(&relayed("coord")).unwrap().relay.unwrap().name(), "vm-1/coord");
    assert_eq!(relay_sender(&relayed(&"x".repeat(MAX_FIELD_BYTES + 1))), None);
}

#[test]
fn sender_records_keep_a_relay_author_and_forwarder_distinct() {
    let provenance = json!({
        "kind": "agent_message", "from": "fromAgent", "fromName": "worker",
        "fromSessionId": "forwarder", "fromHarness": "codex",
        "_acpmuxMessage": {"sender": {"sessionId": "author", "name": "original"},
            "forwardedBy": {"session": "forwarder"}},
    });
    let record = sender_record(Some(&provenance), None, None);
    assert_eq!(record["author"]["sessionId"], "author");
    assert_eq!(record["forwardedBy"]["session"], "forwarder");
    assert_eq!(record["actorId"], "forwarder");
}

#[test]
fn sender_records_keep_worker_and_delegator_distinct() {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "worker", "name": "worker",
        "harness": "codex", "cwd": "/tmp", "status": "idle",
        "createdAt": 1, "updatedAt": 1,
        "lineage": {"parent": "root", "root": "root", "depth": 1},
        "delegator": "root"
    }))
    .expect("session metadata");
    let provenance = stamp_sender(
        session_message("worker", "worker", "receiver"),
        Some(&BoundSender {
            session_id: Some("worker".into()),
            harness: Some("codex".into()),
            relay: None,
        }),
    );
    let record = sender_record(Some(&provenance), None, Some(&meta));
    assert_eq!(record["actorKind"], "codex_worker");
    assert_eq!(record["actorId"], "worker");
    assert_eq!(record["parent"], "root");
    assert_eq!(record["delegator"], "root");
}

#[test]
fn sender_actor_metadata_uses_the_stamped_session_not_provenance_from() {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "worker", "name": "worker",
        "harness": "codex", "cwd": "/tmp", "status": "idle",
        "createdAt": 1, "updatedAt": 1,
        "lineage": {"parent": "root", "root": "root", "depth": 1},
        "delegator": "root"
    }))
    .expect("session metadata");
    let provenance = stamp_sender(
        json!({"kind": "session_message", "from": "acp:root", "fromName": "root", "to": "receiver"}),
        Some(&BoundSender {
            session_id: Some("worker".into()),
            harness: Some("codex".into()),
            relay: None,
        }),
    );
    let record = sender_record_with_auth(Some(&provenance), Some("root"), Some(&meta), false);
    assert_eq!(record["actorId"], "worker");
    assert_eq!(record["actorKind"], "codex_worker");
    assert_eq!(record["parent"], "root");
    assert_eq!(record["delegator"], "root");
}
