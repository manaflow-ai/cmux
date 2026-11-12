//! The attention queue the TUI builds from its tree and agent roster, the
//! attention list, and what the host notification gate learns from the App
//! (is the tab drawn, does the host window have focus, does the TUI show its
//! own host).

use std::time::{Duration, Instant};

use super::*;
use crate::app::attention_jump::tree_attention_entries;
use crate::app::{AppEvent, MenuAction, MenuItem};
use crate::config::{Action, Keys};
use crate::host_notify::{HostNotifyGate, HostTerminal, HostTerminalInfo};
use crate::session::tree::TabNotificationView;
use crate::session::{AgentInfo, Session, TreeView};
use cmux_tui_core::resource::TerminalPublicId;
use cmux_tui_core::{
    Mux, MuxEvent, NotificationEvent, NotificationLevel, SurfaceId, SurfaceOptions,
};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};

const HOST_TERMINAL: &str = "term_aa2748091e24db727232dab348e2f19b";

/// `notify_tree(41, true)` (an unread warning) plus tab 42 (an older unread
/// info notification) and tab 43 (an agent the roster shows blocked), all in
/// one pane.
fn attention_tree() -> TreeView {
    let base = notify_tree(41, true);
    let mut workspace = base.workspaces()[0].clone();
    let first = workspace.screens[0].panes[0].tabs[0].clone();
    let mut finished = first.clone();
    finished.surface = 42;
    finished.name = Some("build".into());
    finished.notification = Some(TabNotificationView { unread: true, level: "info", sequence: 0 });
    let mut blocked = first;
    blocked.surface = 43;
    blocked.notification = None;
    blocked.terminal_id = TerminalPublicId::parse(HOST_TERMINAL.to_string()).ok();
    workspace.screens[0].panes[0].tabs.extend([finished, blocked]);
    TreeView::from_parts(vec![workspace], 0, Some(1), 0)
}

fn blocked_agent(surface: SurfaceId, updated_at_ms: u64) -> AgentInfo {
    AgentInfo {
        surface,
        state: "blocked".into(),
        source: "hook".into(),
        session: None,
        agent: Some("claude".into()),
        updated_at_ms,
    }
}

#[test]
fn attention_entries_put_blocked_tabs_first_then_warnings_then_unread_ones() {
    let tree = attention_tree();
    let entries = tree_attention_entries(&tree, &[blocked_agent(43, 100)]);
    let order: Vec<_> = entries.iter().map(|entry| entry.candidate.key).collect();
    assert_eq!(order, vec![43, 41, 42], "must-act first, then the warning, then info");
    assert_eq!(entries[2].tab, "build");
    assert_eq!(entries[0].workspace, "work");

    // An agent that is not blocked adds nothing.
    let mut working = blocked_agent(43, 1);
    working.state = "working".into();
    let order: Vec<_> =
        tree_attention_entries(&tree, &[working]).iter().map(|e| e.candidate.key).collect();
    assert_eq!(order, vec![41, 42]);
    // An agent on a tab outside the tree is not listed.
    let order: Vec<_> = tree_attention_entries(&tree, &[blocked_agent(99, 1)])
        .iter()
        .map(|e| e.candidate.key)
        .collect();
    assert_eq!(order, vec![41, 42]);
}

#[test]
fn attention_list_opens_a_searchable_menu_with_one_row_per_tab() {
    let mux = Mux::new("attention-list-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());

    app.run_action(Action::AttentionList).unwrap();
    let menu = app.menu.as_ref().expect("the attention list opens");
    assert!(menu.search.is_some(), "the list is searchable");
    let actions: Vec<_> = menu.levels[0].items.iter().filter_map(MenuItem::action).collect();
    assert_eq!(actions, vec![MenuAction::FocusAttention(41), MenuAction::FocusAttention(42)]);
    let labels: Vec<_> = menu.levels[0].items.iter().filter_map(MenuItem::label).collect();
    assert!(labels[1].starts_with("• work › build"), "{labels:?}");

    // Nothing needs the person: a toast, no menu.
    app.menu = None;
    app.replace_tree(notify_tree(41, false));
    app.run_action(Action::AttentionList).unwrap();
    assert!(app.menu.is_none());
    assert!(app.toast.is_some());
}

/// The list was opened, then the chosen tab closed: Enter in the list
/// reaches the focus path, which says so.
#[test]
fn attention_list_enter_on_a_tab_that_closed_shows_a_toast() {
    let mux = Mux::new("attention-list-gone-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    app.run_action(Action::AttentionList).unwrap();
    assert!(app.menu.is_some());
    let mut closed = attention_tree();
    for tab in &mut closed.workspaces_mut()[0].screens[0].panes[0].tabs {
        tab.surface += 100;
    }
    app.replace_tree(closed);
    app.toast = None;
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE))))
        .unwrap();
    assert!(app.menu.is_none(), "Enter closes the list");
    assert!(app.toast.is_some(), "a vanished tab is not a silent no-op");
}

