//! Wire tests for the count of the quick terminal (`quick-terminal-v1`): one for each workspace.
//!
//! A request names the screen that the client shows. The quick terminal of that screen's workspace comes to
//! that screen: the same pane with its terminal and its frame. So a workspace with 2 screens has one quick
//! terminal, and the mark is in the screen that holds the pane. Each test reads the state after the answer of
//! a request.

use super::*;

/// The workspaces of the tree JSON.
pub(super) fn workspaces(wire: &Wire) -> Vec<Value> {
    handle_command(
        &wire.mux,
        wire.mux.local_test_client(0),
        Command::ListWorkspaces { known: None, limit: None, after: None },
        &wire.writer,
    )
    .unwrap()["workspaces"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The screens of the workspace at `index`, as the tree JSON shows them.
fn screens_of(wire: &Wire, index: usize) -> Vec<Value> {
    workspaces(wire)[index]["screens"].as_array().cloned().unwrap_or_default()
}

/// The screens of the first workspace.
pub(super) fn screens(wire: &Wire) -> Vec<Value> {
    screens_of(wire, 0)
}

/// The marks of `screens`: one for each screen that has a quick terminal.
fn marks(screens: &[Value]) -> Vec<Value> {
    screens
        .iter()
        .map(|screen| screen["quick_terminal"].clone())
        .filter(|mark| !mark.is_null())
        .collect()
}

/// The panes of `screen`, as the tree JSON lists them.
pub(super) fn panes_of(screen: &Value) -> Vec<PaneId> {
    screen["panes"].as_array().into_iter().flatten().map(|entry| pane(&entry["id"])).collect()
}

/// The floating list of `screen`, back to front: each pane and its frame.
fn floating_of(screen: &Value) -> Vec<(PaneId, Value)> {
    let list = screen["floating"].as_array().cloned().unwrap_or_default();
    list.iter().map(|entry| (pane(&entry["pane"]), frame_of(entry))).collect()
}

/// A new screen in the first workspace: its id and its pane.
pub(super) fn new_screen(wire: &mut Wire) -> (Value, PaneId) {
    let workspace = wire.mux.with_state(|state| state.workspaces[0].id);
    wire.ok(json!({"cmd": "new-screen", "workspace": workspace, "cols": 80, "rows": 22}));
    let screen = screens(wire).last().cloned().expect("the workspace has a screen");
    (screen["id"].clone(), pane(&screen["active_pane"]))
}

/// `quick-terminal` for `screen` with no mode: the toggle.
fn toggle_in(wire: &mut Wire, screen: &Value) -> Value {
    wire.ok(json!({"cmd": "quick-terminal", "screen": screen}))
}

/// The quick terminal of the first screen at the frame (0.1, 0.2, 0.4, 0.5), with the focus, and a second
/// screen of the same workspace: the quick terminal, its surface, the second screen and the pane of it.
fn two_screens(wire: &mut Wire, from: PaneId) -> (PaneId, SurfaceId, Value, PaneId) {
    let (quick, surface) = made(wire, from);
    wire.ok(json!({
        "cmd": "float-pane", "pane": quick, "mode": "on", "x": 0.1, "y": 0.2, "w": 0.4, "h": 0.5,
    }));
    let (second, there) = new_screen(wire);
    assert_eq!(screens(wire).len(), 2, "the fixture: 2 screens in one workspace");
    (quick, surface, second, there)
}

/// A toggle in a second screen of the workspace makes no second quick terminal. The one of the workspace
/// comes to that screen: the same pane and terminal, its frame, the mark and the focus. The screen that it
/// left has the focus on a pane of its own.
#[test]
fn a_toggle_in_another_screen_brings_the_same_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, surface, second, there) = two_screens(&mut wire, panes[0]);

    let data = toggle_in(&mut wire, &second);
    assert_eq!(data["created"], false, "a second quick terminal in one workspace: {data}");
    assert_eq!(pane(&data["pane"]), quick, "{data}");
    assert_eq!(wire.pane_of(surface), Some(quick), "the terminal of the quick terminal");
    let screens = screens(&wire);
    assert_eq!(marks(&screens), vec![json!({"pane": quick, "hidden": false, "from": there})]);
    assert!(screens[0]["quick_terminal"].is_null(), "the screen that it left has a mark");
    assert_eq!(panes_of(&screens[0]), panes, "the screen that it left");
    assert!(floating_of(&screens[0]).is_empty(), "the screen that it left has its entry");
    assert_eq!(screens[0]["active_pane"], json!(panes[0]), "the focus of the screen that it left");
    assert_eq!(panes_of(&screens[1]).len(), 2, "{}", screens[1]);
    assert_eq!(floating_of(&screens[1]), vec![(quick, frame(0.1, 0.2, 0.4, 0.5))]);
    assert_eq!(screens[1]["active_pane"], json!(quick));
    assert_eq!(wire.mux.with_state(|state| state.workspaces[0].active_screen), 1);
}

