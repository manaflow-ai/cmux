//! The one close-selection rule (plans/cmux-next/close-focus.md, "One
//! close-selection rule"), as a table: each row is a strip, the person's
//! steps, and the item selected at the end. Every row runs twice over the
//! same `Openers` state: as the tabs of a pane and as the workspaces of a
//! window's sidebar.
//!
//! The rows are the eight worked cases of the rule, then Chromium's ranks
//! and opener lifetime (`TabStripModel::DetermineNewSelectedIndex`,
//! `AddTab`, `InsertTabAtImpl`, `OnActiveTabChanged`, `TabNavigating`,
//! `FixOpeners`; chrome/browser/ui/tabs/tab_strip_model.cc at
//! 157.0.8103.50).

use cmux_focus_core::close_selection::{OpenerKind, Openers};
use std::collections::{HashMap, HashSet};

/// Where a person's new item goes.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    /// After the selected item (cmux's default).
    AfterSelected,
    /// At the end of the strip (Chrome's default).
    AtEnd,
}

/// Which rule entry picks the successor.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    Tabs,
    Workspaces,
}

#[derive(Clone, Copy, Debug)]
enum Step {
    /// The person makes an item in the foreground (Cmd-T, the plus button,
    /// New Workspace).
    New(&'static str),
    /// The selected item opens a link (or runs "open in new tab") in the
    /// background: the child goes after the opener's last child.
    LinkBehind(&'static str),
    /// The same in the foreground: the child goes right after the opener.
    LinkInFront(&'static str),
    /// Automation (the CLI, the socket) makes an item at the end, not selected.
    Scripted(&'static str),
    /// The person selects an item (a click, a shortcut, the palette).
    Select(&'static str),
    /// Automation selects an item.
    ScriptedSelect(&'static str),
    /// The person types an address in a tab.
    Typed(&'static str),
    /// Any other navigation commits in a tab (a link click, a redirect).
    Navigated(&'static str),
    /// The item closes (any entrypoint).
    Close(&'static str),
    /// The item moves to another strip.
    MoveOut(&'static str),
    /// The item moves to an index of its own strip.
    MoveTo(&'static str, usize),
}
use Step::{
    Close, LinkBehind, LinkInFront, MoveOut, MoveTo, Navigated, New, Scripted, ScriptedSelect,
    Select, Typed,
};

struct Strip {
    kind: Kind,
    mode: Mode,
    order: Vec<String>,
    selected: Option<String>,
    group: HashMap<String, u32>,
    openers: Openers<String>,
}

impl Strip {
    /// `start` lists the items; the one with `*` is selected.
    fn new(kind: Kind, mode: Mode, start: &str, group: &[(&str, u32)]) -> Self {
        let mut selected = None;
        let order = start
            .split_whitespace()
            .map(|item| {
                let id = item.trim_end_matches('*').to_owned();
                if item.ends_with('*') {
                    selected = Some(id.clone());
                }
                id
            })
            .collect();
        let group = group.iter().map(|(item, group)| ((*item).to_owned(), *group)).collect();
        Self { kind, mode, order, selected, group, openers: Openers::new() }
    }

    fn index(&self, item: &str) -> usize {
        self.order.iter().position(|id| id == item).unwrap_or_else(|| panic!("no item {item}"))
    }

    fn select(&mut self, item: &str, gesture: bool) {
        let item = item.to_owned();
        self.openers.selected(self.selected.as_ref(), &item, gesture, &self.order);
        self.selected = Some(item);
    }

    fn remove(&mut self, item: &str) {
        let item = item.to_owned();
        let old = self.order.clone();
        self.order.retain(|id| *id != item);
        let shown: HashSet<String> = self.order.iter().cloned().collect();
        let next = match self.kind {
            Kind::Tabs => self.openers.successor(
                self.selected.as_ref(),
                &old,
                &self.order,
                &shown,
                &self.group,
            ),
            Kind::Workspaces => self.openers.successor_in_orders(
                self.selected.as_ref(),
                &old,
                &self.order,
                std::slice::from_ref(&old),
                &self.group,
            ),
        };
        self.openers.left(&item);
        if let Some(next) = &next {
            self.openers.selected(self.selected.as_ref(), next, false, &self.order);
        }
        self.selected = next;
    }

    fn apply(&mut self, step: Step) {
        let selected = self.selected.clone();
        match step {
            New(item) => {
                let at = match (self.mode, &selected) {
                    (AfterSelected, Some(selected)) => self.index(selected) + 1,
                    _ => self.order.len(),
                };
                self.order.insert(at, item.to_owned());
                self.openers.made(
                    &item.to_owned(),
                    selected.as_ref(),
                    OpenerKind::Quick,
                    true,
                    &self.order,
                );
                self.select(item, false);
            }
            LinkBehind(item) => {
                let opener = selected.expect("a link needs a selected item");
                let after = self.openers.slot(&opener, &self.order, &HashSet::new());
                let at = self.index(&after) + 1;
                self.order.insert(at, item.to_owned());
                self.openers.made(
                    &item.to_owned(),
                    Some(&opener),
                    OpenerKind::Task,
                    false,
                    &self.order,
                );
            }
            LinkInFront(item) => {
                let opener = selected.expect("a link needs a selected item");
                let at = self.index(&opener) + 1;
                self.order.insert(at, item.to_owned());
                self.openers.made(
                    &item.to_owned(),
                    Some(&opener),
                    OpenerKind::Task,
                    true,
                    &self.order,
                );
                self.select(item, false);
            }
            Scripted(item) => self.order.push(item.to_owned()),
            Select(item) => self.select(item, true),
            ScriptedSelect(item) => self.select(item, false),
            Typed(item) => self.openers.typed_navigation(&item.to_owned(), &self.order),
            Navigated(item) => self.openers.navigated(&item.to_owned()),
            Close(item) => self.remove(item),
            MoveOut(item) => {
                // Another strip takes it; this strip's selection follows the close rule.
                self.remove(item);
            }
            MoveTo(item, at) => {
                self.openers.left(&item.to_owned());
                self.order.retain(|id| id != item);
                self.order.insert(at, item.to_owned());
            }
        }
    }
}

struct Row {
    name: &'static str,
    mode: Mode,
    start: &'static str,
    group: &'static [(&'static str, u32)],
    steps: &'static [Step],
    /// The strip at the end, the selected item with `*`.
    end: &'static str,
}

const fn row(
    name: &'static str,
    mode: Mode,
    start: &'static str,
    steps: &'static [Step],
    end: &'static str,
) -> Row {
    Row { name, mode, start, group: &[], steps, end }
}

fn run(kind: Kind, row: &Row) -> String {
    let mut strip = Strip::new(kind, row.mode, row.start, row.group);
    for step in row.steps {
        strip.apply(*step);
    }
    strip
        .order
        .iter()
        .map(|id| if Some(id) == strip.selected.as_ref() { format!("{id}*") } else { id.clone() })
        .collect::<Vec<_>>()
        .join(" ")
}

fn check(rows: &[Row]) {
    let mut wrong = Vec::new();
    for kind in [Kind::Tabs, Kind::Workspaces] {
        for row in rows {
            let end = run(kind, row);
            if end != row.end {
                wrong.push(format!("{kind:?}: {}: got [{end}], want [{}]", row.name, row.end));
            }
        }
    }
    assert!(wrong.is_empty(), "{} rows differ:\n{}", wrong.len(), wrong.join("\n"));
}

use Mode::{AfterSelected, AtEnd};

/// The eight worked cases of the rule (close-focus.md, "One close-selection
/// rule").
#[test]
fn the_eight_worked_cases() {
    check(&[
        row(
            "quick look-up, default mode",
            AfterSelected,
            "A B* C D",
            &[New("N"), Close("N")],
            "A B* C D",
        ),
        row("quick look-up, end mode", AtEnd, "A B* C D", &[New("N"), Close("N")], "A B* C D"),
        row(
            "look-up, then visited another",
            AfterSelected,
            "A B* C D",
            &[New("N"), Select("D"), Select("N"), Close("N")],
            "A B C* D",
        ),
        row("old item, middle", AfterSelected, "A B* C D", &[Close("B")], "A C* D"),
        row("old item, last", AfterSelected, "A B C D*", &[Close("D")], "A B C*"),
        row(
            "two links from B, close the first child",
            AfterSelected,
            "A B* C D",
            &[LinkBehind("X"), LinkBehind("Y"), Select("X"), Close("X")],
            "A B Y* C D",
        ),
        row(
            "close the opener with children",
            AfterSelected,
            "A B* C",
            &[LinkBehind("X"), LinkBehind("Y"), Close("B")],
            "A X* Y C",
        ),
        row("not selected", AfterSelected, "A B* C D", &[Close("C")], "A B* D"),
    ]);
}

/// `DetermineNewSelectedIndex`: a child, a sibling, the opener, the group's
/// neighbor, the next item, the previous one only for the last.
#[test]
fn chromium_ranks() {
    check(&[
        row("rank 5: the first item selects the next", AtEnd, "A* B C D", &[Close("A")], "B* C D"),
        row("rank 5: the only item leaves none", AtEnd, "A*", &[Close("A")], ""),
        row(
            "rank 1: a child after it wins over the next item",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), MoveTo("C", 2), Close("B")],
            "A C X* D",
        ),
        row(
            "rank 2: the sibling before it, when none is after it",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), LinkBehind("Y"), Select("Y"), Close("Y")],
            "A B X* C D",
        ),
        row(
            "rank 3: a foreground link tab returns to its opener",
            AtEnd,
            "A B* C D",
            &[LinkInFront("X"), Close("X")],
            "A B* C D",
        ),
        row(
            "rank 3: a background link tab returns to its opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), Select("X"), Close("X")],
            "A B* C D",
        ),
        row(
            "rank 3: the opener, wherever it is",
            AtEnd,
            "A* B C D",
            &[New("N"), Close("N")],
            "A* B C D",
        ),
        Row {
            name: "rank 4: the last item of a group selects the one before it in the group",
            mode: AtEnd,
            start: "A B C* D",
            group: &[("B", 1), ("C", 1)],
            steps: &[Close("C")],
            end: "A B* D",
        },
        Row {
            name: "rank 4: the next item in the group first",
            mode: AtEnd,
            start: "A B* C D",
            group: &[("B", 1), ("C", 1)],
            steps: &[Close("B")],
            end: "A C* D",
        },
        Row {
            name: "rank 3 goes before rank 4: the opener, not the group's neighbor",
            mode: AtEnd,
            start: "A B* C D",
            group: &[("D", 1), ("N", 1)],
            steps: &[New("N"), Close("N")],
            end: "A B* C D",
        },
    ]);
}

/// `AddTab` and `InsertTabAtImpl`: who has an opener (R2), and a foreground
/// item forgets the strip's older relations.
#[test]
fn who_gets_an_opener() {
    check(&[
        row(
            "an item automation made has none",
            AtEnd,
            "A* B C",
            &[Scripted("S"), Select("S"), Close("S")],
            "A B C*",
        ),
        row(
            "automation that selects its item gives it none",
            AfterSelected,
            "A* B C",
            &[Scripted("S"), ScriptedSelect("S"), Close("S")],
            "A B C*",
        ),
        row(
            "a second look-up returns to the first, the first then to the next item",
            AfterSelected,
            "A B* C D",
            &[New("N"), New("M"), Close("M"), Close("N")],
            "A B C* D",
        ),
        row(
            "a foreground link tab forgets the older family",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), LinkInFront("Y"), Select("X"), Close("X")],
            "A B Y C* D",
        ),
    ]);
}

/// `OnActiveTabChanged`: a quick opener ends when the selection leaves the
/// item; a deliberate move to an unrelated item forgets the strip's
/// relations; a move inside a family, and one automation makes, keep them (R3).
#[test]
fn when_openers_are_forgotten() {
    check(&[
        row(
            "a look-up loses its opener when automation moves the selection",
            AfterSelected,
            "A B* C D",
            &[New("N"), ScriptedSelect("D"), ScriptedSelect("N"), Close("N")],
            "A B C* D",
        ),
        row(
            "a look-up at the end loses its opener after a visit: the previous item",
            AtEnd,
            "A B* C D",
            &[New("N"), Select("A"), Select("N"), Close("N")],
            "A B C D*",
        ),
        row(
            "a look-up loses its opener even for a visit to the opener",
            AfterSelected,
            "A B* C D",
            &[New("N"), Select("B"), Select("N"), Close("N")],
            "A B C* D",
        ),
        row(
            "a visit to an unrelated item forgets a link tab's opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), Select("D"), Select("X"), Close("X")],
            "A B C* D",
        ),
        row(
            "automation's selection keeps a link tab's opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), ScriptedSelect("D"), ScriptedSelect("X"), Close("X")],
            "A B* C D",
        ),
        // Chromium's condition (`new_opener != old_opener && ...`): a move between two items that
        // both have no opener forgets nothing, so the link tab still returns to its opener.
        row(
            "a visit between items with no opener keeps a link tab's opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), Select("D"), Select("B"), Select("X"), Close("X")],
            "A B* C D",
        ),
        row(
            "opener to child and back keeps the family",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), LinkBehind("Y"), Select("X"), Select("B"), Select("Y"), Close("Y")],
            "A B X* C D",
        ),
        row(
            "sibling to sibling keeps the family",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), LinkBehind("Y"), Select("X"), Select("Y"), Close("Y")],
            "A B X* C D",
        ),
        row(
            "a close and the selection it causes forget nothing",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), LinkBehind("Y"), Select("X"), Close("X"), Close("Y")],
            "A B* C D",
        ),
    ]);
}

