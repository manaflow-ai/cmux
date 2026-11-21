//! Small element ids that stay the same across trees of a window.
//!
//! Every tree the engine walks goes through [`WindowIds::assign`]: each
//! element is matched to one of the window's previous tree, and keeps its id,
//! or gets a new one. Ids are never reused, so an old id can never name a
//! different element. Matching, strongest first:
//!
//! 1. the platform's identity ([`Element::identity`]: the same AXUIElement,
//!    the same AT-SPI object) with the same role;
//! 2. under the same parent, the same role and identifier (AXIdentifier);
//! 3. under the same parent, the same role, label (its name, else its
//!    identifier, else the text inside it) and position among siblings with
//!    that role and label.
//!
//! A row whose text changed is a different row, never a renamed one: the text
//! inside an unnamed element is part of its label, so a list that shifts does
//! not hand a row's id to its neighbor.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::desktop::{Element, Rect, UiTree};

/// Windows whose ids are kept (least recently walked dropped first).
pub const MAX_WINDOWS: usize = 64;
/// Removed ids remembered per window, to say what a stale id was.
const MAX_GONE: usize = 4096;
/// The most characters of an unnamed element's inner text in its label.
const LABEL_TEXT_MAX: usize = 80;

/// The role of an app's menu bar in a tree (the macOS desktop's `AXMenuBar`).
pub const MENU_BAR: &str = "menu_bar";

/// An element id as an agent may write it: `17` or `[17]`. None for the
/// desktop's own ids (`12.3`, `bus|/path`), which pass through as they are.
pub fn parse(raw: &str) -> Option<u32> {
    let t = raw.trim();
    let t = t.strip_prefix('[').and_then(|r| r.strip_suffix(']')).unwrap_or(t).trim();
    if t.is_empty() || !t.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    t.parse().ok().filter(|n| *n > 0)
}

/// What the engine knows of one element of a window's latest tree.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// The desktop's id for it in the walk that found it.
    pub platform_id: String,
    /// The walk that found it ([`WindowIds::walk`] when current).
    pub walk: u64,
    pub parent: Option<u32>,
    pub role: String,
    pub name: String,
    pub value: String,
    pub identifier: String,
    label: String,
    nth: usize,
    /// Its position among its parent's children of its role.
    rnth: usize,
    /// The labels of the labeled elements inside it (a few, sorted).
    content: Vec<String>,
    distinct: Vec<String>,
    dups: usize,
    sole: bool,
    identity: Option<u64>,
    pub disabled: bool,
    pub focused: bool,
    /// In global desktop points, as the walk read it.
    pub frame: Option<Rect>,
    pub actions: Vec<String>,
    /// Inside the app's menu bar.
    pub menu_bar: bool,
}

impl Entry {
    /// `button "Save"`, for messages about it.
    pub fn summary(&self) -> String {
        let role = self.role.replace('_', " ");
        let label = if self.name.is_empty() { &self.label } else { &self.name };
        if label.is_empty() {
            role
        } else {
            format!("{role} \"{}\"", super::outline::clip(label, 60))
        }
    }
}

/// How an agent's id stands against the window's latest tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Resolved {
    /// In the latest walk: act on its platform id.
    Current(Entry),
    /// A menu bar element from an earlier walk that left the menus out: walk
    /// again with the menus to get its platform id.
    Carried(Entry),
    /// It was in an earlier tree and is gone (what it was).
    Gone(String),
    /// No tree of this window ever had it.
    Unknown,
}

#[derive(Default)]
pub struct WindowIds {
    walk: u64,
    entries: HashMap<u32, Entry>,
    by_platform: HashMap<String, u32>,
    gone: HashMap<u32, String>,
    gone_order: VecDeque<u32>,
    /// The latest walk's tree, small ids, global frames.
    tree: Option<Element>,
    truncated: bool,
    /// The menu bar of the latest walk that read it, small ids.
    menu_bar: Option<Element>,
    /// The process and root element the ids belong to: a window id the
    /// system reuses for another window starts over.
    owner: Option<(u32, Option<u64>)>,
}

