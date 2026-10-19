//! The document and its indexes. An op touches only the rows it changes:
//! items are keyed by id, each sibling list (a section's top level, a
//! group's children) is an ordered set of `(order key, id)`, and workspace
//! refs, placement references and per-section item counts are indexed, so
//! no op copies, sorts or scans the whole document.
//!
//! The wire form is unchanged: `{revision: "N", sections: [...], items:
//! [...]}` with sections in display order (region, then order key) and
//! items in display order (section, then the top-level list, a group's
//! children right after it). Reading builds the indexes once.

use std::collections::{BTreeSet, HashMap};
use std::ops::Bound;

use serde::{Deserialize, Serialize};

use super::model::*;

/// A sibling list: a section's top level (`None`) or a group's children.
pub type ListKey = (SectionId, Option<ItemId>);

/// One entry of a sibling list, in list order.
pub type ListEntry = (String, ItemId);

type RefKey = (String, String);

/// The sidebar document. Mutations go through the reducer
/// ([`super::reduce`]), which keeps the indexes.
#[derive(Debug, Clone, Default)]
pub struct Doc {
    pub revision: u64,
    /// Display order: region, then order key, then id (at most
    /// [`MAX_SECTIONS`], so a sort per section change is cheap).
    sections: Vec<Section>,
    items: HashMap<ItemId, Item>,
    lists: HashMap<ListKey, BTreeSet<ListEntry>>,
    /// Workspace `(session, workspace id)` -> the items that place it (one
    /// in a valid document; a raw op list may pass through two).
    refs: HashMap<RefKey, BTreeSet<ItemId>>,
    /// `(session, placement reference)` -> items placed before their
    /// public id was known (`extra.workspace_ref`).
    placements: HashMap<RefKey, BTreeSet<ItemId>>,
    /// Items per section (top level and children).
    counts: HashMap<SectionId, usize>,
}

impl PartialEq for Doc {
    fn eq(&self, other: &Self) -> bool {
        self.revision == other.revision
            && self.sections == other.sections
            && self.items == other.items
    }
}

impl Eq for Doc {}

/// A string revision on the wire ("12"); a number reads too.
mod decimal {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &u64, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Either {
            Text(String),
            Number(u64),
        }
        match Either::deserialize(deserializer)? {
            Either::Text(text) => text.parse().map_err(serde::de::Error::custom),
            Either::Number(number) => Ok(number),
        }
    }
}

#[derive(Serialize)]
struct WireOut<'a> {
    #[serde(with = "decimal")]
    revision: u64,
    sections: &'a [Section],
    items: Vec<&'a Item>,
}

#[derive(Deserialize)]
struct WireIn {
    #[serde(with = "decimal")]
    revision: u64,
    #[serde(default)]
    sections: Vec<Section>,
    #[serde(default)]
    items: Vec<Item>,
}

impl Serialize for Doc {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        WireOut { revision: self.revision, sections: &self.sections, items: self.items_in_order() }
            .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Doc {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = WireIn::deserialize(deserializer)?;
        Ok(Doc::from_parts(wire.revision, wire.sections, wire.items))
    }
}

fn sort_sections(sections: &mut [Section]) {
    sections.sort_by(|a, b| {
        a.region_rank()
            .cmp(&b.region_rank())
            .then_with(|| a.order.cmp(&b.order))
            .then_with(|| a.id.cmp(&b.id))
    });
}

fn ref_key(reference: &WorkspaceRef) -> RefKey {
    (reference.session_id.clone(), reference.workspace_id.clone())
}

fn placement_key(reference: &WorkspaceRef) -> Option<RefKey> {
    reference.placement_ref().map(|key| (reference.session_id.clone(), key.to_string()))
}

impl Doc {
    /// A document of these rows (any order; of two rows with one id the
    /// first is kept).
    pub fn from_parts(revision: u64, mut sections: Vec<Section>, items: Vec<Item>) -> Doc {
        let mut seen = std::collections::HashSet::new();
        sections.retain(|section| seen.insert(section.id.clone()));
        sort_sections(&mut sections);
        let mut doc = Doc { revision, sections, ..Doc::default() };
        for item in items {
            if !doc.items.contains_key(&item.id) {
                doc.replace_item(item);
            }
        }
        doc
    }

    /// The rows, in display order.
    pub fn to_parts(&self) -> (Vec<Section>, Vec<Item>) {
        (self.sections.clone(), self.items_in_order().into_iter().cloned().collect())
    }

