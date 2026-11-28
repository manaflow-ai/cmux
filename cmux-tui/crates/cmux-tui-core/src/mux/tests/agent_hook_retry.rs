//! Agent hook projection retries, replay, and quarantine.

use super::*;

#[test]
fn replayed_agent_hook_events_do_not_rewrite_the_record() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface_id).unwrap() {
            ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let started = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({"session_id":"native-1"}),
    )
    .unwrap();
    mux.append_journal_ingress(&started, "test", "hook-replay").unwrap();
    let working_at = mux.list_agents(Some(surface_id), None)[0].updated_at_ms;

    let replay = mux.append_journal_ingress(&started, "test", "hook-replay").unwrap();
    assert!(replay.replayed);
    let record = &mux.list_agents(Some(surface_id), None)[0];
    assert_eq!(record.state, AgentState::Working);
    assert_eq!(record.updated_at_ms, working_at);
}

#[test]
fn replay_of_an_old_plugin_receipt_survives_manifest_upgrade() {
    let mux = test_mux();
    let manifest = |manifest_version| crate::JournalProducerManifest {
        producer_id: "screen_test".into(),
        namespace: "plugin.screen_test".into(),
        manifest_version,
        max_sensitivity: crate::JournalSensitivity::Metadata,
        permissions: vec!["journal.append.plugin.screen_test".into()],
        events: vec![crate::JournalEventSchema {
            kind: "plugin.screen_test.observation".into(),
            schema_version: 1,
            class: crate::JournalClass::Observation,
            replay: crate::JournalReplayPolicy::Advisory,
            sensitivity: crate::JournalSensitivity::Metadata,
            payload_schema: serde_json::json!({"type":"object"}),
        }],
    };
    mux.put_journal_producer(&manifest(1), "test", "producer-v1").unwrap();
    let ingress = crate::JournalIngress {
        producer_id: "screen_test".into(),
        manifest_version: 1,
        kind: "plugin.screen_test.observation".into(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: Vec::new(),
        sensitivity: None,
        payload: serde_json::json!({"state":"idle"}),
        causation_id: None,
        correlation_id: None,
    };
    let first = mux.append_journal_ingress(&ingress, "screen", "observation-1").unwrap();
    assert!(!first.replayed);

    mux.put_journal_producer(&manifest(2), "test", "producer-v2").unwrap();

    let replay = mux.append_journal_ingress(&ingress, "screen", "observation-1");
    assert!(replay.is_ok(), "an old receipt must remain replayable: {replay:?}");
    assert!(replay.unwrap().replayed);
}

#[test]
fn a_plugin_projection_lost_after_journal_commit_is_reconciled_from_the_roster() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-plugin-reconcile-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "plugin-reconcile";
    let terminal_id;
    {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let mux = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let surface = mux.new_workspace(None, None).unwrap();
        terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
        let manifest = crate::JournalProducerManifest {
            producer_id: "screen_test".into(),
            namespace: "plugin.screen_test".into(),
            manifest_version: 1,
            max_sensitivity: crate::JournalSensitivity::Metadata,
            permissions: vec!["journal.append.plugin.screen_test".into()],
            events: vec![crate::JournalEventSchema {
                kind: "plugin.screen_test.agent.state.changed".into(),
                schema_version: 1,
                class: crate::JournalClass::State,
                replay: crate::JournalReplayPolicy::Advisory,
                sensitivity: crate::JournalSensitivity::Metadata,
                payload_schema: serde_json::json!({"type":"object"}),
            }],
        };
        mux.put_journal_producer(&manifest, "test", "plugin-reconcile-manifest").unwrap();
        let ingress = crate::JournalIngress {
            producer_id: "screen_test".into(),
            manifest_version: 1,
            kind: "plugin.screen_test.agent.state.changed".into(),
            schema_version: 1,
            occurred_at_ms: None,
            subjects: vec![crate::JournalSubject {
                kind: "terminal".into(),
                id: terminal_id.to_string(),
            }],
            sensitivity: None,
            payload: serde_json::json!({
                "format": crate::journal_reducers::AGENT_PLUGIN_FORMAT,
                "plugin": {"id":"screen_test", "version":1},
                "adapter": {"id":"codex", "version":1},
                "event": "state.changed",
                "normalized": {
                    "state":"working",
                    "source_session":"pid:42",
                    "observed_at_ms":"100"
                }
            }),
            causation_id: None,
            correlation_id: None,
        };
        let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
        let commit = mux
            .workspace_registry
            .lock()
            .unwrap()
            .append_journal_ingress(&ingress, &validated, "test", "plugin-reconcile-event")
            .unwrap();

        // The journal transaction has committed. Fail only the following
        // projection transaction to model a daemon crash in that window.
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
        mux.fold_agent_roster(&ingress, &commit);
        assert_eq!(mux.list_agents(Some(surface.id), None).len(), 1);
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 0);
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();

        // Startup runs this reconciliation after restored surfaces exist
        // and again as each terminal host is adopted. The unit runtime's
        // placeholder terminals have no host to adopt after a restart, so
        // exercise the reconciliation on the live terminal directly.
        mux.reconcile_agent_roster_projections();
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
        let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
        let agent = &snapshot["agents"][0];
        assert_eq!(agent["terminal_id"], terminal_id.as_str());
        assert_eq!(agent["state"], "working");
        assert_eq!(agent["source"], "plugin");
        assert_eq!(agent["source_session"], "pid:42");
        assert_eq!(agent["extra"]["agent"], "codex");
        // A healthy projection is left alone.
        let revision = mux.with_state(|state| state.resource_revision);
        mux.reconcile_agent_roster_projections();
        assert_eq!(mux.with_state(|state| state.resource_revision), revision);
        mux.shutdown();
    }

    // The roster is durable reducer state, so the observation that the
    // projection must be rebuilt from survives a restart.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let entry = reopened.agent_roster.lock().unwrap().roster.entries[terminal_id.as_str()].clone();
    assert_eq!(entry.agent_state(), AgentState::Working);
    assert_eq!(entry.agent_source(), AgentSource::Plugin);
    assert_eq!(entry.agent.as_deref(), Some("codex"));
    assert_eq!(entry.session.as_deref(), Some("pid:42"));
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn failed_agent_hook_projection_does_not_consume_sequence() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
    let receipt = mux
        .workspace_registry
        .lock()
        .unwrap()
        .append_journal_ingress(&ingress, &validated, "test", "hook-pending-retry")
        .unwrap();
    assert!(receipt.sequence > 0);
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        1
    );
    let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
    mux.workspace_registry
        .lock()
        .unwrap()
        .append_journal_ingress(&ingress, &validated, "other-origin", "hook-pending-retry")
        .unwrap();
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        2
    );
    assert!(mux.list_agents(Some(surface.id), None).is_empty());
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    mux.retry_pending_agent_hooks().unwrap();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    let replay = mux.append_journal_ingress(&ingress, "test", "hook-pending-retry").unwrap();
    assert!(replay.replayed);
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        1
    );
    mux.append_journal_ingress(&ingress, "other-origin", "hook-pending-retry").unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
    assert_eq!(mux.list_agents(Some(surface.id), None)[0].state, AgentState::Working);
}