/// A hidden quick terminal comes to the screen of the toggle and shows there.
#[test]
fn a_toggle_in_another_screen_brings_and_shows_a_hidden_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _, second, there) = two_screens(&mut wire, panes[0]);
    wire.focus(quick);
    let hidden = wire.toggle();
    assert_eq!(hidden["hidden"], true, "the fixture: the quick terminal is hidden: {hidden}");

    let data = toggle_in(&mut wire, &second);
    assert_eq!(data["created"], false, "{data}");
    assert_eq!(data["hidden"], false, "{data}");
    let screens = screens(&wire);
    assert_eq!(marks(&screens), vec![json!({"pane": quick, "hidden": false, "from": there})]);
    assert_eq!(floating_of(&screens[1]), vec![(quick, frame(0.1, 0.2, 0.4, 0.5))]);
    assert_eq!(screens[1]["active_pane"], json!(quick));
}

/// A toggle after the quick terminal came hides it in the screen that it came to, and the focus goes back to
/// the pane of that screen. The next toggle there shows that terminal again.
#[test]
fn a_hide_after_a_bring_gives_the_focus_back_in_that_screen() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, surface, second, there) = two_screens(&mut wire, panes[0]);
    toggle_in(&mut wire, &second);

    let data = toggle_in(&mut wire, &second);
    assert_eq!(data["hidden"], true, "{data}");
    let screens_now = screens(&wire);
    assert_eq!(marks(&screens_now), vec![json!({"pane": quick, "hidden": true, "from": there})]);
    assert_eq!(screens_now[1]["active_pane"], json!(there));
    assert_eq!(wire.pane_of(surface), Some(quick), "a hide closes nothing");

    let data = toggle_in(&mut wire, &second);
    assert_eq!((data["created"].clone(), data["hidden"].clone()), (json!(false), json!(false)));
    assert_eq!(screens(&wire)[1]["active_pane"], json!(quick));
}

/// The mode `hide` from a screen that does not hold the quick terminal hides it where it is: a hide moves
/// no pane.
#[test]
fn a_hide_from_another_screen_hides_it_where_it_is() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _, second, there) = two_screens(&mut wire, panes[0]);

    let data = wire.ok(json!({"cmd": "quick-terminal", "screen": second, "mode": "hide"}));
    assert_eq!(data["hidden"], true, "{data}");
    let screens = screens(&wire);
    assert_eq!(marks(&screens), vec![json!({"pane": quick, "hidden": true, "from": panes[0]})]);
    assert!(!screens[0]["quick_terminal"].is_null(), "a hide moved the quick terminal");
    assert_eq!(screens[0]["active_pane"], json!(panes[0]));
    assert_eq!(panes_of(&screens[1]), vec![there]);
}

/// Each workspace has its own quick terminal.
#[test]
fn each_workspace_has_its_own_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let other = screens_of(&wire, 1)[0]["id"].clone();

    let data = toggle_in(&mut wire, &other);
    assert_eq!(data["created"], true, "{data}");
    assert_ne!(pane(&data["pane"]), quick);
    assert_eq!(marks(&screens(&wire)).len(), 1);
    assert_eq!(marks(&screens_of(&wire, 1)).len(), 1);
    assert_eq!(wire.mark()["pane"], json!(quick), "the first workspace keeps its own");
}

