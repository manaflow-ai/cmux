//! The sidebar layout engine's list and row rules (`sidebar_list_rules`), moved from Swift
//! (`CmuxNextSidebar/Logic/SidebarLayout+DoneFold.swift`, `+SessionTree.swift`, `+Folder.swift`,
//! `+StuckHeader.swift`, `+Viewport.swift`, `+Hover.swift` and `+RevealInSidebar.swift`, plus
//! `SidebarSessionTreeState.hiddenStarted`/`isFolded`, `SidebarTreeRollUp` and
//! `SidebarLayout.row(at:)`).
//!
//! Each request names one rule (`rule`):
//!
//! - `fold`: one list's drawn entries with the workspaces marked Done, archived, settled and
//!   automatic moved behind their fold rows at the end, and past the row limit the rest behind a
//!   "Show N more" row (`foldingDone`). Fold rows are negative indices (`DONE_FOLD`,
//!   `SHOW_MORE`, `ARCHIVED_FOLD`, `SETTLED_FOLD`, `AUTOMATIC_FOLD`) whose depth is their count.
//! - `dragUnfolds`: whether a drag of rows unfolds every list (`dragUnfolds`).
//! - `gapEntry`: the drawn entry a drop gap opens before in a list drawn out of model order.
//! - `pathToMatch`: the groups a filter keeps above a group with a visible workspace.
//! - `treeOrder` and `treeRows`: the session tree's drawn order of one list, each row's depth,
//!   chevron and roll-up (`treeOrder`, `treeChildren`, `treeDescendants`, `treeFold`,
//!   `hiddenStarted`, `isFolded`).
//! - `folderBuckets`: Group by Folder's buckets of a section's loose rows.
//! - `rowAt`, `stuckHeader`, `pill`, `revealExtent`, `onScreen`, `viewportPositions`: the laid-out
//!   rows' geometry (hit test, the pinned group header, the hover pill, the reveal span).
//!
//! Row heights come from the caller (`SidebarLayoutMetrics` and `WorkspaceRowContent` measure
//! them); the rules read laid-out rows (`y`, `height`), never measure text. Localized text stays
//! in Swift.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

/// The index `fold` gives the "Done (N)" row's entry (its depth is the fold's count).
pub const DONE_FOLD: i64 = -1;
/// The index `fold` gives the "Show N more" row's entry (its depth is the count; 0 once opened).
pub const SHOW_MORE: i64 = -2;
/// The index `fold` gives the "Archived (N)" row's entry.
pub const ARCHIVED_FOLD: i64 = -3;
/// The index `fold` gives the "Settled (N)" row's entry.
pub const SETTLED_FOLD: i64 = -4;
/// The index `fold` gives the "Automatic (N)" row's entry.
pub const AUTOMATIC_FOLD: i64 = -5;
/// Space kept around a revealed active row (close-focus.md).
pub const REVEAL_PADDING: f64 = 8.0;

/// One drawn entry of a list: a model index (negative: a fold row) and a depth (a fold row's count).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Entry {
    pub index: i64,
    pub depth: i64,
}

/// What the fold rules read of a workspace.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Workspace {
    pub id: String,
    /// `taskStatus == .done`.
    pub done: bool,
    pub archived: bool,
    /// `agentChip == .needsYou`.
    pub needs_you: bool,
}

/// A list's folds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FoldKind {
    Done,
    Settled,
    Automatic,
    Archived,
}

/// The session tree as the fold rules read it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct FoldTree {
    pub parents: HashMap<String, String>,
    pub hides_started: bool,
}

/// `SidebarLayoutOptions` as the fold rules read it, for one list.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct FoldOptions {
    pub active: Option<String>,
    /// `filterMatches != nil`.
    pub filtering: bool,
    pub folds_done: bool,
    pub folds_archived: bool,
    pub archive_section: bool,
    pub settled: HashSet<String>,
    pub automatic: HashSet<String>,
    pub tree: Option<FoldTree>,
    /// `sidebar.groupRowLimit`; 0 or less: no limit.
    pub row_limit: i64,
    /// This list's folds the person opened (`openDoneFolds`).
    pub open: HashSet<FoldKind>,
    /// This list's "Show N more" row is open (`openShowMore`).
    pub show_more_open: bool,
}

impl FoldOptions {
    fn tree_lets_fold(&self) -> bool {
        self.tree.as_ref().is_none_or(|tree| tree.hides_started)
    }

