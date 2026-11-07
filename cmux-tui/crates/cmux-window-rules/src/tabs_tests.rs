use super::panes::{
    self, AutoFacts, Direction, SplitDo, SplitFacts, SplitFolders, TabBarFacts, TabBarRefusal,
    ToolSplit,
};
use super::*;

fn facts() -> NewTabFacts {
    NewTabFacts { can_host_agent: true, ..NewTabFacts::default() }
}

#[test]
fn the_selected_tab_names_the_kind() {
    assert_eq!(same_kind(&facts()), NewTabKind::Terminal);
    let browser =
        NewTabFacts { selected_kind: SelectedKind::Browser, engine: Some("cef".into()), ..facts() };
    assert_eq!(same_kind(&browser), NewTabKind::Browser { engine: Some("cef".into()) });
    assert_eq!(
        same_kind(&NewTabFacts { local_browser: true, ..facts() }),
        NewTabKind::Browser { engine: None }
    );
    assert_eq!(same_kind(&NewTabFacts { agent: true, ..browser }), NewTabKind::Agent);
    assert_eq!(
        same_kind(&NewTabFacts { agent: true, new_tab_page: true, ..facts() }),
        NewTabKind::Page
    );
}

#[test]
fn a_persons_cmd_t_opens_the_page_where_agent_tabs_live() {
    let user = NewTabFacts { user: true, follows_setting: true, ..facts() };
    assert_eq!(new_tab_kind(&user), NewTabKind::Page);
    assert_eq!(
        new_tab_kind(&NewTabFacts { can_host_agent: false, ..user.clone() }),
        NewTabKind::Terminal
    );
    // New <Kind> Tab follows the selected tab, not the setting.
    assert_eq!(new_tab_kind(&NewTabFacts { follows_setting: false, ..user }), NewTabKind::Terminal);
    let agent = NewTabFacts { agent: true, can_host_agent: false, ..facts() };
    assert_eq!(new_tab_kind(&agent), NewTabKind::Terminal);
}

fn resolved(url: &str) -> Resolution {
    Resolution { url: url.into(), ..Resolution::default() }
}

#[test]
fn no_url_opens_the_default_page_on_the_asked_engine() {
    let plan =
        browser_open(&BrowserOpenFacts { engine: Some("webkit".into()), ..Default::default() });
    assert_eq!(plan, BrowserOpen::Open { url: None, engine: Some("webkit".into()) });
}

#[test]
fn a_chromium_page_opens_in_chromium_unless_cmux_shows_it() {
    let chromium_page = BrowserOpenFacts {
        has_text: true,
        chromium_internal: true,
        chromium: Some(Resolution {
            route: Some(PageRoute::Chromium),
            ..resolved("chrome://extensions/")
        }),
        ..Default::default()
    };
    assert_eq!(
        browser_open(&chromium_page),
        BrowserOpen::Open { url: Some("chrome://extensions/".into()), engine: Some("cef".into()) }
    );
    let history = BrowserOpenFacts {
        has_text: true,
        chromium_internal: true,
        cmux_owned: true,
        webkit: Some(Resolution {
            route: Some(PageRoute::CmuxPage),
            page: Some("cmux://history".into()),
            ..resolved("chrome://history/")
        }),
        ..Default::default()
    };
    assert_eq!(
        browser_open(&history),
        BrowserOpen::Open { url: Some("cmux://history".into()), engine: None }
    );
    let settings = BrowserOpenFacts {
        has_text: true,
        webkit: Some(Resolution {
            route: Some(PageRoute::BrowserSettings),
            ..resolved("chrome://settings/")
        }),
        ..Default::default()
    };
    assert_eq!(browser_open(&settings), BrowserOpen::BrowserSettings);
    let passwords = BrowserOpenFacts {
        has_text: true,
        webkit: Some(Resolution {
            route: Some(PageRoute::PasswordsPage),
            ..resolved("chrome://password-manager/")
        }),
        ..Default::default()
    };
    assert_eq!(browser_open(&passwords), BrowserOpen::PasswordsPage);
}

