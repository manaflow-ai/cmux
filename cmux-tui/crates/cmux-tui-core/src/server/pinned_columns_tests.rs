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
        Self::home_with(false)
    }

    /// [`Self::home`] with a web page as the pinned tab (Home's page), so a
    /// stash can name it.
    fn home_page() -> (Self, Vec<PaneId>) {
        Self::home_with(true)
    }

    fn home_with(page: bool) -> (Self, Vec<PaneId>) {
        let mux = Mux::new_for_test("pinned-columns", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let mut wire = Self { mux, outbound, writer, next_id: 1 };
        let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
        let left = wire.mux.with_state(|state| state.pane_of(first.id).unwrap());
        let surface = wire.mux.new_pane_right(left, 0.5, Some((38, 22))).unwrap();
        let right = wire.mux.with_state(|state| state.pane_of(surface.id).unwrap());
        if page {
            let record = crate::workspace_registry::FrontendBrowserRecord {
                engine: "cef".into(),
                url: "https://example.com/home".into(),
                title: None,
                favicon_url: None,
                profile_id: None,
                owner: None,
            };
            wire.mux.new_frontend_browser_tab(Some(left), record, None).unwrap();
            wire.ok(json!({"cmd": "close-surface", "surface": first.id}));
        }
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
    // A terminal tab aimed at it opens in a new column right of it instead (FC-1); none enters it.
    wire.ok(json!({"cmd": "new-tab", "pane": panes[0]}));
    let params =
        json!({"machine": "current", "session": "current", "pane": wire.pane_id(panes[0])});
    resource_ok(&resource(&wire.mux, "tab.create_terminal", params.clone(), Some("new-in-home")));
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

/// The Home Chief pane (home-chief-pane.md): every other close or reshape that would take its
/// pane or its tab away is refused too, through the resource API the CLI and MCP use.
#[test]
fn pinned_column_survives_pane_close_screen_close_and_a_split() {
    let (wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let pane = json!({"machine": "current", "session": "current", "pane": wire.pane_id(panes[0])});
    refused(&resource(&wire.mux, "pane.close", pane.clone(), Some("close-home-pane")));
    assert_eq!(wire.tabs(panes[0]), vec![home], "pane.close kept Home");

    let mut split = pane;
    split["direction"] = json!("down");
    let response = resource(&wire.mux, "pane.split", split, Some("split-home"));
    assert!(
        response.get("error").is_some_and(|e| !e.is_null()),
        "a split in Home was taken: {response}"
    );
    let dock_panes = wire.mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[0].root.pane_ids_vec().len()
    });
    assert_eq!(dock_panes, 1, "no pane joined the pinned column");

    // A second screen keeps the workspace open (closing its last screen closes the workspace,
    // which is not a removal; the store's home workspace refuses that itself, `home_not_closable`).
    let workspace_id = wire.mux.with_state(|state| state.workspaces[0].id);
    wire.mux
        .new_screen_with_spec(
            Some(workspace_id),
            crate::TerminalSpawnOptions::new(None, Vec::new()),
            None,
            crate::ScreenSpec::default(),
        )
        .unwrap();
    let (workspace, screen) = wire.mux.with_state(|state| {
        let workspace = &state.workspaces[0];
        (workspace.public_id.to_string(), workspace.screens[0].public_id.to_string())
    });
    let close = json!({"machine": "current", "session": "current", "workspace": workspace, "screen": screen});
    let response = resource(&wire.mux, "screen.close", close, Some("close-home-screen"));
    assert!(
        response.get("error").is_some_and(|e| !e.is_null()),
        "Home's screen closed: {response}"
    );
    assert_eq!(wire.tabs(panes[0]), vec![home], "screen.close kept Home");
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

/// `pinned-dock-alone-v1` (Leo 2026-10-19: "i cant even close the terminal on
/// the right of chief"): closing the last column beside the Home dock is no
/// longer refused. The pinned column stays, alone, at its own width, with its
/// pin and its tab.
#[test]
fn closing_the_last_column_beside_a_pinned_dock_leaves_the_dock_alone() {
    let (mut wire, panes) = Wire::home();
    let identity = wire.ok(json!({"cmd": "identify"}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.contains(&json!("pinned-dock-alone-v1")), "{identity}");
    let home = wire.tabs(panes[0])[0];
    let width = wire.mux.with_state(|state| state.workspaces[0].screens[0].layout_columns[0].width);
    let right = wire.tabs(panes[1])[0];
    wire.ok(json!({"cmd": "close-surface", "surface": right}));
    let (columns, dock, kept) = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let columns = screen
            .layout_columns
            .iter()
            .map(|c| (c.width, c.root.pane_ids_vec()))
            .collect::<Vec<_>>();
        (
            columns,
            screen.layout_columns.first().and_then(|c| c.dock),
            state.panes.contains_key(&panes[1]),
        )
    });
    assert_eq!(columns, vec![(width, vec![panes[0]])], "the dock is the screen's only column");
    let dock = dock.expect("still docked");
    assert!(dock.pinned && dock.edge == crate::model::DockEdge::Left, "{dock:?}");
    assert!(!kept, "the closed column's pane is gone");
    assert_eq!(wire.tabs(panes[0]), vec![home]);
    // The pinned tab still never closes.
    refused(&wire.send(json!({"cmd": "close-surface", "surface": home})));
}

/// `pinned-dock-alone-v1` (Leo 2026-10-19: "did we disable the initial thing
/// auto opening a random terminal pane on the right yet?"): a screen's only
/// tab moves into a new pinned dock without a `respawn`, so Home's dock needs
/// no placeholder terminal on its right. An unpinned dock still needs one.
#[test]
fn a_screens_only_tab_becomes_a_lone_pinned_dock_without_a_respawn() {
    let mut wire = Wire::home().0;
    let lone = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(lone).unwrap());
    let unpinned = json!({"edge": "left", "mode": "docked", "role": "agent_chat"});
    let response = wire.send(json!({
        "cmd": "move-tab-to-column", "surface": lone, "pane": pane, "width": 0.4, "dock": unpinned,
    }));
    assert_eq!(response["ok"], false, "an unpinned dock alone is refused: {response}");
    let pinned = json!({"edge": "left", "mode": "docked", "role": "agent_chat", "pinned": true});
    let data = wire.ok(json!({
        "cmd": "move-tab-to-column", "surface": lone, "pane": pane, "width": 0.4, "dock": pinned,
        "transaction": "home-dock-1",
    }));
    let new_pane: PaneId = serde_json::from_value(data["pane"].clone()).unwrap();
    assert_eq!(wire.tabs(new_pane), vec![lone]);
    let (columns, panes) = wire.mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(new_pane).unwrap();
        let screen = &state.workspaces[workspace].screens[screen];
        let columns = screen.layout_columns.iter().map(|c| (c.width, c.dock)).collect::<Vec<_>>();
        (columns, screen.root.pane_ids_vec())
    });
    assert_eq!(panes, vec![new_pane], "no terminal was left behind");
    let [(width, Some(dock))] = columns.as_slice() else {
        panic!("one docked column: {columns:?}")
    };
    assert!((width - 0.4).abs() < 1e-6 && dock.pinned, "{columns:?}");
    assert_eq!(dock.role, Some(crate::model::DockRole::AgentChat));
}