    fn not_active(&self, ws: &Workspace) -> bool {
        self.active.as_deref() != Some(ws.id.as_str())
    }

    /// Whether `ws` draws behind its list's "Settled (N)" row.
    pub fn settles(&self, ws: &Workspace) -> bool {
        self.settled.contains(&ws.id)
            && self.not_active(ws)
            && !self.filtering
            && self.tree_lets_fold()
    }

    /// Whether `ws` draws behind its list's "Automatic (N)" row.
    pub fn automates(&self, ws: &Workspace) -> bool {
        self.automatic.contains(&ws.id)
            && self.not_active(ws)
            && !self.filtering
            && self.tree_lets_fold()
    }
}

/// `drawn` cut into runs: each top-level entry with the nested entries drawn right after it.
pub fn runs(drawn: &[Entry]) -> Vec<Vec<Entry>> {
    let mut runs: Vec<Vec<Entry>> = Vec::new();
    for entry in drawn {
        match runs.last_mut() {
            Some(run) if entry.depth > 0 => run.push(*entry),
            _ => runs.push(vec![*entry]),
        }
    }
    runs
}

fn at<T>(list: &[T], index: i64) -> Option<&T> {
    usize::try_from(index).ok().and_then(|i| list.get(i))
}

/// `drawn` with its folds (`foldingDone`). `workspaces` and `limits` are by model index (a
/// missing workspace: a group or an item; a missing limit: counted).
pub fn fold(
    drawn: &[Entry],
    workspaces: &[Option<Workspace>],
    limits: &[bool],
    o: &FoldOptions,
) -> Vec<Entry> {
    if o.filtering {
        return drawn.to_vec();
    }
    let ws = |i: i64| at(workspaces, i).and_then(Option::as_ref);
    let mut shown = Vec::new();
    let (mut done, mut settled, mut automatic, mut archived) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for run in runs(drawn) {
        // Swift compares optionals: with no active workspace, a run holding a group or an item
        // entry holds it too.
        let holds_active =
            run.iter().any(|e| ws(e.index).map(|w| w.id.as_str()) == o.active.as_deref());
        let first = run.first().and_then(|e| ws(e.index));
        match first {
            Some(w) if o.folds_archived && w.archived && !holds_active => archived.push(run),
            Some(w) if o.folds_done && w.done && !holds_active => done.push(run),
            Some(w) if o.settles(w) && !holds_active => settled.push(run),
            Some(w) if o.automates(w) && !holds_active => automatic.push(run),
            _ => shown.push(run),
        }
    }
    let mut listed = limiting(&shown, &ws, limits, o);
    for (kind, index, runs) in [
        (FoldKind::Automatic, AUTOMATIC_FOLD, automatic),
        (FoldKind::Settled, SETTLED_FOLD, settled),
        (FoldKind::Done, DONE_FOLD, done),
        (FoldKind::Archived, ARCHIVED_FOLD, archived),
    ] {
        if runs.is_empty() {
            continue;
        }
        let folded: Vec<Entry> = runs.into_iter().flatten().collect();
        listed.push(Entry { index, depth: folded.len() as i64 });
        if o.open.contains(&kind) {
            listed.extend(folded);
        }
    }
    listed
}

fn limiting<'a>(
    shown: &[Vec<Entry>],
    ws: &impl Fn(i64) -> Option<&'a Workspace>,
    limits: &[bool],
    o: &FoldOptions,
) -> Vec<Entry> {
    let limits = |i: i64| at(limits, i).copied().unwrap_or(true);
    let all: Vec<Entry> = shown.iter().flatten().copied().collect();
    let first = |run: &Vec<Entry>| run.first().map_or(0, |e| e.index);
    let limited = shown.iter().filter(|run| limits(first(run))).count() as i64;
    if o.row_limit <= 0 || limited <= o.row_limit + 1 {
        return all;
    }
    if o.show_more_open {
        let mut all = all;
        all.push(Entry { index: SHOW_MORE, depth: 0 });
        return all;
    }
    let mut kept = Vec::new();
    let mut hidden = 0i64;
    let mut n = 0i64;
    for run in shown {
        if !limits(first(run)) {
            kept.extend_from_slice(run);
            continue;
        }
        let stays = run.iter().any(|e| {
            ws(e.index).is_some_and(|w| {
                (o.active.is_some() && o.active.as_deref() == Some(w.id.as_str())) || w.needs_you
            })
        });
        if n < o.row_limit || stays {
            kept.extend_from_slice(run);
        } else {
            hidden += run.len() as i64;
        }
        n += 1;
    }
    if hidden == 0 {
        return all;
    }
    kept.push(Entry { index: SHOW_MORE, depth: hidden });
    kept
}