/// One node of a walk in pre-order, before ids are given.
struct Flat {
    parent: Option<usize>,
    label: String,
    nth: usize,
    rnth: usize,
    content: Vec<String>,
    /// Its content without the labels its same-role unlabeled siblings also
    /// hold (a feed card's "Like", "Share"): what tells it apart.
    distinct: Vec<String>,
    /// How many siblings (it included) have its role and label.
    dups: usize,
    /// Its identifier, unless weak (AppKit's generated `_NS:12`).
    identifier: String,
    /// No sibling shares its role and identifier.
    ident_unique: bool,
    /// No sibling has its role.
    sole: bool,
    menu_bar: bool,
}

/// Roles whose views AppKit recycles for other content (table and outline
/// rows and cells): the same identity with another label is another item.
/// Not a table's column: its identifier (NSTableColumn's, `name`,
/// `dateModified`) names that column, and AppKit makes its element anew for
/// every read, so it keeps its id by that identifier.
const RECYCLED_ROLES: &[&str] = &[
    "row",
    "cell",
    "outline_row",
    "list_item",
    "list item",
    "item",
    "tree_item",
    "data_item",
    "table_row",
    "table row",
    "table_cell",
    "table cell",
];

/// Walks an entry a cut walk did not reach is kept, carried, before it is gone.
pub const CARRY_WALKS: u64 = 8;
/// The most labels kept of a container's content.
const CONTENT_MAX: usize = 12;

/// A token that is a time or a count: `12:05`, `5m`, `2h`, `3d`, `(12)`.
fn time_token(t: &str) -> bool {
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let t = t.trim_matches(|c: char| c == ',' || c == '.' || c == '·');
    if let Some(inner) = t.strip_prefix('(').and_then(|r| r.strip_suffix(')')) {
        return digits(inner);
    }
    if t.contains(':') {
        return t.split(':').all(digits) && t.split(':').count() <= 3;
    }
    let n = t.bytes().take_while(u8::is_ascii_digit).count();
    n > 0
        && matches!(
            t.get(n..).unwrap_or_default().to_ascii_lowercase().as_str(),
            "s" | "m" | "h" | "d" | "w" | "y" | "mo" | "min" | "hr" | "wk"
        )
}

/// A unit word after a number: `5 min ago`, `2 hours`.
fn unit_word(t: &str) -> bool {
    let t = t.trim_matches(|c: char| c == ',' || c == '.').to_ascii_lowercase();
    matches!(
        t.as_str(),
        "s" | "sec"
            | "secs"
            | "second"
            | "seconds"
            | "m"
            | "min"
            | "mins"
            | "minute"
            | "minutes"
            | "h"
            | "hr"
            | "hrs"
            | "hour"
            | "hours"
            | "d"
            | "day"
            | "days"
            | "w"
            | "wk"
            | "wks"
            | "week"
            | "weeks"
            | "mo"
            | "month"
            | "months"
            | "y"
            | "yr"
            | "yrs"
            | "year"
            | "years"
            | "am"
            | "pm"
    )
}

/// The label with its time and count fragments replaced by `#`.
fn without_times(label: &str) -> String {
    let words: Vec<&str> = label.split_whitespace().collect();
    let mut out: Vec<&str> = Vec::with_capacity(words.len());
    let mut i = 0;
    while i < words.len() {
        let Some(&w) = words.get(i) else { break };
        let number =
            !w.is_empty() && w.trim_end_matches([',', '.']).bytes().all(|b| b.is_ascii_digit());
        if time_token(w) {
            out.push("#");
        } else if number && words.get(i + 1).is_some_and(|n| unit_word(n)) {
            out.push("#");
            i += 1;
        } else {
            out.push(w);
        }
        i += 1;
    }
    out.join(" ")
}

/// Two labels of one recycled item that differ only in a time or a count
/// ("2 min ago" and "3 min ago", "Inbox (4)" and "Inbox (5)"); never in a
/// name or a number that is the item ("IMG_0001", "#1234", a bare "12").
pub fn time_drift(a: &str, b: &str) -> bool {
    a != b && without_times(a) == without_times(b) && without_times(a).contains('#')
}

/// Roles an unnamed element of which is told apart by the text inside it.
const ITEM_ROLES: &[&str] = &[
    "row",
    "cell",
    "outline_row",
    "list_item",
    "list item",
    "item",
    "tree_item",
    "data_item",
    "table_row",
    "table row",
    "table_cell",
    "table cell",
    "link",
    "hyperlink",
    "button",
    "tab",
    "tab_item",
    "radio",
    "checkbox",
    "menu_item",
    "menu_button",
    "popup_button",
    "column",
];

