//! The focus keys' rule: one test for each case of the tiled rule and of the rule with floating panes, and a
//! property test that walks the keys over 2000 layouts from a fixed seed.
//!
//! A screen is written by names. The `order` of a pane is the place of its name among the names in their order as
//! text, so 2 panes that are equal in each other way come out by name.

use super::FocusDirection::{Down, Left, Right, Up};
use super::*;
use std::collections::BTreeSet;

fn frame(x: f64, y: f64, w: f64, h: f64) -> Option<FocusFrame> {
    Some(FocusFrame { x, y, w, h })
}

fn place(index: usize) -> Option<u32> {
    Some(u32::try_from(index).expect("a small index"))
}

struct Screen {
    names: Vec<String>,
    panes: Vec<FocusPane>,
}

fn screen(frames: &[(&str, Option<FocusFrame>)]) -> Screen {
    let mut sorted = frames.iter().map(|(name, _)| *name).collect::<Vec<_>>();
    sorted.sort_unstable();
    let panes = frames
        .iter()
        .map(|(name, frame)| FocusPane {
            frame: *frame,
            column: None,
            recency: None,
            floating: None,
            order: place(sorted.iter().position(|other| other == name).expect("the name"))
                .expect("a place"),
        })
        .collect();
    Screen { names: frames.iter().map(|(name, _)| (*name).to_owned()).collect(), panes }
}

impl Screen {
    fn index(&self, name: &str) -> Option<usize> {
        self.names.iter().position(|other| other == name)
    }

    /// The focus history, the newest pane first. A name that is no pane of the screen is left out.
    fn history(mut self, newest_first: &[&str]) -> Screen {
        for pane in &mut self.panes {
            pane.recency = None;
        }
        for (at, name) in newest_first.iter().enumerate() {
            if let Some(index) = self.index(name)
                && self.panes[index].recency.is_none()
            {
                self.panes[index].recency = place(at);
            }
        }
        self
    }

    /// The floating panes, back to front.
    fn floating(mut self, back_to_front: &[&str]) -> Screen {
        for (at, name) in back_to_front.iter().enumerate() {
            if let Some(index) = self.index(name) {
                self.panes[index].floating = place(at);
            }
        }
        self
    }

    fn columns(mut self, columns: &[&[&str]]) -> Screen {
        for (at, column) in columns.iter().enumerate() {
            for name in *column {
                let index = self.index(name).expect("a pane of the screen");
                self.panes[index].column = place(at);
            }
        }
        self
    }

    /// The name of the pane that the key gives from `from`. A name that is no pane of the screen has no row.
    fn next(&self, from: &str, direction: FocusDirection) -> Option<&str> {
        assert!(is_valid(&self.panes), "the rows are valid");
        let source = self.index(from).unwrap_or(self.panes.len());
        neighbor(&self.panes, source, direction).map(|index| self.names[index].as_str())
    }

    /// [`Self::next`] of a screen whose rows are not valid.
    fn next_of_rows_not_valid(&self, from: &str, direction: FocusDirection) -> Option<&str> {
        assert!(!is_valid(&self.panes), "the rows are not valid");
        let source = self.index(from).unwrap_or(self.panes.len());
        neighbor(&self.panes, source, direction).map(|index| self.names[index].as_str())
    }
}

// The tiled rule.

#[test]
fn directional_focus_steps_through_the_area_then_leaves_it() {
    let strip = screen(&[
        ("p1", frame(0.0, 0.0, 200.0, 800.0)),
        ("p2", frame(200.0, 0.0, 200.0, 800.0)),
        ("p3", frame(400.0, 0.0, 200.0, 800.0)),
        ("q", frame(600.0, 0.0, 600.0, 800.0)),
    ]);
    assert_eq!(strip.next("p1", Right), Some("p2"));
    assert_eq!(strip.next("p2", Right), Some("p3"));
    assert_eq!(
        strip.next("p3", Right),
        Some("q"),
        "right from the last pane of the area leaves it"
    );
    assert_eq!(strip.next("q", Left), Some("p3"), "left into the area gives its nearest pane");
    assert_eq!(strip.next("p2", Left), Some("p1"));
}

#[test]
fn a_pane_with_no_frame_has_no_neighbor_and_the_same_pane_with_its_frame_has_one() {
    let other = screen(&[("chat", None), ("other", frame(0.0, 0.0, 1400.0, 800.0))]);
    assert_eq!(other.next("chat", Right), None, "the frames of another screen give no neighbor");
    assert_eq!(other.next("no row", Right), None, "a source with no row has no neighbor");
    let own = screen(&[
        ("chat", frame(0.0, 0.0, 700.0, 800.0)),
        ("diff", frame(700.0, 0.0, 700.0, 800.0)),
    ]);
    assert_eq!(own.next("chat", Right), Some("diff"));
}

#[test]
fn the_facing_edge_of_the_neighbor_joins_it() {
    let pair =
        screen(&[("p1", frame(0.0, 0.0, 500.0, 600.0)), ("p2", frame(500.0, 0.0, 500.0, 600.0))]);
    assert_eq!(pair.next("p1", Right), Some("p2"));
    assert_eq!(pair.next("p2", Left), Some("p1"));
    assert_eq!(pair.next("p1", Left), None);
}

