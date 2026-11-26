//! The close-selection state of every window's workspaces
//! (`close_selection::windows::WindowCloseSelection`): the Rust twins of the
//! macOS app's `WorkspaceCloseSelectionTests` that drive the state directly
//! (Lawrence 2026-11-10: closing a workspace "lowkey focuses the wrong
//! workspace afterwards, we need to copy how google chrome does it"). The
//! state and every decision moved here from the Swift class
//! `WindowCloseSelection`; each test names the Swift test it is the twin of.
//!
//! The picks that changed with the move (an opener no row lists, a workspace
//! no row lists yet, a close of several rows, a quick relation through a
//! cancelled close) are in tests/window_close_selection_root.rs.

use cmux_focus_core::close_selection::OpenerKind::{self, Quick, Task};
use cmux_focus_core::close_selection::windows::{
    RepairStart, SettleFacts, WindowCloseSelection, kept,
};

type Id = &'static str;
type Rule = WindowCloseSelection<Id, Id>;

const W: Id = "w";

/// A person's New Workspace: the window showed `old` and now shows `new`.
/// `Quick`: placed at the end or the top. `Task`: after the current row.
fn make(rule: &mut Rule, new: Id, old: Id, kind: OpenerKind) {
    rule.expect_create(&new, &W, kind);
    rule.shown(&new, Some(&old), &W, true);
}

/// The person selects `new` in the window (a click, a shortcut).
fn go(rule: &mut Rule, new: Id, old: Id) {
    rule.shown(&new, Some(&old), &W, true);
}

/// The window's pick after its members changed (the app's
/// `WindowRegistry.repairedSelection`).
fn repaired(rule: &Rule, current: Id, previous: &[Id], members: &[Id]) -> Option<Id> {
    kept(Some(&current), members, &[])
        .or_else(|| rule_pick(rule, current, previous, members, &[previous.to_vec()]))
}

/// The rule's pick for a close while the window shows `shown`.
fn rule_pick(
    rule: &Rule,
    shown: Id,
    previous: &[Id],
    members: &[Id],
    orders: &[Vec<Id>],
) -> Option<Id> {
    rule.pick(Some(&shown), previous, members, orders)
}

/// Closes `closed` while the window shows `shown`: the pick, then the
/// workspace leaves the state.
fn close(rule: &mut Rule, closed: Id, shown: Id, rows: &[Id]) -> Option<Id> {
    let members: Vec<Id> = rows.iter().copied().filter(|id| *id != closed).collect();
    let pick = repaired(rule, shown, rows, &members);
    rule.left(&closed);
    pick
}

fn facts(owner: &[(Id, Id)], claimed: &[Id], existing: &[Id]) -> SettleFacts<Id, Id> {
    SettleFacts {
        owner: owner.iter().copied().collect(),
        claimed: claimed.iter().copied().collect(),
        existing: existing.iter().copied().collect(),
    }
}

// The default placement (after the current row): Chrome 156's observed
// middle-tab rows.

/// One module name in each test file of this change, so one test-name
/// filter (`window_close_selection::`) runs them all.
mod window_close_selection {
    use super::*;

