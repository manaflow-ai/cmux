use super::*;

#[test]
fn the_tables_keep_their_rows_and_order() {
    let tables = tables();
    assert_eq!(tables.page_commands.len(), 7);
    let remote: Vec<&str> = tables
        .page_commands
        .iter()
        .filter(|row| row.refuses_remote)
        .map(|row| row.action)
        .collect();
    assert_eq!(remote, ["agentPane.editInstructions", "agentPane.addProjectFiles"]);
    assert_eq!(tables.permission_commands[0].command, "permissionAllowOnce");
    assert_eq!(tables.permission_commands.len(), 7);
    assert_eq!(tables.copy_files[1].kinds, ["claude_config", "codex_config"]);
    assert_eq!(
        tables.teams[0].shell_line,
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode in-process\n"
    );
    assert_eq!(tables.teams[1].action, "palette.launchCodexTeams");
    assert_eq!(tables.efforts.first(), Some(&"default"));
    assert_eq!(tables.modes.last(), Some(&"plan"));
}

#[test]
fn zoom_steps_clamp_and_round_the_percent() {
    assert_eq!(zoom(1.0, 0.1, 0.5, 2.0), Zoom { zoom: 1.1, percent: 110 });
    assert_eq!(zoom(1.95, 0.1, 0.5, 2.0), Zoom { zoom: 2.0, percent: 200 });
    assert_eq!(zoom(0.55, -0.1, 0.5, 2.0), Zoom { zoom: 0.5, percent: 50 });
}

#[test]
fn open_file_without_a_path_opens_the_picker_and_refuses_an_unknown_place() {
    assert_eq!(file_place("", Some("nowhere"), false, false), FilePlace::Picker);
    assert_eq!(
        file_place("/a", Some("nowhere"), false, false),
        FilePlace::InvalidPlace { place: "nowhere".to_owned() }
    );
    assert_eq!(
        file_place("/a", None, false, false),
        FilePlace::Open { target: FileTarget::Tab, paneless: false }
    );
}

#[test]
fn the_editor_needs_no_pane_only_when_none_is_named_or_focused() {
    let open = |names, focused| file_place("/a", Some("editor"), names, focused);
    assert_eq!(open(false, false), FilePlace::Open { target: FileTarget::Editor, paneless: true });
    assert_eq!(open(true, false), FilePlace::Open { target: FileTarget::Editor, paneless: false });
    assert_eq!(open(false, true), FilePlace::Open { target: FileTarget::Editor, paneless: false });
}

#[test]
fn a_remote_file_must_be_absolute_and_open_as_a_tab() {
    assert_eq!(file_check("a.txt", FileTarget::Tab, true), Some(FileRefusal::NotAbsolute));
    assert_eq!(file_check("/a\0b", FileTarget::Tab, true), Some(FileRefusal::NotAbsolute));
    assert_eq!(file_check("/a", FileTarget::Editor, true), Some(FileRefusal::RemotePreview));
    assert_eq!(file_check("/a", FileTarget::Tab, true), None);
    assert_eq!(file_check("a", FileTarget::Tab, false), Some(FileRefusal::NotAbsolute));
    assert_eq!(file_check("a", FileTarget::Editor, false), None);
}

#[test]
fn a_new_chat_pane_route() {
    assert_eq!(pane_route(true, true, true, false), PaneRoute::Open);
    assert_eq!(pane_route(true, false, false, true), PaneRoute::Refuse);
    assert_eq!(pane_route(false, true, true, true), PaneRoute::OverTopPage);
    assert_eq!(pane_route(false, true, false, false), PaneRoute::Open);
    assert_eq!(pane_route(false, false, false, true), PaneRoute::FirstPane);
    assert_eq!(pane_route(false, false, false, false), PaneRoute::Refuse);
}

#[test]
fn a_chat_on_a_machine_sets_its_host_and_route() {
    let ready = HostFacts { ready: true, active_local: true, ..HostFacts::default() };
    assert_eq!(
        host_plan(&ready),
        HostPlan { host: Some("local".to_owned()), open: HostOpen::Local }
    );
    let peer = HostFacts { route: HostRoute::Peer { peer: "blue".to_owned() }, ..ready };
    assert_eq!(host_plan(&peer).host.as_deref(), Some("blue"));
    let away = HostFacts { active_local: false, ..peer };
    assert_eq!(host_plan(&away).open, HostOpen::LocalPlacement);
    let remote_target = HostFacts { targeted: true, target_local: false, ..away };
    assert_eq!(host_plan(&remote_target).open, HostOpen::Refuse { reason: HostRefusal::NoMachine });
    let local_target = HostFacts { target_local: true, ..remote_target };
    assert_eq!(host_plan(&local_target).open, HostOpen::Local);
    let cloud = HostFacts {
        route: HostRoute::Cloud { machine: "m".to_owned() },
        active_local: false,
        ..ready
    };
    assert_eq!(
        host_plan(&cloud),
        HostPlan { host: None, open: HostOpen::Cloud { machine: "m".to_owned() } }
    );
    let pending = HostFacts { route: HostRoute::Pending, ..ready };
    assert_eq!(host_plan(&pending), HostPlan { host: None, open: HostOpen::Local });
}

#[test]
fn a_machine_that_is_not_ready_or_a_cancelled_open_is_refused() {
    let cancelled = HostFacts { cancelled: true, ready: true, ..HostFacts::default() };
    assert_eq!(host_plan(&cancelled).open, HostOpen::Refuse { reason: HostRefusal::Cancelled });
    assert_eq!(
        host_plan(&HostFacts::default()).open,
        HostOpen::Refuse { reason: HostRefusal::NotReady }
    );
}

