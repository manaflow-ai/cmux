//! Ported from the Mac app's DropZoneRuleTests and BonsplitDropParityTests
//! (the drop zone rule, plans/cmux-next/drop-zones/DESIGN.md).

use super::*;

fn zone_in(x: f64, y: f64, width: f64, height: f64, previous: Option<Zone>) -> Zone {
    zone(x, y, &Rect::new(0.0, 0.0, width, height), 0.0, 0.0, &Style::default(), previous)
}

const P: usize = 0;

fn pane(zone: Zone) -> Option<Target> {
    Some(Target::Pane { pane: P, zone })
}

fn dock(edge: Edge) -> Option<Target> {
    Some(Target::NewDock { edge })
}

/// Viewport 1200 x 800 with one scrolling pane filling it.
fn screen() -> Screen {
    Screen {
        width: 1200.0,
        height: 800.0,
        panes: vec![Pane { rect: Rect::new(0.0, 0.0, 1200.0, 800.0), ..Pane::default() }],
        ..Screen::default()
    }
}

fn dock_at(screen: &Screen, x: f64, y: f64, previous: Option<Target>) -> Option<Target> {
    screen.dock_target(x, y, 30.0, 20.0, previous)
}

/// A big pane splits from its outer quarter, as classic cmux (Bonsplit) did.
#[test]
fn outer_quarter_splits() {
    for (width, height, x, y, expected) in [
        (1200.0, 800.0, 250.0, 400.0, Zone::Left),
        (1200.0, 800.0, 950.0, 400.0, Zone::Right),
        (1200.0, 800.0, 600.0, 180.0, Zone::Top),
        (1200.0, 800.0, 600.0, 620.0, Zone::Bottom),
        (2400.0, 1200.0, 2400.0 - 580.0, 600.0, Zone::Right),
    ] {
        assert_eq!(zone_in(x, y, width, height, None), expected, "{width}x{height} at ({x}, {y})");
    }
}

/// The middle half of each axis joins the pane on every pane size.
#[test]
fn middle_joins() {
    for (width, height) in [(1200.0, 800.0), (400.0, 300.0), (2400.0, 1200.0)] {
        for x in [width / 2.0, width * 0.3, width * 0.7] {
            assert_eq!(zone_in(x, height / 2.0, width, height, None), Zone::Center);
        }
    }
}

/// A small pane keeps all five targets.
#[test]
fn small_pane_keeps_every_target() {
    let at = |x, y| zone_in(x, y, 160.0, 140.0, None);
    assert_eq!(at(80.0, 70.0), Zone::Center);
    assert_eq!(at(45.0, 70.0), Zone::Left);
    assert_eq!(at(115.0, 70.0), Zone::Right);
    assert_eq!(at(80.0, 10.0), Zone::Top);
    assert_eq!(at(80.0, 130.0), Zone::Bottom);
}

/// A corner goes to the edge the pointer is relatively nearest.
#[test]
fn corners_split_on_the_diagonal() {
    let at = |x, y| zone_in(x, y, 1200.0, 800.0, None);
    assert_eq!(at(70.0, 10.0), Zone::Top);
    assert_eq!(at(10.0, 70.0), Zone::Left);
    assert_eq!(at(1190.0, 760.0), Zone::Right);
}

/// The shown zone holds a few points past its line.
#[test]
fn shown_zone_holds_near_its_line() {
    let at = |x, previous| zone_in(x, 400.0, 1200.0, 800.0, Some(previous));
    assert_eq!(at(304.0, Zone::Left), Zone::Left);
    assert_eq!(at(296.0, Zone::Center), Zone::Center);
    assert_eq!(at(340.0, Zone::Left), Zone::Center);
}

/// A header joins over the tab bar and the zones divide the body below it.
#[test]
fn tab_bars_join_and_the_body_splits() {
    let rect = Rect::new(0.0, 0.0, 400.0, 400.0);
    let style = Style::default();
    assert_eq!(zone(200.0, 10.0, &rect, 30.0, 0.0, &style, None), Zone::Center);
    assert_eq!(zone(200.0, 40.0, &rect, 30.0, 0.0, &style, None), Zone::Top);
    assert_eq!(zone(200.0, 395.0, &rect, 0.0, 20.0, &style, None), Zone::Center);
    assert_eq!(zone(200.0, 370.0, &rect, 0.0, 20.0, &style, None), Zone::Bottom);
}

