//! W1-B: the attention queue the TUI builds from its tree and agent roster,
//! and what the host notification gate learns from the App (is the tab
//! drawn, does the host window have focus, does the TUI show its own host).

use super::*;
use crate::app::attention_jump::tree_attention_entries;
use crate::host_notify::{HostNotifyGate, HostTerminal, HostTerminalInfo};
use crate::session::AgentInfo;
use crate::session::tree::TabAttentionView;
use cmux_tui_core::resource::TerminalPublicId;
use cmux_tui_core::{NotificationEvent, NotificationLevel};

const HOST_TERMINAL: &str = "term_aa2748091e24db727232dab348e2f19b";

/// `notify_tree(41, true)` plus tab 42 (an agent's request) and tab 43 (an
/// agent the roster shows blocked), all in one pane.
fn attention_tree() -> TreeView {
    let base = notify_tree(41, true);
    let mut workspace = base.workspaces()[0].clone();
    let first = workspace.screens[0].panes[0].tabs[0].clone();
    let mut requested = first.clone();
    requested.surface = 42;
    requested.notification = None;
    requested.name = Some("release".into());
    requested.attention = Some(TabAttentionView { reason: "approve deploy".into(), at_ms: 500 });
    let mut blocked = first;
    blocked.surface = 43;
    blocked.notification = None;
    blocked.terminal_id = TerminalPublicId::parse(HOST_TERMINAL.to_string()).ok();
    workspace.screens[0].panes[0].tabs.extend([requested, blocked]);
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
fn attention_entries_put_blocked_and_requested_tabs_before_unread_ones() {
    let tree = attention_tree();
    let entries = tree_attention_entries(&tree, &[blocked_agent(43, 100)]);
    let order: Vec<_> = entries.iter().map(|entry| entry.candidate.key).collect();
    assert_eq!(order, vec![43, 42, 41], "oldest must-act first, then unread");
    assert_eq!(entries[1].reason.as_deref(), Some("approve deploy"));
    assert_eq!(entries[1].tab, "release");
    assert_eq!(entries[0].workspace, "work");

    // A roster that is not blocked adds nothing; a later block sorts after
    // the older request.
    let entries = tree_attention_entries(&tree, &[blocked_agent(43, 900)]);
    let order: Vec<_> = entries.iter().map(|entry| entry.candidate.key).collect();
    assert_eq!(order, vec![42, 43, 41]);
    let mut working = blocked_agent(43, 1);
    working.state = "working".into();
    let order: Vec<_> =
        tree_attention_entries(&tree, &[working]).iter().map(|e| e.candidate.key).collect();
    assert_eq!(order, vec![42, 41]);
}

/// One key as a Kitty-protocol host reports it with associated text only:
/// the unshifted key code, the given modifiers, and `text`.
fn reported_text_key(
    code: char,
    modifiers: KeyModifiers,
    text: &str,
) -> crate::keys::KeyboardInput {
    crate::keys::KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char(code), modifiers),
        shifted_key: None,
        base_layout_key: None,
        text: text.to_string(),
    })
}

