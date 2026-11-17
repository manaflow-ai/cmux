//! Wire tests for the quick terminal (`quick-terminal-v1`).
//!
//! The quick terminal is one floating pane of a workspace with a mark: `Screen.quick_terminal` names the pane,
//! says whether it is hidden, and names the pane that gets the focus back at a hide. A hidden quick terminal
//! stays a pane of the screen and an entry of `Screen.floating`: a hide closes nothing. Each test reads the
//! state after the answer of a request.

use super::super::*;
use crate::mux::tests::floating_panes::{open_restart_mux, seed as seeded_store};

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    /// One workspace whose screen has `count` panes side by side. Returns the panes from left to right.
    fn with_panes(count: usize) -> (Self, Vec<PaneId>) {
        let wire = Self::on(Mux::new_for_test("quick-terminal", crate::SurfaceOptions::default()));
        let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
        let mut panes = vec![wire.mux.with_state(|state| state.pane_of(first.id).unwrap())];
        for _ in 1..count {
            let last = *panes.last().unwrap();
            let surface = wire.mux.new_pane_right(last, 0.5, Some((38, 22))).unwrap();
            panes.push(wire.mux.with_state(|state| state.pane_of(surface.id).unwrap()));
        }
        (wire, panes)
    }

    /// A wire to the server of `mux`.
    fn on(mux: Arc<Mux>) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        Self { mux, outbound, writer, next_id: 1 }
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

    /// The first screen of the first workspace, as the tree JSON shows it.
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

    /// `quick-terminal` for the screen with no mode: the toggle.
    fn toggle(&mut self) -> Value {
        let screen = self.screen()["id"].clone();
        self.ok(json!({"cmd": "quick-terminal", "screen": screen}))
    }

    /// `quick-terminal` for the screen with `mode`.
    fn quick(&mut self, mode: &str) -> Value {
        let screen = self.screen()["id"].clone();
        self.ok(json!({"cmd": "quick-terminal", "screen": screen, "mode": mode}))
    }

    fn focus(&mut self, pane: PaneId) {
        self.ok(json!({"cmd": "focus-pane", "pane": pane}));
    }

    /// `Screen.quick_terminal`: null when the screen has no quick terminal.
    fn mark(&self) -> Value {
        self.screen()["quick_terminal"].clone()
    }

    fn active(&self) -> Value {
        self.screen()["active_pane"].clone()
    }

    /// The `floating` member of the screen: empty when it is omitted.
    fn floating(&self) -> Vec<Value> {
        self.screen()["floating"].as_array().cloned().unwrap_or_default()
    }

    /// The floating panes of the screen, back to front.
    fn floating_panes(&self) -> Vec<PaneId> {
        self.floating().iter().map(|entry| pane(&entry["pane"])).collect()
    }

    /// Every pane of the screen, as the tree JSON lists them.
    fn panes(&self) -> Vec<PaneId> {
        self.screen()["panes"].as_array().unwrap().iter().map(|entry| pane(&entry["id"])).collect()
    }

    /// The public id of `pane`: a restart keeps it and can give the pane another number.
    fn public_id(&self, pane: PaneId) -> Value {
        self.mux.with_state(|state| json!(state.panes[&pane].public_id))
    }

    /// The pane that shows the surface, if a pane does.
    fn pane_of(&self, surface: SurfaceId) -> Option<PaneId> {
        self.mux.with_state(|state| state.pane_of(surface))
    }
}

fn pane(value: &Value) -> PaneId {
    serde_json::from_value(value.clone()).unwrap_or_else(|_| panic!("no pane id: {value}"))
}

/// The frame of an entry of `Screen.floating`.
fn frame_of(entry: &Value) -> Value {
    json!({"x": entry["x"], "y": entry["y"], "w": entry["w"], "h": entry["h"]})
}

fn frame(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"x": x, "y": y, "w": w, "h": h})
}

fn refused(response: &Value, code: &str) {
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], code, "{response}");
}

/// A quick terminal that the toggle made from the focus on `from`: the pane and the surface of the answer.
fn made(wire: &mut Wire, from: PaneId) -> (PaneId, SurfaceId) {
    wire.focus(from);
    let data = wire.toggle();
    assert_eq!(data["created"], true, "{data}");
    (pane(&data["pane"]), data["surface"].as_u64().unwrap())
}

