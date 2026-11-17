//! Wire tests for the quick terminal (`quick-terminal-v1`) against the other acts of a screen.
//!
//! A hidden quick terminal is a pane that the person does not see. So an undo of the layout does not close it,
//! and a move of the focused pane's tab gives it no focus. 2 requests at once make one quick terminal. Each
//! test reads the state after the answer of a request; the test of 2 requests at once orders its 2 threads
//! with channels and the test seams of a pane creation, with no clock.

use std::sync::mpsc::{Receiver, channel};

use super::workspace::{new_screen, panes_of, screens, workspaces};
use super::*;

/// The screen that has `pane`, as the tree JSON shows it.
fn screen_with(wire: &Wire, pane: PaneId) -> Value {
    workspaces(wire)
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().cloned().unwrap_or_default())
        .find(|screen| panes_of(screen).contains(&pane))
        .unwrap_or_else(|| panic!("no screen has the pane {pane}"))
}

/// The one tab of `pane`.
fn only_tab(wire: &Wire, pane: PaneId) -> SurfaceId {
    wire.mux.with_state(|state| {
        let tabs = &state.panes[&pane].tabs;
        assert_eq!(tabs.len(), 1, "the fixture: the pane has one tab");
        tabs[0]
    })
}

/// A hidden quick terminal that the toggle made from the first pane of `panes`, which has the focus again:
/// the quick terminal and its surface. In the tree the quick terminal is the pane after the first pane.
fn hidden(wire: &mut Wire, panes: &[PaneId]) -> (PaneId, SurfaceId) {
    let (quick, surface) = made(wire, panes[0]);
    let data = wire.toggle();
    assert_eq!(data["hidden"], true, "the fixture: the quick terminal is hidden: {data}");
    assert_eq!(wire.active(), json!(panes[0]), "the fixture: the first pane has the focus");
    (quick, surface)
}

/// The make of the quick terminal is the last entry of the layout undo. While the quick terminal is hidden,
/// an undo does not ask to close it: the request is refused as stale. After a show the undo asks, as it does
/// for each pane that a change made.
#[test]
fn an_undo_after_a_hide_does_not_ask_to_close_the_hidden_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, surface) = hidden(&mut wire, &panes);

    let response = wire.send(json!({"cmd": "undo-layout", "pane": panes[0]}));
    assert_ne!(
        response["data"]["confirmation_required"], true,
        "the undo asks to close a quick terminal that is hidden: {response}"
    );
    refused(&response, "layout-undo-stale");
    assert_eq!(wire.pane_of(surface), Some(quick), "the terminal of the quick terminal");
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": true, "from": panes[0]}));

    let shown = wire.toggle();
    assert_eq!(shown["hidden"], false, "{shown}");
    let preview = wire.ok(json!({"cmd": "undo-layout", "pane": panes[0]}));
    assert_eq!(preview["confirmation_required"], true, "{preview}");
    assert_eq!(preview["closes_panes"], json!([quick]), "{preview}");
}

/// A confirmation that the person gave while the quick terminal showed does not close it after a hide: the
/// confirmed undo is refused as stale, and the pane, its terminal and its mark stay.
#[test]
fn a_confirmed_undo_after_a_hide_keeps_the_hidden_quick_terminal_and_its_shell() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, surface) = made(&mut wire, panes[0]);
    let preview = wire.ok(json!({"cmd": "undo-layout", "pane": panes[0]}));
    assert_eq!(
        preview["confirmation_required"], true,
        "the fixture: the undo of a make asks: {preview}"
    );
    let hide = wire.toggle();
    assert_eq!(hide["hidden"], true, "the fixture: the quick terminal is hidden: {hide}");

    let response = wire.send(json!({
        "cmd": "undo-layout", "pane": panes[0], "revision": preview["revision"], "confirm_close": true,
    }));
    assert_eq!(
        wire.pane_of(surface),
        Some(quick),
        "a confirmed undo ended the terminal of a hidden quick terminal: {response}"
    );
    refused(&response, "layout-undo-stale");
    assert_eq!(wire.panes().len(), 3, "the undo closed a pane");
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": true, "from": panes[0]}));
    assert_eq!(wire.active(), json!(panes[0]));
}

