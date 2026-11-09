//! Resource selector resolution: public ids, ancestor scopes, names, and stale or duplicate selectors.

use super::*;

fn selector_fixture()
-> (RestoredResourceState, MachinePublicId, SessionPublicId, ResourceTopologySnapshot) {
    let (snapshot, topology) = resource_restore_fixture();
    let session = snapshot.session_id.clone();
    let restored = restore_resource_state(snapshot, topology.clone()).unwrap();
    (restored, MachinePublicId::random().unwrap(), session, topology)
}

fn routed_selectors(
    machine: &MachinePublicId,
    session: &SessionPublicId,
) -> crate::ResourceSelectors {
    crate::ResourceSelectors {
        machine: Some(machine.to_string()),
        session: Some(session.to_string()),
        ..crate::ResourceSelectors::default()
    }
}

#[test]
fn direct_browser_id_derives_its_complete_path_without_structural_selectors() {
    let (restored, machine, session, topology) = selector_fixture();
    let browser = topology.browsers[0].public_id.clone();
    let tab = topology
        .tabs
        .iter()
        .find(|tab| tab.content_id == ContentPublicId::Browser(browser.clone()))
        .unwrap();
    let pane = topology.panes.iter().find(|pane| pane.public_id == tab.pane_id).unwrap();
    let screen = topology.screens.iter().find(|screen| screen.public_id == pane.screen_id).unwrap();
    let mut selectors = routed_selectors(&machine, &session);
    selectors.browser = Some(browser.to_string());

    let resolved = resolve_resource_selectors(
        &restored.state,
        ResourceSelectorContext {
            machine_id: &machine,
            machine_name: None,
            session_id: &session,
            session_name: "test",
            in_process_host: None,
        },
        crate::ResourceTarget::Browser,
        &selectors,
    )
    .unwrap()
    .path;
    assert_eq!(resolved.workspace, Some(screen.workspace_id.clone()));
    assert_eq!(resolved.screen, Some(screen.public_id.clone()));
    assert_eq!(resolved.pane, Some(pane.public_id.clone()));
    assert_eq!(resolved.tab, Some(tab.public_id.clone()));
    assert_eq!(resolved.browser, Some(browser));
}

#[test]
fn terminal_selector_uses_ancestor_scope_and_rejects_scope_after_last_view_closes() {
    let mux = test_mux();
    let source = mux.new_workspace(Some("source".into()), None).unwrap();
    let destination_anchor = mux.new_workspace(Some("destination".into()), None).unwrap();
    let terminal_id = source.terminal_public_id().cloned().unwrap();
    let (source_workspace, source_pane, destination_workspace, destination_pane) =
        mux.with_state(|state| {
            let source_pane = state.pane_of(source.id).unwrap();
            let destination_pane = state.pane_of(destination_anchor.id).unwrap();
            let source_workspace =
                state.workspaces[state.screen_of(source_pane).unwrap().0].public_id.clone();
            let destination_workspace =
                state.workspaces[state.screen_of(destination_pane).unwrap().0].public_id.clone();
            (source_workspace, source_pane, destination_workspace, destination_pane)
        });
    // Keep both workspaces live after every view of `terminal_id` closes.
    mux.new_tab(Some(source_pane), None, None).unwrap();

    let terminal_selectors = crate::ResourceSelectors {
        terminal: Some(terminal_id.to_string()),
        ..Mux::ordinary_resource_selectors()
    };
    mux.resource_project_terminal_selected(
        terminal_selectors.clone(),
        mux.ordinary_pane_selectors(destination_pane).unwrap(),
        usize::MAX,
        Some("second view".into()),
        None,
        &WorkspaceMutation::daemon_local("selector-multiview"),
    )
    .unwrap();

    for expected_workspace in [&source_workspace, &destination_workspace] {
        let mut scoped = terminal_selectors.clone();
        scoped.workspace = Some(expected_workspace.to_string());
        let path = mux.resolve_resource_path(crate::ResourceTarget::Terminal, &scoped).unwrap();
        assert_eq!(path.workspace.as_ref(), Some(expected_workspace));
        assert_eq!(path.terminal.as_ref(), Some(&terminal_id));
    }

    let placements = mux.with_state(|state| {
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec()
    });
    assert_eq!(placements.len(), 2);
    for placement in placements {
        assert!(mux.close_surface(placement).unwrap());
    }

    let path =
        mux.resolve_resource_path(crate::ResourceTarget::Terminal, &terminal_selectors).unwrap();
    assert_eq!(path.workspace, None);
    assert_eq!(path.tab, None);
    assert_eq!(path.terminal, Some(terminal_id));

    let mut scoped = terminal_selectors;
    scoped.workspace = Some(destination_workspace.to_string());
    let error = mux.resolve_resource_path(crate::ResourceTarget::Terminal, &scoped).unwrap_err();
    assert_eq!(error.code, "selector.wrong_parent");
    assert_eq!(error.details["scope"], "terminal");
    assert_eq!(error.details["actual_parent"], "<none>");
}

