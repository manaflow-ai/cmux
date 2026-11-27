use super::*;

struct Session {
    root: std::path::PathBuf,
}

impl Session {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-screens-{name}-{}", WorkspacePublicId::random().unwrap()));
        Self { root }
    }

    /// The registry alone, after the mux that held it is dropped.
    fn registry(&self) -> WorkspaceRegistry {
        WorkspaceRegistry::open(&self.root, "screens").unwrap()
    }

    fn open(&self) -> Arc<Mux> {
        let registry = WorkspaceRegistry::open(&self.root, "screens").unwrap();
        Mux::from_workspace_registry(
            "screens".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Screen ids of workspace `index`, in order.
fn order(mux: &Mux, index: usize) -> Vec<ScreenId> {
    mux.with_state(|state| state.workspaces[index].screens.iter().map(|s| s.id).collect())
}

fn public_order(mux: &Mux, index: usize) -> Vec<String> {
    mux.with_state(|state| {
        state.workspaces[index].screens.iter().map(|s| s.public_id.as_str().to_string()).collect()
    })
}

fn tree(mux: &Mux) -> Value {
    let decorations = mux.tree_decorations();
    mux.with_state(|state| crate::server::workspaces_json(state, &decorations))
}

fn new_screen(mux: &Arc<Mux>, workspace: WorkspaceId) -> ScreenId {
    mux.new_screen_with_spec(
        Some(workspace),
        TerminalSpawnOptions::new(None, Vec::new()),
        None,
        ScreenSpec::default(),
    )
    .unwrap()
    .1
}

#[test]
fn cmux_next_screen_metadata_survives_restart_and_emits_screen_changed() {
    let session = Session::new("metadata");
    let mux = session.open();
    let first = mux.new_workspace(None, None).unwrap().id;
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let s1 = order(&mux, 0)[0];
    let s2 = new_screen(&mux, workspace);
    let s3 = new_screen(&mux, workspace);
    assert_eq!(order(&mux, 0), vec![s1, s2, s3]);
    let _ = first;

    let events = mux.subscribe();
    assert!(
        mux.set_screen_metadata(s3, Some(Some("green".into())), Some(Some("🚀".into()))).unwrap()
    );
    let delta = std::iter::from_fn(|| events.try_recv().ok())
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => Some(delta),
            _ => None,
        })
        .expect("screen-changed delta");
    assert_eq!(delta.screen, Some(s3));
    assert_eq!(delta.index, Some(2));
    assert_eq!(delta.entity["color"], "green");
    assert_eq!(delta.entity["icon"], "🚀");
    assert!(mux.set_screen_metadata(s3, Some(Some("bad color!".into())), None).is_err());
    assert!(mux.set_screen_metadata(s3, None, Some(Some("two words".into()))).is_err());
    // Absent keeps, null clears.
    assert!(mux.set_screen_metadata(s3, None, Some(None)).unwrap());
    assert!(!mux.set_screen_metadata(s3, None, None).unwrap());

    let (changed, index) = mux.set_screen_pinned(s3, true).unwrap();
    assert!(changed);
    assert_eq!(index, 0);
    assert_eq!(order(&mux, 0), vec![s3, s1, s2]);
    mux.rename_screen(s2, "logs".into());
    mux.move_screen(s2, ScreenDestination::Workspace { workspace: None, index: Some(0) }).unwrap();
    // The pinned screen stays first.
    assert_eq!(order(&mux, 0), vec![s3, s2, s1]);
    let json = tree(&mux);
    assert_eq!(json["workspaces"][0]["screens"][0]["pinned"], true);
    assert_eq!(json["workspaces"][0]["screens"][0]["color"], "green");
    assert_eq!(json["workspaces"][0]["screens"][0]["icon"], Value::Null);
    assert_eq!(json["workspaces"][0]["screens"][1]["name"], "logs");

    // Order, pin, and color are durable: the registry has them after
    // the daemon exits.
    let before = public_order(&mux, 0);
    let workspace_public =
        mux.with_state(|state| state.workspaces[0].public_id.as_str().to_string());
    drop(mux);
    let registry = session.registry();
    assert_eq!(registry.live_screen_order(&workspace_public).unwrap(), before);
    let snapshot = registry.presentation_snapshot().unwrap();
    let record = snapshot.screens.screen(&before[0]).unwrap();
    assert!(record.pinned);
    assert_eq!(record.color.as_deref(), Some("green"));
    assert_eq!(record.icon, None);
}