#[test]
fn journal_commit_preseeds_hook_retry_before_projection() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
    let commit = mux
        .workspace_registry
        .lock()
        .unwrap()
        .append_journal_ingress(&ingress, &validated, "test", "crash-window")
        .unwrap();
    assert!(!commit.replayed);
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        1
    );

    let replay = mux.append_journal_ingress(&ingress, "test", "crash-window").unwrap();
    assert!(replay.replayed);
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
    assert_eq!(mux.list_agents(Some(surface.id), None)[0].state, AgentState::Working);
}

#[test]
fn available_agent_report_wakes_pending_hook_projection_retry() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
    let commit = mux
        .workspace_registry
        .lock()
        .unwrap()
        .append_journal_ingress(&ingress, &validated, "test", "hook-wake")
        .unwrap();
    assert!(!commit.replayed);
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        1
    );

    mux.report_agent(surface.id, AgentState::Working, AgentSource::Socket, None).unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
    assert_eq!(mux.list_agents(Some(surface.id), None)[0].source, AgentSource::Hook);
}

#[test]
fn unavailable_terminal_hook_is_retained_for_projection_retry() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    // Keep the durable terminal in its Running lifecycle while removing
    // the in-memory catalog entry, which models a recoverable adoption
    // gap rather than a terminal that can never return.
    assert!(mux.remove_terminal_catalog_for_test(&terminal_id).is_some());
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();

    let receipt = mux.append_journal_ingress(&ingress, "test", "missing-terminal").unwrap();
    assert!(receipt.sequence > 0);
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .pending_agent_hook_projections_for_terminal(&terminal_id)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn unavailable_terminal_hook_retries_without_consuming_attempt_budget() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    assert!(mux.remove_terminal_catalog_for_test(&terminal_id).is_some());
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();

    for attempt in 0..3 {
        mux.append_journal_ingress(&ingress, "test", "transient-budget").unwrap();
        let retry_state = mux
            .workspace_registry
            .lock()
            .unwrap()
            .agent_hook_pending_retry_state_for_test(
                crate::agent_hooks::AGENT_HOOK_PRODUCER_ID,
                "test",
                "transient-budget",
            )
            .unwrap()
            .expect("unavailable terminal hook remains pending");
        assert_eq!(retry_state.0, 0, "transient retry consumed attempt {attempt}");
    }
}

