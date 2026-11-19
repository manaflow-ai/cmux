//! The Files tree's listing of one repository, kept between requests:
//! `git.files.list` and `git.files.search` answer from it, and the
//! repository's file watch (`kept_watch`) keeps it current.
//!
//! It holds what the direct path makes per request (`list`, `files::search`):
//! the paths git lists (`ls-files --cached --others --exclude-standard`), as a
//! tree of their names, and for each name what it is on the disk, looked at
//! through real folders only (`work_tree_entry`). Each node also counts the
//! listed paths at or below it that the daemon reaches (`live`), so a folder
//! listing shows each child whose count is not zero, with no look and no walk
//! below it: a listing costs the folder's children.
//!
//! A change of one path (`apply`) looks at that path again, at its subtree
//! when it is or was a folder, and moves the counts of its folders: it costs
//! what changed and the path's depth, not the tree. An untracked path comes
//! and goes as git's own listing would have it: it is listed while it is
//! there and no ignore rule hides it (`git check-ignore`, which reads no
//! index), and never below a nested repository. A change of the index lists
//! the paths again from the index only (`apply_index`), and touches the paths
//! that came or went. What the tree cannot follow (an ignore file, the
//! watch losing events) is a full rebuild, made by the watch's own thread.
//!
//! A filter keystroke scores the paths below the searched folder; a
//! keystroke that extends the one before scores only that one's matches
//! (every match of the longer query is a match of the shorter one: a
//! subsequence of it). Only the shown results get their matched characters.

use std::collections::HashSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use super::Repository;
use super::files::{Best, Scored, Scorer, touch};
use super::work_tree_entry::{Kind, Tree};

/// No node, no entry.
const NONE: u32 = u32::MAX;
/// The listing git gives at the start is cut past this; a repository whose
/// listing is longer is not kept (the direct path answers it).
const MAX_LISTING_BYTES: usize = 32 * 1024 * 1024;
/// Score-table cells one search may fill (as the direct path).
const MAX_SCORED_CELLS: usize = 64 * 1024 * 1024;
/// Names the check-ignore input files apart.
static INPUT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
/// The root node.
const ROOT: u32 = 0;

/// One name of the tree: a listed path, or a folder above one.
struct Node {
    name: Box<str>,
    parent: u32,
    /// Sorted by name.
    children: Vec<u32>,
    /// What it is on the disk, reached through real folders; `None` when
    /// it is not there or not reached (a folder above it is no real folder).
    kind: Option<Kind>,
    /// The listed entry with this path, or [`NONE`].
    entry: u32,
    /// git's index has this path.
    tracked: bool,
    /// Listed paths at or below this one that are reached: itself (when
    /// listed and there), and, when it is a real folder, its children's.
    live: u32,
    /// Listed paths at or below this one; at zero the node goes.
    listed_below: u32,
}

/// One listed path, for the search.
struct Entry {
    /// From the top folder, as git spells it.
    path: Box<str>,
    node: u32,
}

/// The last search: a keystroke that extends it scores its matches only.
struct Memo {
    below: String,
    query: Vec<char>,
    /// The listed paths at the time ([`KeptTree::generation`]).
    generation: u64,
    /// Entries whose path matched (reached or not); complete only when the
    /// search was not cut.
    matched: Vec<u32>,
}

/// What a search found, as the direct path's reply has it.
pub(super) struct Found {
    /// Paths relative to the searched folder and their matched characters.
    pub(super) results: Vec<(String, Vec<usize>)>,
    pub(super) total: usize,
    pub(super) cut: bool,
}

/// Why a tree was not made.
#[derive(Debug)]
pub(super) enum Unkept {
    /// git failed, or the work tree did not open.
    Failed,
    /// The listing is longer than the tree keeps.
    TooLong,
}

pub(super) struct KeptTree {
    root: PathBuf,
    overrides: Vec<(String, String)>,
    nodes: Vec<Node>,
    free_nodes: Vec<u32>,
    entries: Vec<Option<Entry>>,
    free_entries: Vec<u32>,
    /// Moves on when a path is listed or unlisted: a search's matches hold
    /// while it stays.
    generation: u64,
    memo: Option<Memo>,
    /// Folders an ignore rule hides: nothing below them is listed unless
    /// tracked. Cleared with a rebuild (an ignore file changed).
    ignored: HashSet<Box<str>>,
    /// A digest of the index's path listing at the last read.
    index_digest: Option<(usize, u64)>,
}