#[test]
fn other_edges_and_farther_panes_still_split() {
    let row = screen(&[
        ("a", frame(0.0, 0.0, 300.0, 600.0)),
        ("b", frame(300.0, 0.0, 300.0, 600.0)),
        ("c", frame(600.0, 0.0, 300.0, 600.0)),
    ]);
    assert_eq!(row.next("a", Right), Some("b"), "the pane beside the source, not the farther one");
    // A pane to the right of the source that is beside no part of it: the rule gives it by the nearest edge.
    let offset =
        screen(&[("a", frame(0.0, 0.0, 300.0, 300.0)), ("b", frame(300.0, 300.0, 300.0, 300.0))]);
    assert_eq!(offset.next("a", Right), Some("b"));
    assert_eq!(offset.next("a", Down), Some("b"));
}

#[test]
fn the_most_recently_focused_of_two_adjacent_panes_gets_the_focus() {
    let three = || {
        screen(&[
            ("left", frame(0.0, 0.0, 600.0, 800.0)),
            ("right", frame(600.0, 0.0, 600.0, 500.0)),
            ("below", frame(600.0, 500.0, 600.0, 300.0)),
        ])
    };
    assert_eq!(
        three().history(&["left", "below"]).next("left", Right),
        Some("below"),
        "the smaller pane had the focus last"
    );
    assert_eq!(three().history(&["left"]).next("left", Right), Some("right"));
    assert_eq!(three().next("left", Right), Some("right"), "with no history the larger overlap");
    assert_eq!(three().history(&["left", "right", "below"]).next("left", Right), Some("right"));
}

#[test]
fn with_no_history_the_largest_overlap_then_the_nearest_centre_then_the_top_left_pane_wins() {
    let overlap = screen(&[
        ("s", frame(0.0, 0.0, 300.0, 900.0)),
        ("big", frame(300.0, 0.0, 300.0, 500.0)),
        ("small", frame(300.0, 500.0, 300.0, 400.0)),
    ]);
    assert_eq!(overlap.next("s", Right), Some("big"));
    let centre = screen(&[
        ("s", frame(0.0, 300.0, 300.0, 300.0)),
        ("top", frame(300.0, 0.0, 300.0, 400.0)),
        ("mid", frame(300.0, 400.0, 300.0, 100.0)),
        ("low", frame(300.0, 500.0, 300.0, 400.0)),
    ]);
    assert_eq!(centre.next("s", Right), Some("mid"), "3 equal overlaps: the nearest centre");
    let top = screen(&[
        ("s", frame(0.0, 300.0, 300.0, 300.0)),
        ("top", frame(300.0, 150.0, 300.0, 300.0)),
        ("low", frame(300.0, 450.0, 300.0, 300.0)),
    ]);
    assert_eq!(top.next("s", Right), Some("top"), "equal overlaps and centres: the top one");
    let left = screen(&[
        ("s", frame(300.0, 0.0, 300.0, 300.0)),
        ("left", frame(150.0, 300.0, 300.0, 300.0)),
        ("right", frame(450.0, 300.0, 300.0, 300.0)),
    ]);
    assert_eq!(left.next("s", Down), Some("left"), "equal overlaps and centres: the left one");
    let order = screen(&[
        ("s", frame(0.0, 0.0, 300.0, 600.0)),
        ("y", frame(300.0, 0.0, 200.0, 600.0)),
        ("x", frame(300.0, 0.0, 100.0, 600.0)),
    ]);
    assert_eq!(order.next("s", Right), Some("x"), "equal in each way: the order of the rows");
    // The overlap and the distance between the centres are compared as whole numbers: 299.6 and 300.4 are
    // equal, and 150.2 and 149.8 are equal, so the top pane wins. Not rounded, `b` has the larger overlap and
    // the nearer centre.
    let rounded = screen(&[
        ("s", frame(0.0, 0.0, 300.0, 600.0)),
        ("a", frame(300.0, 0.0, 300.0, 299.6)),
        ("b", frame(300.0, 299.6, 300.0, 300.4)),
    ]);
    assert_eq!(rounded.next("s", Right), Some("a"));
}

#[test]
fn a_pane_within_the_edge_tolerance_is_a_candidate_and_one_past_it_is_not() {
    let beside = |x: f64| {
        screen(&[("s", frame(0.0, 0.0, 300.0, 600.0)), ("n", frame(x, 0.0, 300.0, 600.0))])
    };
    assert_eq!(beside(298.5).next("s", Right), Some("n"));
    assert_eq!(beside(298.5).next("n", Left), Some("s"));
    assert_eq!(beside(298.4).next("s", Right), None);
    assert_eq!(beside(298.4).next("n", Left), None);
    let below = |y: f64| {
        screen(&[("s", frame(0.0, 0.0, 300.0, 300.0)), ("n", frame(0.0, y, 300.0, 300.0))])
    };
    assert_eq!(below(298.5).next("s", Down), Some("n"));
    assert_eq!(below(298.5).next("n", Up), Some("s"));
    assert_eq!(below(298.4).next("s", Down), None);
    assert_eq!(below(298.4).next("n", Up), None);
}

