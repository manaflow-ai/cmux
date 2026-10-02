use super::*;

pub(crate) struct PresentationTestSession {
    root: std::path::PathBuf,
    session: &'static str,
}

impl PresentationTestSession {
    pub(crate) fn new(session: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-presentation-{session}-{}", WorkspacePublicId::random().unwrap()));
        Self { root, session }
    }

    pub(crate) fn open(&self) -> Arc<Mux> {
        let registry = WorkspaceRegistry::open(&self.root, self.session).unwrap();
        Mux::from_workspace_registry(
            self.session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }
}

impl Drop for PresentationTestSession {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn keys(mux: &Mux) -> Vec<String> {
    mux.with_state(|state| state.workspaces.iter().map(|ws| ws.key.clone()).collect())
}

fn group_of(mux: &Mux, key: &str) -> Option<String> {
    mux.presentation_snapshot().workspace(key).and_then(|record| record.group.clone())
}

fn move_to_group(mux: &Mux, key: &str, group: Option<&str>, index: Option<usize>) {
    mux.move_workspace_to_group(
        None,
        Some(key),
        group.map(str::to_string),
        index,
        None,
        None,
        &WorkspaceMutation::local("presentation-test"),
    )
    .unwrap();
}

#[test]
fn cmux_next_workspace_groups_survive_restart_with_order_membership_and_collapse() {
    let session = PresentationTestSession::new("groups");
    let mux = session.open();
    let a = mux.create_empty_workspace(Some("a".into()), None, None).unwrap().key;
    let b = mux.create_empty_workspace(Some("b".into()), None, None).unwrap().key;
    let c = mux.create_empty_workspace(Some("c".into()), None, None).unwrap().key;

    let work =
        mux.create_workspace_group(Some("work".into()), "Work".into(), None, false, None).unwrap();
    assert_eq!((work.index, work.changed), (0, true));
    let personal = mux
        .create_workspace_group(
            Some("personal".into()),
            "Personal".into(),
            Some("gray".into()),
            false,
            Some(0),
        )
        .unwrap();
    assert_eq!(personal.index, 0);
    // A retried create with the same id and name is a no-op.
    let retry =
        mux.create_workspace_group(Some("work".into()), "Work".into(), None, false, None).unwrap();
    assert!(!retry.changed);
    assert!(
        mux.create_workspace_group(Some("work".into()), "Other".into(), None, false, None).is_err()
    );

    move_to_group(&mux, &a, Some("work"), None);
    // `c` lands before `a` inside `work`: its final in-group index is 0.
    move_to_group(&mux, &c, Some("work"), Some(0));
    assert_eq!(keys(&mux), vec![c.clone(), a.clone(), b.clone()]);
    assert_eq!(group_of(&mux, &a).as_deref(), Some("work"));
    assert_eq!(group_of(&mux, &c).as_deref(), Some("work"));
    assert_eq!(group_of(&mux, &b), None);
    // Reordering within the group moves only relative to its members.
    move_to_group(&mux, &c, Some("work"), Some(1));
    assert_eq!(keys(&mux), vec![a.clone(), c.clone(), b.clone()]);
    assert!(
        mux.move_workspace_to_group(
            None,
            Some(&b),
            Some("missing".into()),
            None,
            None,
            None,
            &WorkspaceMutation::local("presentation-test"),
        )
        .is_err()
    );

    mux.update_workspace_group("work", None, Some(Some("#445566".into())), Some(true)).unwrap();
    let moved = mux.move_workspace_group("work", 0).unwrap();
    assert_eq!(moved.index, 0);
    drop(mux);

    let mux = session.open();
    let groups = mux.workspace_groups();
    assert_eq!(
        groups.iter().map(|group| group.id.as_str()).collect::<Vec<_>>(),
        vec!["work", "personal"]
    );
    assert!(groups[0].collapsed);
    assert_eq!(groups[0].color.as_deref(), Some("#445566"));
    assert_eq!(groups[1].color.as_deref(), Some("gray"));
    assert_eq!(keys(&mux), vec![a.clone(), c.clone(), b.clone()]);
    assert_eq!(group_of(&mux, &a).as_deref(), Some("work"));

    // Deleting a group ungroups its workspaces in place.
    let mut ungrouped = mux.delete_workspace_group("work").unwrap();
    ungrouped.sort();
    let mut expected = vec![a.clone(), c.clone()];
    expected.sort();
    assert_eq!(ungrouped, expected);
    assert_eq!(group_of(&mux, &a), None);
    assert_eq!(keys(&mux), vec![a, c, b]);
    drop(mux);
    let mux = session.open();
    assert_eq!(mux.workspace_groups().len(), 1);
}

#[test]
fn cmux_next_workspace_metadata_survives_restart_and_emits_workspace_changed() {
    let session = PresentationTestSession::new("metadata");
    let mux = session.open();
    let key = mux.create_empty_workspace(Some("repo".into()), None, None).unwrap().key;
    let events = mux.subscribe();
    let update = WorkspacePresentationUpdate {
        group: None,
        color: Some(Some("gray".into())),
        icon: Some(Some("terminal.fill".into())),
        title: Some(Some("Release train".into())),
        pinned: Some(true),
        marked_unread: Some(true),
    };
    let result = mux
        .set_workspace_metadata(
            None,
            Some(&key),
            update.clone(),
            None,
            None,
            &WorkspaceMutation::new("meta-1", "presentation-test").unwrap(),
        )
        .unwrap();
    assert!(result.changed);
    let delta = std::iter::from_fn(|| events.try_recv().ok())
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::WorkspaceChanged => {
                Some(delta)
            }
            _ => None,
        })
        .expect("workspace-changed delta");
    assert_eq!(delta.workspace_revision, Some(result.revision));
    assert_eq!(delta.entity["color"], "gray");
    assert_eq!(delta.entity["icon"], "terminal.fill");
    assert_eq!(delta.entity["title"], "Release train");
    assert_eq!(delta.entity["pinned"], true);
    assert_eq!(delta.entity["marked_unread"], true);
    // Absent fields are unchanged; null clears one field.
    mux.set_workspace_metadata(
        None,
        Some(&key),
        WorkspacePresentationUpdate { title: Some(None), ..Default::default() },
        None,
        None,
        &WorkspaceMutation::local("presentation-test"),
    )
    .unwrap();
    for bad in [
        WorkspacePresentationUpdate { icon: Some(Some("Bad Icon".into())), ..Default::default() },
        WorkspacePresentationUpdate { color: Some(Some("#12".into())), ..Default::default() },
        WorkspacePresentationUpdate { title: Some(Some(" ".into())), ..Default::default() },
    ] {
        assert!(
            mux.set_workspace_metadata(
                None,
                Some(&key),
                bad,
                None,
                None,
                &WorkspaceMutation::local("presentation-test"),
            )
            .is_err()
        );
    }
    drop(events);
    drop(mux);