/// One path git listed at the start, and whether the index has it.
type Listed = (String, bool);

impl KeptTree {
    /// Lists the repository and looks at each listed path and folder.
    pub(super) fn build(repository: &Repository) -> Result<Self, Unkept> {
        let listing = ["ls-files", "-z", "-t", "--cached", "--others", "--exclude-standard"];
        let output = repository.run(&listing, MAX_LISTING_BYTES).map_err(|_| Unkept::Failed)?;
        if output.truncated {
            return Err(Unkept::TooLong);
        }
        let mut listed: Vec<Listed> = Vec::new();
        for token in output.stdout.split(|byte| *byte == 0) {
            if token.len() < 3 {
                continue;
            }
            let tracked = token[0] != b'?';
            if let Some(path) = candidate(&token[2..]) {
                listed.push((path, tracked));
            }
        }
        listed.sort_unstable();
        listed.dedup_by(|later, earlier| {
            if later.0 == earlier.0 {
                earlier.1 |= later.1;
                true
            } else {
                false
            }
        });
        let mut tree = Self {
            root: repository.root.clone(),
            overrides: repository.overrides.clone(),
            nodes: Vec::with_capacity(listed.len() + listed.len() / 8 + 1),
            free_nodes: Vec::new(),
            entries: Vec::with_capacity(listed.len()),
            free_entries: Vec::new(),
            generation: 0,
            memo: None,
            ignored: HashSet::new(),
            index_digest: None,
        };
        tree.nodes.push(Node::new("".into(), NONE));
        tree.fill(&listed);
        Ok(tree)
    }

    /// Makes the nodes of `listed` (sorted, no repeat), then looks at each.
    fn fill(&mut self, listed: &[Listed]) {
        // The folders of the last path: sorted, the paths of one folder
        // follow each other.
        let mut stack: Vec<u32> = Vec::new();
        for (path, tracked) in listed {
            let parts: Vec<&str> = path.split('/').collect();
            let mut parent = ROOT;
            for (depth, part) in parts.iter().enumerate() {
                let reuse = stack
                    .get(depth)
                    .copied()
                    .filter(|node| &*self.nodes[*node as usize].name == *part);
                let node = match reuse {
                    Some(node) => node,
                    None => {
                        stack.truncate(depth);
                        let node = self.unsorted_child(parent, part).unwrap_or_else(|| {
                            let node = self.new_node(part, parent);
                            self.nodes[parent as usize].children.push(node);
                            node
                        });
                        stack.push(node);
                        node
                    }
                };
                parent = node;
            }
            stack.truncate(parts.len());
            let entry = self.new_entry(path, parent);
            let node = &mut self.nodes[parent as usize];
            node.entry = entry;
            node.tracked = *tracked;
        }
        let mut order: Vec<u32> = Vec::new();
        for node in 0..self.nodes.len() {
            self.sort_children(node);
        }
        // Looks in folder order, so a folder's entries share its opens.
        let mut tree = Tree::open(&self.root);
        self.nodes[ROOT as usize].kind = tree.as_ref().map(|_| Kind::Folder);
        let mut path = String::new();
        self.look_below(ROOT, &mut tree, &mut path, &mut order);
        // Children before their folder: the counts go up.
        for node in order.into_iter().rev() {
            self.recount(node);
        }
        self.recount(ROOT);
        touch(&self.root, self.nodes.len());
    }

    /// Sorts the children of `node` by name.
    fn sort_children(&mut self, node: usize) {
        let mut children = std::mem::take(&mut self.nodes[node].children);
        children.sort_unstable_by(|left, right| {
            self.nodes[*left as usize].name.cmp(&self.nodes[*right as usize].name)
        });
        self.nodes[node].children = children;
    }

