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
    result.as_ref().is_err_and(is_lost)
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

/// The pane that the make splits closed after the plan: the plan is lost, and the make makes no pane. With
/// no check of the pane, the make fails with the error of a pane that is not known, and the request does
/// not plan again.
#[test]
fn a_make_whose_target_pane_closed_is_a_lost_plan() {
    let mux = Mux::new_for_test("quick-plan-make-closed", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 22))).unwrap();
    let (screen, first) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (screen.id, screen.active_pane)
    });
    let surface = mux.new_pane_right(first, 0.5, Some((38, 22))).unwrap();
    let target = mux.with_state(|state| state.pane_of(surface.id)).unwrap();
    assert!(mux.close_pane(target).unwrap(), "the fixture: the target pane closed");
    let count = panes(&mux);

    let result = mux.act_on_plan(
        &Actor::Daemon,
        screen,
        Plan::Make(target),
        None,
        TerminalSpawnOptions::default(),
        None,
    );
    assert!(lost(&result), "a make with a closed target pane is no lost plan: {result:?}");
    assert_eq!(panes(&mux), count, "a make with a closed target pane made a pane");
}

/// The pane that the make splits is in another screen of the workspace after the plan (a move of the pane):
/// the plan is lost. The make puts no quick terminal into that other screen, and makes no pane.
#[test]
fn a_make_whose_target_pane_is_in_another_screen_is_a_lost_plan() {
    let mux = Mux::new_for_test("quick-plan-make-moved", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 22))).unwrap();
    let screen = mux.with_state(|state| state.workspaces[0].screens[0].id);
    let other = second_screen(&mux);
    let target = mux.with_state(|state| state.workspaces[0].screens[1].active_pane);
    let count = panes(&mux);

    let result = mux.act_on_plan(
        &Actor::Daemon,
        screen,
        Plan::Make(target),
        None,
        TerminalSpawnOptions::default(),
        None,
    );
    assert!(
        lost(&result),
        "a make with a target pane of the screen {other} is no lost plan: {result:?}"
    );
    assert_eq!(panes(&mux), count, "the make made a pane in the screen of its target pane");
    let marked = mux.with_state(|state| state.workspaces[0].quick_terminal().is_some());
    assert!(!marked, "the make put a quick terminal into the screen of its target pane");
}

/// The commits of the hide operation that the mutation ledger of the store holds.
fn hide_commits(mux: &Mux) -> i64 {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT COUNT(*) FROM resource_mutations WHERE operation = 'pane.quick-terminal-hide'",
            [],
            |row| row.get::<_, i64>(0),
        )?)
    })
    .unwrap()
}

/// The quick terminal of the first screen: its pane, and whether it is hidden.
fn mark(mux: &Mux) -> Option<(PaneId, bool)> {
    mux.with_state(|state| {
        let mark = state.workspaces[0].screens[0].quick_terminal();
        mark.map(|(pane, mark)| (pane, mark.hidden))
    })
}

/// Another request hid the quick terminal after the plan of a hide: the hide has nothing to hide. It makes
/// no commit of the store and sends no event, and the quick terminal stays hidden. With no check, the hide
/// makes a commit that changes nothing and sends the 2 events of a hide.
#[test]
fn a_hide_of_a_hidden_quick_terminal_commits_nothing_and_sends_no_event() {
    let (mux, screen, quick) = with_quick_terminal("quick-plan-hide-hidden");
    mux.hide_quick_terminal_as(&Actor::Daemon, screen).unwrap();
    assert_eq!(mark(&mux), Some((quick, true)), "the fixture: the quick terminal is hidden");
    assert_eq!(hide_commits(&mux), 1, "the fixture: the first hide is one commit of the store");
    let events = mux.subscribe();

    mux.hide_quick_terminal_as(&Actor::Daemon, screen).unwrap();
    assert_eq!(hide_commits(&mux), 1, "a hide with nothing to hide made a commit of the store");
    let events = events.try_iter().collect::<Vec<_>>();
    let of_the_screen = events
        .iter()
        .filter(|event| match event {
            MuxEvent::TreeDelta(delta) => {
                delta.kind == TreeDeltaKind::ScreenChanged && delta.screen == Some(screen)
            }
            MuxEvent::LayoutChanged(changed, _) => *changed == screen,
            _ => false,
        })
        .count();
    assert_eq!(of_the_screen, 0, "a hide with nothing to hide sent an event: {events:?}");
    assert_eq!(mark(&mux), Some((quick, true)), "the quick terminal stays hidden");
}

/// A request plans again one time. The error of its second act, when that plan is lost too, is the error of
/// the command that says so: no client sees the value of a lost plan. Each other error stays as it is.
#[test]
fn a_second_lost_plan_is_the_error_of_the_command() {
    let again = lost_again(anyhow::Error::new(PlanLost));
    assert!(!is_lost(&again), "the client gets the value of a lost plan: {again:?}");
    assert_eq!(
        again.downcast_ref::<FloatPaneError>(),
        Some(&FloatPaneError::QuickTerminalChanged),
        "{again:?}"
    );
    assert_eq!(FloatPaneError::QuickTerminalChanged.code(), None, "the error has no code");

    let other = lost_again(FloatPaneError::NoPlaceForQuickTerminal.into());
    assert_eq!(
        other.downcast_ref::<FloatPaneError>(),
        Some(&FloatPaneError::NoPlaceForQuickTerminal),
        "{other:?}"
    );
}

/// The lost plan of a creation whose terminal is spawned is an `operation.failed` with a mark: the settlement
/// of a creation that failed keeps that value as it is. The request reads the mark as a lost plan, and a
/// second one is the error of the command. An `operation.failed` with the same text and no mark is no lost
/// plan: the request does not read the text.
#[test]
fn the_lost_plan_of_a_creation_is_read_by_its_mark() {
    let failure = lost_in_creation("pane.split");
    assert_eq!(failure.code, "operation.failed", "{failure:?}");
    let settled = anyhow::Error::new(failure);
    assert!(is_lost(&settled), "the mark is not read as a lost plan: {settled:?}");
    let again = lost_again(settled);
    assert_eq!(
        again.downcast_ref::<FloatPaneError>(),
        Some(&FloatPaneError::QuickTerminalChanged),
        "{again:?}"
    );

    let extra = serde_json::json!({"attempt": 1});
    let plain = ResourceError::operation_failed("pane.split", PlanLost.to_string(), extra);
    let plain = anyhow::Error::new(plain);
    assert!(!is_lost(&plain), "the text of a lost plan with no mark is a lost plan: {plain:?}");
}