#[test]
fn quick_terminal_capability_is_advertised() {
    let (mut wire, _) = Wire::with_panes(1);
    let identity = wire.ok(json!({"cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "quick-terminal-v1")
    );
}

/// With no quick terminal in the workspace the toggle makes one: a new pane that floats at the frame of the
/// request, has the mark and has the focus. The mark names the pane that had the focus.
#[test]
fn toggle_with_no_quick_terminal_makes_one_with_the_frame_and_the_focus() {
    let (mut wire, panes) = Wire::with_panes(2);
    wire.focus(panes[0]);
    assert!(wire.mark().is_null(), "a new screen has no quick terminal");
    let screen = wire.screen()["id"].clone();

    let data = wire.ok(json!({
        "cmd": "quick-terminal", "screen": screen, "x": 0.5, "y": 0.4, "w": 0.5, "h": 0.6,
    }));
    assert_eq!(data["screen"], screen, "{data}");
    assert_eq!(data["created"], true, "{data}");
    assert_eq!(data["hidden"], false, "{data}");
    let quick = pane(&data["pane"]);
    assert!(!panes.contains(&quick), "the quick terminal is a new pane: {data}");
    assert_eq!(data["focused"], json!(quick), "{data}");
    let surface = data["surface"].as_u64().expect("a new quick terminal has a surface");
    assert_eq!(wire.pane_of(surface), Some(quick), "the surface of the answer is in the new pane");

    assert_eq!(wire.panes().len(), 3, "the quick terminal is a pane of the screen");
    let floating = wire.floating();
    assert_eq!(floating.len(), 1, "{floating:?}");
    assert_eq!(pane(&floating[0]["pane"]), quick);
    assert_eq!(frame_of(&floating[0]), frame(0.5, 0.4, 0.5, 0.6), "the frame of the request");
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": false, "from": panes[0]}));
    assert_eq!(wire.active(), json!(quick));
}

/// With no frame in the request a new quick terminal stands at the bottom right.
#[test]
fn a_new_quick_terminal_with_no_frame_is_at_the_bottom_right() {
    let (mut wire, panes) = Wire::with_panes(1);
    let (quick, _) = made(&mut wire, panes[0]);
    let floating = wire.floating();
    assert_eq!(pane(&floating[0]["pane"]), quick);
    assert_eq!(frame_of(&floating[0]), frame(0.55, 0.55, 0.45, 0.45));
}

/// The toggle of a quick terminal that shows and has the focus hides it. The focus goes back to the pane that
/// had it, and the pane stays a pane of the screen and an entry of the list with its frame.
#[test]
fn toggle_of_the_focused_quick_terminal_hides_it_and_returns_the_focus() {
    let (mut wire, panes) = Wire::with_panes(3);
    let (quick, _) = made(&mut wire, panes[1]);
    let shown = wire.floating();

    let data = wire.toggle();
    assert_eq!(data["created"], false, "{data}");
    assert_eq!(data["hidden"], true, "{data}");
    assert_eq!(pane(&data["pane"]), quick, "{data}");
    assert_eq!(
        data["focused"],
        json!(panes[1]),
        "the pane that had the focus gets it back: {data}"
    );
    assert!(data.get("surface").is_none(), "a hide makes no surface: {data}");
    assert_eq!(wire.active(), json!(panes[1]));
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": true, "from": panes[1]}));
    assert_eq!(wire.floating(), shown, "a hidden quick terminal keeps its entry and its frame");
    assert_eq!(wire.panes().len(), 4, "a hide closes no pane");
}

/// The toggle of a hidden quick terminal shows it, gives it the focus and brings it to the front. The mark
/// names the pane that has the focus at the show.
#[test]
fn toggle_of_a_hidden_quick_terminal_shows_and_focuses_it() {
    let (mut wire, panes) = Wire::with_panes(3);
    let (quick, _) = made(&mut wire, panes[1]);
    wire.toggle();
    wire.ok(json!({"cmd": "float-pane", "pane": panes[0], "mode": "on"}));
    wire.focus(panes[2]);
    assert_eq!(wire.mark()["hidden"], true, "a float and a focus of other panes show nothing");

    let data = wire.toggle();
    assert_eq!(data["created"], false, "{data}");
    assert_eq!(data["hidden"], false, "{data}");
    assert_eq!(data["focused"], json!(quick), "{data}");
    assert_eq!(wire.active(), json!(quick));
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": false, "from": panes[2]}));
    assert_eq!(wire.floating_panes(), vec![panes[0], quick], "a show brings it to the front");
}

/// The toggle of a quick terminal that shows without the focus gives it the focus and does not hide it. The
/// next toggle hides it and gives the focus back to the pane that had it at that focus.
#[test]
fn toggle_of_a_shown_quick_terminal_without_the_focus_focuses_it() {
    let (mut wire, panes) = Wire::with_panes(3);
    let (quick, _) = made(&mut wire, panes[1]);
    wire.focus(panes[0]);
    assert_eq!(wire.mark()["hidden"], false, "a focus of another pane does not hide it");

    let data = wire.toggle();
    assert_eq!(data["created"], false, "{data}");
    assert_eq!(data["hidden"], false, "{data}");
    assert_eq!(data["focused"], json!(quick), "{data}");
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": false, "from": panes[0]}));

    let data = wire.toggle();
    assert_eq!(data["hidden"], true, "{data}");
    assert_eq!(wire.active(), json!(panes[0]));
}

/// A hide is not a close: the surface of the quick terminal is in its pane before the hide, while it is
/// hidden and after the show, and the daemon still has it.
#[test]
fn a_hidden_quick_terminal_keeps_its_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, surface) = made(&mut wire, panes[0]);
    let before = wire.panes();

    wire.toggle();
    assert_eq!(wire.mark()["hidden"], true);
    assert_eq!(wire.pane_of(surface), Some(quick), "the hidden pane keeps its surface");
    assert!(wire.mux.surface(surface).is_some(), "a hide ends no surface");
    assert_eq!(wire.panes(), before, "a hide closes no pane");

    let data = wire.toggle();
    assert_eq!(data["hidden"], false, "{data}");
    assert_eq!(pane(&data["pane"]), quick, "the same pane shows again: {data}");
    assert!(data.get("surface").is_none(), "a show makes no surface: {data}");
    assert_eq!(wire.pane_of(surface), Some(quick));
    assert!(wire.mux.surface(surface).is_some());
    assert_eq!(wire.panes(), before);
}