#[test]
fn terminal_projection_event_matches_every_changed_public_snapshot() {
    let mux = test_mux();
    let source = mux.new_workspace(Some("source".into()), None).unwrap();
    let destination = mux.new_workspace(Some("destination".into()), None).unwrap();
    let destination_pane = mux.with_state(|state| state.pane_of(destination.id).unwrap());
    mux.new_tab(Some(destination_pane), None, None).unwrap();
    let terminal_id = source.terminal_public_id().cloned().unwrap();
    let destination_selectors = mux.ordinary_pane_selectors(destination_pane).unwrap();
    let destination_pane_id = destination_selectors.pane.clone().unwrap();
    let before = mux.with_state(|state| state.resource_revision);

    mux.resource_project_terminal_selected(
        crate::ResourceSelectors {
            terminal: Some(terminal_id.to_string()),
            ..Mux::ordinary_resource_selectors()
        },
        destination_selectors,
        0,
        Some("projected".into()),
        None,
        &WorkspaceMutation::daemon_local("projection-complete-delta"),
    )
    .unwrap();

    let batches = mux.resource_events_after(before).unwrap().batches;
    assert_eq!(batches.len(), 1);
    let changes = batches[0].changes.as_array().unwrap();
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == terminal_id.as_str())
        .unwrap();
    let terminal_delta = changes
        .iter()
        .find(|change| change["resource"] == "terminal" && change["id"] == terminal_id.as_str())
        .expect("projection changes the terminal's placement list");
    assert_eq!(&terminal_delta["value"], terminal);

    let destination_tabs = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|tab| tab["pane_id"] == destination_pane_id)
        .collect::<Vec<_>>();
    assert_eq!(destination_tabs.len(), 3);
    for tab in destination_tabs {
        let tab_id = tab["id"].as_str().unwrap();
        let delta = changes
            .iter()
            .find(|change| change["resource"] == "tab" && change["id"] == tab_id)
            .unwrap_or_else(|| panic!("projection omitted changed tab {tab_id}"));
        assert_eq!(&delta["value"], tab);
    }
}

#[test]
fn selector_names_preserve_empty_whitespace_and_unicode_and_report_duplicates() {
    let (mut restored, machine, session, _) = selector_fixture();
    let before = restored.state.resource_revision;
    let mut selectors = routed_selectors(&machine, &session);
    selectors.workspace = Some("Duplicate".into());
    let duplicate = resolve_resource_selectors(
        &restored.state,
        ResourceSelectorContext {
            machine_id: &machine,
            machine_name: None,
            session_id: &session,
            session_name: "test",
            in_process_host: None,
        },
        crate::ResourceTarget::Workspace,
        &selectors,
    )
    .unwrap_err();
    assert_eq!(duplicate.code, "selector.ambiguous");
    assert_eq!(
        duplicate.details["candidates"],
        serde_json::json!([restore_workspace_id(1), restore_workspace_id(2)])
    );
    assert_eq!(restored.state.resource_revision, before);

    for (index, name) in ["", "  日本語  "].into_iter().enumerate() {
        restored.state.workspaces[index].name = name.into();
        selectors.workspace = Some(format!("name:{name}"));
        let resolved = resolve_resource_selectors(
            &restored.state,
            ResourceSelectorContext {
                machine_id: &machine,
                machine_name: None,
                session_id: &session,
                session_name: "test",
                in_process_host: None,
            },
            crate::ResourceTarget::Workspace,
            &selectors,
        )
        .unwrap();
        assert_eq!(
            resolved.path.workspace,
            Some(restored.state.workspaces[index].public_id.clone())
        );
    }
}

