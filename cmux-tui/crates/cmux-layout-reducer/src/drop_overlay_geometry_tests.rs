//! The drop overlay's rects.

use super::*;

const REGION: Rect = Rect { x: 10.0, y: 20.0, width: 200.0, height: 100.0 };

#[test]
fn a_split_gives_each_pane_half_less_half_the_gap() {
    let (incoming, existing) = split_preview(REGION, Zone::Left, 8.0);
    assert_eq!(incoming, Rect::new(10.0, 20.0, 96.0, 100.0));
    assert_eq!(existing, Some(Rect::new(114.0, 20.0, 96.0, 100.0)));
    let (incoming, existing) = split_preview(REGION, Zone::Right, 8.0);
    assert_eq!(incoming, Rect::new(114.0, 20.0, 96.0, 100.0));
    assert_eq!(existing, Some(Rect::new(10.0, 20.0, 96.0, 100.0)));
    let (incoming, existing) = split_preview(REGION, Zone::Top, -4.0);
    assert_eq!(incoming, Rect::new(10.0, 20.0, 200.0, 50.0));
    assert_eq!(existing, Some(Rect::new(10.0, 70.0, 200.0, 50.0)));
    let (incoming, existing) = split_preview(REGION, Zone::Bottom, 0.0);
    assert_eq!(incoming, Rect::new(10.0, 70.0, 200.0, 50.0));
    assert_eq!(existing, Some(Rect::new(10.0, 20.0, 200.0, 50.0)));
    assert_eq!(split_preview(REGION, Zone::Center, 8.0), (REGION, None));
    assert_eq!(split_preview(REGION, Zone::Column, 8.0), (REGION, None));
    // A gap wider than the region leaves empty panes, never negative ones.
    assert_eq!(split_preview(REGION, Zone::Left, 900.0).0.width, 0.0);
}

#[test]
fn the_caret_sits_on_the_new_divider() {
    assert_eq!(insertion_line(REGION, Zone::Left, 4.0, 0.5), Rect::new(108.0, 45.0, 4.0, 50.0));
    assert_eq!(insertion_line(REGION, Zone::Column, 4.0, 2.0), Rect::new(108.0, 20.0, 4.0, 100.0));
    assert_eq!(insertion_line(REGION, Zone::Top, 4.0, 0.5), Rect::new(60.0, 68.0, 100.0, 4.0));
    assert_eq!(insertion_line(REGION, Zone::Center, 4.0, 0.5), Rect::new(60.0, 24.0, 100.0, 4.0));
    assert_eq!(insertion_line(REGION, Zone::Bottom, 4.0, -1.0).width, 0.0);
}

#[test]
fn a_glow_grows_from_the_new_panes_side() {
    assert_eq!(glow_edges(Zone::Left), &[RectEdge::MinX]);
    assert_eq!(glow_edges(Zone::Bottom), &[RectEdge::MaxY]);
    assert_eq!(glow_edges(Zone::Center).len(), 4);
    assert_eq!(glow_edges(Zone::Column), glow_edges(Zone::Center));
}

#[test]
fn a_band_is_cut_from_its_edge() {
    assert_eq!(band(REGION, RectEdge::MinX, 30.0), Rect::new(10.0, 20.0, 30.0, 100.0));
    assert_eq!(band(REGION, RectEdge::MaxX, 30.0), Rect::new(180.0, 20.0, 30.0, 100.0));
    assert_eq!(band(REGION, RectEdge::MinY, 30.0), Rect::new(10.0, 20.0, 200.0, 30.0));
    assert_eq!(band(REGION, RectEdge::MaxY, 30.0), Rect::new(10.0, 90.0, 200.0, 30.0));
    // Clamped to the rect's side, and never negative.
    assert_eq!(band(REGION, RectEdge::MaxY, 500.0), REGION);
    assert_eq!(band(REGION, RectEdge::MinX, -5.0).width, 0.0);
}

#[test]
fn a_card_is_centered_and_never_larger_than_its_target() {
    assert_eq!(inset_card(REGION, 0.5, 300.0, 40.0), Rect::new(60.0, 50.0, 100.0, 40.0));
    assert_eq!(inset_card(REGION, 0.5, 60.0, 40.0).width, 60.0);
    assert_eq!(inset_card(REGION, 3.0, 900.0, 900.0), REGION);
}

#[test]
fn the_tab_pill_sits_at_the_top_leading_corner() {
    assert_eq!(tab_pill(REGION, 80.0, 24.0, 6.0), Rect::new(16.0, 26.0, 80.0, 24.0));
    assert_eq!(tab_pill(REGION, 900.0, 900.0, 6.0), Rect::new(16.0, 26.0, 188.0, 88.0));
    assert_eq!(tab_pill(Rect::new(0.0, 0.0, 4.0, 4.0), 10.0, 10.0, 6.0).width, 0.0);
}

#[test]
fn a_morph_starts_on_the_pointer_at_three_to_two() {
    assert_eq!(morph_start(Point { x: 100.0, y: 50.0 }, 120.0), Rect::new(40.0, 10.0, 120.0, 80.0));
    // 100 * 2 / 3 = 66.67 rounds to 67.
    assert_eq!(morph_start(Point { x: 0.0, y: 0.0 }, 100.0).height, 67.0);
}

#[test]
fn the_wire() {
    let zone: Zone = serde_json::from_str(r#""column""#).expect("zone");
    assert_eq!(zone, Zone::Column);
    let edge = serde_json::to_value(RectEdge::MinY).expect("edge");
    assert_eq!(edge, serde_json::json!("min_y"));
}