/// W6-D (bench r5 #5): the cmux app sends `A` after the prefix as
/// `CSI 97;;65u` (key `a`, no Shift, text `A`), as a Caps Lock press also
/// reports it. That key is the character `A`: `Ctrl-b A` opens the "Needs
/// you" list and does not jump like `Ctrl-b a`.
#[test]
fn w6d_prefix_then_a_reported_as_text_opens_the_needs_you_list() {
    let mux = Mux::new("w6d-attention-list-text-key", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    let before = app.active_surface();

    app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
    app.handle_keyboard(reported_text_key('a', KeyModifiers::NONE, "A")).unwrap();

    assert!(app.menu.is_some(), "Ctrl-b A must open the Needs you list");
    assert_eq!(app.active_surface(), before, "the list must not jump to a tab");
    assert!(!app.prefix_armed);
}

/// The same text-only report resolves every printable binding by the
/// character the person typed; a plain `a` (text `a`) stays `a`, and a
/// Ctrl chord keeps its key (its text is not the typed character).
#[test]
fn w6d_text_only_key_reports_resolve_bindings_by_the_typed_character() {
    let keys = Config::default().keys;
    let resolve = |input: crate::keys::KeyboardInput| {
        let (key, fallback) = input.shortcut_keys();
        crate::app::action_for_binding(&keys, &key, fallback.as_ref())
    };
    assert_eq!(
        resolve(reported_text_key('a', KeyModifiers::NONE, "A")),
        Some(Action::AttentionList)
    );
    assert_eq!(
        resolve(reported_text_key('a', KeyModifiers::NONE, "a")),
        Some(Action::NextAttention)
    );
    assert_eq!(
        resolve(reported_text_key('s', KeyModifiers::NONE, "S")),
        Some(Action::FocusSidebar)
    );
    assert_eq!(
        resolve(reported_text_key('/', KeyModifiers::NONE, "?")),
        Some(Action::ShowShortcuts)
    );
    assert_eq!(
        resolve(reported_text_key('k', KeyModifiers::CONTROL, "K")),
        resolve(crate::keys::KeyboardInput::from(KeyEvent::new(
            KeyCode::Char('k'),
            KeyModifiers::CONTROL
        ))),
        "a Ctrl chord resolves by its key, not its text"
    );
}

/// W5-Q (bench r4 #5): the TUI's queue puts a finished agent turn nobody
/// viewed (an idle agent with an unread notification) before an older bell,
/// as `cmux attention list` does.
#[test]
fn w5q_tui_attention_puts_a_finished_agent_turn_before_a_bell() {
    let base = notify_tree(41, true);
    let mut workspace = base.workspaces()[0].clone();
    let mut finished = workspace.screens[0].panes[0].tabs[0].clone();
    finished.surface = 44;
    finished.name = Some("pong".into());
    finished.notification = Some(TabNotificationView { unread: true, level: "info", sequence: 9 });
    workspace.screens[0].panes[0].tabs[0].notification =
        Some(TabNotificationView { unread: true, level: "info", sequence: 2 });
    workspace.screens[0].panes[0].tabs.push(finished);
    let tree = TreeView::from_parts(vec![workspace], 0, Some(1), 0);
    let mut idle = blocked_agent(44, 50);
    idle.state = "idle".into();
    let entries = tree_attention_entries(&tree, &[idle]);
    let order: Vec<_> = entries.iter().map(|entry| entry.candidate.key).collect();
    assert_eq!(order, vec![44, 41], "the finished turn first, then the older bell");
    assert_eq!(entries[0].candidate.kind, crate::attention::AttentionKind::Done);
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
fn daemon_notification(surface: SurfaceId, title: &str, desktop: bool) -> NotificationEvent {
    NotificationEvent {
        id: None,
        message: None,
        prompt: None,
        session: None,
        notification: 7,
        title: title.to_string(),
        subtitle: None,
        body: String::new(),
        preview: None,
        question: None,
        level: NotificationLevel::Info,
        surface: Some(surface),
        workspace_id: None,
        source: cmux_tui_core::NotificationSource::Terminal,
        desktop,
        reply: false,
    }
}

/// A BEL in a hidden tab reaches the App as the daemon's `Bell` notification
/// with `desktop: false` (core `attention_a_bell_posts_one_notification_event_…`,
/// remote `attention_a_daemon_bell_arrives_as_a_bannerless_terminal_notification`).
/// The App passes it on as a bare BEL only with `notifications.bell` on, only for
/// a tab the person cannot see; a real notification gets the host's banner.
#[test]
fn attention_a_hidden_tabs_bell_rings_the_host_bell_only_when_configured() {
    let mux = Mux::new("attention-host-bell-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    app.pane_areas = vec![browser_completion_area(41)];
    let now = Instant::now();
    let bell = daemon_notification(42, "Bell", false);

    assert!(!app.config.notifications.bell, "the host bell is off by default");
    assert_eq!(app.host_notification_bytes(&bell, now), None);
    app.config.notifications.bell = true;
    assert_eq!(app.host_notification_bytes(&bell, now), Some(vec![0x07]));
    let later = now + Duration::from_secs(10);
    assert_eq!(
        app.host_notification_bytes(&daemon_notification(41, "Bell", false), later),
        None,
        "the tab the person looks at"
    );
    app.config.notifications.bell = false;
    let done = app.host_notification_bytes(&daemon_notification(43, "bench done", true), later);
    assert_eq!(done.as_deref(), Some(&b"\x1b]777;notify;bench done;\x07"[..]));
}

/// Two panes: the person's shell (first, focused in the session) and an
/// agent split beside it that the roster shows blocked.
struct AgentBeside {
    mux: Arc<Mux>,
    person: SurfaceId,
    person_pane: cmux_tui_core::PaneId,
    agent: SurfaceId,
    agent_pane: cmux_tui_core::PaneId,
}

fn blocked_agent_beside_the_person(name: &str) -> AgentBeside {
    let (mux, person) = test_mux(name, None);
    let person_pane = mux.with_state(|state| state.pane_of(person.id).unwrap());
    let agent = mux.split(person_pane, SplitDir::Right, Some((20, 8))).unwrap();
    let agent_pane = mux.with_state(|state| state.pane_of(agent.id).unwrap());
    assert!(mux.focus_pane_as(&cmux_tui_core::Actor::Daemon, person_pane));
    mux.report_agent(agent.id, AgentState::Blocked, AgentSource::Hook, Some("s1".into())).unwrap();
    AgentBeside { mux, person: person.id, person_pane, agent: agent.id, agent_pane }
}

fn close_all(mux: &Arc<Mux>) {
    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

/// W6-D (bench r5 #5): with one blocked agent, `Ctrl-b a` moved the TUI's
/// view only: `pane list` / `tab list` still said the person's pane had
/// focus, and the screen said nothing. The jump is the person's explicit
/// focus request, as `cmux attention next --focus`: it moves the session's
/// focus to the agent's tab (what `pane list` reports) and a toast names
/// the tab and why it needs the person.
#[test]
fn w6d_attention_jump_moves_the_session_focus_and_says_where_it_went() {
    let AgentBeside { mux, person, person_pane, agent, agent_pane } =
        blocked_agent_beside_the_person("w6d-attention-jump-session-focus");
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    assert_eq!(app.active_surface(), Some(person));

    app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE)).unwrap();

    let shared = mux.with_state(|state| state.active_pane());
    let toast = app.toast.as_ref().map(|toast| toast.text.clone()).unwrap_or_default();
    close_all(&mux);
    assert_eq!(app.active_surface(), Some(agent), "the TUI shows the agent");
    assert_eq!(shared, Some(agent_pane), "the session focus (pane list) moved from {person_pane}");
    let messages = &localization::catalog().attention;
    assert!(
        toast.contains(messages.needs_you) && toast.contains(messages.blocked),
        "the toast must say where the jump went and why: {toast:?}"
    );
}

/// A row picked in the "Needs you" list takes the same path as the key.
#[test]
fn w6d_attention_list_row_moves_the_session_focus() {
    let AgentBeside { mux, agent, agent_pane, .. } =
        blocked_agent_beside_the_person("w6d-attention-list-session-focus");
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    app.activate_menu(MenuAction::FocusAttention(agent)).unwrap();

    let shared = mux.with_state(|state| state.active_pane());
    close_all(&mux);
    assert_eq!(app.active_surface(), Some(agent));
    assert_eq!(shared, Some(agent_pane), "the list row must move the session focus");
}