/// Whether a drag of `dragged` unfolds every list (`dragUnfolds`). `workspaces` are the model's,
/// looked up by id (the first of an id wins).
pub fn drag_unfolds(dragged: &[Workspace], workspaces: &[Workspace], o: &FoldOptions) -> bool {
    let any_fold = o.folds_done
        || o.folds_archived
        || o.archive_section
        || !o.settled.is_empty()
        || !o.automatic.is_empty();
    if !any_fold || o.filtering {
        return false;
    }
    let folds = |w: &Workspace| {
        o.not_active(w)
            && ((o.folds_done && w.done)
                || ((o.folds_archived || o.archive_section) && w.archived)
                || o.settles(w)
                || o.automates(w))
    };
    if dragged.iter().any(folds) {
        return true;
    }
    let Some(parents) = o.tree.as_ref().map(|t| &t.parents).filter(|p| !p.is_empty()) else {
        return false;
    };
    let mut by_id: HashMap<&str, &Workspace> = HashMap::new();
    for w in workspaces {
        by_id.entry(w.id.as_str()).or_insert(w);
    }
    let folds_id = |id: &str| by_id.get(id).is_some_and(|w| folds(w));
    let ancestors = |id: &str| -> Vec<String> {
        let mut seen: HashSet<&str> = HashSet::from([id]);
        let mut found = Vec::new();
        let mut next = parents.get(id);
        while let Some(parent) = next {
            if !seen.insert(parent.as_str()) {
                break;
            }
            found.push(parent.clone());
            next = parents.get(parent);
        }
        found
    };
    let ids: HashSet<&str> = dragged.iter().map(|w| w.id.as_str()).collect();
    if ids.iter().any(|id| ancestors(id).iter().any(|a| folds_id(a))) {
        return true;
    }
    parents.keys().any(|child| {
        !ids.contains(child.as_str())
            && ancestors(child).iter().any(|a| ids.contains(a.as_str()))
            && folds_id(child)
    })
}

/// Where a drop gap goes in a list.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Gap {
    pub section: String,
    pub group: Option<String>,
    pub index: i64,
}

/// The entry a drop gap opens before (`gapEntry`): `Some(None)` after the last entry
/// (`gapAtEnd`), `None` when the list draws in model order or the gap is elsewhere.
pub fn gap_entry(
    drawn: &[Entry],
    gap: Option<&Gap>,
    section: &str,
    group: Option<&str>,
    count: i64,
) -> Option<Option<i64>> {
    let gap = gap?;
    if gap.section != section
        || gap.group.as_deref() != group
        || gap.index > count
        || !drawn.iter().any(|e| e.index < 0 || e.depth > 0)
    {
        return None;
    }
    Some(
        drawn
            .iter()
            .find(|e| e.index < 0 || (e.depth == 0 && e.index >= gap.index))
            .map(|e| e.index),
    )
}

/// A section's group as `pathToMatch` reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct MatchGroup {
    pub id: String,
    pub parent: Option<String>,
    /// The group holds a workspace the filter shows.
    pub visible: bool,
}

/// Every group above a group with a visible workspace, sorted.
pub fn path_to_match(groups: &[MatchGroup]) -> Vec<String> {
    let mut parents: HashMap<&str, Option<&str>> = HashMap::new();
    for g in groups {
        parents.entry(g.id.as_str()).or_insert(g.parent.as_deref());
    }
    let mut path: BTreeSet<String> = BTreeSet::new();
    for g in groups.iter().filter(|g| g.visible) {
        let mut parent = g.parent.as_deref();
        while let Some(id) = parent {
            if !path.insert(id.to_owned()) {
                break;
            }
            parent = parents.get(id).copied().flatten();
        }
    }
    path.into_iter().collect()
}

/// What an agent is doing, as a row's roll-up counts it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentState {
    #[default]
    Idle,
    FinishedUnread,
    Running,
    Failed,
    Blocked,
}

/// A folded parent's counts of the states under it (`SidebarTreeRollUp`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RollUp {
    pub blocked: i64,
    pub failed: i64,
    pub running: i64,
    pub unread: i64,
    pub total: i64,
}