/// A screen that has a quick terminal moves into a workspace that has one: the workspace keeps its quick
/// terminal, and the one that came is a plain floating pane with its terminal.
#[test]
fn a_screen_that_moves_into_a_workspace_with_a_quick_terminal_brings_a_plain_floating_pane() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let (first, second) =
        wire.mux.with_state(|state| (state.workspaces[0].id, state.workspaces[1].id));
    // A workspace keeps its last screen, so the screen that moves is a second one.
    wire.ok(json!({"cmd": "new-screen", "workspace": second, "cols": 80, "rows": 22}));
    let other = screens_of(&wire, 1)[1]["id"].clone();
    let data = toggle_in(&mut wire, &other);
    assert_eq!(
        data["created"], true,
        "the fixture: the second workspace has a quick terminal: {data}"
    );
    let (came, surface) = (pane(&data["pane"]), data["surface"].as_u64().unwrap());

    wire.ok(json!({"cmd": "move-screen", "screen": other, "workspace": first}));
    let screens = screens(&wire);
    assert_eq!(screens.len(), 2, "the fixture: the screen is in the first workspace");
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "2 quick terminals in one workspace: {marks:?}");
    assert_eq!(marks[0]["pane"], json!(quick), "the workspace keeps its quick terminal");
    assert!(screens[1]["quick_terminal"].is_null(), "{}", screens[1]);
    let floating: Vec<PaneId> =
        floating_of(&screens[1]).into_iter().map(|(pane, _)| pane).collect();
    assert_eq!(floating, vec![came], "the pane that came floats still");
    assert_eq!(wire.pane_of(surface), Some(came), "the terminal of the pane that came");
}

/// A restart keeps the quick terminal in the screen that it came to, and the workspace has one.
#[test]
fn a_quick_terminal_that_came_to_another_screen_survives_a_restart_there() {
    let (root, session) = seeded_store("quick-bring-restart", |_| {});
    let mut wire = Wire::on(open_restart_mux(&root, &session));
    let free = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let panes = screen.root.pane_ids_vec();
        panes.into_iter().find(|pane| !screen.pane_never_floats(*pane))
    });
    let (quick, _) = made(&mut wire, free.expect("the fixture: a pane that can float"));
    let second = screens(&wire)[1]["id"].clone();
    let data = toggle_in(&mut wire, &second);
    assert_eq!(data["created"], false, "{data}");
    let before = (wire.public_id(quick), panes_of(&screens(&wire)[0]).len());
    wire.mux.shutdown();
    drop(wire);

    let wire = Wire::on(open_restart_mux(&root, &session));
    let screens = screens(&wire);
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "one quick terminal in the workspace after a restart: {marks:?}");
    let mark = &screens[1]["quick_terminal"];
    assert_eq!(
        mark["hidden"], false,
        "the quick terminal is in the screen that it came to: {mark}"
    );
    let quick = pane(&mark["pane"]);
    assert_eq!((wire.public_id(quick), panes_of(&screens[0]).len()), before);
    assert_eq!(floating_of(&screens[1]).len(), 1);
    wire.mux.shutdown();
    drop(wire);
    std::fs::remove_dir_all(root).unwrap();
}

/// A store with a mark in 2 screens of one workspace, as a build that had one quick terminal for each screen
/// wrote it: the first screen keeps the quick terminal, and the other one is a plain floating pane.
#[test]
fn two_marks_in_a_workspace_load_as_one() {
    let (root, session) = seeded_store("quick-two-marks", |_| {});
    let mut wire = Wire::on(open_restart_mux(&root, &session));
    let free = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let panes = screen.root.pane_ids_vec();
        panes.into_iter().find(|pane| !screen.pane_never_floats(*pane))
    });
    let (quick, _) = made(&mut wire, free.expect("the fixture: a pane that can float"));
    let single = pane(&screens(&wire)[1]["active_pane"]);
    let surface = wire.mux.new_pane_right(single, 0.5, Some((38, 22))).unwrap();
    let plain = wire.pane_of(surface.id).unwrap();
    wire.ok(json!({"cmd": "float-pane", "pane": plain, "mode": "on"}));
    let (first, second) = (wire.public_id(quick), wire.public_id(plain));
    wire.mux.shutdown();
    drop(wire);
    let sql = format!(
        "UPDATE resource_floating_panes SET quick = 1 WHERE pane_id = '{}'",
        second.as_str().unwrap()
    );
    crate::WorkspaceRegistry::open(&root, &session).unwrap().execute_sql_for_test(&sql).unwrap();

    let wire = Wire::on(open_restart_mux(&root, &session));
    let screens = screens(&wire);
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "2 marks in one workspace: {marks:?}");
    assert_eq!(wire.public_id(pane(&marks[0]["pane"])), first, "the first screen keeps the mark");
    assert!(screens[1]["quick_terminal"].is_null(), "{}", screens[1]);
    let floating = floating_of(&screens[1]);
    assert_eq!(floating.len(), 1, "the other one is a floating pane still");
    assert_eq!(wire.public_id(floating[0].0), second);
    wire.mux.shutdown();
    drop(wire);
    std::fs::remove_dir_all(root).unwrap();
}

