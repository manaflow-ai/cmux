//! The Swift strip, window dock and moved window tests, ported (CmuxNextAppTests `ColumnStripFitTests`,
//! `WindowDocksTests`' placement cases, `MoveToNewWindowTests`' placement cases).

use super::column_strip::{
    self, ColumnDock, ColumnResize, EqualizeColumn, scrollbar_page_target, scrollbar_thumb,
};
use super::dock_strip::{DockMode, FrameOrientation};
use super::width_ledger::{self, LedgerChange, LedgerColumn};
use super::window_frame::{self, MINIMUM_SIDE, MOVED_WINDOW_GAP, WindowDock, WindowPlacement};
use super::{DockEdge, Point, Rect, Size};
use std::collections::BTreeSet;

const VIEWPORTS: [f64; 6] = [600.5, 1000., 1200.25, 1279.75, 1437.5, 1919.75];

#[test]
fn equal_columns_fill_the_viewport_without_overflow() {
    let gap = 8.;
    for count in 1..=6 {
        for scale in [1., 2.] {
            for viewport in VIEWPORTS {
                let widths = vec![1.0 / count as f64; count];
                let (frames, content) = column_strip::frames(
                    &widths,
                    Size { width: viewport, height: 800. },
                    gap,
                    scale,
                    &[],
                );
                assert!(
                    (content - viewport).abs() < 0.001,
                    "{count} at {scale} in {viewport}: {content}"
                );
                let last = frames.last().map_or(0., |f| f.max_x());
                assert!(
                    (last + gap - viewport).abs() < 0.001,
                    "{count} at {scale} in {viewport}: ends {last}"
                );
                assert!(column_strip::max_offset(content, viewport) < 0.001);
            }
        }
    }
}

#[test]
fn a_column_past_the_edge_keeps_its_width() {
    for scale in [1., 2.] {
        for viewport in VIEWPORTS {
            let (frames, content) = column_strip::frames(
                &[1., 1.],
                Size { width: viewport, height: 800. },
                8.,
                scale,
                &[],
            );
            assert!((frames[1].width() - frames[0].width()).abs() <= 1., "{viewport}");
            assert!(column_strip::max_offset(content, viewport) > viewport / 2.);
        }
    }
}

#[test]
fn snaps_are_ascending_deduplicated_and_clamped() {
    let (frames, content) =
        column_strip::frames(&[0.5, 0.5, 0.5], Size { width: 1000., height: 800. }, 8., 2., &[]);
    let snaps = column_strip::snap_offsets(&frames, content, 1000., 8.);
    assert_eq!(snaps.first(), Some(&0.));
    assert_eq!(snaps.last(), Some(&column_strip::max_offset(content, 1000.)));
    assert!(snaps.windows(2).all(|pair| pair[1] - pair[0] > 0.5), "{snaps:?}");
    assert_eq!(column_strip::leading_column_index(&frames, frames[1].min_x() - 8., 8.), Some(1));
    assert_eq!(column_strip::leading_column_index(&[], 0., 8.), None);
}

#[test]
fn the_thumb_shows_the_visible_share_and_pages_toward_a_click() {
    let track = Rect::new(0., 0., 1000., 6.);
    assert_eq!(scrollbar_thumb(track, 0., 1000., 1000., 40.), None, "B1: nothing to scroll");
    let thumb = scrollbar_thumb(track, 0., 2000., 1000., 40.).expect("thumb");
    assert_eq!(thumb, Rect::new(0., 0., 500., 6.));
    let end = scrollbar_thumb(track, 1000., 2000., 1000., 40.).expect("thumb");
    assert_eq!(end.max_x(), 1000.);
    let banded = scrollbar_thumb(track, 1200., 2000., 1000., 40.).expect("thumb");
    assert!(
        banded.width() < 500. && banded.max_x() == 1000.,
        "rubber band shortens at the end: {banded:?}"
    );
    assert_eq!(column_strip::scrollbar_offset(250., 500., track, 1000.), 500.);
    let snaps = [0., 400., 800., 1000.];
    assert_eq!(scrollbar_page_target(900., thumb, 0., 1000., &snaps), Some(1000.), "B3");
    assert_eq!(scrollbar_page_target(100., thumb, 0., 1000., &snaps), None, "a click on the thumb");
    assert_eq!(
        scrollbar_page_target(10., Rect::new(500., 0., 500., 6.), 1000., 300., &snaps),
        Some(800.)
    );
}

fn column(
    id: &str,
    width: f64,
    dock: Option<(DockEdge, DockMode)>,
    minimum: f64,
) -> EqualizeColumn {
    EqualizeColumn {
        id: id.into(),
        width,
        dock: dock.map(|(edge, mode)| ColumnDock { edge, mode }),
        minimum,
    }
}

