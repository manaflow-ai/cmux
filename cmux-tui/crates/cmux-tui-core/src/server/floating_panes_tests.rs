//! Wire tests for floating panes (`floating-panes-v1`).
//!
//! A floating pane stays a leaf of the screen's layout; `Screen.floating`
//! lists the floating panes back to front, each with its frame. A screen
//! keeps at least one tiled pane. The list is restored by `undo-layout`.

use cmux_layout_reducer::floating_panes::is_normal;

use super::super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    /// One workspace whose screen has `count` panes side by side. Returns the
    /// panes from left to right.
    fn with_panes(count: usize) -> (Self, Vec<PaneId>) {
        let mux = Mux::new_for_test("floating-panes", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let mut wire = Self { mux, outbound, writer, next_id: 1 };
        let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
        let mut panes = vec![wire.mux.with_state(|state| state.pane_of(first.id).unwrap())];
        for _ in 1..count {
            let last = *panes.last().unwrap();
            panes.push(wire.new_pane_right(last));
        }
        (wire, panes)
    }

    fn new_pane_right(&mut self, target: PaneId) -> PaneId {
        let surface = self.mux.new_pane_right(target, 0.5, Some((38, 22))).unwrap();
        self.mux.with_state(|state| state.pane_of(surface.id).unwrap())
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
            Command::ListWorkspaces { known: None, limit: None },
            &self.writer,
        )
        .unwrap()["workspaces"][0]["screens"][0]
            .clone()
    }

    /// The `floating` member of the screen: empty when it is omitted.
    fn floating(&self) -> Vec<Value> {
        self.screen()["floating"].as_array().cloned().unwrap_or_default()
    }

    /// The floating panes of the screen, back to front.
    fn floating_panes(&self) -> Vec<PaneId> {
        self.floating()
            .iter()
            .map(|entry| serde_json::from_value(entry["pane"].clone()).unwrap())
            .collect()
    }

    /// Every pane of the screen, as the tree JSON lists them.
    fn panes(&self) -> Vec<PaneId> {
        self.screen()["panes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pane| serde_json::from_value(pane["id"].clone()).unwrap())
            .collect()
    }

    fn float(&mut self, pane: PaneId, mode: &str) -> Value {
        self.ok(json!({"cmd": "float-pane", "pane": pane, "mode": mode}))
    }

    fn float_at(&mut self, pane: PaneId, frame: [f64; 4]) -> Value {
        let [x, y, w, h] = frame;
        self.ok(json!({
            "cmd": "float-pane", "pane": pane, "mode": "on", "x": x, "y": y, "w": w, "h": h,
        }))
    }

    fn layout_revision(&self) -> u64 {
        self.mux.with_state(|state| state.workspaces[0].screens[0].layout_revision)
    }

    /// The rules every act keeps: the stored list is the list the rules give
    /// for the panes of the tree, and the tree JSON shows the same list.
    fn assert_rules(&self, context: &str) {
        let (panes, list) = self.mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            (screen.root.pane_ids_vec(), screen.floating.clone())
        });
        assert!(is_normal(&panes, &list), "{context}: {list:?} is not a list of {panes:?}");
        assert!(list.len() < panes.len(), "{context}: no tiled pane is left in {panes:?}");
        let shown = self.floating_panes();
        let stored = list.iter().map(|entry| entry.pane).collect::<Vec<_>>();
        assert_eq!(shown, stored, "{context}: the tree JSON shows another list");
        let mut listed = self.panes();
        let mut all = panes;
        listed.sort_unstable();
        all.sort_unstable();
        assert_eq!(listed, all, "{context}: a floating pane must stay a pane of the screen");
    }
}

fn frame(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"x": x, "y": y, "w": w, "h": h})
}

fn refused(response: &Value, code: &str) {
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], code, "{response}");
}