#[test]
fn the_adjacent_panes_are_the_ones_within_the_tolerance_of_the_nearest() {
    let second = |x: f64| {
        screen(&[
            ("s", frame(0.0, 0.0, 300.0, 600.0)),
            ("near", frame(300.0, 0.0, 300.0, 200.0)),
            ("second", frame(x, 200.0, 300.0, 400.0)),
        ])
    };
    assert_eq!(second(301.5).next("s", Right), Some("second"), "adjacent too: the larger overlap");
    assert_eq!(second(301.6).next("s", Right), Some("near"), "not adjacent: the nearest");
    let farther = screen(&[
        ("s", frame(0.0, 0.0, 300.0, 600.0)),
        ("near", frame(300.0, 0.0, 300.0, 100.0)),
        ("far", frame(600.0, 0.0, 300.0, 600.0)),
    ])
    .history(&["far"]);
    assert_eq!(
        farther.next("s", Right),
        Some("near"),
        "the history counts among adjacent panes only"
    );
}

#[test]
fn with_no_overlapping_pane_the_nearest_edge_then_the_nearest_centre_wins() {
    let edge = || {
        screen(&[
            ("s", frame(0.0, 0.0, 300.0, 300.0)),
            ("near", frame(310.0, 400.0, 300.0, 300.0)),
            ("far", frame(400.0, 300.0, 300.0, 300.0)),
        ])
    };
    assert_eq!(edge().next("s", Right), Some("near"));
    assert_eq!(edge().history(&["far"]).next("s", Right), Some("near"), "no history in this case");
    let centre = |up_height: f64, down_y: f64| {
        screen(&[
            ("s", frame(0.0, 300.0, 300.0, 300.0)),
            ("up", frame(300.0, 0.0, 300.0, up_height)),
            ("down", frame(300.0, down_y, 300.0, 300.0)),
        ])
    };
    assert_eq!(centre(290.0, 610.0).next("s", Right), Some("up"), "the nearest centre");
    assert_eq!(centre(299.8, 600.0).next("s", Right), Some("down"), "the centres are not rounded");
    assert_eq!(centre(300.0, 600.0).next("s", Right), Some("up"), "equal centres: the top one");
    // The distance is compared as a whole number: 0.4 and 0 are equal, so the nearer centre wins. Not rounded,
    // `b` has the nearer edge.
    let rounded = screen(&[
        ("s", frame(0.0, 0.0, 300.0, 300.0)),
        ("a", frame(300.4, 300.0, 300.0, 300.0)),
        ("b", frame(300.0, 600.0, 300.0, 300.0)),
    ]);
    assert_eq!(rounded.next("s", Right), Some("a"));
}

#[test]
fn a_key_into_another_column_gives_the_pane_that_the_column_remembers() {
    let strip = || {
        screen(&[
            ("a", frame(0.0, 0.0, 400.0, 900.0)),
            ("b1", frame(400.0, 0.0, 400.0, 300.0)),
            ("b2", frame(400.0, 300.0, 400.0, 300.0)),
            ("b3", frame(400.0, 600.0, 400.0, 300.0)),
            ("c", frame(800.0, 0.0, 400.0, 900.0)),
        ])
        .columns(&[&["a"], &["b1", "b2", "b3"], &["c"]])
    };
    assert_eq!(strip().history(&["a", "b3"]).next("a", Right), Some("b3"));
    assert_eq!(strip().history(&["c", "b3", "b1"]).next("c", Left), Some("b3"));
    assert_eq!(strip().history(&["a"]).next("a", Right), Some("b2"), "a column with no history");
    assert_eq!(strip().next("a", Right), Some("b2"));
    assert_eq!(
        strip().history(&["b1", "b3"]).next("b1", Down),
        Some("b2"),
        "up and down: no column"
    );
    assert_eq!(strip().history(&["b3", "b1"]).next("b3", Up), Some("b2"));
    assert_eq!(strip().history(&["b2", "c"]).next("b2", Right), Some("c"));
    assert_eq!(strip().history(&["b1"]).next("b1", Left), Some("a"));
}

#[test]
fn a_column_remembers_a_pane_that_is_not_beside_the_source_and_one_that_has_no_frame() {
    let apart = screen(&[
        ("a", frame(0.0, 0.0, 400.0, 300.0)),
        ("d", frame(0.0, 300.0, 400.0, 600.0)),
        ("b1", frame(400.0, 0.0, 400.0, 300.0)),
        ("b2", frame(400.0, 300.0, 400.0, 600.0)),
    ])
    .columns(&[&["a", "d"], &["b1", "b2"]])
    .history(&["a", "b2"]);
    assert_eq!(apart.next("a", Right), Some("b2"), "the pane beside the source is b1");
    assert_eq!(apart.next("a", Down), Some("d"));
    let own = screen(&[
        ("a", frame(0.0, 0.0, 300.0, 450.0)),
        ("b", frame(300.0, 0.0, 300.0, 450.0)),
        ("c", frame(0.0, 450.0, 600.0, 450.0)),
    ])
    .columns(&[&["a", "b", "c"]])
    .history(&["a", "c", "b"]);
    assert_eq!(own.next("a", Right), Some("b"), "a move in the source's own column");
    let hidden = screen(&[
        ("a", frame(0.0, 0.0, 400.0, 900.0)),
        ("b1", frame(400.0, 0.0, 400.0, 900.0)),
        ("hidden", None),
    ])
    .columns(&[&["a"], &["b1", "hidden"]])
    .history(&["a", "hidden", "b1"]);
    assert_eq!(hidden.next("a", Right), Some("hidden"));
}

