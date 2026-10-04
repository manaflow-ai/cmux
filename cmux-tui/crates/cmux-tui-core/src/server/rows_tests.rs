//! Wire tests for rows (`rows-v1`, plans/cmux-next/rows.md step 3): each
//! column is a vertical strip of rows. A row has an id (allocated as a split
//! id) and a height in permille; `columns[].layout` stays the compat chain
//! (the rows folded into vertical splits whose ids are rows 2..n), so a client
//! without `rows-v1` still sees every pane.

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    fn new() -> Self {
        let mux = Mux::new_for_test("rows", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        Self { mux, outbound, writer, next_id: 1 }
    }

    /// One workspace on a split screen; returns its only pane.
    fn lone() -> (Self, PaneId) {
        let wire = Self::new();
        let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
        let pane = wire.mux.with_state(|state| state.pane_of(first.id).unwrap());
        (wire, pane)
    }

    fn send(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        handle_message(&self.mux, 7, &request.to_string(), &self.writer);
        let response: Value = serde_json::from_str(&self.outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id, "response must answer the request: {response}");
        response
    }

    fn ok(&mut self, request: Value) -> Value {
        let response = self.send(request.clone());
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        response["data"].clone()
    }

    fn screen(&self) -> Value {
        handle_command(&self.mux, 0, Command::ListWorkspaces, &self.writer).unwrap()["workspaces"]
            [0]["screens"][0]
            .clone()
    }

    fn columns(&self) -> Vec<Value> {
        self.screen()["columns"].as_array().cloned().unwrap_or_default()
    }

    fn rows(&self, column: usize) -> Vec<Value> {
        self.columns()
            .get(column)
            .and_then(|column| column["rows"].as_array().cloned())
            .unwrap_or_default()
    }
}

#[test]
fn rows_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"rows-v1"));
}

/// New Row on a split screen: the tree becomes the first row of one column,
/// and a new row with one pane holding one new terminal goes below it.
#[test]
fn new_row_on_a_split_screen_makes_one_column_of_two_rows() {
    let (mut wire, pane) = Wire::lone();
    let created = wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 400}));
    let new_pane: PaneId = serde_json::from_value(created["pane"].clone()).unwrap();
    assert_ne!(new_pane, pane);
    let columns = wire.columns();
    assert_eq!(columns.len(), 1, "one column with two rows stays in columns mode");
    let rows = wire.rows(0);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["height"], 1000);
    assert_eq!(rows[1]["height"], 400);
    // Every pane is in exactly one row (R1), and the new pane has a tab.
    let panes_in = |row: &Value| row["layout"].to_string();
    assert!(panes_in(&rows[0]).contains(&pane.to_string()));
    assert!(panes_in(&rows[1]).contains(&new_pane.to_string()));
    assert_eq!(wire.mux.with_state(|state| state.panes[&new_pane].tabs.len()), 1);
}

/// The compat chain: `layout` folds the rows into vertical splits whose ids
/// are the ids of rows 2..n, so an old client sees every pane.
#[test]
fn column_layout_is_the_compat_chain_of_the_rows() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let column = &wire.columns()[0];
    let rows = column["rows"].as_array().unwrap();
    assert_eq!(column["layout"]["type"], "split", "{column}");
    // Split nodes carry their id as `split` (node_json), rows as `id`.
    assert_eq!(column["layout"]["split"], rows[1]["id"], "the chain split carries row 2's id");
}

#[test]
fn a_column_with_one_row_sends_no_rows() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-pane-right", "pane": pane, "cols": 38, "rows": 22}));
    assert_eq!(wire.columns().len(), 2);
    for column in wire.columns() {
        assert!(column.get("rows").is_none(), "{column}");
    }
}

