//! The Swift geometry tests, ported (CmuxNextAppTests `DropZoneRuleTests`, `HomeLoneDockTests`,
//! `DividerHandleCenteringTests`' band cases), plus the `vectors.json` replay.

use super::divider_band::DividerBand;
use super::dock_strip::{self, Dock, DockMode, Docks, FrameOrientation};
use super::drop_zones::{
    self, Bars, DropGeometry, DropStyle, DropTarget, GapZone, PaneDropZone as Z,
};
use super::{DockEdge, Point, Rect, Size, SplitAxis};

fn style() -> DropStyle {
    DropStyle::default()
}

fn zone(x: f64, y: f64, w: f64, h: f64, previous: Option<Z>) -> Z {
    drop_zones::zone(Point::new(x, y), Rect::new(0., 0., w, h), 0., 0., &style(), previous)
}

fn pane(zone: Z) -> DropTarget {
    DropTarget::Pane { pane: "p".into(), zone }
}

fn dock(edge: DockEdge, screen: &str) -> DropTarget {
    DropTarget::NewDock { screen: screen.into(), edge }
}

#[test]
fn outer_quarter_splits() {
    for (w, h, x, y, expected) in [
        (1200., 800., 250., 400., Z::Left),
        (1200., 800., 950., 400., Z::Right),
        (1200., 800., 600., 180., Z::Top),
        (1200., 800., 600., 620., Z::Bottom),
        (2400., 1200., 2400. - 580., 600., Z::Right),
    ] {
        assert_eq!(zone(x, y, w, h, None), expected, "{w}x{h} at {x},{y}");
    }
}

#[test]
fn middle_joins() {
    for (w, h) in [(1200., 800.), (400., 300.), (2400., 1200.)] {
        assert_eq!(zone(w / 2., h / 2., w, h, None), Z::Center);
        assert_eq!(zone(w * 0.3, h / 2., w, h, None), Z::Center);
        assert_eq!(zone(w * 0.7, h / 2., w, h, None), Z::Center);
    }
}

#[test]
fn small_pane_keeps_every_target() {
    assert_eq!(zone(80., 70., 160., 140., None), Z::Center);
    assert_eq!(zone(45., 70., 160., 140., None), Z::Left);
    assert_eq!(zone(115., 70., 160., 140., None), Z::Right);
    assert_eq!(zone(80., 10., 160., 140., None), Z::Top);
    assert_eq!(zone(80., 130., 160., 140., None), Z::Bottom);
}

#[test]
fn corners_split_on_the_diagonal() {
    assert_eq!(zone(70., 10., 1200., 800., None), Z::Top);
    assert_eq!(zone(10., 70., 1200., 800., None), Z::Left);
    assert_eq!(zone(1190., 760., 1200., 800., None), Z::Right);
}

#[test]
fn shown_zone_holds_near_its_line() {
    let line = 300.;
    assert_eq!(zone(line + 4., 400., 1200., 800., Some(Z::Left)), Z::Left);
    assert_eq!(zone(line - 4., 400., 1200., 800., Some(Z::Center)), Z::Center);
    assert_eq!(zone(line + 40., 400., 1200., 800., Some(Z::Left)), Z::Center);
}

#[test]
fn tab_bars_join_the_pane() {
    let rect = Rect::new(0., 0., 400., 300.);
    let at = |y: f64| drop_zones::zone(Point::new(5., y), rect, 30., 20., &style(), None);
    assert_eq!(at(10.), Z::Center, "over the header");
    assert_eq!(at(290.), Z::Center, "over the footer");
    assert_eq!(at(150.), Z::Left);
}

fn geometry() -> DropGeometry {
    DropGeometry {
        viewport: Size { width: 1200., height: 800. },
        panes: [("p".to_owned(), Rect::new(0., 0., 1200., 800.))].into(),
        ..DropGeometry::default()
    }
}

fn dock_at(point: Point, previous: Option<&DropTarget>) -> Option<DropTarget> {
    drop_zones::dock_target(point, "s", &geometry(), &style(), 30., 20., previous)
}

fn view_target(point: Point, previous: Option<&DropTarget>) -> Option<DropTarget> {
    drop_zones::target_in_view(point, 0., "s", &geometry(), &Bars::default(), &style(), previous)
}

#[test]
fn shown_dock_holds_near_its_line() {
    for (edge, z, held, released) in [
        (DockEdge::Top, Z::Top, Point::new(600., 74.), Point::new(600., 75.)),
        (DockEdge::Bottom, Z::Bottom, Point::new(600., 744.), Point::new(600., 743.)),
        (DockEdge::Left, Z::Left, Point::new(24., 400.), Point::new(25., 400.)),
        (DockEdge::Right, Z::Right, Point::new(1176., 400.), Point::new(1175., 400.)),
    ] {
        let previous = dock(edge, "s");
        assert_eq!(dock_at(held, Some(&previous)), Some(previous.clone()), "{edge:?}");
        assert_eq!(dock_at(released, Some(&previous)), None, "{edge:?}");
        assert_eq!(dock_at(held, None), None, "{edge:?}");
        assert_eq!(view_target(released, Some(&previous)), Some(pane(z)), "{edge:?}");
    }
}

