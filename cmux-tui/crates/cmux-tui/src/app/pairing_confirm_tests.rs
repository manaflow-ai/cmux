use std::time::Duration;

use cmux_tui_core::{Mux, MuxEvent, SurfaceOptions};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::Terminal;
use ratatui::backend::TestBackend;

use super::super::tests::test_app;
use super::super::{AppEvent, Session};

#[test]
fn enter_does_not_approve_a_rendered_pairing_dialog() {
    // A dialog can appear while the user types in a terminal; the Enter
    // that ends their command line must not admit a browser. Approval is
    // an explicit `y` (or the Approve button).
    let mux = Mux::new("pairing-explicit-confirm-test", SurfaceOptions::default());
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let mut app = test_app(Session::Local(mux));
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    app.render_action(&mut terminal, action).unwrap();

    for (code, modifiers) in [
        (KeyCode::Enter, KeyModifiers::NONE),
        (KeyCode::Char(' '), KeyModifiers::NONE),
        (KeyCode::Char('y'), KeyModifiers::CONTROL),
        (KeyCode::Char('y'), KeyModifiers::ALT),
        (KeyCode::Char('y'), KeyModifiers::SUPER),
    ] {
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(code, modifiers)))).unwrap();
        assert_eq!(
            app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id),
            Some(challenge.id),
            "{code:?} {modifiers:?} closed the pairing dialog"
        );
        assert!(decision.try_recv().is_err(), "{code:?} {modifiers:?} approved a pairing request");
    }

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE))))
        .unwrap();
    assert!(app.pairing_dialog.is_none());
    assert!(matches!(
        decision.recv_timeout(Duration::from_secs(1)),
        Ok(cmux_tui_core::PairingDecision::Approved { .. })
    ));
}

#[test]
fn an_attached_tui_offers_no_approve_it_cannot_perform() {
    // Only the TUI that runs the daemon (or the verified app) may approve
    // a pairing (cx-ehrq). An attached TUI must not show an Approve that
    // always fails, and `y` must not try it.
    let mux = Mux::new("pairing-remote-deny-only-test", SurfaceOptions::default());
    let (challenge, _decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let mut app = test_app(crate::session::test_remote_session_without_provider_authority());
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    app.render_action(&mut terminal, action).unwrap();

    let screen = format!("{:?}", terminal.backend().buffer());
    assert!(!screen.contains("Approve y"), "an attached TUI drew Approve");
    let dialog = app.pairing_dialog.as_ref().expect("dialog shown");
    assert_eq!(dialog.approve.width, 0, "the Approve hit area must be empty");

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(
        app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id),
        Some(challenge.id),
        "y on an attached TUI must leave the dialog for a human surface"
    );
}