#[test]
fn cmux_next_screen_groups_stay_contiguous_and_survive_restart() {
    let session = Session::new("groups");
    let mux = session.open();
    mux.new_workspace(None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let s1 = order(&mux, 0)[0];
    let s2 = new_screen(&mux, workspace);
    let s3 = new_screen(&mux, workspace);
    let s4 = new_screen(&mux, workspace);
    mux.set_screen_pinned(s1, true).unwrap();
    assert!(
        mux.create_screen_group(&[s1], None, None).is_err(),
        "pinned screens cannot be grouped"
    );
    assert!(mux.create_screen_group(&[s2], None, Some("blurple".into())).is_err());

    let created =
        mux.create_screen_group(&[s4, s2], Some("Build".into()), Some("orange".into())).unwrap();
    let group = created.group.clone().unwrap().id;
    assert_eq!(created.members, vec![s2, s4]);
    assert_eq!(order(&mux, 0), vec![s1, s2, s4, s3]);

    mux.update_screen_group(&group, Some(String::new()), Some("cyan".into()), Some(true)).unwrap();
    let record = mux.presentation_snapshot().screens.groups[&group].clone();
    assert_eq!((record.name.as_str(), record.color.as_str(), record.collapsed), ("", "cyan", true));

    mux.add_screens_to_screen_group(&group, &[s3], Some(0)).unwrap();
    assert_eq!(order(&mux, 0), vec![s1, s3, s2, s4]);
    mux.remove_screens_from_screen_group(&[s3]).unwrap();
    assert_eq!(order(&mux, 0), vec![s1, s2, s4, s3]);
    // A single screen move into the middle of the group is pulled out:
    // groups stay contiguous.
    mux.move_screen(s3, ScreenDestination::Workspace { workspace: None, index: Some(2) }).unwrap();
    let runs = mux.with_state(|state| {
        workspace_screen_groups(&state.workspaces[0], &mux.presentation_snapshot().screens)
    });
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].members.len(), 2);
    // Moving the group cannot pass the pinned screen.
    mux.move_screen_group(&group, ScreenDestination::Workspace { workspace: None, index: Some(0) })
        .unwrap();
    assert_eq!(order(&mux, 0)[0], s1);

    let json = tree(&mux);
    let groups = &json["workspaces"][0]["screen_groups"];
    assert_eq!(groups[0]["id"], group.as_str());
    assert_eq!(groups[0]["count"], 2);
    assert_eq!(groups[0]["collapsed"], true);
    let start = groups[0]["start"].as_u64().unwrap() as usize;
    assert_eq!(json["workspaces"][0]["screens"][start]["group"], group.as_str());

    let saved = mux.save_screen_group(&group).unwrap();
    assert_eq!(mux.presentation_snapshot().saved_screen_groups[0].id, saved);
    assert_eq!(mux.presentation_snapshot().saved_screen_groups[0].members.len(), 2);

    let before = public_order(&mux, 0);
    let workspace_public =
        mux.with_state(|state| state.workspaces[0].public_id.as_str().to_string());
    drop(mux);
    {
        let registry = session.registry();
        assert_eq!(registry.live_screen_order(&workspace_public).unwrap(), before);
        let snapshot = registry.presentation_snapshot().unwrap();
        assert_eq!(snapshot.screens.groups[&group].saved_id.as_deref(), Some(saved.as_str()));
        assert!(snapshot.screens.groups[&group].collapsed);
        assert_eq!(snapshot.screens.members.values().filter(|g| **g == group).count(), 2);
        assert_eq!(snapshot.saved_screen_groups.len(), 1);
    }
    let mux = session.open();
    mux.new_workspace(None, None).unwrap();

    mux.ungroup_screen_group(&group).ok();
    assert!(mux.presentation_snapshot().screens.groups.is_empty());
    // The saved record outlives the live group and reopens it.
    let workspace = mux.with_state(|state| state.workspaces.last().unwrap().id);
    let reopened = mux.reopen_saved_screen_group(&saved, workspace).unwrap();
    assert_eq!(reopened.members.len(), 2);
    assert_eq!(reopened.group.unwrap().saved_id.as_deref(), Some(saved.as_str()));
    assert!(mux.delete_saved_screen_group(&saved).unwrap());
}

