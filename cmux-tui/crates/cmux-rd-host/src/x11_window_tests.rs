use super::*;

const SCREEN: (u32, u32) = (1920, 1080);

fn cand(id: u32, title: Option<&str>, rect: WinRect) -> Candidate {
    Candidate {
        id,
        title: title.map(str::to_owned),
        rect,
        viewable: true,
        draws: true,
        override_redirect: false,
    }
}

#[test]
fn the_list_keeps_viewable_drawing_windows_on_screen() {
    let r = WinRect { x: 10, y: 20, w: 800, h: 600 };
    let mut hidden = cand(2, Some("hidden"), r);
    hidden.viewable = false;
    let mut input_only = cand(3, Some("input"), r);
    input_only.draws = false;
    let zero = cand(4, Some("zero"), WinRect { w: 0, ..r });
    let off = cand(5, Some("off"), WinRect { x: 4000, ..r });
    let mut menu = cand(6, Some("menu"), r);
    menu.override_redirect = true;
    let untitled = cand(7, None, r);
    let all = [cand(1, Some("term"), r), hidden, input_only, zero, off, menu, untitled];
    let ids = |l: Vec<WindowInfo>| l.iter().map(|w| w.id).collect::<Vec<_>>();
    // A window manager's client list names managed windows: untitled ones stay.
    assert_eq!(ids(filter(&all, SCREEN, true)), vec![1, 6, 7]);
    // The root's children: no menus, no untitled helpers.
    let listed = filter(&all, SCREEN, false);
    assert_eq!(listed, vec![WindowInfo { id: 1, title: "term".into(), rect: r }]);
}

#[test]
fn the_part_on_screen_is_even_and_never_past_the_window() {
    let r = WinRect { x: -101, y: 7, w: 501, h: 300 };
    assert_eq!(on_screen(r, SCREEN), Some(Rect { x: 0, y: 8, w: 400, h: 298 }));
    let right = WinRect { x: 1800, y: 1000, w: 400, h: 400 };
    assert_eq!(on_screen(right, SCREEN), Some(Rect { x: 1800, y: 1000, w: 120, h: 80 }));
    assert_eq!(on_screen(WinRect { x: 1919, y: 0, w: 10, h: 10 }, SCREEN), None);
    assert_eq!(on_screen(WinRect { x: -50, y: -50, w: 40, h: 40 }, SCREEN), None);
}

#[test]
fn a_window_view_streams_its_rect_fitted() {
    let w = WinRect { x: 100, y: 50, w: 1280, h: 720 };
    let (f, view) = Followed::start(9, w, SCREEN, None).unwrap();
    assert_eq!(view.src, Rect { x: 100, y: 50, w: 1280, h: 720 });
    assert_eq!(view.out, (1280, 720));
    assert_eq!(f.offset, (0, 0));
    assert_eq!(view.pointer(0, 0), (100, 50), "input lands on the window");
    let (_, small) = Followed::start(9, w, SCREEN, Some(640)).unwrap();
    assert_eq!(small.out, (640, 360));
    assert_eq!(small.pointer(320, 180), (100 + 640, 50 + 360));
    let gone = Followed::start(9, WinRect { x: 3000, ..w }, SCREEN, None).unwrap_err();
    assert!(gone.contains("not on the screen"), "{gone}");
}

#[test]
fn a_move_slides_the_source_and_a_resize_ends_the_share() {
    let w = WinRect { x: 100, y: 50, w: 640, h: 480 };
    let (f, view) = Followed::start(9, w, SCREEN, None).unwrap();
    assert_eq!(f.on_change(w, view.src, SCREEN), Change::Same);
    let moved = f.on_change(WinRect { x: 300, y: 200, ..w }, view.src, SCREEN);
    assert_eq!(moved, Change::Moved(Rect { x: 300, y: 200, w: 640, h: 480 }));
    // Past the right edge: the same size, slid back inside the screen.
    let edge = f.on_change(WinRect { x: 1700, y: 900, ..w }, view.src, SCREEN);
    assert_eq!(edge, Change::Moved(Rect { x: 1280, y: 600, w: 640, h: 480 }));
    // An odd origin lands on an even pixel.
    let odd = f.on_change(WinRect { x: 301, y: 201, ..w }, view.src, SCREEN);
    assert_eq!(odd, Change::Moved(Rect { x: 300, y: 200, w: 640, h: 480 }));
    assert_eq!(
        f.on_change(WinRect { w: 800, ..w }, view.src, SCREEN),
        Change::Resized { from: (640, 480), to: (800, 480) }
    );
}

#[test]
fn a_window_that_started_past_an_edge_keeps_showing_the_same_part() {
    let w = WinRect { x: -200, y: 0, w: 600, h: 400 };
    let (f, view) = Followed::start(9, w, SCREEN, None).unwrap();
    assert_eq!(view.src, Rect { x: 0, y: 0, w: 400, h: 400 });
    assert_eq!(f.offset, (200, 0));
    let moved = f.on_change(WinRect { x: 100, y: 10, ..w }, view.src, SCREEN);
    assert_eq!(moved, Change::Moved(Rect { x: 300, y: 10, w: 400, h: 400 }));
}