#[test]
fn equalize_gives_strip_columns_equal_shares_beside_a_docked_dock() {
    let none = BTreeSet::new();
    let strip = [column("a", 0.5, None, 0.), column("b", 0.25, None, 0.)];
    assert_eq!(
        column_strip::equalize(&strip, &none, 1440., 8.),
        vec![ColumnResize { column: "b".into(), width: 0.5 }]
    );
    let docked = [
        column("chief", 0.3, Some((DockEdge::Left, DockMode::Docked)), 300.),
        column("a", 1., None, 0.),
        column("b", 1., None, 0.),
    ];
    let resizes = column_strip::equalize(&docked, &none, 1440., 8.);
    // W = (1440 - 4 * 8) / 3 = 469.33; the dock's fraction is (W + gap) / (viewport - gap).
    let dock = resizes.iter().find(|r| r.column == "chief").expect("dock resize");
    assert!((dock.width - (469.333_333_333_333_3 + 8.) / 1432.).abs() < 1e-9, "{dock:?}");
    assert!(resizes.iter().filter(|r| r.column != "chief").all(|r| r.width == 0.5));
    let lone = [column("chief", 0.3, Some((DockEdge::Left, DockMode::Docked)), 0.)];
    assert!(
        column_strip::equalize(&lone, &none, 1440., 8.).is_empty(),
        "a lone dock keeps its width"
    );
}

const FRAME: Rect = Rect::new(0., 0., 1000., 800.);

fn place(
    items: &[(&str, DockEdge, DockMode, i64)],
    orientation: FrameOrientation,
) -> WindowPlacement {
    let docks: Vec<WindowDock> = items
        .iter()
        .map(|&(id, edge, mode, extent)| WindowDock {
            workspace: id.into(),
            edge,
            mode,
            extent_permille: extent,
            hidden: false,
        })
        .collect();
    window_frame::place(&docks, orientation, 8., FRAME)
}

#[test]
fn no_docks_gives_the_stage_the_whole_frame() {
    let placed = place(&[], FrameOrientation::ColumnMajor);
    assert_eq!(placed.stage, FRAME);
    assert!(placed.docks.is_empty());
}

#[test]
fn a_docked_left_dock_takes_its_share_and_the_stage_the_rest() {
    let placed =
        place(&[("ws-l", DockEdge::Left, DockMode::Docked, 300)], FrameOrientation::ColumnMajor);
    assert_eq!(placed.frame_of("ws-l"), Some(Rect::new(0., 0., 300., 800.)));
    assert_eq!(placed.stage, Rect::new(308., 0., 692., 800.));
}

#[test]
fn column_major_side_docks_own_the_corners_and_row_major_bands_do() {
    let items = [
        ("ws-l", DockEdge::Left, DockMode::Docked, 250),
        ("ws-b", DockEdge::Bottom, DockMode::Docked, 250),
    ];
    let placed = place(&items, FrameOrientation::ColumnMajor);
    assert_eq!(placed.frame_of("ws-l"), Some(Rect::new(0., 0., 250., 800.)));
    assert_eq!(placed.frame_of("ws-b"), Some(Rect::new(258., 600., 742., 200.)));
    assert_eq!(placed.stage, Rect::new(258., 0., 742., 592.));
    let placed = place(&items, FrameOrientation::RowMajor);
    assert_eq!(placed.frame_of("ws-b"), Some(Rect::new(0., 600., 1000., 200.)));
    assert_eq!(placed.frame_of("ws-l"), Some(Rect::new(0., 0., 250., 592.)));
    assert_eq!(placed.stage, Rect::new(258., 0., 742., 592.));
}

#[test]
fn a_floating_dock_never_resizes_the_stage_and_a_hidden_one_is_not_placed() {
    let placed =
        place(&[("ws-r", DockEdge::Right, DockMode::Overlay, 400)], FrameOrientation::ColumnMajor);
    assert_eq!(placed.stage, FRAME, "W8");
    assert_eq!(placed.frame_of("ws-r"), Some(Rect::new(600., 0., 400., 800.)));
    assert!(placed.docks[0].floating);
    let hidden = WindowDock {
        workspace: "ws-l".into(),
        edge: DockEdge::Left,
        mode: DockMode::Docked,
        extent_permille: 300,
        hidden: true,
    };
    let placed = window_frame::place(&[hidden], FrameOrientation::ColumnMajor, 8., FRAME);
    assert_eq!(placed.stage, FRAME);
    assert_eq!(placed.frame_of("ws-l"), None);
}

