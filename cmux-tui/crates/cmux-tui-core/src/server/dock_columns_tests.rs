//! Wire tests for docked viewport columns (`dock-columns-v1`).
//!
//! A screen with horizontal viewport columns can pin at most one column per
//! edge. The flag lives on the column record, so it moves with the column,
//! persists with the screen, and is restored by `undo-layout`.

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    fn new() -> Self {
        let mux = Mux::new_for_test("dock-columns", crate::SurfaceOptions::default());
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
        handle_message(&self.mux, self.mux.local_test_client(7), &request.to_string(), &self.writer);
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
        handle_command(&self.mux, self.mux.local_test_client(0), Command::ListWorkspaces, &self.writer).unwrap()["workspaces"]
            [0]["screens"][0]
            .clone()
    }

    fn columns(&self) -> Vec<Value> {
        self.screen()["columns"].as_array().cloned().unwrap_or_default()
    }

    /// The `dock` member of each column, `None` where it is omitted.
    fn dock(&self) -> Vec<Option<Value>> {
        self.columns()
            .into_iter()
            .map(|column| column.as_object().unwrap().get("dock").cloned())
            .collect()
    }

    fn set_dock(&mut self, pane: PaneId, edge: &str, mode: &str) -> Value {
        self.ok(json!({
            "cmd": "set-column-dock",
            "pane": pane,
            "dock": true,
            "edge": edge,
            "mode": mode,
        }))
    }
}

fn dock(edge: &str, mode: &str) -> Option<Value> {
    Some(json!({"edge": edge, "mode": mode}))
}

#[test]
fn dock_column_capability_is_advertised() {
    let mut wire = Wire::new();
    let identity = wire.ok(json!({"cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "dock-columns-v1")
    );
}

#[test]
fn dock_column_sets_right_with_defaults_and_left_overlay() {
    let (mut wire, panes) = Wire::with_columns(3);
    assert_eq!(wire.dock(), vec![None, None, None], "a new column is never docked");
    let columns = wire.columns();

    let data = wire.ok(json!({
        "cmd": "set-column-dock",
        "pane": panes[2],
        "dock": true,
        "transaction": 41,
    }));
    assert_eq!(data["column"], columns[2]["id"]);
    assert_eq!(data["dock"], json!({"edge": "right", "mode": "docked"}));
    assert_eq!(data["transaction"], 41);
    assert_eq!(wire.dock(), vec![None, None, dock("right", "docked")]);

    let data = wire.set_dock(panes[0], "left", "overlay");
    assert_eq!(data["column"], columns[0]["id"]);
    assert_eq!(data["dock"], json!({"edge": "left", "mode": "overlay"}));
    assert!(data.get("transaction").is_none(), "no transaction, no echo: {data}");
    assert_eq!(wire.dock(), vec![dock("left", "overlay"), None, dock("right", "docked")]);

    // Order, widths, and the compatibility projection are unchanged.
    let after = wire.columns();
    for (before, after) in columns.iter().zip(&after) {
        assert_eq!(before["id"], after["id"]);
        assert_eq!(before["width"], after["width"]);
        assert_eq!(before["layout"], after["layout"]);
    }
}

#[test]
fn dock_column_replaces_the_column_holding_the_same_edge() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    wire.set_dock(panes[1], "right", "overlay");
    assert_eq!(wire.dock(), vec![None, dock("right", "overlay"), None]);
}

#[test]
fn dock_column_moves_to_the_other_edge() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    wire.set_dock(panes[2], "left", "docked");
    assert_eq!(wire.dock(), vec![None, None, dock("left", "docked")]);
}

#[test]
fn dock_column_refuses_to_pin_the_last_scrolling_column() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_dock(panes[1], "right", "docked");
    let response = wire.send(json!({
        "cmd": "set-column-dock",
        "pane": panes[0],
        "dock": true,
        "edge": "left",
    }));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], "dock-column-last-scrolling");
    assert!(response["error"].as_str().unwrap().contains("at least one column must scroll"));
    assert_eq!(wire.dock(), vec![None, dock("right", "docked")]);

    // Replacing the same edge frees a column, so it is allowed.
    let data = wire.set_dock(panes[0], "right", "docked");
    assert_eq!(data["dock"], json!({"edge": "right", "mode": "docked"}));
    assert_eq!(wire.dock(), vec![dock("right", "docked"), None]);
}

