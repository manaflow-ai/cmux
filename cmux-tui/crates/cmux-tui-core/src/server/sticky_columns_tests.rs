//! Wire tests for sticky viewport columns (`sticky-columns-v1`).
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
        let mux = Mux::new_for_test("sticky-columns", crate::SurfaceOptions::default());
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

    /// The `sticky` member of each column, `None` where it is omitted.
    fn sticky(&self) -> Vec<Option<Value>> {
        self.columns()
            .into_iter()
            .map(|column| column.as_object().unwrap().get("sticky").cloned())
            .collect()
    }

    fn set_sticky(&mut self, pane: PaneId, edge: &str, mode: &str) -> Value {
        self.ok(json!({
            "cmd": "set-column-sticky",
            "pane": pane,
            "sticky": true,
            "edge": edge,
            "mode": mode,
        }))
    }
}

fn sticky(edge: &str, mode: &str) -> Option<Value> {
    Some(json!({"edge": edge, "mode": mode}))
}

#[test]
fn sticky_column_capability_is_advertised() {
    let mut wire = Wire::new();
    let identity = wire.ok(json!({"cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "sticky-columns-v1")
    );
}

#[test]
fn sticky_column_sets_right_with_defaults_and_left_overlay() {
    let (mut wire, panes) = Wire::with_columns(3);
    assert_eq!(wire.sticky(), vec![None, None, None], "a new column is never sticky");
    let columns = wire.columns();

    let data = wire.ok(json!({
        "cmd": "set-column-sticky",
        "pane": panes[2],
        "sticky": true,
        "transaction": "tx-sticky-right",
    }));
    assert_eq!(data["column"], columns[2]["id"]);
    assert_eq!(data["sticky"], json!({"edge": "right", "mode": "docked"}));
    assert_eq!(data["transaction"], "tx-sticky-right");
    assert_eq!(wire.sticky(), vec![None, None, sticky("right", "docked")]);

    let data = wire.set_sticky(panes[0], "left", "overlay");
    assert_eq!(data["column"], columns[0]["id"]);
    assert_eq!(data["sticky"], json!({"edge": "left", "mode": "overlay"}));
    assert!(data.get("transaction").is_none(), "no transaction, no echo: {data}");
    assert_eq!(
        wire.sticky(),
        vec![sticky("left", "overlay"), None, sticky("right", "docked")]
    );

    // Order, widths, and the compatibility projection are unchanged.
    let after = wire.columns();
    for (before, after) in columns.iter().zip(&after) {
        assert_eq!(before["id"], after["id"]);
        assert_eq!(before["width"], after["width"]);
        assert_eq!(before["layout"], after["layout"]);
    }
}

#[test]
fn sticky_column_replaces_the_column_holding_the_same_edge() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_sticky(panes[2], "right", "docked");
    wire.set_sticky(panes[1], "right", "overlay");
    assert_eq!(wire.sticky(), vec![None, sticky("right", "overlay"), None]);
}

#[test]
fn sticky_column_moves_to_the_other_edge() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_sticky(panes[2], "right", "docked");
    wire.set_sticky(panes[2], "left", "docked");
    assert_eq!(wire.sticky(), vec![None, None, sticky("left", "docked")]);
}

#[test]
fn sticky_column_refuses_to_pin_the_last_scrolling_column() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_sticky(panes[1], "right", "docked");
    let response = wire.send(json!({
        "cmd": "set-column-sticky",
        "pane": panes[0],
        "sticky": true,
        "edge": "left",
    }));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], "sticky-column-last-scrolling");
    assert!(response["error"].as_str().unwrap().contains("at least one column must scroll"));
    assert_eq!(wire.sticky(), vec![None, sticky("right", "docked")]);

    // Replacing the same edge frees a column, so it is allowed.
    let data = wire.set_sticky(panes[0], "right", "docked");
    assert_eq!(data["sticky"], json!({"edge": "right", "mode": "docked"}));
    assert_eq!(wire.sticky(), vec![sticky("right", "docked"), None]);
}