/// `TabNavigating`: a typed navigation starts another task, except the first
/// one of a tab the person just made (R3).
#[test]
fn typed_navigation() {
    check(&[
        row(
            "the first one of a new tab keeps its opener",
            AfterSelected,
            "A B* C D",
            &[New("N"), Typed("N"), Close("N")],
            "A B* C D",
        ),
        row(
            "the second one forgets",
            AfterSelected,
            "A B* C D",
            &[New("N"), Typed("N"), Typed("N"), Close("N")],
            "A B C* D",
        ),
        row(
            "a link click in a new tab keeps its opener",
            AfterSelected,
            "A B* C D",
            &[New("N"), Navigated("N"), Close("N")],
            "A B* C D",
        ),
        row(
            "after a link click a typed one is not the first: it forgets",
            AfterSelected,
            "A B* C D",
            &[New("N"), Navigated("N"), Typed("N"), Close("N")],
            "A B C* D",
        ),
        row(
            "one in a link tab forgets",
            AtEnd,
            "A B* C D",
            &[LinkInFront("X"), Typed("X"), Close("X")],
            "A B C* D",
        ),
        row(
            "one in the opener forgets its children's relations",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), LinkBehind("Y"), Typed("B"), Select("Y"), Close("Y")],
            "A B X C* D",
        ),
    ]);
}

