use super::*;

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

fn dropped(pinned: bool, daemon: Option<u64>) -> Dropped {
    Dropped { pinned, daemon }
}

#[test]
fn a_drop_on_pinned_pins_the_unpinned_and_unknown_workspaces() {
    let workspaces = [dropped(true, Some(1)), dropped(false, Some(1)), dropped(false, None)];
    assert_eq!(
        reorder_pins(DropSection::Pinned, &workspaces),
        ReorderPins::Pin { workspaces: vec![1, 2] }
    );
    assert_eq!(
        reorder_pins(DropSection::Custom, &workspaces),
        ReorderPins::Pin { workspaces: vec![1, 2] }
    );
}

#[test]
fn a_drop_on_pinned_of_pinned_workspaces_only_snaps_back() {
    let workspaces = [dropped(true, Some(1)), dropped(true, Some(2))];
    assert_eq!(reorder_pins(DropSection::Pinned, &workspaces), ReorderPins::SnapBack);
    assert_eq!(reorder_pins(DropSection::Custom, &workspaces), ReorderPins::SnapBack);
}

#[test]
fn a_pinned_workspace_dropped_on_its_own_machine_unpins_and_others_keep_their_pin() {
    let workspaces = [
        dropped(true, Some(1)),
        dropped(true, Some(2)),
        dropped(false, Some(1)),
        dropped(true, None),
    ];
    assert_eq!(
        reorder_pins(DropSection::Machine { daemon: Some(1) }, &workspaces),
        ReorderPins::Reorder { unpin: vec![0] }
    );
    // A machine the app has no daemon for unpins nothing (no daemon is that machine's).
    assert_eq!(
        reorder_pins(DropSection::Machine { daemon: None }, &workspaces),
        ReorderPins::Reorder { unpin: vec![] }
    );
}

#[test]
fn pins_go_only_to_daemons_with_the_pin_capability() {
    assert_eq!(
        pin_commands(&[true, false, true]),
        PinCommands { send: vec![0, 2], refused: true, snap_back: false }
    );
    assert_eq!(
        pin_commands(&[true]),
        PinCommands { send: vec![0], refused: false, snap_back: false }
    );
    assert_eq!(
        pin_commands(&[false]),
        PinCommands { send: vec![], refused: true, snap_back: true }
    );
    // No known owner: nothing to send, nothing refused.
    assert_eq!(pin_commands(&[]), PinCommands { send: vec![], refused: false, snap_back: true });
}

#[test]
fn same_daemon_is_the_one_owner_of_every_known_workspace() {
    assert_eq!(same_daemon(&[Some(3), None, Some(3)]), Some(3));
    assert_eq!(same_daemon(&[Some(3), Some(4)]), None);
    assert_eq!(same_daemon(&[None, None]), None);
    assert_eq!(same_daemon(&[]), None);
}

#[test]
fn a_plain_plus_in_a_local_window_is_new_tab() {
    assert_eq!(new_workspace(None, false, true, true), NewWorkspace::NewTab);
    assert_eq!(new_workspace(None, false, true, false), NewWorkspace::NewTab);
}

#[test]
fn a_new_workspace_goes_to_the_named_machine_else_the_windows() {
    assert_eq!(
        new_workspace(Some(true), false, true, true),
        NewWorkspace::Create { on: NewWorkspaceDaemon::Machine }
    );
    // A machine named but not found falls back to the window's daemon.
    assert_eq!(
        new_workspace(Some(false), false, false, true),
        NewWorkspace::Create { on: NewWorkspaceDaemon::Window }
    );
    // A group in a local window: the window's machine.
    assert_eq!(
        new_workspace(None, true, true, true),
        NewWorkspace::Create { on: NewWorkspaceDaemon::Window }
    );
    // A group in a local window with no daemon: the app's default.
    assert_eq!(
        new_workspace(None, true, true, false),
        NewWorkspace::Create { on: NewWorkspaceDaemon::Default }
    );
}

