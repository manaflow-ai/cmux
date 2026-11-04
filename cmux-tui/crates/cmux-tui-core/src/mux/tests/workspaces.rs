//! Screens and workspaces: names, sequences, empty registry limits, and persistent identity.

use super::*;

#[test]
fn screens_within_workspace() {
    let mux = test_mux();
    mux.new_workspace(None, None).unwrap();
    let s2 = mux.new_screen(None, None).unwrap();

    let (screen1, screen2) = mux.with_state(|s| {
        let ws = &s.workspaces[0];
        assert_eq!(ws.screens.len(), 2);
        assert_eq!(ws.active_screen, 1);
        (ws.screens[0].id, ws.screens[1].id)
    });

    // Select back to screen 1; screen 2 keeps running.
    mux.select_screen(Some(0), None);
    mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 0));

    // Renaming a screen sticks; clearing falls back.
    assert!(mux.rename_screen(screen2, "logs".into()));
    mux.with_state(|s| {
        assert_eq!(s.workspaces[0].screens[1].name.as_deref(), Some("logs"));
    });

    // Focusing a pane in screen 2 activates that screen.
    let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
    assert!(mux.focus_pane(p2));
    mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 1));

    // Closing screen 2 keeps the workspace with screen 1.
    assert!(mux.close_screen(screen2).unwrap());
    mux.with_state(|s| {
        let ws = &s.workspaces[0];
        assert_eq!(ws.screens.len(), 1);
        assert_eq!(ws.screens[0].id, screen1);
        assert_eq!(ws.active_screen, 0);
    });
}

#[test]
fn workspaces_and_renames() {
    let mux = test_mux();
    let events = mux.subscribe();
    mux.new_workspace(None, None).unwrap();
    mux.new_workspace(Some("dev".into()), None).unwrap();

    let (ws0, ws1, pane1, surface1) = mux.with_state(|s| {
        assert_eq!(s.workspaces.len(), 2);
        assert_eq!(s.workspaces[0].name, "workspace-1");
        assert_eq!(s.workspaces[1].name, "dev");
        assert_eq!(s.active_workspace, 1);
        let pane = s.workspaces[1].screens[0].active_pane;
        let surface = s.panes[&pane].tabs[0];
        (s.workspaces[0].id, s.workspaces[1].id, pane, surface)
    });

    assert!(mux.rename_workspace(ws0, "ops".into()));
    assert!(mux.rename_pane(pane1, "logs".into()));
    assert!(mux.rename_surface(surface1, "api".into()));
    mux.with_state(|s| {
        assert_eq!(s.workspaces[0].name, "ops");
        assert_eq!(s.panes[&pane1].name.as_deref(), Some("logs"));
        assert_eq!(s.surfaces[&surface1].name().as_deref(), Some("api"));
    });
    // Clearing the names falls back to the generated labels.
    assert!(mux.rename_pane(pane1, String::new()));
    assert!(mux.rename_surface(surface1, String::new()));
    mux.with_state(|s| {
        assert_eq!(s.panes[&pane1].name, None);
        assert_eq!(s.surfaces[&surface1].name(), None);
    });

    assert!(mux.close_workspace(ws1));
    mux.with_state(|s| {
        assert_eq!(s.workspaces.len(), 1);
        assert_eq!(s.workspaces[0].id, ws0);
        assert_eq!(s.active_workspace, 0);
    });
    assert!(events.try_iter().count() > 0);
}

#[test]
fn automatically_created_workspaces_use_one_based_sequence() {
    let mux = test_mux();
    let _first = mux.new_workspace(None, None).unwrap();
    let second = mux.new_workspace(None, None).unwrap();
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].name, "workspace-1");
        assert_eq!(state.workspaces[1].name, "workspace-2");
    });

    // A user name is authoritative and does not get rewritten by later
    // automatic creation. The sequence continues past existing defaults.
    let first_workspace = mux.with_state(|state| state.workspaces[0].id);
    assert!(mux.rename_workspace(first_workspace, "shell".into()));
    let third = mux.new_workspace(None, None).unwrap();
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].name, "shell");
        assert_eq!(state.workspaces[1].name, "workspace-2");
        assert_eq!(state.workspaces[2].name, "workspace-3");
    });
    assert_ne!(second.id, third.id);
}