#[test]
fn text_that_is_no_url_or_an_agents_chromium_page_is_refused() {
    let words = BrowserOpenFacts { has_text: true, ..Default::default() };
    assert_eq!(browser_open(&words), BrowserOpen::Refuse { reason: BrowserRefusal::InvalidUrl });
    let agent = BrowserOpenFacts {
        has_text: true,
        engine: Some("cef".into()),
        agent: true,
        chromium: Some(Resolution { agent_refuses: true, ..resolved("chrome://settings/") }),
        ..Default::default()
    };
    assert_eq!(
        browser_open(&agent),
        BrowserOpen::Refuse { reason: BrowserRefusal::AgentChromiumPage }
    );
    // An explicit WebKit request reads the WebKit resolution, never Chromium's.
    let webkit =
        BrowserOpenFacts { engine: Some("webkit".into()), chromium: Some(resolved("x")), ..words };
    assert_eq!(browser_open(&webkit), BrowserOpen::Refuse { reason: BrowserRefusal::InvalidUrl });
}

#[test]
fn an_agents_tab_in_the_persons_pane_opens_behind() {
    let here = BrowserPlacementFacts { scripted: true, focused_here: true, ..Default::default() };
    assert_eq!(browser_placement(here), BrowserPlacement { background: true, agent_driven: true });
    let allowed = BrowserPlacementFacts { allows_view_change: true, ..here };
    assert!(!browser_placement(allowed).background);
    let beside = BrowserPlacementFacts {
        beside_caller: true,
        new_column_beside: true,
        ..Default::default()
    };
    assert_eq!(
        browser_placement(beside),
        BrowserPlacement { background: true, agent_driven: false }
    );
}

#[test]
fn reopen_on_the_other_engine() {
    let tab = ReopenFacts { is_browser: true, target: "cef".into(), ..Default::default() };
    assert_eq!(reopen(&tab), Reopen::Reopen);
    assert_eq!(reopen(&ReopenFacts { current: Some("cef".into()), ..tab.clone() }), Reopen::Same);
    assert_eq!(
        reopen(&ReopenFacts { chromium_unavailable: true, ..tab.clone() }),
        Reopen::Refuse(ReopenRefusal::ChromiumUnavailable)
    );
    assert_eq!(
        reopen(&ReopenFacts { is_browser: false, ..tab.clone() }),
        Reopen::Refuse(ReopenRefusal::NotABrowserTab)
    );
    let back =
        ReopenFacts { current: Some("cef".into()), target: "webkit".into(), proxied: true, ..tab };
    assert_eq!(reopen(&back), Reopen::Refuse(ReopenRefusal::ProxiedTabStaysInChromium));
    // An unknown engine tag is WebKit.
    assert_eq!(
        reopen(&ReopenFacts {
            current: Some("x".into()),
            target: "webkit".into(),
            proxied: false,
            ..back
        }),
        Reopen::Same
    );
}

#[test]
fn terminal_chat_routes_by_session_and_harness() {
    assert_eq!(
        terminal_chat(Some("Claude-Code"), Some(" s-1 ")),
        TerminalChat::Adopt { harness: "claude".into(), session: "s-1".into() }
    );
    assert_eq!(
        terminal_chat(Some("codex"), Some("abc")),
        TerminalChat::Adopt { harness: "codex".into(), session: "abc".into() }
    );
    assert_eq!(terminal_chat(Some("claude"), None), TerminalChat::NoSession);
    assert_eq!(terminal_chat(Some("claude"), Some("  ")), TerminalChat::NoSession);
    assert_eq!(terminal_chat(Some("opencode"), Some("x")), TerminalChat::UnsupportedHarness);
    assert_eq!(terminal_chat(None, Some("x")), TerminalChat::UnsupportedHarness);
    assert_eq!(harness(Some("claude_code")), Some("claude"));
}

#[test]
fn duplicate_leaves_page_tabs_alone() {
    let page = DuplicateFacts { local_page: true, ..Default::default() };
    assert_eq!(duplicate(&[page]), None);
    assert_eq!(duplicate(&[]), None);
    let browser_page = DuplicateFacts { browser: true, page: true, ..Default::default() };
    assert!(!is_page_tab(browser_page));
    let tabs = [
        browser_page,
        DuplicateFacts { local_browser: true, ..Default::default() },
        DuplicateFacts { agent: true, ..Default::default() },
        page,
        DuplicateFacts::default(),
    ];
    assert_eq!(
        duplicate(&tabs),
        Some(vec![
            Duplicate::Browser,
            Duplicate::LocalBrowser,
            Duplicate::Agent,
            Duplicate::Skip,
            Duplicate::Terminal
        ])
    );
}

