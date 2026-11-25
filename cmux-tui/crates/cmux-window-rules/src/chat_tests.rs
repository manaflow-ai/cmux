use super::*;

fn col(panes: &[&str]) -> Column {
    Column { panes: panes.iter().map(|p| p.to_string()).collect(), ..Column::default() }
}

fn lone(panes: &[&str]) -> Column {
    Column { lone_chat: true, ..col(panes) }
}

fn chat_dock(panes: &[&str]) -> Column {
    Column { dock: Some(Dock { role: Some(DockRole::AgentChat), ..Dock::default() }), ..col(panes) }
}

fn home_dock(panes: &[&str], allows_tabs: bool) -> Column {
    let dock = Dock { role: Some(DockRole::AgentChat), pinned: true, allows_tabs };
    Column { dock: Some(dock), ..col(panes) }
}

fn plain_dock(panes: &[&str]) -> Column {
    Column { dock: Some(Dock::default()), ..col(panes) }
}

fn strings(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

fn tab(pane: &str) -> ColumnPlacement {
    ColumnPlacement::Tab { pane: pane.into() }
}

fn place(pane: &str, columns: &[Column]) -> ColumnPlacement {
    column_placement(pane, columns, &[], false)
}

/// Leo 2026-10-30: "IF I'M FOCUSED ON THE MAIN PANE OPEN IT THERE". Cmd-T in the chat dock opens the
/// New Tab page in the dock; a chat or any other new tab from it still goes to the strip.
#[test]
fn cmd_t_in_the_main_pane_opens_the_page_there() {
    let columns = [chat_dock(&["chat"]), col(&["page"])];
    assert!(keeps_new_tab_page("chat", &columns));
    assert_eq!(place("chat", &columns), tab("page"));
    assert!(!keeps_new_tab_page("page", &columns));
    assert_eq!(place("page", &columns), ColumnPlacement::Here);
}

/// Home's pinned dock keeps its own route, and a pane in no dock is no chat dock.
#[test]
fn homes_pinned_dock_and_plain_panes_keep_their_route() {
    assert!(!keeps_new_tab_page("home", &[home_dock(&["home"], false), col(&["page"])]));
    assert!(!keeps_new_tab_page("chat", &[col(&["chat"])]));
    assert!(!keeps_new_tab_page("files", &[plain_dock(&["files"]), col(&["page"])]));
}

/// A pick on a page in the chat dock opens in the strip beside it, the pane used last first.
#[test]
fn a_pick_on_a_page_in_the_chat_dock_opens_in_the_strip() {
    let columns = [chat_dock(&["chat"]), col(&["page"]), col(&["other"])];
    assert_eq!(page_pick("chat", &columns, &[], false), Some("page".into()));
    assert_eq!(
        page_pick("chat", &columns, &strings(&["chat", "other"]), false),
        Some("other".into())
    );
    assert_eq!(
        page_pick("chat", &columns, &[], true),
        None,
        "a zoomed screen shows the dock alone"
    );
    assert_eq!(
        page_pick("page", &columns, &[], false),
        None,
        "a page in the strip is replaced in place"
    );
    assert_eq!(page_pick("home", &[home_dock(&["home"], false), col(&["page"])], &[], false), None);
}

/// #29848: a pane Split Down made below the chat in the dock is an ordinary pane.
#[test]
fn a_pick_on_a_page_below_the_chat_in_the_dock_takes_the_pages_place() {
    let columns = [chat_dock(&["chat", "below"]), col(&["page"])];
    assert!(keeps_new_tab_page("chat", &columns));
    assert_eq!(page_pick("chat", &columns, &[], false), Some("page".into()));
    assert!(!keeps_new_tab_page("below", &columns));
    assert_eq!(page_pick("below", &columns, &[], false), None);
    assert!(is_below_chat("below", &columns));
    assert!(!is_below_chat("chat", &columns), "the chat's own picks still go beside it");
    assert!(!is_below_chat("page", &columns));
}

/// #29848: Split Down grows an unpinned chat dock only.
#[test]
fn split_down_grows_only_an_unpinned_chat_dock() {
    let chat = Dock { role: Some(DockRole::AgentChat), ..Dock::default() };
    assert!(chat.splits_down(false));
    assert!(!chat.splits_down(true), "a zoomed screen shows the chat alone");
    assert!(!Dock { pinned: true, ..chat }.splits_down(false), "Home opens beside its dock");
    assert!(!Dock::default().splits_down(false));
}

/// A tool dragged into a chat dock is refused, except into Home's pinned dock while it takes tabs.
#[test]
fn homes_dock_takes_any_dragged_tab_other_chat_docks_only_chats() {
    let chat = Dock { role: Some(DockRole::AgentChat), ..Dock::default() };
    assert!(chat.takes_only_chats());
    assert!(Dock { pinned: true, ..chat }.takes_only_chats(), "closed to tabs");
    assert!(!Dock { pinned: true, allows_tabs: true, ..chat }.takes_only_chats());
    assert!(!Dock::default().takes_only_chats());
}

/// The read answers the move refusal: a tool into the dock, not a reorder in it, not a chat.
#[test]
fn the_chat_dock_refuses_a_tool_moved_into_it() {
    let columns = [chat_dock(&["chat"]), col(&["page"])];
    let refuses = |moving| read("chat", &columns, &[], false, Some(moving)).refuses_move;
    assert!(refuses(Moving { same_pane: false, chat: false }));
    assert!(!refuses(Moving { same_pane: true, chat: false }));
    assert!(!refuses(Moving { same_pane: false, chat: true }));
    assert!(!read("page", &columns, &[], false, Some(Moving::default())).refuses_move);
    let read = read("chat", &columns, &[], false, None);
    assert!(read.chat_dock && read.takes_only_chats && read.splits_down && !read.refuses_move);
}

/// A chat alone on its screen docks left; beside the chat dock, opens are tabs on the right.
#[test]
fn a_lone_chat_docks_and_the_dock_opens_in_the_strip() {
    assert_eq!(place("c", &[lone(&["c"])]), ColumnPlacement::DockChat);
    let columns = [chat_dock(&["c"]), col(&["r1"]), col(&["r2"])];
    assert_eq!(place("c", &columns), tab("r1"));
    assert_eq!(column_placement("c", &columns, &strings(&["c", "r2", "r1"]), false), tab("r2"));
}

/// Only the chat is a main pane: a strip pane, a terminal alone, a chat beside other columns and a
/// zoomed screen keep the usual rules.
#[test]
fn other_panes_keep_the_usual_rules() {
    assert_eq!(place("r1", &[chat_dock(&["c"]), col(&["r1"])]), ColumnPlacement::Here);
    assert_eq!(place("t", &[col(&["t"])]), ColumnPlacement::Here);
    assert_eq!(place("c", &[lone(&["c"]), col(&["t"])]), ColumnPlacement::Here);
    assert_eq!(column_placement("c", &[lone(&["c"])], &[], true), ColumnPlacement::Here);
    assert_eq!(place("c", &[lone(&["c"]), chat_dock(&["d"])]), ColumnPlacement::Here);
    assert_eq!(place("gone", &[lone(&["c"])]), ColumnPlacement::Here);
}

/// From Home's dock alone, new tabs and new chats open beside it; an unpinned dock alone keeps them.
#[test]
fn new_tabs_from_the_lone_home_dock_open_beside_it() {
    for allows_tabs in [false, true] {
        let alone = [home_dock(&["dock"], allows_tabs)];
        assert_eq!(place("dock", &alone), ColumnPlacement::BesideDock);
        assert_eq!(new_chat_placement("dock", &alone, false), NewChatPlacement::BesideDock);
    }
    assert_eq!(place("dock", &[chat_dock(&["dock"])]), ColumnPlacement::Here);
    assert_eq!(place("dock", &[home_dock(&["dock"], false), col(&["p1"])]), tab("p1"));
}

/// A new agent chat never lands in Home's pinned chat dock: from the strip it opens where it was
/// asked for, from the dock in the first scrolling pane.
#[test]
fn a_new_chat_skips_a_pinned_dock() {
    for allows_tabs in [false, true] {
        let columns = [home_dock(&["dock"], allows_tabs), col(&["p1"])];
        assert_eq!(new_chat_placement("p1", &columns, false), NewChatPlacement::Here);
        assert_eq!(
            new_chat_placement("dock", &columns, false),
            NewChatPlacement::Dock { pane: "p1".into() }
        );
    }
}

/// The chat dock is the workspace's one chat: a new chat joins it; a lone chat takes a second chat
/// in its pane; anything else makes the dock.
#[test]
fn a_new_chat_joins_the_dock_or_makes_one() {
    let columns = [col(&["p1"]), chat_dock(&["d1", "d2"])];
    assert_eq!(
        new_chat_placement("p1", &columns, false),
        NewChatPlacement::Dock { pane: "d1".into() }
    );
    assert_eq!(new_chat_placement("c", &[lone(&["c"])], true), NewChatPlacement::Here);
    assert_eq!(new_chat_placement("t", &[col(&["t"])], false), NewChatPlacement::NewDock);
    assert_eq!(new_chat_placement("gone", &[col(&["t"])], false), NewChatPlacement::Here);
    assert_eq!(read("c", &[lone(&["c"])], &[], false, None).new_chat, NewChatPlacement::Here);
}

fn cmd_i(pane: &str, columns: Vec<Column>) -> DockedOpen {
    let read = read(pane, &columns, &[], false, None);
    DockedOpen {
        user: true,
        can_host: true,
        dock_roles: true,
        shown: true,
        pane: pane.into(),
        chat_dock_top: read.chat_dock_top,
        docks_chat: read.placement == ColumnPlacement::DockChat,
        ..DockedOpen::default()
    }
}

/// Cmd-I focuses the workspace's chat dock, never Home's Chief; a lone chat is that chat.
#[test]
fn cmd_i_focuses_the_one_chat() {
    let focus = |pane: &str| DockedOpenDecision::Focus { pane: pane.into() };
    assert_eq!(docked_open(&cmd_i("t", vec![chat_dock(&["d", "e"]), col(&["t"])])), focus("d"));
    assert_eq!(docked_open(&cmd_i("c", vec![lone(&["c"])])), focus("c"));
    assert_eq!(
        docked_open(&cmd_i("t", vec![home_dock(&["h"], true), col(&["t"])])),
        DockedOpenDecision::Open
    );
    let pending = DockedOpen { pending_dock: true, ..cmd_i("t", vec![col(&["t"])]) };
    assert_eq!(docked_open(&pending), DockedOpenDecision::Handled);
}

/// Scripts, targets, arguments and daemons without chat docks open a chat tab in the pane.
#[test]
fn cmd_i_from_a_script_is_not_the_docked_chats() {
    let base = cmd_i("t", vec![chat_dock(&["d"]), col(&["t"])]);
    for facts in [
        DockedOpen { user: false, ..base.clone() },
        DockedOpen { targeted: true, ..base.clone() },
        DockedOpen { has_arguments: true, ..base.clone() },
        DockedOpen { can_host: false, ..base.clone() },
        DockedOpen { dock_roles: false, ..base.clone() },
        DockedOpen { shown: false, ..base },
    ] {
        assert_eq!(docked_open(&facts), DockedOpenDecision::NotHandled);
    }
}

#[test]
fn a_drop_into_the_chat_dock_never_splits_and_a_workspace_drop_skips_it() {
    assert_eq!(drop_split(true, true), DropSplit::RefusedChatDock);
    assert_eq!(drop_split(true, false), DropSplit::Split);
    assert_eq!(drop_split(false, false), DropSplit::Measure);
    assert_eq!(drop_pane(&[true, false, false]), Some(1));
    assert_eq!(drop_pane(&[true]), Some(0));
    assert_eq!(drop_pane(&[]), None);
}

fn pane(id: &str, focused_at: u64) -> ChatPane {
    ChatPane { id: id.into(), resource_id: Some(format!("pane_{id}")), focused_at }
}

fn workspace(id: &str, panes: Vec<ChatPane>) -> ChatWorkspace {
    ChatWorkspace {
        id: id.into(),
        resource_id: Some(format!("ws_{id}")),
        key: Some(format!("key-{id}")),
        panes,
    }
}

fn at(workspace: usize, pane: &str) -> Option<ChatDestination> {
    Some(ChatDestination { workspace, pane: pane.into() })
}

/// The active window's focused pane, once its focus topology is of that workspace; else the pane
/// it remembers; else the pane focused last.
#[test]
fn a_chat_opens_at_the_windows_focus() {
    let workspaces = vec![
        workspace("a", vec![pane("a1", 5), pane("a2", 9)]),
        workspace("b", vec![pane("b1", 1)]),
    ];
    let window = ChatWindow {
        workspace: Some("a".into()),
        recency: strings(&["b"]),
        focus_workspace: Some("a".into()),
        focused_pane: Some("a1".into()),
        ..ChatWindow::default()
    };
    assert_eq!(destination(std::slice::from_ref(&window), &workspaces), at(0, "a1"));
    // The topology is still the previous workspace's: its pane never masks this one's memory.
    let moving = ChatWindow {
        focus_workspace: Some("b".into()),
        remembered: HashMap::from([("a".into(), "a1".into())]),
        ..window.clone()
    };
    assert_eq!(destination(&[moving], &workspaces), at(0, "a1"));
    let unknown = ChatWindow { focus_workspace: Some("b".into()), ..window };
    assert_eq!(destination(&[unknown], &workspaces), at(0, "a2"), "the pane focused last");
}

/// A workspace with no key or no pane is passed over, for the window's recent ones, then the next window.
#[test]
fn a_chat_skips_a_workspace_without_a_key_or_a_pane() {
    let keyless = ChatWorkspace { key: None, ..workspace("a", vec![pane("a1", 1)]) };
    let workspaces =
        vec![keyless, workspace("e", vec![]), workspace("b", vec![pane("b1", 1), pane("b2", 1)])];
    let first = ChatWindow {
        workspace: Some("a".into()),
        recency: strings(&["e"]),
        ..ChatWindow::default()
    };
    let second = ChatWindow { recency: strings(&["b"]), ..ChatWindow::default() };
    assert_eq!(destination(std::slice::from_ref(&first), &workspaces), None);
    assert_eq!(destination(&[first, second], &workspaces), at(2, "b1"), "the first of equals");
    assert_eq!(latest_pane(&workspaces), at(2, "b1"));
    assert_eq!(latest_pane(&[]), None);
}

#[test]
fn a_target_names_a_pane_or_a_workspaces_latest_pane() {
    let workspaces = vec![
        workspace("a", vec![pane("a1", 3), pane("a2", 2)]),
        workspace("b", vec![pane("b1", 1)]),
    ];
    assert_eq!(target(TargetKind::Pane, "b1", &workspaces), at(1, "b1"));
    assert_eq!(target(TargetKind::Pane, "pane_a2", &workspaces), at(0, "a2"));
    assert_eq!(target(TargetKind::Pane, "zz", &workspaces), None);
    assert_eq!(target(TargetKind::Workspace, "ws_b", &workspaces), at(1, "b1"));
    assert_eq!(target(TargetKind::Workspace, "key-a", &workspaces), at(0, "a1"));
    assert_eq!(target(TargetKind::Workspace, "a", &[workspace("a", vec![])]), None);
    assert_eq!(target(TargetKind::Other, "a", &workspaces), None);
}

#[test]
fn a_new_chats_folder() {
    let tabs = vec![Some("/first".to_string()), Some("/second".to_string())];
    assert_eq!(cwd(Some("/given"), Some("/agent"), &tabs, 1).as_deref(), Some("/given"));
    assert_eq!(cwd(Some(""), Some("/agent"), &tabs, 1).as_deref(), Some("/agent"));
    assert_eq!(cwd(None, None, &tabs, 1).as_deref(), Some("/second"));
    assert_eq!(cwd(None, None, &tabs, 7).as_deref(), Some("/first"));
    assert_eq!(cwd(None, None, &tabs, -1).as_deref(), Some("/first"));
    assert_eq!(cwd(None, None, &[], 0), None);
}

fn facts(width: f64, panes: &[&str]) -> ColumnFacts {
    ColumnFacts {
        column: ActionColumn { width, panes: strings(panes), ..ActionColumn::default() },
        handle: true,
        ..ColumnFacts::default()
    }
}

#[test]
fn widths_set_a_preset_and_cycle_around() {
    assert_eq!(
        column_plan("column.widthHalf", &facts(1.0, &["p"])),
        ColumnPlan::SetWidth { width: 0.5 }
    );
    assert_eq!(
        column_plan("column.widthHalf", &facts(0.5004, &["p"])),
        ColumnPlan::Refuse { refusal: ColumnRefusal::AlreadyHasWidth, quiet: true }
    );
    assert_eq!(
        column_plan("column.cycleWidth", &facts(0.5, &[])),
        ColumnPlan::SetWidth { width: 2.0 / 3.0 }
    );
    assert_eq!(
        column_plan("column.cycleWidth", &facts(1.0, &["p"])),
        ColumnPlan::SetWidth { width: 1.0 / 3.0 }
    );
    assert_eq!(
        column_plan("column.cycleWidthBack", &facts(0.34, &["p"])),
        ColumnPlan::SetWidth { width: 1.0 }
    );
    assert_eq!(next_width(0.5, false), 1.0 / 3.0);
    assert_eq!(column_plan("column.nope", &facts(0.5, &["p"])), ColumnPlan::Unknown);
}

#[test]
fn moves_take_the_whole_column_or_swap_a_lone_pane() {
    let mut with_right = facts(0.5, &["a", "b"]);
    with_right.right = Some(strings(&["r"]));
    assert_eq!(
        column_plan("column.moveLeft", &with_right),
        ColumnPlan::Refuse { refusal: ColumnRefusal::ColumnAtEdge, quiet: true }
    );
    assert_eq!(
        column_plan("column.moveRight", &with_right),
        ColumnPlan::Refuse { refusal: ColumnRefusal::NeedsColumnMove, quiet: false }
    );
    with_right.column_move = true;
    assert_eq!(
        column_plan("column.moveRight", &with_right),
        ColumnPlan::MoveColumn { side: Side::Right, pane: "a".into() }
    );
    let mut lone_pane = facts(0.5, &["a"]);
    lone_pane.left = Some(strings(&["l"]));
    assert_eq!(
        column_plan("column.moveLeft", &lone_pane),
        ColumnPlan::SwapPane { side: Side::Left, pane: "a".into() }
    );
    lone_pane.handle = false;
    assert_eq!(
        column_plan("column.moveLeft", &lone_pane),
        ColumnPlan::Refuse { refusal: ColumnRefusal::NoHandle, quiet: false }
    );
    assert_eq!(column_plan("column.moveLeft", &facts(0.5, &[])), ColumnPlan::Nothing);
}

#[test]
fn focus_goes_to_the_adjacent_columns_latest_tile_and_center_to_the_focused_one() {
    let mut f = facts(0.5, &["a", "b"]);
    f.right = Some(strings(&["r1", "r2"]));
    assert_eq!(column_plan("column.focusRight", &f), ColumnPlan::Focus { pane: "r1".into() });
    f.recent = strings(&["a", "r2"]);
    assert_eq!(column_plan("column.focusRight", &f), ColumnPlan::Focus { pane: "r2".into() });
    assert_eq!(
        column_plan("column.focusLeft", &f),
        ColumnPlan::Refuse {
            refusal: ColumnRefusal::NoColumnInDirection { side: Side::Left },
            quiet: true
        }
    );
    assert_eq!(column_plan("column.center", &f), ColumnPlan::Center { pane: "a".into() });
    f.focused = Some("b".into());
    assert_eq!(column_plan("column.center", &f), ColumnPlan::Center { pane: "b".into() });
    f.focused = Some("r1".into());
    assert_eq!(column_plan("column.center", &f), ColumnPlan::Center { pane: "a".into() });
}

#[test]
fn a_lone_column_disables_widths_and_moves_and_undock_needs_a_dock() {
    let implicit = ActionColumn { implicit: true, ..ActionColumn::default() };
    let docked = ActionColumn { docked: true, ..ActionColumn::default() };
    assert_eq!(
        column_availability("column.widthHalf", Some(&implicit)),
        Some(ColumnUnavailable::AddSecondColumn)
    );
    assert_eq!(
        column_availability("column.focusRight", Some(&implicit)),
        Some(ColumnUnavailable::AddSecondColumn)
    );
    assert_eq!(column_availability("column.center", Some(&implicit)), None);
    assert_eq!(column_availability("column.widthHalf", Some(&docked)), None);
    assert_eq!(
        column_availability("column.undock", Some(&implicit)),
        Some(ColumnUnavailable::NotDocked)
    );
    assert_eq!(column_availability("column.undock", Some(&docked)), None);
    assert_eq!(column_availability("column.undock", None), None);
    let actions = column_actions();
    assert_eq!(actions.lone_column_disabled.len(), 10);
    assert_eq!(actions.canvas.len(), 9);
}

#[test]
fn a_dock_asks_its_capabilities_first() {
    let all = DockFacts { band: true, dock_columns: true, edge_docks: true };
    assert_eq!(dock_needs(all), None);
    assert_eq!(dock_needs(DockFacts { dock_columns: false, ..all }), Some(DockNeeds::DockColumns));
    assert_eq!(dock_needs(DockFacts { edge_docks: false, ..all }), Some(DockNeeds::EdgeDocks));
    assert_eq!(dock_needs(DockFacts { edge_docks: false, band: false, ..all }), None);
}

/// A screen's only scrolling column docks its focused tab: a fresh tab stays behind a pane's only
/// tab in a one-pane column; a pane's only tab leaves through another pane of its column.
#[test]
fn the_focused_tab_moves_into_a_new_dock() {
    let base = DockMoveFacts {
        pane: "p".into(),
        pane_tabs: 1,
        column_panes: strings(&["p"]),
        has_tab: true,
        edge_docks: true,
        tab_column_respawn: true,
        ..DockMoveFacts::default()
    };
    assert_eq!(dock_move(&base), DockMove::Move { respawn: true, anchor: "p".into() });
    assert_eq!(
        dock_move(&DockMoveFacts { tab_column_respawn: false, ..base.clone() }),
        DockMove::Refuse { needs: DockNeeds::TabColumnRespawn }
    );
    assert_eq!(
        dock_move(&DockMoveFacts { edge_docks: false, ..base.clone() }),
        DockMove::Refuse { needs: DockNeeds::EdgeDocks }
    );
    assert_eq!(dock_move(&DockMoveFacts { has_tab: false, ..base.clone() }), DockMove::NoTab);
    let two_panes =
        DockMoveFacts { column_panes: strings(&["p", "q"]), shown_others: strings(&["q"]), ..base };
    assert_eq!(dock_move(&two_panes), DockMove::Move { respawn: false, anchor: "q".into() });
    let two_tabs = DockMoveFacts { pane_tabs: 2, ..two_panes.clone() };
    assert_eq!(dock_move(&two_tabs), DockMove::Move { respawn: false, anchor: "p".into() });
    let unshown = DockMoveFacts { shown_others: vec![], ..two_panes };
    assert_eq!(dock_move(&unshown), DockMove::Move { respawn: false, anchor: "p".into() });
}