#[test]
fn selector_rejects_incomplete_name_chain_wrong_type_stale_id_and_wrong_parent() {
    let (restored, machine, session, topology) = selector_fixture();
    let context = ResourceSelectorContext {
        machine_id: &machine,
        machine_name: None,
        session_id: &session,
        session_name: "test",
        in_process_host: None,
    };

    let mut incomplete = routed_selectors(&machine, &session);
    incomplete.screen = Some(topology.screens[0].public_id.to_string());
    incomplete.pane = Some("one".into());
    let error = resolve_resource_selectors(
        &restored.state,
        context.clone(),
        crate::ResourceTarget::Pane,
        &incomplete,
    )
    .unwrap_err();
    assert_eq!(error.code, "selector.invalid");
    assert_eq!(error.details["scope"], "pane");
    assert!(error.details["reason"].as_str().is_some_and(|reason| reason.contains("workspace")));

    let mut wrong_type = routed_selectors(&machine, &session);
    wrong_type.workspace = Some(topology.browsers[0].public_id.to_string());
    assert_eq!(
        resolve_resource_selectors(
            &restored.state,
            context.clone(),
            crate::ResourceTarget::Workspace,
            &wrong_type,
        )
        .unwrap_err()
        .code,
        "selector.invalid"
    );

    let mut stale = routed_selectors(&machine, &session);
    stale.workspace = Some(WorkspacePublicId::random().unwrap().to_string());
    assert_eq!(
        resolve_resource_selectors(
            &restored.state,
            context.clone(),
            crate::ResourceTarget::Workspace,
            &stale,
        )
        .unwrap_err()
        .code,
        "selector.not_found"
    );

    let mut wrong_parent = routed_selectors(&machine, &session);
    wrong_parent.workspace = Some(restore_workspace_id(2).to_string());
    wrong_parent.browser = Some(topology.browsers[0].public_id.to_string());
    let error = resolve_resource_selectors(
        &restored.state,
        context,
        crate::ResourceTarget::Browser,
        &wrong_parent,
    )
    .unwrap_err();
    assert_eq!(error.code, "selector.wrong_parent");
    assert!(error.details["expected_parent"].as_str().unwrap().starts_with("ws_"));
    assert!(error.details["actual_parent"].as_str().unwrap().starts_with("ws_"));
    let encoded = serde_json::to_string(&error).unwrap();
    for private in ["workspace_key", "surface", "numeric_id", "short_id", "\"slot\""] {
        assert!(!encoded.contains(private));
    }
}

#[test]
fn selector_rename_and_concurrent_rename_share_one_locked_snapshot() {
    let mux = test_mux();
    let first = mux
        .resource_create_empty_workspace(
            Some("target".into()),
            None,
            Some(0),
            &WorkspaceMutation::daemon("selector-race-first", "test").unwrap(),
        )
        .unwrap();
    let second = mux
        .resource_create_empty_workspace(
            Some("other".into()),
            None,
            Some(1),
            &WorkspaceMutation::daemon("selector-race-second", "test").unwrap(),
        )
        .unwrap();
    let first_id = WorkspacePublicId::parse(first.result["workspace"].as_str().unwrap()).unwrap();
    let second_id = WorkspacePublicId::parse(second.result["workspace"].as_str().unwrap()).unwrap();
    let (machine, session) = {
        let registry = mux.workspace_registry.lock().unwrap();
        (registry.machine_id().clone(), registry.session_id().clone())
    };
    let mut selectors = routed_selectors(&machine, &session);
    selectors.workspace = Some("target".into());

    let (resolved_tx, resolved_rx) = std::sync::mpsc::sync_channel(1);
    let overlap = Arc::new(std::sync::Barrier::new(2));
    *mux.resource_rename_after_selector_resolution.lock().unwrap() = Some(Arc::new({
        let overlap = overlap.clone();
        move |resolved| {
            resolved_tx.send(resolved.clone()).unwrap();
            overlap.wait();
        }
    }));
    let selected = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.resource_rename_workspace_selected(
                selectors,
                Some("renamed".into()),
                crate::resource_name::WorkspaceNameUpdate::user(),
                None,
                Some(2),
                &WorkspaceMutation::daemon("selector-race-selected", "test").unwrap(),
            )
        })
    };
    assert_eq!(resolved_rx.recv().unwrap(), first_id);
    let concurrent = {
        let mux = mux.clone();
        let second_id = second_id.clone();
        std::thread::spawn(move || {
            overlap.wait();
            mux.resource_rename_workspace(
                &second_id,
                "target".into(),
                None,
                None,
                &WorkspaceMutation::daemon("selector-race-direct", "test").unwrap(),
            )
        })
    };
    selected.join().unwrap().unwrap();
    concurrent.join().unwrap().unwrap();
    *mux.resource_rename_after_selector_resolution.lock().unwrap() = None;

    mux.with_state(|state| {
        let first = state.resource_indexes.workspaces[&first_id];
        let second = state.resource_indexes.workspaces[&second_id];
        assert_eq!(state.workspaces[state.workspace_index(first).unwrap()].name, "renamed");
        assert_eq!(state.workspaces[state.workspace_index(second).unwrap()].name, "target");
    });
}