    let mux = session.open();
    let record = mux.presentation_snapshot().workspace(&key).cloned().unwrap();
    assert_eq!(record.color.as_deref(), Some("gray"));
    assert_eq!(record.icon.as_deref(), Some("terminal.fill"));
    assert_eq!(record.title, None);
    assert!(record.pinned);
    assert!(record.marked_unread);
    let replay = mux
        .set_workspace_metadata(
            None,
            Some(&key),
            update,
            None,
            None,
            &WorkspaceMutation::new("meta-1", "presentation-test").unwrap(),
        )
        .unwrap();
    assert!(replay.replayed);
}

fn pane_tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes[&pane].tabs.clone())
}

#[test]
fn cmux_next_pinned_tabs_sort_first_and_survive_restart() {
    let session = PresentationTestSession::new("pins");
    let mux = session.open();
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let third = mux.new_tab(Some(pane), None, None).unwrap().id;
    assert_eq!(pane_tabs(&mux, pane), vec![first, second, third]);

    let pinned = mux.set_tab_pinned(third, true).unwrap();
    assert_eq!(pinned, TabPinChange { changed: true, index: 0 });
    assert_eq!(pane_tabs(&mux, pane), vec![third, first, second]);
    let pinned = mux.set_tab_pinned(second, true).unwrap();
    assert_eq!(pinned.index, 1);
    assert_eq!(pane_tabs(&mux, pane), vec![third, second, first]);
    assert!(!mux.set_tab_pinned(second, true).unwrap().changed);

    // An unpinned tab cannot move ahead of the pinned run, and a pinned
    // tab cannot move behind it.
    let clamped = mux.pinned_tab_move_index(first, pane, 0);
    mux.move_tab(first, pane, clamped);
    assert_eq!(pane_tabs(&mux, pane), vec![third, second, first]);
    let clamped = mux.pinned_tab_move_index(third, pane, 3);
    mux.move_tab(third, pane, clamped);
    assert_eq!(pane_tabs(&mux, pane), vec![second, third, first]);

    let unpinned = mux.set_tab_pinned(second, false).unwrap();
    assert_eq!(unpinned.index, 1);
    assert_eq!(pane_tabs(&mux, pane), vec![third, second, first]);
    let pinned_tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&third].clone());
    // The flag is durable: the registry itself reports it.
    let durable = mux.workspace_registry.lock().unwrap().presentation_snapshot().unwrap();
    assert_eq!(durable.pinned_tabs.len(), 1);
    assert!(durable.pinned_tabs.contains(pinned_tab_id.as_str()));
    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    let tabs = tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"].as_array().unwrap().clone();
    assert_eq!(tabs[0]["pinned"], true);
    assert_eq!(tabs[1]["pinned"], false);
}