#[test]
fn automatic_workspace_sequence_survives_renaming_the_first_workspace() {
    let mux = test_mux();
    let _first = mux.new_workspace(None, None).unwrap();
    let first_workspace = mux.with_state(|state| state.workspaces[0].id);
    assert!(mux.rename_workspace(first_workspace, "shell".into()));

    mux.new_workspace(None, None).unwrap();

    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].name, "shell");
        assert_eq!(state.workspaces[1].name, "workspace-2");
    });
}

#[test]
fn empty_workspace_registry_has_stable_keys_revisions_and_close() {
    let mux = test_mux();
    let events = mux.subscribe();
    let invalid = mux
        .create_empty_workspace(
            Some("invalid".into()),
            Some("frontend-scaling-not-a-uuid".into()),
            None,
        )
        .expect_err("noncanonical workspace key must fail");
    assert_eq!(invalid.to_string(), "workspace key must be a lowercase UUID");
    mux.with_state(|state| {
        assert_eq!(state.workspace_revision, 0);
        assert!(state.workspaces.is_empty());
    });
    let key = "018f6e21-7b70-7e70-8000-000000000001".to_string();
    let first = mux
        .create_empty_workspace(Some("empty".into()), Some(key.clone()), None)
        .expect("create empty workspace");
    assert_eq!(first.key, key);
    assert_eq!(first.index, 0);
    assert_eq!(first.revision, 1);
    mux.with_state(|state| {
        assert_eq!(state.workspace_revision, 1);
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].key, key);
        assert!(state.workspaces[0].screens.is_empty());
        assert_eq!(state.workspace_index(first.workspace), Some(0));
        assert_eq!(
            state.workspace_by_key(&key).map(|workspace| workspace.id),
            Some(first.workspace)
        );
    });
    let MuxEvent::TreeDelta(added) = events.recv().expect("workspace-added delta") else {
        panic!("expected workspace-added delta");
    };
    assert_eq!(added.kind, TreeDeltaKind::WorkspaceAdded);
    assert_eq!(added.workspace_revision, Some(1));
    assert_eq!(added.entity["key"], key);

    assert!(
        mux.create_empty_workspace(None, Some(first.key.clone()), None)
            .expect_err("duplicate stable key must fail")
            .to_string()
            .contains("already exists")
    );
    let conflict = mux
        .rename_workspace_at_revision(first.workspace, "stale".into(), Some(0))
        .expect_err("stale registry mutation must fail");
    assert_eq!(conflict.to_string(), "workspace revision conflict: expected 0, current 1");
    assert_eq!(
        mux.rename_workspace_at_revision(first.workspace, "renamed".into(), Some(1)).unwrap(),
        Some(2)
    );
    assert_eq!(mux.close_workspace_at_revision(first.workspace, Some(2)).unwrap(), Some(3));
    mux.with_state(|state| {
        assert!(state.workspaces.is_empty());
        assert_eq!(state.workspace_revision, 3);
        assert!(state.workspace_by_id(first.workspace).is_none());
        assert!(state.workspace_by_key(&key).is_none());
    });
    let MuxEvent::TreeDelta(closed) = events.recv().expect("workspace-closed delta") else {
        panic!("expected workspace-closed delta");
    };
    assert_eq!(closed.kind, TreeDeltaKind::WorkspaceClosed);
    assert_eq!(closed.workspace_revision, Some(3));
    assert!(matches!(events.recv().expect("empty event"), MuxEvent::Empty));
}