/// The quick terminal of a screen becomes a tiled pane (`float-pane` with `off`), and a toggle in another
/// screen makes the new quick terminal of the workspace. An undo in the first screen puts the pane back
/// into the list of floating panes with no mark: the workspace has one quick terminal still.
#[test]
fn an_undo_in_a_screen_that_had_the_quick_terminal_puts_no_mark_back() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (once, _) = made(&mut wire, panes[0]);
    wire.ok(json!({"cmd": "float-pane", "pane": once, "mode": "off"}));
    assert!(wire.mark().is_null(), "the fixture: a tiled pane has no mark");
    let (second, _) = new_screen(&mut wire);
    let data = toggle_in(&mut wire, &second);
    assert_eq!(
        data["created"], true,
        "the fixture: the workspace has a new quick terminal: {data}"
    );
    let quick = pane(&data["pane"]);

    let response = wire.send(json!({"cmd": "undo-layout", "pane": panes[0]}));
    let screens = screens(&wire);
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "an undo made a second quick terminal in the workspace: {marks:?}");
    assert_eq!(marks[0]["pane"], json!(quick), "the workspace keeps its quick terminal");
    assert_eq!(response["data"]["undone"], true, "the undo of the float request: {response}");
    let floating: Vec<PaneId> =
        floating_of(&screens[0]).into_iter().map(|(pane, _)| pane).collect();
    assert_eq!(floating, vec![once], "the undo puts the pane back into the list");
}

/// A screen has a quick terminal and a change of its layout to undo, and moves into a workspace that has a
/// quick terminal: its own becomes a plain floating pane. An undo in that screen puts back the frame of
/// before the change and no mark: the workspace has one quick terminal still.
#[test]
fn an_undo_in_a_screen_that_came_into_a_workspace_with_a_quick_terminal_puts_no_mark_back() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let (first, second) =
        wire.mux.with_state(|state| (state.workspaces[0].id, state.workspaces[1].id));
    wire.ok(json!({"cmd": "new-screen", "workspace": second, "cols": 80, "rows": 22}));
    let other = screens_of(&wire, 1)[1]["id"].clone();
    let data = toggle_in(&mut wire, &other);
    assert_eq!(
        data["created"], true,
        "the fixture: the second workspace has a quick terminal: {data}"
    );
    let came = pane(&data["pane"]);
    // The change to undo is the frame of the quick terminal: its snapshot of before has the mark.
    wire.ok(json!({
        "cmd": "float-pane", "pane": came, "mode": "on", "x": 0.1, "y": 0.2, "w": 0.4, "h": 0.5,
    }));
    wire.ok(json!({"cmd": "move-screen", "screen": other, "workspace": first}));
    assert_eq!(
        marks(&screens(&wire)).len(),
        1,
        "the fixture: the move ended the mark of the pane that came"
    );

    let response = wire.send(json!({"cmd": "undo-layout", "pane": came}));
    let screens = screens(&wire);
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "an undo made a second quick terminal in the workspace: {marks:?}");
    assert_eq!(marks[0]["pane"], json!(quick), "the workspace keeps its quick terminal");
    assert_eq!(response["data"]["undone"], true, "the undo of the frame: {response}");
    assert_eq!(
        floating_of(&screens[1]),
        vec![(came, frame(0.55, 0.55, 0.45, 0.45))],
        "the pane that came floats at the frame of before the change"
    );
}

