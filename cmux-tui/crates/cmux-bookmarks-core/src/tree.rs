//! One browser profile's bookmark tree in memory and the op reducer of
//! `bookmarks-v1`. Each op is the daemon's (`personal_bookmarks/ops.rs`)
//! step for step: the same checks in the same order with the same
//! messages, the same index clamping, the same result JSON. Every check
//! runs before the first change, so a refused op leaves the tree as it was
//! (the daemon's transaction).
//!
//! What only the daemon can check: that a profile exists in
//! `browser_profiles` (the tree holds one profile and refuses another as
//! unknown), that an id is free in every profile (the tree sees its own),
//! a folder icon's syntax and that its stored asset exists (the tree takes
//! any icon on a folder). A daemon refusal of these comes back as the
//! command's error.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde_json::{Value, json};

use crate::{
    BOOKMARKS_BAR, Bookmark, BookmarkError, BookmarkImport, BookmarkImportNode, BookmarkInput,
    BookmarkOp, BookmarkUpdate, MAX_BOOKMARK_DEPTH, MAX_BOOKMARKS_PER_PROFILE, OTHER_BOOKMARKS,
    ensure_valid, is_root, stored_ms, validate_bookmark_id, validate_import_nodes, validate_key,
    validate_kind_url, validate_profile_shape, validate_title, validate_url,
};

/// Levels the daemon's recursive subtree query reaches (`level <= 66`, then
/// one more).
const SUBTREE_LEVELS: usize = 67;
/// Longest parent chain walked before the chain counts as broken.
const MAX_PARENT_CHAIN: usize = MAX_BOOKMARK_DEPTH + 1;
/// Ids tried per minted id before an import is refused.
const MINT_ATTEMPTS: usize = 64;

/// One browser profile's nodes and each parent's ordered children. Every
/// node's `index` is its position among its siblings.
#[derive(Debug, Clone, Default)]
pub struct Tree {
    profile: String,
    nodes: HashMap<String, Bookmark>,
    children: HashMap<String, Vec<String>>,
}

/// Two trees are equal when they list the same nodes in the same order.
impl PartialEq for Tree {
    fn eq(&self, other: &Self) -> bool {
        self.profile == other.profile && self.listing() == other.listing()
    }
}

impl Eq for Tree {}

/// One applied op: the daemon's wire result (without `replayed`) and
/// whether the tree changed (the daemon then bumps `bookmarks_revision`).
#[derive(Debug, Clone, PartialEq)]
pub struct Applied {
    pub result: Value,
    pub changed: bool,
}

impl Tree {
    /// An empty tree of `profile`.
    pub fn new(profile: impl Into<String>) -> Self {
        Self { profile: profile.into(), ..Self::default() }
    }

    /// A tree from a `list-bookmarks` listing. Siblings keep their `index`
    /// order (listing order breaks ties), every node takes this profile, and
    /// a repeated id keeps its first node.
    pub fn from_listing(
        profile: impl Into<String>,
        listing: impl IntoIterator<Item = Bookmark>,
    ) -> Self {
        let mut tree = Self::new(profile);
        let mut groups = HashMap::<String, Vec<(usize, usize, String)>>::new();
        for (order, mut node) in listing.into_iter().enumerate() {
            if tree.nodes.contains_key(&node.id) {
                continue;
            }
            node.browser_profile_id.clone_from(&tree.profile);
            groups.entry(node.parent.clone()).or_default().push((
                node.index,
                order,
                node.id.clone(),
            ));
            tree.nodes.insert(node.id.clone(), node);
        }
        for (parent, mut members) in groups {
            members.sort_unstable();
            tree.children
                .insert(parent.clone(), members.into_iter().map(|(_, _, id)| id).collect());
            tree.reindex(&parent);
        }
        tree
    }

