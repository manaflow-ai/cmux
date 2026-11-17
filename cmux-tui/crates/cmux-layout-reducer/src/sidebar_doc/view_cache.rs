//! One window's view kept between changes, so a change rebuilds the rows it
//! touches, not the sidebar (Leo: "never ... acceptable ... linear time
//! growth degradation").
//!
//! The rows of [`view::view`] split into blocks: each section's header,
//! one block per top-level item (a workspace row, or a group with its whole
//! subtree) and the section's unplaced live workspaces. A block depends only
//! on its own tree, its section and the view's context (live set, filter,
//! collapsed ids), so after a change the cache rebuilds only the blocks
//! whose tree holds a touched item, where it left and where it landed
//! ([`Doc::take_touched`]), and re-places those blocks among their
//! siblings. Each block also keeps its share of the projection
//! ([`project::project_rows`] over its rows), so [`ViewCache::projection`]
//! re-projects only rebuilt blocks.
//!
//! The rule stays [`view::view`]'s: the cache calls the same block, header
//! and unplaced functions, and rebuilds everything when what it cannot
//! follow piece by piece changes (a section, the window, the filter, the
//! collapsed ids, a text filter at all, a machine gaining or losing its
//! stand-in section). `view_cache_tests` holds it equal to a full view
//! after every op of the fixtures.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use super::doc::{Doc, Touched};
use super::model::*;
use serde::Serialize;

use super::project::{self, BandItem, Group, Member, Node, ProjectedSection, Projection};
use super::view::{self, Context, Live, LiveIndex, Row, ViewRequest, WindowFilter};

/// One block's share of the projection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Part {
    pub nodes: Vec<Node>,
    pub band_items: Vec<BandItem>,
    pub band_groups: Vec<Group>,
    pub items: Vec<Member>,
    pub archived: Vec<ItemId>,
}

impl Part {
    fn of(doc: &Doc, rows: &[Row]) -> Part {
        if rows.is_empty() {
            return Part::default();
        }
        let out = project::project_rows(doc, rows);
        Part {
            nodes: out.machines.into_values().flatten().collect(),
            band_items: out
                .sections
                .into_iter()
                .flat_map(|section| match section {
                    ProjectedSection::Band { items, .. } => items,
                    ProjectedSection::Workspaces { .. } => Vec::new(),
                })
                .collect(),
            band_groups: out.band_groups,
            items: out.items,
            archived: out.archived,
        }
    }
}

/// One top-level item's rows.
#[derive(Debug, Clone)]
pub struct Block {
    pub key: ItemId,
    pub rows: Vec<Row>,
    /// Every item of its tree (the cache's index).
    members: Vec<ItemId>,
    pub part: Part,
}

/// One shown section.
#[derive(Debug, Clone)]
pub struct SectionView {
    pub section: Section,
    pub header: Option<Row>,
    pub blocks: Vec<Block>,
    /// A machine section's unplaced live workspaces: (place in live order, row).
    pub unplaced: Vec<(usize, Row)>,
}

impl SectionView {
    /// The header is drawn collapsed: no body rows.
    pub fn folded(&self) -> bool {
        self.header.as_ref().is_some_and(|header| header.collapsed)
    }

    /// Where the unplaced rows go among the blocks.
    pub fn unplaced_at(&self) -> usize {
        view::unplaced_at(self.blocks.iter().map(|block| block.rows.first()))
    }

    /// Whether the section draws any row.
    pub fn draws(&self) -> bool {
        self.header.is_some()
            || !self.unplaced.is_empty()
            || self.blocks.iter().any(|block| !block.rows.is_empty())
    }

    fn rows_into(&self, out: &mut Vec<Row>) {
        out.extend(self.header.iter().cloned());
        if self.folded() {
            return;
        }
        let at = self.unplaced_at();
        for (index, block) in self.blocks.iter().enumerate() {
            if index == at {
                out.extend(self.unplaced.iter().map(|(_, row)| row.clone()));
            }
            out.extend(block.rows.iter().cloned());
        }
        if at >= self.blocks.len() {
            out.extend(self.unplaced.iter().map(|(_, row)| row.clone()));
        }
    }
}

