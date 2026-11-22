//! Durable notifications: sources, per-client acks, clears, reads, and eviction.

use super::*;

#[test]
fn cmux_next_notification_source_is_on_event_marker_and_snapshot_and_survives_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-notification-source-{}", WorkspacePublicId::random().unwrap()));
    let session = "notification-source";
    let open = || {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mux = open();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let events = mux.subscribe();

    mux.post_notification("plain".into(), "".into(), NotificationLevel::Info, Some(surface_id))
        .unwrap();
    mux.post_notification_as(
        &Actor::Daemon,
        "osc".into(),
        "body".into(),
        NotificationLevel::Info,
        Some(surface_id),
        NotificationSource::Terminal,
    )
    .unwrap();
    let sources = events
        .try_iter()
        .filter_map(|event| match event {
            MuxEvent::Notification(note) => Some((note.title, note.source)),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        sources,
        vec![
            ("plain".to_string(), NotificationSource::Cli),
            ("osc".to_string(), NotificationSource::Terminal),
        ]
    );
    assert_eq!(
        mux.terminal_notification(&terminal_id).map(|marker| marker.source),
        Some(NotificationSource::Terminal)
    );
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let sources = snapshot["notifications"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["extra"]["source"].clone())
        .collect::<Vec<_>>();
    assert!(sources.contains(&serde_json::json!("terminal")), "{sources:?}");
    assert!(sources.contains(&serde_json::json!("cli")), "{sources:?}");
    drop(events);
    mux.shutdown();
    drop(mux);

    let mux = open();
    let ledger = mux.resource_notifications(16);
    assert_eq!(ledger[0].title, "osc");
    assert_eq!(ledger[0].source, NotificationSource::Terminal);
    assert_eq!(ledger[1].source, NotificationSource::Cli);
    assert_eq!(
        mux.terminal_notification(&terminal_id).map(|marker| marker.source),
        Some(NotificationSource::Terminal)
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_hook_notifications_have_the_agent_source() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "PermissionRequest",
        Some(&terminal_id.to_string()),
        serde_json::json!({"tool_name":"Bash"}),
    )
    .unwrap();
    mux.apply_agent_hook_record(&ingress, 1).unwrap();
    let posted = mux.resource_notifications(16);
    assert_eq!(posted.len(), 1);
    assert_eq!(posted[0].source, NotificationSource::Agent);
    assert_eq!(
        mux.terminal_notification(&terminal_id).map(|marker| marker.source),
        Some(NotificationSource::Agent)
    );
}

#[test]
fn agent_hook_transitions_post_durable_notifications_once() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let ingress = |event: &str, native: Value| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal_id.to_string()),
            native,
        )
        .unwrap()
    };
    mux.apply_agent_hook_record(&ingress("SessionStart", serde_json::json!({})), 1).unwrap();
    mux.apply_agent_hook_record(&ingress("UserPromptSubmit", serde_json::json!({})), 2).unwrap();
    assert!(mux.resource_notifications(16).is_empty(), "start and prompt need no attention");

    mux.apply_agent_hook_record(
        &ingress(
            "PermissionRequest",
            serde_json::json!({"tool_name":"Bash","message":"Allow Bash(rm -rf build)?"}),
        ),
        3,
    )
    .unwrap();
    let posted = mux.resource_notifications(16);
    assert_eq!(posted.len(), 1);
    assert_eq!(posted[0].title, "Claude needs approval");
    assert_eq!(posted[0].body, "Bash", "redacted prompt text must not leak; tool name may");
    assert_eq!(posted[0].level, NotificationLevel::Warning);
    assert_eq!(posted[0].terminal_id.as_ref(), Some(&terminal_id));
    assert!(mux.surface_notification(surface_id).is_some_and(|marker| marker.unread));

    // A replayed sequence (restart repair) is a fence no-op and must not
    // post a second notification.
    mux.apply_agent_hook_record(
        &ingress("PermissionRequest", serde_json::json!({"message":"again"})),
        3,
    )
    .unwrap();
    assert_eq!(mux.resource_notifications(16).len(), 1);

    mux.apply_agent_hook_record(&ingress("Stop", serde_json::json!({})), 4).unwrap();
    let posted = mux.resource_notifications(16);
    assert_eq!(posted.len(), 2);
    assert_eq!(posted[0].title, "Claude finished");
    assert_eq!(posted[0].level, NotificationLevel::Info);

    // The rows are durable resource effects: the public snapshot carries
    // them with an empty per-client read set.
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let rows = snapshot["notifications"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    for row in rows {
        assert_eq!(row["read_by"], serde_json::json!([]));
        assert_eq!(row["terminal_id"], serde_json::json!(terminal_id));
    }
}

