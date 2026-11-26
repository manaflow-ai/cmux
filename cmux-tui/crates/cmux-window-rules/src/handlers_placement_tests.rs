use super::*;

const KINDS: [&str; 4] = ["terminal", "browser", "agentChat", "newTabPage"];
const PLACES: [&str; 10] = [
    "right",
    "left",
    "up",
    "down",
    "columnRight",
    "columnLeft",
    "row",
    "tab",
    "workspace",
    "window",
];

/// The reducer's fallback plan (`NewPlacementPlan.fallback`): the op for a place.
fn op(place: &str) -> PlaceOp {
    match place {
        "right" => PlaceOp::Split { edge: "right".into() },
        "left" => PlaceOp::Split { edge: "left".into() },
        "up" => PlaceOp::Split { edge: "top".into() },
        "down" => PlaceOp::Split { edge: "bottom".into() },
        "columnRight" => PlaceOp::Column { left: false },
        "columnLeft" => PlaceOp::Column { left: true },
        "row" => PlaceOp::Row,
        "tab" => PlaceOp::Tab,
        "workspace" => PlaceOp::Workspace,
        _ => PlaceOp::Window,
    }
}

fn facts(kind: &str, place: &str, origin: &str) -> NewAtFacts {
    NewAtFacts {
        kind: kind.into(),
        op: op(place),
        made_in_place: true,
        origin: origin.into(),
        frontend_browser_tabs: true,
    }
}

fn open(facts: &NewAtFacts) -> (Option<Create>, bool, PlaceStep) {
    match new_at(facts) {
        NewAt::Open { create, agent_driven, place, .. } => (create, agent_driven, place),
        NewAt::NeedsFrontendBrowserTabs => panic!("refused"),
    }
}

// NewAtPlacementTests: an automated browser is agent-driven at every place
// and keeps its own create only at a new tab.
#[test]
fn an_automated_browser_is_agent_driven_and_creates_only_at_a_tab() {
    for origin in ["cli", "mcp", "script"] {
        for place in PLACES {
            let (create, agent_driven, _) = open(&facts("browser", place, origin));
            assert!(agent_driven, "{origin} {place}");
            assert_eq!(create.is_some(), place == "tab", "{origin} {place}");
        }
    }
}

#[test]
fn a_persons_browser_is_not_agent_driven_and_keeps_its_own_create() {
    for origin in ["user", "remote"] {
        for place in PLACES {
            let (create, agent_driven, _) = open(&facts("browser", place, origin));
            assert!(!agent_driven);
            let own = matches!(place, "right" | "down" | "tab");
            assert_eq!(create.is_some(), own, "{origin} {place}");
        }
    }
}

#[test]
fn a_terminal_from_the_cli_is_not_agent_driven() {
    for place in PLACES {
        let (create, agent_driven, _) = open(&facts("terminal", place, "cli"));
        assert!(!agent_driven);
        let own = matches!(
            place,
            "right" | "left" | "up" | "down" | "columnRight" | "columnLeft" | "row" | "tab"
        );
        assert_eq!(create.is_some(), own, "{place}");
    }
}

#[test]
fn no_create_runs_when_the_plan_makes_then_moves() {
    for kind in KINDS {
        for place in PLACES {
            let mut run = facts(kind, place, "user");
            run.made_in_place = false;
            assert_eq!(open(&run).0, None, "{kind} {place}");
        }
    }
}

#[test]
fn a_browser_off_a_tab_needs_frontend_browser_tabs() {
    for place in PLACES {
        let mut run = facts("browser", place, "user");
        run.frontend_browser_tabs = false;
        assert_eq!(new_at(&run) == NewAt::NeedsFrontendBrowserTabs, place != "tab", "{place}");
        let mut terminal = facts("terminal", place, "user");
        terminal.frontend_browser_tabs = false;
        assert_ne!(new_at(&terminal), NewAt::NeedsFrontendBrowserTabs);
    }
}