#[test]
fn empty_workspace_registry_enforces_count_and_string_limits() {
    let mux = test_mux();
    let boundary_key = "k".repeat(WORKSPACE_KEY_MAX_BYTES);
    Mux::validate_workspace_key(&boundary_key).expect("boundary-sized workspace key");
    let key = "018f6e21-7b70-7e70-8000-000000001020".to_string();
    let name = "n".repeat(WORKSPACE_NAME_MAX_BYTES);
    let placement = mux
        .create_empty_workspace(Some(name.clone()), Some(key.clone()), None)
        .expect("boundary-sized workspace fields");
    mux.with_state(|state| {
        let workspace = state.workspace_by_id(placement.workspace).unwrap();
        assert_eq!(workspace.key, key);
        assert_eq!(workspace.name, name);
    });

    let oversized_key = "k".repeat(WORKSPACE_KEY_MAX_BYTES + 1);
    assert_eq!(
        Mux::validate_workspace_key(&oversized_key)
            .expect_err("oversized key must fail")
            .to_string(),
        format!("workspace key exceeds {WORKSPACE_KEY_MAX_BYTES} bytes")
    );
    let oversized_name = "n".repeat(WORKSPACE_NAME_MAX_BYTES + 1);
    assert_eq!(
        mux.create_empty_workspace(Some(oversized_name.clone()), None, None)
            .expect_err("oversized name must fail")
            .to_string(),
        format!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes")
    );
    assert_eq!(
        mux.rename_workspace_at_revision(placement.workspace, oversized_name, Some(1))
            .expect_err("oversized rename must fail")
            .to_string(),
        format!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes")
    );
    mux.with_state(|state| {
        assert_eq!(state.workspace_revision, 1);
        assert_eq!(state.workspace_by_id(placement.workspace).unwrap().name, name);
    });

    let full_mux = test_mux();
    {
        let mut state = full_mux.state.lock().unwrap();
        for index in 0..WORKSPACE_REGISTRY_LIMIT {
            state.push_workspace(Workspace {
                id: index as u64 + 1,
                public_id: WorkspacePublicId::random().unwrap(),
                key: format!("key-{index}"),
                name: format!("workspace-{index}"),
                name_source: Default::default(),
                name_revision: 0,
                screens: Vec::new(),
                active_screen: 0,
            });
        }
    }
    assert_eq!(
        full_mux
            .create_empty_workspace(None, None, None)
            .expect_err("full registry must reject another workspace")
            .to_string(),
        format!("workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})")
    );
    full_mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), WORKSPACE_REGISTRY_LIMIT);
        assert_eq!(state.workspace_revision, 0);
    });
}

#[test]
fn concurrent_workspace_creation_suppresses_stale_empty_event() {
    let mux = test_mux();
    let initial = mux.create_empty_workspace(None, None, None).unwrap();
    let events = mux.subscribe();
    let close_ready = Arc::new(std::sync::Barrier::new(2));
    let resume_close = Arc::new(std::sync::Barrier::new(2));
    *mux.workspace_close_before_empty_check.lock().unwrap() = Some(Arc::new({
        let close_ready = close_ready.clone();
        let resume_close = resume_close.clone();
        move || {
            close_ready.wait();
            resume_close.wait();
        }
    }));

    let close_mux = mux.clone();
    let close = std::thread::spawn(move || {
        close_mux.close_workspace_at_revision(initial.workspace, Some(1)).unwrap()
    });
    close_ready.wait();
    let replacement = mux.create_empty_workspace(None, None, Some(2)).unwrap();
    *mux.workspace_close_before_empty_check.lock().unwrap() = None;
    resume_close.wait();
    assert_eq!(close.join().unwrap(), Some(2));

    let emitted = events.try_iter().collect::<Vec<_>>();
    assert!(emitted.iter().any(|event| matches!(
        event,
        MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceClosed, .. })
    )));
    assert!(emitted.iter().any(|event| matches!(
        event,
        MuxEvent::TreeDelta(TreeDelta {
            kind: TreeDeltaKind::WorkspaceAdded,
            workspace,
            ..
        }) if *workspace == replacement.workspace
    )));
    assert!(!emitted.iter().any(|event| matches!(event, MuxEvent::Empty)));
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].id, replacement.workspace);
    });
}