    /// While building, the child `name` of `parent` that a path before made,
    /// out of order: a lone name ("a") and its folder ("a/b") have names
    /// between them that start with it ("a-b", "a.c").
    fn unsorted_child(&self, parent: u32, name: &str) -> Option<u32> {
        for child in self.nodes[parent as usize].children.iter().rev() {
            let other = &*self.nodes[*child as usize].name;
            if other == name {
                return Some(*child);
            }
            if !other.starts_with(name) {
                return None;
            }
        }
        None
    }

    /// Looks at every node below `node` (whose path is `path`), depth first;
    /// pushes each to `order`.
    fn look_below(
        &mut self,
        node: u32,
        tree: &mut Option<Tree>,
        path: &mut String,
        order: &mut Vec<u32>,
    ) {
        let folder = self.nodes[node as usize].kind == Some(Kind::Folder);
        let children = self.nodes[node as usize].children.clone();
        for child in children {
            let length = path.len();
            if !path.is_empty() {
                path.push('/');
            }
            path.push_str(&self.nodes[child as usize].name);
            self.nodes[child as usize].kind = if folder { look(tree, path) } else { None };
            order.push(child);
            if !self.nodes[child as usize].children.is_empty() {
                self.look_below(child, tree, path, order);
            }
            path.truncate(length);
        }
    }

    /// Sets `node`'s counts from its own entry and its children's.
    fn recount(&mut self, node: u32) {
        let at = &self.nodes[node as usize];
        let own = u32::from(at.entry != NONE);
        let mut live = u32::from(at.entry != NONE && at.kind.is_some());
        let mut listed = own;
        let folder = at.kind == Some(Kind::Folder);
        for child in &at.children {
            let child = &self.nodes[*child as usize];
            listed += child.listed_below;
            if folder {
                live += child.live;
            }
        }
        let at = &mut self.nodes[node as usize];
        at.live = live;
        at.listed_below = listed;
    }

    fn new_node(&mut self, name: &str, parent: u32) -> u32 {
        let node = Node::new(name.into(), parent);
        match self.free_nodes.pop() {
            Some(free) => {
                self.nodes[free as usize] = node;
                free
            }
            None => {
                self.nodes.push(node);
                u32::try_from(self.nodes.len() - 1).unwrap_or(NONE)
            }
        }
    }

    fn new_entry(&mut self, path: &str, node: u32) -> u32 {
        let entry = Some(Entry { path: path.into(), node });
        match self.free_entries.pop() {
            Some(free) => {
                self.entries[free as usize] = entry;
                free
            }
            None => {
                self.entries.push(entry);
                u32::try_from(self.entries.len() - 1).unwrap_or(NONE)
            }
        }
    }

    /// The child `name` of `parent`.
    fn child(&self, parent: u32, name: &str) -> Option<u32> {
        let children = &self.nodes[parent as usize].children;
        children
            .binary_search_by(|child| (*self.nodes[*child as usize].name).cmp(name))
            .ok()
            .map(|at| children[at])
    }

    /// The node of `path` ("" is the top folder).
    fn find(&self, path: &str) -> Option<u32> {
        if path.is_empty() {
            return Some(ROOT);
        }
        let mut node = ROOT;
        for part in path.split('/') {
            node = self.child(node, part)?;
        }
        Some(node)
    }

    /// The path of `node` from the top folder.
    fn path_of(&self, mut node: u32) -> String {
        let mut parts = Vec::new();
        while node != ROOT && node != NONE {
            parts.push(&*self.nodes[node as usize].name);
            node = self.nodes[node as usize].parent;
        }
        parts.reverse();
        parts.join("/")
    }

    /// The children of the folder `below` (from the top folder) that a
    /// listing shows: name and whether it is a folder. As `list::children`
    /// gives them for the direct path, unsorted.
    pub(super) fn list(&self, below: &str) -> Vec<(&str, bool)> {
        let Some(node) = self.find(below) else { return Vec::new() };
        let children = &self.nodes[node as usize].children;
        touch(&self.root, children.len() + 1);
        if self.nodes[node as usize].kind != Some(Kind::Folder) {
            return Vec::new();
        }
        children
            .iter()
            .map(|child| &self.nodes[*child as usize])
            .filter(|child| child.live > 0)
            .map(|child| (&*child.name, child.kind == Some(Kind::Folder)))
            .collect()
    }

