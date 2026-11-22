//! Agent reports and hook authority: durable order, sequence fences, and session ids.

use super::*;

#[test]
fn agent_reports_apply_hook_authority() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let events = mux.subscribe();
    let initial_revision = mux.with_state(|state| state.resource_revision);
    let initial_epoch = mux.resource_event_epoch();
    let socket = mux
        .report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("socket-session".to_string()),
        )
        .unwrap();
    assert_eq!(socket.state, AgentState::Working);
    assert_eq!(socket.source, AgentSource::Socket);
    assert!(matches!(
        events.recv_timeout(Duration::from_millis(100)),
        Ok(MuxEvent::AgentChanged {
            surface: event_surface,
            state,
            source,
            session: Some(session),
            ..
        }) if event_surface == surface.id
            && state.as_ref() == "working"
            && source.as_ref() == "socket"
            && session.as_ref() == "socket-session"
    ));

    let hook = mux
        .report_agent(
            surface.id,
            AgentState::Blocked,
            AgentSource::Hook,
            Some("hook-session".to_string()),
        )
        .unwrap();
    assert_eq!(hook.state, AgentState::Blocked);
    assert_eq!(hook.source, AgentSource::Hook);

    let ignored_socket = mux
        .report_agent(
            surface.id,
            AgentState::Done,
            AgentSource::Socket,
            Some("late-socket".to_string()),
        )
        .unwrap();
    assert_eq!(ignored_socket.state, AgentState::Blocked);
    assert_eq!(ignored_socket.source, AgentSource::Hook);

    let filtered = mux.list_agents(Some(surface.id), Some(AgentState::Blocked));
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].session.as_deref(), Some("hook-session"));
    assert!(mux.list_agents(Some(surface.id), Some(AgentState::Done)).is_empty());
    // The late socket report is a replay-equivalent no-op because the
    // hook projection already owns this terminal.
    assert_eq!(mux.with_state(|state| state.resource_revision), initial_revision + 2);
    // Each fresh direct report publishes twice on the shared change
    // epoch: its resource commit and its journal echo.
    assert_eq!(mux.resource_event_epoch(), initial_epoch + 4);
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
    let resource_events = mux.resource_events_after(initial_revision).unwrap();
    assert_eq!(resource_events.batches.len(), 2);
    assert_eq!(resource_events.batches[0].changes[0]["value"]["source"], "socket");
    assert_eq!(resource_events.batches[1].changes[0]["value"]["source"], "hook");
    assert_eq!(resource_events.batches[1].changes[0]["value"]["state"], "blocked");
    assert_eq!(resource_events.batches[1].changes[0]["value"]["source_session"], "hook-session");
    assert!(matches!(
        events.recv_timeout(Duration::from_millis(100)),
        Ok(MuxEvent::AgentChanged {
            surface: event_surface,
            state,
            source,
            session: Some(session),
            ..
        }) if event_surface == surface.id
            && state.as_ref() == "blocked"
            && source.as_ref() == "hook"
            && session.as_ref() == "hook-session"
    ));
    assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::TreeChanged)));
}