#[test]
fn a_screen_of_one_pane_has_no_neighbor_and_rows_that_are_not_valid_are_known() {
    let only = screen(&[("only", frame(0.0, 0.0, 1200.0, 900.0))]);
    for direction in [Left, Right, Up, Down] {
        assert_eq!(only.next("only", direction), None);
    }
    let pane = |order: u32| FocusPane {
        frame: frame(0.0, 0.0, 10.0, 10.0),
        column: None,
        recency: None,
        floating: None,
        order,
    };
    assert!(is_valid(&[]));
    assert!(is_valid(&[pane(0), pane(1)]));
    assert!(!is_valid(&[pane(1), pane(1)]), "2 panes with one order");
    assert!(!is_valid(&[
        FocusPane { recency: Some(0), ..pane(0) },
        FocusPane { recency: Some(0), ..pane(1) }
    ]));
    assert!(!is_valid(&[
        FocusPane { floating: Some(2), ..pane(0) },
        FocusPane { floating: Some(2), ..pane(1) }
    ]));
    assert!(!is_valid(&[FocusPane { frame: frame(0.0, 0.0, -1.0, 10.0), ..pane(0) }]));
    assert!(!is_valid(&[FocusPane { frame: frame(f64::NAN, 0.0, 1.0, 10.0), ..pane(0) }]));
    assert!(!is_valid(&[FocusPane { frame: frame(0.0, 0.0, 1.0, f64::INFINITY), ..pane(0) }]));
    assert!(is_valid(&[FocusPane { frame: None, ..pane(0) }]));
    for (code, direction, back) in
        [(0, Left, Right), (1, Right, Left), (2, Up, Down), (3, Down, Up)]
    {
        assert_eq!(FocusDirection::from_code(code), Some(direction));
        assert_eq!(direction.opposite(), back);
        assert_eq!(direction.opposite().is_horizontal(), direction.is_horizontal());
    }
    assert_eq!(FocusDirection::from_code(4), None);
}

#[test]
fn a_pane_whose_frame_is_not_valid_is_as_a_pane_with_no_frame() {
    // Each frame is one that `is_valid` refuses: not a number, not finite, a negative size.
    for bad in [
        frame(f64::NAN, 25.0, 50.0, 50.0),
        frame(100.0, 25.0, f64::INFINITY, 50.0),
        frame(100.0, 25.0, -50.0, 50.0),
    ] {
        // On the way of `s` to the right, before `f` in the list of the floating panes.
        let floating = screen(&[
            ("s", frame(0.0, 0.0, 100.0, 100.0)),
            ("bad", bad),
            ("f", frame(250.0, 25.0, 100.0, 50.0)),
        ])
        .floating(&["bad", "f"])
        .history(&["s"]);
        assert_eq!(floating.next_of_rows_not_valid("s", Right), Some("f"), "{bad:?} is no stop");
        // Beside `s` as `t` is, and before `t` in the order of the rows.
        let tiled = screen(&[
            ("s", frame(0.0, 0.0, 100.0, 100.0)),
            ("bad", bad.map(|frame| FocusFrame { y: 0.0, h: 100.0, ..frame })),
            ("t", frame(100.0, 0.0, 100.0, 100.0)),
        ]);
        assert_eq!(tiled.next_of_rows_not_valid("s", Right), Some("t"), "{bad:?} is no candidate");
        for direction in [Left, Right, Up, Down] {
            assert_eq!(
                floating.next_of_rows_not_valid("bad", direction),
                None,
                "{bad:?} as a source"
            );
            assert_eq!(tiled.next_of_rows_not_valid("bad", direction), None, "{bad:?} as a source");
        }
        // With no floating pane, its column can remember it, as a pane with no frame.
        let remembered = screen(&[
            ("a", frame(0.0, 0.0, 400.0, 900.0)),
            ("b1", frame(400.0, 0.0, 400.0, 900.0)),
            ("bad", bad),
        ])
        .columns(&[&["a"], &["b1", "bad"]])
        .history(&["a", "bad", "b1"]);
        assert_eq!(remembered.next_of_rows_not_valid("a", Right), Some("bad"));
    }
}

// The rule with floating panes.

fn two_tiled_and_one_floating() -> Screen {
    screen(&[
        ("a", frame(0.0, 0.0, 600.0, 900.0)),
        ("b", frame(600.0, 0.0, 600.0, 900.0)),
        ("f", frame(450.0, 300.0, 300.0, 300.0)),
    ])
    .floating(&["f"])
}

fn three_tiled_and_a_cover() -> Screen {
    screen(&[
        ("a", frame(0.0, 0.0, 400.0, 900.0)),
        ("b", frame(400.0, 0.0, 400.0, 900.0)),
        ("c", frame(800.0, 0.0, 400.0, 900.0)),
        ("f", frame(390.0, 0.0, 420.0, 900.0)),
    ])
    .floating(&["f"])
}