#[test]
fn set_row_heights_replaces_every_height_of_a_column() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let column = wire.columns()[0]["id"].clone();
    let ids: Vec<Value> = wire.rows(0).iter().map(|row| row["id"].clone()).collect();
    wire.ok(json!({
        "cmd": "set-row-heights",
        "column": column,
        "heights": [{"row": ids[0], "height": 600}, {"row": ids[1], "height": 400}],
        "fit": true,
    }));
    let heights: Vec<Value> = wire.rows(0).iter().map(|row| row["height"].clone()).collect();
    assert_eq!(heights, vec![json!(600), json!(400)]);
    // A stale row set is refused and changes nothing.
    let stale = wire.send(json!({
        "cmd": "set-row-heights", "column": column, "heights": [{"row": ids[0], "height": 500}],
    }));
    assert_eq!(stale["ok"], false, "{stale}");
    assert_eq!(wire.rows(0)[0]["height"], 600);
}

/// One column with rows keeps its id when a second column joins it and
/// when it is left alone again; left alone, it fills the screen width.
#[test]
fn a_lone_column_of_rows_keeps_its_id_and_fills_the_width() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let id = wire.columns()[0]["id"].clone();
    let width = |wire: &Wire| wire.columns()[0]["width"].as_f64().unwrap();
    let right = wire.ok(json!({"cmd": "new-pane-right", "pane": pane, "cols": 38, "rows": 22}));
    assert_eq!(wire.columns().len(), 2);
    assert_eq!(wire.columns()[0]["id"], id, "a second column keeps the first column's id");
    wire.ok(json!({"cmd": "set-viewport-pane-width", "pane": pane, "width": 0.6}));
    assert!((width(&wire) - 0.6).abs() < 1e-6, "{}", wire.screen());
    let right_pane = wire.mux.with_state(|state| {
        let surface = serde_json::from_value(right["surface"].clone()).unwrap();
        state.pane_of(surface).unwrap()
    });
    wire.ok(json!({"cmd": "close-pane", "pane": right_pane}));
    assert_eq!(wire.columns().len(), 1);
    assert_eq!(wire.columns()[0]["id"], id, "the column left alone keeps its id");
    assert_eq!(width(&wire), 1.0, "the column left alone fills the width: {}", wire.screen());
    assert_eq!(wire.rows(0).len(), 2);
}

/// `set-viewport-pane-width` returns the width in effect after the commit: a
/// lone column of rows always fills the screen (1.0), and a column beside
/// another keeps the requested width.
#[test]
fn set_viewport_pane_width_returns_the_effective_width() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let lone = wire.ok(json!({"cmd": "set-viewport-pane-width", "pane": pane, "width": 0.6}));
    assert_eq!(lone, json!({"width": 1.0}), "a lone column fills the width");
    assert_eq!(wire.columns()[0]["width"], 1.0, "{}", wire.screen());
    wire.ok(json!({"cmd": "new-pane-right", "pane": pane, "cols": 38, "rows": 22}));
    let set = wire.ok(json!({"cmd": "set-viewport-pane-width", "pane": pane, "width": 0.6}));
    let width = set["width"].as_f64().unwrap_or_else(|| panic!("no width: {set}"));
    assert!((width - 0.6).abs() < 1e-6, "{set}");
    assert!((wire.columns()[0]["width"].as_f64().unwrap() - width).abs() < 1e-6);
}

/// A client without `rows-v1` cannot resize a row through its synthetic split.
#[test]
fn the_synthetic_row_split_is_read_only() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let split = wire.rows(0)[1]["id"].clone();
    let refused = wire.send(json!({"cmd": "set-split-ratio", "split": split, "ratio": 0.3}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "row-split-compat-readonly", "{refused}");
}

/// Closing the last pane of a row removes the row (R2); one column with one
/// row collapses back to a split screen.
#[test]
fn closing_a_rows_last_pane_removes_the_row_and_collapses() {
    let (mut wire, pane) = Wire::lone();
    let created = wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let new_pane: PaneId = serde_json::from_value(created["pane"].clone()).unwrap();
    wire.ok(json!({"cmd": "close-pane", "pane": new_pane}));
    assert!(wire.screen().get("columns").is_none(), "{}", wire.screen());
}

