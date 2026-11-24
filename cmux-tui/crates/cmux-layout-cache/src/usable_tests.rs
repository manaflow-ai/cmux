use super::*;
use crate::model::*;
use proptest::prelude::*;

const SCREEN: Rect = Rect::new(0.0, 0.0, 1440.0, 900.0);

fn display(id: u32, frame: Rect, scale: f64) -> Display {
    Display { id, frame, backing_scale: scale }
}

fn cache(frame: Rect) -> LayoutCache {
    LayoutCache {
        build_key: "b1".into(),
        written_at_ms: 1_000,
        displays: vec![display(1, SCREEN, 2.0)],
        windows: vec![WindowLayout {
            id: "w".into(),
            frame,
            display_id: 1,
            backing_scale: 2.0,
            panes: PaneNode::Leaf(Leaf {
                pane_id: "p".into(),
                last_content: Some(LastContent {
                    image_key: "k".into(),
                    pixel_w: 2,
                    pixel_h: 2,
                    captured_at_ms: 0,
                }),
                ..Leaf::default()
            }),
            ..WindowLayout::default()
        }],
        ..LayoutCache::default()
    }
}

fn now(build: &str, displays: Vec<Display>, now_ms: u64) -> NowState {
    NowState { build_key: build.into(), displays, now_ms }
}

#[test]
fn same_display_same_build_uses_everything() {
    let f = Rect::new(100.0, 50.0, 800.0, 600.0);
    let u = usable(&cache(f), &now("b1", vec![display(1, SCREEN, 2.0)], 2_000));
    assert_eq!(u.windows, ["w"]);
    assert_eq!(u.frames[0].frame, f);
    assert_eq!(u.content, ["p"]);
    assert!(u.reasons.is_empty());
}

#[test]
fn another_build_keeps_geometry_and_drops_pictures() {
    let f = Rect::new(100.0, 50.0, 800.0, 600.0);
    let u = usable(&cache(f), &now("b2", vec![display(1, SCREEN, 2.0)], 2_000));
    assert_eq!(u.windows, ["w"]);
    assert_eq!(u.frames[0].frame, f);
    assert!(u.content.is_empty());
    assert_eq!(u.reasons[0].kind, ReasonKind::BuildChanged);
}

#[test]
fn geometry_never_ages_but_pictures_do() {
    let f = Rect::new(100.0, 50.0, 800.0, 600.0);
    let u = usable(
        &cache(f),
        &now("b1", vec![display(1, SCREEN, 2.0)], 1_000 + CONTENT_MAX_AGE_MS * 30),
    );
    assert_eq!(u.frames[0].frame, f);
    assert!(u.content.is_empty());
    assert_eq!(u.reasons[0].kind, ReasonKind::ContentStale);
    assert_eq!(u.reasons[0].pane_id.as_deref(), Some("p"));
}

#[test]
fn a_gone_display_clamps_onto_the_one_left() {
    let f = Rect::new(1500.0, 50.0, 800.0, 600.0);
    let small = Rect::new(0.0, 0.0, 1280.0, 800.0);
    let u = usable(&cache(f), &now("b1", vec![display(7, small, 1.0)], 2_000));
    assert_eq!(u.frames[0].display_id, 7);
    assert_eq!(u.frames[0].frame, Rect::new(480.0, 50.0, 800.0, 600.0));
    assert_eq!(u.reasons[0].kind, ReasonKind::DisplayMoved);
    assert!(u.content.is_empty(), "scale changed: pictures don't fit");
}

#[test]
fn a_display_that_changed_frame_moves_its_window() {
    let f = Rect::new(100.0, 50.0, 800.0, 600.0);
    let moved = Rect::new(-1440.0, 0.0, 1440.0, 900.0);
    let u = usable(&cache(f), &now("b1", vec![display(1, moved, 2.0)], 2_000));
    assert_eq!(u.reasons[0].kind, ReasonKind::DisplayMoved);
    assert!(u.frames[0].frame.x >= moved.x && u.frames[0].frame.max_x() <= moved.max_x());
}

#[test]
fn no_display_places_nothing() {
    let u = usable(&cache(SCREEN), &now("b1", vec![], 2_000));
    assert!(u.windows.is_empty());
    assert_eq!(u.reasons[0].kind, ReasonKind::NoDisplay);
}

proptest! {
    /// Wherever the window was and whatever displays exist, the placement lies on a display now.
    #[test]
    fn placement_is_always_on_a_display(
        x in -5000.0f64..5000.0, y in -5000.0f64..5000.0, w in 1.0f64..4000.0, h in 1.0f64..4000.0,
        dx in -3000.0f64..3000.0, dw in 200.0f64..3000.0, dh in 200.0f64..2000.0,
    ) {
        let d = display(3, Rect::new(dx, 0.0, dw, dh), 2.0);
        let u = usable(&cache(Rect::new(x, y, w, h)), &now("b1", vec![d.clone()], 2_000));
        let f = u.frames[0].frame;
        prop_assert!(f.x >= d.frame.x - EPSILON && f.max_x() <= d.frame.max_x() + 1e-6);
        prop_assert!(f.y >= d.frame.y - EPSILON && f.max_y() <= d.frame.max_y() + 1e-6);
    }
}