#[test]
fn a_key_reaches_a_floating_pane_between_two_tiled_panes_and_leaves_it() {
    let shown = two_tiled_and_one_floating;
    assert_eq!(shown().history(&["a"]).next("a", Right), Some("f"));
    assert_eq!(
        shown().history(&["f", "a"]).next("f", Right),
        Some("b"),
        "the same key goes on to the tiled target"
    );
    assert_eq!(
        shown().history(&["f", "a"]).next("f", Left),
        Some("a"),
        "the opposite key goes back"
    );
    assert_eq!(shown().history(&["b", "f", "a"]).next("b", Left), Some("f"));
    assert_eq!(shown().history(&["f", "b", "a"]).next("f", Left), Some("a"));
    assert_eq!(shown().history(&["a"]).next("a", Left), None);
    // With no floating pane the tiled rule is the whole rule.
    let tiled =
        screen(&[("a", frame(0.0, 0.0, 600.0, 900.0)), ("b", frame(600.0, 0.0, 600.0, 900.0))]);
    assert_eq!(tiled.history(&["a"]).next("a", Right), Some("b"));
    let no_frame = screen(&[
        ("a", frame(0.0, 0.0, 600.0, 900.0)),
        ("b", frame(600.0, 0.0, 600.0, 900.0)),
        ("f", None),
    ])
    .floating(&["f"])
    .history(&["a"]);
    assert_eq!(no_frame.next("a", Right), Some("b"), "a floating pane with no frame is not there");
}

#[test]
fn a_tiled_pane_that_a_floating_pane_covers_wholly_never_gets_the_focus() {
    let shown = three_tiled_and_a_cover;
    assert_eq!(shown().history(&["a"]).next("a", Right), Some("f"));
    assert_eq!(shown().history(&["f", "a"]).next("f", Right), Some("c"), "not the covered pane");
    assert_eq!(shown().history(&["c", "f", "a"]).next("c", Left), Some("f"));
    assert_eq!(shown().history(&["f", "c", "a"]).next("f", Left), Some("a"));
    assert_eq!(shown().history(&["f", "a"]).next("f", Left), Some("a"));
}

#[test]
fn two_floating_panes_in_a_row_are_two_stops() {
    let shown = || {
        screen(&[
            ("a", frame(0.0, 0.0, 600.0, 900.0)),
            ("b", frame(600.0, 0.0, 600.0, 900.0)),
            ("f", frame(300.0, 300.0, 200.0, 200.0)),
            ("g", frame(520.0, 300.0, 200.0, 200.0)),
        ])
        .floating(&["f", "g"])
    };
    assert_eq!(shown().history(&["a"]).next("a", Right), Some("f"));
    assert_eq!(shown().history(&["f", "a"]).next("f", Right), Some("g"));
    assert_eq!(shown().history(&["g", "f", "a"]).next("g", Right), Some("b"));
    assert_eq!(shown().history(&["g", "f", "a"]).next("g", Left), Some("f"));
}

#[test]
fn from_a_tiled_pane_with_no_tiled_target_the_nearest_floating_pane_after_it_gets_the_focus() {
    // No floating pane lies wholly past the right edge of `a` and none is beside it: the centres give the order.
    let shown = screen(&[
        ("a", frame(0.0, 0.0, 600.0, 400.0)),
        ("b", frame(0.0, 400.0, 600.0, 500.0)),
        ("f", frame(500.0, 500.0, 300.0, 300.0)),
        ("g", frame(700.0, 600.0, 200.0, 200.0)),
    ])
    .floating(&["g", "f"])
    .history(&["a"]);
    assert_eq!(shown.next("a", Right), Some("f"));
    assert_eq!(shown.next("a", Left), None);
}

#[test]
fn from_a_floating_pane_with_no_tiled_pane_in_the_history_the_nearest_pane_after_it_gets_the_focus()
{
    let shown = two_tiled_and_one_floating;
    assert_eq!(shown().history(&["f"]).next("f", Right), Some("b"));
    assert_eq!(shown().history(&["f"]).next("f", Left), Some("a"));
    assert_eq!(shown().next("f", Right), Some("b"), "no history");
    // The 2 tiled panes have the centre of `f` on the other axis: a tiled pane is before a floating pane there.
    assert_eq!(shown().history(&["f"]).next("f", Up), Some("a"));
    assert_eq!(shown().history(&["f"]).next("f", Down), None);
}

#[test]
fn from_a_floating_pane_a_key_of_another_way_gives_the_nearest_pane_and_one_beside_it_first() {
    // `f` is on no way of `z`, the tiled pane before it. Down: `n` has the nearest centre and is not below `f`;
    // `q` is below it.
    let shown = screen(&[
        ("a", frame(0.0, 0.0, 1200.0, 300.0)),
        ("n", frame(0.0, 300.0, 700.0, 100.0)),
        ("m", frame(0.0, 400.0, 700.0, 200.0)),
        ("q", frame(700.0, 300.0, 500.0, 300.0)),
        ("z", frame(0.0, 600.0, 1200.0, 300.0)),
        ("f", frame(750.0, 50.0, 300.0, 300.0)),
    ])
    .floating(&["f"])
    .history(&["f", "z"]);
    assert_eq!(shown.next("f", Down), Some("q"));
    assert_eq!(shown.next("f", Left), Some("a"));
}