/// `FixOpeners` and R4: an item that leaves hands its children its own
/// opener; a relation never crosses strips.
#[test]
fn items_that_leave() {
    check(&[
        row(
            "a grandchild returns to the grandparent",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), Select("X"), LinkBehind("Y"), Close("X"), Close("Y")],
            "A B* C D",
        ),
        row(
            "an opener that moved to another strip is no opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), Select("X"), MoveOut("B"), Close("X")],
            "A C* D",
        ),
        row(
            "a child that moved inside its strip has no opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), MoveTo("X", 4), Select("X"), Close("X")],
            "A B C D*",
        ),
        row(
            "an opener that moved inside its strip is no opener",
            AtEnd,
            "A B* C D",
            &[LinkBehind("X"), MoveTo("B", 0), Select("X"), Close("X")],
            "B A C* D",
        ),
        row(
            "a moved look-up has no opener",
            AfterSelected,
            "A B* C D",
            &[New("N"), MoveTo("N", 0), Close("N")],
            "A* B C D",
        ),
    ]);
}

fn ids(items: &str) -> Vec<String> {
    items.split_whitespace().map(str::to_owned).collect()
}

fn id(item: &str) -> String {
    item.to_owned()
}

/// R2's edges: an item with no opener, and what the state then holds.
#[test]
fn items_with_no_opener() {
    let strip = ids("A B N C");
    let mut openers = Openers::new();
    // With no relation a selection change is nothing, whatever the strip.
    openers.selected(Some(&id("A")), &id("B"), true, &[]);
    assert!(openers.is_empty());
    // A person's item made in the background has none and is not "just made".
    openers.made(&id("N"), Some(&id("B")), OpenerKind::Quick, false, &strip);
    assert!(openers.is_empty());
    // Made in the foreground with no selected item: none, but it is "just made".
    openers.made(&id("N"), None, OpenerKind::Quick, true, &strip);
    assert_eq!(openers.opener(&id("N")), None);
    assert!(!openers.has_relations());
    assert!(!openers.is_empty());
    openers.left(&id("N"));
    assert!(openers.is_empty());
    // An item is never its own opener.
    openers.made(&id("N"), Some(&id("N")), OpenerKind::Task, true, &strip);
    assert!(!openers.has_relations());
    // A relation is held from the make to the item's end.
    openers.made(&id("N"), Some(&id("B")), OpenerKind::Task, false, &strip);
    assert!(openers.has_relations());
    openers.left(&id("N"));
    assert!(!openers.has_relations());
    assert!(openers.is_empty());
}