#[test]
fn shares_are_clamped_per_edge_count_and_never_below_the_minimum() {
    let side = FrameOrientation::ColumnMajor;
    let one = place(&[("ws-l", DockEdge::Left, DockMode::Docked, 900)], side);
    assert_eq!(
        one.frame_of("ws-l").map(|f| f.width()),
        Some(500.),
        "W6: one side dock at most half"
    );
    let two = place(
        &[
            ("ws-l", DockEdge::Left, DockMode::Docked, 900),
            ("ws-r", DockEdge::Right, DockMode::Docked, 900),
        ],
        side,
    );
    assert_eq!(two.frame_of("ws-l").map(|f| f.width()), Some(400.));
    assert_eq!(two.frame_of("ws-r").map(|f| f.width()), Some(400.));
    let bands = place(
        &[
            ("ws-t", DockEdge::Top, DockMode::Docked, 900),
            ("ws-b", DockEdge::Bottom, DockMode::Docked, 900),
        ],
        side,
    );
    assert_eq!(
        bands.frame_of("ws-t").map(|f| f.height()),
        Some(266.),
        "W6: two bands at most 1/3 each"
    );
    let small = place(&[("ws-l", DockEdge::Left, DockMode::Docked, 100)], side);
    assert_eq!(small.frame_of("ws-l").map(|f| f.width()), Some(MINIMUM_SIDE));
}

#[test]
fn dock_at_point_finds_the_topmost_dock() {
    let placed = place(
        &[
            ("ws-r", DockEdge::Right, DockMode::Overlay, 400),
            ("ws-l", DockEdge::Left, DockMode::Docked, 300),
        ],
        FrameOrientation::ColumnMajor,
    );
    assert_eq!(placed.workspace_at(Point::new(700., 100.)), Some("ws-r"));
    assert_eq!(placed.workspace_at(Point::new(100., 100.)), Some("ws-l"));
    assert_eq!(placed.workspace_at(Point::new(450., 100.)), None, "the stage");
}

#[test]
fn the_new_window_opens_beside_the_old_one() {
    let screen = Rect::new(0., 0., 3000., 1000.);
    let gap = MOVED_WINDOW_GAP;
    let left = Rect::new(100., 100., 1000., 700.);
    assert_eq!(
        window_frame::moved_window_frame(left, screen, gap),
        Rect::new(1100. + gap, 100., 1000., 700.)
    );
    let right = Rect::new(1900., 100., 1000., 700.);
    assert_eq!(
        window_frame::moved_window_frame(right, screen, gap),
        Rect::new(900. - gap, 100., 1000., 700.)
    );
    let wide = Rect::new(200., 200., 2600., 700.);
    let cascaded = window_frame::moved_window_frame(wide, screen, gap);
    assert!(cascaded.width() == wide.width() && cascaded.height() == wide.height());
    assert!(cascaded != wide && screen.contains_rect(&cascaded));
}

#[test]
fn three_moves_from_one_window_each_get_a_spot_of_their_own() {
    let screen = Rect::new(0., 0., 1512., 944.);
    for source in [screen, Rect::new(20., 20., 1480., 900.), Rect::new(206., 112., 1100., 720.)] {
        let mut open = vec![source];
        for _ in 0..3 {
            let next =
                window_frame::moved_window_frame_avoiding(source, screen, &open, MOVED_WINDOW_GAP);
            open.push(next);
        }
        let spots: BTreeSet<(i64, i64)> =
            open.iter().map(|f| (f.min_x().round() as i64, f.max_y().round() as i64)).collect();
        assert_eq!(spots.len(), open.len(), "two windows share a top-left: {open:?}");
    }
}

fn ledger_column(id: Option<&str>, panes: &[&str], width: f64) -> LedgerColumn {
    LedgerColumn {
        id: id.map(Into::into),
        panes: panes.iter().map(|&pane| pane.into()).collect(),
        width,
        docked: false,
    }
}

#[test]
fn the_ledger_catches_a_create_that_resizes_another_column() {
    let before = [ledger_column(Some("a"), &["p1"], 700.), ledger_column(Some("b"), &["p2"], 700.)];
    let mut after = before.to_vec();
    after.push(ledger_column(Some("c"), &["p3"], 400.));
    let record =
        width_ledger::note_change(None, &before, &after, 1440.).expect("a create is recorded");
    assert_eq!(width_ledger::note_change(None, &before, &before, 1440.), None, "no create");
    let settled = [
        ledger_column(Some("a"), &["p1"], 700.),
        ledger_column(Some("b"), &["p2"], 500.),
        ledger_column(Some("c"), &["p3"], 400.),
    ];
    assert_eq!(
        width_ledger::take(Some(&record), &settled, 1440.),
        vec![LedgerChange { column: "b".into(), before: 700., after: 500. }]
    );
    assert!(
        width_ledger::take(Some(&record), &settled, 1200.).is_empty(),
        "the screen's width changed"
    );
    let split =
        [ledger_column(Some("a"), &["p1", "p9"], 300.), ledger_column(Some("b"), &["p2"], 700.)];
    assert!(
        width_ledger::take(Some(&record), &split, 1440.).is_empty(),
        "a column that took a new pane"
    );
}