/// Each shown dock holds 12 pt inward past its band, without entering either tab bar.
#[test]
fn shown_dock_holds_near_its_line() {
    let screen = screen();
    for (edge, zone, held, released) in [
        (Edge::Top, Zone::Top, (600.0, 74.0), (600.0, 75.0)),
        (Edge::Bottom, Zone::Bottom, (600.0, 744.0), (600.0, 743.0)),
        (Edge::Left, Zone::Left, (24.0, 400.0), (25.0, 400.0)),
        (Edge::Right, Zone::Right, (1176.0, 400.0), (1175.0, 400.0)),
    ] {
        let previous = dock(edge);
        assert_eq!(dock_at(&screen, held.0, held.1, previous), previous, "{edge:?} held");
        assert_eq!(dock_at(&screen, released.0, released.1, previous), None, "{edge:?} released");
        assert_eq!(dock_at(&screen, held.0, held.1, None), None, "{edge:?} fresh");
        assert_eq!(screen.target(released.0, released.1, 0.0, previous), pane(zone));
    }
}

/// Entering a dock from the split zone facing it needs half a band (up to 12 pt).
#[test]
fn pane_edge_does_not_flip_to_dock() {
    let screen = screen();
    for (edge, zone, near, inside) in [
        (Edge::Top, Zone::Top, (600.0, 55.0), (600.0, 49.0)),
        (Edge::Bottom, Zone::Bottom, (600.0, 761.0), (600.0, 769.0)),
        (Edge::Left, Zone::Left, (9.0, 400.0), (5.0, 400.0)),
        (Edge::Right, Zone::Right, (1191.0, 400.0), (1195.0, 400.0)),
    ] {
        assert_eq!(dock_at(&screen, near.0, near.1, pane(zone)), None, "{edge:?} near");
        assert_eq!(dock_at(&screen, inside.0, inside.1, pane(zone)), dock(edge), "{edge:?} inside");
        // Another screen's dock arrives as no previous target; another screen's
        // column as an index past the gaps.
        for previous in [pane(Zone::Center), Some(Target::NewColumn { gap: usize::MAX }), None] {
            assert_eq!(
                dock_at(&screen, near.0, near.1, previous),
                dock(edge),
                "{edge:?} from {previous:?}"
            );
        }
        assert_eq!(screen.target(near.0, near.1, 0.0, pane(zone)), pane(zone));
    }
}

#[test]
fn dock_hysteresis_preserves_tab_bars_and_corner_order() {
    let screen = screen();
    for (x, y, edge) in [(600.0, 29.0, Edge::Top), (600.0, 781.0, Edge::Bottom)] {
        assert_eq!(dock_at(&screen, x, y, dock(edge)), None);
    }
    assert_eq!(screen.dock_target(2.0, 35.0, 30.0, 0.0, dock(Edge::Left)), dock(Edge::Top));
}

/// An edge that already holds a dock opens no other.
#[test]
fn a_held_edge_is_not_free() {
    let mut screen = screen();
    let frame = Rect::new(0.0, 560.0, 1200.0, 240.0);
    screen.docks = vec![Dock { edge: Edge::Bottom, frame, cover: frame }];
    assert_eq!(dock_at(&screen, 600.0, 770.0, None), None);
    assert_eq!(dock_at(&screen, 600.0, 40.0, None), dock(Edge::Top));
}