#[test]
fn cmux_next_git_head_reads_branches_worktrees_and_detached_heads() {
    let root = std::env::temp_dir()
        .join(format!("cmux-git-head-{}", WorkspacePublicId::random().unwrap()));
    let repo = root.join("repo");
    let nested = repo.join("src").join("deep");
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/feature/tabs\n").unwrap();
    assert_eq!(
        read_git_head(&nested),
        Some(GitHead { name: "feature/tabs".into(), detached: false })
    );

    let worktree = root.join("worktree");
    let worktree_git = root.join("gitdirs").join("worktree");
    std::fs::create_dir_all(&worktree).unwrap();
    std::fs::create_dir_all(&worktree_git).unwrap();
    std::fs::write(worktree.join(".git"), "gitdir: ../gitdirs/worktree\n").unwrap();
    std::fs::write(worktree_git.join("HEAD"), "0123456789abcdef0123456789abcdef01234567\n")
        .unwrap();
    assert_eq!(read_git_head(&worktree), Some(GitHead { name: "0123456".into(), detached: true }));
    assert_eq!(read_git_head(&root.join("gitdirs")), None);

    let mux = Mux::new_for_test("git-heads", SurfaceOptions::default());
    let nested_path = nested.to_string_lossy().into_owned();
    let directories = mux.resolve_tab_directories(vec![(7, nested_path.clone())], true);
    assert_eq!(
        directories[&7],
        TabDirectory {
            cwd: Some(nested_path.clone()),
            git_branch: Some("feature/tabs".into()),
            git_detached: false,
        }
    );
    // Cache-only resolution (used under the state lock) never reads disk.
    let cached = mux.resolve_tab_directories(vec![(8, nested_path)], false);
    assert_eq!(cached[&8].git_branch.as_deref(), Some("feature/tabs"));
    let unknown = mux.resolve_tab_directories(vec![(9, "/nonexistent-cmux".into())], false);
    assert_eq!(unknown[&9].git_branch, None);
    let _ = std::fs::remove_dir_all(&root);
}

fn tab_json(mux: &Mux, surface: SurfaceId) -> Value {
    let decorations = mux.tree_decorations();
    mux.with_state(|state| {
        crate::server::tree_entity_json(state, &decorations, TreeDeltaKind::TabChanged, surface)
    })
    .expect("tab is present in the tree")
}

#[test]
fn cmux_next_frontend_browser_tabs_persist_without_a_cdp_target() {
    let session = PresentationTestSession::new("frontend-browser");
    let mux = session.open();
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = FrontendBrowserRecord {
        engine: "webkit".into(),
        url: "https://example.com/start".into(),
        title: Some("Example".into()),
        favicon_url: None,
        profile_id: Some("default".into()),
        owner: Some("install_mac_a".into()),
    };
    assert!(
        mux.new_frontend_browser_tab(
            Some(pane),
            FrontendBrowserRecord { engine: "gecko".into(), ..record.clone() },
            None,
        )
        .is_err()
    );
    let browser = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap();
    assert_eq!(browser.kind(), SurfaceKind::Browser);
    assert!(mux.is_frontend_browser_surface(&browser));
    assert_eq!(mux.presentation_snapshot().frontend_browsers.len(), 1);
    let tab = tab_json(&mux, browser.id);
    assert_eq!(tab["kind"], "browser");
    assert_eq!(tab["browser_renderer"], "frontend");
    assert_eq!(tab["browser_engine"], "webkit");
    assert_eq!(tab["browser_profile_id"], "default");
    assert_eq!(tab["browser_owner"], "install_mac_a");
    assert_eq!(tab["url"], "https://example.com/start");
    assert_eq!(tab["title"], "Example");
    assert!(tab["browser_status"].is_null());

    let (updated, changed) = mux
        .update_frontend_browser_tab(
            browser.id,
            Some("https://example.com/next".into()),
            Some("Next".into()),
            Some(Some("https://example.com/favicon.ico".into())),
            Some("install_mac_b".into()),
        )
        .unwrap();
    assert!(changed);
    assert_eq!(updated.url, "https://example.com/next");
    assert_eq!(updated.owner.as_deref(), Some("install_mac_b"));
    assert_eq!(tab_json(&mux, browser.id)["browser_owner"], "install_mac_b");
    // An owner must be a valid install id.
    assert!(
        mux.update_frontend_browser_tab(browser.id, None, None, None, Some("bad/owner".into()))
            .is_err()
    );
    let tab = tab_json(&mux, browser.id);
    assert_eq!(tab["url"], "https://example.com/next");
    assert_eq!(tab["title"], "Next");
    assert_eq!(tab["favicon_url"], "https://example.com/favicon.ico");
    // A PTY tab is not a frontend browser.
    assert!(mux.update_frontend_browser_tab(terminal, None, Some("x".into()), None, None).is_err());
    let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&browser.id].clone());
    drop(browser);
    drop(mux);

    let mux = session.open();
    let restored = mux
        .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
        .and_then(|surface| mux.surface(surface))
        .expect("frontend browser tab restored");
    assert!(mux.is_frontend_browser_surface(&restored));
    let tab = tab_json(&mux, restored.id);
    assert_eq!(tab["url"], "https://example.com/next");
    assert_eq!(tab["title"], "Next");
    assert_eq!(tab["browser_renderer"], "frontend");
    assert_eq!(tab["favicon_url"], "https://example.com/favicon.ico");
}

