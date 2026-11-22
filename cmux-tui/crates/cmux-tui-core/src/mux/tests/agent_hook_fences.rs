//! Agent hook session fences: ended sessions, late events, and reserved markers.

use super::*;

#[test]
fn late_socket_report_cannot_resurrect_hook_ended_agent() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let initial_revision = mux.with_state(|state| state.resource_revision);
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let ended = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "SessionEnd",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    mux.apply_agent_hook_record(&ended, 9).unwrap();
    let ended_events = mux.resource_events_after(initial_revision).unwrap();
    assert_eq!(ended_events.batches.len(), 1);
    let ended_change = &ended_events.batches[0].changes[0];
    assert_eq!(ended_change["kind"], "delete");
    assert_eq!(ended_change["resource"], "agent");
    assert!(ended_change.get("value").is_none());
    let delayed = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    mux.apply_agent_hook_record(&delayed, 10).unwrap();
    assert!(mux.list_agents(Some(surface.id), None).is_empty());
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert!(snapshot["agents"].as_array().unwrap().is_empty());
    assert!(mux.report_agent(surface.id, AgentState::Working, AgentSource::Socket, None).is_err());
    assert!(mux.report_agent(surface.id, AgentState::Working, AgentSource::Hook, None).is_err());
    assert!(mux.list_agents(Some(surface.id), None).is_empty());
    assert!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .public_agent_projections(None, None)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn new_non_hook_session_can_start_after_hook_session_end() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-hook-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agent-hook-restart", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let hook = |event: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({"session_id":"old-hook"}),
        )
        .unwrap()
    };
    mux.apply_agent_hook_record(&hook("SessionEnd"), 1).unwrap();

    mux.report_agent(
        surface.id,
        AgentState::Working,
        AgentSource::Socket,
        Some("new-socket-session".into()),
    )
    .unwrap();
    let record = &mux.list_agents(Some(surface.id), None)[0];
    assert_eq!(record.source, AgentSource::Socket);
    assert_eq!(record.session.as_deref(), Some("new-socket-session"));

    let public = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(public["agents"][0]["source_session"], "new-socket-session");

    // A late event from the ended hook session remains fenced.
    mux.apply_agent_hook_record(&hook("UserPromptSubmit"), 2).unwrap();
    let record = &mux.list_agents(Some(surface.id), None)[0];
    assert_eq!(record.source, AgentSource::Socket);
    assert_eq!(record.session.as_deref(), Some("new-socket-session"));

    mux.shutdown();
    drop(mux);
    let reopened = open_persistent_test_mux("agent-hook-restart", &root);
    assert!(
        reopened.list_agents(None, None).is_empty(),
        "a detached terminal must not remain in the live agent cache"
    );
    let public = crate::resource_api::public_session_snapshot(&reopened).unwrap();
    assert_eq!(public["agents"][0]["source"], "socket");
    assert_eq!(public["agents"][0]["source_session"], "new-socket-session");
    reopened.shutdown();
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn direct_hook_report_with_new_session_can_follow_hook_end() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let hook = |event: &str, session_id: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({"session_id": session_id}),
        )
        .unwrap()
    };
    mux.apply_agent_hook_record(&hook("SessionEnd", "old"), 1).unwrap();
    assert!(
        mux.report_agent(surface.id, AgentState::Working, AgentSource::Hook, Some("new".into()),)
            .is_ok()
    );
    let record = &mux.list_agents(Some(surface.id), None)[0];
    assert_eq!(record.source, AgentSource::Hook);
    assert_eq!(record.session.as_deref(), Some("new"));
    mux.apply_agent_hook_record(&hook("UserPromptSubmit", "new"), 2).unwrap();
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, "new");
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].sequence, 2);
    mux.report_agent(surface.id, AgentState::Blocked, AgentSource::Hook, Some("new".into()))
        .expect("the active hook identity must remain writable");

    let error = mux
        .report_agent(surface.id, AgentState::Working, AgentSource::Hook, Some("old".into()))
        .unwrap_err();
    assert!(error.to_string().contains("agent_session_conflict"));
    let record = &mux.list_agents(Some(surface.id), None)[0];
    assert_eq!(record.state, AgentState::Blocked);
    assert_eq!(record.session.as_deref(), Some("new"));
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, "new");
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].sequence, 2);
}

#[test]
fn old_hook_session_end_cannot_fence_new_session() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let ingress = |event: &str, session_id: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({"session_id": session_id}),
        )
        .unwrap()
    };
    mux.apply_agent_hook_record(&ingress("SessionEnd", "old"), 1).unwrap();
    mux.apply_agent_hook_record(&ingress("SessionStart", "new"), 2).unwrap();
    mux.apply_agent_hook_record(&ingress("UserPromptSubmit", "old"), 3).unwrap();
    let agents = hook_projected_agents(&mux);
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["state"], "idle");
    assert!(
        !mux.agent_hook_fences.lock().unwrap().get(&terminal_id).is_some_and(|fence| fence.ended)
    );
}