#[test]
fn cmux_next_screens_move_between_workspaces_with_their_terminals() {
    let session = Session::new("moves");
    let mux = session.open();
    mux.new_workspace(None, None).unwrap();
    mux.new_workspace(None, None).unwrap();
    let (a, b) = mux.with_state(|state| (state.workspaces[0].id, state.workspaces[1].id));
    let s1 = order(&mux, 0)[0];
    // A workspace keeps at least one screen.
    assert!(
        mux.move_screen(s1, ScreenDestination::Workspace { workspace: Some(b), index: None })
            .is_err()
    );
    let s2 = new_screen(&mux, a);
    let surface = mux.with_state(|state| {
        let (wi, si) = locate_screen(state, s2).unwrap();
        state.panes[&state.workspaces[wi].screens[si].active_pane].tabs[0]
    });
    let moved = mux
        .move_screen(s2, ScreenDestination::Workspace { workspace: Some(b), index: Some(0) })
        .unwrap();
    assert_eq!(moved.workspace, b);
    assert_eq!(moved.index, 0);
    assert_eq!(order(&mux, 0), vec![s1]);
    assert_eq!(order(&mux, 1)[0], s2);
    // The terminal moved with its screen.
    let owner = mux.with_state(|state| {
        state.pane_of(surface).and_then(|pane| state.screen_of(pane)).map(|(wi, _)| wi)
    });
    assert_eq!(owner, Some(1));

    let count = mux.with_state(|state| state.workspaces.len());
    let s3 = new_screen(&mux, b);
    let moved = mux.move_screen(s3, ScreenDestination::NewWorkspace).unwrap();
    assert_eq!(mux.with_state(|state| state.workspaces.len()), count + 1);
    assert_eq!(order(&mux, count), vec![s3]);
    assert_eq!(moved.key, mux.with_state(|state| state.workspaces[count].key.clone()));

    // A screen that changes workspace leaves its group.
    let s4 = new_screen(&mux, b);
    let group = mux.create_screen_group(&[s4], None, None).unwrap().group.unwrap().id;
    mux.move_screen(s4, ScreenDestination::Workspace { workspace: Some(a), index: None }).unwrap();
    assert!(!mux.presentation_snapshot().screens.members.values().any(|g| g == &group));
}

#[test]
fn cmux_next_new_screen_with_spec_applies_name_metadata_position_and_directory() {
    let session = Session::new("spec");
    let mux = session.open();
    mux.new_workspace(None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let s1 = order(&mux, 0)[0];
    let group = mux.create_screen_group(&[s1], Some("g".into()), None).unwrap().group.unwrap().id;
    let dir = std::env::temp_dir();
    let spec = ScreenSpec {
        name: Some("deploy".into()),
        color: Some("red".into()),
        icon: Some("server.rack".into()),
        pinned: None,
        index: Some(0),
        group: Some(group.clone()),
    };
    let (_, screen) = mux
        .new_screen_with_spec(
            Some(workspace),
            TerminalSpawnOptions::new(Some(dir.display().to_string()), Vec::new()),
            None,
            spec,
        )
        .unwrap();
    let json = tree(&mux);
    let screens = json["workspaces"][0]["screens"].as_array().unwrap();
    let entity = screens.iter().find(|s| s["id"] == screen).unwrap();
    assert_eq!(entity["name"], "deploy");
    assert_eq!(entity["color"], "red");
    assert_eq!(entity["icon"], "server.rack");
    assert_eq!(entity["group"], group.as_str());
    assert_eq!(order(&mux, 0), vec![screen, s1]);
}

/// A terminal that exits at once can close its new screen before
/// `new_screen_with_spec_as` returns; the screen was still created, so the
/// call reports its ids instead of failing with "new screen disappeared".
#[test]
fn a_screen_closed_by_its_exit_right_after_create_still_reports_its_ids() {
    for spec in
        [ScreenSpec::default(), ScreenSpec { color: Some("green".into()), ..ScreenSpec::default() }]
    {
        let session = Session::new("exit-after-create");
        let mux = session.open();
        mux.new_workspace(None, None).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        let exiting = Arc::downgrade(&mux);
        mux.set_screen_created_hook_for_test(move |surface| {
            let mux = exiting.upgrade().unwrap();
            let host = mux
                .resource_terminal_host_identity(&mux.surface(surface).unwrap())
                .unwrap()
                .terminal_id;
            let terminal = mux
                .workspace_registry
                .lock()
                .unwrap()
                .terminal_resource_id(&host)
                .unwrap()
                .unwrap();
            let exit = TerminalExit {
                outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
                exited_at_ms: 1,
            };
            assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());
            mux.surface_exited(surface);
        });
        let (surface, screen) = mux
            .new_screen_with_spec(
                Some(workspace),
                TerminalSpawnOptions::new(None, Vec::new()),
                None,
                spec,
            )
            .expect("a created screen is reported even after its terminal exited");
        assert!(mux.surface(surface.id).is_none(), "the exit removed the surface");
        assert!(!order(&mux, 0).contains(&screen), "the exit closed the screen");
    }
}