    /// The best `limit` files below `below` for `query` (no space, not
    /// empty), as `files::search` ranks them.
    pub(super) fn search(&mut self, below: &str, query: &[char], limit: usize) -> Found {
        let prefix = if below.is_empty() { String::new() } else { format!("{below}/") };
        let memo = self.memo.take().filter(|memo| {
            memo.below == below
                && memo.generation == self.generation
                && query.len() >= memo.query.len()
                && query[..memo.query.len()] == memo.query[..]
        });
        let mut scorer = Scorer::new(query, MAX_SCORED_CELLS);
        let mut matched = Vec::new();
        let mut ranked: Vec<(u32, i32)> = Vec::new();
        let mut cut = false;
        let mut consider = |id: u32, entry: &Entry, nodes: &[Node]| -> bool {
            let Some(relative) = entry.path.strip_prefix(prefix.as_str()) else { return true };
            match scorer.best(relative) {
                Best::Score(score) => {
                    matched.push(id);
                    if nodes[entry.node as usize].kind.is_some() {
                        ranked.push((id, score));
                    }
                    true
                }
                Best::NoMatch => true,
                Best::OutOfBudget => false,
            }
        };
        let mut touched = 0;
        match &memo {
            Some(memo) => {
                for id in &memo.matched {
                    touched += 1;
                    let Some(entry) = &self.entries[*id as usize] else { continue };
                    if !consider(*id, entry, &self.nodes) {
                        cut = true;
                        break;
                    }
                }
            }
            None => {
                for (id, entry) in self.entries.iter().enumerate() {
                    touched += 1;
                    let Some(entry) = entry else { continue };
                    if !consider(u32::try_from(id).unwrap_or(NONE), entry, &self.nodes) {
                        cut = true;
                        break;
                    }
                }
            }
        }
        touch(&self.root, touched);
        let total = ranked.len();
        // A folder (a submodule) is counted, never shown.
        ranked.retain(|(id, _)| self.node_of(*id).kind != Some(Kind::Folder));
        let relative = |tree: &Self, id: u32| -> usize { tree.entry_path(id).len() - prefix.len() };
        let order = |left: &(u32, i32), right: &(u32, i32)| {
            right
                .1
                .cmp(&left.1)
                .then_with(|| relative(self, left.0).cmp(&relative(self, right.0)))
                .then_with(|| self.entry_path(left.0).cmp(self.entry_path(right.0)))
        };
        if ranked.len() > limit {
            ranked.select_nth_unstable_by(limit, order);
            ranked.truncate(limit);
        }
        ranked.sort_unstable_by(order);
        let mut marker = Scorer::new(query, usize::MAX);
        let results = ranked
            .iter()
            .filter_map(|(id, _)| {
                let path = &self.entry_path(*id)[prefix.len()..];
                match marker.score(path) {
                    Scored::Match(_, matches) => Some((path.to_owned(), matches)),
                    Scored::NoMatch | Scored::OutOfBudget => None,
                }
            })
            .collect();
        if !cut {
            self.memo = Some(Memo {
                below: below.to_owned(),
                query: query.to_vec(),
                generation: self.generation,
                matched,
            });
        }
        Found { results, total, cut }
    }

    fn entry_path(&self, id: u32) -> &str {
        self.entries[id as usize].as_ref().map_or("", |entry| &entry.path)
    }

    fn node_of(&self, id: u32) -> &Node {
        let node = self.entries[id as usize].as_ref().map_or(ROOT, |entry| entry.node);
        &self.nodes[node as usize]
    }

    /// Changes `live` of `node` by `delta`, and of each folder above it
    /// that counts it (a real folder whose count holds its children's).
    fn add_live(&mut self, mut node: u32, delta: i64) {
        if delta == 0 {
            return;
        }
        let mut steps = 0;
        loop {
            steps += 1;
            let at = &mut self.nodes[node as usize];
            at.live = u32::try_from(i64::from(at.live) + delta).unwrap_or(0);
            let parent = at.parent;
            if parent == NONE || self.nodes[parent as usize].kind != Some(Kind::Folder) {
                break;
            }
            node = parent;
        }
        touch(&self.root, steps);
    }