#[test]
fn a_machine_turned_off_gets_nothing_not_a_local_stand_in() {
    assert_eq!(new_workspace(Some(false), false, true, false), NewWorkspace::Nothing);
    assert_eq!(new_workspace(None, false, false, false), NewWorkspace::Nothing);
    assert_eq!(new_workspace(None, true, false, false), NewWorkspace::Nothing);
}

#[test]
fn new_group_never_stacks_a_second_group_on_a_whole_group() {
    assert_eq!(new_group(true, true, true, true), NewGroup { edit_whole: true, edit_new: false });
    // Not whole: a new group, whose editor opens.
    assert_eq!(new_group(true, true, true, false), NewGroup { edit_whole: false, edit_new: true });
    // Without personal organization there is no whole group to reuse.
    assert_eq!(new_group(true, true, false, true), NewGroup { edit_whole: false, edit_new: true });
}

#[test]
fn automation_and_a_named_group_get_the_group_they_asked_for() {
    assert_eq!(new_group(false, true, true, true), NewGroup { edit_whole: false, edit_new: false });
    assert_eq!(new_group(true, false, true, true), NewGroup { edit_whole: false, edit_new: false });
}

#[test]
fn a_group_forms_where_the_sidebar_placed_it_else_where_asked() {
    assert_eq!(group_create_index(Some(2), Some(5)), Some(2));
    assert_eq!(group_create_index(None, Some(5)), Some(5));
    assert_eq!(group_create_index(None, Some(i64::MAX)), None);
    assert_eq!(group_create_index(Some(1), Some(i64::MAX)), Some(1));
    assert_eq!(group_create_index(None, None), None);
}

#[test]
fn editor_rows_that_keep_a_group_made_empty() {
    for item in [
        "workspaceGroup.newWorkspace",
        "workspaceGroup.setIcon",
        "workspaceGroup.delete",
        "workspaceGroup.ungroup",
        "workspaceGroup.closeWorkspaces",
    ] {
        assert_eq!(editor_item(item), EditorItem { keeps_group: true, performs: true }, "{item}");
    }
    for item in [MORE_ACTIONS_ITEM, KEEP_GROUP_ITEM] {
        assert_eq!(editor_item(item), EditorItem { keeps_group: true, performs: false }, "{item}");
    }
    assert_eq!(
        editor_item("workspaceGroup.setColor"),
        EditorItem { keeps_group: false, performs: true }
    );
}

#[test]
fn placement_moves_join_the_group_or_go_loose_and_the_rest_keep_theirs() {
    let steps = [PlanStep { moves: false, index: 0 }, PlanStep { moves: true, index: 3 }];
    let into = placement_commands(&steps, Some("g1"), true, &ids(&["g2"]), Some(4));
    assert_eq!(into.moving, vec![1]);
    assert_eq!(
        into.places,
        vec![
            Place { step: 0, group: GroupUpdate::Unchanged, index: 0 },
            Place { step: 1, group: GroupUpdate::Set { id: "g1".into() }, index: 3 },
        ]
    );
    assert_eq!(into.regroups, vec![Regroup { group: "g2".into(), top_index: 4 }]);
    let loose = placement_commands(&steps, None, true, &[], None);
    assert_eq!(loose.places.get(1).map(|place| &place.group), Some(&GroupUpdate::Clear));
}

#[test]
fn regroups_need_v2_personal_state_and_a_first_slot() {
    let steps = [PlanStep { moves: true, index: 0 }];
    assert!(placement_commands(&steps, None, false, &ids(&["g"]), Some(0)).regroups.is_empty());
    assert!(placement_commands(&steps, None, true, &ids(&["g"]), None).regroups.is_empty());
}