/// W3-H (bench round 3): `cmux tab alpha show` sends `current` workspace,
/// screen and pane selectors above the name, so a tab named in another pane
/// (an agent's split) was not found. A name the current pane lacks is now
/// looked up in the current screen, then wider; a name the current pane has
/// still resolves there, and two matches outside it are ambiguous.
#[test]
fn w3h_a_tab_name_outside_the_current_pane_resolves_under_current_selectors() {
    let mux = test_mux();
    let root = mux.new_workspace(Some("w3h".into()), None).unwrap();
    let root_pane = mux.with_state(|state| state.pane_of(root.id).unwrap());
    let agent = mux.split(root_pane, SplitDir::Right, None).unwrap();
    let agent_pane = mux.with_state(|state| state.pane_of(agent.id).unwrap());
    assert!(mux.rename_surface(agent.id, "alpha".into()));
    assert!(mux.focus_pane(root_pane));
    let tab_id = |surface: SurfaceId| {
        mux.with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())
    };
    let pane_id =
        |pane: PaneId| mux.with_state(|state| state.resource_indexes.pane_ids.get(&pane).cloned());
    let selectors = crate::ResourceSelectors {
        workspace: Some("current".into()),
        screen: Some("current".into()),
        pane: Some("current".into()),
        tab: Some("alpha".into()),
        ..Mux::ordinary_resource_selectors()
    };
    let path = mux.resolve_resource_path(crate::ResourceTarget::Tab, &selectors).unwrap();
    assert_eq!(path.tab, tab_id(agent.id));
    assert_eq!(path.pane, pane_id(agent_pane));
    let prefixed = crate::ResourceSelectors { tab: Some("name:alpha".into()), ..selectors.clone() };
    let path = mux.resolve_resource_path(crate::ResourceTarget::Tab, &prefixed).unwrap();
    assert_eq!(path.tab, tab_id(agent.id));

    // A name the current pane has resolves there, as before.
    assert!(mux.rename_surface(root.id, "alpha".into()));
    let path = mux.resolve_resource_path(crate::ResourceTarget::Tab, &selectors).unwrap();
    assert_eq!(path.tab, tab_id(root.id));

    // Two tabs with the name outside the current pane are ambiguous.
    assert!(mux.rename_surface(root.id, "root".into()));
    let other = mux.split(agent_pane, SplitDir::Down, None).unwrap();
    assert!(mux.rename_surface(other.id, "alpha".into()));
    assert!(mux.focus_pane(root_pane));
    let error = mux.resolve_resource_path(crate::ResourceTarget::Tab, &selectors).unwrap_err();
    assert_eq!(error.code, "selector.ambiguous");

    // An explicit pane still scopes the name to that pane.
    let pinned = crate::ResourceSelectors {
        pane: pane_id(root_pane).map(|pane| pane.to_string()),
        ..selectors
    };
    let error = mux.resolve_resource_path(crate::ResourceTarget::Tab, &pinned).unwrap_err();
    assert_eq!(error.code, "selector.not_found");
}