#[test]
fn registry_active_workspace_changes_emit_resync_barriers() {
    let mux = test_mux();
    let events = mux.subscribe();
    let first = mux.create_empty_workspace(Some("first".into()), None, None).unwrap();
    assert!(matches!(events.recv().unwrap(), MuxEvent::TreeDelta(_)));

    let second = mux.create_empty_workspace(Some("second".into()), None, None).unwrap();
    assert!(matches!(
        events.recv().unwrap(),
        MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceAdded, .. })
    ));
    assert!(matches!(events.recv().unwrap(), MuxEvent::TreeSelectionChanged(_)));

    mux.close_workspace_at_revision(second.workspace, Some(2)).unwrap();
    assert!(matches!(
        events.recv().unwrap(),
        MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceClosed, .. })
    ));
    assert!(matches!(events.recv().unwrap(), MuxEvent::TreeSelectionChanged(_)));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[state.active_workspace].id, first.workspace);
    });
}

#[test]
fn reaped_surface_close_closes_its_emptied_workspace() {
    let mux = test_mux();
    let keep = mux.new_workspace(None, Some((80, 24))).unwrap();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let events = mux.subscribe();
    let previous_revision = mux.with_state(|state| state.workspace_revision);

    let reaped = mux.state.lock().unwrap().surfaces.remove(&surface.id);
    assert!(reaped.is_some(), "surface must exist before simulating the early-exit race");
    assert!(mux.close_surface(surface.id).unwrap());

    // LAST-TAB-CLOSES-WORKSPACE: the workspace closes in the same commit.
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspace_revision, previous_revision + 1);
    });
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(remaining).expect("workspace-close event arrives") {
            MuxEvent::TreeDelta(TreeDelta {
                kind: TreeDeltaKind::WorkspaceClosed,
                workspace_revision: Some(_),
                ..
            }) => break,
            MuxEvent::Empty => panic!("closing a reaped surface emptied the session"),
            _ => {}
        }
    }
    assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::Empty)));
    surface.kill();
    keep.kill();
}

#[test]
fn reaped_surface_tree_target_close_closes_its_emptied_workspace() {
    for close_screen in [false, true] {
        let mux = test_mux();
        let keep = mux.new_workspace(None, Some((80, 24))).unwrap();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let (pane, screen, previous_revision) = mux.with_state(|state| {
            let pane = state.pane_of(surface.id).unwrap();
            let (wi, si) = state.screen_of(pane).unwrap();
            (pane, state.workspaces[wi].screens[si].id, state.workspace_revision)
        });
        let events = mux.subscribe();
        let reaped = mux.state.lock().unwrap().surfaces.remove(&surface.id);
        assert!(reaped.is_some(), "surface must exist before simulating the race");

        if close_screen {
            assert!(mux.close_screen(screen).unwrap());
        } else {
            mux.close_pane(pane).unwrap();
        }

        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspace_revision, previous_revision + 1);
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match events.recv_timeout(remaining).expect("workspace-close event arrives") {
                MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::WorkspaceClosed,
                    workspace_revision: Some(_),
                    ..
                }) => break,
                MuxEvent::Empty => panic!("closing a reaped tree target emptied the session"),
                _ => {}
            }
        }
        assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::Empty)));
        surface.kill();
        keep.kill();
    }
}

