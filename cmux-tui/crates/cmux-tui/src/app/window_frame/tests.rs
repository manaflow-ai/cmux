use super::*;

fn rect(x: u16, y: u16, width: u16, height: u16) -> Rect {
    Rect { x, y, width, height }
}

fn dock(edge: DockEdge, extent_permille: u16) -> WindowDock {
    WindowDock { extent_permille, ..WindowDock::new(edge, format!("{edge:?}")) }
}

fn floating(edge: DockEdge, extent_permille: u16) -> WindowDock {
    WindowDock { mode: DockMode::Floating, ..dock(edge, extent_permille) }
}

fn placed(edge: DockEdge, rect: Rect) -> DockPlacement {
    DockPlacement { edge, rect, floating: false }
}

#[test]
fn no_docks_leave_the_whole_area_to_the_stage() {
    let area = rect(22, 0, 100, 40);
    let frame = place_frame(area, &[], DockOrientation::ColumnMajor);
    assert_eq!(frame, FramePlacement { stage: area, docks: Vec::new() });
}

#[test]
fn column_major_side_docks_take_the_full_height() {
    let docks = [dock(DockEdge::Left, 300), dock(DockEdge::Bottom, 250)];
    let frame = place_frame(rect(0, 0, 100, 40), &docks, DockOrientation::ColumnMajor);
    assert_eq!(frame.stage, rect(30, 0, 70, 30));
    assert_eq!(
        frame.docks,
        [
            placed(DockEdge::Left, rect(0, 0, 30, 40)),
            placed(DockEdge::Bottom, rect(30, 30, 70, 10))
        ]
    );
}

#[test]
fn row_major_bands_take_the_full_width() {
    let docks = [dock(DockEdge::Left, 300), dock(DockEdge::Bottom, 250)];
    let frame = place_frame(rect(0, 0, 100, 40), &docks, DockOrientation::RowMajor);
    assert_eq!(frame.stage, rect(30, 0, 70, 30));
    assert_eq!(
        frame.docks,
        [
            placed(DockEdge::Bottom, rect(0, 30, 100, 10)),
            placed(DockEdge::Left, rect(0, 0, 30, 30))
        ]
    );
}

#[test]
fn every_edge_places_around_an_offset_area() {
    let docks = [
        dock(DockEdge::Top, 200),
        dock(DockEdge::Right, 200),
        dock(DockEdge::Bottom, 200),
        dock(DockEdge::Left, 200),
    ];
    let frame = place_frame(rect(20, 1, 100, 50), &docks, DockOrientation::ColumnMajor);
    assert_eq!(frame.stage, rect(40, 11, 60, 30));
    assert_eq!(
        frame.docks,
        [
            placed(DockEdge::Left, rect(20, 1, 20, 50)),
            placed(DockEdge::Right, rect(100, 1, 20, 50)),
            placed(DockEdge::Top, rect(40, 1, 60, 10)),
            placed(DockEdge::Bottom, rect(40, 41, 60, 10)),
        ]
    );
}

#[test]
fn a_side_dock_takes_at_most_half_and_two_fifths_beside_another() {
    let alone = place_frame(
        rect(0, 0, 100, 40),
        &[dock(DockEdge::Left, 900)],
        DockOrientation::ColumnMajor,
    );
    assert_eq!(alone.docks[0].rect.width, 50);
    assert_eq!(alone.stage, rect(50, 0, 50, 40));

    let both = place_frame(
        rect(0, 0, 100, 40),
        &[dock(DockEdge::Left, 900), dock(DockEdge::Right, 900)],
        DockOrientation::ColumnMajor,
    );
    assert_eq!(both.docks[0].rect, rect(0, 0, 40, 40));
    assert_eq!(both.docks[1].rect, rect(60, 0, 40, 40));
    assert_eq!(both.stage, rect(40, 0, 20, 40));
}

#[test]
fn a_band_takes_at_most_half_and_a_third_beside_another() {
    let alone =
        place_frame(rect(0, 0, 100, 40), &[dock(DockEdge::Top, 900)], DockOrientation::ColumnMajor);
    assert_eq!(alone.docks[0].rect, rect(0, 0, 100, 20));

    let both = place_frame(
        rect(0, 0, 100, 40),
        &[dock(DockEdge::Top, 900), dock(DockEdge::Bottom, 900)],
        DockOrientation::ColumnMajor,
    );
    assert_eq!(both.docks[0].rect, rect(0, 0, 100, 13));
    assert_eq!(both.docks[1].rect, rect(0, 27, 100, 13));
    assert_eq!(both.stage, rect(0, 13, 100, 14));
}

#[test]
fn an_extent_below_the_record_minimum_counts_as_the_minimum() {
    let frame =
        place_frame(rect(0, 0, 200, 40), &[dock(DockEdge::Left, 10)], DockOrientation::ColumnMajor);
    assert_eq!(frame.docks[0].rect.width, 20);
}