#[test]
fn dock_column_clears_and_clearing_is_idempotent() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_dock(panes[1], "left", "overlay");
    let columns = wire.columns();
    for _ in 0..2 {
        let data = wire.ok(json!({
            "cmd": "set-column-dock",
            "pane": panes[1],
            "dock": false,
            "transaction": 9,
        }));
        assert_eq!(data["column"], columns[1]["id"]);
        assert_eq!(data["dock"], Value::Null);
        assert_eq!(data["transaction"], 9);
        assert_eq!(wire.dock(), vec![None, None]);
    }
}

#[test]
fn dock_column_undo_layout_restores_previous_flags() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    wire.set_dock(panes[2], "left", "overlay");

    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[2]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert_eq!(wire.dock(), vec![None, None, dock("right", "docked")]);

    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[2]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert_eq!(wire.dock(), vec![None, None, None]);
}

#[test]
fn dock_column_changes_in_one_transaction_coalesce_into_one_undo() {
    let (mut wire, panes) = Wire::with_columns(3);
    for (edge, mode) in [("right", "docked"), ("left", "overlay"), ("right", "overlay")] {
        wire.ok(json!({
            "cmd": "set-column-dock",
            "pane": panes[2],
            "dock": true,
            "edge": edge,
            "mode": mode,
            "transaction": 77,
        }));
    }
    assert_eq!(wire.dock(), vec![None, None, dock("right", "overlay")]);
    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[2]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert_eq!(wire.dock(), vec![None, None, None]);
}

#[test]
fn dock_column_emits_screen_change_and_layout_change() {
    let (mut wire, panes) = Wire::with_columns(2);
    let events = wire.mux.subscribe();
    wire.ok(json!({
        "cmd": "set-column-dock",
        "pane": panes[1],
        "dock": true,
        "transaction": 5,
    }));
    let events = events.try_iter().collect::<Vec<_>>();
    assert!(events.iter().any(|event| matches!(event, MuxEvent::LayoutChanged(_))));
    let delta = events
        .iter()
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => Some(delta),
            _ => None,
        })
        .expect("a dock change emits screen-changed");
    assert_eq!(delta.transaction.as_deref(), Some("5"), "the delta echoes the transaction");
    assert_eq!(delta.entity["columns"][1]["dock"], json!({"edge": "right", "mode": "docked"}));
}

#[test]
fn dock_column_flags_clear_when_the_last_scrolling_column_closes() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[0], "left", "docked");
    wire.set_dock(panes[2], "right", "docked");
    wire.ok(json!({"cmd": "close-pane", "pane": panes[1]}));
    assert_eq!(wire.columns().len(), 2);
    assert_eq!(wire.dock(), vec![None, None], "one column must keep scrolling");
}

#[test]
fn dock_column_disappears_when_the_screen_collapses_to_one_column() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_dock(panes[1], "right", "docked");
    wire.ok(json!({"cmd": "close-pane", "pane": panes[0]}));
    assert!(wire.screen().get("columns").is_none());
    // A column created later starts without a flag.
    let surface = wire.mux.new_pane_right(panes[1], 0.5, Some((38, 22))).unwrap();
    assert!(wire.mux.with_state(|state| state.pane_of(surface.id)).is_some());
    assert_eq!(wire.dock(), vec![None, None]);
}

#[test]
fn dock_column_closing_a_dock_column_keeps_the_others() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[0], "left", "overlay");
    wire.set_dock(panes[2], "right", "docked");
    wire.ok(json!({"cmd": "close-pane", "pane": panes[2]}));
    assert_eq!(wire.dock(), vec![dock("left", "overlay"), None]);
}