    pub fn profile(&self) -> &str {
        &self.profile
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<&Bookmark> {
        self.nodes.get(id)
    }

    /// The children of a root or folder, in order.
    pub fn children(&self, parent: &str) -> Vec<&Bookmark> {
        self.children
            .get(parent)
            .map(|ids| ids.iter().filter_map(|id| self.nodes.get(id)).collect())
            .unwrap_or_default()
    }

    /// The tree as `list-bookmarks` lists it: depth-first pre-order, the
    /// `bar` tree, then the `other` tree; nodes no root reaches follow,
    /// grouped by parent.
    pub fn listing(&self) -> Vec<Bookmark> {
        let mut groups = self
            .children
            .iter()
            .filter(|(_, ids)| !ids.is_empty())
            .map(|(parent, ids)| (parent.as_str(), ids))
            .collect::<BTreeMap<_, _>>();
        let mut ordered = Vec::with_capacity(self.nodes.len());
        let mut stack = Vec::<&str>::new();
        for root in [OTHER_BOOKMARKS, BOOKMARKS_BAR] {
            if let Some(ids) = groups.remove(root) {
                stack.extend(ids.iter().rev().map(String::as_str));
            }
        }
        while let Some(id) = stack.pop() {
            if let Some(ids) = groups.remove(id) {
                stack.extend(ids.iter().rev().map(String::as_str));
            }
            if let Some(node) = self.nodes.get(id) {
                ordered.push(node.clone());
            }
        }
        for ids in groups.into_values() {
            ordered.extend(ids.iter().filter_map(|id| self.nodes.get(id)).cloned());
        }
        ordered
    }

    /// Applies one op, or refuses it and changes nothing. `now_ms` is the
    /// creation time of nodes that name none; `mint` makes the ids of
    /// created nodes that name none (it may repeat; a used id is skipped).
    pub fn apply(
        &mut self,
        op: BookmarkOp,
        now_ms: u64,
        mint: &mut dyn FnMut() -> String,
    ) -> Result<Applied, BookmarkError> {
        Ok(match op {
            BookmarkOp::Create(input) => {
                let (bookmark, changed) = self.create(input, now_ms, mint)?;
                Applied { result: json!({"bookmark": bookmark, "changed": changed}), changed }
            }
            BookmarkOp::Update { bookmark, update } => {
                let (bookmark, changed) = self.update(&bookmark, update)?;
                Applied { result: json!({"bookmark": bookmark, "changed": changed}), changed }
            }
            BookmarkOp::Move { bookmark, parent, index } => {
                let (bookmark, changed) = self.move_to(&bookmark, &parent, index)?;
                Applied { result: json!({"bookmark": bookmark, "changed": changed}), changed }
            }
            BookmarkOp::Delete { bookmark } => {
                let deleted = self.delete(&bookmark)?;
                Applied { result: json!({"deleted": deleted}), changed: true }
            }
            BookmarkOp::Import(import) => {
                let (root_ids, count) = self.import(import, now_ms, mint)?;
                Applied { result: json!({"root_ids": root_ids, "count": count}), changed: true }
            }
        })
    }

    // MARK: Ops

    fn create(
        &mut self,
        input: BookmarkInput,
        now_ms: u64,
        mint: &mut dyn FnMut() -> String,
    ) -> Result<(Bookmark, bool), BookmarkError> {
        let id = match input.id {
            Some(id) => {
                validate_bookmark_id(&id)?;
                id
            }
            None => self.mint_ids(1, mint)?.pop().unwrap_or_default(),
        };
        validate_profile_shape(&input.browser_profile_id)?;
        validate_kind_url(&input.kind, input.url.as_deref())?;
        validate_title(&input.title)?;
        validate_key("favicon_key", input.favicon_key.as_deref())?;
        validate_key("source_key", input.source_key.as_deref())?;
        ensure_valid!(InvalidKind;
            input.source_key.is_none() || input.kind == "folder",
            "source_key marks an imported folder; a url has none"
        );
        let created_ms = match input.created_ms {
            Some(value) => {
                stored_ms("created_ms", value)?;
                value
            }
            None => now_ms,
        };
        if let Some(existing) = self.nodes.get(&id) {
            return Ok((existing.clone(), false));
        }
        self.ensure_profile(&input.browser_profile_id)?;
        let parent_depth = self.resolve_parent(&input.parent)?;
        ensure_valid!(TooDeep;
            parent_depth < MAX_BOOKMARK_DEPTH,
            "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
        );
        self.ensure_capacity(0, 1)?;
        let count = self.sibling_count(&input.parent);
        let index = input.index.unwrap_or(count).min(count);
        let bookmark = Bookmark {
            id: id.clone(),
            browser_profile_id: self.profile.clone(),
            parent: input.parent.clone(),
            kind: input.kind,
            index,
            title: input.title,
            url: input.url,
            favicon_key: input.favicon_key,
            source_key: input.source_key,
            created_ms,
            last_used_ms: None,
            icon: None,
        };
        self.insert_child(bookmark, index);
        self.reindex(&input.parent);
        Ok((self.existing(&id)?.clone(), true))
    }

    fn update(
        &mut self,
        id: &str,
        update: BookmarkUpdate,
    ) -> Result<(Bookmark, bool), BookmarkError> {
        validate_bookmark_id(id)?;
        if let Some(title) = &update.title {
            validate_title(title)?;
        }
        if let Some(url) = &update.url {
            validate_url(url)?;
        }
        validate_key("favicon_key", update.favicon_key.as_ref().and_then(Option::as_deref))?;
        if let Some(Some(last_used_ms)) = update.last_used_ms {
            stored_ms("last_used_ms", last_used_ms)?;
        }
        let before = self.existing(id)?.clone();
        ensure_valid!(InvalidKind;
            update.url.is_none() || before.kind == "url",
            "a folder has no url"
        );
        ensure_valid!(InvalidKind;
            update.icon.is_none() || before.kind == "folder",
            "only a folder has an icon"
        );
        let mut after = before.clone();
        if let Some(title) = update.title {
            after.title = title;
        }
        if let Some(url) = update.url {
            after.url = Some(url);
        }
        if let Some(favicon_key) = update.favicon_key {
            after.favicon_key = favicon_key;
        }
        if let Some(last_used_ms) = update.last_used_ms {
            after.last_used_ms = last_used_ms;
        }
        if let Some(icon) = update.icon {
            after.icon = icon;
        }
        let changed = after != before;
        if changed {
            self.nodes.insert(id.to_string(), after.clone());
        }
        Ok((after, changed))
    }

    fn move_to(
        &mut self,
        id: &str,
        parent: &str,
        index: usize,
    ) -> Result<(Bookmark, bool), BookmarkError> {
        validate_bookmark_id(id)?;
        let node = self.existing(id)?.clone();
        let parent_depth = self.resolve_parent(parent)?;
        if !is_root(parent) {
            ensure_valid!(Cycle;
                !self.ancestors(parent)?.contains(&id),
                "a folder cannot move into itself or a descendant"
            );
        }
        let changed = if node.parent == parent {
            let order = self.children.entry(node.parent.clone()).or_default();
            let last = order.len().saturating_sub(1);
            let old = node.index.min(last);
            let new = index.min(last);
            if new != old && old < order.len() {
                let moved = order.remove(old);
                order.insert(new.min(order.len()), moved);
            }
            self.reindex(parent);
            new != old
        } else {
            ensure_valid!(TooDeep;
                parent_depth.saturating_add(self.subtree_height(id)) <= MAX_BOOKMARK_DEPTH,
                "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
            );
            self.detach(id, &node.parent);
            let index = index.min(self.sibling_count(parent));
            let mut moved = node;
            moved.parent = parent.to_string();
            self.insert_child(moved, index);
            self.reindex(parent);
            true
        };
        Ok((self.existing(id)?.clone(), changed))
    }

    fn delete(&mut self, id: &str) -> Result<Vec<String>, BookmarkError> {
        validate_bookmark_id(id)?;
        let parent = self.existing(id)?.parent.clone();
        let deleted = self.subtree_ids(id);
        self.detach(id, &parent);
        for value in &deleted {
            self.nodes.remove(value);
            self.children.remove(value);
        }
        Ok(deleted)
    }

    fn import(
        &mut self,
        import: BookmarkImport,
        now_ms: u64,
        mint: &mut dyn FnMut() -> String,
    ) -> Result<(Vec<String>, usize), BookmarkError> {
        let profile = import.browser_profile_id.as_str();
        validate_profile_shape(profile)?;
        validate_key("source_key", import.source_key.as_deref())?;
        let (count, height) = validate_import_nodes(&import.nodes)?;
        ensure_valid!(count > 0, "nodes cannot be empty");
        if import.replace {
            ensure_valid!(import.source_key.is_some(), "replace needs a source_key");
            ensure_valid!(
                import.nodes.first().is_some_and(|node| node.kind == "folder"),
                "replace needs a folder as the first node"
            );
        }
        self.ensure_profile(profile)?;
        let parent_depth = self.resolve_parent(&import.parent)?;
        let existing = if import.replace {
            self.nodes
                .values()
                .filter(|node| node.kind == "folder" && node.source_key == import.source_key)
                .min_by(|a, b| (a.created_ms, &a.id).cmp(&(b.created_ms, &b.id)))
                .map(|node| node.id.clone())
        } else {
            None
        };
        if let Some(folder) = existing {
            let stored = self.existing(&folder)?.clone();
            let folder_depth = self.node_depth(&folder)?;
            ensure_valid!(TooDeep;
                folder_depth.saturating_sub(1).saturating_add(height) <= MAX_BOOKMARK_DEPTH,
                "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
            );
            let old = self.subtree_ids(&folder);
            self.ensure_capacity(old.len(), count)?;
            let root_title =
                import.nodes.first().map(|node| node.title.clone()).unwrap_or_default();
            let root_children =
                import.nodes.first().and_then(|node| node.children.as_deref()).unwrap_or_default();
            let rest = import.nodes.get(1..).unwrap_or_default();
            let mut ids = self.mint_ids(count.saturating_sub(1), mint)?.into_iter();
            for value in old.iter().filter(|value| **value != folder) {
                self.nodes.remove(value);
                self.children.remove(value);
            }
            self.children.remove(&folder);
            if let Some(node) = self.nodes.get_mut(&folder) {
                node.title = root_title;
            }
            self.insert_import_nodes(&folder, 0, root_children, None, now_ms, &mut ids);
            let mut root_ids = vec![folder];
            if !rest.is_empty() {
                let after = stored.index.saturating_add(1);
                root_ids.extend(self.insert_import_nodes(
                    &stored.parent,
                    after,
                    rest,
                    None,
                    now_ms,
                    &mut ids,
                ));
            }
            return Ok((root_ids, count));
        }
        ensure_valid!(TooDeep;
            parent_depth.saturating_add(height) <= MAX_BOOKMARK_DEPTH,
            "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
        );
        self.ensure_capacity(0, count)?;
        let siblings = self.sibling_count(&import.parent);
        let index = import.index.unwrap_or(siblings).min(siblings);
        let mut ids = self.mint_ids(count, mint)?.into_iter();
        let root_ids = self.insert_import_nodes(
            &import.parent,
            index,
            &import.nodes,
            import.source_key.as_deref(),
            now_ms,
            &mut ids,
        );
        Ok((root_ids, count))
    }

    // MARK: Reads

    fn existing(&self, id: &str) -> Result<&Bookmark, BookmarkError> {
        self.nodes.get(id).ok_or_else(|| BookmarkError::not_found(format!("unknown bookmark {id}")))
    }

    /// The op's profile must be this tree's.
    fn ensure_profile(&self, profile: &str) -> Result<(), BookmarkError> {
        validate_profile_shape(profile)?;
        if profile != self.profile {
            return Err(BookmarkError::not_found(format!("unknown browser profile {profile}")));
        }
        Ok(())
    }

    /// Depth of a node: a child of a root is 1.
    fn node_depth(&self, id: &str) -> Result<usize, BookmarkError> {
        let mut depth = 0usize;
        let mut current = id;
        while !is_root(current) {
            depth = depth.saturating_add(1);
            ensure_valid!(depth <= MAX_PARENT_CHAIN, "bookmark {id} has a broken parent chain");
            current =
                self.nodes.get(current).map(|node| node.parent.as_str()).ok_or_else(|| {
                    BookmarkError::invalid(format!("bookmark {id} has a missing ancestor"))
                })?;
        }
        Ok(depth)
    }

    /// Every ancestor of a node, nearest first, the node included, roots
    /// excluded.
    fn ancestors<'a>(&'a self, id: &'a str) -> Result<Vec<&'a str>, BookmarkError> {
        let mut chain = Vec::new();
        let mut current = id;
        while !is_root(current) {
            ensure_valid!(
                chain.len() <= MAX_PARENT_CHAIN,
                "bookmark {id} has a broken parent chain"
            );
            chain.push(current);
            current =
                self.nodes.get(current).map(|node| node.parent.as_str()).ok_or_else(|| {
                    BookmarkError::invalid(format!("bookmark {id} has a missing ancestor"))
                })?;
        }
        Ok(chain)
    }

    /// A valid parent: a root, or a folder of this tree. Returns the
    /// parent's depth (0 for a root).
    fn resolve_parent(&self, parent: &str) -> Result<usize, BookmarkError> {
        if is_root(parent) {
            return Ok(0);
        }
        ensure_valid!(InvalidParent;
            validate_bookmark_id(parent).is_ok(),
            "parent must be \"bar\", \"other\" or a folder id"
        );
        let profile = &self.profile;
        ensure_valid!(InvalidParent;
            self.nodes.get(parent).is_some_and(|folder| folder.kind == "folder"),
            "parent {parent} is not a folder of browser profile {profile}"
        );
        self.node_depth(parent)
    }

    /// A node and its descendants by level, each level sorted by id (the
    /// daemon's `ORDER BY level, id`).
    fn subtree_levels(&self, id: &str) -> Vec<Vec<String>> {
        let mut levels = vec![vec![id.to_string()]];
        while levels.len() < SUBTREE_LEVELS {
            let mut next = levels
                .last()
                .into_iter()
                .flatten()
                .filter_map(|value| self.children.get(value))
                .flatten()
                .cloned()
                .collect::<Vec<_>>();
            if next.is_empty() {
                break;
            }
            next.sort_unstable();
            levels.push(next);
        }
        levels
    }

    /// A node and its descendants, the node first.
    fn subtree_ids(&self, id: &str) -> Vec<String> {
        self.subtree_levels(id).into_iter().flatten().collect()
    }

    /// Levels of a subtree: 1 for a node without children.
    fn subtree_height(&self, id: &str) -> usize {
        self.subtree_levels(id).len()
    }

    fn sibling_count(&self, parent: &str) -> usize {
        self.children.get(parent).map_or(0, Vec::len)
    }

    fn ensure_capacity(&self, removed: usize, added: usize) -> Result<(), BookmarkError> {
        let total = self.nodes.len().saturating_sub(removed).saturating_add(added);
        ensure_valid!(TooLarge;
            total <= MAX_BOOKMARKS_PER_PROFILE,
            "a profile holds at most {MAX_BOOKMARKS_PER_PROFILE} bookmarks"
        );
        Ok(())
    }

    /// `count` ids that are well formed, unused and distinct, minted before
    /// anything changes.
    fn mint_ids(
        &self,
        count: usize,
        mint: &mut dyn FnMut() -> String,
    ) -> Result<Vec<String>, BookmarkError> {
        let mut ids = Vec::with_capacity(count);
        let mut taken = HashSet::with_capacity(count);
        while ids.len() < count {
            let fresh = (0..MINT_ATTEMPTS).map(|_| mint()).find(|id| {
                validate_bookmark_id(id).is_ok()
                    && !self.nodes.contains_key(id)
                    && !taken.contains(id)
            });
            let Some(id) = fresh else {
                return Err(BookmarkError::invalid("no free bookmark id could be minted"));
            };
            taken.insert(id.clone());
            ids.push(id);
        }
        Ok(ids)
    }

    // MARK: Writes

    /// Puts `node` at `index` among its parent's children (clamped). The
    /// caller reindexes the parent.
    fn insert_child(&mut self, node: Bookmark, index: usize) {
        let siblings = self.children.entry(node.parent.clone()).or_default();
        siblings.insert(index.min(siblings.len()), node.id.clone());
        self.nodes.insert(node.id.clone(), node);
    }

    /// Takes `id` out of its parent's children; its later siblings close the gap.
    fn detach(&mut self, id: &str, parent: &str) {
        if let Some(siblings) = self.children.get_mut(parent) {
            siblings.retain(|value| value != id);
        }
        self.reindex(parent);
    }

    /// Every child of `parent` gets its position as its `index`.
    fn reindex(&mut self, parent: &str) {
        let Some(ids) = self.children.get(parent) else { return };
        for (position, id) in ids.iter().enumerate() {
            if let Some(node) = self.nodes.get_mut(id) {
                node.index = position;
            }
        }
    }

    /// Inserts imported nodes under `parent` from `start`; `nodes[0]`
    /// carries `source_key` when it is a folder. Returns the ids of `nodes`.
    fn insert_import_nodes(
        &mut self,
        parent: &str,
        start: usize,
        nodes: &[BookmarkImportNode],
        source_key: Option<&str>,
        now_ms: u64,
        ids: &mut std::vec::IntoIter<String>,
    ) -> Vec<String> {
        let mut created = Vec::with_capacity(nodes.len());
        for (offset, node) in nodes.iter().enumerate() {
            let Some(id) = ids.next() else { break };
            let bookmark = Bookmark {
                id: id.clone(),
                browser_profile_id: self.profile.clone(),
                parent: parent.to_string(),
                kind: node.kind.clone(),
                index: 0,
                title: node.title.clone(),
                url: node.url.clone(),
                favicon_key: None,
                source_key: source_key
                    .filter(|_| offset == 0 && node.kind == "folder")
                    .map(str::to_string),
                created_ms: node.created_ms.unwrap_or(now_ms),
                last_used_ms: None,
                icon: None,
            };
            self.insert_child(bookmark, start.saturating_add(offset));
            if let Some(children) = &node.children {
                self.insert_import_nodes(&id, 0, children, None, now_ms, ids);
            }
            created.push(id);
        }
        self.reindex(parent);
        created
    }
}