/// As the test above, with a change that made a pane: a new pane in the screen, after its quick terminal. The
/// undo of that change closes the new pane after a confirmation. It puts back no mark: the workspace has
/// one quick terminal still, and the pane that came floats still.
#[test]
fn a_confirmed_undo_in_a_screen_that_came_into_a_workspace_puts_no_mark_back() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = made(&mut wire, panes[0]);
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let (first, second) =
        wire.mux.with_state(|state| (state.workspaces[0].id, state.workspaces[1].id));
    wire.ok(json!({"cmd": "new-screen", "workspace": second, "cols": 80, "rows": 22}));
    let other = screens_of(&wire, 1)[1].clone();
    let (other, beside) = (other["id"].clone(), pane(&other["active_pane"]));
    let data = toggle_in(&mut wire, &other);
    assert_eq!(
        data["created"], true,
        "the fixture: the second workspace has a quick terminal: {data}"
    );
    let came = pane(&data["pane"]);
    // The change to undo is a new pane: its snapshot of before has the mark, and its undo closes the pane.
    let surface = wire.mux.new_pane_right(beside, 0.5, Some((38, 22))).unwrap();
    let added = wire.pane_of(surface.id).unwrap();
    wire.ok(json!({"cmd": "move-screen", "screen": other, "workspace": first}));
    assert_eq!(
        marks(&screens(&wire)).len(),
        1,
        "the fixture: the move ended the mark of the pane that came"
    );
    let asks = wire.ok(json!({"cmd": "undo-layout", "pane": beside}));
    assert_eq!(
        asks["closes_panes"],
        json!([added]),
        "the fixture: the undo asks to close the new pane: {asks}"
    );

    let response = wire.send(json!({
        "cmd": "undo-layout", "pane": beside, "revision": asks["revision"], "confirm_close": true,
    }));
    let screens = screens(&wire);
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "an undo made a second quick terminal in the workspace: {marks:?}");
    assert_eq!(marks[0]["pane"], json!(quick), "the workspace keeps its quick terminal");
    assert_eq!(response["data"]["undone"], true, "the undo of the new pane: {response}");
    assert!(!panes_of(&screens[1]).contains(&added), "the undo closes the new pane");
    let floating: Vec<PaneId> =
        floating_of(&screens[1]).into_iter().map(|(pane, _)| pane).collect();
    assert_eq!(floating, vec![came], "the pane that came floats still");
}

/// As the first test of an undo, and then the new quick terminal of the workspace closes: no screen has a
/// quick terminal. The undo in the first screen puts the pane back into the list of floating panes with its
/// mark: the workspace has one quick terminal again.
#[test]
fn an_undo_after_the_quick_terminal_of_the_other_screen_closed_puts_the_mark_back() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (once, _) = made(&mut wire, panes[0]);
    wire.ok(json!({"cmd": "float-pane", "pane": once, "mode": "off"}));
    assert!(wire.mark().is_null(), "the fixture: a tiled pane has no mark");
    let (second, _) = new_screen(&mut wire);
    let data = toggle_in(&mut wire, &second);
    assert_eq!(
        data["created"], true,
        "the fixture: the workspace has a new quick terminal: {data}"
    );
    wire.ok(json!({"cmd": "close-pane", "pane": pane(&data["pane"])}));
    assert!(
        marks(&screens(&wire)).is_empty(),
        "the fixture: the workspace has no quick terminal after the close"
    );

    let response = wire.send(json!({"cmd": "undo-layout", "pane": panes[0]}));
    assert_eq!(response["data"]["undone"], true, "the undo of the float request: {response}");
    let screens = screens(&wire);
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "the undo puts the mark back: {marks:?}");
    assert_eq!(screens[0]["quick_terminal"]["pane"], json!(once), "{}", screens[0]);
    let floating: Vec<PaneId> =
        floating_of(&screens[0]).into_iter().map(|(pane, _)| pane).collect();
    assert_eq!(floating, vec![once], "the undo puts the pane back into the list");
}

