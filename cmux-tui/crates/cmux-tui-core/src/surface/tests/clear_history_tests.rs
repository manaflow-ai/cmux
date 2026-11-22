use super::*;

#[test]
fn clear_history_preserves_alternate_screen_and_primary_history() {
    let mux = Mux::new_for_test("clear-alternate-screen", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let primary_history_rows = surface
        .with_terminal(|term| {
            for line in 0..40 {
                term.vt_write(format!("primary-{line}\r\n").as_bytes());
            }
            term.vt_write(b"primary-tail");
            let history_rows = term.history_rows();
            term.vt_write(b"\x1b[?1049h");
            term.vt_write(b"alternate-app");
            assert_eq!(term.active_screen(), Screen::Alternate);
            history_rows
        })
        .unwrap();

    surface.clear_history().unwrap();

    surface.with_terminal(|term| {
        assert_eq!(term.active_screen(), Screen::Alternate);
        assert!(term.viewport_text().unwrap().contains("alternate-app"));
        term.vt_write(b"\x1b[?1049l");
        assert_eq!(term.active_screen(), Screen::Primary);
        assert_eq!(term.history_rows(), primary_history_rows);
        assert!(term.viewport_text().unwrap().contains("primary-tail"));
    });
}