/// Rank 1 in full (a child after the closed tab, else the nearest before it;
/// a child before a sibling), a batch close, and hidden tabs.
#[test]
fn ranks_that_the_steps_cannot_make() {
    let none: HashMap<String, u32> = HashMap::new();
    let pick =
        |openers: &Openers<String>, closed: &str, old: &[String], left: &str, shown: &str| {
            let shown: HashSet<String> = ids(shown).into_iter().collect();
            openers.successor(Some(&id(closed)), old, &ids(left), &shown, &none)
        };
    let family = |old: &[String], relations: &[(&str, &str)]| {
        let mut openers = Openers::new();
        for (child, opener) in relations {
            openers.made(&id(child), Some(&id(opener)), OpenerKind::Task, false, old);
        }
        openers
    };
    // X is B's child and stands before it: X, not the next tab C.
    let old = ids("A X B C");
    let openers = family(&old, &[("X", "B")]);
    assert_eq!(pick(&openers, "B", &old, "A X C", "A X C"), Some(id("X")));
    // B has a child X and a sibling S: the child, not the nearer sibling.
    let old = ids("P B S X");
    let openers = family(&old, &[("B", "P"), ("S", "P"), ("X", "B")]);
    assert_eq!(pick(&openers, "B", &old, "P S X", "P S X"), Some(id("X")));
    assert_eq!(pick(&openers, "S", &old, "P B X", "P B X"), Some(id("B")));
    // A batch takes X and its sibling Y: their opener, not the next tab.
    let old = ids("A B X Y C");
    let openers = family(&old, &[("X", "B"), ("Y", "B")]);
    assert_eq!(pick(&openers, "X", &old, "A B C", "A B C"), Some(id("B")));
    // A batch takes X and its opener B, a child of A: the opener's opener.
    let old = ids("A C B X D");
    let openers = family(&old, &[("B", "A"), ("X", "B")]);
    assert_eq!(pick(&openers, "X", &old, "A C D", "A C D"), Some(id("A")));
    // A hidden tab (a collapsed group's) is not picked: the next shown one,
    // and a hidden opener is passed over.
    let old = ids("A B C D");
    assert_eq!(pick(&Openers::new(), "B", &old, "A C D", "A D"), Some(id("D")));
    let old = ids("A B X C");
    let openers = family(&old, &[("X", "B")]);
    assert_eq!(pick(&openers, "X", &old, "A B C", "A C"), Some(id("C")));
}