/// An unnamed element's label: its identifier, else the text inside it.
fn label_of(e: &Element) -> String {
    if !e.name.trim().is_empty() {
        return e.name.trim().to_string();
    }
    // Only an item is named by the text inside it (a list, table or group
    // whose rows change is the same container); a recycled item's identifier
    // names its kind of view, never the item ("cell-view").
    if ITEM_ROLES.contains(&e.role.as_str()) {
        let mut texts = Vec::new();
        inner_text(e, &mut texts, 0, RECYCLED_ROLES.contains(&e.role.as_str()));
        let mut label = texts.join("|");
        if label.chars().count() > LABEL_TEXT_MAX {
            label = label.chars().take(LABEL_TEXT_MAX).collect();
        }
        if !label.is_empty() || RECYCLED_ROLES.contains(&e.role.as_str()) {
            return label;
        }
    }
    if !strong_identifier(&e.identifier).is_empty() {
        return format!("#{}", e.identifier);
    }
    String::new()
}

/// The first few names and static texts below `e` (not editable values,
/// which change as the person types).
/// `values`: a recycled row is also named by the text in its fields (Finder
/// shows a file's name in a text field, not a label).
fn inner_text(e: &Element, out: &mut Vec<String>, depth: usize, values: bool) {
    // Two levels: a row's cells' text, never a list's rows' (a list whose
    // rows change is the same list).
    if out.len() >= 3 || depth >= 2 {
        return;
    }
    for c in &e.children {
        let t = if !c.name.trim().is_empty() {
            c.name.trim()
        } else if super::outline::is_static_text(&c.role)
            || (values && super::guards::is_text_input(&c.role))
        {
            c.value.trim()
        } else {
            ""
        };
        if !t.is_empty() {
            out.push(t.to_string());
        }
        if out.len() >= 3 {
            return;
        }
        inner_text(c, out, depth + 1, values);
    }
}

/// Pre-order nodes with their parent, label, positions and content.
fn flatten(root: &Element) -> Vec<(Flat, &Element)> {
    fn visit<'a>(e: &'a Element, f: Flat, out: &mut Vec<(Flat, &'a Element)>) -> Vec<String> {
        let index = out.len();
        let menu_bar = f.menu_bar;
        out.push((f, e));
        let mut seen: HashMap<(&str, String), usize> = HashMap::new();
        let mut by_role: HashMap<&str, usize> = HashMap::new();
        let mut content: Vec<String> = Vec::new();
        for c in &e.children {
            let label = label_of(c);
            let n = seen.entry((c.role.as_str(), label.clone())).or_insert(0);
            let nth = *n;
            *n += 1;
            let r = by_role.entry(c.role.as_str()).or_insert(0);
            let rnth = *r;
            *r += 1;
            if !label.is_empty() && content.len() < CONTENT_MAX {
                content.push(label.clone());
            }
            let f = Flat {
                parent: Some(index),
                label,
                nth,
                rnth,
                content: Vec::new(),
                distinct: Vec::new(),
                dups: 1,
                identifier: strong_identifier(&c.identifier).to_string(),
                ident_unique: false,
                sole: false,
                menu_bar: menu_bar || c.role == MENU_BAR,
            };
            for inner in visit(c, f, out) {
                if content.len() < CONTENT_MAX {
                    content.push(inner);
                }
            }
        }
        content.sort();
        content.dedup();
        if let Some((f, _)) = out.get_mut(index) {
            f.content = content.clone();
        }
        content
    }
    let mut out = Vec::new();
    let f = Flat {
        parent: None,
        label: label_of(root),
        nth: 0,
        rnth: 0,
        content: Vec::new(),
        distinct: Vec::new(),
        dups: 1,
        identifier: strong_identifier(&root.identifier).to_string(),
        ident_unique: true,
        sole: true,
        menu_bar: root.role == MENU_BAR,
    };
    visit(root, f, &mut out);
    // Per parent: repeated (role, label), shared identifiers, and the labels
    // unlabeled same-role siblings share (left out of what tells them apart).
    let mut kids: HashMap<usize, Vec<usize>> = HashMap::new();
    for (i, (f, _)) in out.iter().enumerate() {
        if let Some(p) = f.parent {
            kids.entry(p).or_default().push(i);
        }
    }
    for group in kids.values() {
        let mut keys: HashMap<(String, String), usize> = HashMap::new();
        let mut idents: HashMap<(String, String), usize> = HashMap::new();
        let mut shared: HashMap<(String, String), usize> = HashMap::new();
        let mut roles: HashMap<String, usize> = HashMap::new();
        for &i in group {
            let Some((f, e)) = out.get(i) else { continue };
            *roles.entry(e.role.clone()).or_default() += 1;
            *keys.entry((e.role.clone(), f.label.clone())).or_default() += 1;
            if !f.identifier.is_empty() {
                *idents.entry((e.role.clone(), f.identifier.clone())).or_default() += 1;
            }
            if f.label.is_empty() {
                for l in &f.content {
                    *shared.entry((e.role.clone(), l.clone())).or_default() += 1;
                }
            }
        }
        for &i in group {
            let Some((f, e)) = out.get_mut(i) else { continue };
            let role = e.role.clone();
            f.dups = keys.get(&(role.clone(), f.label.clone())).copied().unwrap_or(1);
            f.sole = roles.get(&role).copied().unwrap_or(1) == 1;
            f.ident_unique = !f.identifier.is_empty()
                && idents.get(&(role.clone(), f.identifier.clone())).copied().unwrap_or(0) == 1;
            if f.label.is_empty() {
                f.distinct = f
                    .content
                    .iter()
                    .filter(|l| {
                        shared.get(&(role.clone(), (*l).clone())).copied().unwrap_or(0) <= 1
                    })
                    .cloned()
                    .collect();
            }
        }
    }
    out
}