#[test]
fn machine_status_follows_the_connection_and_liveness() {
    use Connection::*;
    for (connection, live, status) in [
        (Connected, true, MachineStatus::Connected),
        (Connected, false, MachineStatus::Connected),
        (Connecting, true, MachineStatus::Connecting),
        (Disconnected, true, MachineStatus::Connecting),
        (Failed, true, MachineStatus::Connecting),
        (Connecting, false, MachineStatus::Offline),
        (Disconnected, false, MachineStatus::Offline),
        (Failed, false, MachineStatus::Offline),
    ] {
        assert_eq!(
            machine_status(MachineKind::Cloud, connection, live, None, false),
            Header { status, compatibility_detail: false },
            "{connection:?} live {live}"
        );
    }
}

#[test]
fn a_remote_daemon_too_old_says_update() {
    let required = machine_status(
        MachineKind::Ssh,
        Connection::Failed,
        true,
        Some(Compatibility::Incompatible),
        true,
    );
    assert_eq!(
        required,
        Header { status: MachineStatus::UpdateRequired, compatibility_detail: true }
    );
    // Incompatible but still starting: connecting.
    let starting = machine_status(
        MachineKind::Ssh,
        Connection::Connecting,
        true,
        Some(Compatibility::Incompatible),
        false,
    );
    assert_eq!(starting.status, MachineStatus::Connecting);
    let limited = machine_status(
        MachineKind::Server,
        Connection::Connected,
        true,
        Some(Compatibility::Limited),
        false,
    );
    assert_eq!(
        limited,
        Header { status: MachineStatus::UpdateAvailable, compatibility_detail: true }
    );
    // Limited while connecting stays connecting.
    let limited_connecting = machine_status(
        MachineKind::Cloud,
        Connection::Connecting,
        true,
        Some(Compatibility::Limited),
        false,
    );
    assert_eq!(limited_connecting.status, MachineStatus::Connecting);
    // Not live: no update status.
    let offline = machine_status(
        MachineKind::Cloud,
        Connection::Failed,
        false,
        Some(Compatibility::Incompatible),
        true,
    );
    assert_eq!(offline, Header { status: MachineStatus::Offline, compatibility_detail: false });
}

#[test]
fn this_macs_daemon_has_no_update_status() {
    let local = machine_status(
        MachineKind::Local,
        Connection::Connected,
        true,
        Some(Compatibility::Limited),
        false,
    );
    assert_eq!(local, Header { status: MachineStatus::Connected, compatibility_detail: false });
}

#[test]
fn an_ssh_machine_offered_an_update_says_update_available_only_when_connected() {
    assert_eq!(
        ssh_status(MachineStatus::Connected, true, true),
        Header { status: MachineStatus::UpdateAvailable, compatibility_detail: true }
    );
    assert_eq!(
        ssh_status(MachineStatus::Connected, true, false),
        Header { status: MachineStatus::UpdateAvailable, compatibility_detail: false }
    );
    assert_eq!(
        ssh_status(MachineStatus::Installing, true, true),
        Header { status: MachineStatus::Installing, compatibility_detail: false }
    );
    assert_eq!(
        ssh_status(MachineStatus::UpdateRequired, false, true),
        Header { status: MachineStatus::UpdateRequired, compatibility_detail: true }
    );
}

#[test]
fn only_a_dropped_link_reconnects_on_use() {
    assert_eq!(pane_use(false, Some(LinkState::Connected), false), PaneUse::Up);
    assert_eq!(pane_use(false, Some(LinkState::Connecting), false), PaneUse::Coming);
    for link in [LinkState::Offline, LinkState::Paused, LinkState::Attention] {
        assert_eq!(pane_use(false, Some(link), true), PaneUse::Down);
        assert_eq!(pane_use(false, Some(link), false), PaneUse::Stuck);
    }
    assert_eq!(pane_use(false, None, true), PaneUse::Stuck);
    // An SSH session waiting on its person is never reconnected under it.
    assert_eq!(pane_use(true, Some(LinkState::Connected), true), PaneUse::Stuck);
}