/// The last tab of the focused pane moves to a pane of another screen, so the pane leaves its screen. The
/// focus of that screen goes to a pane that shows: the hidden quick terminal stays hidden, also when it is
/// the first pane of the tree.
#[test]
fn a_tab_move_to_another_screen_gives_no_focus_to_a_hidden_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = hidden(&mut wire, &panes);
    let (_, there) = new_screen(&mut wire);
    let tab = only_tab(&wire, panes[0]);

    let moved = wire.ok(json!({"cmd": "move-tab", "surface": tab, "pane": there, "index": 0}));
    assert_eq!(moved["moved"], true, "the fixture: the tab moved: {moved}");
    assert_eq!(wire.pane_of(tab), Some(there), "the fixture: the tab is in the other screen");
    let left = screens(&wire)[0].clone();
    assert_eq!(
        panes_of(&left).len(),
        2,
        "the fixture: the pane of the tab left its screen: {left}"
    );
    assert_eq!(left["quick_terminal"]["pane"], json!(quick), "{left}");
    assert_eq!(
        left["quick_terminal"]["hidden"], true,
        "the move showed a hidden quick terminal: {left}"
    );
    assert_eq!(left["active_pane"], json!(panes[1]), "{left}");
}

/// The last tab of the focused pane moves to a new workspace. The focus of the screen that the pane leaves
/// goes to a pane that shows: the hidden quick terminal stays hidden.
#[test]
fn a_tab_move_to_a_new_workspace_gives_no_focus_to_a_hidden_quick_terminal() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = hidden(&mut wire, &panes);
    let tab = only_tab(&wire, panes[0]);

    wire.ok(json!({"cmd": "move-tab-to-workspace", "surface": tab}));
    assert_eq!(workspaces(&wire).len(), 2, "the fixture: the tab is in a new workspace");
    let left = screen_with(&wire, quick);
    assert_eq!(
        panes_of(&left).len(),
        2,
        "the fixture: the pane of the tab left its screen: {left}"
    );
    assert_eq!(left["quick_terminal"]["pane"], json!(quick), "{left}");
    assert_eq!(
        left["quick_terminal"]["hidden"], true,
        "the move showed a hidden quick terminal: {left}"
    );
    assert_eq!(left["active_pane"], json!(panes[1]), "{left}");
}

/// What a thread of the test of 2 requests at once tells the test.
enum Step {
    /// The request of the thread is at its pane creation: it decided on a make before.
    AtCreation,
    /// The response to the request.
    Response(Value),
}

/// The next step of a thread: it must be the pane creation of its request.
fn at_creation(steps: &Receiver<Step>, which: &str) {
    match steps.recv() {
        Ok(Step::AtCreation) => {}
        Ok(Step::Response(response)) => {
            panic!("the {which} toggle made no pane creation: {response}")
        }
        Err(_) => panic!("the {which} toggle ended with no response"),
    }
}

/// The answer of the request of a thread.
fn answer(steps: &Receiver<Step>, which: &str) -> Value {
    match steps.recv() {
        Ok(Step::Response(response)) => {
            assert_eq!(response["ok"], true, "the {which} toggle failed: {response}");
            response["data"].clone()
        }
        _ => panic!("the {which} toggle ended with no response"),
    }
}