#[test]
fn dock_column_tab_drags_keep_flags_consistent() {
    let (mut wire, panes) = Wire::with_columns(3);
    let extra = wire.mux.new_tab(Some(panes[0]), None, Some((38, 22))).unwrap();
    wire.set_dock(panes[2], "right", "docked");

    // A tab dragged into a new column: the new column scrolls.
    wire.ok(json!({"cmd": "move-tab-to-column", "surface": extra.id, "pane": panes[0]}));
    assert_eq!(wire.dock(), vec![None, None, dock("right", "docked"), None]);

    // Dragging the docked column's only tab away removes that column.
    let dock_tab = wire.mux.with_state(|state| state.panes[&panes[2]].tabs[0]);
    wire.ok(json!({
        "cmd": "move-tab-to-split",
        "surface": dock_tab,
        "pane": panes[0],
        "edge": "bottom",
    }));
    assert_eq!(wire.dock(), vec![None, None, None]);
}

/// An unknown pane is not found; a pane on a screen without `columns` is in
/// that screen's implicit column (see
/// `dock_column_on_a_split_screen_uses_the_implicit_single_column`).
#[test]
fn dock_column_unknown_pane_is_not_found() {
    let (mut wire, _) = Wire::with_columns(1);
    let response = wire.send(json!({"cmd": "set-column-dock", "pane": 999_999, "dock": true}));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], "viewport-column-not-found");
}

#[test]
fn dock_column_rejects_unknown_edge_and_mode() {
    let (mut wire, panes) = Wire::with_columns(2);
    for request in [
        json!({"cmd": "set-column-dock", "pane": panes[1], "dock": true, "edge": "diagonal"}),
        json!({"cmd": "set-column-dock", "pane": panes[1], "dock": true, "mode": "floating"}),
        json!({"cmd": "set-column-dock", "pane": panes[1], "dock": false, "edge": ""}),
    ] {
        let response = wire.send(request);
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error_code"], "invalid-argument");
    }
    let response = wire.send(json!({
        "cmd": "set-column-dock",
        "pane": panes[1],
        "dock": true,
        "transaction": "not-a-number",
    }));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(wire.dock(), vec![None, None]);
}

/// Tab ids in the tree, sorted.
fn tab_ids(screen: &Value) -> Vec<u64> {
    let mut ids = screen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|pane| pane["tabs"].as_array().cloned().unwrap_or_default())
        .map(|tab| tab["surface"].as_u64().unwrap())
        .collect::<Vec<_>>();
    ids.sort_unstable();
    ids
}

fn layout_has_pane(layout: &Value) -> bool {
    match layout["type"].as_str() {
        Some("leaf") => layout["pane"].is_u64(),
        Some("stack") => layout["panes"].as_array().is_some_and(|panes| !panes.is_empty()),
        Some("split") => layout_has_pane(&layout["a"]) && layout_has_pane(&layout["b"]),
        _ => false,
    }
}

/// Runs a deterministic pseudo-random sequence of `set-column-dock`
/// requests (accepted and rejected) and checks after every request: the tab
/// set is unchanged, every column still holds a pane, column order and
/// widths are unchanged, at most one column holds each edge, at least one
/// column scrolls, and repeating the same request commits nothing. Returns
/// the accepted and rejected counts.
fn run_dock_sequence(mut wire: Wire, mut seed: u64) -> (usize, usize) {
    let tabs = tab_ids(&wire.screen());
    let columns = wire.columns();
    let column_panes = wire.mux.with_state(|state| {
        state.workspaces[0].screens[0]
            .layout_columns
            .iter()
            .map(|column| column.root.first_visible_pane())
            .collect::<Vec<_>>()
    });
    let edges = ["left", "right"];
    let modes = ["docked", "overlay"];
    let mut next = |bound: usize| {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) as usize % bound
    };
    let (mut accepted, mut rejected) = (0, 0);
    for _ in 0..120 {
        let request = json!({
            "cmd": "set-column-dock",
            "pane": column_panes[next(column_panes.len())],
            "dock": next(4) != 0,
            "edge": edges[next(2)],
            "mode": modes[next(2)],
        });
        let response = wire.send(request.clone());
        if response["ok"] == true {
            accepted += 1;
        } else {
            rejected += 1;
            assert_eq!(response["error_code"], "dock-column-last-scrolling", "{response}");
        }

        assert_eq!(tab_ids(&wire.screen()), tabs, "a dock change never adds or removes a tab");
        let after = wire.columns();
        assert_eq!(after.len(), columns.len());
        for (before, column) in columns.iter().zip(&after) {
            assert_eq!(before["id"], column["id"], "column order is unchanged");
            assert_eq!(before["width"], column["width"]);
            assert!(layout_has_pane(&column["layout"]), "every column holds a pane");
        }
        let flags = wire.dock();
        assert!(flags.iter().any(Option::is_none), "at least one column scrolls");
        for edge in edges {
            let holders = flags.iter().flatten().filter(|flag| flag["edge"] == edge).count();
            assert!(holders <= 1, "{edge} is held by {holders} columns");
        }

        let revision = wire.mux.with_state(|state| state.resource_revision);
        let replay = wire.send(request);
        assert_eq!(replay["ok"], response["ok"], "{replay}");
        assert_eq!(wire.dock(), flags, "repeating a request changes nothing");
        assert_eq!(wire.mux.with_state(|state| state.resource_revision), revision);
    }
    (accepted, rejected)
}