/// Two lists of labels share at least half of the longer one.
fn half_shared(a: &[String], b: &[String]) -> bool {
    let shared = a.iter().filter(|x| b.contains(x)).count();
    !a.is_empty() && !b.is_empty() && shared * 2 >= a.len().max(b.len())
}

/// An identifier that names the element, or "" for a weak one: AppKit's
/// generated `_NS:12`, or digits alone.
pub fn strong_identifier(id: &str) -> &str {
    if id.starts_with("_NS:") || id.bytes().all(|b| b.is_ascii_digit()) { "" } else { id }
}

type Key = (Option<u32>, String, String, usize);

/// For an element whose role and label repeat among its siblings (identical
/// "Remove" buttons): only the same count of them and the same position
/// match; one removed or added makes every one of them new.
fn same_repeat(o: &Entry, f: &Flat) -> bool {
    (o.dups <= 1 && f.dups <= 1) || (o.dups == f.dups && o.rnth == f.rnth)
}

impl WindowIds {
    /// The latest walk's number.
    pub fn walk(&self) -> u64 {
        self.walk
    }

    /// Gives every element of `tree` its id (rewriting `tree`'s ids in place)
    /// and records the walk. New ids come from `next`, shared by every window,
    /// so an id names one element of one window, ever. `menus`: the walk read
    /// the app's menu bar; when it did not, or the walk was cut at the element
    /// limit, earlier ids it did not reach are kept, carried (a cut walk's for
    /// at most [`CARRY_WALKS`] walks).
    ///
    /// An element keeps an id only on evidence from two independent axes
    /// ([`Self::assign`]'s passes), never on one weak key: when in doubt it
    /// gets a new id and the old one is reported gone, so a model is told to
    /// look again instead of acting on another element.
    pub fn assign(&mut self, tree: &mut UiTree, menus: bool, next: &mut u32) {
        self.walk += 1;
        let walk = self.walk;
        let old = std::mem::take(&mut self.entries);
        let mut by_identity: HashMap<(u64, &str), Vec<u32>> = HashMap::new();
        let mut by_ident: HashMap<(Option<u32>, &str, &str), Vec<u32>> = HashMap::new();
        let mut by_key: HashMap<Key, Vec<u32>> = HashMap::new();
        let mut by_place: HashMap<(Option<u32>, &str, usize), u32> = HashMap::new();
        let mut old_root: Option<(u32, &str)> = None;
        let mut sorted: Vec<(&u32, &Entry)> = old.iter().collect();
        sorted.sort_by_key(|(id, _)| **id);
        for (id, e) in sorted {
            if let Some(h) = e.identity {
                by_identity.entry((h, e.role.as_str())).or_default().push(*id);
            }
            let ident = strong_identifier(&e.identifier);
            if !ident.is_empty() {
                by_ident.entry((e.parent, e.role.as_str(), ident)).or_default().push(*id);
            }
            if !e.label.is_empty() {
                by_key
                    .entry((e.parent, e.role.clone(), e.label.clone(), e.nth))
                    .or_default()
                    .push(*id);
            }
            by_place.insert((e.parent, e.role.as_str(), e.rnth), *id);
            if e.parent.is_none() && !e.menu_bar {
                old_root = Some((*id, e.role.as_str()));
            }
        }
        let flat = flatten(&tree.root);
        let mut ids: Vec<Option<u32>> = vec![None; flat.len()];
        let mut taken: HashSet<u32> = HashSet::new();
        // Pass 1, top-down (parents first): the platform's identity, under a
        // parent that kept its id, plus a second axis. A reference can be
        // reused after its element is freed (an AXUIElement's hash, an AT-SPI
        // path), and AppKit reuses row views and rebuilds menus in place, so
        // identity alone proves nothing:
        // - the same non-empty label; or
        // - no label on either side (not a recycled item, told apart only by
        //   its text); or
        // - a recycled item whose label changed only in a time or count
        //   ("2 min ago"), at the same position.
        // A recycled row's children follow it: under a row that got a new id,
        // nothing keeps an old id (its "Delete" button belongs to another file).
        for (i, (f, e)) in flat.iter().enumerate() {
            if f.parent.is_none() {
                if let Some((id, role)) = old_root
                    && role == e.role
                {
                    if let Some(slot) = ids.get_mut(i) {
                        *slot = Some(id);
                    }
                    taken.insert(id);
                }
                continue;
            }
            let Some(h) = e.identity else { continue };
            let Some(parent) = f.parent.and_then(|p| ids.get(p).copied().flatten()) else {
                continue;
            };
            let recycled = RECYCLED_ROLES.contains(&e.role.as_str());
            let found = by_identity.get(&(h, e.role.as_str())).and_then(|v| {
                v.iter().copied().find(|id| {
                    !taken.contains(id)
                        && old.get(id).is_some_and(|o| {
                            o.parent == Some(parent)
                                && ((!f.label.is_empty()
                                    && o.label == f.label
                                    && same_repeat(o, f))
                                    || (f.label.is_empty()
                                        && o.label.is_empty()
                                        && !recycled
                                        && o.rnth == f.rnth)
                                    || (recycled
                                        && time_drift(&o.label, &f.label)
                                        && o.rnth == f.rnth))
                        })
                })
            });
            if let Some(id) = found {
                if let Some(slot) = ids.get_mut(i) {
                    *slot = Some(id);
                }
                taken.insert(id);
            }
        }
        // Pass 2, over the ids pass 1 left free, parents before children, and
        // only under a parent that kept its id:
        // - a strong identifier unique among the siblings in both trees, for a
        //   role that is not recycled, whose label did not change;
        // - a non-empty label at the same place (role, label, and position
        //   when that role and label repeat among the siblings);
        // - an unlabeled container at the same position whose distinctive
        //   content (labels its same-role siblings do not share) is the same,
        //   every label of it; or, the only container of its role among its
        //   siblings in both trees, sharing at least half its labels (a list
        //   that gained a row is the same list).
        for (i, (f, e)) in flat.iter().enumerate() {
            if ids.get(i).copied().flatten().is_some() {
                continue;
            }
            let recycled = RECYCLED_ROLES.contains(&e.role.as_str());
            let parent = f.parent.and_then(|p| ids.get(p).copied().flatten());
            let parent_kept = parent.is_some_and(|p| old.contains_key(&p));
            let free = |id: &u32| !taken.contains(id);
            let labels_agree =
                |o: &Entry| o.label.is_empty() || f.label.is_empty() || o.label == f.label;
            let found = (parent_kept && !recycled && f.ident_unique)
                .then(|| by_ident.get(&(parent, e.role.as_str(), f.identifier.as_str())))
                .flatten()
                .filter(|v| v.len() == 1)
                .and_then(|v| v.first().copied())
                .filter(|id| free(id) && old.get(id).is_some_and(labels_agree))
                .or_else(|| {
                    (parent_kept && !f.label.is_empty())
                        .then(|| by_key.get(&(parent, e.role.clone(), f.label.clone(), f.nth)))
                        .flatten()
                        .and_then(|v| {
                            v.iter().copied().find(|id| {
                                free(id) && old.get(id).is_some_and(|o| same_repeat(o, f))
                            })
                        })
                })
                .or_else(|| {
                    (parent_kept && f.label.is_empty() && !recycled && !f.content.is_empty())
                        .then(|| by_place.get(&(parent, e.role.as_str(), f.rnth)))
                        .flatten()
                        .copied()
                        .filter(|id| {
                            free(id)
                                && old.get(id).is_some_and(|o| {
                                    o.label.is_empty()
                                        && if o.sole && f.sole {
                                            half_shared(&o.content, &f.content)
                                        } else {
                                            !f.distinct.is_empty() && o.distinct == f.distinct
                                        }
                                })
                        })
                });
            let id = found.unwrap_or_else(|| {
                *next += 1;
                *next
            });
            taken.insert(id);
            if let Some(slot) = ids.get_mut(i) {
                *slot = Some(id);
            }
        }
        let ids: Vec<u32> = ids.into_iter().map(|id| id.unwrap_or_default()).collect();
        let mut entries: HashMap<u32, Entry> = HashMap::with_capacity(flat.len());
        for ((f, e), &id) in flat.iter().zip(&ids) {
            entries.insert(
                id,
                Entry {
                    platform_id: e.id.clone(),
                    walk,
                    parent: f.parent.and_then(|p| ids.get(p).copied()),
                    role: e.role.clone(),
                    name: e.name.clone(),
                    value: e.value.clone(),
                    identifier: e.identifier.clone(),
                    label: f.label.clone(),
                    nth: f.nth,
                    rnth: f.rnth,
                    content: f.content.clone(),
                    distinct: f.distinct.clone(),
                    dups: f.dups,
                    sole: f.sole,
                    identity: e.identity,
                    disabled: e.disabled,
                    focused: e.focused,
                    frame: e.frame,
                    actions: e.actions.clone(),
                    menu_bar: f.menu_bar,
                },
            );
        }
        let has_menu_bar = flat.iter().any(|(f, _)| f.menu_bar);
        for (id, e) in old {
            if taken.contains(&id) {
                continue;
            }
            // Menu bar entries wait for the next walk with the menus; entries
            // a cut walk did not reach wait a few walks, then are gone.
            let carry = if e.menu_bar {
                !(menus && has_menu_bar)
            } else {
                tree.truncated && walk - e.walk <= CARRY_WALKS
            };
            if carry {
                entries.insert(id, e);
            } else {
                self.bury(id, e.summary());
            }
        }
        // Rewrite the tree's ids to the small ones, in the same pre-order.
        let mut order = ids.iter();
        rewrite(&mut tree.root, &mut order);
        self.by_platform = entries
            .iter()
            .filter(|(_, e)| e.walk == walk)
            .map(|(id, e)| (e.platform_id.clone(), *id))
            .collect();
        self.entries = entries;
        self.truncated = tree.truncated;
        if menus && has_menu_bar {
            self.menu_bar = tree.root.children.iter().find(|c| c.role == MENU_BAR).cloned();
        }
        self.tree = Some(tree.root.clone());
    }