/// A close of the quick terminal's pane ends the mark, and the next toggle makes a new one.
#[test]
fn the_close_of_the_quick_terminal_ends_the_mark_and_a_toggle_makes_a_new_one() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);

    wire.ok(json!({"cmd": "close-pane", "pane": quick}));
    assert!(wire.mark().is_null(), "the mark goes with the pane");
    assert!(wire.floating().is_empty());
    assert_eq!(wire.panes().len(), 2);

    let data = wire.toggle();
    assert_eq!(data["created"], true, "{data}");
    let next = pane(&data["pane"]);
    assert_ne!(next, quick, "a new pane: {data}");
    assert_eq!(wire.mark()["pane"], json!(next));
    assert_eq!(wire.mark()["hidden"], false);
}

/// A focus request for a hidden quick terminal shows it, so a hidden quick terminal never has the focus.
#[test]
fn a_focus_of_a_hidden_quick_terminal_shows_it() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    wire.toggle();
    wire.focus(panes[1]);

    wire.focus(quick);
    assert_eq!(wire.active(), json!(quick));
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": false, "from": panes[1]}));
}

/// The pane that the mark names closes while the quick terminal shows: a hide still gives the focus to a
/// pane of the screen that is not the quick terminal, and the mark names no pane that is gone.
#[test]
fn a_hide_never_leaves_the_focus_on_the_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(3);
    let (quick, _) = made(&mut wire, panes[1]);
    wire.ok(json!({"cmd": "close-pane", "pane": panes[1]}));
    wire.focus(quick);

    let data = wire.toggle();
    assert_eq!(data["hidden"], true, "{data}");
    let focused = pane(&data["focused"]);
    assert!(
        focused == panes[0] || focused == panes[2],
        "the focus is on a pane that shows: {data}"
    );
    assert_eq!(wire.active(), json!(focused));
    let mark = wire.mark();
    assert_eq!(mark["pane"], json!(quick));
    assert_ne!(mark["from"], json!(panes[1]), "the mark names a pane that is gone: {mark}");
}