#[test]
fn the_creates_match_the_kinds_own_actions() {
    assert_eq!(in_place("terminal", &op("up")), Some(Create::TerminalSplit { direction: "up" }));
    assert_eq!(
        in_place("terminal", &op("columnLeft")),
        Some(Create::Action { action: "newColumnLeft" })
    );
    assert_eq!(
        in_place("terminal", &op("columnRight")),
        Some(Create::Action { action: "newColumn" })
    );
    assert_eq!(in_place("terminal", &op("row")), Some(Create::Action { action: "newRow" }));
    assert_eq!(in_place("terminal", &op("tab")), Some(Create::TerminalTab));
    assert_eq!(in_place("terminal", &op("window")), None);
    assert_eq!(
        in_place("browser", &op("right")),
        Some(Create::Action { action: "splitBrowserRight" })
    );
    assert_eq!(
        in_place("browser", &op("down")),
        Some(Create::Action { action: "splitBrowserDown" })
    );
    assert_eq!(in_place("browser", &op("left")), None);
    assert_eq!(in_place("browser", &op("tab")), Some(Create::Action { action: "openBrowser" }));
    assert_eq!(
        in_place("newTabPage", &op("left")),
        Some(Create::PageSplit { edge: "right", swaps_back: true })
    );
    assert_eq!(
        in_place("newTabPage", &op("right")),
        Some(Create::PageSplit { edge: "right", swaps_back: false })
    );
    assert_eq!(
        in_place("newTabPage", &op("up")),
        Some(Create::PageSplit { edge: "bottom", swaps_back: true })
    );
    assert_eq!(
        in_place("newTabPage", &op("down")),
        Some(Create::PageSplit { edge: "bottom", swaps_back: false })
    );
    assert_eq!(in_place("newTabPage", &op("tab")), Some(Create::PageTab));
    assert_eq!(in_place("agentChat", &op("tab")), Some(Create::ChatTab));
    assert_eq!(in_place("agentChat", &op("right")), Some(Create::ChatSplit { direction: "right" }));
    assert_eq!(in_place("agentChat", &op("down")), Some(Create::ChatSplit { direction: "down" }));
    assert_eq!(in_place("agentChat", &op("left")), None);
    assert_eq!(in_place("other", &op("tab")), None);
}

#[test]
fn a_made_tab_reaches_its_place() {
    assert_eq!(place_step(&op("left")), PlaceStep::Split { edge: "left".into() });
    assert_eq!(place_step(&op("columnLeft")), PlaceStep::Fork { left: Some(true) });
    assert_eq!(place_step(&op("columnRight")), PlaceStep::Fork { left: Some(false) });
    assert_eq!(place_step(&op("row")), PlaceStep::Fork { left: None });
    assert_eq!(
        place_step(&op("workspace")),
        PlaceStep::Action { action: "palette.moveTabToNewWorkspace" }
    );
    assert_eq!(place_step(&op("window")), PlaceStep::Action { action: "tab.moveToNewWindow" });
    assert_eq!(place_step(&op("tab")), PlaceStep::Finished);
    assert_eq!(made("agentChat"), Some(Made::AgentChat));
    assert_eq!(made("other"), None);
}

// NewAtPlacementTests: direction maps a split edge to Cmd-D's direction.
#[test]
fn direction_follows_the_edge() {
    assert_eq!(direction("right"), "right");
    assert_eq!(direction("left"), "left");
    assert_eq!(direction("top"), "up");
    assert_eq!(direction("bottom"), "down");
}

// NewAtPlacementTests: rows are gated for every kind, a left column for a terminal only.
#[test]
fn the_row_gate_is_every_kinds_and_the_left_column_gate_a_terminals() {
    for kind in KINDS {
        assert_eq!(new_at_gate(kind, "row"), Some(NewAtGate::Row));
        let left = (kind == "terminal").then_some(NewAtGate::ColumnLeft);
        assert_eq!(new_at_gate(kind, "columnLeft"), left);
        assert_eq!(new_at_gate(kind, SUBMENU_PLACE), None);
    }
}

#[test]
fn an_open_from_a_chat_goes_beside_it() {
    let chat =
        BesideFacts { selected_is_chat: true, allows_view_change: true, ..Default::default() };
    assert_eq!(
        beside_chat(&chat),
        Some(BesideFlags {
            beside_caller: true,
            new_column_beside: true,
            beside_takes_focus: true
        })
    );
    let page = BesideFacts { keeps_new_tab_page: true, ..Default::default() };
    assert_eq!(beside_chat(&page).map(|flags| flags.beside_takes_focus), Some(false));
    assert_eq!(beside_chat(&BesideFacts { beside_caller: true, ..chat }), None);
    assert_eq!(beside_chat(&BesideFacts::default()), None);
}

#[test]
fn a_beside_open_steps_in_order() {
    let step = |chat_in_anchor, tab_in_anchor, lone| {
        beside_step(&BesideStepFacts { chat_in_anchor, tab_in_anchor, lone })
    };
    assert_eq!(step(Some(false), Some(true), true), BesideStep::ChatDocked);
    assert_eq!(step(Some(true), Some(true), true), BesideStep::DockChat);
    assert_eq!(step(Some(true), Some(false), true), BesideStep::DockChat);
    assert_eq!(step(Some(true), Some(false), false), BesideStep::Moved);
    assert_eq!(step(None, Some(false), false), BesideStep::Moved);
    assert_eq!(step(Some(true), Some(true), false), BesideStep::RightColumn);
    assert_eq!(step(None, None, true), BesideStep::RightColumn);
}