    /// Looks at `node` (path `path`) again, and below it when it is or was
    /// a folder; moves the counts above it.
    fn relook(&mut self, node: u32, path: &str, tree: &mut Option<Tree>) {
        let before = self.nodes[node as usize].live;
        let parent = self.nodes[node as usize].parent;
        let reached = parent == NONE || self.nodes[parent as usize].kind == Some(Kind::Folder);
        self.relook_below(node, path, reached, tree);
        let after = self.nodes[node as usize].live;
        if parent != NONE && self.nodes[parent as usize].kind == Some(Kind::Folder) {
            self.add_live(parent, i64::from(after) - i64::from(before));
        }
    }

    fn relook_below(&mut self, node: u32, path: &str, reached: bool, tree: &mut Option<Tree>) {
        let old = self.nodes[node as usize].kind;
        let new = if node == ROOT {
            tree.as_ref().map(|_| Kind::Folder)
        } else if reached {
            look(tree, path)
        } else {
            None
        };
        self.nodes[node as usize].kind = new;
        touch(&self.root, 1);
        if old == Some(Kind::Folder) || new == Some(Kind::Folder) {
            let folder = new == Some(Kind::Folder);
            for child in self.nodes[node as usize].children.clone() {
                let below = join(path, &self.nodes[child as usize].name);
                self.relook_below(child, &below, folder, tree);
            }
        }
        self.recount(node);
    }

    /// Lists `path` (made of names of real things; tracked or not).
    fn insert(&mut self, path: &str, tracked: bool, tree: &mut Option<Tree>) {
        let mut node = ROOT;
        let mut made = None;
        let mut at = String::new();
        for part in path.split('/') {
            at = join(&at, part);
            node = match self.child(node, part) {
                Some(child) => child,
                None => {
                    let child = self.new_node(part, node);
                    let parent_folder = self.nodes[node as usize].kind == Some(Kind::Folder);
                    self.nodes[child as usize].kind =
                        if parent_folder { look(tree, &at) } else { None };
                    let children = &self.nodes[node as usize].children;
                    let place = children
                        .binary_search_by(|other| (*self.nodes[*other as usize].name).cmp(part))
                        .unwrap_or_else(|place| place);
                    self.nodes[node as usize].children.insert(place, child);
                    made.get_or_insert(child);
                    child
                }
            };
        }
        touch(&self.root, path.split('/').count());
        let new_entry = self.nodes[node as usize].entry == NONE;
        if new_entry {
            let entry = self.new_entry(path, node);
            self.nodes[node as usize].entry = entry;
            self.generation += 1;
        }
        self.nodes[node as usize].tracked |= tracked;
        // Counts: from the listed node up to the first node that was there.
        let top = made.unwrap_or(node);
        let mut at = node;
        let before = self.nodes[top as usize].live;
        loop {
            self.recount(at);
            if at == top {
                break;
            }
            at = self.nodes[at as usize].parent;
        }
        let parent = self.nodes[top as usize].parent;
        let after = self.nodes[top as usize].live;
        if made.is_some() {
            self.add_listed(parent, u32::from(new_entry), true);
            if self.nodes[parent as usize].kind == Some(Kind::Folder) {
                self.add_live(parent, i64::from(after));
            }
        } else {
            self.add_listed(parent, u32::from(new_entry), true);
            if parent != NONE && self.nodes[parent as usize].kind == Some(Kind::Folder) {
                self.add_live(parent, i64::from(after) - i64::from(before));
            }
        }
    }

    /// Adds (`up`) or takes `count` listed paths at `node` and each folder
    /// above it.
    fn add_listed(&mut self, mut node: u32, count: u32, up: bool) {
        let mut steps = 0;
        while node != NONE && count > 0 {
            steps += 1;
            let at = &mut self.nodes[node as usize];
            at.listed_below =
                if up { at.listed_below + count } else { at.listed_below.saturating_sub(count) };
            node = at.parent;
        }
        touch(&self.root, steps);
    }

