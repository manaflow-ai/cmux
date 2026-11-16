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

type FamilyReply = ((String, bool), Vec<FamilyPage>);

/// A small family-page fixture for mixed table/pager walks.  Each family ask
/// has an explicit sequence of pages, so a test can model a table prefix
/// followed by a pager rest (or a snapshot changing between asks) without
/// coupling the client tests to the daemon's page splitter.
struct Scripted {
    replies: Vec<FamilyReply>,
    asks: Vec<(String, bool)>,
}

impl Scripted {
    fn new(replies: Vec<FamilyReply>) -> Self {
        Self { replies, asks: Vec::new() }
    }

    fn page(rows: Vec<Summary>, cold_unread: bool, closure: bool) -> FamilyPage {
        FamilyPage { rows, cold_unread, closure, deeper: Vec::new(), foreign: Vec::new() }
    }

    fn foreign_page(
        rows: Vec<Summary>,
        cold_unread: bool,
        closure: bool,
        foreign: Vec<RowKey>,
    ) -> FamilyPage {
        FamilyPage { rows, cold_unread, closure, deeper: Vec::new(), foreign }
    }
}

impl Family for Scripted {
    fn family(
        &mut self,
        root: &RowKey,
        cold: bool,
        each: &mut dyn FnMut(FamilyPage) -> ControlFlow<()>,
    ) -> io::Result<()> {
        let key = (root.chat_id.to_string(), cold);
        self.asks.push(key.clone());
        let Some((_, pages)) = self.replies.iter_mut().find(|(candidate, _)| *candidate == key)
        else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("no scripted reply for {key:?}"),
            ));
        };
        for page in pages.iter().map(|page| FamilyPage {
            rows: page.rows.clone(),
            cold_unread: page.cold_unread,
            closure: page.closure,
            deeper: page.deeper.clone(),
            foreign: page.foreign.clone(),
        }) {
            if each(page).is_break() {
                break;
            }
        }
        Ok(())
    }
}

fn scripted_row(id: &str, parent: Option<&str>) -> Summary {
    let mut row = Summary::new(id);
    row.origin = "local".into();
    row.parent = parent.map(|parent| RowKey::new("local", parent));
    row
}