#[test]
fn notification_ack_is_per_client_and_replay_safe() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    let first = mux
        .post_notification("one".into(), "".into(), NotificationLevel::Info, Some(surface_id))
        .unwrap();
    let second = mux
        .post_notification("two".into(), "".into(), NotificationLevel::Error, Some(surface_id))
        .unwrap();
    assert_ne!(first, second);
    let ledger = mux.resource_notifications(16);
    let (newest, oldest) = (ledger[0].id.clone(), ledger[1].id.clone());
    let revision_before = mux.with_state(|state| state.resource_revision);
    let epoch_before = mux.resource_event_epoch();

    let mutation = WorkspaceMutation::daemon("ack-a-1", "test").unwrap();
    let ack =
        mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&oldest)).unwrap();
    assert!(!ack.replayed);
    assert_eq!(ack.result["acknowledged"], serde_json::json!([oldest]));
    assert_eq!(ack.result["unknown"], serde_json::json!([]));
    assert_eq!(ack.revision, revision_before + 1);
    assert_eq!(mux.with_state(|state| state.resource_revision), revision_before + 1);
    assert!(mux.resource_event_epoch() > epoch_before, "subscribers must wake");
    assert_eq!(mux.notification_read_by(&oldest), vec!["mac-a".to_string()]);
    assert!(mux.notification_read_by(&newest).is_empty());
    // The shared console marker is not a per-client read.
    assert!(mux.surface_notification(surface_id).is_some_and(|marker| marker.unread));

    // Same key, same input: replay without a new revision or a new row.
    let replay =
        mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&oldest)).unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.revision, revision_before + 1);
    assert_eq!(mux.with_state(|state| state.resource_revision), revision_before + 1);

    // A second client keeps its own state and sees the merged set.
    let mutation_b = WorkspaceMutation::daemon("ack-b-1", "test").unwrap();
    let unknown = NotificationPublicId::random().unwrap();
    let ack_b = mux
        .ack_notifications(
            &mutation_b,
            None,
            "mac-b",
            &[newest.clone(), oldest.clone(), unknown.clone(), oldest.clone()],
        )
        .unwrap();
    assert_eq!(ack_b.result["acknowledged"], serde_json::json!([newest, oldest]));
    assert_eq!(ack_b.result["unknown"], serde_json::json!([unknown]));
    assert_eq!(mux.notification_read_by(&oldest), vec!["mac-a".to_string(), "mac-b".to_string()]);
    assert_eq!(mux.notification_read_by(&newest), vec!["mac-b".to_string()]);

    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let rows = snapshot["notifications"].as_array().unwrap();
    let row = |id: &NotificationPublicId| {
        rows.iter().find(|row| row["id"] == serde_json::json!(id)).cloned().unwrap()
    };
    assert_eq!(row(&oldest)["read_by"], serde_json::json!(["mac-a", "mac-b"]));
    assert_eq!(row(&newest)["read_by"], serde_json::json!(["mac-b"]));

    // The ack publishes one upsert delta per acknowledged row so remote
    // feeds converge without a snapshot.
    let page = mux.resource_events_after(revision_before).unwrap();
    let ack_batch =
        page.batches.iter().find(|batch| batch.revision == revision_before + 2).unwrap();
    let changes = ack_batch.changes.as_array().unwrap();
    assert_eq!(changes.len(), 2);
    assert!(changes.iter().all(|change| {
        change["resource"] == "notification"
            && change["kind"] == "upsert"
            && change["value"]["read_by"].as_array().unwrap().contains(&serde_json::json!("mac-b"))
    }));

    let bad = WorkspaceMutation::daemon("ack-bad", "test").unwrap();
    assert!(mux.ack_notifications(&bad, None, "has space", &[oldest]).is_err());
}