#[test]
fn persistent_workspace_registry_recovers_exact_identity_order_and_revision() {
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-persistent-{}", crate::workspace_registry::new_uuid_v4()));
    let (registry_id, generation) = {
        let mux = Mux::open_persistent("recover", SurfaceOptions::default(), &root).unwrap();
        let first = mux
            .create_empty_workspace(
                Some("one".into()),
                Some("018f6e21-7b70-7e70-8000-000000001004".into()),
                Some(0),
            )
            .unwrap();
        let second = mux
            .create_empty_workspace(
                Some("two".into()),
                Some("018f6e21-7b70-7e70-8000-000000001005".into()),
                Some(1),
            )
            .unwrap();
        assert_eq!(
            mux.rename_workspace_at_revision(second.workspace, "renamed".into(), Some(2)).unwrap(),
            Some(3)
        );
        assert_eq!(
            mux.move_workspace_at_revision(second.workspace, 0, Some(3)).unwrap(),
            Some((4, true))
        );
        assert_eq!(first.workspace, 1);
        mux.registry_identity()
    };

    let recovered = Mux::open_persistent("recover", SurfaceOptions::default(), &root).unwrap();
    let (recovered_registry_id, recovered_generation) = recovered.registry_identity();
    assert_eq!(recovered_registry_id, registry_id);
    assert_ne!(recovered_generation, generation);
    recovered.with_state(|state| {
        assert_eq!(state.workspace_revision, 4);
        assert_eq!(state.workspaces.len(), 2);
        assert_eq!(state.workspaces[0].key, "018f6e21-7b70-7e70-8000-000000001005");
        assert_eq!(state.workspaces[0].name, "renamed");
        assert_eq!(state.workspaces[1].key, "018f6e21-7b70-7e70-8000-000000001004");
        assert!(state.workspaces.iter().all(|workspace| workspace.screens.is_empty()));
    });
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn persistent_provider_managed_mux_keeps_registry_durable_and_lifecycle_guarded() {
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-persistent-provider-{}", crate::workspace_registry::new_uuid_v4()));
    let key = "018f6e21-7b70-7e70-8000-000000001019";
    {
        let mux = Mux::open_persistent_provider_managed(
            "recover-provider",
            SurfaceOptions::default(),
            &root,
            ProviderWorkspaceAuthority::new("persistent-provider-authority-00000001").unwrap(),
        )
        .unwrap();
        let workspace =
            mux.create_empty_workspace(Some("managed".into()), Some(key.into()), None).unwrap();
        let error = mux
            .rename_workspace_at_revision(workspace.workspace, "escaped".into(), None)
            .unwrap_err();
        assert!(error.to_string().contains("provider-managed workspace directly"));
        assert_eq!(
            mux.rename_provider_managed_workspace(
                workspace.workspace,
                key,
                "provider rename".into(),
            )
            .unwrap(),
            Some(2)
        );
        mux.shutdown();
    }

    let recovered = Mux::open_persistent_provider_managed(
        "recover-provider",
        SurfaceOptions::default(),
        &root,
        ProviderWorkspaceAuthority::new("replacement-process-authority-00001").unwrap(),
    )
    .unwrap();
    recovered.with_state(|state| {
        assert_eq!(state.workspace_revision, 2);
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].key, key);
        assert_eq!(state.workspaces[0].name, "provider rename");
    });
    let error = recovered.close_workspace_at_revision(1, None).unwrap_err();
    assert!(error.to_string().contains("provider-managed workspace directly"));
    recovered.shutdown();
    drop(recovered);
    std::fs::remove_dir_all(root).unwrap();
}

/// The registry's identity never waits on its lock (#27698 audit): durable
/// commits hold it for seconds on a loaded Mac, and every mutation's reply,
/// `list-workspaces` and `identify` read the identity.
#[test]
fn registry_identity_does_not_wait_on_the_registry_lock() {
    let mux = test_mux();
    let expected = mux.registry_identity();
    let held = mux.workspace_registry.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = mux.clone();
    std::thread::spawn(move || tx.send(reader.registry_identity()).unwrap());
    let read = rx.recv_timeout(Duration::from_secs(5));
    drop(held);
    assert_eq!(read.ok(), Some(expected), "the identity waited on the held registry lock");
}

/// The workspace changes the journal states after `revision`: (upserts, deletes) by workspace public id.
fn workspace_changes_after(mux: &Mux, revision: u64) -> (Vec<String>, Vec<String>) {
    let mut upserts = Vec::new();
    let mut deletes = Vec::new();
    for batch in mux.resource_events_after(revision).unwrap().batches {
        for change in batch.changes.as_array().cloned().unwrap_or_default() {
            if change["resource"] != "workspace" {
                continue;
            }
            let id = change["id"].as_str().unwrap().to_string();
            if change["kind"] == "upsert" {
                upserts.push(id);
            } else if change["kind"] == "delete" {
                deletes.push(id);
            }
        }
    }
    (upserts, deletes)
}