/// A window's workspaces: the drawn rows decide, as before, and the opener
/// ranks apply to them.
#[test]
fn a_workspace_returns_to_its_opener_among_the_drawn_rows() {
    let none: HashMap<String, u32> = HashMap::new();
    let mut openers = Openers::new();
    // Joined a, b, c, d, then n made from b; the sidebar draws a b n c d.
    let old = ids("a b c d n");
    let rows = ids("a b n c d");
    openers.made(&id("n"), Some(&id("b")), OpenerKind::Quick, true, &old);
    let left = ids("a b c d");
    let pick = |openers: &Openers<String>, orders: &[Vec<String>]| {
        openers.successor_in_orders(Some(&id("n")), &old, &left, orders, &none)
    };
    assert_eq!(pick(&openers, std::slice::from_ref(&rows)), Some(id("b")));
    // The sidebar is filtered and does not draw the opener: the next drawn row.
    assert_eq!(pick(&openers, &[ids("a n c"), rows.clone()]), Some(id("c")));
    // No drawn row lists the closed one: the model's rows decide, opener first.
    assert_eq!(pick(&openers, &[ids("a c"), rows.clone()]), Some(id("b")));
    // The opener is in another window (not a member here): the next row.
    let other = ids("a c d n");
    let other_left = ids("a c d");
    assert_eq!(
        openers.successor_in_orders(Some(&id("n")), &other, &other_left, &[ids("a n c d")], &none),
        Some(id("c"))
    );
    // No relation: the row below, else the row above, in the drawn order.
    let plain = Openers::new();
    assert_eq!(pick(&plain, std::slice::from_ref(&rows)), Some(id("c")));
    assert_eq!(
        plain.successor_in_orders(
            Some(&id("d")),
            &old,
            &ids("a b c n"),
            std::slice::from_ref(&rows),
            &none
        ),
        Some(id("c"))
    );
    // A pinned tile (a member no row lists) is never picked while a row is left.
    assert_eq!(
        plain.successor_in_orders(
            Some(&id("c")),
            &ids("a b c p"),
            &ids("a b p"),
            &[ids("a b c")],
            &none
        ),
        Some(id("b"))
    );
    assert_eq!(
        plain.successor_in_orders(Some(&id("c")), &ids("p c"), &ids("p"), &[ids("c")], &none),
        Some(id("p"))
    );
    // A surviving selection stays; no selection takes the first member.
    assert_eq!(
        openers.successor_in_orders(
            Some(&id("a")),
            &old,
            &left,
            std::slice::from_ref(&rows),
            &none
        ),
        Some(id("a"))
    );
    assert_eq!(
        openers.successor_in_orders(None, &old, &left, std::slice::from_ref(&rows), &none),
        Some(id("a"))
    );
}