impl RollUp {
    pub fn of(states: impl IntoIterator<Item = AgentState>) -> Self {
        let mut r = RollUp::default();
        for state in states {
            r.total += 1;
            match state {
                AgentState::Blocked => r.blocked += 1,
                AgentState::Failed => r.failed += 1,
                AgentState::Running => r.running += 1,
                AgentState::FinishedUnread => r.unread += 1,
                AgentState::Idle => {}
            }
        }
        r
    }

    fn is_empty(&self) -> bool {
        self.total == 0
            && self.blocked == 0
            && self.failed == 0
            && self.running == 0
            && self.unread == 0
    }
}

/// A tree parent's chevron.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TreeFold {
    Expanded,
    Collapsed,
}

/// `SidebarSessionTreeState` as the tree rules read it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SessionTree {
    pub parents: HashMap<String, String>,
    pub collapsed: HashSet<String>,
    pub opened: HashSet<String>,
    pub folds_deep: bool,
    pub hides_started: bool,
    pub keeps: HashSet<String>,
}

impl SessionTree {
    /// Whether the parent `id`, drawn at `depth`, folds its subtree.
    pub fn is_folded(&self, id: &str, depth: i64) -> bool {
        self.collapsed.contains(id) || (self.folds_deep && depth > 0 && !self.opened.contains(id))
    }

    /// The agent-started sessions `hidesStarted` leaves out of the list, as indices into `ids`.
    pub fn hidden_started(&self, ids: &[Option<String>], states: &[AgentState]) -> BTreeSet<usize> {
        let mut hidden = BTreeSet::new();
        if !self.hides_started || self.parents.is_empty() {
            return hidden;
        }
        let mut kept: HashSet<&str> = HashSet::new();
        for (index, id) in ids.iter().enumerate() {
            let Some(id) = id.as_deref() else { continue };
            let blocked = states.get(index) == Some(&AgentState::Blocked);
            if !self.parents.contains_key(id) || !(self.keeps.contains(id) || blocked) {
                continue;
            }
            let mut current = Some(id);
            while let Some(next) = current {
                if !self.parents.contains_key(next) || !kept.insert(next) {
                    break;
                }
                current = self.parents.get(next).map(String::as_str);
            }
        }
        for (index, id) in ids.iter().enumerate() {
            if let Some(id) = id.as_deref()
                && self.parents.contains_key(id)
                && !kept.contains(id)
            {
                hidden.insert(index);
            }
        }
        hidden
    }
}

/// Each workspace's children among `ids`, as indices in the list's order (`treeChildren`).
pub fn tree_children(
    ids: &[Option<String>],
    parents: &HashMap<String, String>,
) -> HashMap<String, Vec<usize>> {
    let present: HashSet<&str> = ids.iter().flatten().map(String::as_str).collect();
    let mut rooted: HashMap<&str, bool> = HashMap::new();
    let mut children: HashMap<String, Vec<usize>> = HashMap::new();
    for (index, id) in ids.iter().enumerate() {
        let Some(id) = id.as_deref() else { continue };
        let Some(parent) = parents.get(id).filter(|p| present.contains(p.as_str())) else {
            continue;
        };
        // `reachesRoot(id)`, remembered per node.
        let mut path: Vec<&str> = Vec::new();
        let mut on_path: HashSet<&str> = HashSet::new();
        let mut next = Some(id);
        let mut answer = true;
        while let Some(current) = next {
            if let Some(known) = rooted.get(current) {
                answer = *known;
                break;
            }
            if !on_path.insert(current) {
                answer = false;
                break;
            }
            path.push(current);
            next = parents.get(current).map(String::as_str).filter(|p| present.contains(p));
        }
        for node in path {
            rooted.insert(node, answer);
        }
        if answer {
            children.entry(parent.clone()).or_default().push(index);
        }
    }
    children
}

/// Every descendant of `id` among `ids` (`treeDescendants`), in its stack order.
pub fn tree_descendants(
    id: &str,
    ids: &[Option<String>],
    children: &HashMap<String, Vec<usize>>,
) -> Vec<usize> {
    let mut found = Vec::new();
    let mut stack = children.get(id).cloned().unwrap_or_default();
    while let Some(index) = stack.pop() {
        found.push(index);
        if let Some(Some(child)) = ids.get(index) {
            stack.extend(children.get(child).into_iter().flatten().copied());
        }
    }
    found
}