#[test]
fn floating_pane_capability_is_advertised() {
    let (mut wire, _) = Wire::with_panes(1);
    let identity = wire.ok(json!({"cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "floating-panes-v1")
    );
}

#[test]
fn floating_pane_floats_and_goes_back() {
    let (mut wire, panes) = Wire::with_panes(3);
    assert!(wire.screen().get("floating").is_none(), "a new pane is tiled");

    let data = wire.ok(json!({"cmd": "float-pane", "pane": panes[1], "transaction": 41}));
    assert_eq!(data["floating"], true, "{data}");
    assert_eq!(data["changed"], true, "{data}");
    assert_eq!(data["frame"], frame(0.2, 0.2, 0.6, 0.6), "a new floating pane is centered");
    assert_eq!(data["transaction"], 41);
    let floating = wire.floating();
    assert_eq!(floating.len(), 1, "{floating:?}");
    assert_eq!(floating[0]["pane"], json!(panes[1]));
    assert_eq!(floating[0]["x"], 0.2);
    assert_eq!(floating[0]["w"], 0.6);
    assert_eq!(wire.panes().len(), 3, "the floating pane stays a pane of the screen");
    wire.assert_rules("after float");

    let data = wire.float(panes[1], "toggle");
    assert_eq!(data["floating"], false, "{data}");
    assert_eq!(data["changed"], true, "{data}");
    assert!(data.get("frame").is_none(), "a tiled pane has no frame: {data}");
    assert!(data.get("transaction").is_none(), "no transaction, no echo: {data}");
    assert!(wire.screen().get("floating").is_none(), "an empty list is omitted");
    assert_eq!(wire.panes().len(), 3);
}

#[test]
fn floating_pane_refuses_the_last_tiled_pane() {
    let (mut wire, panes) = Wire::with_panes(2);
    wire.float(panes[0], "on");
    let response = wire.send(json!({"cmd": "float-pane", "pane": panes[1], "mode": "on"}));
    refused(&response, "floating-pane-last-tiled");
    assert_eq!(wire.floating_panes(), vec![panes[0]]);
    wire.assert_rules("after the refusal");

    let (mut alone, panes) = Wire::with_panes(1);
    let response = alone.send(json!({"cmd": "float-pane", "pane": panes[0]}));
    refused(&response, "floating-pane-last-tiled");
    assert!(alone.floating().is_empty());
}

#[test]
fn floating_pane_refuses_an_unknown_pane_and_a_bad_argument() {
    let (mut wire, panes) = Wire::with_panes(2);
    let response = wire.send(json!({"cmd": "float-pane", "pane": 987_654}));
    refused(&response, "floating-pane-missing");
    let response = wire.send(json!({"cmd": "float-pane", "pane": panes[0], "mode": "sideways"}));
    refused(&response, "invalid-argument");
    let response = wire.send(json!({"cmd": "float-pane", "pane": panes[0], "x": 0.25}));
    refused(&response, "invalid-argument");
    assert!(wire.floating().is_empty());
}

#[test]
fn floating_pane_refuses_a_pane_of_a_docked_column() {
    let (mut wire, panes) = Wire::with_panes(3);
    wire.ok(json!({"cmd": "set-column-dock", "pane": panes[2], "dock": true, "edge": "right"}));
    let response = wire.send(json!({"cmd": "float-pane", "pane": panes[2], "mode": "on"}));
    refused(&response, "floating-pane-fixed");
    assert!(wire.floating().is_empty());
}

#[test]
fn floating_pane_frame_moves_and_raises() {
    let (mut wire, panes) = Wire::with_panes(3);
    wire.float(panes[0], "on");
    wire.float(panes[1], "on");
    assert_eq!(wire.floating_panes(), vec![panes[0], panes[1]], "the last float is the front");

    // A frame that reaches past the screen is moved into it; the pane comes to the front.
    let data = wire.float_at(panes[0], [0.9, 0.9, 0.5, 0.5]);
    assert_eq!(data["frame"], frame(0.5, 0.5, 0.5, 0.5), "{data}");
    assert_eq!(wire.floating_panes(), vec![panes[1], panes[0]]);

    // A frame below the smallest size takes the smallest size.
    let data = wire.float_at(panes[1], [0.1, 0.1, 0.01, 0.01]);
    assert_eq!(data["frame"], frame(0.1, 0.1, 0.15, 0.15), "{data}");
    assert_eq!(wire.floating_panes(), vec![panes[0], panes[1]]);
    assert_eq!(wire.floating()[1]["h"], 0.15);
    wire.assert_rules("after two frames");
}

#[test]
fn floating_pane_focus_brings_it_to_the_front() {
    let (mut wire, panes) = Wire::with_panes(3);
    wire.float(panes[0], "on");
    wire.float(panes[1], "on");
    assert_eq!(wire.floating_panes(), vec![panes[0], panes[1]]);

    wire.ok(json!({"cmd": "focus-pane", "pane": panes[0]}));
    assert_eq!(wire.floating_panes(), vec![panes[1], panes[0]]);
    wire.assert_rules("after focus");
}

#[test]
fn floating_pane_undo_layout_puts_the_pane_back() {
    let (mut wire, panes) = Wire::with_panes(3);
    wire.float(panes[1], "on");
    // One drag: three frames with one transaction are one undo entry.
    for step in [0.05, 0.1, 0.15] {
        wire.ok(json!({
            "cmd": "float-pane", "pane": panes[1], "mode": "on",
            "x": step, "y": step, "w": 0.4, "h": 0.4, "transaction": 77,
        }));
    }
    assert_eq!(wire.floating()[0]["x"], 0.15);

    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[1]}));
    assert_eq!(undone["undone"], true, "{undone}");
    let floating = wire.floating();
    assert_eq!(floating.len(), 1, "the drag is undone, the float stays: {floating:?}");
    assert_eq!(floating[0]["x"], 0.2);
    assert_eq!(floating[0]["w"], 0.6);

    let undone = wire.ok(json!({"cmd": "undo-layout", "pane": panes[1]}));
    assert_eq!(undone["undone"], true, "{undone}");
    assert!(wire.floating().is_empty(), "the float is undone");
    assert_eq!(wire.panes().len(), 3);
}