/// Selectors as the CLI sends `<scope> <value>`: `current` parents above a
/// value that is not an id (cli/command.rs `Selectors::insert`).
fn w5p_cli_selectors(scope: &str, value: &str) -> crate::ResourceSelectors {
    let mut selectors = Mux::ordinary_resource_selectors();
    let is_id = matches!(Selector::parse(value), Ok(Selector::Id(_)));
    let current = || (!is_id).then(|| "current".to_string());
    let value = Some(value.to_string());
    match scope {
        "pane" => {
            (selectors.workspace, selectors.screen, selectors.pane) = (current(), current(), value);
        }
        "tab" => {
            (selectors.workspace, selectors.screen, selectors.pane) =
                (current(), current(), current());
            selectors.tab = value;
        }
        _ => {
            (selectors.workspace, selectors.screen, selectors.pane) =
                (current(), current(), current());
            (selectors.tab, selectors.terminal) = (current(), value);
        }
    }
    selectors
}

/// The (pane, tab, terminal) ids a selector resolves to.
type W5pPlace = (Option<String>, Option<String>, Option<String>);

/// The resolved (pane, tab, terminal) of a CLI-shaped selector.
fn w5p_resolve(mux: &Arc<Mux>, scope: &str, value: &str) -> Result<W5pPlace, ResourceError> {
    let target = match scope {
        "pane" => crate::ResourceTarget::Pane,
        "tab" => crate::ResourceTarget::Tab,
        _ => crate::ResourceTarget::Terminal,
    };
    let path = mux.resolve_resource_path(target, &w5p_cli_selectors(scope, value))?;
    Ok((
        path.pane.map(|id| id.to_string()),
        path.tab.map(|id| id.to_string()),
        path.terminal.map(|id| id.to_string()),
    ))
}

/// W5-P: the daemon is the one selector resolver, so one selector selects
/// one object in every command and every client. A tab name (an agent's
/// name) outside the current pane selects that tab, its terminal and its
/// pane under the CLI's `current` parents; a bare id (the 32 hex digits), a
/// unique id prefix, a terminal's host id (the raw protocol's
/// `terminal_id`) and a tab or pane id as a terminal selector select what
/// the full id selects; `focused` is `current`.
#[test]
fn w5p_one_selector_selects_the_same_object_in_every_scope() {
    let mux = test_mux();
    let root = mux.new_workspace(Some("w5p".into()), None).unwrap();
    let root_pane = mux.with_state(|state| state.pane_of(root.id).unwrap());
    let agent = mux.split(root_pane, SplitDir::Right, None).unwrap();
    let agent_pane = mux.with_state(|state| state.pane_of(agent.id).unwrap());
    assert!(mux.rename_surface(agent.id, "alpha".into()));
    assert!(mux.focus_pane(root_pane));
    let (pane, tab, terminal) = mux.with_state(|state| {
        let indexes = &state.resource_indexes;
        let Some(ContentPublicId::Terminal(terminal)) = indexes.content_ids.get(&agent.id) else {
            panic!("alpha shows no terminal");
        };
        (
            indexes.pane_ids.get(&agent_pane).unwrap().to_string(),
            indexes.tab_ids.get(&agent.id).unwrap().to_string(),
            terminal.to_string(),
        )
    });
    let alpha = (Some(pane.clone()), Some(tab.clone()), Some(terminal.clone()));

    // The name: the same tab, terminal and pane from every scope.
    // A tab target resolves no terminal: its (pane, tab) are alpha's.
    let pane_tab = |place: W5pPlace| (place.0, place.1);
    assert_eq!(w5p_resolve(&mux, "terminal", "alpha").unwrap(), alpha, "terminal alpha");
    assert_eq!(
        pane_tab(w5p_resolve(&mux, "tab", "alpha").unwrap()),
        pane_tab(alpha.clone()),
        "tab alpha"
    );
    assert_eq!(w5p_resolve(&mux, "pane", "alpha").unwrap().0, Some(pane.clone()));

    // Every id form of each object selects it.
    let payload = |id: &str| id.rsplit_once('_').unwrap().1.to_owned();
    for (scope, id) in [("pane", &pane), ("tab", &tab), ("terminal", &terminal)] {
        let prefix = &id[..id.len() - 20];
        for form in [id.clone(), payload(id), prefix.to_owned()] {
            let resolved = w5p_resolve(&mux, scope, &form)
                .unwrap_or_else(|error| panic!("{scope} {form}: {error:?}"));
            match scope {
                "pane" => assert_eq!(resolved.0, Some(pane.clone()), "{scope} {form}"),
                "tab" => assert_eq!(pane_tab(resolved), pane_tab(alpha.clone()), "{scope} {form}"),
                _ => assert_eq!(resolved, alpha, "{scope} {form}"),
            }
        }
    }
    // A terminal selector takes the terminal's host id, and a tab or pane id.
    let host = mux
        .with_state(|state| {
            state
                .surfaces
                .get(&agent.id)
                .and_then(|surface| mux.resource_terminal_host_identity(surface))
        })
        .map(|identity| identity.terminal_id)
        .expect("alpha's terminal has a host id");
    for form in [host, tab, pane.clone()] {
        let resolved = w5p_resolve(&mux, "terminal", &form)
            .unwrap_or_else(|error| panic!("terminal {form}: {error:?}"));
        assert_eq!(resolved, alpha, "terminal {form}");
    }

    // `focused` is `current`: the root pane has the focus.
    let focused = w5p_resolve(&mux, "pane", "focused").unwrap().0;
    let current = w5p_resolve(&mux, "pane", "current").unwrap().0;
    assert_eq!(focused, current);
    assert_ne!(focused, Some(pane));
}