/// A move of the quick terminal by `float-pane` is kept through a hide and a show, and it hides nothing.
#[test]
fn a_moved_quick_terminal_keeps_its_frame_through_a_hide_and_a_show() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    wire.ok(json!({
        "cmd": "float-pane", "pane": quick, "mode": "on", "x": 0.1, "y": 0.2, "w": 0.4, "h": 0.5,
    }));
    assert_eq!(wire.mark()["hidden"], false, "a move does not hide it");
    assert_eq!(frame_of(&wire.floating()[0]), frame(0.1, 0.2, 0.4, 0.5));

    wire.focus(quick);
    wire.toggle();
    assert_eq!(wire.mark()["hidden"], true);
    assert_eq!(
        frame_of(&wire.floating()[0]),
        frame(0.1, 0.2, 0.4, 0.5),
        "the frame of a hidden one"
    );
    wire.toggle();
    assert_eq!(wire.mark()["hidden"], false);
    assert_eq!(
        frame_of(&wire.floating()[0]),
        frame(0.1, 0.2, 0.4, 0.5),
        "the frame after the show"
    );
}

/// `float-pane` with `off` puts the quick terminal back into the tiled layout: it is a plain pane then, and
/// the next toggle makes a new quick terminal.
#[test]
fn a_quick_terminal_that_goes_back_into_the_tiled_layout_is_a_plain_pane() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);

    wire.ok(json!({"cmd": "float-pane", "pane": quick, "mode": "off"}));
    assert!(wire.mark().is_null(), "a tiled pane has no mark");
    assert!(wire.floating().is_empty());
    assert_eq!(wire.panes().len(), 3, "the pane stays");

    let data = wire.toggle();
    assert_eq!(data["created"], true, "{data}");
    assert_ne!(pane(&data["pane"]), quick, "{data}");
    assert_eq!(wire.panes().len(), 4);
}

/// The modes: `show` makes a quick terminal when the workspace has none and shows a hidden one; `hide` hides
/// one that shows, with or without the focus, and does nothing when there is none.
#[test]
fn the_modes_show_and_hide_do_one_thing_each() {
    let (mut wire, panes) = Wire::with_panes(2);
    wire.focus(panes[0]);
    let data = wire.quick("hide");
    assert_eq!(data["created"], false, "{data}");
    assert!(data.get("pane").is_none(), "no quick terminal, no pane: {data}");
    assert!(wire.mark().is_null());
    assert_eq!(wire.panes().len(), 2, "a hide makes no pane");

    let data = wire.quick("show");
    assert_eq!(data["created"], true, "{data}");
    let quick = pane(&data["pane"]);
    let again = wire.quick("show");
    assert_eq!(again["created"], false, "{again}");
    assert_eq!(again["hidden"], false, "a show of one that shows hides nothing: {again}");

    wire.focus(panes[1]);
    let data = wire.quick("hide");
    assert_eq!(data["hidden"], true, "{data}");
    assert_eq!(data["focused"], json!(panes[1]), "a hide of one without the focus moves no focus");
    let data = wire.quick("show");
    assert_eq!(data["hidden"], false, "{data}");
    assert_eq!(data["focused"], json!(quick), "{data}");
    assert_eq!(wire.panes().len(), 3, "one quick terminal for the three requests");
}

#[test]
fn quick_terminal_refuses_a_bad_argument() {
    let (mut wire, _) = Wire::with_panes(2);
    let screen = wire.screen()["id"].clone();
    let response =
        wire.send(json!({"cmd": "quick-terminal", "screen": screen, "mode": "sideways"}));
    refused(&response, "invalid-argument");
    let response = wire.send(json!({"cmd": "quick-terminal", "screen": screen, "x": 0.25}));
    refused(&response, "invalid-argument");
    assert!(wire.mark().is_null());
    assert_eq!(wire.panes().len(), 2, "a refused request makes no pane");
}