/// The workspace values the journal states, folded from revision 0 over every page, by workspace public id.
fn journal_workspaces(mux: &Mux) -> std::collections::BTreeMap<String, Value> {
    let mut stated = std::collections::BTreeMap::<String, Value>::new();
    let mut revision = 0;
    loop {
        let page = mux.resource_events_after(revision).unwrap();
        if page.batches.is_empty() {
            return stated;
        }
        for batch in page.batches {
            revision = batch.revision;
            for change in batch.changes.as_array().cloned().unwrap_or_default() {
                if change["resource"] != "workspace" {
                    continue;
                }
                let id = change["id"].as_str().unwrap().to_string();
                if change["kind"] == "delete" {
                    stated.remove(&id);
                } else if change["kind"] == "upsert" {
                    stated.insert(id, change["value"].clone());
                }
            }
        }
    }
}

/// The journal, folded from revision 0, states each live workspace's whole value as its rows give it now
/// (`workspace_value`: name, index, focus, session, name provenance, decorations and key), and no other.
fn assert_journal_states_the_rows(mux: &Mux) {
    let stated = journal_workspaces(mux);
    let registry = mux.workspace_registry.lock().unwrap();
    let db = registry.connection.get();
    let live = db
        .prepare(
            "SELECT rw.public_id FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
             ORDER BY w.position",
        )
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    for id in &live {
        let rows = crate::state::values::workspace_value(&db, id).unwrap().unwrap();
        assert_eq!(
            stated.get(id),
            Some(&rows),
            "workspace {id}: the journal states {:?}, its rows {rows}",
            stated.get(id)
        );
    }
    assert_eq!(
        stated.len(),
        live.len(),
        "the journal states {} workspaces, the rows hold {}",
        stated.len(),
        live.len()
    );
}

/// The journal, folded from revision 0, states every live workspace as the session snapshot shows it (name, index,
/// focus, and the decorations: title, color, icon), and no other; and each whole value as its rows give it.
fn assert_journal_states_the_session(mux: &Mux) {
    let stated = journal_workspaces(mux);
    let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
    let live = snapshot["workspaces"].as_array().unwrap();
    assert_eq!(
        stated.len(),
        live.len(),
        "the journal states {} workspaces, the session has {}",
        stated.len(),
        live.len()
    );
    for workspace in live {
        let id = workspace["id"].as_str().unwrap();
        let journal = &stated[id];
        for field in ["name", "index", "focused"] {
            assert_eq!(
                journal[field], workspace[field],
                "workspace {id}: journal {field} {} vs session {}",
                journal[field], workspace[field]
            );
        }
        for field in ["title", "color", "icon"] {
            assert_eq!(
                journal["extra"][field], workspace["extra"][field],
                "workspace {id}: journal extra.{field} {} vs session {}",
                journal["extra"][field], workspace["extra"][field]
            );
        }
    }
    assert_journal_states_the_rows(mux);
}

/// `count` workspaces, then one full resource effect projection (as a session's first terminal create runs when the
/// fold is empty), which restates every resource and seeds the journal's public fold, as in a live session.
fn mux_with_workspaces(count: usize) -> Arc<Mux> {
    let mux = test_mux();
    for index in 0..count {
        let key = format!("018f6e21-7b70-7e70-8000-{index:012}");
        mux.create_empty_workspace(Some(format!("ws {index}")), Some(key), None).unwrap();
    }
    let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
    let fingerprint = serde_json::json!({"operation": operation, "fixture": key});
    let expected_revision = mux.with_state(|state| state.resource_revision);
    mux.prepare_resource_effect(
        &WorkspaceMutation::daemon(key, "test").unwrap(),
        operation,
        &fingerprint,
        &serde_json::json!({}),
        None,
        Some(expected_revision),
    )
    .unwrap();
    mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
    mux.commit_full_resource_effect_projection(key, operation, &fingerprint, serde_json::json!({}))
        .unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().public_fold_seeded(),
        "the full projection did not seed the fold"
    );
    mux
}