/// 2 clients send a toggle at the same time for a screen with no quick terminal. Each request sees no quick
/// terminal and decides on a make. One request makes the quick terminal. The other makes no pane: it shows
/// the quick terminal that the first made, and its answer says so.
///
/// The order: the first request stops at its pane creation, before it changes the state. The second request
/// decides and comes to its own pane creation. Then the first goes on.
#[test]
fn two_toggles_at_once_make_one_quick_terminal_and_no_other_pane() {
    let (mut wire, panes) = Wire::with_panes(1);
    wire.focus(panes[0]);
    let screen = wire.screen()["id"].clone();
    let request = json!({"cmd": "quick-terminal", "screen": screen});

    let (first_steps, first) = channel::<Step>();
    let (go_on, wait) = channel::<()>();
    let at_fence = first_steps.clone();
    wire.mux.set_creation_before_fence_hook_for_test(Box::new(move || {
        at_fence.send(Step::AtCreation).unwrap();
        wait.recv().unwrap();
    }));
    let (mux, toggle) = (wire.mux.clone(), request.clone());
    let first_thread = std::thread::spawn(move || {
        let response = Wire::on(mux).send(toggle);
        first_steps.send(Step::Response(response)).unwrap();
    });
    at_creation(&first, "first");

    let (second_steps, second) = channel::<Step>();
    let (mux, toggle) = (wire.mux.clone(), request);
    let second_thread = std::thread::spawn(move || {
        let joined = second_steps.clone();
        let response = crate::mux::with_group_join_notice(
            Box::new(move || joined.send(Step::AtCreation).unwrap()),
            || Wire::on(mux).send(toggle),
        );
        second_steps.send(Step::Response(response)).unwrap();
    });
    at_creation(&second, "second");
    go_on.send(()).unwrap();
    let won = answer(&first, "first");
    let lost = answer(&second, "second");
    first_thread.join().unwrap();
    second_thread.join().unwrap();

    assert_eq!(won["created"], true, "{won}");
    let quick = pane(&won["pane"]);
    assert_eq!(wire.panes().len(), 2, "the toggle that lost made a pane of its own: {lost}");
    assert_eq!(lost["created"], false, "{lost}");
    assert!(lost.get("surface").is_none(), "the toggle that lost made a terminal: {lost}");
    assert_eq!(pane(&lost["pane"]), quick, "{lost}");
    assert_eq!(lost["hidden"], false, "{lost}");
    assert_eq!(lost["focused"], json!(quick), "{lost}");
    assert_eq!(wire.floating_panes(), vec![quick]);
    assert_eq!(wire.mark(), json!({"pane": quick, "hidden": false, "from": panes[0]}));
    assert_eq!(wire.active(), json!(quick));
}