#[test]
fn two_panes_with_one_centre_are_in_one_order_the_tiled_one_then_the_floating_ones_back_to_front() {
    let shown = || {
        screen(&[
            ("a", frame(0.0, 0.0, 600.0, 900.0)),
            ("b", frame(600.0, 0.0, 600.0, 900.0)),
            ("f", frame(150.0, 300.0, 300.0, 300.0)),
            ("g", frame(150.0, 300.0, 300.0, 300.0)),
        ])
        .floating(&["f", "g"])
    };
    assert_eq!(shown().history(&["a"]).next("a", Right), Some("f"));
    assert_eq!(shown().history(&["a"]).next("a", Down), Some("f"));
    assert_eq!(shown().history(&["a"]).next("a", Left), None);
    assert_eq!(shown().history(&["a"]).next("a", Up), None);
    assert_eq!(shown().history(&["f", "a"]).next("f", Right), Some("g"));
    assert_eq!(shown().history(&["g", "f", "a"]).next("g", Right), Some("b"));
    assert_eq!(shown().history(&["g", "f", "a"]).next("g", Left), Some("f"));
    assert_eq!(shown().history(&["f", "a"]).next("f", Left), Some("a"));
}

#[test]
fn a_tiled_pane_that_a_floating_pane_covers_wholly_is_still_a_source() {
    let shown = three_tiled_and_a_cover().history(&["b"]);
    assert_eq!(shown.next("b", Right), Some("f"));
    assert_eq!(shown.next("b", Left), Some("a"));
    assert_eq!(shown.next("b", Down), Some("f"));
}

#[test]
fn with_columns_the_same_key_goes_on_to_the_pane_that_the_column_remembers_if_it_shows() {
    let shown = || {
        screen(&[
            ("a", frame(0.0, 0.0, 600.0, 900.0)),
            ("b1", frame(600.0, 0.0, 600.0, 450.0)),
            ("b2", frame(600.0, 450.0, 600.0, 450.0)),
            ("f", frame(450.0, 100.0, 300.0, 200.0)),
        ])
        .columns(&[&["a"], &["b1", "b2"]])
        .floating(&["f"])
    };
    assert_eq!(shown().history(&["a", "b2", "b1"]).next("a", Right), Some("f"));
    assert_eq!(
        shown().history(&["f", "a", "b2", "b1"]).next("f", Right),
        Some("b2"),
        "the pane beside `f` is b1"
    );
    assert_eq!(shown().history(&["f", "a", "b2", "b1"]).next("f", Left), Some("a"));
    // The pane that the column remembers is covered wholly: the column gives its next one.
    let covered = screen(&[
        ("a", frame(0.0, 0.0, 600.0, 900.0)),
        ("b1", frame(600.0, 0.0, 600.0, 450.0)),
        ("b2", frame(600.0, 450.0, 600.0, 450.0)),
        ("h", frame(590.0, 440.0, 620.0, 470.0)),
    ])
    .columns(&[&["a"], &["b1", "b2"]])
    .floating(&["h"])
    .history(&["a", "b2", "b1"]);
    assert_eq!(covered.next("a", Right), Some("b1"));
}

#[test]
fn a_long_focus_history_gives_the_newest_tiled_pane_that_shows_as_the_pane_before() {
    let shown = three_tiled_and_a_cover;
    // `b` is covered wholly, so the pane before `f` is `c`.
    assert_eq!(shown().history(&["f", "b", "c", "a"]).next("f", Right), Some("c"));
    assert_eq!(shown().history(&["f", "b", "c", "a"]).next("f", Left), Some("a"));
    // The pane before `f` is `a`.
    assert_eq!(shown().history(&["f", "b", "a", "c"]).next("f", Right), Some("c"));
    assert_eq!(shown().history(&["f", "b", "a", "c"]).next("f", Left), Some("a"));
}

#[test]
fn a_floating_pane_with_its_corner_out_of_the_area_is_a_stop_as_each_other_one() {
    let shown = || {
        screen(&[
            ("a", frame(0.0, 0.0, 600.0, 900.0)),
            ("b", frame(600.0, 0.0, 600.0, 900.0)),
            ("f", frame(-100.0, -50.0, 300.0, 300.0)),
        ])
        .floating(&["f"])
    };
    assert_eq!(shown().history(&["a"]).next("a", Left), Some("f"));
    assert_eq!(shown().history(&["a"]).next("a", Up), Some("f"));
    assert_eq!(shown().history(&["a"]).next("a", Right), Some("b"));
    assert_eq!(shown().history(&["a"]).next("a", Down), None);
    assert_eq!(
        shown().history(&["f", "a"]).next("f", Right),
        Some("a"),
        "the opposite key goes back"
    );
    assert_eq!(shown().history(&["f", "a"]).next("f", Down), Some("a"));
    assert_eq!(shown().history(&["f", "a"]).next("f", Left), None);
    assert_eq!(shown().history(&["f", "a"]).next("f", Up), None);
    assert_eq!(shown().history(&["b", "a"]).next("b", Left), Some("a"), "`f` is not between the 2");
}