/// `next-attention` through the action dispatch: nothing needs the person,
/// so a toast says so and focus stays.
#[test]
fn attention_next_key_with_an_empty_queue_shows_a_toast() {
    let mux = Mux::new("attention-next-empty-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(notify_tree(41, false));
    app.toast = None;
    app.run_action(Action::NextAttention).unwrap();
    assert!(app.toast.is_some());
    assert!(app.menu.is_none());
}

#[test]
fn attention_keys_default_to_prefix_a_and_shift_a() {
    let keys = Keys::default();
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE)),
        Some(Action::NextAttention)
    );
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('A'), KeyModifiers::SHIFT)),
        Some(Action::AttentionList)
    );
}

#[test]
fn attention_host_context_follows_drawn_panes_host_focus_and_the_own_host_terminal() {
    let mux = Mux::new("attention-host-context-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    app.pane_areas = vec![browser_completion_area(41)];

    let drawn = app.host_notify_context(41);
    assert!(drawn.attached && drawn.tab_drawn && drawn.host_focused);
    assert!(!drawn.own_host_terminal && !drawn.session_hosts_tui);
    assert!(!app.host_notify_context(42).tab_drawn, "a background tab is not seen");

    app.handle(AppEvent::Input(Event::FocusLost)).unwrap();
    assert!(!app.host_notify_context(41).host_focused);
    app.handle(AppEvent::Input(Event::FocusGained)).unwrap();
    assert!(app.host_notify_context(41).host_focused);

    // The TUI runs in a cmux terminal that its own session shows (tab 43):
    // that session's clients already show its notifications.
    app.host_notify = HostNotifyGate::new(HostTerminalInfo {
        terminal: HostTerminal::Cmux,
        multiplexed: false,
        cmux_terminal: Some(HOST_TERMINAL.to_string()),
    });
    let hosted = app.host_notify_context(42);
    assert!(hosted.session_hosts_tui && !hosted.own_host_terminal);
    assert!(app.host_notify_context(43).own_host_terminal);
}

/// A daemon notification as the App receives it (`MuxEvent::Notification`).
fn daemon_notification(surface: SurfaceId, title: &str) -> NotificationEvent {
    NotificationEvent {
        notification: 7,
        title: title.to_string(),
        body: String::new(),
        level: NotificationLevel::Info,
        surface: Some(surface),
    }
}

/// A BEL in a hidden tab reaches the App as `MuxEvent::Bell`. The App passes
/// it on as a bare BEL only with `notifications.bell` on, only for a tab the
/// person cannot see; a real notification gets the host's banner.
#[test]
fn attention_a_hidden_tabs_bell_rings_the_host_bell_only_when_configured() {
    let mux = Mux::new("attention-host-bell-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    app.pane_areas = vec![browser_completion_area(41)];
    let now = Instant::now();

    assert!(!app.config.notifications.bell, "the host bell is off by default");
    assert_eq!(app.host_bell_bytes(42, now), None);
    app.config.notifications.bell = true;
    assert_eq!(app.host_bell_bytes(42, now), Some(vec![0x07]));
    let later = now + Duration::from_secs(10);
    assert_eq!(app.host_bell_bytes(41, later), None, "the tab the person looks at");
    app.config.notifications.bell = false;
    let done = app.host_notification_bytes(&daemon_notification(43, "bench done"), later);
    assert_eq!(done.as_deref(), Some(&b"\x1b]777;notify;bench done;\x07"[..]));
}

/// The App's event loop passes a daemon notification for a hidden tab to
/// the host gate (the write starts that tab's rate limit).
#[test]
fn attention_notification_event_reaches_the_host_gate_through_the_event_loop() {
    let mux = Mux::new("attention-host-event-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    app.pane_areas = vec![browser_completion_area(41)];
    // The App writes to the real stdout: a bare BEL, no desktop banner.
    app.config.notifications.desktop = crate::host_notify::DesktopNotifyMode::Off;
    app.config.notifications.bell = true;

    app.handle(AppEvent::Mux(MuxEvent::Notification(daemon_notification(43, "hidden")))).unwrap();
    let later = Instant::now() + Duration::from_secs(2);
    assert_eq!(
        app.host_notification_bytes(&daemon_notification(43, "again"), later),
        None,
        "tab 43 waits out its five seconds"
    );
    assert!(app.host_notification_bytes(&daemon_notification(42, "other"), later).is_some());
}
