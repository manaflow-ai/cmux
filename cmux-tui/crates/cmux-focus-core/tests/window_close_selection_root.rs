//! What changed when the close-selection state of the windows moved from
//! the macOS app's Swift class into `WindowCloseSelection` (coordinator
//! order 2026-11-10 20:08Z: "the relation state, when a relation ends, and
//! the M2 / S3 preparations move into cmux-focus-core"):
//!
//! - the pick prepares its own inputs (second review of #40649, M2 and S3):
//!   an opener no row lists can be picked, and a workspace no row lists yet
//!   is picked with the opener rank. The table proves the new pick with raw
//!   inputs equals the old function with the inputs Swift prepared;
//! - a close of several rows asks the same pick as a close of one (Chrome
//!   156 as observed: Chrome picks the opener of the selected tab when the
//!   selected tab is among the closed ones);
//!
//! A quick relation through a cancelled close is in
//! tests/window_close_selection_press.rs.

use cmux_focus_core::close_selection::OpenerKind::{self, Quick, Task};
use cmux_focus_core::close_selection::windows::{WindowCloseSelection, kept};
use std::collections::HashMap;

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

/// The rule's pick for a person's close of several rows in one gesture (a
/// multi-selection, Close Others, Close Below, Close Above, a group close).
fn batch_pick(rule: &Rule, shown: Id, previous: &[Id], members: &[Id]) -> Option<Id> {
    rule.pick(Some(&shown), previous, members, &[previous.to_vec()])
}

/// The row orders the macOS app prepared for `Openers::successor_in_orders`
/// before the move (`WindowCloseSelection.pick` at 8e32a9172730), only while
/// a relation is held: an opener of `shown` that is a member and that no
/// order lists goes first in each order that lists `shown` (M2), and
/// `previous` is the last order (S3).
fn swift_prepared(
    rule: &Rule,
    shown: Option<Id>,
    previous: &[Id],
    members: &[Id],
    orders: &[Vec<Id>],
) -> Vec<Vec<Id>> {
    let mut orders = orders.to_vec();
    let Some(shown) = shown else { return orders };
    if rule.is_empty() {
        return orders;
    }
    if let Some((opener, _)) = rule.openers().opener(&shown)
        && members.contains(opener)
        && !orders.iter().any(|order| order.contains(opener))
    {
        for order in orders.iter_mut().filter(|order| order.contains(&shown)) {
            order.insert(0, *opener);
        }
    }
    orders.push(previous.to_vec());
    orders
}

/// One close: the person's creates (new, opener, kind), then the raw inputs
/// of the pick and the workspace the window must show.
struct Case {
    name: &'static str,
    made: &'static [(Id, Id, OpenerKind)],
    shown: Option<Id>,
    previous: &'static [Id],
    members: &'static [Id],
    orders: &'static [&'static [Id]],
    pick: Option<Id>,
}

const ROWS: &[Id] = &["a", "b", "n", "c"];
const ABC: &[Id] = &["a", "b", "c"];
const N_FROM_B: &[(Id, Id, OpenerKind)] = &[("n", "b", Task)];
const N_FROM_P: &[(Id, Id, OpenerKind)] = &[("n", "p", Task)];

/// "p" is a pinned layout tile: a member that no sidebar row lists.
const CASES: &[Case] = &[
    Case {
        name: "M2: the opener is a tile no order lists; before, the next row c",
        made: N_FROM_P,
        shown: Some("n"),
        previous: &["a", "b", "n", "c", "p"],
        members: &["a", "b", "c", "p"],
        orders: &[ROWS, ROWS],
        pick: Some("p"),
    },
    Case {
        name: "the opener is listed only in the model's order (a collapsed group): not touched",
        made: N_FROM_B,
        shown: Some("n"),
        previous: ROWS,
        members: ABC,
        orders: &[&["a", "n", "c"], ROWS],
        pick: Some("c"),
    },
    Case {
        name: "S3: no order lists the new workspace yet; before, the neighbor c",
        made: N_FROM_B,
        shown: Some("n"),
        previous: &["a", "b", "c", "n"],
        members: ABC,
        orders: &[ABC, ABC],
        pick: Some("b"),
    },
    Case {
        name: "S3 with no order at all",
        made: N_FROM_B,
        shown: Some("n"),
        previous: &["a", "b", "c", "n"],
        members: ABC,
        orders: &[],
        pick: Some("b"),
    },
    Case {
        name: "M2 and S3: a tile opener and no order lists the new workspace",
        made: N_FROM_P,
        shown: Some("n"),
        previous: &["p", "a", "b", "c", "n"],
        members: &["p", "a", "b", "c"],
        orders: &[ABC, ABC],
        pick: Some("p"),
    },
    Case {
        name: "a relation is held, the closed row has none: a tile is not picked",
        made: N_FROM_B,
        shown: Some("c"),
        previous: &["a", "b", "n", "c", "p"],
        members: &["a", "b", "n", "p"],
        orders: &[ROWS, ROWS],
        pick: Some("n"),
    },
    Case {
        name: "the quick look-up at the end",
        made: &[("n", "a", Quick)],
        shown: Some("n"),
        previous: &["a", "b", "c", "n"],
        members: ABC,
        orders: &[&["a", "b", "c", "n"]],
        pick: Some("a"),
    },
    Case {
        name: "no relation at all: the next row",
        made: &[],
        shown: Some("b"),
        previous: ABC,
        members: &["a", "c"],
        orders: &[ABC],
        pick: Some("c"),
    },
    Case {
        name: "no relation at all, a tile and a row no order lists: by position",
        made: &[],
        shown: Some("n"),
        previous: &["p", "a", "b", "c", "n"],
        members: &["p", "a", "b", "c"],
        orders: &[ABC, ABC],
        pick: Some("c"),
    },
    Case {
        name: "the shown workspace survives: it stays",
        made: N_FROM_B,
        shown: Some("n"),
        previous: ROWS,
        members: &["a", "n", "c"],
        orders: &[ROWS],
        pick: Some("n"),
    },
    Case {
        name: "nothing was shown: the first member",
        made: N_FROM_B,
        shown: None,
        previous: ROWS,
        members: ABC,
        orders: &[ROWS],
        pick: Some("a"),
    },
    Case {
        name: "no member is left",
        made: N_FROM_B,
        shown: Some("n"),
        previous: ROWS,
        members: &[],
        orders: &[ROWS],
        pick: None,
    },
];

