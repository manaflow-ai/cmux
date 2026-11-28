use super::*;

fn b(x: f64, y: f64, width: f64, height: f64) -> Bounds {
    Bounds { x, y, width, height }
}

fn cand() -> Candidate {
    Candidate {
        id: 42,
        title: Some("Notes".into()),
        layer: 0,
        on_screen: true,
        pid: 500,
        bundle: Some("com.apple.Notes".into()),
    }
}

#[test]
fn only_titled_normal_on_screen_windows_of_other_apps_are_offered() {
    let own = [100, 99];
    assert!(offered(&cand(), &own));
    assert!(!offered(&Candidate { on_screen: false, ..cand() }, &own));
    assert!(!offered(&Candidate { layer: 25, ..cand() }, &own));
    assert!(!offered(&Candidate { title: None, ..cand() }, &own));
    assert!(!offered(&Candidate { title: Some("  ".into()), ..cand() }, &own));
    assert!(!offered(&Candidate { pid: 99, ..cand() }, &own));
    assert!(!offered(&Candidate { bundle: Some("com.cmuxterm.app".into()), ..cand() }, &own));
    assert!(offered(&Candidate { bundle: None, ..cand() }, &own));
}

#[test]
fn the_shared_window_comes_from_the_setup_or_the_display_name() {
    assert_eq!(session_window(Some(7), "main").unwrap(), Some(7));
    assert_eq!(session_window(None, "window:4242").unwrap(), Some(4242));
    assert_eq!(session_window(None, "window:0x10").unwrap(), Some(16));
    assert_eq!(session_window(None, "main").unwrap(), None);
    assert_eq!(session_window(None, "1").unwrap(), None);
    assert!(session_window(None, "window:front").is_err());
}

#[test]
fn a_window_streams_at_its_pixel_size_fitted() {
    // A Retina window of 800x600 points is 1600x1200 pixels.
    assert_eq!(pixel_size(b(10.0, 20.0, 800.0, 600.0), 2.0, None), Some((1600, 1200)));
    // Fitted into the viewer's max width, keeping its aspect, even.
    assert_eq!(pixel_size(b(0.0, 0.0, 800.0, 600.0), 2.0, Some(1000)), Some((1000, 750)));
    assert_eq!(pixel_size(b(0.0, 0.0, 333.0, 201.0), 1.0, None), Some((332, 200)));
    assert_eq!(pixel_size(b(0.0, 0.0, 1.0, 600.0), 1.0, None), None);
}

#[test]
fn a_move_follows_a_resize_or_close_ends() {
    let start = b(100.0, 100.0, 800.0, 600.0);
    let on = |bounds| Some(Frame { bounds, on_screen: true });
    assert_eq!(follow(start, start, on(start)), Change::Same);
    // Sub-point jitter is the same frame.
    assert_eq!(follow(start, start, on(b(100.3, 100.0, 800.4, 600.0))), Change::Same);
    assert_eq!(
        follow(start, start, on(b(300.0, 50.0, 800.0, 600.0))),
        Change::Moved(b(300.0, 50.0, 800.0, 600.0))
    );
    // Minimized: the window server still knows it, nothing changes.
    assert_eq!(follow(start, start, Some(Frame { bounds: start, on_screen: false })), Change::Same);
    let resized = follow(start, start, on(b(100.0, 100.0, 900.0, 600.0)));
    assert_eq!(resized, Change::Resized { from: (800, 600), to: (900, 600) });
    assert!(end_reason(7, &resized).unwrap().contains("resized from 800x600 to 900x600"));
    assert_eq!(follow(start, start, None), Change::Closed);
    assert_eq!(end_reason(7, &Change::Closed).as_deref(), Some("the shared window 7 was closed"));
    assert_eq!(end_reason(7, &Change::Moved(start)), None);
}