#[test]
fn sticky_column_clears_and_clearing_is_idempotent() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_sticky(panes[1], "left", "overlay");
    let columns = wire.columns();
    for _ in 0..2 {
        let data = wire.ok(json!({
            "cmd": "set-column-sticky",
            "pane": panes[1],
            "sticky": false,
            "transaction": "tx-clear",
        }));
        assert_eq!(data["column"], columns[1]["id"]);
        assert_eq!(data["sticky"], Value::Null);
        assert_eq!(data["transaction"], "tx-clear");
        assert_eq!(wire.sticky(), vec![None, None]);
    }
}

#[test]
fn sticky_column_undo_layout_restores_previous_flags() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_sticky(panes[2], "right", "docked");
    wire.set_sticky(panes[2], "left", "overlay");

    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[2]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert_eq!(wire.sticky(), vec![None, None, sticky("right", "docked")]);

    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[2]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert_eq!(wire.sticky(), vec![None, None, None]);
}

#[test]
fn sticky_column_emits_screen_change_with_the_transaction() {
    let (mut wire, panes) = Wire::with_columns(2);
    let events = wire.mux.subscribe();
    wire.ok(json!({
        "cmd": "set-column-sticky",
        "pane": panes[1],
        "sticky": true,
        "transaction": "tx-event",
    }));
    let events = events.try_iter().collect::<Vec<_>>();
    assert!(events.iter().any(|event| matches!(event, MuxEvent::LayoutChanged(_))));
    let delta = events
        .iter()
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => Some(delta),
            _ => None,
        })
        .expect("a sticky change emits screen-changed");
    assert_eq!(delta.transaction.as_deref(), Some("tx-event"));
    assert_eq!(delta.entity["columns"][1]["sticky"], json!({"edge": "right", "mode": "docked"}));
}

#[test]
fn sticky_column_flags_clear_when_the_last_scrolling_column_closes() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_sticky(panes[0], "left", "docked");
    wire.set_sticky(panes[2], "right", "docked");
    wire.ok(json!({"cmd": "close-pane", "pane": panes[1]}));
    assert_eq!(wire.columns().len(), 2);
    assert_eq!(wire.sticky(), vec![None, None], "one column must keep scrolling");
}

#[test]
fn sticky_column_disappears_when_the_screen_collapses_to_one_column() {
    let (mut wire, panes) = Wire::with_columns(2);
    wire.set_sticky(panes[1], "right", "docked");
    wire.ok(json!({"cmd": "close-pane", "pane": panes[0]}));
    assert!(wire.screen().get("columns").is_none());
    // A column created later starts without a flag.
    let surface = wire.mux.new_pane_right(panes[1], 0.5, Some((38, 22))).unwrap();
    assert!(wire.mux.with_state(|state| state.pane_of(surface.id)).is_some());
    assert_eq!(wire.sticky(), vec![None, None]);
}

#[test]
fn sticky_column_closing_a_sticky_column_keeps_the_others() {
    let (mut wire, panes) = Wire::with_columns(3);
    wire.set_sticky(panes[0], "left", "overlay");
    wire.set_sticky(panes[2], "right", "docked");
    wire.ok(json!({"cmd": "close-pane", "pane": panes[2]}));
    assert_eq!(wire.sticky(), vec![sticky("left", "overlay"), None]);
}

#[test]
fn sticky_column_unknown_pane_or_screen_without_columns_is_not_found() {
    let (mut wire, panes) = Wire::with_columns(1);
    for pane in [panes[0], 999_999] {
        let response = wire.send(json!({"cmd": "set-column-sticky", "pane": pane, "sticky": true}));
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error_code"], "viewport-column-not-found");
    }
}

#[test]
fn sticky_column_rejects_unknown_edge_and_mode() {
    let (mut wire, panes) = Wire::with_columns(2);
    for request in [
        json!({"cmd": "set-column-sticky", "pane": panes[1], "sticky": true, "edge": "top"}),
        json!({"cmd": "set-column-sticky", "pane": panes[1], "sticky": true, "mode": "floating"}),
        json!({"cmd": "set-column-sticky", "pane": panes[1], "sticky": false, "edge": ""}),
    ] {
        let response = wire.send(request);
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error_code"], "invalid-argument");
    }
    let response = wire.send(json!({
        "cmd": "set-column-sticky",
        "pane": panes[1],
        "sticky": true,
        "transaction": "",
    }));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(wire.sticky(), vec![None, None]);
}