#[test]
fn pane_edge_does_not_flip_to_dock() {
    for (edge, z, near, inside) in [
        (DockEdge::Top, Z::Top, Point::new(600., 55.), Point::new(600., 49.)),
        (DockEdge::Bottom, Z::Bottom, Point::new(600., 761.), Point::new(600., 769.)),
        (DockEdge::Left, Z::Left, Point::new(9., 400.), Point::new(5., 400.)),
        (DockEdge::Right, Z::Right, Point::new(1191., 400.), Point::new(1195., 400.)),
    ] {
        let expected = dock(edge, "s");
        assert_eq!(dock_at(near, Some(&pane(z))), None, "{edge:?}");
        assert_eq!(dock_at(inside, Some(&pane(z))), Some(expected.clone()), "{edge:?}");
        for previous in [
            pane(Z::Center),
            DropTarget::NewColumn { screen: "s".into(), after: None },
            dock(edge, "other"),
        ] {
            assert_eq!(
                dock_at(near, Some(&previous)),
                Some(expected.clone()),
                "{edge:?} from {previous:?}"
            );
        }
        assert_eq!(view_target(near, Some(&pane(z))), Some(pane(z)), "{edge:?}");
        assert_eq!(dock_at(near, None), Some(expected), "{edge:?}");
    }
}

#[test]
fn dock_hysteresis_preserves_tab_bars_and_corner_order() {
    for (point, edge) in
        [(Point::new(600., 29.), DockEdge::Top), (Point::new(600., 781.), DockEdge::Bottom)]
    {
        assert_eq!(dock_at(point, Some(&dock(edge, "s"))), None, "{edge:?}");
    }
    let corner = drop_zones::dock_target(
        Point::new(2., 35.),
        "s",
        &geometry(),
        &style(),
        30.,
        0.,
        Some(&dock(DockEdge::Left, "s")),
    );
    assert_eq!(corner, Some(dock(DockEdge::Top, "s")));
}

#[test]
fn column_gap_hysteresis() {
    for offset in [0., 75.] {
        let mut geometry = geometry();
        geometry.gap_zones =
            vec![GapZone { after: Some("c".into()), frame: Rect::new(282., 0., 36., 800.) }];
        let gap = DropTarget::NewColumn { screen: "s".into(), after: Some("c".into()) };
        let target = |x: f64, previous: Option<&DropTarget>, in_view: bool| {
            let bars = Bars::default();
            if in_view {
                drop_zones::target_in_view(
                    Point::new(x - offset, 400.),
                    offset,
                    "s",
                    &geometry,
                    &bars,
                    &style(),
                    previous,
                )
            } else {
                drop_zones::target(Point::new(x, 400.), "s", &geometry, &bars, &style(), previous)
            }
        };
        for in_view in [false, true] {
            for x in [270., 329.] {
                assert_eq!(target(x, Some(&gap), in_view), Some(gap.clone()));
            }
            assert_eq!(target(269., Some(&gap), in_view), Some(pane(Z::Left)));
            assert_eq!(target(331., Some(&gap), in_view), Some(pane(Z::Center)));
            for previous in [pane(Z::Left), pane(Z::Right)] {
                assert_eq!(target(286., Some(&previous), in_view), Some(pane(Z::Left)));
                assert_eq!(target(314., Some(&previous), in_view), Some(pane(Z::Center)));
                assert_eq!(target(292., Some(&previous), in_view), Some(gap.clone()));
                assert_eq!(target(308., Some(&previous), in_view), Some(gap.clone()));
            }
            for previous in [
                pane(Z::Center),
                dock(DockEdge::Left, "s"),
                DropTarget::NewColumn { screen: "s".into(), after: None },
                DropTarget::NewColumn { screen: "other".into(), after: Some("c".into()) },
            ] {
                assert_eq!(target(283., Some(&previous), in_view), Some(gap.clone()));
                assert_eq!(target(317., Some(&previous), in_view), Some(gap.clone()));
            }
            assert_eq!(target(283., None, in_view), Some(gap.clone()));
            assert_eq!(target(317., None, in_view), Some(gap.clone()));
            assert_eq!(target(281., None, in_view), Some(pane(Z::Left)));
            assert_eq!(target(319., None, in_view), Some(pane(Z::Center)));
        }
    }
}