/// A bring is a move of a pane between 2 screens: it ends the layout undo of both, as each move of a pane
/// between screens does. An undo in the screen that the quick terminal left, and one in the screen that it
/// came to, have no change to undo.
#[test]
fn a_bring_ends_the_layout_undo_of_both_screens() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (_, _, second, there) = two_screens(&mut wire, panes[0]);
    let surface = wire.mux.new_pane_right(there, 0.5, Some((38, 22))).unwrap();
    let beside = wire.pane_of(surface.id).unwrap();
    wire.ok(json!({"cmd": "float-pane", "pane": beside, "mode": "on"}));
    let entries = |wire: &Wire| {
        wire.mux.with_state(|state| {
            let screens = &state.workspaces[0].screens;
            (screens[0].layout_undo.len(), screens[1].layout_undo.len())
        })
    };
    let before = entries(&wire);
    assert!(
        before.0 > 0 && before.1 > 0,
        "the fixture: each screen has a change to undo: {before:?}"
    );

    toggle_in(&mut wire, &second);
    assert_eq!(entries(&wire), (0, 0), "a bring kept a change to undo");
    for pane in [panes[0], there] {
        let response = wire.send(json!({"cmd": "undo-layout", "pane": pane}));
        refused(&response, "layout-undo-unavailable");
    }
}

/// The quick terminal comes to a screen that has a zoomed pane: the zoom of that screen ends, as it does
/// for each pane that becomes a split of a pane of a zoomed screen.
#[test]
fn a_bring_ends_the_zoom_of_the_screen_that_it_comes_to() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _, second, there) = two_screens(&mut wire, panes[0]);
    wire.mux.new_pane_right(there, 0.5, Some((38, 22))).unwrap();
    let zoom = wire.ok(json!({"cmd": "zoom-pane", "pane": there, "mode": "on"}));
    assert_eq!(zoom["zoomed"], true, "the fixture: a pane of the second screen is zoomed: {zoom}");
    assert_eq!(screens(&wire)[1]["zoomed_pane"], json!(there), "the fixture: the zoom");

    let data = toggle_in(&mut wire, &second);
    assert_eq!(pane(&data["pane"]), quick, "{data}");
    let screen = screens(&wire)[1].clone();
    assert_eq!(screen["quick_terminal"]["pane"], json!(quick), "{screen}");
    assert!(screen["zoomed_pane"].is_null(), "the bring kept the zoom of the screen: {screen}");
}

/// 2 clients send `show` at the same time, each for another screen of the workspace, while a third screen
/// holds the quick terminal. Each request brings it, in an order that the test does not set. After both the
/// workspace has one quick terminal: the same pane with its terminal, in one of the 2 screens, and each
/// answer names it.
#[test]
fn two_shows_at_once_from_2_screens_bring_one_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, surface, second, _) = two_screens(&mut wire, panes[0]);
    let (third, _) = new_screen(&mut wire);
    let start = Arc::new(std::sync::Barrier::new(2));
    let threads: Vec<_> = [second, third]
        .into_iter()
        .map(|screen| {
            let (mux, start) = (wire.mux.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                Wire::on(mux)
                    .send(json!({"cmd": "quick-terminal", "screen": screen, "mode": "show"}))
            })
        })
        .collect();
    for thread in threads {
        let response = thread.join().unwrap();
        assert_eq!(response["ok"], true, "a show at the same time as another failed: {response}");
        let data = &response["data"];
        assert_eq!(data["created"], false, "{data}");
        assert_eq!(pane(&data["pane"]), quick, "{data}");
    }

    let screens = screens(&wire);
    assert_eq!(screens.len(), 3, "the fixture: 3 screens in one workspace");
    let marks = marks(&screens);
    assert_eq!(marks.len(), 1, "one quick terminal in the workspace: {marks:?}");
    assert_eq!(marks[0]["pane"], json!(quick), "{marks:?}");
    assert_eq!(marks[0]["hidden"], false, "{marks:?}");
    assert!(screens[0]["quick_terminal"].is_null(), "no show brought the quick terminal");
    assert_eq!(screens.iter().map(|screen| panes_of(screen).len()).sum::<usize>(), 5);
    assert_eq!(wire.pane_of(surface), Some(quick), "the terminal of the quick terminal");
}