#[test]
fn with_a_floating_pane_a_column_gives_no_pane_that_has_no_frame() {
    let tiled = screen(&[
        ("a", frame(0.0, 0.0, 400.0, 900.0)),
        ("b1", frame(400.0, 0.0, 400.0, 900.0)),
        ("hidden", None),
    ])
    .columns(&[&["a"], &["b1", "hidden"]])
    .history(&["a", "hidden", "b1"]);
    assert_eq!(tiled.next("a", Right), Some("hidden"), "no floating pane: the tiled rule");
    // The same screen with one floating pane that is on no way of the key.
    let shown = screen(&[
        ("a", frame(0.0, 0.0, 400.0, 900.0)),
        ("b1", frame(400.0, 0.0, 400.0, 900.0)),
        ("hidden", None),
        ("f", frame(50.0, 700.0, 100.0, 100.0)),
    ])
    .columns(&[&["a"], &["b1", "hidden"]])
    .floating(&["f"])
    .history(&["a", "hidden", "b1"]);
    assert_eq!(shown.next("a", Right), Some("b1"), "a column remembers only its panes that show");
}

/// A tiled pane `s` with no tiled pane on its right, and 23 floating panes beside it: `far` at the centre 500,
/// `nan` (its x is not a number), `f02` at the centre 300 and `f03` to `f22` at the centres 331 to 464, back to
/// front in that order. The screen, and the stops of the key right from `s`.
fn a_way_with_a_frame_that_is_not_a_number(reversed: bool) -> (Screen, Vec<String>) {
    let stop = |centre: f64| frame(centre - 25.0, 25.0, 50.0, 50.0);
    let mut rows = vec![
        ("s".to_owned(), frame(0.0, 0.0, 100.0, 100.0)),
        ("far".to_owned(), stop(500.0)),
        ("nan".to_owned(), frame(f64::NAN, 25.0, 50.0, 50.0)),
        ("f02".to_owned(), stop(300.0)),
    ];
    rows.extend((3_u8..=22).map(|at| (format!("f{at:02}"), stop(310.0 + 7.0 * f64::from(at)))));
    let back_to_front = rows.iter().skip(1).map(|(name, _)| name.clone()).collect::<Vec<_>>();
    if reversed {
        rows.reverse();
    }
    let named = rows.iter().map(|(name, frame)| (name.as_str(), *frame)).collect::<Vec<_>>();
    let order = back_to_front.iter().map(String::as_str).collect::<Vec<_>>();
    let shown = screen(&named).floating(&order).history(&["s"]);
    let mut stops = back_to_front.iter().skip(2).cloned().collect::<Vec<_>>();
    stops.push("far".to_owned());
    (shown, stops)
}

/// The panes that `count` presses of the key give from `from`, to the first press that gives none.
fn presses(shown: &Screen, from: &str, direction: FocusDirection, count: usize) -> Vec<String> {
    let mut at = from.to_owned();
    let mut reached = Vec::new();
    for _ in 0..count {
        let Some(next) = shown.next_of_rows_not_valid(&at, direction) else { break };
        at = next.to_owned();
        reached.push(at.clone());
    }
    reached
}

#[test]
fn a_way_of_22_floating_panes_and_a_frame_that_is_not_a_number_has_one_order() {
    for reversed in [false, true] {
        let (shown, stops) = a_way_with_a_frame_that_is_not_a_number(reversed);
        assert_eq!(stops.len(), 22);
        assert_eq!(
            presses(&shown, "s", Right, stops.len() + 1),
            stops,
            "the key right gives each floating pane with a valid frame by its centre, then no pane \
             (rows in the other order: {reversed})"
        );
        let mut back = stops.iter().rev().skip(1).cloned().collect::<Vec<_>>();
        back.push("s".to_owned());
        assert_eq!(
            presses(&shown, "far", Left, stops.len()),
            back,
            "the key left goes back the same way (rows in the other order: {reversed})"
        );
        for direction in [Left, Right, Up, Down] {
            assert_eq!(shown.next_of_rows_not_valid("nan", direction), None, "never a source");
        }
    }
}

// The property test: grids of 1 to 4 columns and 1 to 3 rows with 1 to 3 floating panes, from a fixed seed. It
// makes no docked column and no strip of columns, and its focus history has 2 entries.

struct Generator {
    state: u64,
}

impl Generator {
    fn below(&mut self, bound: u64) -> u64 {
        self.state = self
            .state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.state >> 33) % bound
    }

    fn unit(&mut self) -> f64 {
        self.below(10_001) as f64 / 10_000.0
    }
}

struct Layout {
    frames: Vec<(String, FocusFrame)>,
    tiled: Vec<String>,
    floating: Vec<String>,
}

fn covers(cover: FocusFrame, inner: FocusFrame) -> bool {
    cover.x <= inner.x
        && cover.y <= inner.y
        && cover.x + cover.w >= inner.x + inner.w
        && cover.y + cover.h >= inner.y + inner.h
}

impl Layout {
    fn frame(&self, name: &str) -> FocusFrame {
        self.frames.iter().find(|(other, _)| other == name).expect("a pane of the layout").1
    }