#[test]
fn numbers_pick_tabs_and_panes() {
    assert_eq!(tab_by_number(1, 3), Some(0));
    assert_eq!(tab_by_number(5, 3), Some(2));
    assert_eq!(tab_by_number(9, 12), Some(11));
    assert_eq!(tab_by_number(0, 3), Some(0));
    assert_eq!(tab_by_number(1, 0), None);
    assert_eq!(pane_by_number(2, 3), Some(1));
    assert_eq!(pane_by_number(4, 3), None);
    assert_eq!(pane_by_number(0, 3), None);
    assert_eq!(pane_by_number(9, 3), Some(2));
    assert_eq!(pane_by_number(9, 0), None);
}

#[test]
fn move_to_split_reads_its_direction_and_the_chat_dock() {
    let right = MoveToSplitFacts::default();
    assert_eq!(move_to_split(&right), MoveToSplit::Split { edge: Edge::Right });
    let up = MoveToSplitFacts { direction: Some("up".into()), ..Default::default() };
    assert_eq!(move_to_split(&up), MoveToSplit::Split { edge: Edge::Top });
    let chat = MoveToSplitFacts {
        tabs_in_pane: 2,
        chat_dock: true,
        chat: true,
        dock_column: true,
        ..Default::default()
    };
    assert_eq!(move_to_split(&chat), MoveToSplit::ColumnAfterDock);
    // The dock refuses every other split: a lone docked chat, another edge, a tab not a chat.
    let lone = MoveToSplitFacts { tabs_in_pane: 1, ..chat.clone() };
    assert_eq!(move_to_split(&lone), MoveToSplit::Refuse);
    let left = MoveToSplitFacts { direction: Some("left".into()), ..chat };
    assert_eq!(move_to_split(&left), MoveToSplit::Refuse);
    let page = MoveToSplitFacts { chat: false, ..chat.clone() };
    assert_eq!(move_to_split(&page), MoveToSplit::Refuse);
    let group = MoveToSplitFacts { group: true, ..chat };
    assert_eq!(move_to_split(&group), MoveToSplit::Refuse);
}

#[test]
fn collapse_restart_icons_and_ids() {
    assert_eq!(group_collapse(None, false), Some(true));
    assert_eq!(group_collapse(Some(true), true), None);
    assert_eq!(group_collapse(Some(false), true), Some(false));
    assert_eq!(restart_refusal(RestartFacts { pty: true, dead: true, failed: false }), None);
    assert_eq!(restart_refusal(RestartFacts { pty: true, dead: false, failed: true }), None);
    assert_eq!(
        restart_refusal(RestartFacts { pty: true, ..Default::default() }),
        Some(RestartRefusal::TabNotDead)
    );
    assert_eq!(
        restart_refusal(RestartFacts { dead: true, ..Default::default() }),
        Some(RestartRefusal::NotATerminal)
    );
    assert_eq!(icon_undo(true, None, Some("star")), Some(IconUndo::Set));
    assert_eq!(icon_undo(true, Some("star"), None), Some(IconUndo::Remove));
    assert_eq!(icon_undo(true, Some("star"), Some("star")), None);
    assert_eq!(icon_undo(false, None, Some("star")), None);
    assert_eq!(
        workspace_id_text(&["ws_1".into(), "ws_2".into()], true),
        "workspace_ref=workspace:ws_1\nworkspace_id=ws_1\n\nworkspace_ref=workspace:ws_2\nworkspace_id=ws_2"
    );
    assert_eq!(workspace_id_text(&["ws_1".into()], false), "workspace_id=ws_1");
    assert_eq!(
        identifiers_text(Some("ws_1"), "p", "t"),
        "workspace_id=ws_1\npane_id=p\nsurface_id=t"
    );
    assert_eq!(identifiers_text(None, "p", "t"), "pane_id=p\nsurface_id=t");
}