/// Both coordinate paths hold a shown gap 12 pt horizontally, and shrink entry from a left or
/// right split zone by width / 4; entry from anything else keeps the frame.
#[test]
fn column_gap_hysteresis() {
    for offset in [0.0, 75.0] {
        let mut screen = screen();
        screen.gaps = vec![Rect::new(282.0, 0.0, 36.0, 800.0)];
        let gap = Some(Target::NewColumn { gap: 0 });
        for in_view in [false, true] {
            let target = |x: f64, previous: Option<Target>| {
                if in_view {
                    screen.target(x - offset, 400.0, offset, previous)
                } else {
                    screen.target_in_content(x, 400.0, previous)
                }
            };
            for x in [270.0, 329.0] {
                assert_eq!(target(x, gap), gap);
            }
            assert_eq!(target(269.0, gap), pane(Zone::Left));
            assert_eq!(target(331.0, gap), pane(Zone::Center));
            for previous in [pane(Zone::Left), pane(Zone::Right)] {
                assert_eq!(target(286.0, previous), pane(Zone::Left));
                assert_eq!(target(314.0, previous), pane(Zone::Center));
                assert_eq!(target(292.0, previous), gap);
                assert_eq!(target(308.0, previous), gap);
            }
            for previous in
                [pane(Zone::Center), dock(Edge::Left), Some(Target::NewColumn { gap: 9 })]
            {
                assert_eq!(target(283.0, previous), gap);
                assert_eq!(target(317.0, previous), gap);
            }
            assert_eq!(target(283.0, None), gap);
            assert_eq!(target(317.0, None), gap);
            assert_eq!(target(281.0, None), pane(Zone::Left));
            assert_eq!(target(319.0, None), pane(Zone::Center));
        }
    }
}

/// A point outside every pane resolves to the nearest one, at its nearest point.
#[test]
fn no_dead_zones() {
    let screen = Screen {
        width: 1000.0,
        height: 600.0,
        panes: vec![
            Pane { rect: Rect::new(0.0, 0.0, 400.0, 600.0), ..Pane::default() },
            Pane { rect: Rect::new(600.0, 0.0, 400.0, 600.0), ..Pane::default() },
        ],
        ..Screen::default()
    };
    assert_eq!(
        screen.target(450.0, 300.0, 0.0, None),
        Some(Target::Pane { pane: 0, zone: Zone::Right })
    );
    assert_eq!(
        screen.target(560.0, 300.0, 0.0, None),
        Some(Target::Pane { pane: 1, zone: Zone::Left })
    );
    assert_eq!(Screen::default().target(10.0, 10.0, 0.0, None), None);
}

/// A dock's cover takes the drop for its own panes; strip panes clip to the uncovered part.
#[test]
fn a_dock_cover_takes_its_own_panes() {
    let frame = Rect::new(0.0, 500.0, 1000.0, 100.0);
    let screen = Screen {
        width: 1000.0,
        height: 600.0,
        panes: vec![
            Pane { rect: Rect::new(0.0, 0.0, 1000.0, 600.0), ..Pane::default() },
            Pane { rect: frame, fixed: true, ..Pane::default() },
        ],
        docks: vec![Dock { edge: Edge::Bottom, frame, cover: frame }],
        uncovered: Rect::new(0.0, 0.0, 1000.0, 500.0),
        ..Screen::default()
    };
    assert_eq!(
        screen.target(500.0, 550.0, 0.0, None),
        Some(Target::Pane { pane: 1, zone: Zone::Center })
    );
    // Just above the cover the strip pane takes it; its zone reads its whole cell.
    assert_eq!(
        screen.target(500.0, 490.0, 0.0, None),
        Some(Target::Pane { pane: 0, zone: Zone::Bottom })
    );
}

/// A new dock's preview is 30% of the screen across, less the strip gaps.
#[test]
fn dock_preview_rects() {
    let mut screen = screen();
    screen.style.strip_gap = 8.0;
    assert_eq!(screen.dock_preview(Edge::Top), Rect::new(8.0, 0.0, 1184.0, 240.0));
    assert_eq!(screen.dock_preview(Edge::Bottom), Rect::new(8.0, 560.0, 1184.0, 240.0));
    assert_eq!(screen.dock_preview(Edge::Left), Rect::new(8.0, 0.0, 360.0, 800.0));
    assert_eq!(screen.dock_preview(Edge::Right), Rect::new(832.0, 0.0, 360.0, 800.0));
}