    pub fn sections(&self) -> &[Section] {
        &self.sections
    }

    pub fn section(&self, id: &str) -> Option<&Section> {
        self.sections.iter().find(|section| section.id == id)
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.get(id)
    }

    pub fn item_count(&self) -> usize {
        self.items.len()
    }

    /// Every item in no particular order.
    pub fn items_unordered(&self) -> impl Iterator<Item = &Item> {
        self.items.values()
    }

    /// Every item in display order: per section, its top-level list with
    /// each group's descendants right after the group (depth first). Items
    /// no list reaches (an unknown section or parent, possible only in a
    /// document that fails the invariants) follow, by id.
    pub fn items_in_order(&self) -> Vec<&Item> {
        let mut out = Vec::with_capacity(self.items.len());
        for section in &self.sections {
            for item in self.list(&section.id, None) {
                self.push_drawn(item, &mut out);
            }
        }
        if out.len() != self.items.len() {
            let shown: std::collections::HashSet<&str> =
                out.iter().map(|item| item.id.as_str()).collect();
            let mut rest: Vec<&Item> =
                self.items.values().filter(|item| !shown.contains(item.id.as_str())).collect();
            rest.sort_by(|a, b| a.id.cmp(&b.id));
            out.extend(rest);
        }
        out
    }