fn rule_of(case: &Case) -> Rule {
    let mut rule = Rule::new();
    for &(new, old, kind) in case.made {
        make(&mut rule, new, old, kind);
    }
    rule
}

fn orders_of(case: &Case) -> Vec<Vec<Id>> {
    case.orders.iter().map(|order| order.to_vec()).collect()
}

/// One module name in each test file of this change, so one test-name
/// filter (`window_close_selection::`) runs them all.
mod window_close_selection {
    use super::*;

    /// The pick with the raw inputs gives the wanted workspace: the window's
    /// rule needs no preparation by its caller (M2, S3).
    #[test]
    fn the_pick_needs_no_prepared_orders() {
        for case in CASES {
            let rule = rule_of(case);
            let picked = pick(&rule, case.shown, case.previous, case.members, &orders_of(case));
            assert_eq!(picked, case.pick, "{}", case.name);
        }
    }

    /// The pick with the raw inputs equals `Openers::successor_in_orders` (the
    /// function the app called before the move, unchanged) with the orders the
    /// app prepared for it.
    #[test]
    fn the_pick_with_raw_inputs_equals_the_old_function_with_the_prepared_inputs() {
        for case in CASES {
            let rule = rule_of(case);
            let raw = orders_of(case);
            let prepared = swift_prepared(&rule, case.shown, case.previous, case.members, &raw);
            let group: HashMap<Id, u32> = HashMap::new();
            let old = rule.openers().successor_in_orders(
                case.shown.as_ref(),
                case.previous,
                case.members,
                &prepared,
                &group,
            );
            assert_eq!(old, case.pick, "the old function, prepared inputs: {}", case.name);
            let new = pick(&rule, case.shown, case.previous, case.members, &raw);
            assert_eq!(new, old, "{}", case.name);
        }
    }

    /// The old function keeps its result for today's inputs: with the raw
    /// orders it picks neither an opener no row lists, nor the opener of a
    /// workspace no row lists (the app at feat still prepares its inputs).
    #[test]
    fn the_old_function_is_not_changed() {
        let group: HashMap<Id, u32> = HashMap::new();
        let unprepared =
            |case: &&Case| case.name.starts_with("M2:") || case.name.starts_with("S3:");
        for case in CASES.iter().filter(unprepared) {
            let rule = rule_of(case);
            let old = rule.openers().successor_in_orders(
                case.shown.as_ref(),
                case.previous,
                case.members,
                &orders_of(case),
                &group,
            );
            assert_eq!(old, Some("c"), "{}", case.name);
        }
    }

    // A close of several rows in one gesture: the same pick as a close of one.

    /// a b c d n*, "n" made from "b", Close Below on "c" closes "d" and "n":
    /// the window shows "b", the opener of the selected workspace (Chrome 156
    /// as observed). Before the move the Swift class picked by position, with
    /// no opener rank: "c" (Swift: aCloseOfSeveralRowsHasNoOpenerRank).
    #[test]
    fn a_close_of_several_rows_picks_the_opener_of_the_shown_workspace() {
        let mut rule = Rule::new();
        let rows = ["a", "b", "c", "d", "n"];
        make(&mut rule, "n", "b", Task);
        assert_eq!(batch_pick(&rule, "n", &rows, &["a", "b", "c"]), Some("b"));
        // One row: the same answer.
        let one = pick(&rule, Some("n"), &rows, &["a", "b", "c", "d"], &[rows.to_vec()]);
        assert_eq!(one, Some("b"));
    }

    /// An opener that closes in the same gesture is no candidate: the next
    /// rank decides, by place among the survivors. a b c d n*, "n" made from
    /// "b", "b" and "n" close: "n" was the last row, so the row above it, "d".
    #[test]
    fn an_opener_that_closes_in_the_same_gesture_is_not_picked() {
        let mut rule = Rule::new();
        let rows = ["a", "b", "c", "d", "n"];
        make(&mut rule, "n", "b", Task);
        assert_eq!(batch_pick(&rule, "n", &rows, &["a", "c", "d"]), Some("d"));
        // In the middle: the next surviving row below.
        let middle = ["a", "b", "n", "c", "d"];
        assert_eq!(batch_pick(&rule, "n", &middle, &["a", "d"]), Some("d"));
    }

    /// Close Others on the shown workspace keeps it (R0), and a close of
    /// several rows with no relation is by position.
    #[test]
    fn a_close_of_several_rows_keeps_a_surviving_selection_and_is_positional_with_no_relation() {
        let mut rule = Rule::new();
        let rows = ["a", "b", "n", "c", "d"];
        assert_eq!(batch_pick(&rule, "b", &rows, &["a", "d"]), Some("d"));
        assert_eq!(batch_pick(&rule, "d", &rows, &["a", "b"]), Some("b"));
        make(&mut rule, "n", "b", Task);
        assert_eq!(batch_pick(&rule, "n", &rows, &["n"]), Some("n"));
        assert_eq!(kept(Some(&"n"), &["n"], &[]), Some("n"));
    }
}
