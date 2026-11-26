//! Ported from cmux-next macOS `ChiefPanelModelTests.swift`: the Chief panel shows only when open
//! and never over Home, docked it takes its edge, floating it stays inside and round-trips; plus
//! the layout style's resolved metrics.

use super::*;

fn bounds() -> Rect {
    Rect { x: 0.0, y: 0.0, width: 1000.0, height: 600.0 }
}

fn intersects(a: Rect, b: Rect) -> bool {
    a.width > 0.0
        && a.height > 0.0
        && b.width > 0.0
        && b.height > 0.0
        && a.x < b.x + b.width
        && b.x < a.x + a.width
        && a.y < b.y + b.height
        && b.y < a.y + a.height
}

fn union(a: Rect, b: Rect) -> Rect {
    let (x, y) = (a.x.min(b.x), a.y.min(b.y));
    let max_x = (a.x + a.width).max(b.x + b.width);
    let max_y = (a.y + a.height).max(b.y + b.height);
    Rect { x, y, width: max_x - x, height: max_y - y }
}

fn contains(outer: Rect, inner: Rect) -> bool {
    inner.x >= outer.x
        && inner.y >= outer.y
        && inner.x + inner.width <= outer.x + outer.width
        && inner.y + inner.height <= outer.y + outer.height
}

#[test]
fn it_shows_only_when_open_and_never_over_home() {
    let mut panel = ChiefPanel::default();
    assert!(!panel.is_shown(Some("ws"), Some("home")), "a new window shows the Chief");
    panel.open();
    assert!(panel.is_shown(Some("ws"), Some("home")));
    assert!(!panel.is_shown(Some("home"), Some("home")), "the Chief shows over Home");
    assert!(!panel.is_shown(None, Some("home")));
    panel.dock(DockEdge::Right);
    assert!(!panel.is_shown(Some("home"), Some("home")));
    panel.hide();
    assert!(!panel.is_shown(Some("ws"), Some("home")));
    assert_eq!(panel.docked_edge, Some(DockEdge::Right), "hiding lost the dock");
    assert!(panel.undock() && panel.docked_edge.is_none());
    assert!(!panel.undock(), "a floating panel undocked again");
}

#[test]
fn docked_it_takes_its_edge() {
    for edge in DockEdge::ALL {
        let mut panel = ChiefPanel::default();
        panel.dock(edge);
        let ChiefSplit { panel: rect, stage } = panel.split(bounds());
        assert!(!intersects(rect, stage), "{edge:?}: the Chief covers the stage");
        assert_eq!(union(rect, stage), bounds(), "{edge:?}: the Chief and the stage leave a gap");
        match edge {
            DockEdge::Left => assert!(rect.x == 0.0 && rect.width == 300.0),
            DockEdge::Right => assert!(rect.x + rect.width == 1000.0 && rect.width == 300.0),
            DockEdge::Top => assert!(rect.y == 0.0 && rect.height == 180.0),
            DockEdge::Bottom => assert!(rect.y + rect.height == 600.0 && rect.height == 180.0),
        }
        panel.docked_edge = None;
        assert_eq!(panel.split(bounds()).stage, bounds());
    }
}

#[test]
fn the_floating_place_stays_inside_and_round_trips() {
    let minimum = ChiefPanelFrame::MINIMUM_SIZE;
    let size = Size { width: 1000.0, height: 600.0 };
    let drop = Rect { x: 120.0, y: 80.0, width: 400.0, height: 300.0 };
    let frame = ChiefPanelFrame::fitting(drop, size, minimum);
    assert_eq!(frame.rect(size, minimum), drop);
    let small = Size { width: 500.0, height: 300.0 };
    let r = frame.rect(small, minimum);
    assert!(contains(Rect { x: 0.0, y: 0.0, width: 500.0, height: 300.0 }, r), "{r:?}");
    assert!(r.width >= minimum.width && r.height >= minimum.height);
    let off = ChiefPanelFrame::fitting(
        Rect { x: 900.0, y: 550.0, width: 400.0, height: 300.0 },
        size,
        minimum,
    )
    .rect(size, minimum);
    assert!(contains(Rect { x: 0.0, y: 0.0, width: 1000.0, height: 600.0 }, off), "{off:?}");
}

#[test]
fn the_extent_is_clamped_and_an_empty_content_has_no_frame() {
    let mut panel = ChiefPanel::new(None, false, ChiefPanelFrame::INITIAL, 5);
    assert_eq!(panel.dock_extent_permille(), 100);
    panel.set_dock_extent_permille(5000);
    assert_eq!(panel.dock_extent_permille(), 900);
    let empty = Size { width: 0.0, height: 600.0 };
    assert_eq!(
        ChiefPanelFrame::INITIAL.rect(empty, ChiefPanelFrame::MINIMUM_SIZE),
        Rect::default()
    );
    assert_eq!(
        ChiefPanelFrame::fitting(bounds(), empty, ChiefPanelFrame::MINIMUM_SIZE),
        ChiefPanelFrame::INITIAL
    );
}

fn style() -> StyleInput {
    StyleInput {
        floating_panes: false,
        divider_thickness: 1.0,
        draws_lines: true,
        floating_panes_hide_focus_ring: false,
        focus_ring_enabled: true,
        attention_width: 2.0,
        drop_edge_range: (48.0, f64::MAX),
        minimum_pane_content_size: Size { width: 200.0, height: 64.0 },
        pane_padding: 4.0,
        pane_chrome_height: 28.0,
        drop_edge_minimum: None,
        drop_edge_maximum: None,
        minimum_content_width: None,
        minimum_content_height: None,
    }
}

#[test]
fn the_style_resolves_its_overrides() {
    let plain = resolve_style(&style());
    assert_eq!(plain.minimum_pane_size, Size { width: 208.0, height: 100.0 });
    assert!(plain.focus_ring_enabled && plain.divider_thickness == 1.0);
    let cards = resolve_style(&StyleInput { floating_panes: true, draws_lines: false, ..style() });
    assert_eq!(cards.divider_thickness, 0.0);
    assert!(!cards.focus_ring_enabled && cards.attention_width == 0.0);
    let edges = resolve_style(&StyleInput {
        drop_edge_minimum: Some(60.0),
        drop_edge_maximum: Some(30.0),
        ..style()
    });
    assert_eq!(edges.drop_edge_range, (60.0, 60.0), "the upper bound is never below the lower");
    let open = resolve_style(&StyleInput { drop_edge_maximum: Some(0.0), ..style() });
    assert_eq!(open.drop_edge_range, (48.0, f64::MAX), "zero means no upper bound");
    let sized = resolve_style(&StyleInput { minimum_content_width: Some(96.0), ..style() });
    assert_eq!(sized.minimum_pane_size.width, 104.0);
}
