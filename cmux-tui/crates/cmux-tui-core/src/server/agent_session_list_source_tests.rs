//! The kin walk ([`super::list_source::kin`]) against a family that pages as the hub's does
//! (acpmux-core `hub/kin_tests.rs`): a hot part depth first to a depth bound, naming `deeper`
//! rows, and a cold part of the cold rows under the root or a hot descendant.

use super::list_source::{Family, FamilyPage, kin};
use acpmux_list_types::{RowKey, Summary};
use std::io;
use std::ops::ControlFlow;

/// Rows (each hot or cold) and the asks made of them.
struct Table {
    rows: Vec<(Summary, bool)>,
    depth: usize,
    asks: Vec<(String, bool)>,
    /// Say `coldUnread` on every last hot page, as the hub does when its snapshot holds a row.
    snapshot_held: bool,
}

fn key(row: &Summary) -> RowKey {
    RowKey::new(row.origin.as_str(), row.chat_id.as_str())
}

impl Table {
    fn new(depth: usize) -> Self {
        Self { rows: Vec::new(), depth, asks: Vec::new(), snapshot_held: false }
    }

    fn add(&mut self, origin: &str, id: &str, parent: Option<(&str, &str)>, hot: bool) {
        let mut row = Summary::new(id);
        row.origin = origin.into();
        row.parent = parent.map(|(origin, id)| RowKey::new(origin, id));
        self.rows.push((row, hot));
    }

    fn children(&self, parent: &RowKey, hot: bool) -> Vec<&Summary> {
        let mut found: Vec<&Summary> = self
            .rows
            .iter()
            .filter(|(row, is_hot)| *is_hot == hot && row.parent.as_ref() == Some(parent))
            .map(|(row, _)| row)
            .collect();
        found.sort_by(|a, b| a.chat_id.cmp(&b.chat_id));
        found
    }

    /// The hot part depth first from `root`, and its `deeper` rows.
    fn hot(&self, root: &RowKey) -> (Vec<Summary>, Vec<RowKey>) {
        let (mut rows, mut deeper) = (Vec::new(), Vec::new());
        let mut stack = vec![(root.clone(), 0)];
        while let Some((parent, depth)) = stack.pop() {
            for child in self.children(&parent, true).into_iter().rev() {
                stack.push((key(child), depth + 1));
            }
            if depth > 0 {
                let row = self.rows.iter().find(|(row, _)| key(row) == parent).unwrap();
                rows.push(row.0.clone());
                if depth == self.depth {
                    if !self.children(&parent, true).is_empty() {
                        deeper.push(parent);
                    }
                    stack.retain(|(_, below)| *below <= depth);
                }
            }
        }
        (rows, deeper)
    }

    /// The cold rows under `root` or one of its hot descendants.
    fn cold(&self, root: &RowKey) -> Vec<Summary> {
        let (hot, _) = self.hot(root);
        let parents: Vec<RowKey> =
            std::iter::once(root.clone()).chain(hot.iter().map(key)).collect();
        parents.iter().flat_map(|parent| self.children(parent, false)).cloned().collect()
    }
}

impl Family for Table {
    fn family(
        &mut self,
        root: &RowKey,
        cold: bool,
        each: &mut dyn FnMut(FamilyPage) -> ControlFlow<()>,
    ) -> io::Result<()> {
        self.asks.push((root.chat_id.to_string(), cold));
        let page = if cold {
            FamilyPage { rows: self.cold(root), cold_unread: false, deeper: Vec::new() }
        } else {
            let (rows, deeper) = self.hot(root);
            let cold_unread = self.snapshot_held || !self.cold(root).is_empty();
            FamilyPage { rows, cold_unread, deeper }
        };
        // Two rows a page, so the walk is paged.
        let FamilyPage { rows, cold_unread, deeper } = page;
        let pages: Vec<Vec<Summary>> = rows.chunks(2).map(<[Summary]>::to_vec).collect();
        let last = pages.len().saturating_sub(1);
        for (at, rows) in pages.into_iter().enumerate() {
            let tail = at == last;
            let page = FamilyPage {
                rows,
                cold_unread: tail && cold_unread,
                deeper: if tail { deeper.clone() } else { Vec::new() },
            };
            if each(page).is_break() {
                return Ok(());
            }
        }
        Ok(())
    }
}

