//! Agent roster derived from the journal: incarnations, resume boundaries, and snapshot repair.

use super::*;

#[test]
fn agent_roster_rederives_from_the_journal_head_without_its_snapshot() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-rederive-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "roster-rederive";
    let (terminal_id, live_entries) = {
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
        let terminal_id = mux.with_state(|state| {
            match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
                ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
                ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
            }
        });
        let append = |event: &str, key: &str| {
            let ingress = crate::agent_hooks::agent_hook_journal_ingress(
                "claude",
                event,
                Some(&terminal_id.to_string()),
                serde_json::json!({"session_id":"native-1"}),
            )
            .unwrap();
            mux.append_journal_ingress(&ingress, "test", key).unwrap();
        };
        append("SessionStart", "rederive-1");
        append("UserPromptSubmit", "rederive-2");
        let entries = mux.agent_roster.lock().unwrap().roster.entries.clone();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[terminal_id.as_str()].state, "working");
        mux.shutdown();
        (terminal_id, entries)
    };

    // Wipe the persisted reducer state so the reopen cannot lean on the
    // snapshot: an identical roster proves it derives from the journal.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry
        .put_journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID, 0, 0, "")
        .unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let rederived = reopened.agent_roster.lock().unwrap().roster.entries.clone();
    assert_eq!(rederived, live_entries);

    // Folding the tail after an ended session removes the entry, and
    // that removal survives the next reopen through the snapshot.
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "SessionEnd",
        Some(&terminal_id.to_string()),
        serde_json::json!({"session_id":"native-1"}),
    )
    .unwrap();
    reopened.append_journal_ingress(&ingress, "test", "rederive-3").unwrap();
    assert!(reopened.agent_roster.lock().unwrap().roster.entries.is_empty());
    reopened.shutdown();
    drop(reopened);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let final_mux = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    assert!(final_mux.agent_roster.lock().unwrap().roster.entries.is_empty());
    final_mux.shutdown();
    drop(final_mux);
    std::fs::remove_dir_all(root).unwrap();
}

fn public_agent_state(mux: &Mux, terminal_id: &TerminalPublicId) -> Option<String> {
    hook_projected_agents(mux)
        .into_iter()
        .find(|agent| agent["terminal_id"] == terminal_id.as_str())
        .and_then(|agent| agent["state"].as_str().map(str::to_owned))
}