/// A sidebar section or group is Chromium's group: the row below in the
/// same section, else the row above in it, before a row of another section.
#[test]
fn a_workspace_stays_in_its_section() {
    let group: HashMap<String, u32> = [("a", 1), ("b", 1), ("c", 2), ("d", 2)]
        .into_iter()
        .map(|(row, section)| (id(row), section))
        .collect();
    let openers: Openers<String> = Openers::new();
    let old = ids("a b c d");
    let pick = |closed: &str| {
        let left: Vec<String> = old.iter().filter(|row| *row != closed).cloned().collect();
        openers.successor_in_orders(
            Some(&id(closed)),
            &old,
            &left,
            std::slice::from_ref(&old),
            &group,
        )
    };
    assert_eq!(pick("b"), Some(id("a")));
    assert_eq!(pick("a"), Some(id("b")));
    assert_eq!(pick("c"), Some(id("d")));
    assert_eq!(pick("d"), Some(id("c")));
}

/// R5 and `GetIndexOfLastWebContentsOpenedBy`: a background child goes after
/// the run of the opener's descendants that follows it; a pinned item never
/// ends the run.
#[test]
fn a_background_child_goes_after_the_openers_last_child() {
    let mut openers = Openers::new();
    let none = HashSet::new();
    assert_eq!(openers.slot(&id("B"), &ids("A B C"), &none), id("B"));
    openers.made(&id("X"), Some(&id("B")), OpenerKind::Task, false, &ids("A B X C"));
    assert_eq!(openers.slot(&id("B"), &ids("A B X C"), &none), id("X"));
    openers.made(&id("Y"), Some(&id("X")), OpenerKind::Task, false, &ids("A B X Y C"));
    assert_eq!(openers.slot(&id("B"), &ids("A B X Y C"), &none), id("Y"));
    assert_eq!(openers.slot(&id("X"), &ids("A B X Y C"), &none), id("Y"));
    // An unrelated tab ends the run; a pinned one does not.
    assert_eq!(openers.slot(&id("B"), &ids("A B C X Y"), &none), id("B"));
    let pinned: HashSet<String> = HashSet::from([id("C")]);
    assert_eq!(openers.slot(&id("B"), &ids("A B C X Y"), &pinned), id("Y"));
    // A tab that left is skipped (`FixOpeners`): Y is then B's child.
    openers.left(&id("X"));
    assert_eq!(openers.slot(&id("B"), &ids("A B Y C"), &none), id("Y"));
    assert_eq!(openers.opener(&id("Y")), Some((&id("B"), OpenerKind::Task)));
}

/// One state holds every strip's relations: forgetting one strip's leaves
/// the others'.
#[test]
fn strips_do_not_share_relations() {
    let mut openers = Openers::new();
    let one = ids("A B X");
    let two = ids("P Q Y");
    openers.made(&id("X"), Some(&id("B")), OpenerKind::Task, false, &one);
    openers.made(&id("Y"), Some(&id("Q")), OpenerKind::Task, false, &two);
    openers.selected(Some(&id("B")), &id("A"), true, &one);
    openers.selected(Some(&id("A")), &id("X"), true, &one);
    assert_eq!(openers.opener(&id("X")), None);
    assert_eq!(openers.opener(&id("Y")), Some((&id("Q"), OpenerKind::Task)));
    openers.left(&id("Y"));
    assert!(openers.is_empty());
}