    fn bury(&mut self, id: u32, summary: String) {
        self.gone.insert(id, summary);
        self.gone_order.push_back(id);
        while self.gone_order.len() > MAX_GONE {
            if let Some(old) = self.gone_order.pop_front() {
                self.gone.remove(&old);
            }
        }
    }

    pub fn resolve(&self, id: u32) -> Resolved {
        match self.entries.get(&id) {
            Some(e) if e.walk == self.walk => Resolved::Current(e.clone()),
            Some(e) => Resolved::Carried(e.clone()),
            None => match self.gone.get(&id) {
                Some(s) => Resolved::Gone(s.clone()),
                None => Resolved::Unknown,
            },
        }
    }

    pub fn entry(&self, id: u32) -> Option<&Entry> {
        self.entries.get(&id)
    }

    /// The small id of a desktop id of the latest walk.
    pub fn id_of(&self, platform_id: &str) -> Option<u32> {
        self.by_platform.get(platform_id).copied()
    }

    /// The latest tree (small ids, global frames) and whether it was cut short.
    pub fn tree(&self) -> Option<(&Element, bool)> {
        self.tree.as_ref().map(|t| (t, self.truncated))
    }

    /// An element of the latest tree, or of the menu bar of the latest walk
    /// that read it.
    pub fn element(&self, id: u32) -> Option<&Element> {
        let want = id.to_string();
        self.tree
            .as_ref()
            .and_then(|t| find(t, &want))
            .or_else(|| self.menu_bar.as_ref().and_then(|m| find(m, &want)))
    }