#[test]
fn dock_column_ops_preserve_layout_invariants_on_two_columns() {
    let (wire, _) = Wire::with_columns(2);
    let (accepted, rejected) = run_dock_sequence(wire, 0x5eed);
    assert!(accepted > 0 && rejected > 0, "{accepted} accepted, {rejected} rejected");
}

#[test]
fn dock_column_ops_preserve_layout_invariants_on_four_columns() {
    let (wire, panes) = Wire::with_columns(4);
    wire.mux.split(panes[1], SplitDir::Down, Some((38, 10))).unwrap();
    wire.mux.new_tab(Some(panes[2]), None, Some((38, 22))).unwrap();
    // Two edges hold at most two of four columns, so nothing is rejected.
    assert_eq!(run_dock_sequence(wire, 0xc01), (120, 0));
}

/// One `cmux.protocol/2` request; returns the response envelope.
fn resource(mux: &Arc<Mux>, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": operation,
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap()
}

/// The workspace and screen public ids of the test screen.
fn public_ids(mux: &Arc<Mux>) -> (String, String) {
    mux.with_state(|state| {
        let workspace = &state.workspaces[0];
        (workspace.public_id.to_string(), workspace.screens[0].public_id.to_string())
    })
}

fn export_layout(mux: &Arc<Mux>) -> Value {
    let (_, screen) = public_ids(mux);
    let params = json!({"machine": "current", "session": "current", "screen": screen});
    resource(mux, "screen.layout.export", params, None)["result"].clone()
}

fn apply_layout(mux: &Arc<Mux>, layout: Value, key: &str) -> Value {
    let (workspace, _) = public_ids(mux);
    let params = json!({
        "machine": "current",
        "session": "current",
        "workspace": workspace,
        "layout": layout,
    });
    resource(mux, "workspace.layout.apply", params, Some(key))
}

#[test]
fn dock_column_flags_survive_a_layout_apply_that_keeps_the_column() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    let mut layout = export_layout(&wire.mux);
    assert_eq!(layout["root"]["kind"], "viewport", "{layout}");
    layout["root"]["columns"][1]["width"] = json!(0.4);

    let applied = apply_layout(&wire.mux, layout, "dock-apply-keep");
    assert!(applied.get("error").is_none(), "{applied}");
    let width = wire.columns()[1]["width"].as_f64().unwrap();
    assert!((width - 0.4).abs() < 1e-6, "{width}");
    assert_eq!(wire.dock(), vec![None, None, dock("right", "docked")]);
}