#[test]
fn a_split_takes_the_explicit_then_home_then_the_split_tabs_folder() {
    let folders = SplitFolders {
        uninherited: None,
        inherited: Some("/work".into()),
        selected: Some("/sel".into()),
        first: Some("/first".into()),
        explicit: None,
    };
    let plan = panes::split(&SplitFacts {
        direction: Some(Direction::Left),
        folders: folders.clone(),
        ..Default::default()
    });
    assert_eq!(plan.action, SplitDo::Split);
    assert_eq!(plan.edge, Edge::Left);
    assert!(plan.horizontal);
    assert_eq!(plan.daemon_direction, Direction::Right);
    assert_eq!(plan.swap_towards, Some(Direction::Right));
    assert_eq!(plan.split_action, "splitLeft");
    assert_eq!(plan.cwd.as_deref(), Some("/work"));
    let home = SplitFolders { uninherited: Some("/home".into()), ..folders.clone() };
    let plan = panes::split(&SplitFacts {
        direction: Some(Direction::Down),
        folders: home,
        ..Default::default()
    });
    assert_eq!(
        (plan.cwd.as_deref(), plan.swap_towards, plan.horizontal),
        (Some("/home"), None, false)
    );
    let none = SplitFolders { inherited: None, ..folders };
    let plan =
        panes::split(&SplitFacts { folders: none, tool: ToolSplit::Tab, ..Default::default() });
    assert_eq!(
        (plan.action, plan.cwd.as_deref(), plan.tab_cwd),
        (SplitDo::StripTerminal, Some("/sel"), None)
    );
}

#[test]
fn a_persons_split_of_a_page_opens_the_new_tab_page() {
    let page = SplitFacts { page: true, shown: true, ..Default::default() };
    assert_eq!(panes::split(&page).action, SplitDo::PageSplit);
    assert_eq!(panes::split(&SplitFacts { shown: false, ..page.clone() }).action, SplitDo::Split);
    assert_eq!(
        panes::split(&SplitFacts { tool: ToolSplit::Tab, ..page.clone() }).action,
        SplitDo::StripPage
    );
    let dock = panes::split(&SplitFacts {
        tool: ToolSplit::BesideDock,
        direction: Some(Direction::Up),
        ..page.clone()
    });
    assert_eq!((dock.action, dock.edge), (SplitDo::DockPage, Edge::Right));
    assert_eq!(
        panes::split(&SplitFacts { tool: ToolSplit::BesideDock, ..Default::default() }).action,
        SplitDo::DockColumn
    );
    assert_eq!(
        panes::split(&SplitFacts { tool: ToolSplit::Refused, ..page }).action,
        SplitDo::Refuse
    );
}

#[test]
fn auto_layout_splits_the_longer_side_with_room() {
    let wide = AutoFacts { width: 800.0, height: 400.0, room_right: true, room_down: true };
    assert_eq!(panes::auto_direction(wide).fitting, Some(Direction::Right));
    let tall = AutoFacts { width: 400.0, height: 800.0, ..wide };
    assert_eq!(panes::auto_direction(tall).preferred, Direction::Down);
    let only_down = AutoFacts { room_right: false, ..wide };
    assert_eq!(panes::auto_direction(only_down).fitting, Some(Direction::Down));
    let none = AutoFacts { room_right: false, room_down: false, ..wide };
    assert_eq!(panes::auto_direction(none).fitting, None);
    let tie = AutoFacts { width: 500.0, height: 500.0, ..wide };
    assert_eq!(panes::auto_direction(tie).preferred, Direction::Right);
}

#[test]
fn tab_bar_refusals() {
    let app = panes::tab_bar(TabBarFacts { app_pane: true, ..Default::default() });
    assert_eq!(
        (app.toggle, app.new_tab),
        (Some(TabBarRefusal::AppPaneHasNoTabBar), Some(TabBarRefusal::AppPaneHasNoTabBar))
    );
    let chief = panes::tab_bar(TabBarFacts { pinned_dock: true, ..Default::default() });
    assert_eq!((chief.toggle, chief.new_tab), (None, Some(TabBarRefusal::ChiefPaneHasNoTabBar)));
    let home = panes::tab_bar(TabBarFacts {
        pinned_dock: true,
        pinned_dock_hides_tab_bar: true,
        ..Default::default()
    });
    assert_eq!(home.toggle, Some(TabBarRefusal::ChiefPaneHasNoTabBar));
    let plain = panes::tab_bar(TabBarFacts::default());
    assert_eq!((plain.toggle, plain.new_tab), (None, None));
}

#[test]
fn terminal_tables() {
    assert_eq!(panes::TERMINAL_BINDINGS.len(), 9);
    assert_eq!(panes::clear_failure_kind("error: not connected to host"), "not connected");
    assert_eq!(panes::clear_failure_kind("/Users/x/secret"), "other");
    assert_eq!(panes::shell_quoted("/tmp/it's here.png"), "'/tmp/it'\\''s here.png'");
}