    /// `item`, then its descendants depth first. The depth is bounded, so a
    /// parent cycle (only in a document that fails the invariants) stops.
    fn push_drawn<'a>(&'a self, item: &'a Item, out: &mut Vec<&'a Item>) {
        self.push_drawn_at(item, out, 0);
    }

    fn push_drawn_at<'a>(&'a self, item: &'a Item, out: &mut Vec<&'a Item>, level: usize) {
        out.push(item);
        if item.body.is_group() && level <= MAX_GROUP_DEPTH {
            for child in self.list(&item.section, Some(item.id.as_str())) {
                self.push_drawn_at(child, out, level + 1);
            }
        }
    }

    /// The descendants of `group` in display order (children, and the
    /// children of each nested group right after it). Empty for an item
    /// that is not a group.
    pub fn descendants(&self, group: &str) -> Vec<&Item> {
        let Some(item) = self.items.get(group) else { return Vec::new() };
        let mut out = Vec::new();
        self.push_drawn(item, &mut out);
        out.remove(0);
        out
    }

    /// The groups above `id`, nearest first. Stops at a missing parent. In
    /// a parent cycle (only in a document that fails the invariants) it
    /// stops at the first repeat and returns more than
    /// [`MAX_GROUP_DEPTH`] entries, so every depth check refuses it.
    pub fn ancestors(&self, id: &str) -> Vec<&Item> {
        let mut out: Vec<&Item> = Vec::new();
        let mut cursor = self.items.get(id).and_then(|item| item.parent.as_deref());
        while let Some(parent) = cursor {
            let Some(item) = self.items.get(parent) else { break };
            if out.iter().any(|seen| seen.id == item.id) || item.id == id {
                // A cycle: report more ancestors than any valid depth.
                out.resize(MAX_GROUP_DEPTH + 1, item);
                break;
            }
            out.push(item);
            cursor = item.parent.as_deref();
        }
        out
    }

    /// Whether `ancestor` is `id` or a group above it.
    pub fn is_within(&self, id: &str, ancestor: &str) -> bool {
        id == ancestor || self.ancestors(id).iter().any(|item| item.id == ancestor)
    }

    /// How many group levels `group` and its nested groups take: 1 for a
    /// group with no nested group, 0 for an item that is not a group.
    pub fn group_height(&self, id: &str) -> usize {
        self.group_height_at(id, 0)
    }

    fn group_height_at(&self, id: &str, level: usize) -> usize {
        let Some(item) = self.items.get(id).filter(|item| item.body.is_group()) else {
            return 0;
        };
        if level > MAX_GROUP_DEPTH {
            return level;
        }
        1 + self
            .list(&item.section, Some(id))
            .map(|child| self.group_height_at(&child.id, level + 1))
            .max()
            .unwrap_or(0)
    }

    /// The machines of the workspaces in `id` (itself, or anywhere under a
    /// group).
    pub fn machines_of(&self, id: &str) -> BTreeSet<String> {
        let Some(item) = self.items.get(id) else { return BTreeSet::new() };
        std::iter::once(item)
            .chain(self.descendants(id))
            .filter_map(|item| item.body.workspace().map(|r| r.session_id.clone()))
            .collect()
    }

    /// The ordered entries of one sibling list.
    pub fn list_entries(
        &self,
        section: &str,
        parent: Option<&str>,
    ) -> Option<&BTreeSet<ListEntry>> {
        self.lists.get(&(section.to_string(), parent.map(str::to_string)))
    }

    /// The items of one sibling list, in order.
    pub fn list<'a>(
        &'a self,
        section: &str,
        parent: Option<&str>,
    ) -> impl DoubleEndedIterator<Item = &'a Item> + 'a {
        self.list_entries(section, parent)
            .into_iter()
            .flat_map(|set| set.iter())
            .filter_map(|(_, id)| self.items.get(id))
    }

    pub fn list_len(&self, section: &str, parent: Option<&str>) -> usize {
        self.list_entries(section, parent).map_or(0, BTreeSet::len)
    }

    /// The children of `parent` (or the top-level items of `section`), in
    /// order.
    pub fn children(&self, section: &str, parent: Option<&str>) -> Vec<&Item> {
        self.list(section, parent).collect()
    }

    /// How many items sit in `section` (top level and children).
    pub fn section_item_count(&self, section: &str) -> usize {
        self.counts.get(section).copied().unwrap_or(0)
    }

    /// The items of `section`: top level, each group's descendants after it.
    pub fn section_items(&self, section: &str) -> Vec<&Item> {
        let mut out = Vec::new();
        for item in self.list(section, None) {
            self.push_drawn(item, &mut out);
        }
        out
    }

    /// The item that places `reference`.
    pub fn workspace_item(&self, reference: &WorkspaceRef) -> Option<&Item> {
        self.refs
            .get(&ref_key(reference))
            .and_then(|ids| ids.iter().next())
            .and_then(|id| self.items.get(id))
    }

    /// How many items place `reference` (1 in a valid document).
    pub fn ref_count(&self, reference: &WorkspaceRef) -> usize {
        self.refs.get(&ref_key(reference)).map_or(0, BTreeSet::len)
    }

    /// The item of `session` placed by its placement reference `key`
    /// (before its public id was known, or resolved since).
    pub fn placement_item(&self, session: &str, key: &str) -> Option<&Item> {
        self.placements
            .get(&(session.to_string(), key.to_string()))
            .and_then(|ids| ids.iter().next())
            .and_then(|id| self.items.get(id))
    }

    /// The machine a group or workspace item belongs to: a workspace's
    /// session, the session of a group's first workspace in display order,
    /// nested groups included (None for a group with no workspace or
    /// another body). A group outside a machine section may hold
    /// workspaces of several machines; [`Doc::machines_of`] names them all.
    pub fn item_machine(&self, item: &Item) -> Option<String> {
        match &item.body {
            Body::Workspace { reference } => Some(reference.session_id.clone()),
            Body::Group { .. } => self
                .descendants(&item.id)
                .into_iter()
                .find_map(|child| child.body.workspace().map(|r| r.session_id.clone())),
            _ => None,
        }
    }

    pub fn machine_section(&self, session_id: &str) -> Option<&Section> {
        self.sections.iter().find(|section| section.kind.machine() == Some(session_id))
    }

    /// The last row an item draws: its last descendant for a group with
    /// children, else itself.
    fn last_drawn<'a>(&'a self, item: &'a Item) -> &'a Item {
        let mut last = item;
        for _ in 0..=MAX_GROUP_DEPTH {
            if !last.body.is_group() {
                break;
            }
            match self.list(&last.section, Some(last.id.as_str())).next_back() {
                Some(child) => last = child,
                None => break,
            }
        }
        last
    }

    /// The item right before `id` in display order (across sections).
    pub fn previous_in_order(&self, id: &str) -> Option<&Item> {
        let item = self.items.get(id)?;
        let entry = (item.order.clone(), item.id.clone());
        if let Some(parent) = &item.parent {
            let earlier = self
                .list_entries(&item.section, Some(parent.as_str()))
                .and_then(|set| set.range(..&entry).next_back())
                .and_then(|(_, id)| self.items.get(id));
            return earlier
                .map(|earlier| self.last_drawn(earlier))
                .or_else(|| self.items.get(parent));
        }
        if let Some(earlier) = self
            .list_entries(&item.section, None)
            .and_then(|set| set.range(..&entry).next_back())
            .and_then(|(_, id)| self.items.get(id))
        {
            return Some(self.last_drawn(earlier));
        }
        self.last_before_section(&item.section)
    }

    /// The last row drawn in the nearest section before `section` that has
    /// items.
    pub fn last_before_section(&self, section: &str) -> Option<&Item> {
        let at = self.sections.iter().position(|candidate| candidate.id == section)?;
        self.sections[..at]
            .iter()
            .rev()
            .find_map(|section| self.list(&section.id, None).next_back())
            .map(|top| self.last_drawn(top))
    }

    /// A key that sorts items into display order: the section, then the
    /// entries from the item's top-level ancestor down to the item (a
    /// group sorts before its descendants).
    pub fn display_key(&self, item: &Item) -> (usize, Vec<ListEntry>) {
        let section = self
            .sections
            .iter()
            .position(|section| section.id == item.section)
            .unwrap_or(usize::MAX);
        let mut path: Vec<ListEntry> = self
            .ancestors(&item.id)
            .into_iter()
            .map(|ancestor| (ancestor.order.clone(), ancestor.id.clone()))
            .collect();
        path.reverse();
        path.push((item.order.clone(), item.id.clone()));
        (section, path)
    }

    /// The first entry after `entry` in a list, skipping `skip`.
    pub(crate) fn entry_after<'a>(
        set: &'a BTreeSet<ListEntry>,
        entry: &ListEntry,
        skip: &dyn Fn(&str) -> bool,
    ) -> Option<&'a ListEntry> {
        set.range((Bound::Excluded(entry), Bound::Unbounded)).find(|(_, id)| !skip(id))
    }

    /// The last entry before `entry` in a list, skipping `skip`.
    pub(crate) fn entry_before<'a>(
        set: &'a BTreeSet<ListEntry>,
        entry: &ListEntry,
        skip: &dyn Fn(&str) -> bool,
    ) -> Option<&'a ListEntry> {
        set.range(..entry).rev().find(|(_, id)| !skip(id))
    }

    // MARK: Row writes (the reducer's journal calls these)

    fn index(&mut self, item: &Item) {
        self.lists
            .entry((item.section.clone(), item.parent.clone()))
            .or_default()
            .insert((item.order.clone(), item.id.clone()));
        *self.counts.entry(item.section.clone()).or_default() += 1;
        if let Some(reference) = item.body.workspace() {
            self.refs.entry(ref_key(reference)).or_default().insert(item.id.clone());
            if let Some(key) = placement_key(reference) {
                self.placements.entry(key).or_default().insert(item.id.clone());
            }
        }
    }

    fn unindex(&mut self, item: &Item) {
        let list = (item.section.clone(), item.parent.clone());
        if let Some(set) = self.lists.get_mut(&list) {
            set.remove(&(item.order.clone(), item.id.clone()));
            if set.is_empty() {
                self.lists.remove(&list);
            }
        }
        if let Some(count) = self.counts.get_mut(&item.section) {
            *count -= 1;
            if *count == 0 {
                self.counts.remove(&item.section);
            }
        }
        if let Some(reference) = item.body.workspace() {
            let key = ref_key(reference);
            if let Some(ids) = self.refs.get_mut(&key) {
                ids.remove(&item.id);
                if ids.is_empty() {
                    self.refs.remove(&key);
                }
            }
            if let Some(key) = placement_key(reference)
                && let Some(ids) = self.placements.get_mut(&key)
            {
                ids.remove(&item.id);
                if ids.is_empty() {
                    self.placements.remove(&key);
                }
            }
        }
    }

    /// Store `item` (insert or replace by id); returns the old row.
    pub(crate) fn replace_item(&mut self, item: Item) -> Option<Item> {
        let old = self.items.remove(&item.id);
        if let Some(old) = &old {
            self.unindex(old);
        }
        self.index(&item);
        self.items.insert(item.id.clone(), item);
        old
    }

    pub(crate) fn remove_item(&mut self, id: &str) -> Option<Item> {
        let old = self.items.remove(id)?;
        self.unindex(&old);
        Some(old)
    }

    /// Store `section` (insert or replace by id); returns the old row.
    pub(crate) fn replace_section(&mut self, section: Section) -> Option<Section> {
        let old = match self.sections.iter_mut().find(|existing| existing.id == section.id) {
            Some(existing) => Some(std::mem::replace(existing, section)),
            None => {
                self.sections.push(section);
                None
            }
        };
        sort_sections(&mut self.sections);
        old
    }

    pub(crate) fn remove_section(&mut self, id: &str) -> Option<Section> {
        let at = self.sections.iter().position(|section| section.id == id)?;
        Some(self.sections.remove(at))
    }
}