/// A workspace create states only what it changes in the journal (#32408). Each create restated every workspace
/// (an upsert of each, with its index and focus), so its journal record and its WAL bytes grew with the session:
/// 542 KB per create at 50 workspaces, 3434 KB at 500, in the classic import. A create at the end changes the new
/// workspace and, when it takes the focus, the one that loses it.
#[test]
fn a_workspace_create_journals_only_the_workspaces_it_changes() {
    let mux = mux_with_workspaces(40);
    let before = mux.with_state(|state| state.resource_revision);
    mux.create_empty_workspace(
        Some("last".into()),
        Some("018f6e21-7b70-7e70-8000-000000009999".into()),
        None,
    )
    .unwrap();
    let (upserts, _) = workspace_changes_after(&mux, before);
    assert!(
        (1..=2).contains(&upserts.len()),
        "one create at 40 workspaces journaled {} workspace upserts (the new one, and the one losing focus)",
        upserts.len()
    );
    assert_journal_states_the_session(&mux);
}

/// A move to the middle shifts the index of every workspace between its old and new place: each of those is
/// stated again, and only those.
#[test]
fn a_workspace_move_journals_every_workspace_it_shifts() {
    let mux = mux_with_workspaces(40);
    let moved = mux.with_state(|state| state.workspaces[30].id);
    let before = mux.with_state(|state| state.resource_revision);
    mux.move_workspace_at_revision_as(&Actor::Daemon, moved, 10, None).unwrap();
    let (upserts, _) = workspace_changes_after(&mux, before);
    // Index 30 to 10: the moved one and the 20 that shift down by one (10..=29), plus at most one focus change.
    assert!(
        (21..=22).contains(&upserts.len()),
        "a move from 30 to 10 journaled {} workspace upserts",
        upserts.len()
    );
    assert_journal_states_the_session(&mux);
}

/// A rename states the renamed workspace only.
#[test]
fn a_workspace_rename_journals_only_that_workspace() {
    let mux = mux_with_workspaces(40);
    let renamed = mux.with_state(|state| state.workspaces[17].id);
    let before = mux.with_state(|state| state.resource_revision);
    mux.rename_workspace_at_revision_as(&Actor::Daemon, renamed, "renamed".into(), None).unwrap();
    let (upserts, _) = workspace_changes_after(&mux, before);
    assert_eq!(
        upserts.len(),
        1,
        "a rename at 40 workspaces journaled {} workspace upserts",
        upserts.len()
    );
    assert_journal_states_the_session(&mux);
}

/// A metadata commit (a color) changes only the workspace's decorations, through its extra rows: that workspace is
/// still stated, with the new color.
#[test]
fn a_workspace_metadata_commit_journals_its_workspace() {
    let mux = mux_with_workspaces(40);
    let key = mux.with_state(|state| state.workspaces[5].key.clone());
    let before = mux.with_state(|state| state.resource_revision);
    let update = crate::workspace_registry::WorkspacePresentationUpdate {
        color: Some(Some("red".into())),
        ..Default::default()
    };
    mux.set_workspace_metadata(
        None,
        Some(&key),
        update,
        None,
        None,
        &WorkspaceMutation::daemon_local("cmux-tui"),
    )
    .unwrap();
    let (upserts, _) = workspace_changes_after(&mux, before);
    assert!(!upserts.is_empty(), "a color change journaled no workspace upsert");
    assert!(
        upserts.len() <= 2,
        "a color change at 40 workspaces journaled {} workspace upserts",
        upserts.len()
    );
    assert_journal_states_the_session(&mux);
}

/// A resource-path move (`workspace.move`, `SetWorkspaceOrder` in a resource patch) moves positions outside the
/// legacy workspace commit; a later workspace create must still leave the journal stating every workspace's index.
#[test]
fn a_create_after_a_resource_move_keeps_the_journal_equal_to_the_session() {
    let mux = mux_with_workspaces(40);
    let moved = mux.with_state(|state| state.workspaces[30].public_id.clone());
    mux.resource_move_workspace(
        &moved,
        5,
        None,
        None,
        &WorkspaceMutation::daemon_local("cmux-tui"),
    )
    .unwrap();
    assert_journal_states_the_session(&mux);
    mux.create_empty_workspace(
        Some("after-move".into()),
        Some("018f6e21-7b70-7e70-8000-000000009998".into()),
        None,
    )
    .unwrap();
    assert_journal_states_the_session(&mux);
}