    /// What the model was shown of element `id`, compared when it acts on the
    /// id ([`Fingerprint`]). None when the latest walk does not have it.
    pub fn fingerprint(&self, id: u32) -> Option<Fingerprint> {
        let e = self.entries.get(&id)?;
        let mut chain = Vec::new();
        let mut cur = e.parent;
        while let Some(p) = cur {
            if chain.len() > 256 {
                break;
            }
            let pe = self.entries.get(&p)?;
            // The window's own title changes as a document is edited; its id
            // stands for it in the chain.
            let label = if pe.parent.is_none() { String::new() } else { pe.label.clone() };
            chain.push((p, pe.role.clone(), label));
            cur = pe.parent;
        }
        // A recycled row keeps its id through a ticking time or count, so its
        // fingerprint reads the label without them.
        let label = if RECYCLED_ROLES.contains(&e.role.as_str()) {
            without_times(&e.label)
        } else {
            e.label.clone()
        };
        Some(Fingerprint {
            role: e.role.clone(),
            label,
            value_class: value_class(&e.role, &e.value),
            nth: e.nth,
            dups: e.dups,
            identity: e.identity,
            chain,
        })
    }

    /// The ids the window still has: current, or carried.
    pub fn live_ids(&self) -> HashSet<u32> {
        self.entries.keys().copied().collect()
    }