#[test]
fn delayed_old_hook_session_start_cannot_replace_active_session() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let ingress = |event: &str, session_id: &str, observed_at_ms: u64| {
        let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({"session_id": session_id}),
        )
        .unwrap();
        crate::agent_hooks::stamp_agent_hook_observed_at(&mut ingress, observed_at_ms);
        ingress
    };
    mux.apply_agent_hook_record(&ingress("SessionStart", "old", 1_000), 1).unwrap();
    mux.apply_agent_hook_record(&ingress("SessionEnd", "old", 2_000), 2).unwrap();
    // The old session's start can arrive after its end marker. It was
    // observed before that end, so it is a stale event of the ended
    // incarnation, not a resume.
    mux.apply_agent_hook_record(&ingress("SessionStart", "old", 1_000), 3).unwrap();
    assert!(hook_projected_agents(&mux).is_empty());
    assert!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].ended);
    mux.apply_agent_hook_record(&ingress("SessionStart", "new", 3_000), 4).unwrap();
    mux.apply_agent_hook_record(&ingress("SessionStart", "old", 3_500), 5).unwrap();
    assert_eq!(hook_projected_agents(&mux)[0]["state"], "idle");
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, "new");
}

#[test]
fn late_sessionless_hook_event_cannot_attach_to_new_session() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let explicit = |event: &str, session_id: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({"session_id": session_id}),
        )
        .unwrap()
    };
    let sessionless = |event: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({}),
        )
        .unwrap()
    };

    mux.apply_agent_hook_record(&explicit("SessionStart", "old"), 1).unwrap();
    mux.apply_agent_hook_record(&explicit("SessionEnd", "old"), 2).unwrap();
    mux.apply_agent_hook_record(&explicit("SessionStart", "new"), 3).unwrap();
    mux.apply_agent_hook_record(&sessionless("UserPromptSubmit"), 4).unwrap();

    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, "new");
    assert_eq!(hook_projected_agents(&mux)[0]["state"], "idle");
}

#[test]
fn sessionless_hook_lifecycles_get_distinct_fence_identity() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
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
    let first = mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id.clone();
    // A session-less start cannot silently reuse the active generation.
    mux.apply_agent_hook_record(&ingress("SessionStart"), 2).unwrap();
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, first);
    mux.apply_agent_hook_record(&ingress("SessionEnd"), 2).unwrap();
    mux.apply_agent_hook_record(&ingress("SessionStart"), 3).unwrap();
    let second = mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id.clone();
    assert_ne!(first, second);
    mux.apply_agent_hook_record(&ingress("UserPromptSubmit"), 4).unwrap();
    assert_eq!(hook_projected_agents(&mux)[0]["state"], "working");
}

#[test]
fn socket_report_preserves_hook_sequence_marker() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let initial_revision = mux.with_state(|state| state.resource_revision);
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let hook = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    mux.apply_agent_hook_record(&hook, 4).unwrap();
    mux.report_agent(
        surface.id,
        AgentState::Working,
        AgentSource::Socket,
        Some("raw-session".into()),
    )
    .unwrap();
    let projections = mux.workspace_registry.lock().unwrap().public_projections().unwrap();
    let projection =
        projections.agents.into_iter().find(|agent| agent.terminal_id == terminal_id).unwrap();
    assert_eq!(projection.source_session, None);
    assert_eq!(
        mux.agent_hook_fences.lock().unwrap().get(&terminal_id).map(|fence| fence.sequence),
        Some(4)
    );
    let public_agents =
        mux.workspace_registry.lock().unwrap().public_agent_projections(None, None).unwrap();
    assert_eq!(public_agents.len(), 1);
    assert_eq!(public_agents[0].source_session, None);
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let snapshot_agent = snapshot["agents"].as_array().unwrap().first().unwrap();
    assert!(snapshot_agent["source_session"].is_null());
    let public_events = mux.resource_events_after(initial_revision).unwrap();
    assert!(
        public_events
            .batches
            .iter()
            .all(|batch| { batch.changes[0]["value"]["source_session"].is_null() })
    );
}

#[test]
fn non_hook_reports_reject_reserved_hook_markers() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let error = mux
        .report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("cmux-hook-sequence:9".into()),
        )
        .unwrap_err();
    assert!(error.to_string().contains("reserved hook marker"));
    assert!(mux.list_agents(Some(surface.id), None).is_empty());
}

