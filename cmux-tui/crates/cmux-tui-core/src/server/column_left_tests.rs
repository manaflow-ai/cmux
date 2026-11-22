//! Wire tests for `new-pane-right {side: "left"}` (`column-left-v1`, New
//! Column Left): the new column opens immediately left of the pane's column,
//! on a split screen and between two columns, focused, with its width; an
//! unknown side or a left browser column is refused and creates nothing.

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    /// One workspace whose screen has `count` viewport columns (a lone split
    /// screen for 1), each holding one pane. Returns the panes in order.
    fn with_columns(count: usize) -> (Self, Vec<PaneId>) {
        let mux = Mux::new_for_test("column-left", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let mut panes = vec![mux.with_state(|state| state.pane_of(first.id).unwrap())];
        for _ in 1..count {
            let last = *panes.last().unwrap();
            let surface = mux.new_pane_right(last, 0.5, Some((38, 22))).unwrap();
            panes.push(mux.with_state(|state| state.pane_of(surface.id).unwrap()));
        }
        (Self { mux, outbound, writer, next_id: 1 }, panes)
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

    /// The pane the request created.
    fn created(&mut self, request: Value) -> PaneId {
        let response = self.send(request.clone());
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        let surface: SurfaceId =
            serde_json::from_value(response["data"]["surface"].clone()).unwrap();
        self.mux.with_state(|state| state.pane_of(surface).unwrap())
    }

    /// Each column of the first screen: its width and panes in order.
    fn columns(&self) -> Vec<(f32, Vec<PaneId>)> {
        self.mux.with_state(|state| {
            state.workspaces[0].screens[0]
                .layout_columns
                .iter()
                .map(|column| (column.width, column.root.pane_ids_vec()))
                .collect()
        })
    }

    fn active_pane(&self) -> PaneId {
        self.mux.with_state(|state| state.workspaces[0].screens[0].active_pane)
    }
}

#[test]
fn column_left_capability_is_advertised() {
    let (mut wire, _) = Wire::with_columns(1);
    let identity = wire.send(json!({"cmd": "identify"}));
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "column-left-v1"),
        "{identity}"
    );
}

#[test]
fn side_left_on_a_split_screen_opens_the_first_column() {
    let (mut wire, panes) = Wire::with_columns(1);
    let new = wire.created(json!({
        "cmd": "new-pane-right", "pane": panes[0], "width": 0.6666667, "side": "left",
        "cols": 38, "rows": 22,
    }));
    let columns = wire.columns();
    assert_eq!(
        columns.iter().map(|column| column.1.clone()).collect::<Vec<_>>(),
        vec![vec![new], vec![panes[0]]]
    );
    assert!((columns[0].0 - 0.6666667).abs() < 1e-4, "{columns:?}");
    assert_eq!(wire.active_pane(), new);
    assert!(wire.mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_column_projection_is_consistent()
    }));
}

#[test]
fn side_left_opens_between_the_pane_column_and_its_left_neighbor() {
    let (mut wire, panes) = Wire::with_columns(2);
    let new = wire.created(json!({
        "cmd": "new-pane-right", "pane": panes[1], "width": 0.5, "side": "left", "cols": 38, "rows": 22,
    }));
    assert_eq!(
        wire.columns().into_iter().map(|column| column.1).collect::<Vec<_>>(),
        vec![vec![panes[0]], vec![new], vec![panes[1]]]
    );
    // `side: "right"` keeps the old placement.
    let right = wire.created(json!({
        "cmd": "new-pane-right", "pane": panes[0], "width": 0.5, "side": "right", "cols": 38, "rows": 22,
    }));
    assert_eq!(
        wire.columns().into_iter().map(|column| column.1).collect::<Vec<_>>(),
        vec![vec![panes[0]], vec![right], vec![new], vec![panes[1]]]
    );
}

#[test]
fn an_unknown_side_or_a_left_browser_column_is_refused_and_creates_nothing() {
    let (mut wire, panes) = Wire::with_columns(2);
    let before = wire.columns();
    for request in [
        json!({"cmd": "new-pane-right", "pane": panes[0], "width": 0.5, "side": "up"}),
        json!({"cmd": "new-pane-right", "pane": panes[0], "width": 0.5, "side": "left",
               "kind": "browser", "url": "https://example.com/left"}),
    ] {
        let response = wire.send(request.clone());
        assert_eq!(response["ok"], false, "{request} must be refused: {response}");
    }
    assert_eq!(wire.columns(), before);
}