#[test]
fn a_targeted_chat_route() {
    let base = TargetedFacts { applies: true, found: true, ..TargetedFacts::default() };
    assert_eq!(targeted_route(TargetedFacts::default()), TargetedRoute::Skip);
    assert_eq!(targeted_route(TargetedFacts { found: false, ..base }), TargetedRoute::NotFound);
    assert_eq!(targeted_route(base), TargetedRoute::Store { selects: true });
    let shown = TargetedFacts { shown: true, ..base };
    assert_eq!(targeted_route(shown), TargetedRoute::Store { selects: false });
    assert_eq!(
        targeted_route(TargetedFacts { shown_docks_chat: true, ..shown }),
        TargetedRoute::InShown
    );
    let person = TargetedFacts { allows_view_change: true, ..shown };
    assert_eq!(targeted_route(person), TargetedRoute::InShown);
    assert_eq!(targeted_route(TargetedFacts { pane: true, ..person }), TargetedRoute::Skip);
}

fn home() -> Vec<InspectorColumn> {
    vec![
        InspectorColumn { panes: vec![1], dock: true },
        InspectorColumn { panes: vec![2], dock: false },
    ]
}

#[test]
fn in_home_the_inspector_is_a_tab_in_the_right_column() {
    assert_eq!(inspector_placement(1, true, &home()), Some(InspectorPlacement::Tab { pane: 2 }));
    assert_eq!(inspector_placement(2, true, &home()), Some(InspectorPlacement::Tab { pane: 2 }));
    assert_eq!(inspector_placement(1, true, &home()[..1]), None);
    assert_eq!(
        inspector_placement(2, false, &home()),
        Some(InspectorPlacement::NewColumn { pane: 2 })
    );
}

#[test]
fn the_inspector_anchor_avoids_home() {
    let user = AnchorWorkspace { home: false, has_pane: true };
    let home = AnchorWorkspace { home: true, has_pane: true };
    let empty = AnchorWorkspace { home: false, has_pane: false };
    let facts = |pane_in_home, targeted, scope| AnchorFacts {
        targeted,
        pane_in_home,
        scope_workspace: scope,
        workspaces: vec![home, empty, user],
    };
    assert_eq!(inspector_anchor(&facts(Some(false), true, None)), InspectorAnchor::Pane);
    assert_eq!(inspector_anchor(&facts(None, true, Some(user))), InspectorAnchor::Refuse);
    assert_eq!(
        inspector_anchor(&facts(Some(true), true, Some(user))),
        InspectorAnchor::ScopeWorkspace
    );
    assert_eq!(
        inspector_anchor(&facts(None, false, Some(home))),
        InspectorAnchor::Workspace { index: 2 }
    );
    let none = AnchorFacts { workspaces: vec![home], ..AnchorFacts::default() };
    assert_eq!(inspector_anchor(&none), InspectorAnchor::Refuse);
}

#[test]
fn memory_routes_round_trip() {
    assert_eq!(memory_route(None, None), "local");
    assert_eq!(memory_route(Some(""), Some("")), "local");
    assert_eq!(memory_route(None, Some("01J")), "local:01J");
    assert_eq!(memory_route(Some("mini"), Some("01J")), "server:mini");
    assert_eq!(parse_memory_route("local"), Some(ChiefPlace::Local { chief: None }));
    assert_eq!(
        parse_memory_route("local:01J"),
        Some(ChiefPlace::Local { chief: Some("01J".to_owned()) })
    );
    assert_eq!(
        parse_memory_route("server:mini"),
        Some(ChiefPlace::Server { machine_id: "mini".to_owned() })
    );
    for unreadable in ["", "local:", "server:", "cloud:x"] {
        assert_eq!(parse_memory_route(unreadable), None, "{unreadable}");
    }
}

fn harness(name: &str, models: &[(&str, Option<&str>)]) -> HarnessModels {
    HarnessModels {
        harness: name.to_owned(),
        models: models
            .iter()
            .map(|(id, name)| ModelEntry { id: (*id).to_owned(), name: name.map(str::to_owned) })
            .collect(),
    }
}

fn names(catalog: &[HarnessChoices]) -> Vec<&str> {
    catalog.iter().map(|choices| choices.harness.as_str()).collect()
}

#[test]
fn the_model_catalog_lists_each_harness_and_its_short_name() {
    let catalog = model_catalog(&[harness(
        "local/claude",
        &[("opus", Some("Opus")), ("", None), ("opus", None)],
    )]);
    assert_eq!(names(&catalog), ["claude", "local/claude"]);
    assert_eq!(
        catalog[0].models,
        [ModelChoice { value: "opus".to_owned(), title: "opus".to_owned() }]
    );
}

#[test]
fn a_shared_short_name_fails_closed() {
    let catalog = model_catalog(&[
        harness("claude", &[("a", None)]),
        harness("peer/claude", &[("b", None)]),
        harness("codex/", &[("c", None)]),
    ]);
    assert_eq!(names(&catalog), ["codex", "codex/", "peer/claude"]);
}

#[test]
fn an_agent_opened_workspace_placement() {
    assert_eq!(
        session_placement(true, true),
        SessionPlacement { joins_group: true, below_caller: false, default_slot: None }
    );
    assert_eq!(
        session_placement(false, true),
        SessionPlacement {
            joins_group: false,
            below_caller: false,
            default_slot: Some(DefaultSlot::Top)
        }
    );
    assert_eq!(
        session_placement(false, false),
        SessionPlacement {
            joins_group: false,
            below_caller: true,
            default_slot: Some(DefaultSlot::NewWorkspace)
        }
    );
}