fn scripted_replies(cold: Vec<(&str, Vec<FamilyPage>)>) -> Vec<FamilyReply> {
    let mut replies: Vec<FamilyReply> =
        vec![(("root".into(), false), vec![Scripted::page(Vec::new(), true, false)])];
    replies.extend(cold.into_iter().map(|(root, pages)| ((root.into(), true), pages)));
    // Every cold row that is queued for a mixed walk must be askable.  The
    // default hot answer is empty but advertises a cold snapshot part, as the
    // daemon does when a snapshot is present.
    let roots: Vec<String> = replies.iter().map(|((root, _), _)| root.clone()).collect();
    for root in roots.into_iter().filter(|root| root != "root") {
        replies.push(((root, false), vec![Scripted::page(Vec::new(), true, false)]));
    }
    replies
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
            FamilyPage {
                rows: self.cold(root),
                cold_unread: false,
                closure: false,
                deeper: Vec::new(),
                foreign: Vec::new(),
            }
        } else {
            let (rows, deeper) = self.hot(root);
            let cold_unread = self.snapshot_held || !self.cold(root).is_empty();
            FamilyPage { rows, cold_unread, closure: false, deeper, foreign: Vec::new() }
        };
        // Two rows a page, so the walk is paged.
        let FamilyPage { rows, cold_unread, closure: _, deeper, foreign: _ } = page;
        let pages: Vec<Vec<Summary>> = rows.chunks(2).map(<[Summary]>::to_vec).collect();
        let last = pages.len().saturating_sub(1);
        for (at, rows) in pages.into_iter().enumerate() {
            let tail = at == last;
            let page = FamilyPage {
                rows,
                cold_unread: tail && cold_unread,
                closure: false,
                deeper: if tail { deeper.clone() } else { Vec::new() },
                foreign: Vec::new(),
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

/// A cold walk whose pages all carry the table's closure does not ask below
/// each listed cold row.  `deeper` remains the only follow-up mechanism.
#[test]
fn a_table_closure_walk_makes_no_per_cold_row_asks() {
    let cold_a = scripted_row("cold-a", Some("root"));
    let cold_b = scripted_row("cold-b", Some("root"));
    let mut list = Scripted::new(scripted_replies(vec![(
        "root",
        vec![Scripted::page(vec![cold_a], true, true), Scripted::page(vec![cold_b], true, true)],
    )]));
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["cold-a", "cold-b"]);
    assert_eq!(list.asks, [("root".to_owned(), false), ("root".to_owned(), true)]);
}

#[test]
fn a_foreign_closure_row_and_deeper_key_are_left_out_and_never_asked() {
    let mut child = scripted_row("child", Some("peer-parent"));
    child.origin = "local".to_owned();
    let child_key = key(&child);
    let mut page = foreign_page(vec![child], true, false, vec![child_key.clone()]);
    page.deeper.push(child_key);
    let mut list = Scripted::new(vec![
        (("root".into(), false), vec![Scripted::page(Vec::new(), true, false)]),
        (("root".into(), true), vec![page]),
    ]);
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert!(found.is_empty());
    assert_eq!(list.asks, [("root".to_owned(), false), ("root".to_owned(), true)]);
}

#[test]
fn a_local_child_of_a_peer_is_left_out_when_it_sorts_before_the_peer() {
    let peer = scripted_row("peer-parent", Some("root"));
    let mut child = scripted_row("child", Some("peer-parent"));
    child.origin = "local".to_owned();
    let child_key = key(&child);
    let mut page = foreign_page(vec![child, peer], true, true, vec![child_key]);
    page.deeper.push(RowKey::new("local", "child"));
    let mut list = Scripted::new(vec![
        (("root".into(), false), vec![Scripted::page(Vec::new(), true, false)]),
        (("root".into(), true), vec![page]),
    ]);
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert!(found.is_empty());
    assert_eq!(list.asks, [("root".to_owned(), false), ("root".to_owned(), true)]);
}

#[test]
fn a_pager_local_child_of_a_peer_is_left_out_before_or_after_the_peer() {
    let peer = scripted_row("peer-parent", Some("root"));
    let mut child = scripted_row("child", Some("peer-parent"));
    child.origin = "local".to_owned();
    let mut list = Scripted::new(vec![
        (("root".into(), false), vec![Scripted::page(Vec::new(), true, false)]),
        (
            ("root".into(), true),
            vec![Scripted::page(vec![child.clone(), peer.clone()], true, false)],
        ),
        (("child".into(), false), vec![Scripted::page(Vec::new(), false, false)]),
        (("peer-parent".into(), false), vec![Scripted::page(Vec::new(), false, false)]),
    ]);
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert!(found.is_empty(), "pager must match closure peer exclusion");
    assert!(!list.asks.contains(&("child".to_owned(), false)));
}

#[test]
fn a_transitive_foreign_grandchild_is_left_out_when_it_sorts_before_its_parent() {
    let peer = scripted_row("peer-parent", Some("root"));
    let mut parent = scripted_row("local-parent", Some("peer-parent"));
    parent.origin = "local".to_owned();
    let mut grandchild = scripted_row("local-grandchild", Some("local-parent"));
    grandchild.origin = "local".to_owned();
    let parent_key = key(&parent);
    let grandchild_key = key(&grandchild);
    let page = foreign_page(
        vec![grandchild, parent, peer],
        true,
        true,
        vec![grandchild_key.clone(), parent_key.clone()],
    );
    let mut list = Scripted::new(vec![
        (("root".into(), false), vec![Scripted::page(Vec::new(), true, false)]),
        (("root".into(), true), vec![page]),
    ]);
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert!(found.is_empty());
    assert_eq!(list.asks, [("root".to_owned(), false), ("root".to_owned(), true)]);
}

/// A table prefix lists a cold parent and the pager rest drops its grandchild.
/// The mixed walk asks below the parent after the page sequence and recovers it.
#[test]
fn a_table_prefix_then_pager_rest_finds_cold_grandchild() {
    let parent = scripted_row("parent", Some("root"));
    let sibling = scripted_row("sibling", Some("root"));
    let grandchild = scripted_row("grandchild", Some("parent"));
    let mut list = Scripted::new(scripted_replies(vec![
        (
            "root",
            vec![
                // The table prefix lists the parent; the pager rest has only
                // an unrelated sibling.  The grandchild is absent here.
                Scripted::page(vec![parent], true, true),
                Scripted::page(vec![sibling], true, false),
            ],
        ),
        // The client must ask below the cold parent to recover the dropped
        // grandchild after observing the pager page.
        ("parent", vec![Scripted::page(vec![grandchild], true, true)]),
        ("sibling", vec![Scripted::page(Vec::new(), false, false)]),
        ("grandchild", vec![Scripted::page(Vec::new(), false, false)]),
    ]));
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["parent", "sibling", "grandchild"]);
    assert!(list.asks.contains(&("parent".to_owned(), true)));
}

