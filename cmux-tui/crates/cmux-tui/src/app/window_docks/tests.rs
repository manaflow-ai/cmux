use super::*;

fn record(docks: &[(DockEdge, &str)]) -> WindowFrameRecord {
    WindowFrameRecord {
        docks: docks.iter().map(|(edge, key)| WindowDock::new(*edge, *key)).collect(),
        ..WindowFrameRecord::default()
    }
}

fn edges(record: &WindowFrameRecord) -> Vec<(DockEdge, &str)> {
    record.docks.iter().map(|dock| (dock.edge, dock.workspace_key.as_str())).collect()
}

#[test]
fn docking_on_an_occupied_edge_returns_the_old_workspace_to_the_sidebar() {
    let mut frame = record(&[(DockEdge::Left, "a")]);
    assert_eq!(frame.dock("b", DockEdge::Left).as_deref(), Some("a"));
    assert_eq!(edges(&frame), [(DockEdge::Left, "b")]);
}

#[test]
fn a_workspace_moves_between_edges_and_keeps_its_mode() {
    let mut frame = record(&[(DockEdge::Left, "a")]);
    frame.toggle_floating("a");
    assert_eq!(frame.dock("a", DockEdge::Bottom), None);
    assert_eq!(edges(&frame), [(DockEdge::Bottom, "a")]);
    assert_eq!(frame.docks[0].mode, DockMode::Floating);
}

#[test]
fn docking_the_stage_workspace_clears_the_stage_key() {
    let mut frame = WindowFrameRecord { stage_key: Some("a".into()), ..record(&[]) };
    frame.dock("a", DockEdge::Right);
    assert_eq!(frame.stage_key, None);
}

#[test]
fn toggle_hides_and_shows_the_edge_and_selection_shows_it() {
    let mut frame = record(&[(DockEdge::Top, "a")]);
    assert_eq!(frame.toggle_hidden(DockEdge::Top), Some(true));
    assert_eq!(frame.toggle_hidden(DockEdge::Bottom), None);
    assert!(frame.show("a"));
    assert!(!frame.show("a"));
    assert!(!frame.dock_of("a").unwrap().hidden);
}

#[test]
fn undock_and_orientation() {
    let mut frame = record(&[(DockEdge::Left, "a"), (DockEdge::Right, "b")]);
    assert!(frame.undock("a"));
    assert!(!frame.undock("a"));
    frame.toggle_orientation();
    assert_eq!(frame.dock_orientation, DockOrientation::RowMajor);
    assert_eq!(edges(&frame), [(DockEdge::Right, "b")]);
}

#[test]
fn closed_workspaces_lose_their_docks() {
    let mut frame = WindowFrameRecord {
        stage_key: Some("gone-stage".into()),
        ..record(&[(DockEdge::Left, "a"), (DockEdge::Right, "gone"), (DockEdge::Left, "c")])
    };
    assert!(frame.retain_live(|key| !key.starts_with("gone")));
    assert_eq!(edges(&frame), [(DockEdge::Left, "a")]);
    assert_eq!(frame.stage_key, None);
    assert!(!frame.retain_live(|_| true));
}

#[test]
fn the_stage_shows_the_last_workspace_that_is_not_docked() {
    let order = ["a", "b", "c", "d"];
    let mut frame = record(&[(DockEdge::Left, "b")]);
    assert_eq!(frame.stage_for("a", &[], &order), Some("a"));
    // A docked workspace holds focus: the stage keeps its key.
    frame.stage_key = Some("c".into());
    assert_eq!(frame.stage_for("b", &[], &order), Some("c"));
    // No key: the most recently shown, then the first in order.
    frame.stage_key = None;
    assert_eq!(frame.stage_for("b", &["d".into(), "a".into()], &order), Some("a"));
    assert_eq!(frame.stage_for("b", &[], &order), Some("a"));
    let everything = record(&[(DockEdge::Left, "a"), (DockEdge::Right, "b")]);
    assert_eq!(everything.stage_for("a", &[], &["a", "b"]), None);
}

#[test]
fn the_record_round_trips_with_the_app_field_names() {
    let mut frame = record(&[(DockEdge::Bottom, "k")]);
    frame.stage_key = Some("s".into());
    let value = serde_json::to_value(&frame).unwrap();
    assert_eq!(value["docks"][0]["edge"], "bottom");
    assert_eq!(value["dock_orientation"], "column_major");
    assert_eq!(value["stage_key"], "s");
    assert_eq!(serde_json::from_value::<WindowFrameRecord>(value).unwrap(), frame);
    assert_eq!(
        serde_json::from_value::<WindowFrameRecord>(serde_json::json!({})).unwrap(),
        WindowFrameRecord::default()
    );
}