#[test]
fn dock_column_flags_clear_when_a_layout_apply_leaves_only_dock_columns() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[0], "left", "docked");
    wire.set_dock(panes[2], "right", "docked");
    let mut layout = export_layout(&wire.mux);
    let columns = layout["root"]["columns"].as_array().unwrap().clone();
    // Merge the scrolling middle column into the first one; the middle
    // column's id becomes the merged split's id.
    let merged = json!({
        "kind": "split",
        "split_id": columns[1]["column_id"],
        "direction": "vertical",
        "ratio": 0.5,
        "first": columns[0]["root"],
        "second": columns[1]["root"],
    });
    let mut first = columns[0].clone();
    first["root"] = merged;
    layout["root"]["columns"] = json!([first, columns[2]]);

    let applied = apply_layout(&wire.mux, layout, "dock-apply-merge");
    assert!(applied.get("error").is_none(), "{applied}");
    assert_eq!(wire.columns().len(), 2);
    assert_eq!(wire.dock(), vec![None, None], "one column must keep scrolling");
}

/// The docked member of each viewport column in the v2 layout document,
/// `None` where it is omitted.
fn exported_dock(layout: &Value) -> Vec<Option<Value>> {
    layout["root"]["columns"]
        .as_array()
        .unwrap()
        .iter()
        .map(|column| column.as_object().unwrap().get("dock").cloned())
        .collect()
}

#[test]
fn dock_column_flag_is_in_the_v2_layout_document() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    wire.set_dock(panes[0], "left", "overlay");
    let layout = export_layout(&wire.mux);
    assert_eq!(
        exported_dock(&layout),
        vec![dock("left", "overlay"), None, dock("right", "docked")],
        "{layout}"
    );
    let screen = resource(
        &wire.mux,
        "screen.get",
        json!({"machine": "current", "session": "current", "screen": public_ids(&wire.mux).1}),
        None,
    );
    assert_eq!(
        exported_dock(&screen["result"]["layout"]),
        vec![dock("left", "overlay"), None, dock("right", "docked")],
        "{screen}"
    );
}

#[test]
fn dock_column_flag_in_a_layout_apply_sets_and_clears_the_flag() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    let mut layout = export_layout(&wire.mux);
    layout["root"]["columns"][0]["dock"] = json!({"edge": "left", "mode": "overlay"});
    layout["root"]["columns"][2]["dock"] = Value::Null;

    let applied = apply_layout(&wire.mux, layout, "dock-apply-set-clear");
    assert!(applied.get("error").is_none(), "{applied}");
    assert_eq!(wire.dock(), vec![dock("left", "overlay"), None, None]);
}

/// DOCK-WIRE (R87): a document from an older client that clears a flag with
/// `sticky: null` is refused, so the stored flag never stays behind its back.
#[test]
fn a_layout_apply_refuses_the_old_sticky_field() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[2], "right", "docked");
    let mut layout = export_layout(&wire.mux);
    layout["root"]["columns"][2]["sticky"] = Value::Null;
    let (workspace, _) = public_ids(&wire.mux);
    let request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "old-sticky",
        "operation": "workspace.layout.apply",
        "params": {"machine": "current", "session": "current", "workspace": workspace, "layout": layout},
        "idempotency_key": "old-sticky",
    });
    let refused =
        match crate::resource_router::handle_resource_message(&wire.mux, &request.to_string()) {
            Err(_) => true,
            Ok(response) => response.get("error").is_some() || response["ok"] == false,
        };
    assert!(refused, "a layout with sticky is refused");
    assert_eq!(wire.dock(), vec![None, None, dock("right", "docked")]);
}

#[test]
fn dock_column_flags_in_a_layout_apply_must_keep_one_scrolling_column() {
    let (wire, _) = Wire::with_columns(2);
    let mut layout = export_layout(&wire.mux);
    layout["root"]["columns"][0]["dock"] = json!({"edge": "left", "mode": "docked"});
    layout["root"]["columns"][1]["dock"] = json!({"edge": "right", "mode": "docked"});

    let applied = apply_layout(&wire.mux, layout, "dock-apply-all-dock");
    assert!(applied.get("error").is_some(), "{applied}");
    assert_eq!(wire.dock(), vec![None, None]);
}