fn ids(rows: &[Summary]) -> Vec<&str> {
    rows.iter().map(|row| row.chat_id.as_str()).collect()
}

/// Decision 146's fifth difference, and what the first ask leaves out: a cold child of a cold
/// child and a hot chat under a cold one come by a second ask rooted at the cold row; a peer's
/// row, and a row under one, are never kin (v1's child collector leaves peers out).
#[test]
fn a_cold_rows_kin_come_by_a_second_ask_and_peers_never() {
    let mut table = Table::new(64);
    table.add("local", "a", Some(("local", "root")), true);
    table.add("local", "b", Some(("local", "a")), false);
    table.add("local", "c", Some(("local", "b")), false);
    table.add("local", "d", Some(("local", "b")), true);
    table.add("peer", "p", Some(("local", "root")), true);
    table.add("local", "q", Some(("peer", "p")), true);
    table.add("local", "unrelated", None, true);
    let found = kin(&mut table, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["a", "b", "d", "c"]);
    assert_eq!(
        table.asks,
        [
            ("root".to_owned(), false),
            ("root".to_owned(), true),
            ("b".to_owned(), false),
            ("b".to_owned(), true),
            ("c".to_owned(), false),
        ],
        "a cold part is asked only when the hot part says coldUnread"
    );
}

/// A chain past the depth bound: the rows under a `deeper` row come by an ask rooted there.
#[test]
fn a_family_deeper_than_the_bound_is_asked_again_under_its_deeper_rows() {
    let mut table = Table::new(3);
    let mut parent = "root".to_owned();
    for n in 1..=7 {
        let id = format!("n{n}");
        table.add("local", &id, Some(("local", &parent)), true);
        parent = id;
    }
    let found = kin(&mut table, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["n1", "n2", "n3", "n4", "n5", "n6", "n7"]);
    assert_eq!(table.asks.iter().filter(|(_, cold)| !cold).count(), 3);
}

/// At the cap the walk ends: no more rows are taken and no more asks made (v1's
/// `MAX_CHILDREN`).
#[test]
fn the_walk_stops_at_its_cap() {
    let mut table = Table::new(64);
    for n in 0..10 {
        table.add("local", &format!("c{n}"), Some(("local", "root")), n % 2 == 0);
        table.add("local", &format!("g{n}"), Some(("local", &format!("c{n}"))), false);
    }
    let found = kin(&mut table, "root", 4, true).unwrap();
    assert_eq!(found.len(), 4);
    assert_eq!(table.asks, [("root".to_owned(), false)], "the hot part held the cap");
}

/// Decision 301: the attach reads the hot part only. The hub says `coldUnread` on every last
/// hot page while its snapshot holds a row, cold kin or not, so a hot-only walk asks no cold
/// part, whatever a page says, and never goes under a cold row.
#[test]
fn a_hot_only_walk_asks_no_cold_part_though_every_page_says_cold_unread() {
    let mut table = Table::new(64);
    table.snapshot_held = true;
    table.add("local", "a", Some(("local", "root")), true);
    table.add("local", "g", Some(("local", "a")), true);
    table.add("local", "b", Some(("local", "a")), false);
    table.add("local", "d", Some(("local", "b")), true);
    let found = kin(&mut table, "root", 256, false).unwrap();
    assert_eq!(ids(&found), ["a", "g"]);
    assert_eq!(table.asks, [("root".to_owned(), false)], "one hot ask, no cold part");
    // The same table read with its cold kin: the cold part is asked, as the hub's pages say.
    table.asks.clear();
    let found = kin(&mut table, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["a", "g", "b", "d"]);
    assert!(table.asks.contains(&("root".to_owned(), true)));
}
