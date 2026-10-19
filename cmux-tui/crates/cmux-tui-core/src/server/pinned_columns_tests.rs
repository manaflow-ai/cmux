//! Wire tests for pinned dock columns (`pinned-dock-v1`): the Home dock.
//!
//! A pinned column keeps its first tab (no close, move out or reorder away
//! from the first place) and takes no other tab unless the column's
//! `allow_tabs` is on. The rule is a column kind: it reads the column's tabs,
//! never a title or a page.

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

const PINNED: &str = "dock-column-pinned";

impl Wire {
    /// Two viewport columns, the first docked left as the agent chat and
    /// pinned. Returns the wire and the panes in column order.
    fn home() -> (Self, Vec<PaneId>) {
        let mux = Mux::new_for_test("pinned-columns", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let mut wire = Self { mux, outbound, writer, next_id: 1 };
        let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
        let left = wire.mux.with_state(|state| state.pane_of(first.id).unwrap());
        let surface = wire.mux.new_pane_right(left, 0.5, Some((38, 22))).unwrap();
        let right = wire.mux.with_state(|state| state.pane_of(surface.id).unwrap());
        let data = wire.ok(json!({
            "cmd": "set-column-dock", "pane": left, "dock": true, "edge": "left",
            "role": "agent_chat", "pinned": true,
        }));
        assert_eq!(data["dock"]["pinned"], true, "{data}");
        (wire, vec![left, right])
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

    fn tabs(&self, pane: PaneId) -> Vec<SurfaceId> {
        self.mux.with_state(|state| state.panes[&pane].tabs.clone())
    }

    fn dock(&self) -> Value {
        self.mux.with_state(|state| {
            serde_json::to_value(state.workspaces[0].screens[0].layout_columns[0].dock).unwrap()
        })
    }

    fn tab_id(&self, surface: SurfaceId) -> String {
        self.mux.with_state(|state| {
            state
                .resource_indexes
                .tabs
                .iter()
                .find(|(_, slot)| **slot == surface)
                .map(|(id, _)| id.to_string())
                .expect("tab has a public id")
        })
    }

    fn pane_id(&self, pane: PaneId) -> String {
        self.mux.with_state(|state| state.panes[&pane].public_id.to_string())
    }

    fn column_update(&self, fields: Value) -> Value {
        let (workspace, screen, column) = self.mux.with_state(|state| {
            let workspace = &state.workspaces[0];
            let screen = &workspace.screens[0];
            let id = screen.layout_columns[0].id;
            let column = state
                .resource_indexes
                .splits
                .iter()
                .find(|(_, split)| **split == id)
                .map(|(public, _)| public.to_string())
                .expect("column has a public id");
            (workspace.public_id.to_string(), screen.public_id.to_string(), column)
        });
        let mut params = json!({
            "machine": "current", "session": "current",
            "workspace": workspace, "screen": screen, "column": column,
        });
        for (key, value) in fields.as_object().unwrap() {
            params[key] = value.clone();
        }
        let key = format!("column-update-{}", uuid_like(&params));
        resource(&self.mux, "column.update", params, Some(&key))
    }
}

fn uuid_like(value: &Value) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    value.to_string().hash(&mut hasher);
    format!("{:016x}", hasher.finish())
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

fn refused(response: &Value) {
    assert_ne!(response["ok"], true, "{response}");
    assert!(response.to_string().contains(PINNED), "{response}");
}

fn resource_ok(response: &Value) {
    assert!(response.get("error").is_none_or(Value::is_null), "{response}");
}

#[test]
fn pinned_dock_capability_is_advertised() {
    let (mut wire, _) = Wire::home();
    let identity = wire.ok(json!({"cmd": "identify"}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.contains(&json!("pinned-dock-v1")), "{identity}");
}

#[test]
fn pinned_column_cannot_be_undocked_or_moved_and_keeps_its_pin_on_a_redock() {
    let (mut wire, panes) = Wire::home();
    refused(&wire.send(json!({"cmd": "set-column-dock", "pane": panes[0], "dock": false})));
    refused(
        &wire.send(
            json!({"cmd": "set-column-dock", "pane": panes[0], "dock": true, "edge": "right"}),
        ),
    );
    wire.ok(json!({
        "cmd": "set-column-dock", "pane": panes[0], "dock": true, "edge": "left",
        "mode": "overlay", "role": "agent_chat",
    }));
    let dock = wire.dock();
    assert_eq!(dock["pinned"], true, "a re-dock keeps the pin: {dock}");
    assert_eq!(dock["mode"], "overlay", "{dock}");
}

#[test]
fn pinned_tab_cannot_close_through_the_socket_or_the_resource_api() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    refused(&wire.send(json!({"cmd": "close-surface", "surface": home})));
    assert_eq!(wire.tabs(panes[0]), vec![home]);
    let params = json!({"machine": "current", "session": "current", "tab": wire.tab_id(home)});
    refused(&resource(&wire.mux, "tab.close", params, Some("close-home")));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the pinned tab stays");
    refused(&wire.send(json!({"cmd": "close-pane", "pane": panes[0]})));
    assert_eq!(wire.tabs(panes[0]), vec![home]);
}

#[test]
fn pinned_column_takes_no_new_tab_until_allow_tabs_is_on() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    refused(&wire.send(json!({"cmd": "new-tab", "pane": panes[0]})));
    let params =
        json!({"machine": "current", "session": "current", "pane": wire.pane_id(panes[0])});
    refused(&resource(&wire.mux, "tab.create_terminal", params.clone(), Some("new-in-home")));
    assert_eq!(wire.tabs(panes[0]), vec![home], "no tab entered the pinned column");

    resource_ok(&wire.column_update(json!({"allow_tabs": true})));
    assert_eq!(wire.dock()["allow_tabs"], true);
    resource_ok(&resource(&wire.mux, "tab.create_terminal", params, Some("new-in-home-2")));
    let tabs = wire.tabs(panes[0]);
    assert_eq!(tabs.len(), 2, "allow_tabs lets a tab in: {tabs:?}");
    assert_eq!(tabs[0], home, "the pinned tab keeps the first place");
    // The extra tab closes freely; the pinned tab still does not.
    wire.ok(json!({"cmd": "close-surface", "surface": tabs[1]}));
    assert_eq!(wire.tabs(panes[0]), vec![home]);
    refused(&wire.send(json!({"cmd": "close-surface", "surface": home})));
}

#[test]
fn pinned_column_refuses_moves_in_and_the_pinned_tab_moving_out_or_back() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let other = wire.tabs(panes[1])[0];
    let moved =
        wire.send(json!({"cmd": "move-tab", "surface": other, "pane": panes[0], "index": 1}));
    assert_ne!(moved["data"]["moved"], true, "no tab moves into the pinned column: {moved}");
    assert_eq!(wire.tabs(panes[0]), vec![home]);
    let out = wire.send(json!({"cmd": "move-tab", "surface": home, "pane": panes[1], "index": 0}));
    assert_ne!(out["data"]["moved"], true, "the pinned tab never leaves: {out}");
    assert_eq!(wire.tabs(panes[0]), vec![home]);