#[test]
fn raw_and_resource_agent_reports_share_durable_order_across_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-coordinator-{}", WorkspacePublicId::random().unwrap()));
    let session = "agent-coordinator";
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let mux = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let created = public_request(
        &mux,
        "agent-create",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("agent-create"),
    );
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    let surface = mux.resource_surface_for_terminal(&terminal_id).unwrap();
    let created_revision = created["result"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
    let initial_epoch = mux.resource_event_epoch();

    let raw = mux
        .report_agent(surface, AgentState::Working, AgentSource::Socket, Some("raw-session".into()))
        .unwrap();
    assert_eq!(raw.state, AgentState::Working);
    assert_eq!(mux.with_state(|state| state.resource_revision), created_revision + 1);

    let hook_params = serde_json::json!({
        "machine":"current",
        "session":"current",
        "terminal_id":terminal_id,
        "state":"blocked",
        "source":"hook",
        "source_session":"hook-session",
        "expected_revision":(created_revision + 1).to_string(),
    });
    let hook =
        public_request(&mux, "agent-hook", "agent.report", hook_params.clone(), Some("agent-hook"));
    assert_eq!(hook["result"]["revision"], (created_revision + 2).to_string());
    assert_eq!(hook["result"]["value"]["source"], "hook");
    assert_eq!(hook["result"]["value"]["state"], "blocked");

    let ignored = mux
        .report_agent(
            surface,
            AgentState::Done,
            AgentSource::Socket,
            Some("late-raw-session".into()),
        )
        .unwrap();
    assert_eq!(ignored.state, AgentState::Blocked);
    assert_eq!(ignored.source, AgentSource::Hook);
    assert_eq!(ignored.session.as_deref(), Some("hook-session"));
    // The late socket report is a replay-equivalent no-op because the
    // hook projection already owns this terminal.
    assert_eq!(mux.with_state(|state| state.resource_revision), created_revision + 2);
    // Each fresh direct report publishes twice on the shared change
    // epoch: its resource commit and its journal echo.
    assert_eq!(mux.resource_event_epoch(), initial_epoch + 4);
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);

    let batches = mux.resource_events_after(created_revision).unwrap().batches;
    assert_eq!(
        batches.iter().map(|batch| batch.revision).collect::<Vec<_>>(),
        vec![created_revision + 1, created_revision + 2]
    );
    assert_eq!(batches[0].changes[0]["value"]["source"], "socket");
    assert_eq!(batches[0].changes[0]["value"]["source_session"], "raw-session");
    assert_eq!(batches[1].changes[0]["value"], hook["result"]["value"]);
    assert_eq!(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["agents"],
        serde_json::json!([hook["result"]["value"].clone()])
    );

    mux.shutdown();
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 1);
    assert!(
        reopened.list_agents(None, None).is_empty(),
        "the legacy live-surface cache must not retain a detached terminal"
    );
    assert_eq!(
        crate::resource_api::public_session_snapshot(&reopened).unwrap()["agents"],
        serde_json::json!([hook["result"]["value"].clone()])
    );

    let epoch_before_replay = reopened.resource_event_epoch();
    let event_count_before_replay =
        reopened.resource_events_after(created_revision).unwrap().batches.len();
    let replay = public_request(
        &reopened,
        "agent-hook-replay",
        "agent.report",
        hook_params,
        Some("agent-hook"),
    );
    assert_eq!(replay["result"]["replayed"], true);
    assert_eq!(replay["result"]["revision"], (created_revision + 2).to_string());
    assert_eq!(replay["result"]["value"], hook["result"]["value"]);
    assert_eq!(reopened.resource_event_epoch(), epoch_before_replay);
    assert_eq!(
        reopened.resource_events_after(created_revision).unwrap().batches.len(),
        event_count_before_replay
    );
    assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 1);

    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn concurrent_raw_socket_and_resource_hook_reports_serialize_to_hook_state() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface_id).unwrap() {
            ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let revision = mux.with_state(|state| state.resource_revision);
    let barrier = Arc::new(std::sync::Barrier::new(3));

    let raw_thread = {
        let mux = mux.clone();
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            barrier.wait();
            mux.report_agent(
                surface_id,
                AgentState::Working,
                AgentSource::Socket,
                Some("racing-socket".into()),
            )
            .unwrap()
        })
    };
    let hook_thread = {
        let mux = mux.clone();
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            barrier.wait();
            mux.resource_report_agent_selected(
                crate::ResourceSelectors {
                    machine: Some("current".into()),
                    session: Some("current".into()),
                    ..Default::default()
                },
                &terminal_id,
                AgentState::Blocked,
                AgentSource::Hook,
                Some("racing-hook".into()),
                None,
                &WorkspaceMutation::daemon("racing-hook", "resource-test").unwrap(),
            )
            .unwrap()
        })
    };
    barrier.wait();
    let raw_result = raw_thread.join().unwrap();
    let hook_commit = hook_thread.join().unwrap();
    assert!(matches!(raw_result.source, AgentSource::Socket | AgentSource::Hook));
    assert!(
        matches!(hook_commit.revision, value if value == revision + 1 || value == revision + 2)
    );

    let records = mux.list_agents(Some(surface_id), None);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].state, AgentState::Blocked);
    assert_eq!(records[0].source, AgentSource::Hook);
    assert_eq!(records[0].session.as_deref(), Some("racing-hook"));
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
    // The socket report commits its own revision only when it wins the
    // race; a socket report that lands after the hook is retained by the
    // hook-owned record without a new revision. Either way the hook's
    // commit is the last batch.
    let batches = mux.resource_events_after(revision).unwrap().batches;
    let last = batches.last().expect("the hook report published a revision");
    assert_eq!(last.revision, hook_commit.revision);
    assert_eq!(last.changes[0]["value"]["source"], "hook");
    assert_eq!(last.changes[0]["value"]["state"], "blocked");
    if raw_result.source == AgentSource::Socket {
        // The socket report committed first and the hook replaced it.
        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].revision, revision + 1);
        assert_eq!(batches[0].changes[0]["value"]["source"], "socket");
        assert_eq!(hook_commit.revision, revision + 2);
    } else {
        // The hook committed first. The later socket report loses to the
        // hook-owned record and restates nothing, so it adds no revision.
        assert_eq!(batches.len(), 1);
        assert_eq!(hook_commit.revision, revision + 1);
    }
}