/// The roster (and every view it backs) must show the state the public
/// agent rows show after each journal event.
#[track_caller]
fn assert_agent_views(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    terminal_id: &TerminalPublicId,
    expected: Option<&str>,
) {
    assert_eq!(public_agent_state(mux, terminal_id).as_deref(), expected, "public agent row");
    assert_eq!(roster_agent_state(mux, terminal_id).as_deref(), expected, "agent roster");
    let listed = mux
        .list_agents(Some(surface), None)
        .into_iter()
        .map(|record| record.state.as_str().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(listed, expected.into_iter().map(str::to_owned).collect::<Vec<_>>(), "list_agents");
}

/// [`append_journal_hook`] with the hook helper's observation stamp.
fn append_journal_hook_at(
    mux: &Arc<Mux>,
    terminal_id: &TerminalPublicId,
    event: &str,
    session_id: &str,
    observed_at_ms: u64,
) {
    let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal_id.as_str()),
        serde_json::json!({ "session_id": session_id }),
    )
    .unwrap();
    ingress.payload["normalized"]["observed_at_ms"] = serde_json::json!(observed_at_ms.to_string());
    let key = format!("roster-resume-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

#[test]
fn journal_roster_resumed_session_id_starts_a_new_incarnation() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-resume-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-resume", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");

    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_000);
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "a", 1_100);
    append_journal_hook_at(&mux, &terminal_id, "SessionEnd", "a", 1_200);
    assert_agent_views(&mux, surface.id, &terminal_id, None);
    // `claude --resume a` reuses the id on the same terminal.
    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_300);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "a", 1_400);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook_at(&mux, &terminal_id, "Stop", "a", 1_500);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    // The resumed incarnation can end and resume again.
    append_journal_hook_at(&mux, &terminal_id, "SessionEnd", "a", 1_600);
    assert_agent_views(&mux, surface.id, &terminal_id, None);
    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_700);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_rejects_late_events_of_the_ended_incarnation_after_resume() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-resume-late-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-resume-late", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");

    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_000);
    append_journal_hook_at(&mux, &terminal_id, "SessionEnd", "a", 1_200);
    // A duplicate start the ended incarnation emitted before its end is
    // not a resume.
    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_000);
    assert_agent_views(&mux, surface.id, &terminal_id, None);
    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_300);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    // Late events of the ended incarnation cannot change the resumed one.
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "a", 1_150);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook_at(&mux, &terminal_id, "SessionEnd", "a", 1_200);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "a", 1_400);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_new_session_event_after_an_end_takes_the_terminal_without_a_start() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-takeover-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-takeover", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");

    append_journal_hook_at(&mux, &terminal_id, "SessionStart", "old", 1_000);
    append_journal_hook_at(&mux, &terminal_id, "SessionEnd", "old", 1_200);
    // An event another session emitted before that end stays fenced.
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "other", 1_100);
    assert_agent_views(&mux, surface.id, &terminal_id, None);
    // A session whose start never reached the fence (for example after a
    // direct hook report restarted the projector) takes the terminal with
    // its first event observed after the end.
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "new", 1_300);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook_at(&mux, &terminal_id, "UserPromptSubmit", "other", 1_400);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook_at(&mux, &terminal_id, "Stop", "new", 1_500);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_resume_boundary_survives_restart_and_replay() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-resume-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "roster-resume-restart";
    let terminal_id = {
        let mux = open_persistent_test_mux(session, &root);
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
        append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_000);
        append_journal_hook_at(&mux, &terminal_id, "SessionEnd", "a", 1_200);
        append_journal_hook_at(&mux, &terminal_id, "SessionStart", "a", 1_300);
        assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
        mux.shutdown();
        terminal_id
    };

    // Both fences restore the incarnation boundary: the projector's from
    // the registry, the roster's from its snapshot.
    let reopened = open_persistent_test_mux(session, &root);
    let fence = reopened.agent_hook_fences.lock().unwrap()[&terminal_id].clone();
    assert_eq!(fence.session_id, "a");
    assert!(!fence.ended);
    assert_eq!(fence.ended_at_ms, Some(1_200));
    assert_eq!(roster_agent_state(&reopened, &terminal_id).as_deref(), Some("idle"));
    append_journal_hook_at(&reopened, &terminal_id, "UserPromptSubmit", "a", 1_150);
    assert_eq!(roster_agent_state(&reopened, &terminal_id).as_deref(), Some("idle"));
    reopened.shutdown();
    drop(reopened);

    // Re-folding the journal without the snapshot rebuilds the boundary.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry
        .put_journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID, 0, 0, "")
        .unwrap();
    drop(registry);
    let replayed = open_persistent_test_mux(session, &root);
    assert_eq!(roster_agent_state(&replayed, &terminal_id).as_deref(), Some("idle"));
    append_journal_hook_at(&replayed, &terminal_id, "UserPromptSubmit", "a", 1_400);
    assert_eq!(roster_agent_state(&replayed, &terminal_id).as_deref(), Some("working"));
    replayed.shutdown();
    drop(replayed);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_ignores_late_hook_events_from_an_ended_session() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fence-late-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fence-late", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");

    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("old"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("old"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook(&mux, &terminal_id, "SessionEnd", Some("old"));
    assert_agent_views(&mux, surface.id, &terminal_id, None);

    // A late event from the ended session cannot resurrect it.
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("old"));
    assert_agent_views(&mux, surface.id, &terminal_id, None);

    // A new session starts idle, and late events from the ended session
    // (with or without its id) cannot mark it working.
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("new"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("old"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", None);
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook(&mux, &terminal_id, "SessionEnd", Some("old"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));

    // The current session still drives the terminal.
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("new"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_keeps_the_owning_session_when_sessions_overlap() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fence-overlap-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fence-overlap", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");

    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("a"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    // A second session starting while `a` is live does not take over.
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("b"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("b"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("a"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    // Only the owning session can end it.
    append_journal_hook(&mux, &terminal_id, "SessionEnd", Some("b"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook(&mux, &terminal_id, "SessionEnd", Some("a"));
    assert_agent_views(&mux, surface.id, &terminal_id, None);
    // After `a` ends, `b` can start, and `a` can no longer write.
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("b"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("a"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("b"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook(&mux, &terminal_id, "Stop", Some("b"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_direct_hook_restart_fences_the_ended_session() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fence-direct-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fence-direct", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");

    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("old"));
    append_journal_hook(&mux, &terminal_id, "SessionEnd", Some("old"));
    // A direct hook report with a fresh session restarts the fence; its
    // journal echo carries the restart to the roster.
    mux.report_agent(surface.id, AgentState::Working, AgentSource::Hook, Some("new".into()))
        .unwrap();
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook(&mux, &terminal_id, "Stop", Some("old"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("working"));
    append_journal_hook(&mux, &terminal_id, "Stop", Some("new"));
    assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_roster_session_fence_survives_restart_and_replay() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fence-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "roster-fence-restart";
    let terminal_id = {
        let mux = open_persistent_test_mux(session, &root);
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
        append_journal_hook(&mux, &terminal_id, "SessionStart", Some("old"));
        append_journal_hook(&mux, &terminal_id, "SessionEnd", Some("old"));
        append_journal_hook(&mux, &terminal_id, "SessionStart", Some("new"));
        assert_agent_views(&mux, surface.id, &terminal_id, Some("idle"));
        mux.shutdown();
        terminal_id
    };

    // The restored snapshot keeps the fence: a late event from the ended
    // session arriving after the restart cannot mark the roster working.
    let reopened = open_persistent_test_mux(session, &root);
    assert_eq!(roster_agent_state(&reopened, &terminal_id).as_deref(), Some("idle"));
    append_journal_hook(&reopened, &terminal_id, "UserPromptSubmit", Some("old"));
    assert_eq!(roster_agent_state(&reopened, &terminal_id).as_deref(), Some("idle"));
    reopened.shutdown();
    drop(reopened);

    // Re-folding the whole journal without the snapshot rebuilds the same
    // fence, so replay also ignores the late event.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry
        .put_journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID, 0, 0, "")
        .unwrap();
    drop(registry);
    let replayed = open_persistent_test_mux(session, &root);
    assert_eq!(roster_agent_state(&replayed, &terminal_id).as_deref(), Some("idle"));
    append_journal_hook(&replayed, &terminal_id, "UserPromptSubmit", Some("new"));
    assert_eq!(roster_agent_state(&replayed, &terminal_id).as_deref(), Some("working"));
    replayed.shutdown();
    drop(replayed);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn invalid_agent_roster_snapshot_replays_from_the_journal_head() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-invalid-snapshot-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "roster-invalid-snapshot";
    let (terminal_id, cursor) = {
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
        let terminal_id = mux.with_state(|state| {
            match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
                ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
                ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
            }
        });
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            "UserPromptSubmit",
            Some(terminal_id.as_str()),
            serde_json::json!({"session_id":"native-1"}),
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", "invalid-snapshot-1").unwrap();
        let cursor = mux.agent_roster.lock().unwrap().cursor;
        assert_eq!(
            mux.agent_roster.lock().unwrap().roster.entries[terminal_id.as_str()].state,
            "working"
        );
        mux.shutdown();
        drop(mux);
        (terminal_id, cursor)
    };

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry
        .put_journal_reducer_state(
            crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
            crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            cursor,
            "not-json",
        )
        .unwrap();
    drop(registry);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let entry = reopened
        .agent_roster
        .lock()
        .unwrap()
        .roster
        .entries
        .get(terminal_id.as_str())
        .cloned()
        .expect("invalid snapshots must replay the retained journal");
    assert_eq!(entry.state, "working");
    assert_eq!(entry.source, "hook");
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn invalid_empty_agent_roster_snapshot_is_repaired_on_restart() {
    let root = std::env::temp_dir().join(format!(
        "cmux-roster-invalid-empty-snapshot-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let session = "roster-invalid-empty-snapshot";
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry
        .put_journal_reducer_state(
            crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
            crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            0,
            "not-json",
        )
        .unwrap();
    drop(registry);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let mux = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    assert!(mux.agent_roster.lock().unwrap().roster.entries.is_empty());
    mux.shutdown();
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let (version, cursor, snapshot) = registry
        .journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .expect("startup must replace a rejected empty snapshot");
    assert_eq!(version, crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION);
    assert_eq!(cursor, 0);
    assert!(crate::journal_reducers::AgentRoster::restore(&snapshot).is_some());
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn agent_roster_replays_when_persisted_cursor_is_ahead_of_journal() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-ahead-cursor-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "roster-ahead-cursor";
    let terminal_id = {
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
        let terminal_id = mux.with_state(|state| {
            match state.resource_indexes.content_ids.get(&surface.id).unwrap() {
                ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
                ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
            }
        });
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            "UserPromptSubmit",
            Some(terminal_id.as_str()),
            serde_json::json!({"session_id":"native-1"}),
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", "ahead-cursor-1").unwrap();
        mux.shutdown();
        drop(mux);
        terminal_id
    };

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let journal_head = registry.session_journal_head().unwrap();
    assert!(journal_head > 0);
    // Keep a valid snapshot, but move its cursor beyond the retained
    // journal. Startup must reject that checkpoint and replay the journal
    // instead of returning a cursor.invalid error.
    registry
        .put_journal_reducer_state(
            crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
            crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
            journal_head.checked_add(1).expect("test journal head must not overflow"),
            &crate::journal_reducers::AgentRoster::default().snapshot().to_string(),
        )
        .unwrap();
    drop(registry);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let entry = reopened
        .agent_roster
        .lock()
        .unwrap()
        .roster
        .entries
        .get(terminal_id.as_str())
        .cloned()
        .expect("an ahead cursor must replay the retained journal");
    assert_eq!(entry.state, "working");
    assert_eq!(entry.source, "hook");
    let (live_head, cursor, snapshot) = {
        let registry = reopened.workspace_registry.lock().unwrap();
        let (_, cursor, snapshot) = registry
            .journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)
            .unwrap()
            .expect("startup must repair the rejected cursor");
        (registry.session_journal_head().unwrap(), cursor, snapshot)
    };
    // Mux startup can append unrelated lifecycle records after the roster
    // checkpoint is repaired. The durable cursor must reach the journal
    // head that existed at reopen, while the live head may have advanced.
    assert_eq!(cursor, journal_head);
    assert!(live_head >= cursor);
    assert!(crate::journal_reducers::AgentRoster::restore(&snapshot).is_some());
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn failed_raw_agent_report_rolls_back_projection_memory_revision_and_event() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let revision = mux.with_state(|state| state.resource_revision);
    let epoch = mux.resource_event_epoch();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

    let error = mux
        .report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("failed-session".into()),
        )
        .unwrap_err();
    assert!(error.to_string().contains("forced resource patch failure"));
    assert!(mux.list_agents(None, None).is_empty());
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 0);
    assert_eq!(mux.with_state(|state| state.resource_revision), revision);
    assert_eq!(mux.resource_event_epoch(), epoch);
    assert!(mux.resource_events_after(revision).unwrap().batches.is_empty());
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
}

#[test]
fn agent_reports_require_a_terminal_and_never_create_a_default_projection() {
    let mux = test_mux();
    let browser = mux.new_browser_tab("about:blank".into(), None, None).unwrap();
    let revision = mux.with_state(|state| state.resource_revision);
    let epoch = mux.resource_event_epoch();
    let error = mux
        .report_agent(
            browser.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("browser-session".into()),
        )
        .unwrap_err();
    assert!(error.to_string().contains("is not a terminal"));
    assert!(mux.list_agents(None, None).is_empty());
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 0);
    assert_eq!(mux.with_state(|state| state.resource_revision), revision);
    assert_eq!(mux.resource_event_epoch(), epoch);
}
