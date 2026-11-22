use super::*;

fn hook(manifest_version: u32) -> JournalHookManifest {
    JournalHookManifest {
        hook_id: "active_hook".into(),
        manifest_version,
        filter: JournalHookFilter::default(),
        exec: JournalHookExec {
            argv: vec!["/usr/bin/true".into()],
            timeout_ms: 1_000,
            max_parallel: 1,
        },
        delivery: JournalHookDeliveryPolicy {
            start: "tail".into(),
            retry: JournalHookRetry { max_attempts: 1, backoff_ms: 0 },
        },
        permissions: vec!["journal.read".into()],
    }
}

#[test]
fn journal_hook_states_exclude_disabled_manifest_history() {
    let mut registry = WorkspaceRegistry::in_memory("active-hooks").unwrap();
    registry.put_journal_hook(&hook(1), "client_test", "hook_v1").unwrap();
    registry.put_journal_hook(&hook(2), "client_test", "hook_v2").unwrap();

    let states = registry.journal_hook_states().unwrap();
    assert_eq!(states.len(), 1);
    assert_eq!(states[0].manifest.manifest_version, 2);
    assert!(states[0].enabled);
}

#[test]
fn userland_producer_list_excludes_reserved_hook_manifest() {
    let mut registry = WorkspaceRegistry::in_memory("userland-producers").unwrap();
    let manifest = JournalProducerManifest {
        producer_id: "screen_detector".into(),
        namespace: "plugin.screen_detector".into(),
        manifest_version: 1,
        max_sensitivity: JournalSensitivity::Metadata,
        permissions: vec!["journal.append.plugin.screen_detector".into()],
        events: vec![JournalEventSchema {
            kind: "plugin.screen_detector.agent.state.changed".into(),
            schema_version: 1,
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Metadata,
            payload_schema: json!({"type":"object"}),
        }],
    };
    registry.put_journal_producer(&manifest, "client_test", "producer_1").unwrap();

    let all = registry.journal_producer_manifests().unwrap();
    assert!(all.iter().any(|item| item.producer_id == crate::AGENT_HOOK_PRODUCER_ID));
    assert!(all.iter().any(|item| item.producer_id == "screen_detector"));

    let userland = registry.userland_journal_producer_manifests().unwrap();
    assert_eq!(userland.len(), 1);
    assert_eq!(userland[0], manifest);
}

#[test]
fn legacy_built_in_agent_manifest_is_migrated() {
    let registry = WorkspaceRegistry::in_memory("legacy-agent-manifest").unwrap();
    let current = crate::agent_hooks::built_in_agent_producer_manifest();
    let mut legacy = current.clone();
    legacy.events.retain(|event| event.kind != "agent.plugin.exited");
    for event in &mut legacy.events {
        event.payload_schema["properties"]["adapter"]["properties"]["id"]["pattern"] =
            Value::String("^[a-z0-9_-]+$".into());
    }
    let legacy_json = canonical_json(&serde_json::to_value(&legacy).unwrap()).unwrap();
    registry
        .connection
        .get()
        .execute(
            "UPDATE journal_producers SET manifest_json = ?1 WHERE producer_id = ?2",
            params![legacy_json, crate::AGENT_HOOK_PRODUCER_ID],
        )
        .unwrap();

    let db = registry.connection.get();
    let transaction = db.unchecked_transaction().unwrap();
    ensure_built_in_agent_producer(&transaction).unwrap();
    transaction.commit().unwrap();

    let installed = registry
        .connection
        .get()
        .query_row(
            "SELECT manifest_json FROM journal_producers WHERE producer_id = ?1",
            [crate::AGENT_HOOK_PRODUCER_ID],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    assert_eq!(serde_json::from_str::<JournalProducerManifest>(&installed).unwrap(), current);
}

#[test]
fn legacy_agent_manifest_with_plugin_exit_is_migrated() {
    let registry = WorkspaceRegistry::in_memory("legacy-agent-plugin-exit").unwrap();
    let current = crate::agent_hooks::built_in_agent_producer_manifest();
    let legacy = legacy_built_in_agent_producer_manifests(&current).into_iter().nth(1).unwrap();
    let legacy_json = canonical_json(&serde_json::to_value(&legacy).unwrap()).unwrap();
    registry
        .connection
        .get()
        .execute(
            "UPDATE journal_producers SET manifest_json = ?1 WHERE producer_id = ?2",
            params![legacy_json, crate::AGENT_HOOK_PRODUCER_ID],
        )
        .unwrap();

    let db = registry.connection.get();
    let transaction = db.unchecked_transaction().unwrap();
    ensure_built_in_agent_producer(&transaction).unwrap();
    transaction.commit().unwrap();

    let installed = registry
        .journal_producer_manifests()
        .unwrap()
        .into_iter()
        .find(|manifest| manifest.producer_id == crate::AGENT_HOOK_PRODUCER_ID)
        .unwrap();
    assert_eq!(installed, current);
}

#[test]
fn unknown_built_in_agent_manifest_still_fails_closed() {
    let registry = WorkspaceRegistry::in_memory("unknown-agent-manifest").unwrap();
    let mut tampered = crate::agent_hooks::built_in_agent_producer_manifest();
    tampered.events[0].kind = "agent.untrusted".into();
    let tampered_json = canonical_json(&serde_json::to_value(&tampered).unwrap()).unwrap();
    registry
        .connection
        .get()
        .execute(
            "UPDATE journal_producers SET manifest_json = ?1 WHERE producer_id = ?2",
            params![tampered_json, crate::AGENT_HOOK_PRODUCER_ID],
        )
        .unwrap();

    let db = registry.connection.get();
    let transaction = db.unchecked_transaction().unwrap();
    let error = ensure_built_in_agent_producer(&transaction).unwrap_err();
    assert!(error.to_string().contains("does not match this binary"));
}

#[test]
fn checkpoint_digest_is_verified_when_read() {
    let mut registry = WorkspaceRegistry::in_memory("checkpoint-integrity").unwrap();
    let commit = registry
        .create_journal_checkpoint(
            0,
            1,
            &json!({"session_snapshot":{"cursor":{"revision":"0"}}}),
            &[],
            "client_test",
            "checkpoint_1",
        )
        .unwrap();
    registry
        .connection
        .get()
        .execute_batch("DROP TRIGGER journal_checkpoints_reject_update;")
        .unwrap();
    registry
        .connection
        .get()
        .execute(
            "UPDATE journal_checkpoints SET state_json = '{\"tampered\":true}'
                 WHERE checkpoint_id = ?1",
            [&commit.checkpoint.checkpoint_id],
        )
        .unwrap();

    let error = registry.journal_checkpoint(&commit.checkpoint.checkpoint_id).unwrap_err();
    assert!(error.to_string().contains("digest"), "{error:#}");
}
