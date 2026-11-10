//! Tests: a terminal tab shows its title's text (D2). The daemon announces no
//! spinner frame of the same text, so a tab that showed the raw title would
//! keep the first frame (`⠂ Task`) while the agent works.

use super::*;

#[test]
fn a_title_event_shows_its_text_not_the_spinner_frame() {
    let mux = Mux::new("tab-title-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(browser_completion_tree(41, 42));
    let (tx, rx) = crossbeam_channel::bounded(4);
    let tx = SessionEventSender::unscoped(tx);
    let event = MuxEvent::terminal_title(41, "⠂ Fix the login bug".into());

    assert!(matches!(forward_mux_event(event, &tx, &app.mux_titles), ForwardMuxOutcome::Continue));
    assert!(matches!(app.handle(rx.recv().unwrap()).unwrap(), RenderAction::Paint));
    assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "Fix the login bug");
}

#[test]
fn a_tree_tab_shows_its_title_text_and_an_old_daemons_terminal_title_loses_its_glyphs() {
    let tree = crate::session::tree::parse_tree(&serde_json::json!({
        "workspaces": [{"id": 1, "active": true, "screens": [{"id": 2, "layout": {"type": "leaf", "pane": 3}, "panes": [{"id": 3, "tabs": [
            {"surface": 4, "kind": "pty", "title": "⠐ Fix it", "title_text": "Fix it", "title_activity": "working"},
            {"surface": 5, "kind": "pty", "title": "✳ Run tests"},
            {"surface": 6, "kind": "browser", "title": "● Slack | general"}
        ]}]}]}]
    }));
    let titles: Vec<&str> = tree.workspaces()[0].screens[0].panes[0]
        .tabs
        .iter()
        .map(|tab| tab.title.as_str())
        .collect();
    assert_eq!(titles, ["Fix it", "Run tests", "● Slack | general"]);
}