    /// Fingerprints of every element of the latest walk.
    pub fn fingerprints(&self) -> HashMap<u32, Fingerprint> {
        self.entries
            .keys()
            .filter(|id| self.entries.get(id).is_some_and(|e| e.walk == self.walk || e.menu_bar))
            .filter_map(|id| self.fingerprint(*id).map(|f| (*id, f)))
            .collect()
    }

    /// The ids of `id`'s ancestors, nearest first.
    pub fn ancestors(&self, id: u32) -> Vec<u32> {
        let mut out = Vec::new();
        let mut cur = self.entries.get(&id).and_then(|e| e.parent);
        while let Some(p) = cur {
            if out.contains(&p) || out.len() > 256 {
                break;
            }
            out.push(p);
            cur = self.entries.get(&p).and_then(|e| e.parent);
        }
        out
    }
}

pub fn find<'a>(e: &'a Element, id: &str) -> Option<&'a Element> {
    if e.id == id {
        return Some(e);
    }
    e.children.iter().find_map(|c| find(c, id))
}

/// Gives the tree's nodes the ids, in the pre-order of [`flatten`].
fn rewrite(e: &mut Element, ids: &mut std::slice::Iter<'_, u32>) {
    if let Some(id) = ids.next() {
        e.id = id.to_string();
    }
    for c in &mut e.children {
        rewrite(c, ids);
    }
}

/// What an element was when its id was shown to the model: its role, label,
/// the kind of its value, its place among same-role same-label siblings, and
/// its ancestors' ids, roles and labels up to the window. An id whose element
/// no longer matches is refused, never acted on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fingerprint {
    pub role: String,
    pub label: String,
    pub value_class: &'static str,
    pub nth: usize,
    /// How many siblings look the same (role and label), it included.
    pub dups: usize,
    /// The platform's identity for the element (AXUIElement hash, AT-SPI
    /// object, UIA RuntimeId), when it has one.
    pub identity: Option<u64>,
    pub chain: Vec<(u32, String, String)>,
}

impl Fingerprint {
    /// What differs, in words, for the refusal; None when they match.
    pub fn difference(&self, now: &Fingerprint) -> Option<String> {
        if self.role != now.role {
            return Some(format!(
                "it is a {} now, not a {}",
                now.role.replace('_', " "),
                self.role.replace('_', " ")
            ));
        }
        if self.label != now.label {
            return Some(format!("its name is now \"{}\", not \"{}\"", now.label, self.label));
        }
        if self.value_class != now.value_class {
            return Some("its kind of value changed".into());
        }
        if self.nth != now.nth || self.dups != now.dups {
            return Some("its place among elements like it changed".into());
        }
        if self.chain != now.chain {
            return Some("what contains it changed".into());
        }
        // Read both times and different: another element that looks the same
        // (a list swapped for another with a row of the same name).
        if let (Some(a), Some(b)) = (self.identity, now.identity)
            && a != b
        {
            return Some("it is another element that looks the same".into());
        }
        None
    }
}