    /// Swift: aNewWorkspaceAfterTheCurrentRowClosedAtOnceReturnsToTheOneHeCameFrom.
    #[test]
    fn a_new_workspace_after_the_current_row_closed_at_once_returns_to_its_opener() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "b", Task);
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "c", "d"]), Some("b"));
    }

    /// Swift: aVisitToItsOpenerAndBackStillReturnsToTheOpener.
    #[test]
    fn a_visit_to_its_opener_and_back_still_returns_to_the_opener() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "b", Task);
        go(&mut rule, "b", "n");
        go(&mut rule, "n", "b");
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "c", "d"]), Some("b"));
    }

    /// Swift: aVisitToAnUnrelatedWorkspaceAndBackSelectsTheNextRow.
    #[test]
    fn a_visit_to_an_unrelated_workspace_and_back_selects_the_next_row() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "b", Task);
        go(&mut rule, "d", "n");
        go(&mut rule, "n", "d");
        assert!(rule.is_empty());
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "c", "d"]), Some("c"));
    }

    // Placed at the end: the quick look-up.

    /// Swift: aNewWorkspaceAtTheEndClosedAtOnceReturnsToTheOneHeCameFrom.
    #[test]
    fn a_new_workspace_at_the_end_closed_at_once_returns_to_its_opener() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "a", Quick);
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "c", "n"]), Some("a"));
    }

    /// Swift: anyVisitEndsTheQuickOpener.
    #[test]
    fn any_visit_ends_the_quick_opener() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "a", Quick);
        go(&mut rule, "a", "n");
        go(&mut rule, "n", "a");
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
        // The last row, with no opener: the row above it.
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "c", "n"]), Some("c"));
    }

    // No relation: by position.

    /// Swift: closingAMiddleRowSelectsTheNextRow, closingTheLastRowSelectsThePreviousRow.
    #[test]
    fn with_no_relation_the_next_row_and_the_previous_one_only_for_the_last() {
        assert_eq!(close(&mut Rule::new(), "b", "b", &["a", "b", "c"]), Some("c"));
        assert_eq!(close(&mut Rule::new(), "c", "c", &["a", "b", "c"]), Some("b"));
    }

    /// Swift: aWorkspaceAScriptMadeHasNoOpener. Nothing expected it (the CLI,
    /// the socket, MCP, a restore, a move): the window showing it makes no
    /// relation.
    #[test]
    fn a_workspace_a_script_made_has_no_opener() {
        let mut rule = Rule::new();
        rule.shown(&"n", Some(&"a"), &W, false);
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
        assert_eq!(close(&mut rule, "n", "n", &["a", "n", "b", "c"]), Some("b"));
    }

    /// Swift: closingAWorkspaceThatIsNotShownKeepsTheSelectionAndTheRelation.
    #[test]
    fn closing_a_workspace_that_is_not_shown_keeps_the_selection_and_the_relation() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "b", Task);
        assert_eq!(close(&mut rule, "c", "n", &["a", "b", "n", "c", "d"]), Some("n"));
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "d"]), Some("b"));
    }

    /// Swift: aTabMovedToANewWorkspaceGetsNoOpener. A move reports no create,
    /// so the person's selection of the moved workspace makes no relation.
    #[test]
    fn a_workspace_no_create_reported_gets_no_opener() {
        let mut rule = Rule::new();
        rule.shown(&"moved", Some(&"b"), &W, true);
        assert!(rule.is_empty());
        assert_eq!(close(&mut rule, "moved", "moved", &["a", "b", "moved", "c"]), Some("c"));
    }

    /// A create expected by another window, or shown by a window that showed
    /// nothing before, makes no relation.
    #[test]
    fn a_create_another_window_shows_or_with_nothing_shown_before_gets_no_opener() {
        let mut rule = Rule::new();
        rule.expect_create(&"n", &W, Task);
        rule.shown(&"n", Some(&"b"), &"v", true);
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
        rule.expect_create(&"m", &W, Quick);
        rule.shown(&"m", None, &W, true);
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
    }

    /// Swift: aRelationDoesNotCrossWindows. "n" moved to window "v"; the
    /// selection repair of "w" settles the state after its pick.
    #[test]
    fn a_relation_does_not_cross_windows() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "b", Task);
        let questions = rule.settle_questions(&W);
        let mut asked = questions.workspaces.clone();
        asked.sort_unstable();
        assert_eq!(asked, ["b", "n"]);
        assert!(questions.windows.is_empty());
        rule.settle(&W, &facts(&[("n", "v"), ("b", "w")], &[], &["w", "v"]));
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
        assert_eq!(close(&mut rule, "n", "n", &["x", "n", "y"]), Some("y"));
    }

    /// Swift: aCreateTheWindowDidNotShowGetsNoOpener. The window lists "n" and
    /// still shows "b" (a background create): the repair after it settles the
    /// state, and a later visit makes no relation.
    #[test]
    fn a_create_the_window_did_not_show_gets_no_opener() {
        let mut rule = Rule::new();
        rule.expect_create(&"n", &W, Task);
        assert_eq!(rule.settle_questions(&W).workspaces, ["n"]);
        rule.settle(&W, &facts(&[("n", "w")], &[], &["w"]));
        assert!(!rule.holds_ids());
        go(&mut rule, "n", "b");
        assert!(rule.is_empty());
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "c"]), Some("c"));
    }

    /// A create that failed (not listed, not waited for) and one whose window
    /// is gone get no opener either.
    #[test]
    fn a_create_that_failed_or_whose_window_is_gone_gets_no_opener() {
        let mut rule = Rule::new();
        rule.expect_create(&"n", &W, Task);
        rule.settle(&W, &facts(&[], &[], &["w"]));
        assert!(!rule.holds_ids());
        rule.expect_create(&"m", &"v", Task);
        assert_eq!(rule.settle_questions(&W).windows, ["v"]);
        rule.settle(&W, &facts(&[], &["m"], &["w"]));
        assert!(!rule.holds_ids());
    }

    /// Swift: aRepairWhileTheCreateWaitsKeepsItsOpener. While its window waits
    /// for the create (not listed yet, still claimed), a repair keeps it.
    #[test]
    fn a_repair_while_the_create_waits_keeps_its_opener() {
        let mut rule = Rule::new();
        rule.expect_create(&"n", &W, Task);
        rule.settle(&W, &facts(&[], &["n"], &["w"]));
        go(&mut rule, "n", "b");
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "c"]), Some("b"));
    }

    /// Swift: aTileThatIsNotTheOpenerIsNotSelected. A member no row lists (a
    /// pinned tile "p") that is not the opener is never picked while a row is
    /// left, also with a relation held: a script selects "c" (no gesture, the
    /// relation of "n" stays) and "c", the last row, closes.
    #[test]
    fn a_tile_that_is_not_the_opener_is_not_selected() {
        let mut rule = Rule::new();
        let rows = vec!["a", "b", "n", "c"];
        make(&mut rule, "n", "b", Task);
        rule.shown(&"c", Some(&"n"), &W, false);
        assert!(!rule.is_empty());
        let previous = ["a", "b", "n", "c", "p"];
        let pick = rule_pick(&rule, "c", &previous, &["a", "b", "n", "p"], &[rows.clone(), rows]);
        assert_eq!(pick, Some("n"));
    }

    /// Swift: aSwitchAndACloseNeverWalkTheMembers. With nothing held, a switch,
    /// a close and a settle hold no id and ask nothing; with one relation held
    /// the settle asks about that relation's two workspaces only, whatever the
    /// size of the window.
    #[test]
    fn with_nothing_held_nothing_is_asked_and_one_relation_asks_about_two_workspaces() {
        let mut rule = Rule::new();
        rule.shown(&"w1", Some(&"w0"), &W, true);
        rule.left(&"w2");
        assert!(!rule.has_questions());
        let questions = rule.settle_questions(&W);
        assert!(questions.workspaces.is_empty() && questions.windows.is_empty());
        assert_eq!(questions.workspaces.capacity() + questions.windows.capacity(), 0);
        rule.settle(&W, &SettleFacts::default());
        assert!(!rule.holds_ids());
        make(&mut rule, "n", "w1", Task);
        go(&mut rule, "w1", "n");
        assert!(rule.has_questions());
        assert_eq!(rule.settle_questions(&W).workspaces.len(), 2);
        rule.settle(&W, &facts(&[("n", "w"), ("w1", "w")], &[], &["w"]));
        assert!(!rule.is_empty());
    }

    /// Swift: theRepairSelectsTheOpenerAndTheCommittedCloseEndsTheRelation. The
    /// repair picks and selects at the press; the relation of the closed
    /// workspace ends when no window lists it any more (the close is
    /// committed), not before.
    #[test]
    fn the_repair_selects_the_opener_and_the_committed_close_ends_the_relation() {
        let mut rule = Rule::new();
        let (rows, left) = (["a", "b", "n", "c"], ["a", "b", "c"]);
        make(&mut rule, "n", "b", Task);
        let pick = repaired(&rule, "n", &rows, &left);
        assert_eq!(pick, Some("b"));
        let repair = RepairStart {
            shown: Some(&"n"),
            pick: pick.as_ref(),
            gesture: false,
            pressed: false,
            members: &left,
            preferred: &[],
        };
        rule.repair_begin(&repair);
        rule.shown(&"b", Some(&"n"), &W, true);
        rule.repair_end();
        rule.settle(&W, &facts(&[("n", "w"), ("b", "w")], &[], &["w"]));
        assert!(!rule.is_empty());
        rule.settle(&W, &facts(&[("b", "w")], &[], &["w"]));
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
    }

    /// Swift: onlyTheCallerMakesAPreferredSelectionAGesture. A workspace in
    /// `preferred` is the person's only when the caller says so; a daemon
    /// delta's caller says "no gesture", so the selection it causes keeps the
    /// relations, whatever the window's own report says.
    #[test]
    fn only_the_caller_makes_a_preferred_selection_a_gesture() {
        for gesture in [false, true] {
            let mut rule = Rule::new();
            let members = ["a", "b", "n", "c", "x"];
            make(&mut rule, "n", "b", Task);
            let pick = kept(Some(&"n"), &members, &["x"]);
            assert_eq!(pick, Some("x"));
            let repair = RepairStart {
                shown: Some(&"n"),
                pick: pick.as_ref(),
                gesture,
                pressed: false,
                members: &members,
                preferred: &["x"],
            };
            rule.repair_begin(&repair);
            rule.shown(&"x", Some(&"n"), &W, true);
            rule.repair_end();
            assert_eq!(rule.is_empty(), gesture, "gesture {gesture}");
        }
    }

    /// Swift: aRenamedWindowKeepsItsCreatesAndRelations. The launch window
    /// takes a saved window's identity; its creates and relations follow.
    #[test]
    fn a_renamed_window_keeps_its_creates_and_relations() {
        let mut rule = Rule::new();
        make(&mut rule, "n", "b", Task);
        rule.expect_create(&"m", &W, Task);
        rule.renamed(&W, &"w2");
        assert!(rule.settle_questions(&"w2").windows.is_empty());
        rule.settle(&"w2", &facts(&[("n", "w2"), ("b", "w2")], &["m"], &["w2"]));
        assert!(!rule.is_empty());
        rule.shown(&"m", Some(&"n"), &"w2", true);
        assert_eq!(close(&mut rule, "m", "m", &["a", "b", "n", "m", "c"]), Some("n"));
        assert_eq!(close(&mut rule, "n", "n", &["a", "b", "n", "c"]), Some("b"));
    }
}
