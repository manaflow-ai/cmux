use super::*;

fn size(w: u32, h: u32, scale: f64) -> ScreenSize {
    ScreenSize { css_width: w, css_height: h, scale }
}

#[test]
fn canonical_screen_uses_only_visible_viewers() {
    let mut s = Session::default();
    s.apply(SessionInput::Open { viewer: "a".into(), screen: size(1000, 800, 2.0) }).unwrap();
    s.apply(SessionInput::Open { viewer: "b".into(), screen: size(600, 900, 1.0) }).unwrap();
    assert_eq!(s.canonical_screen(), Some(size(600, 800, 2.0)));
    s.apply(SessionInput::Visibility { viewer: "b".into(), visible: false }).unwrap();
    assert_eq!(s.canonical_screen(), Some(size(1000, 800, 2.0)));
}

#[test]
fn reject_leaves_state_unchanged() {
    let mut s = Session::default();
    s.apply(SessionInput::Open { viewer: "a".into(), screen: size(800, 600, 2.0) }).unwrap();
    let before = s.clone();
    assert_eq!(
        s.apply(SessionInput::Visibility { viewer: "x".into(), visible: true }),
        Err(SessionReject::UnknownViewer)
    );
    assert_eq!(s, before);
}
