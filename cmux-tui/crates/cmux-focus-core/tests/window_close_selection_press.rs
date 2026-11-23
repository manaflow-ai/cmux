//! A quick relation through the press of a close (review of #40649,
//! should-fix). The press of a close (the macOS app's `InstantClose`) hides
//! the row and selects the pick at once; the close can still be cancelled
//! (the question) or refused. A task relation outlived that press; a quick
//! relation ended at it, because the selection the press made left its
//! workspace. Wanted: the selection a repair makes at a press does not end
//! the relation; the committed close ends it; a selection of another
//! workspace ends it as before.

use cmux_focus_core::close_selection::OpenerKind::{self, Quick, Task};
use cmux_focus_core::close_selection::windows::{RepairStart, SettleFacts, WindowCloseSelection};

type Id = &'static str;
type Rule = WindowCloseSelection<Id, Id>;

const W: Id = "w";

/// A person's New Workspace: the window showed `old` and now shows `new`.
fn make(rule: &mut Rule, new: Id, old: Id, kind: OpenerKind) {
    rule.expect_create(&new, &W, kind);
    rule.shown(&new, Some(&old), &W, true);
}

/// The rule's pick for a close of one row.
fn pick(
    rule: &Rule,
    shown: Option<Id>,
    previous: &[Id],
    members: &[Id],
    orders: &[Vec<Id>],
) -> Option<Id> {
    rule.pick(shown.as_ref(), previous, members, orders)
}

const END_ROWS: [Id; 4] = ["a", "b", "c", "n"];
const LEFT: [Id; 3] = ["a", "b", "c"];

/// The registry lists `listed` in the window, and the window is registered.
fn listed(listed: &[Id]) -> SettleFacts<Id, Id> {
    SettleFacts {
        owner: listed.iter().map(|id| (*id, W)).collect(),
        existing: [W].into_iter().collect(),
        ..SettleFacts::default()
    }
}

/// "n" is made from "a" at the end (`kind`), then the press of its close:
/// the row is hidden, the repair selects the pick, the state settles while
/// the registry still lists "n". `pressed` false: the same repair for a row
/// that left for another reason (a room change). Returns the pick.
fn press_the_close_of_n(rule: &mut Rule, kind: OpenerKind, pressed: bool) -> Option<Id> {
    make(rule, "n", "a", kind);
    let to = pick(rule, Some("n"), &END_ROWS, &LEFT, &[END_ROWS.to_vec()]);
    let repair = RepairStart {
        shown: Some(&"n"),
        pick: to.as_ref(),
        gesture: false,
        pressed,
        members: &LEFT,
        preferred: &[],
    };
    rule.repair_begin(&repair);
    if let Some(to) = &to {
        rule.shown(to, Some(&"n"), &W, true);
    }
    rule.repair_end();
    rule.settle(&W, &listed(&END_ROWS));
    to
}

/// One module name in each test file of this change, so one test-name
/// filter (`window_close_selection::`) runs them all.
mod window_close_selection {
    use super::*;

    /// The close is cancelled: the row is listed again and the window shows it
    /// again. Its quick opener is still there, so closing it returns to "a".
    /// Before the move the selection the press made ended the relation, and the
    /// close selected the row above, "c".
    #[test]
    fn a_quick_relation_outlives_a_cancelled_close() {
        let mut rule = Rule::new();
        assert_eq!(press_the_close_of_n(&mut rule, Quick, true), Some("a"));
        assert!(!rule.is_empty(), "the press of a close ended the quick relation");
        rule.shown(&"n", Some(&"a"), &W, true);
        assert_eq!(pick(&rule, Some("n"), &END_ROWS, &LEFT, &[END_ROWS.to_vec()]), Some("a"));
    }

    /// Swift: aCancelledCloseKeepsTheOpener. A task relation did outlive a
    /// cancelled close before the move, and still does.
    #[test]
    fn a_task_relation_outlives_a_cancelled_close() {
        let mut rule = Rule::new();
        assert_eq!(press_the_close_of_n(&mut rule, Task, true), Some("a"));
        rule.shown(&"n", Some(&"a"), &W, true);
        assert_eq!(pick(&rule, Some("n"), &END_ROWS, &LEFT, &[END_ROWS.to_vec()]), Some("a"));
    }

    /// The committed close ends the quick relation: by `left`, or by the settle
    /// when no window lists the workspace any more.
    #[test]
    fn the_committed_close_ends_the_quick_relation() {
        let mut rule = Rule::new();
        press_the_close_of_n(&mut rule, Quick, true);
        rule.left(&"n");
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
        let mut rule = Rule::new();
        press_the_close_of_n(&mut rule, Quick, true);
        rule.settle(&W, &listed(&LEFT));
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
    }

    /// After the press, a selection of another workspace (the person's own, or
    /// a script's: a quick relation ends "for any reason") ends the relation
    /// the press kept. The close is then cancelled and "n", the last row,
    /// closes again: by position, the row above.
    #[test]
    fn a_selection_of_another_workspace_after_the_press_ends_the_quick_relation() {
        for gesture in [true, false] {
            let mut rule = Rule::new();
            press_the_close_of_n(&mut rule, Quick, true);
            rule.shown(&"c", Some(&"a"), &W, gesture);
            assert!(rule.is_empty(), "gesture {gesture}");
            assert!(!rule.holds_ids(), "gesture {gesture}");
            rule.shown(&"n", Some(&"c"), &W, true);
            let again = pick(&rule, Some("n"), &END_ROWS, &LEFT, &[END_ROWS.to_vec()]);
            assert_eq!(again, Some("c"), "gesture {gesture}");
        }
    }

    /// A repair that is not the press of a close (a room change, a daemon
    /// delta) ends a quick relation when the selection leaves its workspace,
    /// as before.
    #[test]
    fn a_repair_that_is_no_press_ends_the_quick_relation() {
        let mut rule = Rule::new();
        assert_eq!(press_the_close_of_n(&mut rule, Quick, false), Some("a"));
        assert!(rule.is_empty());
        assert!(!rule.holds_ids());
    }
}
