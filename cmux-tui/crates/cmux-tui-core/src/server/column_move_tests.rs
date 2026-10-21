//! Wire tests for `move-column` (`column-move-v1`): a whole viewport column,
//! every pane and split inside it, trades places with its neighbor in one
//! commit, records one `undo-layout` entry, and never crosses a docked
//! column.

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    fn new() -> Self {
        let mux = Mux::new_for_test("column-move", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        Self { mux, outbound, writer, next_id: 1 }
    }

    /// One workspace whose screen has `count` viewport columns, each holding
    /// one pane. Returns the panes in column order.
    fn with_columns(count: usize) -> (Self, Vec<PaneId>) {
        let wire = Self::new();
        let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
        let mut panes = vec![wire.mux.with_state(|state| state.pane_of(first.id).unwrap())];
        for _ in 1..count {
            let last = *panes.last().unwrap();
            let surface = wire.mux.new_pane_right(last, 0.5, Some((38, 22))).unwrap();
            panes.push(wire.mux.with_state(|state| state.pane_of(surface.id).unwrap()));
        }
        (wire, panes)
    }

    fn send(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        handle_message(
            &self.mux,
            self.mux.local_test_client(7),
            &request.to_string(),
            &self.writer,
        );
        let response: Value = serde_json::from_str(&self.outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id, "response must answer the request: {response}");
        response
    }

    fn ok(&mut self, request: Value) -> Value {
        let response = self.send(request.clone());
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        response["data"].clone()
    }

    fn refused(&mut self, request: Value) -> Value {
        let response = self.send(request.clone());
        assert_eq!(response["ok"], false, "{request} must be refused: {response}");
        response
    }

    fn move_column(&mut self, pane: PaneId, direction: &str) -> Value {
        json!({"cmd": "move-column", "pane": pane, "direction": direction})
    }

    /// Each column of the first screen: its id, width and panes in order.
    fn columns(&self) -> Vec<(SplitId, f32, Vec<PaneId>)> {
        self.mux.with_state(|state| {
            state.workspaces[0].screens[0]
                .layout_columns
                .iter()
                .map(|column| (column.id, column.width, column.root.pane_ids_vec()))
                .collect()
        })
    }

    fn active_pane(&self) -> PaneId {
        self.mux.with_state(|state| state.workspaces[0].screens[0].active_pane)
    }
}

#[test]
fn column_move_capability_is_advertised() {
    let mut wire = Wire::new();
    let identity = wire.ok(json!({"cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "column-move-v1"),
        "{identity}"
    );
}

#[test]
fn column_move_swaps_a_multi_pane_column_with_its_neighbor() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.mux.split(panes[1], SplitDir::Down, Some((38, 10))).unwrap();
    let before = wire.columns();
    assert_eq!(before[1].2.len(), 2, "the middle column holds two panes");
    let lower = before[1].2[1];
    let focused = wire.active_pane();

    let request = wire.move_column(lower, "right");
    let data = wire.ok(request);
    assert_eq!(data["changed"], true, "{data}");
    assert_eq!(data["column"], json!(before[1].0), "{data}");
    assert_eq!(data["index"], 2, "{data}");

    let after = wire.columns();
    assert_eq!(after, vec![before[0].clone(), before[2].clone(), before[1].clone()]);
    assert_eq!(wire.active_pane(), focused, "a column move keeps the focus");

    let request = wire.move_column(before[1].2[0], "left");
    wire.ok(request);
    assert_eq!(wire.columns(), before, "moving back restores the order");
}

#[test]
fn column_move_is_one_undo_entry() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.mux.split(panes[0], SplitDir::Down, Some((38, 10))).unwrap();
    let before = wire.columns();
    let request = wire.move_column(panes[0], "right");
    wire.ok(request);
    assert_ne!(wire.columns(), before);
    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[0]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert_eq!(wire.columns(), before);
}

#[test]
fn column_move_refuses_the_edge_and_a_split_screen() {
    let (mut wire, panes) = Wire::with_columns(2);
    let request = wire.move_column(panes[0], "left");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "column-move-edge", "{response}");
    let request = wire.move_column(panes[1], "right");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "column-move-edge", "{response}");

    // A screen stored as one split tree is one implicit column.
    let (mut wire, panes) = Wire::with_columns(1);
    wire.mux.split(panes[0], SplitDir::Down, Some((80, 10))).unwrap();
    let request = wire.move_column(panes[0], "right");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "column-move-edge", "{response}");
}

#[test]
fn column_move_never_crosses_or_moves_a_docked_column() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.ok(json!({
        "cmd": "set-column-dock",
        "pane": panes[2],
        "dock": true,
        "edge": "right",
        "mode": "docked",
    }));
    let before = wire.columns();
    let request = wire.move_column(panes[1], "right");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "column-move-edge", "{response}");
    let request = wire.move_column(panes[2], "left");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "column-move-docked", "{response}");
    assert_eq!(wire.columns(), before, "a refused move changes nothing");
}

#[test]
fn column_move_refuses_an_unknown_pane_and_a_bad_direction() {
    let (mut wire, panes) = Wire::with_columns(2);
    let request = wire.move_column(9_999, "left");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "column-move-missing", "{response}");
    let request = wire.move_column(panes[0], "up");
    let response = wire.refused(request);
    assert_eq!(response["error_code"], "invalid-argument", "{response}");
}