/// W5-P adds `focused`, bare ids and id prefixes as selectors without
/// changing an old answer: a name that looks like one of them still
/// selects the named object, and the new form applies only when no object
/// has that name. A prefix was never a name (the old parser refused it and
/// asked for `name:`), so `name:<prefix>` is the name and the bare prefix
/// is the id.
#[test]
fn w5p_names_keep_their_old_answers_over_the_id_forms_they_look_like() {
    let mux = test_mux();
    let root = mux.new_workspace(Some("w5p-collide".into()), None).unwrap();
    let root_pane = mux.with_state(|state| state.pane_of(root.id).unwrap());
    let named = mux.split(root_pane, SplitDir::Right, None).unwrap();
    assert!(mux.focus_pane(root_pane));
    let tab_id = |surface| {
        mux.with_state(|state| state.resource_indexes.tab_ids.get(&surface).unwrap().to_string())
    };
    let (root_tab, named_tab) = (tab_id(root.id), tab_id(named.id));
    let tab_of = |selector: &str| {
        w5p_resolve(&mux, "tab", selector).unwrap_or_else(|error| panic!("{selector}: {error:?}")).1
    };

    // No tab is named `focused`: it is the focused tab.
    assert_eq!(tab_of("focused"), Some(root_tab.clone()));
    // A tab named `focused` (not the focused one) is what `tab focused` selected.
    assert!(mux.rename_surface(named.id, "focused".into()));
    assert_eq!(tab_of("focused"), Some(named_tab.clone()), "the name wins over focus");

    // A tab named with the 32 hex digits of another tab's id is the name.
    let root_payload = root_tab.rsplit_once('_').unwrap().1.to_owned();
    assert!(mux.rename_surface(named.id, root_payload.clone()));
    assert_eq!(tab_of(&root_payload), Some(named_tab.clone()), "the name wins over the bare id");
    // With no such name, the 32 hex digits are the id.
    assert!(mux.rename_surface(named.id, "plain".into()));
    assert_eq!(tab_of(&root_payload), Some(root_tab.clone()), "the bare id");

    // A tab named with a prefix of another tab's id: `name:` selects it, as
    // before; the prefix alone (refused before) is the id.
    let prefix = root_tab.get(..root_tab.len() - 20).unwrap().to_owned();
    assert!(mux.rename_surface(named.id, prefix.clone()));
    assert_eq!(tab_of(&format!("name:{prefix}")), Some(named_tab));
    assert_eq!(tab_of(&prefix), Some(root_tab));
}