    /// Unlists the path of `node`; drops the nodes left with nothing listed.
    fn unlist(&mut self, node: u32) {
        let entry = self.nodes[node as usize].entry;
        if entry == NONE {
            return;
        }
        self.entries[entry as usize] = None;
        self.free_entries.push(entry);
        self.generation += 1;
        let before = self.nodes[node as usize].live;
        self.nodes[node as usize].entry = NONE;
        self.nodes[node as usize].tracked = false;
        self.recount(node);
        let after = self.nodes[node as usize].live;
        let parent = self.nodes[node as usize].parent;
        if parent != NONE && self.nodes[parent as usize].kind == Some(Kind::Folder) {
            self.add_live(parent, i64::from(after) - i64::from(before));
        }
        self.add_listed(parent, 1, false);
        // Drop the nodes with nothing listed at or below them.
        let mut at = node;
        while at != ROOT && self.nodes[at as usize].listed_below == 0 {
            let parent = self.nodes[at as usize].parent;
            self.nodes[parent as usize].children.retain(|child| *child != at);
            self.nodes[at as usize] = Node::new("".into(), NONE);
            self.free_nodes.push(at);
            at = parent;
        }
    }

    /// Follows changes of the paths `changed` (from the top folder): what
    /// the watch saw. Each is looked at again, with its subtree when it is
    /// or was a folder, and its untracked paths are listed again. Returns
    /// false when it cannot say (git failed): the caller rebuilds.
    pub(super) fn apply(&mut self, changed: &[String]) -> bool {
        let mut tree = Tree::open(&self.root);
        let mut changed: Vec<&str> = changed.iter().map(String::as_str).collect();
        changed.sort_unstable();
        changed.dedup();
        // A path below another changed one is covered by it.
        let mut covering: Vec<&str> = Vec::new();
        for path in changed {
            if covering.last().is_some_and(|above| below_of(path, above)) {
                continue;
            }
            covering.push(path);
        }
        // Each changed path looked at again, at its deepest node.
        for path in &covering {
            if let Some(node) = self.find(path) {
                self.relook(node, path, &mut tree);
            }
        }
        // The untracked paths at each changed path, listed again. A folder
        // the tree has no node of is asked about first, so a new ignored
        // folder is never walked.
        let mut unsure_folders: Vec<String> = Vec::new();
        let mut walks: Vec<&str> = Vec::new();
        for path in &covering {
            match self.untracked_place(path, &mut tree) {
                Place::Never => continue,
                Place::Here => {}
                Place::Below(folder) => unsure_folders.push(folder),
            }
            if self.find(path).is_none() && look(&mut tree, path) == Some(Kind::Folder) {
                unsure_folders.push((*path).to_owned());
            }
            walks.push(path);
        }
        unsure_folders.sort_unstable();
        unsure_folders.dedup();
        let Some(hidden) = self.ignored_of(&unsure_folders) else { return false };
        for folder in hidden {
            self.ignored.insert(folder.into());
        }
        let mut found: Vec<String> = Vec::new();
        let mut gone: Vec<u32> = Vec::new();
        for path in walks {
            if self.hidden(path) {
                continue;
            }
            let mut here = Vec::new();
            self.walk(path, &mut tree, &mut here);
            let present: HashSet<&str> = here.iter().map(String::as_str).collect();
            if let Some(node) = self.find(path) {
                self.untracked_below(node, &mut |tree, node| {
                    let path = tree.path_of(node);
                    if !present.contains(path.as_str()) {
                        gone.push(node);
                    }
                });
            }
            drop(present);
            for path in here {
                let listed =
                    self.find(&path).is_some_and(|node| self.nodes[node as usize].entry != NONE);
                if !listed {
                    found.push(path);
                }
            }
        }
        for node in gone {
            if self.nodes[node as usize].entry != NONE && !self.nodes[node as usize].tracked {
                self.unlist(node);
            }
        }
        found.sort_unstable();
        found.dedup();
        let Some(hidden) = self.ignored_of(&found) else { return false };
        let hidden: HashSet<String> = hidden.into_iter().collect();
        for path in found {
            if !hidden.contains(&path) {
                self.insert(&path, false, &mut tree);
            }
        }
        true
    }

    /// Calls `each` with every untracked listed node at or below `node`.
    fn untracked_below(&self, node: u32, each: &mut impl FnMut(&Self, u32)) {
        let at = &self.nodes[node as usize];
        if at.entry != NONE && !at.tracked {
            each(self, node);
        }
        touch(&self.root, 1);
        for child in &at.children {
            self.untracked_below(*child, each);
        }
    }