#[test]
fn notification_clear_removes_rows_everywhere_and_survives_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-notification-clear-{}", WorkspacePublicId::random().unwrap()));
    let session = "notification-clear";
    let open = || {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mux = open();
    let first = mux.new_workspace(None, None).unwrap();
    let second = mux.new_workspace(None, None).unwrap();
    let first_terminal = first.terminal_public_id().cloned().unwrap();
    mux.create_durable_notification(
        &Actor::Daemon,
        "n-a",
        "a".into(),
        Some("sub".into()),
        "".into(),
        NotificationLevel::Info,
        Some(first.id),
        NotificationSource::Cli,
    )
    .unwrap();
    mux.create_durable_notification(
        &Actor::Daemon,
        "n-b",
        "b".into(),
        None,
        "".into(),
        NotificationLevel::Info,
        Some(second.id),
        NotificationSource::Cli,
    )
    .unwrap();
    mux.create_durable_notification(
        &Actor::Daemon,
        "n-c",
        "c".into(),
        None,
        "".into(),
        NotificationLevel::Info,
        Some(first.id),
        NotificationSource::Cli,
    )
    .unwrap();
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let row_a = snapshot["notifications"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["title"] == "a")
        .cloned()
        .unwrap();
    assert_eq!(row_a["subtitle"], "sub", "subtitle rides the row");
    let mutation = WorkspaceMutation::daemon("ack-a", "test").unwrap();
    let ledger = mux.resource_notifications(8);
    let id_b = ledger.iter().find(|entry| entry.title == "b").unwrap().id.clone();
    mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&id_b)).unwrap();
    let revision_before = mux.with_state(|state| state.resource_revision);

    // Clear one terminal: its two rows go, the other terminal's row stays.
    let clear = WorkspaceMutation::daemon("clear-first", "test").unwrap();
    let commit = mux.clear_notifications(&clear, None, Some(&first_terminal)).unwrap();
    assert!(!commit.replayed);
    assert_eq!(commit.result["cleared"].as_array().unwrap().len(), 2);
    let remaining = mux.resource_notifications(8);
    assert_eq!(remaining.iter().map(|entry| entry.title.as_str()).collect::<Vec<_>>(), vec!["b"]);
    assert!(mux.surface_notification(first.id).is_none(), "console marker dropped with the rows");
    let page = mux.resource_events_after(revision_before).unwrap();
    let batch = page.batches.iter().find(|batch| batch.revision == revision_before + 1).unwrap();
    assert!(
        batch
            .changes
            .as_array()
            .unwrap()
            .iter()
            .all(|change| change["kind"] == "delete" && change["resource"] == "notification")
    );
    // Replay is a no-op.
    let replay = mux.clear_notifications(&clear, None, Some(&first_terminal)).unwrap();
    assert!(replay.replayed);
    drop(mux);

    let mux = open();
    let titles =
        mux.resource_notifications(8).iter().map(|entry| entry.title.clone()).collect::<Vec<_>>();
    assert_eq!(titles, vec!["b"], "cleared rows must not come back from the receipts");
    assert_eq!(mux.notification_read_by(&id_b), vec!["mac-a".to_string()]);
    // Clear everything.
    let all = WorkspaceMutation::daemon("clear-all", "test").unwrap();
    mux.clear_notifications(&all, None, None).unwrap();
    assert!(mux.resource_notifications(8).is_empty());
    assert!(mux.notification_read_by(&id_b).is_empty());
    drop(mux);
    let mux = open();
    assert!(mux.resource_notifications(8).is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn notification_reads_survive_restart_and_eviction_prunes_them() {
    let root = std::env::temp_dir()
        .join(format!("cmux-notification-reads-{}", WorkspacePublicId::random().unwrap()));
    let session = "notification-reads";
    let open = || {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mux = open();
    let surface = mux.new_workspace(None, None).unwrap();
    let surface_id = surface.id;
    mux.post_notification("kept".into(), "".into(), NotificationLevel::Info, Some(surface_id))
        .unwrap();
    let kept = mux.resource_notifications(1)[0].id.clone();
    let mutation = WorkspaceMutation::daemon("ack-restart", "test").unwrap();
    mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&kept)).unwrap();
    drop(mux);

    let mux = open();
    assert_eq!(mux.notification_read_by(&kept), vec!["mac-a".to_string()]);
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let row = snapshot["notifications"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == serde_json::json!(kept))
        .cloned()
        .unwrap();
    assert_eq!(row["read_by"], serde_json::json!(["mac-a"]));
    // Replay across restart still returns the original commit.
    let replay =
        mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&kept)).unwrap();
    assert!(replay.replayed);

    // Evict `kept` from the bounded ledger, then acknowledge something
    // else: the stale read row must be gone from memory and from disk.
    let surface_id = mux.resource_surface_for_terminal(
        mux.resource_notifications(1)[0].terminal_id.as_ref().unwrap(),
    );
    for index in 0..256 {
        mux.post_notification(
            format!("fill-{index}"),
            "".into(),
            NotificationLevel::Info,
            surface_id,
        )
        .unwrap();
    }
    assert!(mux.resource_notifications(256).iter().all(|entry| entry.id != kept));
    assert!(mux.notification_read_by(&kept).is_empty());
    // The prune rides the committed create that evicted `kept`, not an
    // acknowledgement, and only once the receipts no longer retain it.
    let newest = mux.resource_notifications(1)[0].id.clone();
    let prune = WorkspaceMutation::daemon("ack-newest", "test").unwrap();
    mux.ack_notifications(&prune, None, "mac-a", std::slice::from_ref(&newest)).unwrap();
    let stale_rows = mux
        .workspace_registry
        .lock()
        .unwrap()
        .durable_notification_read_clients(kept.as_str())
        .unwrap();
    assert!(stale_rows.is_empty(), "evicted notification kept read rows: {stale_rows:?}");
    drop(mux);
    let mux = open();
    assert!(mux.notification_read_by(&kept).is_empty());
    assert_eq!(mux.notification_read_by(&newest), vec!["mac-a".to_string()]);
    let _ = std::fs::remove_dir_all(&root);
}