#[test]
fn committed_agent_hook_events_drive_the_terminal_agent_record() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface_id).unwrap() {
            ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });

    let append = |event: &str, key: &str, session_id: &str| {
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            serde_json::json!({"session_id":session_id}),
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", key).unwrap();
    };

    append("SessionStart", "hook-1", "native-1");
    let records = mux.list_agents(Some(surface_id), None);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].state, AgentState::Idle);
    assert_eq!(records[0].source, AgentSource::Hook);

    append("UserPromptSubmit", "hook-2", "native-1");
    assert_eq!(mux.list_agents(Some(surface_id), None)[0].state, AgentState::Working);

    append("PermissionRequest", "hook-3", "native-1");
    assert_eq!(mux.list_agents(Some(surface_id), None)[0].state, AgentState::Blocked);

    append("Stop", "hook-4", "native-1");
    assert_eq!(mux.list_agents(Some(surface_id), None)[0].state, AgentState::Idle);

    // Child-agent events carry no top-level lifecycle transition.
    append("SubagentStart", "hook-5", "native-1");
    assert_eq!(mux.list_agents(Some(surface_id), None)[0].state, AgentState::Idle);

    // A socket report cannot downgrade a hook-owned record.
    mux.report_agent(surface_id, AgentState::Working, AgentSource::Socket, None).unwrap();
    assert_eq!(mux.list_agents(Some(surface_id), None)[0].state, AgentState::Idle);

    // An exited agent leaves the roster; a fresh one starts clean.
    append("SessionEnd", "hook-6", "native-1");
    assert!(mux.list_agents(Some(surface_id), None).is_empty());
    append("SessionStart", "hook-7", "native-2");
    let records = mux.list_agents(Some(surface_id), None);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].state, AgentState::Idle);
}

#[test]
fn stale_same_terminal_hook_sequence_cannot_overwrite_newer_state() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = mux.with_state(|state| {
        match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
            ContentPublicId::Terminal(id) => id.clone(),
            ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
        }
    });
    let newer = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "PermissionRequest",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    let older = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(&terminal_id.to_string()),
        serde_json::json!({}),
    )
    .unwrap();
    mux.apply_agent_hook_record(&newer, 2).unwrap();
    mux.apply_agent_hook_record(&older, 1).unwrap();
    assert_eq!(hook_projected_agents(&mux)[0]["state"], "blocked");
}