/// The highlight is the half an edge splits off; strip rects follow the scroll, a dock's do not.
#[test]
fn highlight_and_region_in_view() {
    let mut screen = screen();
    screen.style.pane_padding = 6.0;
    screen.strip_min_x = 10.0;
    screen.gaps = vec![Rect::new(282.0, 0.0, 36.0, 800.0)];
    let content = Rect::new(6.0, 6.0, 1188.0, 788.0);
    let shift = 10.0 - 100.0;
    assert_eq!(screen.region_rect(Target::Pane { pane: P, zone: Zone::Left }), Some(content));
    assert_eq!(
        screen.highlight_rect_in_view(Target::Pane { pane: P, zone: Zone::Right }, 100.0),
        Some(Rect::new(600.0 + shift, 6.0, 594.0, 788.0))
    );
    assert_eq!(
        screen.highlight_rect(Target::Pane { pane: P, zone: Zone::Bottom }),
        Some(Rect::new(6.0, 400.0, 1188.0, 394.0))
    );
    assert_eq!(
        screen.region_rect_in_view(Target::NewColumn { gap: 0 }, 100.0),
        Some(Rect::new(282.0 + shift, 0.0, 36.0, 800.0))
    );
    assert_eq!(
        screen.highlight_rect_in_view(Target::NewDock { edge: Edge::Top }, 100.0),
        Some(screen.dock_preview(Edge::Top))
    );
    assert_eq!(screen.region_rect(Target::Pane { pane: 7, zone: Zone::Left }), None);
}

/// A pane's body sits below its tab bar (the padding plus the reported header) and above a
/// bottom tab bar.
#[test]
fn pane_body_below_the_tab_bar() {
    let mut screen = screen();
    screen.style.pane_padding = 4.0;
    screen.panes[0].header = 28.0;
    screen.panes[0].footer = 20.0;
    assert_eq!(screen.header(&screen.panes[0]), 32.0);
    assert_eq!(screen.footer(&screen.panes[0]), 24.0);
    assert_eq!(screen.pane_body(P, 0.0), Some(Rect::new(4.0, 32.0, 1192.0, 744.0)));
    let rects = screen.rects(Target::Pane { pane: P, zone: Zone::Center }, 0.0).unwrap();
    assert_eq!(rects.body, screen.pane_body(P, 0.0));
    assert_eq!(rects.region, Rect::new(4.0, 4.0, 1192.0, 792.0));
    assert_eq!(screen.rects(Target::NewDock { edge: Edge::Left }, 0.0).unwrap().body, None);
}

/// Classic cmux's edge preview is the inset half of the pane body.
#[test]
fn edge_preview_is_the_inset_half() {
    let body = Rect::new(0.0, 0.0, 400.0, 200.0);
    let at = |zone| classic_pane_highlight(&body, zone, CLASSIC_PANE_PADDING);
    assert_eq!(at(Zone::Left), Rect::new(4.0, 4.0, 196.0, 192.0));
    assert_eq!(at(Zone::Bottom), Rect::new(4.0, 100.0, 392.0, 96.0));
    assert_eq!(at(Zone::Center), Rect::new(4.0, 4.0, 392.0, 192.0));
    assert_eq!(at(Zone::Right), Rect::new(200.0, 4.0, 196.0, 192.0));
    assert_eq!(at(Zone::Top), Rect::new(4.0, 4.0, 392.0, 96.0));
    assert_eq!(classic_pane_highlight(&Rect::new(0.0, 0.0, 6.0, 6.0), Zone::Left, 4.0).width, 0.0);
}

/// The band is a quarter of the extent, at least 48 pt, never more than a third.
#[test]
fn band_floor_and_third() {
    let style = Style::default();
    assert_eq!(band(1200.0, &style), 300.0);
    assert_eq!(band(160.0, &style), 48.0);
    assert_eq!(band(100.0, &style), 100.0 / 3.0);
    assert_eq!(band(300.0, &style), 75.0);
    assert_eq!(band(1.0, &style), 1.0);
}
