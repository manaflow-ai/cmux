//! W1-B: the attention queue the TUI builds from its tree and agent roster,
//! and what the host notification gate learns from the App (is the tab
//! drawn, does the host window have focus, does the TUI show its own host).

use super::*;
use crate::app::attention_jump::tree_attention_entries;
use crate::host_notify::{HostNotifyGate, HostTerminal, HostTerminalInfo};
use crate::session::AgentInfo;
use crate::session::tree::TabAttentionView;
use cmux_tui_core::resource::TerminalPublicId;

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

/// A BEL in a hidden tab: the daemon posts it as a `Bell` notification with
/// `desktop: false` (`post_bell_notification`), which is the one event the
/// App forwards. With `notifications.bell` on, the gate answers a bare BEL
/// for a tab the person cannot see, and nothing for the tab they look at.
#[test]
fn attention_a_hidden_tabs_bell_rings_the_host_bell_only_when_configured() {
    let mux = Mux::new("attention-host-bell-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(attention_tree());
    app.pane_areas = vec![browser_completion_area(41)];
    let bell = |surface| crate::host_notify::HostNotifyRequest {
        surface,
        title: "Bell",
        body: "",
        desktop: false,
    };
    let now = Instant::now();
    let mut config = app.config.notifications;
    assert!(!config.bell, "the host bell is off by default");
    let context = app.host_notify_context(42);
    assert_eq!(app.host_notify.decide(config, &bell(42), context, now), None);
    config.bell = true;
    assert_eq!(app.host_notify.decide(config, &bell(42), context, now), Some(vec![0x07]));
    let seen = app.host_notify_context(41);
    let later = now + Duration::from_secs(10);
    assert_eq!(app.host_notify.decide(config, &bell(41), seen, later), None);
}