#[test]
fn hook_projection_does_not_relock_its_held_sequence_guard() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
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
        serde_json::json!({"agent_type":"claude"}),
    )
    .unwrap();

    // apply_agent_hook_record intentionally holds the sequence guard while
    // it commits. The Hook report path must use its supplied marker and
    // must not try to acquire that guard again.
    mux.apply_agent_hook_record(&hook, 1).unwrap();

    assert_eq!(hook_projected_agents(&mux)[0]["state"], "working");
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(snapshot["agents"][0]["extra"]["agent"], serde_json::json!("claude"));
    assert_eq!(
        mux.agent_hook_fences.lock().unwrap().get(&terminal_id).map(|fence| fence.sequence),
        Some(1)
    );
}

/// Agent changes published after `revision`, in commit order.
fn agent_changes_after(mux: &Mux, revision: u64) -> Vec<Value> {
    mux.resource_events_after(revision)
        .unwrap()
        .batches
        .into_iter()
        .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
        .filter(|change| change["resource"] == "agent")
        .collect()
}

/// A Claude hook journal event for `terminal_id` with the given native
/// payload.
fn claude_hook(
    terminal_id: &TerminalPublicId,
    event: &str,
    native: Value,
) -> crate::JournalIngress {
    crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(&terminal_id.to_string()),
        native,
    )
    .unwrap()
}

/// The published session id tracks the hook session through start, turn,
/// a retained socket report, end (delete), and a new session.
#[test]
fn agent_session_id_follows_the_hook_session_on_the_agent_roster() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = |event: &str, key: &str, native: Value| {
        mux.append_journal_ingress(&claude_hook(&terminal_id, event, native), "test", key).unwrap();
    };
    let snapshot_agents =
        || crate::resource_api::public_session_snapshot(&mux).unwrap()["agents"].clone();

    let revision = mux.with_state(|state| state.resource_revision);
    append("SessionStart", "hook-1", serde_json::json!({"session_id":"claude-session-1"}));
    let agents = snapshot_agents();
    assert_eq!(agents.as_array().unwrap().len(), 1);
    assert_eq!(agents[0]["extra"]["agent"], "claude");
    assert_eq!(agents[0]["extra"]["agent_session_id"], "claude-session-1");
    let changes = agent_changes_after(&mux, revision);
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0]["kind"], "upsert");
    assert_eq!(changes[0]["value"]["extra"]["agent_session_id"], "claude-session-1");

    // A later turn in the same session keeps the id.
    let revision = mux.with_state(|state| state.resource_revision);
    append("UserPromptSubmit", "hook-2", serde_json::json!({"session_id":"claude-session-1"}));
    let changes = agent_changes_after(&mux, revision);
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0]["value"]["state"], "working");
    assert_eq!(changes[0]["value"]["extra"]["agent_session_id"], "claude-session-1");

    // A socket report retained by the hook-owned record keeps the id.
    mux.report_agent(surface.id, AgentState::Idle, AgentSource::Socket, None).unwrap();
    assert_eq!(snapshot_agents()[0]["extra"]["agent_session_id"], "claude-session-1");

    // SessionEnd still deletes the agent.
    let revision = mux.with_state(|state| state.resource_revision);
    append("SessionEnd", "hook-3", serde_json::json!({"session_id":"claude-session-1"}));
    let changes = agent_changes_after(&mux, revision);
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0]["kind"], "delete");
    assert_eq!(snapshot_agents(), serde_json::json!([]));

    // A new session on the terminal (`/clear`, resume) publishes its id.
    let revision = mux.with_state(|state| state.resource_revision);
    append("SessionStart", "hook-4", serde_json::json!({"session_id":"claude-session-2"}));
    let changes = agent_changes_after(&mux, revision);
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0]["kind"], "upsert");
    assert_eq!(changes[0]["value"]["extra"]["agent_session_id"], "claude-session-2");
    assert_eq!(snapshot_agents()[0]["extra"]["agent_session_id"], "claude-session-2");
}

