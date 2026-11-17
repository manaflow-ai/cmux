//! Tests of the acts of the quick terminal against a state that changed after the plan of the request.
//!
//! A request plans with one read of the state, and acts in a commit after that read. Another request can run
//! between the two. Each test here calls the act with a plan that is not true for the state, as a request
//! does that lost against another one. No test has 2 threads: the state of after the other request is the
//! fixture.

use super::*;

/// A workspace with one screen, one tiled pane and the quick terminal that a toggle made: the mux, the
/// screen and the quick terminal.
fn with_quick_terminal(name: &str) -> (Arc<Mux>, ScreenId, PaneId) {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 22))).unwrap();
    let screen = mux.with_state(|state| state.workspaces[0].screens[0].id);
    let made = mux
        .quick_terminal_as(
            &Actor::Daemon,
            screen,
            QuickMode::Toggle,
            None,
            TerminalSpawnOptions::default(),
            None,
        )
        .unwrap();
    let surface = made.expect("the fixture: the toggle made a quick terminal");
    let quick = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_eq!(place(&mux, quick), Some((0, 0, true)), "the fixture: the quick terminal");
    (mux, screen, quick)
}

/// A second screen in the first workspace.
fn second_screen(mux: &Arc<Mux>) -> ScreenId {
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    mux.new_screen_named(Some(workspace), None, TerminalSpawnOptions::default(), Some((80, 22)))
        .unwrap();
    mux.with_state(|state| state.workspaces[0].screens[1].id)
}

/// Where `pane` is: the place of its workspace, the place of its screen in it, and whether the pane has the
/// mark of that screen. None when no screen has the pane.
fn place(mux: &Mux, pane: PaneId) -> Option<(usize, usize, bool)> {
    mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(pane)?;
        let marked = state.workspaces[workspace].screens[screen]
            .quick_terminal()
            .is_some_and(|(quick, _)| quick == pane);
        Some((workspace, screen, marked))
    })
}

/// The count of the panes of the state.
fn panes(mux: &Mux) -> usize {
    mux.with_state(|state| state.panes.len())
}

/// Whether `result` is the error of a plan that is not true any more.
fn lost<T>(result: &anyhow::Result<T>) -> bool {
    result.as_ref().is_err_and(|error| error.chain().any(|cause| cause.is::<PlanLost>()))
}

/// The screen of the request went to another workspace after the plan (a move of the screen): the quick
/// terminal is not the one of the workspace of that screen. The bring moves no pane between workspaces: the
/// plan is lost, and the quick terminal stays where it is with its mark.
#[test]
fn a_bring_to_a_screen_of_another_workspace_is_a_lost_plan_and_moves_nothing() {
    let (mux, _, quick) = with_quick_terminal("quick-plan-other-workspace");
    mux.new_workspace(None, Some((80, 22))).unwrap();
    let other = mux.with_state(|state| state.workspaces[1].screens[0].id);
    let count = panes(&mux);

    let result = mux.bring_quick_terminal_as(&Actor::Daemon, quick, other);
    assert_eq!(
        place(&mux, quick),
        Some((0, 0, true)),
        "a bring moved the quick terminal into another workspace: {result:?}"
    );
    assert!(lost(&result), "{result:?}");
    assert_eq!(panes(&mux), count);
}

/// Another request brought the quick terminal to the screen after the plan: the plan of a second bring to
/// that screen is lost, and nothing moves.
#[test]
fn a_bring_of_a_quick_terminal_that_is_in_the_screen_is_a_lost_plan() {
    let (mux, _, quick) = with_quick_terminal("quick-plan-in-the-screen");
    let second = second_screen(&mux);
    mux.bring_quick_terminal_as(&Actor::Daemon, quick, second).unwrap();
    assert_eq!(place(&mux, quick), Some((0, 1, true)), "the fixture: the first bring");

    let result = mux.bring_quick_terminal_as(&Actor::Daemon, quick, second);
    assert!(lost(&result), "{result:?}");
    assert_eq!(place(&mux, quick), Some((0, 1, true)));
}

/// The quick terminal closed after the plan: the plan of a bring is lost, and the bring makes no pane.
#[test]
fn a_bring_of_a_quick_terminal_that_closed_is_a_lost_plan() {
    let (mux, _, quick) = with_quick_terminal("quick-plan-bring-closed");
    let second = second_screen(&mux);
    assert!(mux.close_pane(quick).unwrap(), "the fixture: the quick terminal closed");
    let count = panes(&mux);

    let result = mux.bring_quick_terminal_as(&Actor::Daemon, quick, second);
    assert!(lost(&result), "{result:?}");
    assert_eq!(panes(&mux), count, "a bring of a closed pane made a pane");
}

/// The quick terminal closed after the plan of a show: the plan is lost, as the plan of a bring is, and
/// the show makes nothing. The request then plans one more time: it finds no quick terminal in the
/// workspace and makes one, which shows and has the focus. The plan is a value inside the request, so the
/// test does the 2 steps of the request: the act of the first plan, then the request with `show`.
#[test]
fn a_show_of_a_quick_terminal_that_closed_is_a_lost_plan_and_the_next_plan_makes_one() {
    let (mux, screen, quick) = with_quick_terminal("quick-plan-show-closed");
    assert!(mux.close_pane(quick).unwrap(), "the fixture: the quick terminal closed");
    let count = panes(&mux);

    let result = mux.act_on_plan(
        &Actor::Daemon,
        screen,
        Plan::Show(quick),
        None,
        TerminalSpawnOptions::default(),
        None,
    );
    assert!(lost(&result), "a show of a closed quick terminal is no lost plan: {result:?}");
    assert_eq!(panes(&mux), count, "a show of a closed pane made a pane");

    let made = mux
        .quick_terminal_as(
            &Actor::Daemon,
            screen,
            QuickMode::Show,
            None,
            TerminalSpawnOptions::default(),
            None,
        )
        .unwrap();
    let surface = made.expect("the next plan makes a quick terminal");
    let new = mux.with_state(|state| state.pane_of(surface));
    assert_eq!(panes(&mux), count + 1, "the next plan makes one pane");
    let (mark, active) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (screen.quick_terminal().map(|(pane, mark)| (pane, mark.hidden)), screen.active_pane)
    });
    assert_eq!(mark, new.map(|pane| (pane, false)), "the new quick terminal shows");
    assert_eq!(Some(active), new, "the new quick terminal has the focus");
}