#[test]
fn persistent_hook_watermark_restores_from_journal() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-watermark-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agent-watermark", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "SessionEnd",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let commit = mux.append_journal_ingress(&ingress, "test", "watermark-end").unwrap();
    assert!(commit.sequence > 0);
    assert_eq!(
        mux.workspace_registry.lock().unwrap().agent_hook_apply_cursor().unwrap(),
        commit.sequence
    );
    let projections = mux.workspace_registry.lock().unwrap().public_projections().unwrap();
    let restored = mux.with_state(|state| restore_public_projections(state, projections)).unwrap();
    assert_eq!(restored.agent_hook_fences[&terminal_id].sequence, commit.sequence);
    assert!(restored.agent_hook_fences[&terminal_id].ended);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn failed_hook_projection_does_not_consume_sequence_and_replay_succeeds() {
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

    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    let error = mux.apply_agent_hook_record(&ingress, 7).unwrap_err();
    assert!(error.to_string().contains("forced resource patch failure"));
    assert_eq!(mux.workspace_registry.lock().unwrap().agent_hook_apply_cursor().unwrap(), 0);
    assert!(mux.agent_hook_fences.lock().unwrap().get(&terminal_id).is_none());

    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    mux.apply_agent_hook_record(&ingress, 7).unwrap();
    assert_eq!(mux.workspace_registry.lock().unwrap().agent_hook_apply_cursor().unwrap(), 7);
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].sequence, 7);
    assert_eq!(hook_projected_agents(&mux).len(), 1);

    // A replay of the committed sequence is an idempotent no-op.
    mux.apply_agent_hook_record(&ingress, 7).unwrap();
    assert_eq!(mux.workspace_registry.lock().unwrap().agent_hook_apply_cursor().unwrap(), 7);
    assert_eq!(hook_projected_agents(&mux).len(), 1);
}

#[test]
fn reopened_ended_hook_fence_rejects_late_transitions() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-ended-reopen-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agent-ended-reopen", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let ingress = |event: &str, session_id: Option<&str>| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            session_id
                .map(|session_id| serde_json::json!({"session_id": session_id}))
                .unwrap_or_else(|| serde_json::json!({})),
        )
        .unwrap()
    };
    mux.apply_agent_hook_record(&ingress("SessionStart", Some("ended-session")), 1).unwrap();
    mux.apply_agent_hook_record(&ingress("SessionEnd", Some("ended-session")), 2).unwrap();
    assert!(mux.list_agents(Some(surface.id), None).is_empty());
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux("agent-ended-reopen", &root);
    assert!(reopened.list_agents(None, None).is_empty());
    let fence = reopened.agent_hook_fences.lock().unwrap()[&terminal_id].clone();
    assert_eq!(fence.session_id, "ended-session");
    assert_eq!(fence.sequence, 2);
    assert!(fence.ended);

    for (session_id, sequence) in
        [(Some("ended-session"), 3), (Some("different-session"), 4), (None, 5)]
    {
        assert!(matches!(
            HookFence::journal_transition(
                Some(&fence),
                terminal_id.as_str(),
                session_id,
                false,
                sequence,
                None,
            ),
            JournalHookTransition::Ignore
        ));
    }
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn agent_hook_events_without_a_live_terminal_still_append() {
    let mux = test_mux();
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        None,
        serde_json::json!({}),
    )
    .unwrap();
    mux.append_journal_ingress(&ingress, "test", "hook-no-terminal").unwrap();
    assert!(mux.list_agents(None, None).is_empty());
}

#[test]
fn unknown_terminal_hook_receipt_is_not_retained_for_retry() {
    let mux = test_mux();
    let terminal_id = TerminalPublicId::parse("term_000000000000000000000000000000ff").unwrap();
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    mux.append_journal_ingress(&ingress, "test", "unknown-terminal").unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
}

#[test]
fn terminal_cleanup_purges_pending_hook_receipts() {
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
    mux.workspace_registry
        .lock()
        .unwrap()
        .enqueue_agent_hook_pending(
            &ingress.producer_id,
            "test",
            "pending-before-close",
            1,
            &ingress,
            AgentHookPendingFailure {
                error: AGENT_HOOK_RETRY_ERROR,
                retry_class: crate::workspace_registry::AgentHookRetryClass::Transient,
            },
        )
        .unwrap();
    mux.purge_terminal_side_tables(&terminal_id);
    assert!(
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().is_empty()
    );
}

#[test]
fn raw_socket_report_reaches_the_roster_through_its_journal_echo() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    mux.report_agent(surface.id, AgentState::Working, AgentSource::Socket, Some("probe".into()))
        .unwrap();
    let records = mux.list_agents(Some(surface.id), None);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].state, AgentState::Working);
    assert_eq!(records[0].source, AgentSource::Socket);
    assert_eq!(records[0].session.as_deref(), Some("probe"));
    // The roster only folds journal events, so the record's presence
    // proves the direct report echoed its intent into the journal.
    let echoes = mux
        .workspace_registry
        .lock()
        .unwrap()
        .session_journal_after(0, 512)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "agent.state.changed")
        .count();
    assert_eq!(echoes, 1);
}