/// W5-P keeps every old answer for a name two tabs share. A tab name
/// (the daemon's old tab-name levels) selects the tab in the current
/// screen before one elsewhere, and two at one level are
/// `selector.ambiguous`; a terminal or pane selector (the CLI's old W3-H
/// rule over the whole session) is ambiguous with both tab ids. An id
/// prefix that two objects share is ambiguous with every candidate, never
/// a guess.
#[test]
fn w5p_shared_names_and_shared_prefixes_keep_their_old_answers() {
    let mux = test_mux();
    let root = mux.new_workspace(Some("w5p-ambiguous".into()), None).unwrap();
    let root_pane = mux.with_state(|state| state.pane_of(root.id).unwrap());
    let left = mux.split(root_pane, SplitDir::Right, None).unwrap();
    let other = mux.new_workspace(Some("w5p-other".into()), None).unwrap();
    let other_pane = mux.with_state(|state| state.pane_of(other.id).unwrap());
    let other_split = mux.split(other_pane, SplitDir::Right, None).unwrap();
    assert!(mux.rename_surface(left.id, "dup".into()));
    assert!(mux.rename_surface(other.id, "dup".into()));
    assert!(mux.rename_surface(other_split.id, "twin".into()));
    let twin_peer = mux.new_tab(Some(other_pane), None, None).unwrap();
    assert!(mux.rename_surface(twin_peer.id, "twin".into()));
    assert!(mux.focus_pane(root_pane));
    let tab_id = |surface| {
        mux.with_state(|state| state.resource_indexes.tab_ids.get(&surface).unwrap().to_string())
    };

    // The same name in two screens: the tab in the current screen.
    let (_, tab, _) = w5p_resolve(&mux, "tab", "dup").unwrap();
    assert_eq!(tab, Some(tab_id(left.id)), "tab dup is the one in the current screen");
    for scope in ["terminal", "pane"] {
        let error = w5p_resolve(&mux, scope, "dup").unwrap_err();
        assert_eq!(error.code, "selector.ambiguous", "{scope} dup: {error:?}");
        let candidates = error.details["candidates"].as_array().map(Vec::len);
        assert_eq!(candidates, Some(2), "{scope} dup: {error:?}");
    }
    // Two at one level (both in another workspace) are ambiguous everywhere.
    for scope in ["terminal", "tab", "pane"] {
        let error = w5p_resolve(&mux, scope, "twin").unwrap_err();
        assert_eq!(error.code, "selector.ambiguous", "{scope} twin: {error:?}");
        let candidates = error.details["candidates"].as_array().map(Vec::len);
        assert_eq!(candidates, Some(2), "{scope} twin: {error:?}");
    }

    // 17 tabs: two of them share the first hex digit of their id.
    for _ in 0..15 {
        mux.new_tab(Some(root_pane), None, None).unwrap();
    }
    let tabs = mux.with_state(|state| {
        state.resource_indexes.tabs.keys().map(ToString::to_string).collect::<Vec<_>>()
    });
    assert!(tabs.len() >= 17, "{tabs:?}");
    let shared = tabs
        .iter()
        .map(|id| id.get(..5).unwrap().to_owned())
        .find(|prefix| tabs.iter().filter(|id| id.starts_with(prefix.as_str())).count() > 1)
        .expect("two of 17 tabs share the first digit");
    let error = w5p_resolve(&mux, "tab", &shared).unwrap_err();
    assert_eq!(error.code, "selector.ambiguous", "{shared}: {error:?}");
    let mut candidates = error.details["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| id.as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    candidates.sort();
    let mut expected =
        tabs.iter().filter(|id| id.starts_with(shared.as_str())).cloned().collect::<Vec<_>>();
    expected.sort();
    assert_eq!(candidates, expected);
    // A prefix of no object is not found (32 prefixes, 20 tabs).
    let missing = (0..16u8)
        .flat_map(|first| (0..2u8).map(move |second| format!("tab_{first:x}{second:x}0")))
        .find(|prefix| !tabs.iter().any(|id| id.starts_with(prefix.as_str())))
        .expect("a three-digit prefix no tab has");
    let error = w5p_resolve(&mux, "tab", &missing).unwrap_err();
    assert_eq!(error.code, "selector.not_found", "{missing}: {error:?}");
    assert!(error.message.contains("32 hex digits"), "{}", error.message);
    assert!(error.message.contains("cmux tab list"), "{}", error.message);
}