fn durable_unread(mux: &Mux) -> Vec<bool> {
    let projections = mux.workspace_registry.lock().unwrap().public_projections().unwrap();
    projections.notifications.iter().map(|notification| notification.unread).collect()
}

#[test]
fn cmux_next_tab_notification_ack_is_explicit_and_durable() {
    let session = PresentationTestSession::new("notification-ack");
    let mux = session.open();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().expect("terminal tab");
    let surface = surface.id;
    mux.post_notification("build done".into(), "".into(), NotificationLevel::Info, Some(surface))
        .unwrap();
    assert!(mux.terminal_notification(&terminal).is_some_and(|marker| marker.unread));
    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    assert_eq!(tree["workspaces"][0]["unread_count"], 1);
    assert_eq!(durable_unread(&mux), vec![true]);

    let ack = mux.acknowledge_tab_notifications(surface).unwrap();
    assert!(ack.cleared);
    assert_eq!(ack.acknowledged.len(), 1);
    assert!(mux.terminal_notification(&terminal).is_none());
    let rows = mux.notification_rows(10).unwrap();
    assert!(rows.iter().all(|(_, acknowledged)| *acknowledged));
    // The acknowledgement is what a restart restores from.
    assert_eq!(durable_unread(&mux), vec![false]);
    // A second acknowledgement is a no-op, not an error.
    assert!(!mux.acknowledge_tab_notifications(surface).unwrap().cleared);

    // A new notification is unread again until acknowledged; the legacy
    // clear (selecting the tab) persists its acknowledgement too.
    mux.post_notification(
        "tests failed".into(),
        "".into(),
        NotificationLevel::Error,
        Some(surface),
    )
    .unwrap();
    assert_eq!(durable_unread(&mux), vec![false, true]);
    assert!(mux.clear_surface_notification(surface));
    assert_eq!(durable_unread(&mux), vec![false, false]);
}

#[test]
fn cmux_next_workspace_group_move_replays_by_mutation_id() {
    let session = PresentationTestSession::new("group-replay");
    let mux = session.open();
    let a = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.create_empty_workspace(None, None, None).unwrap();
    mux.create_workspace_group(Some("g".into()), "G".into(), None, false, None).unwrap();
    let mutation = WorkspaceMutation::new("group-move-1", "presentation-test").unwrap();
    let first = mux
        .move_workspace_to_group(None, Some(&a), Some("g".into()), None, None, None, &mutation)
        .unwrap();
    assert!(first.changed && !first.replayed);
    let replay = mux
        .move_workspace_to_group(None, Some(&a), Some("g".into()), None, None, None, &mutation)
        .unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.revision, first.revision);
    // The same mutation id with a different payload is refused.
    assert!(
        mux.move_workspace_to_group(None, Some(&a), None, None, None, None, &mutation).is_err()
    );
    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    assert_eq!(tree["groups"][0]["id"], "g");
    assert_eq!(tree["workspaces"][0]["group"], "g");
    assert!(tree["workspaces"][1]["group"].is_null());
}