/// The session tree's drawn order of one list (`treeOrder`). `folded` says whether a parent drawn
/// at a depth folds; `skipped` entries draw no row, nor any of their descendants.
pub fn tree_order(
    ids: &[Option<String>],
    parents: Option<&HashMap<String, String>>,
    folded: &dyn Fn(&str, i64) -> bool,
    known: Option<&HashMap<String, Vec<usize>>>,
    skipped: &BTreeSet<usize>,
) -> Vec<Entry> {
    let Some(parents) = parents.filter(|p| !p.is_empty()) else {
        return (0..ids.len()).map(|i| Entry { index: i as i64, depth: 0 }).collect();
    };
    let computed;
    let children = match known {
        Some(known) => known,
        None => {
            computed = tree_children(ids, parents);
            &computed
        }
    };
    let mut nested: HashSet<usize> = children.values().flatten().copied().collect();
    nested.extend(skipped.iter().copied());
    let mut order = Vec::with_capacity(ids.len());
    for root in (0..ids.len()).filter(|i| !nested.contains(i)) {
        // Depth first, children in list order: a stack, so a deep chain never grows the call stack.
        let mut stack = vec![(root, 0i64)];
        while let Some((index, depth)) = stack.pop() {
            order.push(Entry { index: index as i64, depth });
            let Some(Some(id)) = ids.get(index) else { continue };
            if folded(id, depth) {
                continue;
            }
            for child in children.get(id).into_iter().flatten().rev() {
                stack.push((*child, depth + 1));
            }
        }
    }
    order
}

/// One loose row as the session tree draws it (`TreeRow`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeRow {
    pub index: i64,
    pub depth: i64,
    pub fold: Option<TreeFold>,
    pub roll_up: Option<RollUp>,
}

/// One list's rows in the session tree's drawn order (`treeRows`). `states` by index (missing: idle).
pub fn tree_rows(
    ids: &[Option<String>],
    states: &[AgentState],
    live: Option<&SessionTree>,
    filtering: bool,
) -> Vec<TreeRow> {
    let state = |i: usize| states.get(i).copied().unwrap_or_default();
    let skipped = match live {
        Some(tree) if !filtering => tree.hidden_started(ids, states),
        _ => BTreeSet::new(),
    };
    let tree = live.map(|shown| {
        let mut tree = shown.clone();
        if filtering || shown.hides_started {
            tree.collapsed.clear();
            tree.folds_deep = false;
        }
        tree
    });
    let mut children = tree.as_ref().map(|t| tree_children(ids, &t.parents)).unwrap_or_default();
    if !skipped.is_empty() {
        children = children
            .into_iter()
            .filter_map(|(id, kids)| {
                let shown: Vec<usize> = kids.into_iter().filter(|k| !skipped.contains(k)).collect();
                (!shown.is_empty()).then_some((id, shown))
            })
            .collect();
    }
    let folded = |id: &str, depth: i64| tree.as_ref().is_some_and(|t| t.is_folded(id, depth));
    let order =
        tree_order(ids, tree.as_ref().map(|t| &t.parents), &folded, Some(&children), &skipped);
    order
        .into_iter()
        .map(|entry| {
            let mut row =
                TreeRow { index: entry.index, depth: entry.depth, fold: None, roll_up: None };
            let Some(tree) = tree.as_ref().filter(|t| !t.hides_started) else { return row };
            let Some(Some(id)) = at(ids, entry.index) else { return row };
            if children.get(id).is_none_or(Vec::is_empty) {
                return row;
            }
            if !tree.is_folded(id, entry.depth) {
                row.fold = Some(TreeFold::Expanded);
                return row;
            }
            let roll = RollUp::of(tree_descendants(id, ids, &children).into_iter().map(state));
            row.fold = Some(TreeFold::Collapsed);
            row.roll_up = (!roll.is_empty()).then_some(roll);
            row
        })
        .collect()
}

/// Group by Folder's buckets (`folderBuckets`): `folders` by node (None: not a workspace; a
/// workspace without a folder passes ""). The folders in first-seen order, "" last.
pub fn folder_buckets(folders: &[Option<String>]) -> (Vec<String>, BTreeMap<String, Vec<usize>>) {
    let mut order: Vec<String> = Vec::new();
    let mut members: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (index, folder) in folders.iter().enumerate() {
        let Some(folder) = folder else { continue };
        if !members.contains_key(folder) {
            order.push(folder.clone());
        }
        members.entry(folder.clone()).or_default().push(index);
    }
    if let Some(none) = order.iter().position(String::is_empty)
        && none != order.len() - 1
    {
        let moved = order.remove(none);
        order.push(moved);
    }
    (order, members)
}