#[test]
fn a_beside_move_keeps_the_persons_focus() {
    let focus = |person_acted, focused_is_destination, chat_had_focus, focused_is_anchor| {
        beside_focus(&BesideFocusFacts {
            person_acted,
            focused_is_destination,
            chat_had_focus,
            focused_is_anchor,
        })
    };
    assert_eq!(focus(false, false, true, false), BesideFocus { select: true, follow_chat: true });
    assert_eq!(focus(false, false, false, true), BesideFocus { select: true, follow_chat: true });
    assert_eq!(focus(true, true, true, true), BesideFocus { select: false, follow_chat: false });
    assert_eq!(focus(true, false, false, false), BesideFocus { select: true, follow_chat: false });
}

#[test]
fn a_lone_chat_is_one_pane_with_one_chat() {
    let chat = ColumnTab { agent_session: true, new_tab_page: false };
    let page = ColumnTab { agent_session: true, new_tab_page: true };
    assert!(!is_chat(&page));
    assert!(lone_chat(1, &[chat], false));
    assert!(!lone_chat(2, &[chat], false));
    assert!(!lone_chat(1, &[chat, page], false));
    assert!(lone_chat(1, &[chat, page], true));
    assert!(!lone_chat(1, &[page], true));
    assert!(!lone_chat(1, &[], false));
}

#[test]
fn a_chat_docks_only_with_a_respawn_to_leave() {
    let route = |placement, respawn, tab_column_respawn, has_tab| {
        chat_route(&ChatRouteFacts { placement, respawn, tab_column_respawn, has_tab })
    };
    assert_eq!(route(ChatSide::DockChat, true, true, true), ChatSide::DockChat);
    assert_eq!(route(ChatSide::DockChat, false, true, true), ChatSide::Here);
    assert_eq!(route(ChatSide::DockChat, true, false, true), ChatSide::Here);
    assert_eq!(route(ChatSide::DockChat, true, true, false), ChatSide::Here);
    assert_eq!(route(ChatSide::Tab, false, false, false), ChatSide::Tab);
    assert_eq!(route(ChatSide::BesideDock, false, false, false), ChatSide::BesideDock);
}

#[test]
fn beside_a_dock_opens_what_the_split_leaves() {
    let browser =
        |url: &str, new_tab_address| Respawn::Browser { url: url.into(), new_tab_address };
    assert_eq!(beside_dock_open(Some(&Respawn::Terminal)), BesideDockOpen::NewColumn);
    assert_eq!(
        beside_dock_open(Some(&browser("HTTPS://example.com", false))),
        BesideDockOpen::OpenOnHome
    );
    assert_eq!(
        beside_dock_open(Some(&browser("file:///tmp/a.html", false))),
        BesideDockOpen::BrowserTab
    );
    assert_eq!(beside_dock_open(Some(&browser("about:blank", true))), BesideDockOpen::NewTabPage);
    assert_eq!(beside_dock_open(None), BesideDockOpen::NewTabPage);
    assert!(!is_web_page("http://a b"));
    assert!(!is_web_page("example.com"));
}

#[test]
fn a_new_chat_opens_by_its_placement() {
    let opening = |placed, placement, select, conversation_tab_split| {
        new_chat_opening(&NewChatFacts { placed, placement, select, conversation_tab_split })
    };
    let here = NewChatOpening {
        in_dock: false,
        focus_dock: false,
        select: true,
        hidden: false,
        split_right: false,
        docks: false,
    };
    assert_eq!(opening(false, NewChatSide::NewDock, true, true), here);
    assert_eq!(opening(true, NewChatSide::Here, true, true), here);
    assert_eq!(
        opening(true, NewChatSide::Dock, true, false),
        NewChatOpening { in_dock: true, focus_dock: true, ..here }
    );
    assert_eq!(
        opening(true, NewChatSide::Dock, false, false),
        NewChatOpening { in_dock: true, select: false, ..here }
    );
    assert_eq!(
        opening(true, NewChatSide::BesideDock, true, true),
        NewChatOpening { split_right: true, ..here }
    );
    assert_eq!(opening(true, NewChatSide::BesideDock, true, false), here);
    assert_eq!(
        opening(true, NewChatSide::NewDock, true, false),
        NewChatOpening { hidden: true, select: false, docks: true, ..here }
    );
}