/// The group settings of every item (the projection's document-wide fields).
#[derive(Debug, Clone, Default)]
struct Settings {
    sorts: BTreeMap<ItemId, String>,
    row_limits: BTreeMap<ItemId, u32>,
    revealed: BTreeMap<ItemId, u32>,
    pinned_in_group: BTreeSet<ItemId>,
}

impl Settings {
    fn forget(&mut self, id: &str) {
        self.sorts.remove(id);
        self.row_limits.remove(id);
        self.revealed.remove(id);
        self.pinned_in_group.remove(id);
    }

    fn learn(&mut self, item: &Item) {
        let mut out = Projection::default();
        project::group_settings(item, &mut out);
        self.sorts.extend(out.group_sorts);
        self.row_limits.extend(out.group_row_limits);
        self.revealed.extend(out.group_revealed);
        self.pinned_in_group.extend(out.pinned_in_group);
    }
}

/// One window's view, kept and patched per change.
#[derive(Debug, Clone, Default)]
pub struct ViewCache {
    built: bool,
    /// The request it was built for, without its live set (in `live`).
    request: ViewRequest,
    live: LiveIndex,
    sections: Vec<SectionView>,
    /// Each item of a block's tree -> (section, block key).
    index: HashMap<ItemId, (SectionId, ItemId)>,
    settings: Settings,
    host_groups: Vec<SectionId>,
}

fn has_needle(request: &ViewRequest) -> bool {
    request.filter.as_ref().is_some_and(|text| !text.trim().is_empty())
}

fn shows_session(window: &WindowFilter, session: &str) -> bool {
    window.sessions.as_ref().is_none_or(|sessions| sessions.iter().any(|s| s == session))
}

fn make_block(doc: &Doc, context: &Context<'_>, section: &Section, item: &Item) -> Block {
    let rows = view::block_rows(doc, context, section, item);
    let mut members = vec![item.id.clone()];
    if item.body.is_group() {
        members.extend(doc.descendants(item).into_iter().map(|child| child.id.clone()));
    }
    let part = Part::of(doc, &rows);
    Block { key: item.id.clone(), rows, members, part }
}

impl ViewCache {
    /// Forget everything: the next refresh rebuilds (a new document).
    pub fn invalidate(&mut self) {
        self.built = false;
    }

    pub fn sections(&self) -> &[SectionView] {
        &self.sections
    }