/// A laid-out row's kind (`SidebarRowKey`'s case).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RowKind {
    Workspace,
    Group,
    Section,
    Folder,
    Status,
    ListHeader,
    Item,
    Block,
    #[default]
    Other,
}

impl RowKind {
    fn is_reveal_header(self) -> bool {
        matches!(self, Self::Section | Self::Group | Self::Folder | Self::Status | Self::ListHeader)
    }

    fn is_reveal_stop(self) -> bool {
        matches!(self, Self::Workspace | Self::Item | Self::Block)
    }
}

/// A laid-out row: its key (`kind`, `id`), frame and group.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Row {
    pub kind: RowKind,
    pub id: String,
    pub y: f64,
    pub height: f64,
    pub group: Option<String>,
    pub collapsed: bool,
}

impl Row {
    fn max_y(&self) -> f64 {
        self.y + self.height
    }

    fn is_workspace_stop(&self) -> bool {
        match self.kind {
            RowKind::Workspace => true,
            RowKind::Group => self.collapsed,
            _ => false,
        }
    }

    fn is(&self, kind: RowKind, id: &str) -> bool {
        self.kind == kind && self.id == id
    }
}

/// Index of the last row whose top is at or above `y` (rows sorted by y).
pub fn last_index(rows: &[Row], y: f64) -> Option<usize> {
    rows.partition_point(|row| row.y <= y).checked_sub(1)
}

fn position(rows: &[Row], kind: RowKind, id: &str) -> Option<usize> {
    rows.iter().position(|row| row.is(kind, id))
}

/// The row whose hit area holds `y` (`row(at:)`): its frame plus half the spacing to a neighbor.
pub fn row_at(rows: &[Row], row_spacing: f64, y: f64) -> Option<usize> {
    let i = last_index(rows, y)?;
    let row = rows.get(i)?;
    if y < row.max_y() {
        return Some(i);
    }
    let next = rows.get(i + 1)?;
    let gap = next.y - row.max_y();
    if !(gap > 0.0 && gap <= row_spacing) {
        return None;
    }
    Some(if y < row.max_y() + gap / 2.0 { i } else { i + 1 })
}

/// The group header pinned at the list's top `top` (`stuckHeader`): its position and drawn y.
/// `top_level` maps a nested group to its top-level group (missing: itself).
pub fn stuck_header(
    rows: &[Row],
    top: f64,
    top_level: &HashMap<String, String>,
) -> Option<(usize, f64)> {
    let lift = |g: &str| top_level.get(g).cloned().unwrap_or_else(|| g.to_owned());
    let first = last_index(rows, top)?;
    let group = lift(rows.get(first)?.group.as_deref()?);
    let position = position(rows, RowKind::Group, &group).filter(|p| *p <= first)?;
    let header = rows.get(position)?;
    if header.y.partial_cmp(&top) != Some(std::cmp::Ordering::Less) || header.collapsed {
        return None;
    }
    let in_group = |i: usize| {
        rows.get(i).and_then(|r| r.group.as_deref()).map(lift).as_deref() == Some(group.as_str())
    };
    let mut last = last_index(rows, top + header.height).unwrap_or(first);
    while last > first && !in_group(last) {
        last -= 1;
    }
    let goes_on = last + 1 < rows.len() && in_group(last + 1);
    let end = rows.get(last)?.max_y();
    let y = if goes_on { top } else { top.min(end - header.height) };
    (y + header.height > top).then_some((position, y))
}

/// A rectangle.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A point.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// `rect` inset by `inset` top and bottom, corners rounded by `corner_radius`, holds `point`.
pub fn pill(rect: Rect, inset: f64, corner_radius: f64, point: Point) -> bool {
    let (min_x, min_y) = (rect.x, rect.y + inset);
    let (w, h) = (rect.width, rect.height - inset * 2.0);
    let (max_x, max_y) = (min_x + w, min_y + h);
    if !(w > 0.0 && h > 0.0)
        || point.x < min_x
        || point.x >= max_x
        || point.y < min_y
        || point.y >= max_y
    {
        return false;
    }
    let r = corner_radius.min(w / 2.0).min(h / 2.0).max(0.0);
    let cx = point.x.max(min_x + r).min(max_x - r);
    let cy = point.y.max(min_y + r).min(max_y - r);
    let (dx, dy) = (point.x - cx, point.y - cy);
    dx * dx + dy * dy <= r * r
}