#[test]
fn agent_hook_retry_class_uses_typed_transient_errors() {
    let unavailable = anyhow::Error::new(AgentHookTerminalUnavailable)
        .context("terminal term_secret is not available for agent hook projection");
    assert_eq!(
        agent_hook_retry_class(&unavailable),
        crate::workspace_registry::AgentHookRetryClass::Transient
    );
    assert_eq!(
        agent_hook_retry_class(&anyhow::anyhow!("invalid terminal subject")),
        crate::workspace_registry::AgentHookRetryClass::Permanent
    );
}

#[test]
fn agent_report_retries_only_pending_hooks_for_its_terminal() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let second = mux.new_workspace(None, None).unwrap();
    let terminal_id =
        |surface: &Surface| surface.terminal_public_id().cloned().expect("workspace terminal");
    let first_terminal = terminal_id(&first);
    let second_terminal = terminal_id(&second);
    // Drive these rows through the Mux ingress path. A direct registry
    // append bypasses the roster fold and cannot model a real pending
    // hook, because the roster is derived only from committed ingress.
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    let hook = |terminal_id: &TerminalPublicId, key: &str| {
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            "UserPromptSubmit",
            Some(&terminal_id.to_string()),
            serde_json::json!({}),
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", key).unwrap();
    };

    hook(&first_terminal, "first-pending");
    hook(&second_terminal, "second-pending");
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();

    mux.report_agent(first.id, AgentState::Working, AgentSource::Socket, None).unwrap();
    let pending = mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].0, crate::agent_hooks::AGENT_HOOK_PRODUCER_ID);
    assert!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .pending_agent_hook_projections_for_terminal(&first_terminal)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .pending_agent_hook_projections_for_terminal(&second_terminal)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(mux.list_agents(Some(first.id), None)[0].source, AgentSource::Hook);
    // The roster is journal-derived and folds the second hook even while
    // its public resource projection waits in the retry queue. The
    // terminal-scoped retry must still leave that second hook pending.
    assert_eq!(mux.list_agents(Some(second.id), None)[0].source, AgentSource::Hook);

    mux.report_agent(second.id, AgentState::Working, AgentSource::Socket, None).unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
    assert_eq!(mux.list_agents(Some(second.id), None)[0].source, AgentSource::Hook);
}

#[test]
fn terminal_report_drains_more_than_one_pending_retry_page() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
    for index in 0..65 {
        mux.workspace_registry
            .lock()
            .unwrap()
            .append_journal_ingress(&ingress, &validated, "test", &format!("pending-page-{index}"))
            .unwrap();
    }
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        65
    );

    mux.report_agent(surface.id, AgentState::Working, AgentSource::Socket, None).unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
    assert_eq!(mux.list_agents(Some(surface.id), None)[0].source, AgentSource::Hook);
}

#[test]
fn permanently_failed_hook_projection_is_quarantined() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let validated = mux.journal_kernel.validate_ingress(&ingress).unwrap();
    let receipt = mux
        .workspace_registry
        .lock()
        .unwrap()
        .append_journal_ingress(&ingress, &validated, "test", "dead-letter")
        .unwrap();
    assert!(receipt.sequence > 0);
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    for _ in 0..crate::workspace_registry::AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE {
        mux.retry_pending_agent_hooks_for_terminal(&terminal_id).unwrap();
    }
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();

    let retry_state = mux
        .workspace_registry
        .lock()
        .unwrap()
        .agent_hook_pending_retry_state_for_test(
            crate::agent_hooks::AGENT_HOOK_PRODUCER_ID,
            "test",
            "dead-letter",
        )
        .unwrap()
        .expect("failed hook remains durable");
    assert_eq!(retry_state.0, crate::workspace_registry::AGENT_HOOK_MAX_ATTEMPTS);
    assert_eq!(retry_state.1, "agent hook retry limit reached");
    assert!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .pending_agent_hook_projections_for_terminal(&terminal_id)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len(),
        1
    );
}

#[test]
fn sessionless_legacy_hook_identity_survives_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-legacy-marker-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("legacy-marker", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let ingress = |event: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({}),
        )
        .unwrap()
    };

    mux.apply_agent_hook_record(&ingress("SessionStart"), 1).unwrap();
    let first_session_id = mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id.clone();
    assert_eq!(first_session_id, format!("legacy:{terminal_id}:1"));
    mux.shutdown();
    drop(mux);

    let mux = open_persistent_test_mux("legacy-marker", &root);
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, first_session_id);
    let next = ingress("UserPromptSubmit");
    assert_eq!(next.kind, "agent.turn.started");
    let restored_fence = mux.agent_hook_fences.lock().unwrap()[&terminal_id].clone();
    assert!(matches!(
        HookFence::journal_transition(
            Some(&restored_fence),
            terminal_id.as_str(),
            None,
            false,
            2,
            None,
        ),
        JournalHookTransition::Apply(session_id) if session_id == first_session_id
    ));
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