#[test]
fn the_main_panes_agent_tab_and_dock_focus() {
    assert_eq!(agent_tab_target(ChatSide::Tab), Some(AgentTabTarget::Strip));
    assert_eq!(agent_tab_target(ChatSide::DockChat), Some(AgentTabTarget::Docking));
    assert_eq!(agent_tab_target(ChatSide::Here), None);
    assert_eq!(agent_tab_target(ChatSide::BesideDock), None);
    assert_eq!(docked_focus(true, true, true), Some(DockedFocus::Pane));
    assert_eq!(docked_focus(false, true, true), Some(DockedFocus::Dock));
    assert_eq!(docked_focus(false, true, false), None);
    assert_eq!(docked_focus(false, false, true), None);
}

#[test]
fn the_dock_actions_ask_for_their_edge_and_mode() {
    let nearest = dock_settings(Some("nearest"), None);
    assert_eq!(
        nearest,
        DockSettings { configured_edge: None, default_edge: "right", default_mode: "docked" }
    );
    let left = dock_settings(Some("left"), Some("overlay"));
    assert_eq!(
        left,
        DockSettings {
            configured_edge: Some("left"),
            default_edge: "left",
            default_mode: "overlay"
        }
    );
    assert_eq!(
        dock_ask("column.dock", None, None, &left),
        Some(DockAsk { edge: None, mode: Some("overlay") })
    );
    assert_eq!(
        dock_ask("column.dock", Some("top"), Some("docked"), &left),
        Some(DockAsk { edge: Some("top"), mode: Some("docked") })
    );
    assert_eq!(
        dock_ask("column.dock", Some("diag"), Some("x"), &nearest),
        Some(DockAsk { edge: None, mode: Some("docked") })
    );
    for edge in DOCK_EDGES {
        let action = format!("column.dock{}{}", edge[..1].to_uppercase(), &edge[1..]);
        assert_eq!(
            dock_ask(&action, None, None, &left),
            Some(DockAsk { edge: Some(edge), mode: Some("overlay") })
        );
    }
    assert_eq!(
        dock_ask("column.float", Some("left"), None, &nearest),
        Some(DockAsk { edge: None, mode: Some("overlay") })
    );
    assert_eq!(
        dock_ask("tab.moveToNewDockColumn", None, None, &left),
        Some(DockAsk { edge: Some("left"), mode: None })
    );
    assert_eq!(
        dock_ask("tab.moveToNewDockColumn", Some("bottom"), Some("overlay"), &nearest),
        Some(DockAsk { edge: Some("bottom"), mode: Some("overlay") })
    );
    assert_eq!(dock_ask("column.undock", None, None, &nearest), None);
}

#[test]
fn a_refused_dock_change_fails_with_its_reason() {
    assert_eq!(
        dock_failure(DockRefusal::UnknownColumn, false),
        DockFailure::InvalidTarget(DockReason::NoColumnShown)
    );
    assert_eq!(
        dock_failure(DockRefusal::LastScrollingColumn, true),
        DockFailure::InvalidTarget(DockReason::LastScrollingColumn)
    );
    assert_eq!(
        dock_failure(DockRefusal::Unchanged, true),
        DockFailure::NoTarget(DockReason::ColumnNotDocked)
    );
    assert_eq!(
        dock_failure(DockRefusal::Unchanged, false),
        DockFailure::NoTarget(DockReason::ColumnAlreadyDocked)
    );
}

#[test]
fn new_tab_kinds_name_their_actions_and_facts() {
    assert_eq!(new_tab_action("terminal"), Some("newSurface"));
    assert_eq!(new_tab_action("browser"), Some("openBrowser"));
    assert_eq!(new_tab_action("agent"), Some("palette.newAgentChat"));
    assert_eq!(new_tab_action("page"), Some("newTab.page"));
    assert_eq!(new_tab_action("x"), None);
    assert_eq!(selected_kind(Some("pty")), Some("pty"));
    assert_eq!(selected_kind(Some("browser")), Some("browser"));
    assert_eq!(selected_kind(Some("markdown")), Some("other"));
    assert_eq!(selected_kind(None), None);
}

#[test]
fn only_a_persons_unnamed_split_follows_the_setting() {
    assert!(pane_route_follows_setting("user", false));
    assert!(!pane_route_follows_setting("user", true));
    assert!(!pane_route_follows_setting("cli", false));
}

#[test]
fn new_at_reads_the_apps_json() {
    let facts: NewAtFacts = serde_json::from_str(
        r#"{"kind":"browser","op":"column","left":true,"madeInPlace":true,"origin":"mcp","frontendBrowserTabs":true}"#,
    )
    .expect("facts");
    let answer = serde_json::to_value(new_at(&facts)).expect("answer");
    assert_eq!(
        answer,
        serde_json::json!({"route":"open","create":null,"made":"browser","agentDriven":true,"place":{"move":"fork","left":true}})
    );
}