    /// Bring the view up to `doc` for `request`; `touched` is what changed
    /// in `doc` since the last refresh.
    pub fn refresh(&mut self, doc: &Doc, mut request: ViewRequest, touched: Touched) {
        let same_shape = self.built
            && request.window == self.request.window
            && request.filter == self.request.filter
            && request.collapsed == self.request.collapsed;
        if !same_shape || touched.sections || has_needle(&request) {
            return self.rebuild(doc, request);
        }
        let Touched { mut items, mut refs, .. } = touched;
        let mut every_unplaced = false;
        if request.live.as_slice() != self.live.list() {
            let key =
                |live: &view::LiveWorkspace| (live.session_id.clone(), live.workspace_id.clone());
            let old: HashSet<(String, String)> = self.live.list().iter().map(key).collect();
            let new: HashSet<(String, String)> = request.live.iter().map(key).collect();
            for (session, workspace) in old.symmetric_difference(&new) {
                if let Some(item) = doc.workspace_item(&WorkspaceRef::new(session, workspace)) {
                    items.insert(item.id.clone());
                }
                refs.insert((session.clone(), workspace.clone()));
            }
            self.live = LiveIndex::new(std::mem::take(&mut request.live));
            every_unplaced = true;
        }
        // The blocks to rebuild, by section; `true`: re-place them (a
        // top-level item itself changed).
        let mut dirty: HashMap<SectionId, (bool, HashSet<ItemId>)> = HashMap::new();
        for id in &items {
            if let Some((section, key)) = self.index.get(id) {
                let entry = dirty.entry(section.clone()).or_default();
                entry.0 |= key == id;
                entry.1.insert(key.clone());
            }
            if let Some(item) = doc.item(id) {
                let root = doc.root(item);
                if root.parent.is_none() {
                    let entry = dirty.entry(root.section.clone()).or_default();
                    entry.0 |= root.id == *id;
                    entry.1.insert(root.id.clone());
                }
            }
        }
        if !self.patch_unplaced(doc, &refs, every_unplaced) {
            let live = std::mem::take(&mut self.live);
            request.live = live.list().to_vec();
            return self.rebuild(doc, request);
        }
        let context = Context::new(Live::Kept(&self.live), &self.request);
        // Unindex every block that goes or is rebuilt, then build: a member
        // that moved between two rebuilt blocks ends in the new one.
        let mut rebuild: Vec<(usize, ItemId)> = Vec::new();
        for (section_id, (replace, keys)) in &dirty {
            let Some(at) = self.sections.iter().position(|s| s.section.id == *section_id) else {
                continue;
            };
            let section = &mut self.sections[at];
            let mut gone = Vec::new();
            if *replace {
                section.blocks.retain(|block| {
                    let keep = !keys.contains(&block.key);
                    if !keep {
                        gone.push((block.key.clone(), block.members.clone()));
                    }
                    keep
                });
                let mut entering: Vec<&Item> = keys
                    .iter()
                    .filter_map(|key| doc.item(key))
                    .filter(|item| item.parent.is_none() && item.section == *section_id)
                    .collect();
                entering.sort_by(|a, b| (&a.order, &a.id).cmp(&(&b.order, &b.id)));
                for item in entering {
                    let before = doc.list_entries(section_id, None).and_then(|list| {
                        list.range(..(item.order.clone(), item.id.clone())).next_back()
                    });
                    let place = before
                        .and_then(|(_, id)| section.blocks.iter().position(|b| b.key == *id))
                        .map_or(0, |index| index + 1);
                    section.blocks.insert(
                        place,
                        Block {
                            key: item.id.clone(),
                            rows: Vec::new(),
                            members: Vec::new(),
                            part: Part::default(),
                        },
                    );
                }
            }
            for block in &section.blocks {
                if keys.contains(&block.key) {
                    gone.push((block.key.clone(), block.members.clone()));
                    rebuild.push((at, block.key.clone()));
                }
            }
            for (key, members) in gone {
                for member in members {
                    if self.index.get(&member).is_some_and(|(s, k)| s == section_id && *k == key) {
                        self.index.remove(&member);
                    }
                }
            }
        }
        for (at, key) in rebuild {
            let section = &mut self.sections[at];
            let Some(block) = section.blocks.iter_mut().find(|block| block.key == key) else {
                continue;
            };
            let Some(item) = doc.item(&key) else { continue };
            *block = make_block(doc, &context, &section.section, item);
            for member in &block.members {
                self.index.insert(member.clone(), (section.section.id.clone(), key.clone()));
            }
        }
        for id in &items {
            self.settings.forget(id);
            if let Some(item) = doc.item(id) {
                self.settings.learn(item);
            }
        }
    }