/// A screen without stored columns is one implicit column (every screen is a
/// column strip): column ops answer with the column rules, never with
/// "no viewport column", and the layout does not change.
#[test]
fn dock_column_on_a_split_screen_uses_the_implicit_single_column() {
    let (mut wire, panes) = Wire::with_columns(1);
    let before = wire.screen();
    let pin = wire.send(json!({"cmd": "set-column-dock", "pane": panes[0], "dock": true}));
    assert_eq!(pin["ok"], false, "{pin}");
    assert_eq!(pin["error_code"], "dock-column-last-scrolling", "{pin}");
    wire.ok(json!({"cmd": "set-column-dock", "pane": panes[0], "dock": false}));
    assert_eq!(wire.screen()["layout"], before["layout"]);
    assert!(wire.screen().get("columns").is_none());
}

#[test]
fn edge_docks_capability_is_advertised() {
    let mut wire = Wire::new();
    let identify = wire.ok(json!({"cmd": "identify"}));
    let capabilities = identify["capabilities"].as_array().unwrap();
    assert!(capabilities.contains(&json!(EDGE_DOCKS_CAPABILITY)));
}

/// DOCK-WIRE (R87): every edge travels in the one `dock` field; the
/// pre-rename `sticky` field is gone.
#[test]
fn every_edge_is_sent_in_the_one_dock_field() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_dock(panes[0], "left", "docked");
    wire.set_dock(panes[2], "top", "overlay");
    let columns = wire.columns();
    assert_eq!(columns[0]["dock"], json!({"edge": "left", "mode": "docked"}));
    assert_eq!(columns[2]["dock"], json!({"edge": "top", "mode": "overlay"}));
    assert!(columns.iter().all(|column| column.get("sticky").is_none()));
    assert!(columns[1].get("dock").is_none());
    // One column per edge: a second top dock replaces the first.
    wire.set_dock(panes[1], "top", "docked");
    assert!(wire.columns()[2].get("dock").is_none());
}

#[test]
fn move_tab_to_column_pins_the_new_column_in_one_commit() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_dock(panes[1], "bottom", "docked");
    let second = wire.mux.new_tab(Some(panes[0]), None, Some((38, 22))).unwrap();
    wire.ok(json!({
        "cmd": "move-tab-to-column",
        "surface": second.id,
        "pane": panes[0],
        "dock": {"edge": "bottom", "mode": "overlay"},
    }));
    let columns = wire.columns();
    assert_eq!(columns.len(), 3);
    // The new column holds the edge; the old holder scrolls again.
    assert_eq!(columns[2]["dock"], json!({"edge": "bottom", "mode": "overlay"}));
    assert!(columns[1].get("dock").is_none());
}

/// DOCK-WIRE (R87): an older client's `sticky` is refused with
/// invalid-argument, never turned into a plain column.
#[test]
fn move_tab_to_column_refuses_the_old_sticky_field() {
    let (mut wire, panes) = Wire::with_columns(2);
    let second = wire.mux.new_tab(Some(panes[0]), None, Some((38, 22))).unwrap();
    let response = wire.send(json!({
        "cmd": "move-tab-to-column",
        "surface": second.id,
        "pane": panes[0],
        "sticky": {"edge": "right", "mode": "docked"},
    }));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], "invalid-argument");
    assert_eq!(wire.columns().len(), 2);
}

/// The pin is checked on the layout after the move: moving the only tab of
/// the last scrolling column into a new pinned column would leave nothing to
/// scroll, so the drag is refused and nothing moves.
#[test]
fn move_tab_to_column_refuses_a_pin_when_the_closing_source_column_scrolled() {
    let mut wire = Wire::new();
    let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let anchor = wire.mux.with_state(|state| state.pane_of(first.id).unwrap());
    let moved = wire.mux.new_pane_right(anchor, 0.5, Some((38, 22))).unwrap();
    wire.set_dock(anchor, "right", "docked");
    let before = wire.screen();
    let refused = wire.send(json!({
        "cmd": "move-tab-to-column",
        "surface": moved.id,
        "pane": anchor,
        "dock": {"edge": "bottom", "mode": "docked"},
    }));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(wire.screen()["layout"], before["layout"]);
    assert_eq!(wire.dock(), vec![dock("right", "docked"), None]);
}