/// `pinned-dock-alone-v1`: the pinned dock alone still takes no tab. A
/// browser tab made in it (an agent's page beside its chat, a conversation
/// tab) opens in a new column right of it in the same commit, so nothing is
/// ever left in the dock; a background tab leaves the focus in the dock. A
/// terminal tab is refused as before.
/// The screen's columns as (width, pinned), left to right, and the column index holding `pane`.
fn columns_and_column_of(wire: &Wire, pane: PaneId) -> (Vec<(f32, bool)>, Option<usize>) {
    wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let columns = screen
            .layout_columns
            .iter()
            .map(|c| (c.width, c.dock.is_some_and(|d| d.pinned)))
            .collect();
        (columns, screen.layout_columns.iter().position(|column| column.root.contains(pane)))
    })
}

/// FC-1 (fuzz catalog, 2026-11-01): right after launch, Home's dock is pinned before it takes tabs (`allow_tabs`),
/// and a terminal tab aimed at it was refused (`dock-column-pinned`): the first New Terminal Tab from a script, the
/// CLI, MCP, a config command or a login opener failed. A terminal tab aimed at a pinned column that takes no tabs
/// opens in a new column right of the dock instead, through every terminal-tab entrypoint (the JSON-lines `new-tab`
/// the app sends and `tab.create_terminal` of the CLI and MCP), whether the dock is alone on its screen or not. The
/// dock keeps only its pinned tab.
#[test]
fn a_terminal_tab_aimed_at_a_pinned_dock_that_takes_no_tabs_opens_in_a_new_column_right_of_it() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let right = wire.tabs(panes[1])[0];
    wire.ok(json!({"cmd": "close-surface", "surface": right}));

    // Home's dock alone: the app's `new-tab`.
    let created = wire.ok(json!({"cmd": "new-tab", "pane": panes[0]}));
    let surface: SurfaceId = serde_json::from_value(created["surface"].clone()).unwrap();
    assert_eq!(wire.tabs(panes[0]), vec![home], "the dock keeps only its pinned tab");
    let beside =
        wire.mux.with_state(|state| state.pane_of(surface)).expect("the new tab has a pane");
    let (columns, column) = columns_and_column_of(&wire, beside);
    assert_eq!(columns.len(), 2, "{columns:?}");
    assert!(columns[0].1, "the dock stays first and pinned: {columns:?}");
    assert_eq!(columns[1], (crate::mux::LONE_DOCK_NEIGHBOR_WIDTH, false), "{columns:?}");
    assert_eq!(column, Some(1), "the terminal is in the column right of the dock");

    // With a column beside the dock: `tab.create_terminal` (CLI, MCP) aimed at the dock opens a new column right of it.
    let params =
        json!({"machine": "current", "session": "current", "pane": wire.pane_id(panes[0])});
    let reply = resource(&wire.mux, "tab.create_terminal", params, Some("terminal-beside-dock"));
    resource_ok(&reply);
    assert_eq!(wire.tabs(panes[0]), vec![home], "the dock keeps only its pinned tab: {reply}");
    let (columns, _) = columns_and_column_of(&wire, beside);
    assert_eq!(columns.len(), 3, "a new column, not a tab in the dock: {columns:?}");
    assert!(columns[0].1 && !columns[1].1 && !columns[2].1, "{columns:?}");
    let panes_now = wire.mux.with_state(|state| state.workspaces[0].screens[0].root.pane_ids_vec());
    assert_eq!(panes_now.len(), 3, "{panes_now:?}");
    let new_pane =
        panes_now.iter().copied().find(|pane| *pane != panes[0] && *pane != beside).unwrap();
    assert_eq!(
        columns_and_column_of(&wire, new_pane).1,
        Some(1),
        "the new column is right of the dock"
    );
    assert_eq!(wire.tabs(new_pane).len(), 1, "it holds the new terminal");
}