    /// Follow the unplaced live workspaces: `refs` changed placement or
    /// liveness (`every`: the live list changed, so every list again).
    /// False when a machine gains or loses its stand-in section: rebuild.
    fn patch_unplaced(&mut self, doc: &Doc, refs: &HashSet<(String, String)>, every: bool) -> bool {
        if every {
            let unplaced = view::unplaced_by_session(doc, self.live.list());
            for section in &mut self.sections {
                let Some(session) = section.section.kind.machine() else { continue };
                let list = unplaced.iter().find(|(s, _)| s == session);
                let now: Vec<(usize, &str)> = list
                    .map(|(_, list)| {
                        list.iter()
                            .filter_map(|live| {
                                let at =
                                    self.live.position(&live.session_id, &live.workspace_id)?;
                                Some((at, live.workspace_id.as_str()))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let was = section.unplaced.iter().map(|(at, row)| {
                    (*at, row.reference.as_ref().map_or("", |r| r.workspace_id.as_str()))
                });
                if now.iter().copied().eq(was) {
                    continue;
                }
                if doc.section(&section.section.id).is_none() && now.is_empty() {
                    return false;
                }
                section.unplaced = list
                    .map(|(_, list)| {
                        list.iter()
                            .filter_map(|live| {
                                let at =
                                    self.live.position(&live.session_id, &live.workspace_id)?;
                                Some((at, view::unplaced_row(&section.section, live)))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
            }
            // A machine with unplaced workspaces and no section yet.
            return unplaced.iter().all(|(session, _)| {
                !shows_session(&self.request.window, session)
                    || self.sections.iter().any(|s| s.section.kind.machine() == Some(session))
            });
        }
        for (session, workspace) in refs {
            let Some(at) = self.live.position(session, workspace) else { continue };
            let unplaced = doc.workspace_item(&WorkspaceRef::new(session, workspace)).is_none();
            let Some(section) =
                self.sections.iter_mut().find(|s| s.section.kind.machine() == Some(session))
            else {
                if unplaced && shows_session(&self.request.window, session) {
                    return false;
                }
                continue;
            };
            match (section.unplaced.binary_search_by_key(&at, |(place, _)| *place), unplaced) {
                (Err(place), true) => {
                    let live = &self.live.list()[at];
                    section
                        .unplaced
                        .insert(place, (at, view::unplaced_row(&section.section, live)));
                }
                (Ok(place), false) => {
                    section.unplaced.remove(place);
                    if section.unplaced.is_empty() && doc.section(&section.section.id).is_none() {
                        return false;
                    }
                }
                _ => {}
            }
        }
        true
    }

    fn rebuild(&mut self, doc: &Doc, mut request: ViewRequest) {
        self.live = LiveIndex::new(std::mem::take(&mut request.live));
        self.request = request;
        self.index.clear();
        let context = Context::new(Live::Kept(&self.live), &self.request);
        let unplaced = view::unplaced_by_session(doc, self.live.list());
        let sections = view::shown_sections(
            doc,
            &self.request.window,
            unplaced.iter().map(|(session, _)| session.as_str()),
        );
        let machine_count = sections.iter().filter(|s| s.kind.machine().is_some()).count();
        let mut views = Vec::with_capacity(sections.len());
        for section in sections {
            let blocks: Vec<Block> = doc
                .list(&section.id, None)
                .map(|item| make_block(doc, &context, &section, item))
                .collect();
            for block in &blocks {
                for member in &block.members {
                    self.index.insert(member.clone(), (section.id.clone(), block.key.clone()));
                }
            }
            let mut rows = Vec::new();
            if let Some(session) = section.kind.machine()
                && let Some((_, list)) = unplaced.iter().find(|(s, _)| s == session)
            {
                for live in list {
                    if context.matches(live.title.as_deref().unwrap_or_default())
                        && let Some(at) = self.live.position(&live.session_id, &live.workspace_id)
                    {
                        rows.push((at, view::unplaced_row(&section, live)));
                    }
                }
            }
            let body_empty = rows.is_empty() && blocks.iter().all(|b| b.rows.is_empty());
            let header = view::header_row(&section, &context, machine_count, body_empty);
            views.push(SectionView { section, header, blocks, unplaced: rows });
        }
        self.sections = views;
        self.settings = Settings::default();
        for item in doc.items_unordered() {
            self.settings.learn(item);
        }
        let mut out = Projection::default();
        project::host_groups(doc, &mut out);
        self.host_groups = out.host_groups;
        self.built = true;
    }

    /// The rows, as [`view::view`] draws them.
    pub fn rows(&self) -> Vec<Row> {
        let mut out = Vec::new();
        for section in &self.sections {
            section.rows_into(&mut out);
        }
        out
    }

    /// The projection, as [`project::project`] answers for [`Self::rows`]
    /// (read back from [`Self::projection_json`], so both are one path).
    pub fn projection(&self, doc: &Doc) -> Projection {
        serde_json::from_str(&self.projection_json(doc)).unwrap_or_default()
    }

    /// The projection's JSON, byte for byte what `serde_json::to_string` of
    /// [`project::project`] writes, serialized from the kept blocks' parts
    /// with no copy of them and no JSON value tree.
    pub fn projection_json(&self, doc: &Doc) -> String {
        serde_json::to_string(&self.projection_ref(doc)).unwrap_or_else(|_| "{}".into())
    }

    fn projection_ref<'a>(&'a self, doc: &'a Doc) -> ProjectionRef<'a> {
        let mut out = ProjectionRef {
            sections: Vec::new(),
            machines: BTreeMap::new(),
            items: Chain::default(),
            machine_sections: BTreeMap::new(),
            machine_order: Vec::new(),
            unplaced: Vec::new(),
            band_groups: Chain::default(),
            host_groups: &self.host_groups,
            archived: Chain::default(),
            group_sorts: &self.settings.sorts,
            pinned_in_group: &self.settings.pinned_in_group,
            group_row_limits: &self.settings.row_limits,
            group_revealed: &self.settings.revealed,
        };
        let mut placed_list = false;
        for view in &self.sections {
            if !view.draws() {
                continue;
            }
            let body = !view.folded();
            let section = doc.section(&view.section.id).unwrap_or(&view.section);
            let parts: Vec<&Part> =
                if body { view.blocks.iter().map(|block| &block.part).collect() } else { vec![] };
            for part in &parts {
                out.items.push(&part.items);
                out.archived.push(&part.archived);
            }
            if let Some(session) = section.kind.machine() {
                if !out.machine_sections.contains_key(session) {
                    out.machine_order.push(&section.id);
                }
                out.machine_sections.insert(session, &section.id);
                if !placed_list {
                    placed_list = true;
                    out.sections.push(SectionRef::Workspaces { like: Some(section) });
                }
                for part in &parts {
                    if !part.nodes.is_empty() {
                        out.machines.entry(session).or_default().push(&part.nodes);
                    }
                }
                if body {
                    out.unplaced
                        .extend(view.unplaced.iter().filter_map(|(_, row)| row.reference.as_ref()));
                }
                continue;
            }
            let mut items = Chain::default();
            for part in &parts {
                items.push(&part.band_items);
                out.band_groups.push(&part.band_groups);
            }
            out.sections.push(SectionRef::Band { section, items });
        }
        if !placed_list {
            out.sections.push(SectionRef::Workspaces { like: None });
        }
        out
    }
}

/// Slices serialized as one flat sequence.
struct Chain<'a, T>(Vec<&'a [T]>);

impl<T> Default for Chain<'_, T> {
    fn default() -> Self {
        Chain(Vec::new())
    }
}

impl<'a, T> Chain<'a, T> {
    fn push(&mut self, slice: &'a [T]) {
        if !slice.is_empty() {
            self.0.push(slice);
        }
    }
}

impl<T: Serialize> Serialize for Chain<'_, T> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(self.0.iter().flat_map(|slice| slice.iter()))
    }
}

/// [`ProjectedSection`] by reference (the same wire form).
#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum SectionRef<'a> {
    Workspaces {
        #[serde(skip_serializing_if = "Option::is_none")]
        like: Option<&'a Section>,
    },
    Band {
        section: &'a Section,
        items: Chain<'a, BandItem>,
    },
}

/// [`Projection`] by reference: the same fields in the same order with the
/// same skips, so the bytes match.
#[derive(Serialize)]
struct ProjectionRef<'a> {
    sections: Vec<SectionRef<'a>>,
    machines: BTreeMap<&'a str, Chain<'a, Node>>,
    items: Chain<'a, Member>,
    machine_sections: BTreeMap<&'a str, &'a SectionId>,
    machine_order: Vec<&'a SectionId>,
    unplaced: Vec<&'a WorkspaceRef>,
    band_groups: Chain<'a, Group>,
    host_groups: &'a [SectionId],
    archived: Chain<'a, ItemId>,
    group_sorts: &'a BTreeMap<ItemId, String>,
    pinned_in_group: &'a BTreeSet<ItemId>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    group_row_limits: &'a BTreeMap<ItemId, u32>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    group_revealed: &'a BTreeMap<ItemId, u32>,
}