/// 2 clients send a toggle at the same time, each for another screen of one workspace that has no quick
/// terminal. Each request decides on a make. One request makes the quick terminal of the workspace. The other
/// makes no pane: it brings the quick terminal that the first made to its own screen, and its answer says so.
///
/// The order is the order of the test above, with the second request for the second screen.
#[test]
fn two_toggles_at_once_from_2_screens_make_one_quick_terminal_in_the_workspace() {
    let (mut wire, _) = Wire::with_panes(1);
    let first_screen = wire.screen()["id"].clone();
    let (second_screen, there) = new_screen(&mut wire);

    let (first_steps, first) = channel::<Step>();
    let (go_on, wait) = channel::<()>();
    let at_fence = first_steps.clone();
    wire.mux.set_creation_before_fence_hook_for_test(Box::new(move || {
        at_fence.send(Step::AtCreation).unwrap();
        wait.recv().unwrap();
    }));
    let (mux, toggle) =
        (wire.mux.clone(), json!({"cmd": "quick-terminal", "screen": first_screen}));
    let first_thread = std::thread::spawn(move || {
        let response = Wire::on(mux).send(toggle);
        first_steps.send(Step::Response(response)).unwrap();
    });
    at_creation(&first, "first");

    let (second_steps, second) = channel::<Step>();
    let (mux, toggle) =
        (wire.mux.clone(), json!({"cmd": "quick-terminal", "screen": second_screen}));
    let second_thread = std::thread::spawn(move || {
        let joined = second_steps.clone();
        let response = crate::mux::with_group_join_notice(
            Box::new(move || joined.send(Step::AtCreation).unwrap()),
            || Wire::on(mux).send(toggle),
        );
        second_steps.send(Step::Response(response)).unwrap();
    });
    at_creation(&second, "second");
    go_on.send(()).unwrap();
    let won = answer(&first, "first");
    let lost = answer(&second, "second");
    first_thread.join().unwrap();
    second_thread.join().unwrap();

    assert_eq!(won["created"], true, "{won}");
    let quick = pane(&won["pane"]);
    assert_eq!(lost["created"], false, "the toggle that lost made a quick terminal: {lost}");
    assert!(lost.get("surface").is_none(), "the toggle that lost made a terminal: {lost}");
    assert_eq!(pane(&lost["pane"]), quick, "{lost}");
    assert_eq!(lost["hidden"], false, "{lost}");
    let screens = screens(&wire);
    assert_eq!(
        screens.iter().map(|screen| panes_of(screen).len()).sum::<usize>(),
        3,
        "the toggle that lost made a pane of its own: {lost}"
    );
    let marks: Vec<&Value> = screens
        .iter()
        .map(|screen| &screen["quick_terminal"])
        .filter(|mark| !mark.is_null())
        .collect();
    assert_eq!(marks.len(), 1, "one quick terminal in the workspace: {marks:?}");
    assert_eq!(
        screens[1]["quick_terminal"],
        json!({"pane": quick, "hidden": false, "from": there}),
        "the toggle that lost brings the quick terminal to its screen"
    );
    assert_eq!(lost["screen"], second_screen, "{lost}");
    assert_eq!(lost["focused"], json!(quick), "{lost}");
}

/// A float request with a frame for a hidden quick terminal shows it at that frame, as each act that brings
/// a floating pane to the front does. It gives no focus: the focus stays on the pane that has it.
#[test]
fn a_float_request_shows_a_hidden_quick_terminal_and_gives_it_no_focus() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (quick, _) = hidden(&mut wire, &panes);

    wire.ok(json!({
        "cmd": "float-pane", "pane": quick, "mode": "on", "x": 0.1, "y": 0.2, "w": 0.4, "h": 0.5,
    }));
    let mark = wire.mark();
    assert_eq!(mark["pane"], json!(quick), "{mark}");
    assert_eq!(mark["hidden"], false, "{mark}");
    assert_eq!(wire.active(), json!(panes[0]), "a float request moved the focus");
    let floating = wire.floating();
    assert_eq!(floating.len(), 1, "{floating:?}");
    assert_eq!(frame_of(&floating[0]), frame(0.1, 0.2, 0.4, 0.5));
}

/// The public resource operations can not make a quick terminal, because the router copies no parameter that
/// the catalog does not name. This holds while each operation of the catalog refuses the parameters that it
/// does not name, and no operation names the frame of a quick terminal as a parameter.
#[test]
fn no_operation_of_the_catalog_takes_the_frame_of_a_quick_terminal() {
    let catalog: Value =
        serde_json::from_str(include_str!("../../../../spec/resource-operations-v2.json")).unwrap();
    let mut operations = 0;
    for part in ["operations", "local_operations"] {
        let list =
            catalog[part].as_object().unwrap_or_else(|| panic!("the catalog has no `{part}`"));
        for (name, operation) in list {
            operations += 1;
            let params = &operation["params"];
            assert_eq!(
                params["extra"], false,
                "`{name}` takes parameters that the catalog does not name"
            );
            for kind in ["selectors", "fields"] {
                assert!(
                    params[kind].get("quick_terminal_frame").is_none(),
                    "`{name}` takes the frame of a quick terminal as a parameter"
                );
            }
        }
    }
    assert!(operations > 0, "the catalog has no operation");
}