/// An empty pager page can have dropped a grandchild from the root walk.
/// Asking below the parent from the earlier table page still finds
/// that grandchild, with no duplicate in the result.
#[test]
fn an_empty_pager_page_and_dropped_grandchild_are_recovered_by_parent_ask() {
    let parent = scripted_row("parent", Some("root"));
    let grandchild = scripted_row("grandchild", Some("parent"));
    let mut list = Scripted::new(scripted_replies(vec![
        (
            "root",
            vec![
                // The table lists the parent, then a pager page has no row;
                // the grandchild is deliberately dropped from this walk.
                Scripted::page(vec![parent], true, true),
                Scripted::page(Vec::new(), true, false),
            ],
        ),
        ("parent", vec![Scripted::page(vec![grandchild], true, true)]),
        ("grandchild", vec![Scripted::page(Vec::new(), false, false)]),
    ]));
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["parent", "grandchild"]);
    assert_eq!(found.iter().filter(|row| row.chat_id == "grandchild").count(), 1);
    assert!(list.asks.contains(&("parent".to_owned(), true)));
}

/// If a pager serves the first page and a new table serves later root pages,
/// the grandchild remains discoverable even when its position
/// sorts inside the earlier pager pages.
#[test]
fn a_pager_first_then_table_later_snapshot_finds_sorted_grandchild() {
    let mut parent = scripted_row("parent", Some("root"));
    parent.last_activity = 2;
    let mut grandchild = scripted_row("grandchild", Some("parent"));
    grandchild.last_activity = 3;
    let sibling = scripted_row("sibling", Some("root"));
    let mut list = Scripted::new(scripted_replies(vec![
        (
            "root",
            vec![
                // The pager serves the first page with the parent.  A later
                // table page contains a sibling, while the grandchild sorts
                // inside the earlier pager range and is not listed.
                Scripted::page(vec![parent], true, false),
                Scripted::page(vec![sibling], true, true),
            ],
        ),
        // The table becomes available for the follow-up ask under the parent
        // after the pager served the root page.
        ("parent", vec![Scripted::page(vec![grandchild], true, true)]),
        ("sibling", vec![Scripted::page(Vec::new(), false, false)]),
        ("grandchild", vec![Scripted::page(Vec::new(), false, false)]),
    ]));
    let found = kin(&mut list, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["parent", "sibling", "grandchild"]);
    assert!(list.asks.contains(&("parent".to_owned(), true)));
}

/// A pager walk must recover under every cold key it lists, even one already
/// seen in an earlier table walk before the snapshot changed.
#[test]
fn a_mixed_walk_recovers_below_a_previously_seen_cold_row() {
    let bridge = scripted_row("bridge", Some("root"));
    let parent = scripted_row("parent", Some("bridge"));
    let grandchild = scripted_row("grandchild", Some("parent"));
    let mut root_page = Scripted::page(vec![bridge, parent.clone()], false, true);
    root_page.deeper.push(RowKey::new("local", "bridge"));
    let mut table = Scripted::new(scripted_replies(vec![
        ("root", vec![root_page]),
        ("bridge", vec![Scripted::page(vec![parent], false, false)]),
        ("parent", vec![Scripted::page(vec![grandchild], false, true)]),
    ]));
    let found = kin(&mut table, "root", 256, true).unwrap();
    assert_eq!(ids(&found), ["bridge", "parent", "grandchild"]);
    assert_eq!(table.asks.iter().filter(|(key, cold)| key == "parent" && *cold).count(), 1);
}