/// Random creates, acks from several clients, replays, and restarts must
/// keep one invariant: a retained notification's `read_by` is exactly the
/// set of clients that acknowledged it while it was retained.
#[test]
fn notification_read_state_converges_under_random_operations() {
    let root = std::env::temp_dir()
        .join(format!("cmux-notification-fuzz-{}", WorkspacePublicId::random().unwrap()));
    let session = "notification-fuzz";
    let open = || {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mut mux = open();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let clients = ["mac-a", "mac-b", "phone-c"];
    let mut expected: HashMap<NotificationPublicId, BTreeSet<String>> = HashMap::new();
    let mut retained: VecDeque<NotificationPublicId> = VecDeque::new();
    let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let mut ack_counter = 0u64;
    let mut last_ack: Option<(WorkspaceMutation, String, Vec<NotificationPublicId>)> = None;
    for step in 0..400u64 {
        match next() % 10 {
            0..=3 => {
                let surface_id = mux.resource_surface_for_terminal(&terminal_id);
                mux.post_notification(
                    format!("n-{step}"),
                    "".into(),
                    NotificationLevel::Info,
                    surface_id,
                )
                .unwrap();
                let id = mux.resource_notifications(1)[0].id.clone();
                retained.push_back(id.clone());
                expected.insert(id, BTreeSet::new());
                while retained.len() > 256 {
                    let evicted = retained.pop_front().unwrap();
                    expected.remove(&evicted);
                }
            }
            4..=6 if !retained.is_empty() => {
                let client = clients[(next() % clients.len() as u64) as usize];
                let count = 1 + (next() % 4) as usize;
                let ids = (0..count)
                    .map(|_| retained[(next() % retained.len() as u64) as usize].clone())
                    .collect::<Vec<_>>();
                ack_counter += 1;
                let mutation =
                    WorkspaceMutation::daemon(format!("fuzz-ack-{ack_counter}"), "test").unwrap();
                mux.ack_notifications(&mutation, None, client, &ids).unwrap();
                for id in &ids {
                    expected.get_mut(id).unwrap().insert(client.to_string());
                }
                last_ack = Some((mutation, client.to_string(), ids));
            }
            7 => {
                if let Some((mutation, client, ids)) = &last_ack {
                    let replay = mux.ack_notifications(mutation, None, client, ids).unwrap();
                    assert!(replay.replayed, "step {step}: replay must not re-commit");
                }
            }
            8 => {
                drop(mux);
                mux = open();
            }
            _ => {}
        }
        for id in &retained {
            let actual = mux.notification_read_by(id).into_iter().collect::<BTreeSet<_>>();
            assert_eq!(&actual, &expected[id], "step {step}: read set diverged for {id}");
        }
    }
    drop(mux);
    let mux = open();
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    for row in snapshot["notifications"].as_array().unwrap() {
        let id = NotificationPublicId::parse(row["id"].as_str().unwrap()).unwrap();
        let read_by = row["read_by"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_string())
            .collect::<BTreeSet<_>>();
        assert_eq!(read_by, expected[&id], "restart lost or invented a read mark for {id}");
    }
    let _ = std::fs::remove_dir_all(&root);
}