#[test]
fn a_point_in_no_pane_goes_to_the_nearest() {
    let mut geometry = geometry();
    geometry.panes = [
        ("a".to_owned(), Rect::new(0., 0., 100., 100.)),
        ("b".to_owned(), Rect::new(200., 0., 100., 100.)),
    ]
    .into();
    let at = |x: f64, geometry: &DropGeometry| {
        drop_zones::target(Point::new(x, 50.), "s", geometry, &Bars::default(), &style(), None)
    };
    assert_eq!(at(120., &geometry), Some(DropTarget::Pane { pane: "a".into(), zone: Z::Right }));
    assert_eq!(at(190., &geometry), Some(DropTarget::Pane { pane: "b".into(), zone: Z::Left }));
    // Equidistant: the first by pane id.
    assert_eq!(at(150., &geometry), Some(DropTarget::Pane { pane: "a".into(), zone: Z::Right }));
    geometry.panes.clear();
    assert_eq!(at(150., &geometry), None);
}

fn column_dock(edge: DockEdge) -> Option<Dock> {
    Some(Dock {
        column: format!("{edge:?}"),
        mode: Some(DockMode::Docked),
        edge: Some(edge),
        width: 0.5,
        minimum_extent: 0.,
    })
}

#[test]
fn a_lone_dock_fills_the_screen() {
    let parts = dock_strip::parts(&[Some(DockEdge::Left)]);
    assert_eq!(parts.left, None);
    assert_eq!(parts.scrolling, vec![0]);
    assert!(parts.lone, "the lone dock shows at width 1");
    let beside = dock_strip::parts(&[Some(DockEdge::Left), None]);
    assert_eq!(beside.left, Some(0), "with a column beside it the dock is a dock again");
    assert_eq!(beside.scrolling, vec![1]);
    assert!(!beside.lone);
    let docks_only = dock_strip::parts(&[Some(DockEdge::Left), Some(DockEdge::Right)]);
    assert_eq!(docks_only.scrolling, vec![0, 1]);
    assert!(!docks_only.lone);
    let twice = dock_strip::parts(&[Some(DockEdge::Top), Some(DockEdge::Top), None]);
    assert_eq!(
        (twice.top, twice.scrolling),
        (Some(0), vec![1, 2]),
        "the first dock per edge holds it"
    );
}

#[test]
fn docked_side_docks_leave_the_minimum_strip() {
    let docks = Docks {
        left: column_dock(DockEdge::Left),
        right: column_dock(DockEdge::Right),
        ..Docks::default()
    };
    let p = dock_strip::place(
        &docks,
        Size { width: 1000., height: 600. },
        6.,
        FrameOrientation::ColumnMajor,
        2.,
    );
    // Each wants min(0.5 fraction, 0.4 share) = 400; 800 + 12 gaps leaves less than 400, so both shrink.
    assert!(p.strip_width >= 400. - 1., "{p:?}");
    assert_eq!(p.dock.len(), 2);
    assert_eq!(p.dock[0].frame.x, 6.);
    assert_eq!(p.strip_min_x, p.dock[0].frame.max_x());
}

#[test]
fn orientation_decides_the_corners() {
    let docks = Docks {
        left: column_dock(DockEdge::Left),
        top: column_dock(DockEdge::Top),
        ..Docks::default()
    };
    let size = Size { width: 1200., height: 800. };
    let column = dock_strip::place(&docks, size, 6., FrameOrientation::ColumnMajor, 2.);
    let row = dock_strip::place(&docks, size, 6., FrameOrientation::RowMajor, 2.);
    let (left_c, top_c) = (column.dock[0].frame, column.dock[1].frame);
    let (left_r, top_r) = (row.dock[0].frame, row.dock[1].frame);
    assert_eq!((left_c.y, left_c.h), (0., 800.), "column-major sides run the full height");
    assert_eq!(top_c.x, left_c.max_x() + 6.);
    assert_eq!(top_r.x, 6., "row-major bands run the full width");
    assert_eq!(left_r.y, top_r.max_y() + 6.);
    assert!(dock_strip::owns_corners(DockEdge::Left, FrameOrientation::ColumnMajor));
    assert!(!dock_strip::owns_corners(DockEdge::Top, FrameOrientation::ColumnMajor));
    assert!(dock_strip::owns_corners(DockEdge::Top, FrameOrientation::RowMajor));
}

#[test]
fn divider_band_centers_its_line_on_the_pixel_grid() {
    for scale in [1., 2., 3.] {
        let band = DividerBand::new(SplitAxis::Horizontal, 100.3, 1., 7., 0., 300., scale);
        assert!((band.line.mid_x() - 100.3).abs() <= 0.5 / scale + 1e-9, "{band:?}");
        assert!((band.hit.mid_x() - band.line.mid_x()).abs() < 1e-9, "{band:?}");
        assert_eq!((band.line.y, band.line.h), (0., 300.));
    }
}