#[test]
fn a_machines_row_link_is_connected_first_then_what_its_server_says() {
    assert_eq!(row_link(true, false, None), LinkState::Connected);
    assert_eq!(row_link(true, false, Some(ServerState::Paused)), LinkState::Connected);
    assert_eq!(row_link(false, true, None), LinkState::Connecting);
    assert_eq!(row_link(false, false, Some(ServerState::Resuming)), LinkState::Connecting);
    assert_eq!(row_link(false, true, Some(ServerState::Paused)), LinkState::Paused);
    assert_eq!(row_link(false, false, Some(ServerState::Failed)), LinkState::Offline);
    assert_eq!(row_link(false, false, Some(ServerState::Deleted)), LinkState::Offline);
    assert_eq!(row_link(false, false, None), LinkState::Offline);
}

#[test]
fn notice_buttons_go_to_their_owner() {
    assert_eq!(
        notice_action("update", "update-remind-day", true, false, false),
        NoticeAction::CloseUpdate
    );
    assert_eq!(
        notice_action("update-ready", "update-remind-day", true, false, false),
        NoticeAction::CloseUpdate
    );
    assert_eq!(
        notice_action("update", "release_notes", false, true, false),
        NoticeAction::UpdateAction
    );
    // The staged card has no status actions.
    assert_eq!(
        notice_action("update-ready", "release_notes", false, true, false),
        NoticeAction::None
    );
    assert_eq!(
        notice_action("test-feed", "use-real-feed", false, false, false),
        NoticeAction::UseRealFeed
    );
    assert_eq!(notice_action("test-feed", "other", false, false, false), NoticeAction::None);
    assert_eq!(
        notice_action("announcement:a1", "x", false, false, true),
        NoticeAction::AnnouncementTry
    );
    assert_eq!(notice_action("announcement:a1", "x", false, false, false), NoticeAction::None);
    assert_eq!(
        notice_action("tip:t1", "try", false, false, false),
        NoticeAction::Tip { tip: "t1".into() }
    );
    assert_eq!(notice_action("another-card", "yes", false, false, false), NoticeAction::None);
}

#[test]
fn a_notice_x_hides_the_status_and_retires_announcements_and_tips() {
    assert_eq!(dismiss_notice("update"), DismissNotice::Update);
    assert_eq!(dismiss_notice("announcement:a1"), DismissNotice::Announcement { id: "a1".into() });
    assert_eq!(dismiss_notice("tip:t1"), DismissNotice::Tip { id: "t1".into() });
    assert_eq!(dismiss_notice("test-feed"), DismissNotice::None);
    assert_eq!(dismiss_notice("update-ready"), DismissNotice::None);
}

#[test]
fn an_app_click_prefers_apps_open_then_the_interim_show_action_then_its_page() {
    let open = |action: &str| AppAction { action: action.into(), app_argument: true };
    let show = |action: &str| AppAction { action: action.into(), app_argument: false };
    assert_eq!(
        app_activation("cmux/home"),
        vec![open("cmux.apps.open"), show("home.show"), open("app.open")]
    );
    assert_eq!(
        app_activation("cmux/app-store"),
        vec![open("cmux.apps.open"), show("appStore.show"), open("app.open")]
    );
    assert_eq!(app_activation("acme/notes"), vec![open("cmux.apps.open"), open("app.open")]);
}

#[test]
fn requests_round_trip_through_json() {
    let request: Request = serde_json::from_str(
        r#"{"rule":"reorder_pins","section":{"kind":"machine","daemon":2},"workspaces":[{"pinned":true,"daemon":2},{}]}"#,
    )
    .unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&respond(&request).unwrap()).unwrap(),
        serde_json::json!({"kind": "reorder", "unpin": [0]})
    );
    let request: Request = serde_json::from_str(
        r#"{"rule":"machine_status","kind":"ssh","connection":"connected","live":true,"compatibility":"limited"}"#,
    )
    .unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&respond(&request).unwrap()).unwrap(),
        serde_json::json!({"status": "updateAvailable", "compatibility_detail": true})
    );
    let request: Request =
        serde_json::from_str(r#"{"rule":"same_daemon","owners":[1,null,2]}"#).unwrap();
    assert_eq!(respond(&request).unwrap(), b"null");
}