/// Detected, socket, and session-less hook agents publish no session id.
#[test]
fn agent_session_id_is_absent_without_a_hook_session() {
    let mux = test_mux();
    let snapshot_agent = |terminal_id: &TerminalPublicId| {
        crate::resource_api::public_session_snapshot(&mux).unwrap()["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|agent| agent["terminal_id"] == terminal_id.as_str())
            .cloned()
            .unwrap()
    };

    for source in [AgentSource::Detected, AgentSource::Socket] {
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().unwrap();
        let revision = mux.with_state(|state| state.resource_revision);
        mux.report_agent(surface.id, AgentState::Working, source, Some("pid:1".into())).unwrap();
        let changes = agent_changes_after(&mux, revision);
        assert_eq!(changes[0]["kind"], "upsert");
        assert_eq!(changes[0]["value"]["extra"].get("agent_session_id"), None);
        assert_eq!(snapshot_agent(&terminal_id)["extra"].get("agent_session_id"), None);
    }

    // A session-less hook gets a local generation token, which is not a
    // resumable agent session id.
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let revision = mux.with_state(|state| state.resource_revision);
    mux.append_journal_ingress(
        &claude_hook(&terminal_id, "SessionStart", serde_json::json!({})),
        "test",
        "legacy-hook-1",
    )
    .unwrap();
    let changes = agent_changes_after(&mux, revision);
    assert_eq!(changes[0]["value"]["source"], "hook");
    assert_eq!(changes[0]["value"]["extra"].get("agent_session_id"), None);
    assert_eq!(snapshot_agent(&terminal_id)["extra"].get("agent_session_id"), None);

    // Ids that are too long or not portable are withheld, but the hook
    // still drives the agent state.
    let oversized = "a".repeat(257);
    let unportable = ["x; rm -rf ~", "$(id)", "a b", oversized.as_str()];
    for (index, session_id) in unportable.iter().enumerate() {
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().unwrap();
        let revision = mux.with_state(|state| state.resource_revision);
        mux.append_journal_ingress(
            &claude_hook(
                &terminal_id,
                "SessionStart",
                serde_json::json!({"session_id": session_id}),
            ),
            "test",
            &format!("unportable-hook-{index}"),
        )
        .unwrap();
        let changes = agent_changes_after(&mux, revision);
        assert_eq!(changes[0]["kind"], "upsert", "{session_id}");
        assert_eq!(changes[0]["value"]["source"], "hook", "{session_id}");
        assert_eq!(changes[0]["value"]["extra"].get("agent_session_id"), None, "{session_id}");
    }
    assert_eq!(published_agent_session_id(&terminal_id, &"a".repeat(256)), Some("a".repeat(256)));
    assert_eq!(
        published_agent_session_id(&terminal_id, "0f8c2a4e-1b3d-4c5e-9f7a-2b4c6d8e0a1b"),
        Some("0f8c2a4e-1b3d-4c5e-9f7a-2b4c6d8e0a1b".into())
    );
}

/// The session id persists with the projection across a registry reopen.
#[test]
fn agent_session_id_survives_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-session-id-{}", WorkspacePublicId::random().unwrap()));
    let session = "agent-session-id";
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let mux = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let created = public_request(
        &mux,
        "agent-session-create",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "initial_content":"terminal",
        }),
        Some("agent-session-create"),
    );
    let terminal_id =
        TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
            .unwrap();
    mux.append_journal_ingress(
        &claude_hook(
            &terminal_id,
            "SessionStart",
            serde_json::json!({"session_id":"claude-durable"}),
        ),
        "test",
        "durable-hook-1",
    )
    .unwrap();
    let before = crate::resource_api::public_session_snapshot(&mux).unwrap()["agents"].clone();
    assert_eq!(before[0]["extra"]["agent_session_id"], "claude-durable");
    mux.shutdown();
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let after = crate::resource_api::public_session_snapshot(&reopened).unwrap()["agents"].clone();
    assert_eq!(after, before);
    let listed = public_request(
        &reopened,
        "agents",
        "agent.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    assert_eq!(listed["result"], before);

    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}