/// A span along the list.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Span {
    pub start: f64,
    pub length: f64,
}

/// The extent a reveal of row (`kind`, `id`) shows (`revealExtent`): `span` (the row, or an item
/// inside a block row) with the headers above it, the list's top when no workspace stop draws
/// above it, and the list's end when nothing lies below it; context that does not fit in `height`
/// drops, the end first.
pub fn reveal_extent(
    rows: &[Row],
    kind: RowKind,
    id: &str,
    span: Option<Span>,
    height: f64,
    total_height: f64,
) -> Option<Span> {
    let first = position(rows, kind, id)?;
    let row = rows.get(first)?;
    let index = last_index(rows, row.y)
        .filter(|i| rows.get(*i).is_some_and(|r| r.is(kind, id)))
        .unwrap_or(first);
    let start = span.map_or(row.y, |s| s.start);
    let end = start + span.map_or(row.height, |s| s.length);
    let mut lead = if kind == RowKind::Block { row.y } else { start };
    let mut above = index;
    while let Some(prev) = above.checked_sub(1).and_then(|i| rows.get(i)) {
        if !prev.kind.is_reveal_header() || (prev.is_workspace_stop() && prev.group != row.group) {
            break;
        }
        lead = prev.y;
        above -= 1;
    }
    if !rows.iter().take(index).any(Row::is_workspace_stop) {
        lead = 0.0;
    }
    let below =
        rows.iter().skip(index + 1).any(|r| r.kind.is_reveal_stop() || r.is_workspace_stop());
    let trail = if below { end } else { total_height.max(end) };
    let fits = |lead: f64, trail: f64| trail - lead + REVEAL_PADDING * 2.0 <= height;
    let (l, t) = if fits(lead, trail) {
        (lead, trail)
    } else if fits(lead, end) {
        (lead, end)
    } else {
        (start, end)
    };
    Some(Span { start: l, length: t - l })
}

/// Whether row (`kind`, `id`) is drawn and at least partly inside the viewport (`isOnScreen`).
pub fn on_screen(rows: &[Row], kind: RowKind, id: &str, offset: f64, height: f64) -> bool {
    rows.iter()
        .find(|r| r.is(kind, id))
        .is_some_and(|r| r.y + r.height > offset && r.y < offset + height)
}

/// The rows that end after `lower` and start before `upper` (`viewportPositions`). With a drag
/// gap (`gap`) rows may be out of order, so every row is read.
pub fn viewport_positions(rows: &[Row], gap: bool, lower: f64, upper: f64) -> Vec<usize> {
    if gap {
        return (0..rows.len())
            .filter(|i| rows.get(*i).is_some_and(|r| r.max_y() > lower && r.y < upper))
            .collect();
    }
    let mut first = last_index(rows, lower).map_or(0, |i| i + 1);
    while first > 0 && rows.get(first - 1).is_some_and(|r| r.max_y() > lower) {
        first -= 1;
    }
    let mut positions = Vec::new();
    let mut index = first;
    while let Some(row) = rows.get(index).filter(|r| r.y < upper) {
        if row.max_y() > lower {
            positions.push(index);
        }
        index += 1;
    }
    positions
}

/// One rule's request.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "rule", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Request {
    Fold {
        drawn: Vec<Entry>,
        #[serde(default)]
        workspaces: Vec<Option<Workspace>>,
        #[serde(default)]
        limits: Vec<bool>,
        #[serde(default)]
        options: FoldOptions,
    },
    DragUnfolds {
        dragged: Vec<Workspace>,
        #[serde(default)]
        workspaces: Vec<Workspace>,
        #[serde(default)]
        options: FoldOptions,
    },
    GapEntry {
        drawn: Vec<Entry>,
        gap: Option<Gap>,
        section: String,
        group: Option<String>,
        count: i64,
    },
    PathToMatch {
        groups: Vec<MatchGroup>,
    },
    TreeOrder {
        ids: Vec<Option<String>>,
        parents: Option<HashMap<String, String>>,
        #[serde(default)]
        collapsed: HashSet<String>,
    },
    TreeRows {
        ids: Vec<Option<String>>,
        #[serde(default)]
        states: Vec<AgentState>,
        tree: Option<SessionTree>,
        #[serde(default)]
        filtering: bool,
    },
    FolderBuckets {
        folders: Vec<Option<String>>,
    },
    RowAt {
        rows: Vec<Row>,
        row_spacing: f64,
        y: f64,
    },
    StuckHeader {
        rows: Vec<Row>,
        top: f64,
        #[serde(default)]
        top_level: HashMap<String, String>,
    },
    Pill {
        rect: Rect,
        inset: f64,
        corner_radius: f64,
        point: Point,
    },
    RevealExtent {
        rows: Vec<Row>,
        kind: RowKind,
        id: String,
        span: Option<Span>,
        height: f64,
        total_height: f64,
    },
    OnScreen {
        rows: Vec<Row>,
        kind: RowKind,
        id: String,
        offset: f64,
        height: f64,
    },
    ViewportPositions {
        rows: Vec<Row>,
        #[serde(default)]
        gap: bool,
        lower: f64,
        upper: f64,
    },
}

