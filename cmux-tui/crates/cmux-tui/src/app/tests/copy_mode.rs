//! Tests: keyboard copy mode through the App's real key path (prefix entry,
//! search, line yank to the surface selection, return to the live bottom),
//! its mode line, and the page scroll actions.

use super::*;
use crate::app::KeyboardIngress;
use crate::config::Action;
use crate::localization;
use crate::session::Session;

/// Drain session mutation settlements, as main's other App tests do.
fn settle_pending_mutations(app: &mut App, events: &Receiver<AppEvent>) {
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    }
}

fn key(c: char) -> KeyEvent {
    KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
}

fn prefix() -> KeyEvent {
    KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)
}

fn numbered_lines(count: usize) -> String {
    (1..=count).map(|n| format!("{n}\r\n")).collect()
}

fn bottom_offset(app: &App, surface: SurfaceId) -> u64 {
    let scrollbar = app.session.surface(surface).unwrap().scrollbar().unwrap();
    scrollbar.total - scrollbar.len
}

#[test]
fn copy_mode_prefix_search_line_yank_copies_and_returns_to_the_bottom() {
    let (mux, surface) = test_mux("copy-mode-yank-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(numbered_lines(60).as_bytes()));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let bottom = bottom_offset(&app, surface.id);

    app.handle_key(prefix()).unwrap();
    app.handle_key(key('[')).unwrap();
    assert!(app.copy_mode_active(), "prefix [ enters copy mode");
    for c in "/43".chars() {
        app.handle_key(key(c)).unwrap();
    }
    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    let line = app.copy_mode_line().unwrap();
    assert_eq!(line.search, Some(('/', "43".to_string(), "1/1".to_string())));
    assert!(app.surface_scroll_offset(surface.id) < bottom, "the view moved to the match");

    app.handle_key(key('V')).unwrap();
    assert_eq!(
        app.copy_mode_line().unwrap().mode,
        localization::catalog().copy_mode.mode_visual_line
    );
    app.handle_key(key('y')).unwrap();
    assert!(!app.copy_mode_active(), "yank leaves copy mode");
    assert_eq!(surface.selection_text().as_deref(), Some("43"));
    assert_eq!(
        app.surface_scroll_offset(surface.id),
        bottom,
        "leaving copy mode returns to the bottom"
    );
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn copy_mode_swallows_unbound_keys_and_keeps_prefix_commands() {
    let (mux, surface) = test_mux("copy-mode-swallow-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"hello"));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.run_action(Action::CopyMode).unwrap();
    assert!(app.copy_mode_active());

    let routed = app.resolve_keyboard_ingress(key('z').into());
    assert!(matches!(routed, KeyboardIngress::Handled(_)), "copy mode never types into the shell");
    let routed = app.resolve_keyboard_ingress(prefix().into());
    assert!(matches!(routed, KeyboardIngress::Handled(_)));
    assert!(app.prefix_armed, "the prefix still arms in copy mode");
    let routed = app.resolve_keyboard_ingress(key('?').into());
    assert!(
        matches!(
            routed,
            KeyboardIngress::Routed(TerminalInput::FrontendAction {
                action: Action::ShowShortcuts,
                ..
            })
        ),
        "a prefixed key runs its action, not a copy-mode command"
    );
    assert!(app.copy_mode_active());

    app.focus = FocusTarget::WorkspaceRail;
    assert!(app.copy_mode_line().is_none(), "the mode line follows focus off the terminal");
    app.focus = FocusTarget::Pane;
    assert!(app.copy_mode_line().is_some());

    app.handle_key(key('q')).unwrap();
    assert!(!app.copy_mode_active());
    let routed = app.resolve_keyboard_ingress(key('z').into());
    assert!(matches!(routed, KeyboardIngress::Routed(TerminalInput::Keyboard(_))));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn search_scrollback_opens_the_prompt_and_the_mode_line_shows_it() {
    let (mux, surface) = test_mux("copy-mode-search-line-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(numbered_lines(30).as_bytes()));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((40, 12));
    settle_pending_mutations(&mut app, &events);

    app.handle_key(prefix()).unwrap();
    app.handle_key(key('/')).unwrap();
    let line = app.copy_mode_line().expect("prefix / enters copy mode");
    assert_eq!(line.prompt, Some(('?', String::new())), "it opens a backward search");
    app.handle_key(key('2')).unwrap();
    app.handle_key(key('5')).unwrap();

    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let buffer = terminal.backend().buffer();
    let status: String = (0..40).map(|x| buffer[(x, 11)].symbol()).collect();
    assert!(status.contains(localization::catalog().copy_mode.mode_copy), "{status:?}");
    assert!(status.contains("?25"), "{status:?}");

    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let buffer = terminal.backend().buffer();
    let status: String = (0..40).map(|x| buffer[(x, 11)].symbol()).collect();
    assert!(status.contains("?25 1/1"), "{status:?}");
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn page_scroll_actions_move_by_the_visible_rows() {
    let (mux, surface) = test_mux("copy-mode-page-scroll-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(numbered_lines(60).as_bytes()));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let rows = app.session.surface(surface.id).unwrap().scrollbar().unwrap().len;
    let bottom = bottom_offset(&app, surface.id);

    app.handle_key(prefix()).unwrap();
    app.handle_key(KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.surface_scroll_offset(surface.id), bottom - rows);
    app.run_action(Action::ScrollHalfPageDown).unwrap();
    assert_eq!(app.surface_scroll_offset(surface.id), bottom - rows + rows / 2);
    app.run_action(Action::ScrollPageDown).unwrap();
    assert_eq!(app.surface_scroll_offset(surface.id), bottom);
    assert!(!app.copy_mode_active(), "page scrolling is not copy mode");
    mux.close_surface(surface.id).unwrap();
}