    resource_ok(&wire.column_update(json!({"allow_tabs": true})));
    wire.ok(json!({"cmd": "new-tab", "pane": panes[1]}));
    let other = wire.tabs(panes[1])[0];
    let moved =
        wire.send(json!({"cmd": "move-tab", "surface": other, "pane": panes[0], "index": 1}));
    assert_eq!(moved["data"]["moved"], true, "allow_tabs lets a move in: {moved}");
    let back = wire.send(json!({"cmd": "move-tab", "surface": home, "pane": panes[0], "index": 1}));
    assert_ne!(back["data"]["moved"], true, "the pinned tab keeps the first place: {back}");
    assert_eq!(wire.tabs(panes[0])[0], home);
}

#[test]
fn column_update_pins_one_way_and_allow_tabs_needs_a_pin() {
    let (wire, _) = Wire::home();
    let unpin = wire.column_update(json!({"pinned": false}));
    assert_eq!(unpin["error"]["code"], "validation.invalid", "{unpin}");
    resource_ok(&wire.column_update(json!({"allow_tabs": true})));
    resource_ok(&wire.column_update(json!({"allow_tabs": false})));
    assert!(wire.dock().get("allow_tabs").is_none(), "omitted while false: {}", wire.dock());
    assert_eq!(wire.dock()["pinned"], true);
}

#[test]
fn pinned_flags_are_stored_only_when_set() {
    use crate::model::{ColumnDock, DockEdge, DockMode};
    let plain = ColumnDock::new(DockEdge::Left, DockMode::Docked);
    let text = serde_json::to_string(&plain).unwrap();
    assert!(!text.contains("pinned") && !text.contains("allow_tabs"), "{text}");
    let pinned = ColumnDock { pinned: true, allow_tabs: true, ..plain };
    let text = serde_json::to_string(&pinned).unwrap();
    assert!(text.contains("\"pinned\":true") && text.contains("\"allow_tabs\":true"), "{text}");
    let old: ColumnDock = serde_json::from_str(r#"{"edge":"left","mode":"docked"}"#).unwrap();
    assert!(!old.pinned && !old.allow_tabs, "an old record reads as not pinned");
}
