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

    fn screen(&self) -> Value {
        handle_command(
            &self.mux,
            self.mux.local_test_client(0),
            Command::ListWorkspaces,
            &self.writer,
        )
        .unwrap()["workspaces"][0]["screens"][0]
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

/// `row-client-keys-v1` (New Row in the key's turn, perf lead 2026-10-23): `new-row` takes the
/// client-minted `pane_id` and `tab_id` that `split` takes (`split-client-keys-v1`), so the app can
/// show the row before the reply and the daemon's pane replaces it under the same public id.
#[test]
fn new_row_takes_client_minted_pane_and_tab_ids() {
    assert!(advertised_capabilities(false).contains(&"row-client-keys-v1"));
    let (mut wire, pane) = Wire::lone();
    let pane_id = "pane_0123456789abcdef0123456789abcdef";
    let tab_id = "tab_0123456789abcdef0123456789abcdef";
    let created = wire.ok(json!({
        "cmd": "new-row", "pane": pane, "height_permille": 500, "pane_id": pane_id, "tab_id": tab_id,
    }));
    assert_eq!(created["pane_id"], pane_id, "{created}");
    assert_eq!(created["tab_id"], tab_id, "{created}");
    let new_pane: PaneId = serde_json::from_value(created["pane"].clone()).unwrap();
    assert_eq!(wire.mux.with_state(|state| state.panes[&new_pane].public_id.to_string()), pane_id);
    let bad = wire.send(
        json!({"cmd": "new-row", "pane": pane, "height_permille": 500, "pane_id": "pane_xyz"}),
    );
    assert_eq!(bad["ok"], false, "a malformed pane id is refused: {bad}");
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

/// A layout document applies to a screen with rows: the columns keep their
/// rows and heights (`rows-v1`), so `screen.layout.export` round-trips
/// through `workspace.layout.apply`, and a document that moves a pane inside
/// a row applies without losing the rows. A split-tree document cannot carry
/// rows and is still refused.
#[test]
fn layout_documents_apply_to_a_screen_with_rows_and_keep_them() {
    let (mut wire, pane) = Wire::lone();
    wire.ok(json!({"cmd": "new-row", "pane": pane, "height_permille": 500}));
    let column = wire.columns()[0]["id"].clone();
    let ids: Vec<Value> = wire.rows(0).iter().map(|row| row["id"].clone()).collect();
    wire.ok(json!({
        "cmd": "set-row-heights", "column": column,
        "heights": [{"row": ids[0], "height": 700}, {"row": ids[1], "height": 300}],
    }));
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
    assert_eq!(layout["root"]["kind"], "viewport", "{layout}");
    let apply = |document: &Value, key: &str| {
        let params = json!({
            "machine": "current", "session": "current", "workspace": workspace,
            "layout": document,
        });
        resource("workspace.layout.apply", params, Some(key))
    };

    let applied = apply(&layout, "rows-apply-same");
    assert_eq!(applied["ok"], true, "the exported document applies: {applied}");
    assert_eq!(wire.screen(), before, "the exported document changes nothing");

    // A document that changes the screen (its active pane: the lower row's).
    let mut focused = layout.clone();
    let lower = &layout["root"]["columns"][0]["root"]["second"];
    assert_eq!(lower["kind"], "leaf", "{layout}");
    focused["active_pane_id"] = lower["pane_id"].clone();
    let applied = apply(&focused, "rows-apply-focus");
    assert_eq!(applied["ok"], true, "{applied}");
    let heights: Vec<Value> = wire.rows(0).iter().map(|row| row["height"].clone()).collect();
    assert_eq!(heights, [json!(700), json!(300)], "the rows and their heights stay");
    let row_ids: Vec<Value> = wire.rows(0).iter().map(|row| row["id"].clone()).collect();
    assert_eq!(row_ids, ids, "the rows keep their ids");

    let mut tree = layout.clone();
    tree["root"] = layout["root"]["columns"][0]["root"].clone();
    let refused = apply(&tree, "rows-apply-tree");
    assert_eq!(
        refused["error"]["details"]["extra"]["reason_code"], "rows-layout-replace-unsupported",
        "{refused}"
    );
    let heights: Vec<Value> = wire.rows(0).iter().map(|row| row["height"].clone()).collect();
    assert_eq!(heights, [json!(700), json!(300)], "a refused document changes nothing");
}

/// `rows-v1` layout documents carry rows: a column with two or more rows
/// lists them as `rows: [{row_id, height}]`, top to bottom, where row 2..n's
/// `row_id` is the split id of its compat chain split in the column's `root`
/// (the row's content is that chain's subtree). `workspace.layout.apply` sets
/// heights, turns a down-split chain into rows (row 1's `row_id` omitted: a
/// new id), and `rows: []` returns a column to one row; omitted `rows` keep
/// the column's rows.
#[test]
fn layout_documents_carry_rows_and_apply_sets_them() {
    let wire = Wire::new();
    let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let left = wire.mux.with_state(|state| state.pane_of(first.id).unwrap());
    wire.mux.new_pane_right(left, 0.5, Some((38, 22))).unwrap();
    let mut wire = wire;
    wire.ok(json!({"cmd": "split", "pane": left, "dir": "down"}));
    assert_eq!(wire.columns().len(), 2, "{}", wire.screen());
    assert!(wire.rows(0).is_empty(), "a plain down split is no row");
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
        // A request the catalog refuses answers Err: a refusal as well.
        crate::resource_router::handle_resource_message(&wire.mux, &request.to_string())
            .unwrap_or_else(|error| json!({"ok": false, "error": format!("{error:?}")}))
    };
    let scope = json!({"machine": "current", "session": "current", "screen": screen});
    let export = || resource("screen.layout.export", scope.clone(), None)["result"].clone();
    let apply = |document: &Value, key: &str| {
        let params = json!({
            "machine": "current", "session": "current", "workspace": workspace,
            "layout": document,
        });
        resource("workspace.layout.apply", params, Some(key))
    };

    let plain = export();
    assert!(plain["root"]["columns"][0].get("rows").is_none(), "one row: no rows: {plain}");
    let chain = plain["root"]["columns"][0]["root"]["split_id"].clone();
    assert!(chain.is_string(), "{plain}");

    // A down split becomes rows 1 and 2.
    let mut rows = plain;
    rows["root"]["columns"][0]["rows"] = json!([{"height": 600}, {"row_id": chain, "height": 400}]);
    let applied = apply(&rows, "rows-doc-make");
    assert_eq!(applied["ok"], true, "{applied}");
    let heights: Vec<Value> = wire.rows(0).iter().map(|row| row["height"].clone()).collect();
    assert_eq!(heights, [json!(600), json!(400)], "{}", wire.screen());

    // Export lists them, and the export round-trips.
    let exported = export();
    let listed = exported["root"]["columns"][0]["rows"].as_array().cloned().unwrap_or_default();
    assert_eq!(listed.len(), 2, "{exported}");
    assert_eq!(listed[1]["row_id"], chain, "row 2 is the chain split: {exported}");
    assert_eq!(listed[0]["height"], 600);
    assert!(listed[0]["row_id"].is_string() && listed[0]["row_id"] != chain, "{exported}");
    assert!(exported["root"]["columns"][1].get("rows").is_none(), "{exported}");
    let before = wire.screen();
    let applied = apply(&exported, "rows-doc-same");
    assert_eq!(applied["ok"], true, "{applied}");
    assert_eq!(wire.screen(), before, "the exported document changes nothing");

    // Heights change through the document; row ids stay.
    let mut taller = exported.clone();
    taller["root"]["columns"][0]["rows"][0]["height"] = json!(300);
    taller["root"]["columns"][0]["rows"][1]["height"] = json!(700);
    let applied = apply(&taller, "rows-doc-heights");
    assert_eq!(applied["ok"], true, "{applied}");
    let after = export();
    assert_eq!(after["root"]["columns"][0]["rows"][0]["row_id"], listed[0]["row_id"]);
    let heights: Vec<Value> = wire.rows(0).iter().map(|row| row["height"].clone()).collect();
    assert_eq!(heights, [json!(300), json!(700)]);

    // Refused documents change nothing.
    let mut refused = Vec::new();
    let mut low = exported.clone();
    low["root"]["columns"][0]["rows"][1]["height"] = json!(50);
    refused.push(apply(&low, "rows-doc-low"));
    let mut stranger = exported.clone();
    stranger["root"]["columns"][0]["rows"][1]["row_id"] =
        exported["root"]["columns"][0]["column_id"].clone();
    refused.push(apply(&stranger, "rows-doc-stranger"));
    let mut unknown_first = exported.clone();
    unknown_first["root"]["columns"][0]["rows"][0]["row_id"] = chain.clone();
    refused.push(apply(&unknown_first, "rows-doc-first"));
    let mut extra = exported;
    extra["root"]["columns"][0]["rows"][1]["width"] = json!(1);
    refused.push(apply(&extra, "rows-doc-extra"));
    for answer in refused {
        assert_eq!(answer["ok"], false, "{answer}");
    }
    let heights: Vec<Value> = wire.rows(0).iter().map(|row| row["height"].clone()).collect();
    assert_eq!(heights, [json!(300), json!(700)], "a refused document changes nothing");

    // `rows: []`: one row again; the down split stays.
    let mut flat = export();
    flat["root"]["columns"][0]["rows"] = json!([]);
    let applied = apply(&flat, "rows-doc-flat");
    assert_eq!(applied["ok"], true, "{applied}");
    assert!(wire.rows(0).is_empty(), "{}", wire.screen());
    let flat = export();
    assert_eq!(flat["root"]["columns"][0]["root"]["split_id"], chain, "{flat}");
    assert!(flat["root"]["columns"][0].get("rows").is_none(), "{flat}");
}