/// A value's kind: what the person types into a field is always text; for
/// anything else, a number (a slider, a checkbox's 0/1, a progress bar) or
/// text (empty included).
fn value_class(role: &str, v: &str) -> &'static str {
    if super::guards::is_text_input(role) {
        return "text";
    }
    let t = v.trim();
    if !t.is_empty() && t.parse::<f64>().is_ok() { "number" } else { "text" }
}

/// Every window's ids, from one counter: an id is never reused, in any window,
/// and (with a state directory) across restarts of the worker.
#[derive(Default)]
pub struct Registry {
    windows: HashMap<String, WindowIds>,
    order: VecDeque<String>,
    next: u32,
    /// Ids below this are reserved in `store` (a file the counter lives in).
    reserved: u32,
    store: Option<std::path::PathBuf>,
}

/// How many ids are reserved in the store at a time: more than one walk gives
/// out (at most 5,000 window elements and the menu bar).
const RESERVE: u32 = 10_000;

impl Registry {
    /// A registry for a running worker. With `state_dir`, the counter lives
    /// in a file there and ids are reserved ahead in blocks, so no id given
    /// out before a restart is ever given out again. Without it, ids start at
    /// a per-process epoch (tenths of a second since 2026), far past any id an
    /// earlier process of the last years gave out.
    pub fn new(state_dir: Option<&std::path::Path>) -> Self {
        let store = state_dir.map(|d| d.join("element-ids"));
        let epoch = || {
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            (secs.saturating_sub(1_767_225_600) / 10 * 100).min(u64::from(u32::MAX / 2)) as u32
                + 1000
        };
        let start = match &store {
            Some(p) => std::fs::read_to_string(p)
                .ok()
                .and_then(|t| t.trim().parse::<u32>().ok())
                .unwrap_or(0),
            None => epoch(),
        };
        let mut r = Self { next: start, reserved: start, store, ..Self::default() };
        r.reserve();
        r
    }

    /// Reserves the next block of ids in the store before any is given out.
    fn reserve(&mut self) {
        let Some(path) = &self.store else {
            self.reserved = u32::MAX;
            return;
        };
        let upto = self.next.saturating_add(RESERVE);
        let tmp = path.with_extension("tmp");
        let written =
            std::fs::write(&tmp, format!("{upto}\n")).and_then(|()| std::fs::rename(&tmp, path));
        // A store that cannot be written: fall back to the epoch, never reuse.
        if written.is_err() {
            self.store = None;
            self.reserved = u32::MAX;
            return;
        }
        self.reserved = upto;
    }

    fn touch(&mut self, window_id: &str) {
        self.order.retain(|w| w != window_id);
        self.order.push_back(window_id.to_string());
        while self.order.len() > MAX_WINDOWS {
            if let Some(old) = self.order.pop_front() {
                self.windows.remove(&old);
            }
        }
    }

    /// Gives a walk of `window_id` its ids ([`WindowIds::assign`]). `pid`:
    /// the window's process; when it, or the root element's identity, is not
    /// the one the window's ids belong to, the window id names another window
    /// now and its ids start over.
    pub fn assign(&mut self, window_id: &str, tree: &mut UiTree, menus: bool, pid: Option<u32>) {
        self.touch(window_id);
        let owner = pid.map(|p| (p, tree.root.identity));
        if let Some(w) = self.windows.get(window_id)
            && let (Some((op, oroot)), Some((np, nroot))) = (w.owner, owner)
            && (op != np || matches!((oroot, nroot), (Some(a), Some(b)) if a != b))
        {
            self.windows.remove(window_id);
        }
        if self.next.saturating_add(RESERVE / 2) >= self.reserved {
            self.reserve();
        }
        let mut next = self.next;
        let w = self.windows.entry(window_id.to_string()).or_default();
        if owner.is_some() {
            w.owner = owner;
        }
        w.assign(tree, menus, &mut next);
        self.next = next;
    }

    pub fn window(&self, window_id: &str) -> Option<&WindowIds> {
        self.windows.get(window_id)
    }

    /// The window whose latest tree, or an earlier one, had `id`.
    pub fn owner(&self, id: u32) -> Option<&str> {
        self.windows
            .iter()
            .find(|(_, w)| w.entries.contains_key(&id) || w.gone.contains_key(&id))
            .map(|(k, _)| k.as_str())
    }
}