#[test]
fn a_browser_tab_made_in_a_lone_pinned_dock_opens_in_a_new_column_beside_it() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let right = wire.tabs(panes[1])[0];
    wire.ok(json!({"cmd": "close-surface", "surface": right}));
    wire.mux.focus_pane(panes[0]);
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "webkit".into(),
        url: "file:///tmp/notes.html".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let placement = crate::mux::FrontendTabPlacement { activate: false, ..Default::default() };
    let browser =
        wire.mux.new_frontend_browser_tab_placed(Some(panes[0]), record, None, placement).unwrap();
    assert_eq!(wire.tabs(panes[0]), vec![home], "the dock keeps only its tab");
    let (columns, beside, focused) = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let columns = screen
            .layout_columns
            .iter()
            .map(|c| (c.width, c.dock.is_some_and(|d| d.pinned)))
            .collect::<Vec<_>>();
        (columns, state.pane_of(browser.id), state.active_pane())
    });
    assert!(columns[0].1, "{columns:?}");
    assert_eq!(columns[1], (crate::mux::LONE_DOCK_NEIGHBOR_WIDTH, false), "{columns:?}");
    assert_eq!(columns.len(), 2);
    assert_ne!(beside, Some(panes[0]));
    assert_eq!(focused, Some(panes[0]), "a background tab leaves the focus in the dock");
    // With a column beside it the dock takes no browser tab either.
    let refused_tab = wire.mux.new_frontend_browser_tab(
        Some(panes[0]),
        crate::workspace_registry::FrontendBrowserRecord {
            engine: "webkit".into(),
            url: "https://example.com/".into(),
            title: None,
            favicon_url: None,
            profile_id: None,
            owner: None,
        },
        None,
    );
    assert!(refused_tab.is_err(), "the dock with a neighbour refuses the tab");
    assert_eq!(wire.tabs(panes[0]), vec![home]);
}