#[test]
fn floating_pane_becomes_tiled_when_the_last_tiled_pane_closes() {
    let (mut wire, panes) = Wire::with_panes(3);
    wire.float(panes[0], "on");
    wire.float(panes[1], "on");

    wire.ok(json!({"cmd": "close-pane", "pane": panes[2]}));
    assert_eq!(wire.panes().len(), 2);
    assert_eq!(wire.floating_panes(), vec![panes[0]], "the front floating pane becomes tiled");
    wire.assert_rules("after the last tiled pane closed");

    // A floating pane that closes leaves the list.
    wire.ok(json!({"cmd": "close-pane", "pane": panes[0]}));
    assert!(wire.floating().is_empty());
    assert_eq!(wire.panes(), vec![panes[1]]);
}

#[test]
fn floating_pane_repeated_request_commits_nothing() {
    let (mut wire, panes) = Wire::with_panes(2);
    let first = wire.float_at(panes[0], [0.25, 0.25, 0.5, 0.5]);
    assert_eq!(first["changed"], true, "{first}");
    let revision = wire.layout_revision();

    let again = wire.float_at(panes[0], [0.25, 0.25, 0.5, 0.5]);
    assert_eq!(again["changed"], false, "{again}");
    assert_eq!(again["floating"], true, "{again}");
    assert_eq!(again["frame"], frame(0.25, 0.25, 0.5, 0.5), "{again}");
    let off = wire.float(panes[1], "off");
    assert_eq!(off["changed"], false, "a tiled pane stays tiled: {off}");
    assert_eq!(wire.layout_revision(), revision, "no change, no layout revision");
}

#[test]
fn floating_pane_emits_screen_change_and_layout_change() {
    let (mut wire, panes) = Wire::with_panes(2);
    let events = wire.mux.subscribe();
    wire.ok(json!({"cmd": "float-pane", "pane": panes[1], "mode": "on", "transaction": 5}));
    let events = events.try_iter().collect::<Vec<_>>();
    assert!(events.iter().any(|event| matches!(event, MuxEvent::LayoutChanged(..))));
    let delta = events
        .iter()
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => Some(delta),
            _ => None,
        })
        .expect("a float emits screen-changed");
    assert_eq!(delta.transaction.as_deref(), Some("5"), "the delta echoes the transaction");
    assert_eq!(delta.entity["floating"][0]["pane"], json!(panes[1]));
}

/// A fixed sequence of acts from a small generator: after each act the list
/// obeys the rules, and each act did what it says.
#[test]
fn floating_pane_sequence_of_acts_keeps_the_rules() {
    let (mut wire, mut panes) = Wire::with_panes(3);
    let mut seed: u64 = 0x5EED_F10A;
    let mut next = |bound: u64| {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) % bound
    };
    for step in 0..160 {
        let pane = panes[next(panes.len() as u64) as usize];
        let act = next(8);
        let context = format!("step {step}, act {act}, pane {pane}");
        match act {
            0 | 1 => {
                let floated = wire.floating_panes().contains(&pane);
                let response = wire.send(json!({"cmd": "float-pane", "pane": pane}));
                if response["ok"] == true {
                    assert_eq!(wire.floating_panes().contains(&pane), !floated, "{context}");
                } else {
                    refused(&response, "floating-pane-last-tiled");
                    assert!(!floated, "{context}: a floating pane always goes back");
                }
            }
            2 | 3 => {
                let part = |value: u64| value as f64 / 20.0;
                let request = json!({
                    "cmd": "float-pane", "pane": pane, "mode": "on",
                    "x": part(next(21)), "y": part(next(21)),
                    "w": part(next(21)), "h": part(next(21)),
                    "transaction": next(3),
                });
                let response = wire.send(request);
                if response["ok"] == true {
                    assert_eq!(wire.floating_panes().last(), Some(&pane), "{context}");
                } else {
                    refused(&response, "floating-pane-last-tiled");
                }
            }
            4 => {
                wire.float(pane, "off");
                assert!(!wire.floating_panes().contains(&pane), "{context}");
            }
            5 => {
                let floated = wire.floating_panes().contains(&pane);
                wire.ok(json!({"cmd": "focus-pane", "pane": pane}));
                if floated {
                    assert_eq!(wire.floating_panes().last(), Some(&pane), "{context}");
                }
            }
            6 if panes.len() > 1 => {
                wire.ok(json!({"cmd": "close-pane", "pane": pane}));
                panes.retain(|other| *other != pane);
                assert!(!wire.floating_panes().contains(&pane), "{context}");
            }
            _ if panes.len() < 6 => {
                let added = wire.new_pane_right(pane);
                panes.push(added);
                assert!(!wire.floating_panes().contains(&added), "{context}: a new pane is tiled");
            }
            _ => {}
        }
        wire.assert_rules(&context);
    }
}