/// A close in the middle shifts every later workspace down by one: each of those is stated again with its new
/// index, the closed one is deleted, and no other workspace is stated.
#[test]
fn a_workspace_close_journals_every_workspace_it_shifts() {
    let mux = mux_with_workspaces(40);
    let (closed, closed_id) = mux
        .with_state(|state| (state.workspaces[10].id, state.workspaces[10].public_id.to_string()));
    let before = mux.with_state(|state| state.resource_revision);
    assert!(mux.close_workspace_as(&Actor::Daemon, closed));
    let (upserts, deletes) = workspace_changes_after(&mux, before);
    // Indexes 11..=39 shift to 10..=38: 29 workspaces, plus at most one focus change.
    assert!(
        (29..=30).contains(&upserts.len()),
        "a close at index 10 of 40 journaled {} workspace upserts",
        upserts.len()
    );
    assert_eq!(deletes, vec![closed_id], "a close at index 10 of 40 journaled these deletes");
    assert_journal_states_the_session(&mux);
}

/// A pin changes no field of the workspace's public value (`pinned` is presentation state the value does not
/// carry). The commit's extra rows ran, so its own workspace is still stated, and only that one: a journal reader
/// still sees which workspace a metadata commit changed.
#[test]
fn a_workspace_pin_journals_its_workspace() {
    let mux = mux_with_workspaces(40);
    let (key, id) = mux.with_state(|state| {
        (state.workspaces[5].key.clone(), state.workspaces[5].public_id.to_string())
    });
    let before = mux.with_state(|state| state.resource_revision);
    let update = crate::workspace_registry::WorkspacePresentationUpdate {
        pinned: Some(true),
        ..Default::default()
    };
    mux.set_workspace_metadata(
        None,
        Some(&key),
        update,
        None,
        None,
        &WorkspaceMutation::daemon_local("cmux-tui"),
    )
    .unwrap();
    let (upserts, _) = workspace_changes_after(&mux, before);
    assert_eq!(upserts, vec![id], "a pin at 40 workspaces journaled these workspace upserts");
    assert_journal_states_the_session(&mux);
}

/// A workspace commit prepared before another one lands holds a fold copy at an older revision, so it states every
/// workspace, as before #32408. Here an early commit moves workspace 30 to index 10; a late one, prepared on the base
/// before that move landed, renames workspace 17 and writes the base order back. Its fold copy states the base
/// indexes, so pruning against it would drop the 21 workspaces it moves back and leave the journal stating the early
/// move's order.
#[test]
fn a_workspace_commit_prepared_before_another_lands_states_every_workspace() {
    let mux = mux_with_workspaces(40);
    let (base, active) = mux.with_state(|state| {
        (
            mux.registry_projection(state),
            state
                .workspaces
                .get(state.active_workspace)
                .map(|workspace| workspace.public_id.clone()),
        )
    });
    let mut moved = base.clone();
    let workspace = moved.remove(30);
    moved.insert(10, workspace);
    let mut renamed = base.clone();
    renamed[17].name = "late".into();
    renamed[17].name_source = crate::resource_name::NameSource::User;
    renamed[17].name_revision += 1;
    let mut registry = mux.workspace_registry.lock().unwrap();
    let mut prepare = |workspaces: &[RegistryWorkspace], key: &str, op: &str| {
        registry
            .prepare_workspace_commit(
                &WorkspaceMutation::daemon_local("cmux-tui"),
                &serde_json::json!({"op": op}),
                None,
                None,
                op,
                key,
                workspaces,
                active.as_ref(),
                &serde_json::json!({"changed": true}),
                true,
            )
            .unwrap()
    };
    let late = prepare(&renamed, &base[17].key, "workspace-renamed");
    let early = prepare(&moved, &base[30].key, "workspace-moved");
    for intent in [early, late] {
        registry
            .commit_registry_intent(crate::workspace_registry::RegistryIntent::Workspace(intent))
            .unwrap();
    }
    drop(registry);
    assert_journal_states_the_rows(&mux);
}
