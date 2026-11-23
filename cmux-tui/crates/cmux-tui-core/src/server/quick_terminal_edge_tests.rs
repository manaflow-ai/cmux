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

/// The 2 toggles of the test above, and the store refuses the commit of the creation that won 2 times: that
/// creation fails, and its pane leaves. The request that lost plans again after the end of that creation. It
/// sees no quick terminal then, so it makes the quick terminal of the workspace in its own screen, and its
/// answer names a pane that stays.
///
/// The order: a third request, a split, joins the group of the 2 creations and stops at its join. A group
/// commits after each of its creations ran, so the creation that won has no commit while the split stops.
/// The split goes on at the next step of the request that lost: its wait for the creations that run, or its
/// answer.
#[test]
fn a_toggle_that_lost_names_no_pane_of_a_creation_whose_commit_failed() {
    let (mut wire, panes) = Wire::with_panes(1);
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
    // The first request took its hook. The next one is for the request that lost: it tells the test that
    // it waits for the creations that run.
    let waits = second_steps.clone();
    wire.mux.set_creation_before_fence_hook_for_test(Box::new(move || {
        waits.send(Step::AtCreation).unwrap();
    }));
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

    let (third_joined, third) = channel::<()>();
    let (release, held) = channel::<()>();
    let (mux, beside) = (wire.mux.clone(), panes[0]);
    let third_thread = std::thread::spawn(move || {
        crate::mux::with_group_join_notice(
            Box::new(move || {
                third_joined.send(()).unwrap();
                held.recv().unwrap();
            }),
            || mux.split(beside, SplitDir::Right, Some((38, 22))).map(|surface| surface.id),
        )
    });
    third.recv().expect("the split joined no group of creations");
    // The commit of the group and the second commit of the creation that won.
    wire.mux.set_resource_patch_failures_remaining_for_test(2);
    go_on.send(()).unwrap();

    let early = match second.recv() {
        Ok(Step::AtCreation) => None,
        Ok(Step::Response(response)) => Some(response),
        Err(_) => panic!("the toggle that lost ended with no response"),
    };
    release.send(()).unwrap();
    let Ok(Step::Response(won)) = first.recv() else {
        panic!("the toggle that won ended with no response")
    };
    let lost = early.unwrap_or_else(|| match second.recv() {
        Ok(Step::Response(response)) => response,
        _ => panic!("the toggle that lost ended with no response"),
    });
    first_thread.join().unwrap();
    second_thread.join().unwrap();
    let split = third_thread.join().unwrap();

    assert_eq!(won["ok"], false, "the fixture: the creation that won fails: {won}");
    assert_eq!(lost["ok"], true, "the toggle that lost failed: {lost}");
    let lost = &lost["data"];
    let named = pane(&lost["pane"]);
    let screens = screens(&wire);
    assert!(
        screens.iter().any(|screen| panes_of(screen).contains(&named)),
        "the toggle that lost names a pane that did not stay: {lost}"
    );
    assert_eq!(lost["created"], true, "the toggle that lost makes the quick terminal: {lost}");
    let marks: Vec<&Value> = screens
        .iter()
        .map(|screen| &screen["quick_terminal"])
        .filter(|mark| !mark.is_null())
        .collect();
    assert_eq!(marks.len(), 1, "one quick terminal in the workspace: {marks:?}");
    assert_eq!(
        screens[1]["quick_terminal"],
        json!({"pane": named, "hidden": false, "from": there}),
        "the quick terminal is in the screen of the toggle that lost"
    );
    assert_eq!(lost["screen"], second_screen, "{lost}");
    assert!(split.is_ok(), "the fixture: the split has its pane: {:?}", split.err());
}

/// The 2 toggles and the split of the test above, and the store takes each commit. While the creation that
/// won has no commit, a third request for the quick terminal, a `show` from the second screen, reads the
/// pane of that creation in its first plan and brings it. Then the split goes on and the group commits. Each
/// of the 3 answers names the one pane that the first toggle made, that pane stays, and the workspace has
/// one quick terminal, in the second screen.
///
/// The order is the order of the test above. The `show` is sent at the next step of the request that lost,
/// from the thread of the test: the creation that won ran before that step, and the split still stops.
#[test]
fn a_request_that_reads_a_quick_terminal_before_its_commit_names_a_pane_that_stays() {
    let (mut wire, panes) = Wire::with_panes(1);
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
    let waits = second_steps.clone();
    wire.mux.set_creation_before_fence_hook_for_test(Box::new(move || {
        waits.send(Step::AtCreation).unwrap();
    }));
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

    let (third_joined, third) = channel::<()>();
    let (release, held) = channel::<()>();
    let (mux, beside) = (wire.mux.clone(), panes[0]);
    let third_thread = std::thread::spawn(move || {
        crate::mux::with_group_join_notice(
            Box::new(move || {
                third_joined.send(()).unwrap();
                held.recv().unwrap();
            }),
            || mux.split(beside, SplitDir::Right, Some((38, 22))).map(|surface| surface.id),
        )
    });
    third.recv().expect("the split joined no group of creations");
    go_on.send(()).unwrap();

    let early = match second.recv() {
        Ok(Step::AtCreation) => None,
        Ok(Step::Response(response)) => Some(response),
        Err(_) => panic!("the toggle that lost ended with no response"),
    };
    let shown =
        wire.send(json!({"cmd": "quick-terminal", "screen": second_screen, "mode": "show"}));
    release.send(()).unwrap();
    let won = answer(&first, "first");
    let lost = early.unwrap_or_else(|| match second.recv() {
        Ok(Step::Response(response)) => response,
        _ => panic!("the toggle that lost ended with no response"),
    });
    first_thread.join().unwrap();
    second_thread.join().unwrap();
    let split = third_thread.join().unwrap();

    assert_eq!(won["created"], true, "{won}");
    let quick = pane(&won["pane"]);
    assert_eq!(shown["ok"], true, "the show before the commit failed: {shown}");
    assert_eq!(lost["ok"], true, "the toggle that lost failed: {lost}");
    let (shown, lost) = (&shown["data"], &lost["data"]);
    for (which, data) in [("show before the commit", shown), ("toggle that lost", lost)] {
        assert_eq!(pane(&data["pane"]), quick, "the {which} names another pane: {data}");
        assert_eq!(data["created"], false, "the {which} made a quick terminal: {data}");
        assert_eq!(data["hidden"], false, "{data}");
        assert_eq!(data["screen"], second_screen, "{data}");
    }
    assert!(split.is_ok(), "the fixture: the split has its pane: {:?}", split.err());
    let screens = screens(&wire);
    assert!(
        panes_of(&screens[1]).contains(&quick),
        "the pane that the 3 answers name did not stay in the second screen"
    );
    assert_eq!(
        screens.iter().map(|screen| panes_of(screen).len()).sum::<usize>(),
        4,
        "the fixture has 2 panes, and the requests made the quick terminal and the pane of the split"
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
        "the quick terminal is in the second screen, with the pane that had the focus there"
    );
}