#[test]
fn undo_layout_restores_the_rows() {
    let (mut wire, pane) = Wire::lone();
    let first = wire.mux.new_tab(Some(pane), None, Some((80, 22))).unwrap();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let ids: Vec<Value> = wire.rows(0).iter().map(|row| row["id"].clone()).collect();
    let column = wire.columns()[0]["id"].clone();
    wire.ok(json!({
        "cmd": "set-row-heights", "column": column,
        "heights": [{"row": ids[0], "height": 700}, {"row": ids[1], "height": 300}],
    }));
    wire.ok(json!({"cmd": "undo-layout", "pane": pane}));
    assert_eq!(wire.rows(0)[0]["height"], 1000, "undo restores the heights");
    let _ = first;
}

/// The `screen-changed` deltas in `events`, with their transactions.
fn screen_changed_transactions(events: &crate::MuxEventReceiver) -> Vec<Option<String>> {
    events
        .try_iter()
        .filter_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => {
                Some(delta.transaction.map(|transaction| transaction.to_string()))
            }
            _ => None,
        })
        .collect()
}

/// mutation-echo: `new-row` echoes its transaction in the result and in the
/// screen's `screen-changed` delta, so a client can settle its intent.
#[test]
fn new_row_echoes_its_transaction() {
    let (mut wire, pane) = Wire::lone();
    let events = wire.mux.subscribe();
    let created = wire.ok(json!({
        "cmd": "new-row", "pane": pane, "height_permille": 500, "transaction": "tx-row",
    }));
    assert_eq!(created["transaction"], "tx-row");
    let echoed = screen_changed_transactions(&events);
    assert!(echoed.contains(&Some("tx-row".to_string())), "{echoed:?}");
    let refused = wire.send(json!({
        "cmd": "new-row", "pane": pane, "height_permille": 500, "transaction": "",
    }));
    assert_eq!(refused["ok"], false, "an empty transaction is refused: {refused}");
}

#[test]
fn set_row_heights_echoes_its_transaction() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let column = wire.columns()[0]["id"].clone();
    let ids: Vec<Value> = wire.rows(0).iter().map(|row| row["id"].clone()).collect();
    let events = wire.mux.subscribe();
    let data = wire.ok(json!({
        "cmd": "set-row-heights", "column": column, "transaction": 12,
        "heights": [{"row": ids[0], "height": 700}, {"row": ids[1], "height": 300}],
    }));
    assert_eq!(data["transaction"], 12);
    let echoed = screen_changed_transactions(&events);
    assert!(echoed.contains(&Some("12".to_string())), "{echoed:?}");
}

/// Layout documents carry no rows yet: `workspace.layout.apply` on a screen
/// with rows is refused and changes nothing (rows.md decision 5).
#[test]
fn layout_apply_on_a_screen_with_rows_is_refused() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let before = wire.screen();
    let (workspace, screen) = wire.mux.with_state(|state| {
        let workspace = &state.workspaces[0];
        (workspace.public_id.to_string(), workspace.screens[0].public_id.to_string())
    });
    let resource = |operation: &str, params: Value, key: Option<&str>| {
        let mut request = json!({
            "protocol": "cmux.protocol/2", "type": "request", "id": operation,
            "operation": operation, "params": params,
        });
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        crate::resource_router::handle_resource_message(&wire.mux, &request.to_string()).unwrap()
    };
    let scope = json!({"machine": "current", "session": "current", "screen": screen});
    let layout = resource("screen.layout.export", scope, None)["result"].clone();
    assert!(layout.is_object(), "{layout}");
    let params = json!({
        "machine": "current", "session": "current", "workspace": workspace, "layout": layout,
    });
    let applied = resource("workspace.layout.apply", params, Some("rows-apply"));
    assert_eq!(
        applied["error"]["details"]["extra"]["reason_code"], "rows-layout-replace-unsupported",
        "{applied}"
    );
    assert_eq!(wire.screen(), before, "a refused apply changes nothing");
}