    /// True when a folder above `path` (or it) is one an ignore rule hides.
    fn hidden(&self, path: &str) -> bool {
        let mut at = 0;
        loop {
            let end = path[at..].find('/').map_or(path.len(), |slash| at + slash);
            if self.ignored.contains(&path[..end]) {
                return true;
            }
            if end == path.len() {
                return false;
            }
            at = end + 1;
        }
    }

    /// Where git's untracked listing could have paths at `path`.
    fn untracked_place(&self, path: &str, tree: &mut Option<Tree>) -> Place {
        if self.hidden(path) {
            return Place::Never;
        }
        // No untracked path below a nested repository (a folder with a
        // `.git`): git lists none.
        let mut node = Some(ROOT);
        let mut at = String::new();
        let parts: Vec<&str> = path.split('/').collect();
        let mut first_unknown = None;
        for (depth, part) in parts.iter().enumerate() {
            if depth > 0 && look(tree, &join(&at, ".git")).is_some() {
                return Place::Never;
            }
            at = join(&at, part);
            node = node.and_then(|node| self.child(node, part));
            if node.is_none() && first_unknown.is_none() && depth + 1 < parts.len() {
                first_unknown = Some(at.clone());
            }
        }
        touch(&self.root, parts.len());
        match first_unknown {
            Some(folder) => Place::Below(folder),
            None => Place::Here,
        }
    }

    /// The files git's untracked listing could have at `path`: itself when
    /// it is no folder, else each file below it through real folders, none
    /// below a nested repository. Not yet checked against ignore rules.
    fn walk(&self, path: &str, tree: &mut Option<Tree>, found: &mut Vec<String>) {
        match look(tree, path) {
            None => {}
            Some(Kind::Folder) => {
                if look(tree, &join(path, ".git")).is_some() {
                    return;
                }
                let Ok(names) = std::fs::read_dir(self.root.join(path)) else { return };
                let mut names: Vec<(String, bool)> = names
                    .filter_map(Result::ok)
                    .filter_map(|entry| {
                        let name = entry.file_name().into_string().ok()?;
                        let folder = entry.file_type().ok()?.is_dir();
                        Some((name, folder))
                    })
                    .filter(|(name, _)| name != ".git")
                    .collect();
                names.sort_unstable();
                touch(&self.root, names.len());
                for (name, folder) in names {
                    let below = join(path, &name);
                    if folder {
                        self.walk(&below, tree, found);
                    } else if candidate(below.as_bytes()).is_some() {
                        found.push(below);
                    }
                }
            }
            Some(_) if candidate(path.as_bytes()).is_some() => found.push(path.to_owned()),
            Some(_) => {}
        }
    }