/// A screen whose panes are all in a column with rows has no place for a floating pane: the make is refused
/// with its own code and changes nothing.
#[test]
fn a_screen_with_no_pane_that_can_float_refuses_the_make() {
    let (mut wire, panes) = Wire::with_panes(1);
    wire.mux.new_row_with_options(panes[0], 500, Default::default(), Some((38, 10)), None).unwrap();
    let before = wire.panes();
    assert_eq!(before.len(), 2, "the fixture: a column of 2 rows");
    let all_fixed = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        before.iter().all(|pane| screen.pane_never_floats(*pane))
    });
    assert!(all_fixed, "the fixture: no pane of the screen can float");

    let screen = wire.screen()["id"].clone();
    let response = wire.send(json!({"cmd": "quick-terminal", "screen": screen}));
    refused(&response, "quick-terminal-no-place");
    assert_eq!(wire.panes(), before, "a refused make makes no pane");
    assert!(wire.mark().is_null());
    assert!(wire.floating().is_empty());
}

/// A hide sends the layout of the screen with the list, the mark and the focus of after the hide.
#[test]
fn the_layout_event_of_a_hide_has_the_list_the_mark_and_the_focus() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    let events = wire.mux.subscribe();

    wire.toggle();
    let events = events.try_iter().collect::<Vec<_>>();
    let layouts = events
        .iter()
        .filter_map(|event| match event {
            MuxEvent::LayoutChanged(_, Some(delta)) => Some(delta.layout.clone()),
            _ => None,
        })
        .collect::<Vec<_>>();
    let last = layouts.last().expect("a hide sends the layout of its screen");
    assert_eq!(last["quick_terminal"], json!({"pane": quick, "hidden": true, "from": panes[0]}));
    assert_eq!(last["active_pane"], json!(panes[0]));
    assert_eq!(pane(&last["floating"][0]["pane"]), quick, "the hidden pane stays in the list");
    for layout in &layouts {
        assert!(
            layout["active_pane"] != json!(quick) || layout["quick_terminal"]["hidden"] == false,
            "an event shows the focus on a hidden quick terminal: {layout}"
        );
    }
}

/// A restart of the server keeps a hidden quick terminal hidden: the same pane, its frame, and the pane that
/// gets the focus back. The store is the restore fixture of the mux tests.
#[test]
fn a_hidden_quick_terminal_of_wire_requests_survives_a_restart() {
    let (root, session) = seeded_store("quick-restart", |_| {});
    let mut wire = Wire::on(open_restart_mux(&root, &session));
    let free = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        screen
            .root
            .pane_ids_vec()
            .into_iter()
            .filter(|pane| !screen.pane_never_floats(*pane))
            .collect::<Vec<_>>()
    });
    assert_eq!(free.len(), 2, "the fixture: 2 panes that can float");
    let (quick, _) = made(&mut wire, free[0]);
    wire.ok(json!({
        "cmd": "float-pane", "pane": quick, "mode": "on", "x": 0.1, "y": 0.2, "w": 0.4, "h": 0.5,
    }));
    wire.focus(quick);
    wire.toggle();
    let before = (wire.public_id(quick), wire.public_id(free[0]), wire.panes().len());
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": true, "from": free[0]}));
    wire.mux.shutdown();
    drop(wire);

    let mut wire = Wire::on(open_restart_mux(&root, &session));
    let mark = wire.mark();
    assert_eq!(mark["hidden"], true, "a restart keeps it hidden: {mark}");
    let quick = pane(&mark["pane"]);
    let from = pane(&mark["from"]);
    assert_eq!(
        (wire.public_id(quick), wire.public_id(from), wire.panes().len()),
        before,
        "the same pane is the quick terminal, the same pane gets the focus back, no pane is lost"
    );
    assert_ne!(wire.active(), json!(quick), "a hidden quick terminal has no focus after a restart");
    assert_eq!(wire.floating_panes(), vec![quick]);
    assert_eq!(
        frame_of(&wire.floating()[0]),
        frame(0.1, 0.2, 0.4, 0.5),
        "a restart keeps the frame"
    );

    let data = wire.toggle();
    assert_eq!(data["created"], false, "the toggle shows the one that the store kept: {data}");
    assert_eq!(data["hidden"], false, "{data}");
    assert_eq!(wire.active(), json!(quick));
    wire.mux.shutdown();
    drop(wire);
    std::fs::remove_dir_all(root).unwrap();
}