    fn make(generator: &mut Generator, allows_cover: bool) -> Layout {
        let (width, height) = (1200.0, 900.0);
        let columns = 1 + generator.below(4);
        let rows = 1 + generator.below(3);
        let mut layout = Layout { frames: Vec::new(), tiled: Vec::new(), floating: Vec::new() };
        for column in 0..columns {
            for row in 0..rows {
                let name = format!("t{column}{row}");
                layout.tiled.push(name.clone());
                layout.frames.push((
                    name,
                    FocusFrame {
                        x: column as f64 * width / columns as f64,
                        y: row as f64 * height / rows as f64,
                        w: width / columns as f64,
                        h: height / rows as f64,
                    },
                ));
            }
        }
        for index in 0..(1 + generator.below(3)) {
            let w = (0.15 + generator.unit() * 0.6) * width;
            let h = (0.15 + generator.unit() * 0.6) * height;
            let x = generator.unit() * (width - w);
            let y = generator.unit() * (height - h);
            let frame = FocusFrame { x, y, w, h };
            if !allows_cover && layout.tiled.iter().any(|pane| covers(frame, layout.frame(pane))) {
                continue;
            }
            let name = format!("f{index}");
            layout.frames.push((name.clone(), frame));
            layout.floating.push(name);
        }
        layout
    }

    /// The pane that the key gives from `focus` when `origin` is the tiled pane that had the focus before it.
    fn next(&self, focus: &str, origin: &str, direction: FocusDirection) -> Option<String> {
        let frames = self
            .frames
            .iter()
            .map(|(name, frame)| (name.as_str(), Some(*frame)))
            .collect::<Vec<_>>();
        let floating = self.floating.iter().map(String::as_str).collect::<Vec<_>>();
        let history = if self.floating.iter().any(|pane| pane == focus) {
            vec![focus, origin]
        } else {
            vec![focus]
        };
        screen(&frames)
            .floating(&floating)
            .history(&history)
            .next(focus, direction)
            .map(str::to_owned)
    }

    /// Each problem of the layout, by a walk over each (focus, tiled pane before it) that the keys can make from
    /// each tiled pane that shows.
    fn problems(&self) -> Vec<String> {
        let floats = |pane: &str| self.floating.iter().any(|other| other == pane);
        let covered = self
            .tiled
            .iter()
            .filter(|pane| {
                self.floating.iter().any(|cover| covers(self.frame(cover), self.frame(pane)))
            })
            .cloned()
            .collect::<BTreeSet<_>>();
        let wanted = self
            .frames
            .iter()
            .map(|(name, _)| name.clone())
            .filter(|name| !covered.contains(name))
            .collect::<BTreeSet<_>>();
        let mut problems = Vec::new();
        for start in self.tiled.iter().filter(|pane| !covered.contains(*pane)) {
            let mut seen = BTreeSet::from([(start.clone(), start.clone())]);
            let mut queue = vec![(start.clone(), start.clone())];
            let mut reached = BTreeSet::from([start.clone()]);
            while let Some((focus, origin)) = queue.pop() {
                for direction in [Left, Right, Up, Down] {
                    let Some(found) = self.next(&focus, &origin, direction) else { continue };
                    if found == focus {
                        problems
                            .push(format!("{focus} {direction:?}: {found} is not another pane"));
                        continue;
                    }
                    if covered.contains(&found) {
                        problems.push(format!("{focus} {direction:?}: {found} does not show"));
                        continue;
                    }
                    reached.insert(found.clone());
                    let before = if !floats(&found) {
                        found.clone()
                    } else if floats(&focus) {
                        origin.clone()
                    } else {
                        focus.clone()
                    };
                    if seen.insert((found.clone(), before.clone())) {
                        queue.push((found, before));
                    }
                }
            }
            if reached != wanted {
                let missed = wanted.difference(&reached).collect::<Vec<_>>();
                problems.push(format!("from {start}: no keys reach {missed:?}"));
            }
        }
        problems
    }
}

/// From each pane each key gives another pane that shows, or nothing; and from each tiled pane that shows, a
/// finite count of keys reaches each floating pane and each other tiled pane that shows.
fn the_keys_reach_each_pane_that_shows(allows_cover: bool) {
    let mut generator = Generator { state: 0x5_EEDF_10A7 };
    let mut checked = 0;
    let mut failures = Vec::new();
    for index in 0..2000 {
        let layout = Layout::make(&mut generator, allows_cover);
        if layout.floating.is_empty() {
            continue;
        }
        checked += 1;
        let problems = layout.problems();
        if !problems.is_empty() && failures.len() < 3 {
            let first = problems.iter().take(3).collect::<Vec<_>>();
            failures.push(format!("layout {index}: {first:?} {:?}", layout.frames));
        }
    }
    assert!(checked > 1000, "the generator made {checked} layouts with a floating pane");
    assert!(failures.is_empty(), "{failures:?}");
}

#[test]
fn the_keys_reach_each_pane_that_shows_and_no_pane_that_does_not() {
    the_keys_reach_each_pane_that_shows(false);
}

#[test]
fn the_keys_reach_each_pane_that_shows_when_a_floating_pane_covers_a_tiled_pane_wholly() {
    the_keys_reach_each_pane_that_shows(true);
}