fn workspace_count(wire: &Wire) -> usize {
    wire.mux.with_state(|state| state.workspaces.len())
}

/// A bulk close keeps the single close's pinned rule (`pinned-dock-v1`): a
/// `close-tabs` set that names the pinned tab is refused with
/// `dock-column-pinned` and closes nothing, as `tab.close` and `close-surface`
/// refuse it. With Home's dock alone (`pinned-dock-alone-v1`) a set that
/// would empty and close the workspace is refused too.
#[test]
fn close_tabs_refuses_a_set_with_the_pinned_tab_and_closes_nothing() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let right = wire.tabs(panes[1])[0];
    let workspaces = workspace_count(&wire);
    refused(&wire.send(json!({"cmd": "close-tabs", "surfaces": [right, home]})));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the pinned tab stays");
    assert_eq!(wire.tabs(panes[1]), vec![right], "a refused set closes nothing");

    wire.ok(json!({"cmd": "close-tabs", "surfaces": [right]}));
    refused(&wire.send(json!({"cmd": "close-tabs", "surfaces": [home], "end_terminals": true})));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the lone dock keeps its tab");
    assert_eq!(workspace_count(&wire), workspaces, "the workspace did not close");
}

/// `close-tab-group` with `end_terminals` (a batch close) refuses a group
/// that holds the pinned tab, as the plain group close does.
#[test]
fn close_tab_group_refuses_a_group_with_the_pinned_tab() {
    let (mut wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let created = wire.ok(json!({"cmd": "create-tab-group", "surfaces": [home], "name": "Home"}));
    let group = created["group"]["id"].as_str().unwrap().to_string();
    refused(&wire.send(json!({"cmd": "close-tab-group", "group": group, "end_terminals": true})));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the batch group close kept Home");
    refused(&wire.send(json!({"cmd": "close-tab-group", "group": group})));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the plain group close kept Home");
}

/// `layout.bulk` close (the CLI and MCP bulk presets) refuses a selection
/// that holds the pinned tab or its pane, as `tab.close` and `pane.close` do.
#[test]
fn layout_bulk_close_refuses_the_pinned_tab_and_its_pane() {
    let (wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let right = wire.tabs(panes[1])[0];
    let tabs = json!({
        "machine": "current", "session": "current", "verb": "close", "level": "tab",
        "selector": "selection", "ids": [wire.tab_id(right), wire.tab_id(home)],
    });
    refused(&resource(&wire.mux, "layout.bulk", tabs, Some("bulk-home-tabs")));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the pinned tab stays");
    assert_eq!(wire.tabs(panes[1]), vec![right], "a refused bulk close closes nothing");
    let pane = json!({
        "machine": "current", "session": "current", "verb": "close", "level": "pane",
        "selector": "selection", "ids": [wire.pane_id(panes[0])],
    });
    refused(&resource(&wire.mux, "layout.bulk", pane, Some("bulk-home-pane")));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the pinned pane stays");
}

/// `stash.create` closes the tabs it stashes: it refuses Home's pinned page
/// as `tab.close` does.
#[test]
fn stash_refuses_the_pinned_page() {
    let (wire, panes) = Wire::home_page();
    let home = wire.tabs(panes[0])[0];
    let stash = json!({"machine": "current", "session": "current", "tabs": [wire.tab_id(home)]});
    refused(&resource(&wire.mux, "stash.create", stash, Some("stash-home")));
    assert_eq!(wire.tabs(panes[0]), vec![home], "the pinned page stays");
}

/// The `layout.bulk` presets (Close Other Panes, Close All Tabs and the
/// like) skip the pinned column, as they skip pinned tabs and the home
/// workspace: they close the rest and keep Home. An explicit selection that
/// names Home is still refused (above).
#[test]
fn layout_bulk_presets_skip_the_pinned_column() {
    let (wire, panes) = Wire::home();
    let home = wire.tabs(panes[0])[0];
    let third = wire.mux.new_pane_right(panes[1], 0.5, Some((18, 22))).unwrap();
    let third_pane = wire.mux.with_state(|state| state.pane_of(third.id).unwrap());
    let others = json!({
        "machine": "current", "session": "current", "verb": "close", "level": "pane",
        "selector": "others", "anchor": wire.pane_id(panes[1]),
    });
    let response = resource(&wire.mux, "layout.bulk", others, Some("bulk-other-panes"));
    resource_ok(&response);
    assert_eq!(wire.tabs(panes[0]), vec![home], "Close Other Panes kept Home: {response}");
    assert!(
        wire.mux.with_state(|state| !state.panes.contains_key(&third_pane)),
        "Close Other Panes closed the other pane: {response}"
    );

    let all = json!({
        "machine": "current", "session": "current", "verb": "close", "level": "tab",
        "selector": "all", "anchor": wire.tab_id(home),
    });
    let response = resource(&wire.mux, "layout.bulk", all, Some("bulk-all-home-tabs"));
    resource_ok(&response);
    assert_eq!(wire.tabs(panes[0]), vec![home], "Close All Tabs kept Home: {response}");
}

/// A Workspace-form stash skips Home's pinned page, as it skips pinned tabs,
/// and stashes the other pages. A Tabs-form stash that names it is still
/// refused (above).
#[test]
fn workspace_stash_skips_the_pinned_page() {
    let (wire, panes) = Wire::home_page();
    let home = wire.tabs(panes[0])[0];
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "cef".into(),
        url: "https://example.com/other".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let page = wire.mux.new_frontend_browser_tab(Some(panes[1]), record, None).unwrap().id;
    let (home_id, page_id) = (wire.tab_id(home), wire.tab_id(page));
    let workspace = wire.mux.with_state(|state| state.workspaces[0].public_id.to_string());
    let stash = json!({"machine": "current", "session": "current", "workspace": workspace});
    let response = resource(&wire.mux, "stash.create", stash, Some("stash-home-workspace"));
    resource_ok(&response);
    let value = &response["result"]["value"];
    assert_eq!(value["tab_ids"], json!([page_id]), "{response}");
    // The right pane's terminal is skipped too (not a page).
    let skipped = value["skipped"].as_array().unwrap();
    assert!(skipped.contains(&json!(home_id)), "the pinned page is skipped: {response}");
    assert_eq!(wire.tabs(panes[0]), vec![home], "the pinned page stays");
}