#[test]
fn a_dock_is_never_smaller_than_one_pane() {
    let frame =
        place_frame(rect(0, 0, 60, 40), &[dock(DockEdge::Left, 100)], DockOrientation::ColumnMajor);
    assert_eq!(frame.docks[0].rect.width, MIN_DOCK_COLS);
}

#[test]
fn a_frame_too_small_for_a_pane_places_no_dock() {
    let area = rect(0, 0, 20, 6);
    let frame = place_frame(
        area,
        &[dock(DockEdge::Left, 300), dock(DockEdge::Bottom, 300)],
        DockOrientation::ColumnMajor,
    );
    assert_eq!(frame, FramePlacement { stage: area, docks: Vec::new() });
}

#[test]
fn a_dock_that_would_leave_too_small_a_stage_is_skipped() {
    let frame = place_frame(
        rect(0, 0, 40, 20),
        &[dock(DockEdge::Left, 900), dock(DockEdge::Right, 900)],
        DockOrientation::ColumnMajor,
    );
    assert_eq!(frame.docks, [placed(DockEdge::Left, rect(0, 0, 16, 20))]);
    assert_eq!(frame.stage, rect(16, 0, 24, 20));
}

#[test]
fn a_hidden_dock_is_not_placed_and_keeps_the_stage() {
    let area = rect(0, 0, 100, 40);
    let hidden = WindowDock { hidden: true, ..dock(DockEdge::Left, 300) };
    let frame = place_frame(area, &[hidden], DockOrientation::ColumnMajor);
    assert_eq!(frame, FramePlacement { stage: area, docks: Vec::new() });
}

#[test]
fn a_floating_dock_never_resizes_the_stage() {
    let area = rect(0, 0, 100, 40);
    let frame = place_frame(area, &[floating(DockEdge::Left, 300)], DockOrientation::ColumnMajor);
    assert_eq!(frame.stage, area);
    assert_eq!(
        frame.docks,
        [DockPlacement { edge: DockEdge::Left, rect: rect(0, 0, 30, 40), floating: true }]
    );
}

#[test]
fn a_floating_dock_floats_over_the_stage_and_draws_last() {
    let docks = [floating(DockEdge::Left, 300), dock(DockEdge::Bottom, 250)];
    let frame = place_frame(rect(0, 0, 100, 40), &docks, DockOrientation::ColumnMajor);
    assert_eq!(frame.stage, rect(0, 0, 100, 30));
    assert_eq!(
        frame.docks,
        [
            placed(DockEdge::Bottom, rect(0, 30, 100, 10)),
            DockPlacement { edge: DockEdge::Left, rect: rect(0, 0, 30, 30), floating: true },
        ]
    );
}

#[test]
fn only_the_first_dock_of_an_edge_is_placed() {
    let docks = [dock(DockEdge::Left, 300), dock(DockEdge::Left, 500)];
    let frame = place_frame(rect(0, 0, 100, 40), &docks, DockOrientation::ColumnMajor);
    assert_eq!(frame.docks, [placed(DockEdge::Left, rect(0, 0, 30, 40))]);
}

#[test]
fn orientation_never_changes_extents() {
    let docks = [dock(DockEdge::Left, 300), dock(DockEdge::Top, 250)];
    for orientation in [DockOrientation::ColumnMajor, DockOrientation::RowMajor] {
        let frame = place_frame(rect(0, 0, 100, 40), &docks, orientation);
        let left = frame.docks.iter().find(|dock| dock.edge == DockEdge::Left).unwrap();
        let top = frame.docks.iter().find(|dock| dock.edge == DockEdge::Top).unwrap();
        assert_eq!((left.rect.width, top.rect.height), (30, 10), "{orientation:?}");
    }
}

#[test]
fn the_record_reads_the_app_field_names() {
    let dock: WindowDock = serde_json::from_value(serde_json::json!({
        "edge": "bottom",
        "workspace_key": "6ba7b810-9dad-41d1-80b4-00c04fd430c8",
        "mode": "floating",
        "extent_permille": 400,
        "hidden": true,
    }))
    .unwrap();
    assert_eq!(dock.edge, DockEdge::Bottom);
    assert_eq!(dock.mode, DockMode::Floating);
    assert_eq!(dock.extent_permille, 400);
    assert!(dock.hidden);
    let minimal: WindowDock =
        serde_json::from_value(serde_json::json!({"edge": "left", "workspace_key": "k"})).unwrap();
    assert_eq!(minimal, WindowDock::new(DockEdge::Left, "k"));
    assert_eq!(
        serde_json::to_value(DockOrientation::RowMajor).unwrap(),
        serde_json::json!("row_major")
    );
}