    /// Which of `paths` an ignore rule hides (`git check-ignore --no-index`:
    /// the rules only, no index read). `None` when git failed.
    fn ignored_of(&self, paths: &[String]) -> Option<Vec<String>> {
        if paths.is_empty() {
            return Some(Vec::new());
        }
        // The paths go in through a file, not a pipe: git reads all of it
        // while this thread reads its answer, with no second thread. The
        // file is removed at once; the open descriptor still reads it.
        let input = paths.iter().flat_map(|path| path.bytes().chain([0])).collect::<Vec<u8>>();
        let mark = INPUT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let name = format!("cmux-check-ignore-{}-{mark}", std::process::id());
        let at = std::env::temp_dir().join(name);
        let written = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&at)
            .and_then(|mut file| file.write_all(&input));
        let opened = written.and_then(|()| std::fs::File::open(&at));
        let _ = std::fs::remove_file(&at);
        let stdin = opened.ok()?;
        let mut command = cmux_process::Command::new(cmux_git::run::PROGRAM);
        for (key, value) in &self.overrides {
            command.arg("-c").arg(format!("{key}={value}"));
        }
        let output = command
            .args(["check-ignore", "--no-index", "-z", "--stdin"])
            .current_dir(&self.root)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(cmux_process::Stdio::from(stdin))
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null())
            .output()
            .ok()?;
        // 0: some ignored, 1: none.
        if !matches!(output.status.code(), Some(0 | 1)) {
            return None;
        }
        Some(
            output
                .stdout
                .split(|byte| *byte == 0)
                .filter(|token| !token.is_empty())
                .map(|token| String::from_utf8_lossy(token).into_owned())
                .collect(),
        )
    }

    /// Follows a change of the index: the paths it lists now, from the
    /// index only (`ls-files --cached`, no walk of the work tree). A path
    /// that came is listed; one that went is listed again as git's
    /// untracked listing has it. Unchanged paths cost nothing past the
    /// listing's digest. False when git failed: the caller rebuilds.
    pub(super) fn apply_index(&mut self, repository: &Repository) -> bool {
        let Ok(output) = repository.run(&["ls-files", "-z", "--cached"], MAX_LISTING_BYTES) else {
            return false;
        };
        if output.truncated {
            return false;
        }
        let digest = (output.stdout.len(), digest(&output.stdout));
        if self.index_digest == Some(digest) {
            return true;
        }
        self.index_digest = Some(digest);
        let mut now: Vec<String> =
            output.stdout.split(|byte| *byte == 0).filter_map(candidate).collect();
        now.sort_unstable();
        now.dedup();
        let mut before: Vec<(String, u32)> = self
            .entries
            .iter()
            .flatten()
            .filter(|entry| self.nodes[entry.node as usize].tracked)
            .map(|entry| (entry.path.to_string(), entry.node))
            .collect();
        before.sort_unstable();
        touch(&self.root, now.len() + before.len());
        let mut came = Vec::new();
        let mut went = Vec::new();
        let (mut old, mut new) = (before.into_iter().peekable(), now.into_iter().peekable());
        loop {
            match (old.peek(), new.peek()) {
                (Some((path, _)), Some(next)) if path == next => {
                    old.next();
                    new.next();
                }
                (Some((path, _)), Some(next)) if path < next => went.extend(old.next()),
                (Some(_), None) => went.extend(old.next()),
                (_, Some(_)) => came.extend(new.next()),
                (None, None) => break,
            }
        }
        // A path the index no longer has is listed again as an untracked
        // path would be: while it is there and not ignored.
        let mut again = Vec::new();
        for (path, node) in went {
            self.unlist(node);
            again.push(path);
        }
        let mut tree = Tree::open(&self.root);
        for path in came {
            self.insert(&path, true, &mut tree);
        }
        again.is_empty() || self.apply(&again)
    }
}

/// Where an untracked path could be listed.
enum Place {
    /// Below a nested repository or an ignored folder: never.
    Never,
    /// Every folder above it is in the tree.
    Here,
    /// Below a folder the tree has no node of: listed only when no ignore
    /// rule hides that folder.
    Below(String),
}

impl Node {
    fn new(name: Box<str>, parent: u32) -> Self {
        Self {
            name,
            parent,
            children: Vec::new(),
            kind: None,
            entry: NONE,
            tracked: false,
            live: 0,
            listed_below: 0,
        }
    }
}

/// A path as the direct path takes it from git: UTF-8 with no replacement
/// character, not empty, no folder (a trailing `/`).
fn candidate(bytes: &[u8]) -> Option<String> {
    let path = String::from_utf8_lossy(bytes);
    if path.is_empty() || path.ends_with('/') || path.contains('\u{FFFD}') {
        return None;
    }
    Some(path.into_owned())
}

/// What `path` (from the top folder) is, through real folders.
fn look(tree: &mut Option<Tree>, path: &str) -> Option<Kind> {
    #[cfg(test)]
    super::files::LOOKS.with(|looks| looks.set(looks.get() + 1));
    tree.as_mut()?.entry(Path::new(path)).ok()?.kind()
}

fn join(path: &str, name: &str) -> String {
    if path.is_empty() { name.to_owned() } else { format!("{path}/{name}") }
}

/// True when `path` is below `above` (or is it).
fn below_of(path: &str, above: &str) -> bool {
    above.is_empty()
        || path == above
        || (path.starts_with(above) && path.as_bytes().get(above.len()) == Some(&b'/'))
}

fn digest(bytes: &[u8]) -> u64 {
    use std::hash::Hasher as _;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    hasher.write(bytes);
    hasher.finish()
}