/// The count of the terminals of the state: the ones that have a place, and the ones of the catalog.
fn terminals(wire: &Wire) -> (usize, usize) {
    wire.mux.with_state(|state| (state.surfaces.len(), state.terminal_catalog.len()))
}

/// A toggle for the second screen of a workspace with no quick terminal decides on a make, and its creation
/// passes the check of its turn. While its terminal starts, a layout undo in the first screen puts the mark
/// back on the pane that was the quick terminal there. The creation then attaches no pane and its terminal is
/// discarded. The request plans again: it brings the quick terminal that the workspace has to its own
/// screen, and its answer says so. With no check at the attach, the workspace has 2 quick terminals.
///
/// The order: the creation stops after its check and before its effect, at the test seam of a pane creation.
/// The undo is sent from the thread of the test. Then the creation goes on.
#[test]
fn a_make_whose_workspace_got_a_quick_terminal_before_its_attach_makes_no_pane() {
    let (mut wire, panes) = Wire::with_panes(2);
    let (once, surface) = made(&mut wire, panes[0]);
    wire.ok(json!({"cmd": "float-pane", "pane": once, "mode": "off"}));
    let (second_screen, there) = new_screen(&mut wire);
    let pane_count =
        |wire: &Wire| screens(wire).iter().map(|screen| panes_of(screen).len()).sum::<usize>();
    let (panes_before, terminals_before) = (pane_count(&wire), terminals(&wire));

    let (steps, step) = channel::<Step>();
    let (go_on, wait) = channel::<()>();
    let at_effect = steps.clone();
    wire.mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        at_effect.send(Step::AtCreation).unwrap();
        wait.recv().unwrap();
    }));
    let (mux, toggle) =
        (wire.mux.clone(), json!({"cmd": "quick-terminal", "screen": second_screen}));
    let thread = std::thread::spawn(move || {
        let response = Wire::on(mux).send(toggle);
        steps.send(Step::Response(response)).unwrap();
    });
    at_creation(&step, "only");
    let undo = wire.send(json!({"cmd": "undo-layout", "pane": panes[0]}));
    let at_undo = screens(&wire);
    go_on.send(()).unwrap();
    let data = answer(&step, "only");
    thread.join().unwrap();

    assert_eq!(undo["data"]["undone"], true, "the fixture: the undo of the float request: {undo}");
    assert_eq!(
        at_undo[0]["quick_terminal"]["pane"],
        json!(once),
        "the fixture: the undo puts the mark back while the terminal of the make starts"
    );
    assert!(at_undo[1]["quick_terminal"].is_null(), "the fixture: the make has no pane yet");
    let screens = screens(&wire);
    let marks: Vec<&Value> = screens
        .iter()
        .map(|screen| &screen["quick_terminal"])
        .filter(|mark| !mark.is_null())
        .collect();
    assert_eq!(marks.len(), 1, "one quick terminal in the workspace: {marks:?}");
    assert_eq!(
        screens[1]["quick_terminal"],
        json!({"pane": once, "hidden": false, "from": there}),
        "the request brings the quick terminal of the workspace to its screen"
    );
    assert_eq!(data["created"], false, "the request made a quick terminal: {data}");
    assert!(data.get("surface").is_none(), "the request names a terminal that it made: {data}");
    assert_eq!(pane(&data["pane"]), once, "{data}");
    assert_eq!(data["screen"], second_screen, "{data}");
    assert_eq!(data["hidden"], false, "{data}");
    assert_eq!(data["focused"], json!(once), "{data}");
    assert_eq!(pane_count(&wire), panes_before, "the make left a pane: {data}");
    assert_eq!(terminals(&wire), terminals_before, "the make left a terminal: {data}");
    assert_eq!(wire.pane_of(surface), Some(once), "the quick terminal keeps its terminal");
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