/// A stuck header: its row's position and drawn y.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Header {
    pub position: usize,
    pub y: f64,
}

/// One rule's answer.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(untagged, rename_all_fields = "camelCase")]
pub enum Response {
    Drawn {
        drawn: Vec<Entry>,
    },
    Unfolds {
        unfolds: bool,
    },
    /// `entry` null and `at_end` false: the gap opens by model index.
    GapEntry {
        entry: Option<i64>,
        at_end: bool,
    },
    Path {
        path: Vec<String>,
    },
    Order {
        order: Vec<Entry>,
    },
    TreeRows {
        rows: Vec<TreeRow>,
    },
    FolderBuckets {
        folders: Vec<String>,
        members: BTreeMap<String, Vec<usize>>,
    },
    Position {
        position: Option<usize>,
    },
    Header {
        header: Option<Header>,
    },
    Contains {
        contains: bool,
    },
    Extent {
        extent: Option<Span>,
    },
    OnScreen {
        on_screen: bool,
    },
    Positions {
        positions: Vec<usize>,
    },
}

/// Answers one rule.
pub fn respond(request: &Request) -> Response {
    match request {
        Request::Fold { drawn, workspaces, limits, options } => {
            Response::Drawn { drawn: fold(drawn, workspaces, limits, options) }
        }
        Request::DragUnfolds { dragged, workspaces, options } => {
            Response::Unfolds { unfolds: drag_unfolds(dragged, workspaces, options) }
        }
        Request::GapEntry { drawn, gap, section, group, count } => {
            match gap_entry(drawn, gap.as_ref(), section, group.as_deref(), *count) {
                None => Response::GapEntry { entry: None, at_end: false },
                Some(None) => Response::GapEntry { entry: None, at_end: true },
                Some(Some(index)) => Response::GapEntry { entry: Some(index), at_end: false },
            }
        }
        Request::PathToMatch { groups } => Response::Path { path: path_to_match(groups) },
        Request::TreeOrder { ids, parents, collapsed } => {
            let folded = |id: &str, _: i64| collapsed.contains(id);
            Response::Order {
                order: tree_order(ids, parents.as_ref(), &folded, None, &BTreeSet::new()),
            }
        }
        Request::TreeRows { ids, states, tree, filtering } => {
            Response::TreeRows { rows: tree_rows(ids, states, tree.as_ref(), *filtering) }
        }
        Request::FolderBuckets { folders } => {
            let (folders, members) = folder_buckets(folders);
            Response::FolderBuckets { folders, members }
        }
        Request::RowAt { rows, row_spacing, y } => {
            Response::Position { position: row_at(rows, *row_spacing, *y) }
        }
        Request::StuckHeader { rows, top, top_level } => Response::Header {
            header: stuck_header(rows, *top, top_level).map(|(position, y)| Header { position, y }),
        },
        Request::Pill { rect, inset, corner_radius, point } => {
            Response::Contains { contains: pill(*rect, *inset, *corner_radius, *point) }
        }
        Request::RevealExtent { rows, kind, id, span, height, total_height } => Response::Extent {
            extent: reveal_extent(rows, *kind, id, *span, *height, *total_height),
        },
        Request::OnScreen { rows, kind, id, offset, height } => {
            Response::OnScreen { on_screen: on_screen(rows, *kind, id, *offset, *height) }
        }
        Request::ViewportPositions { rows, gap, lower, upper } => {
            Response::Positions { positions: viewport_positions(rows, *gap, *lower, *upper) }
        }
    }
}

#[cfg(test)]
#[path = "sidebar_list_rules_tests.rs"]
mod tests;
