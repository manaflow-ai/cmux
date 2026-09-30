//! Shared presentation metadata for frontends: workspace groups and the
//! per-workspace group membership.
//!
//! The durable rows live in the workspace registry
//! (`workspace_registry/presentation_store.rs`). The mux keeps one immutable
//! snapshot of them, replaced after every commit while the registry lock is
//! held, so tree serialization never reads SQLite.

use super::*;
use crate::resource::BrowserPublicId;
use crate::workspace_registry::{
    FrontendBrowserRecord, PresentationSnapshot, WorkspaceGroupRecord, WorkspacePresentationUpdate,
    new_workspace_group_id, validate_workspace_group_id,
};

/// Per-snapshot data the tree serializer adds to the live [`State`]:
/// unread notification markers and the shared presentation metadata.
///
/// It dereferences to the notification map, so code that only reads
/// notifications keeps working unchanged.
#[derive(Debug, Clone, Default)]
pub struct TreeDecorations {
    pub notifications: HashMap<SurfaceId, SurfaceNotification>,
    pub presentation: Arc<PresentationSnapshot>,
    /// Working directory and git HEAD of each PTY placement.
    pub directories: HashMap<SurfaceId, TabDirectory>,
}

/// The directory a PTY tab presents (the shell's OSC 7 report, or its launch
/// directory) and the git HEAD of the repository containing it, resolved on
/// the machine that hosts the PTY.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TabDirectory {
    pub cwd: Option<String>,
    /// Branch name, or the abbreviated commit when HEAD is detached.
    pub git_branch: Option<String>,
    pub git_detached: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitHead {
    name: String,
    detached: bool,
}

/// A cached HEAD lookup is reused for this long, which bounds both the
/// filesystem work of a tree snapshot and the staleness of a branch switch
/// made without changing directory.
const GIT_HEAD_TTL: Duration = Duration::from_secs(2);
const GIT_HEAD_CACHE_LIMIT: usize = 4096;
const GIT_METADATA_MAX_BYTES: u64 = 4096;

fn read_small_file(path: &Path) -> Option<String> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > GIT_METADATA_MAX_BYTES {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

fn read_git_head_file(git_dir: &Path) -> Option<GitHead> {
    let head = read_small_file(&git_dir.join("HEAD"))?;
    let head = head.trim();
    if let Some(reference) = head.strip_prefix("ref:") {
        let reference = reference.trim();
        let name = reference.strip_prefix("refs/heads/").unwrap_or(reference);
        return (!name.is_empty()).then(|| GitHead { name: name.to_string(), detached: false });
    }
    (head.len() >= 7 && head.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| GitHead { name: head[..7].to_string(), detached: true })
}

/// Find the repository containing `directory` and read its HEAD without
/// running git. A `.git` file (worktrees, submodules) names the git dir.
pub(crate) fn read_git_head(directory: &Path) -> Option<GitHead> {
    let mut current = Some(directory);
    while let Some(candidate) = current {
        let dot_git = candidate.join(".git");
        match std::fs::metadata(&dot_git) {
            Ok(metadata) if metadata.is_dir() => return read_git_head_file(&dot_git),
            Ok(metadata) if metadata.is_file() => {
                let pointer = read_small_file(&dot_git)?;
                let git_dir = pointer.lines().find_map(|line| line.strip_prefix("gitdir:"))?.trim();
                let git_dir = Path::new(git_dir);
                let git_dir = if git_dir.is_absolute() {
                    git_dir.to_path_buf()
                } else {
                    candidate.join(git_dir)
                };
                return read_git_head_file(&git_dir);
            }
            _ => current = candidate.parent(),
        }
    }
    None
}

impl Deref for TreeDecorations {
    type Target = HashMap<SurfaceId, SurfaceNotification>;

    fn deref(&self) -> &Self::Target {
        &self.notifications
    }
}

impl TreeDecorations {
    /// A decoration set with notifications only, for tests and callers that
    /// build a tree snapshot without a mux.
    pub fn from_notifications(notifications: HashMap<SurfaceId, SurfaceNotification>) -> Self {
        Self { notifications, presentation: Arc::default(), directories: HashMap::new() }
    }
}

/// Result of `set-tab-pinned`: whether the flag changed and the tab's final
/// index in its pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabPinChange {
    pub changed: bool,
    pub index: usize,
}

fn surface_directories_in_state(state: &State) -> Vec<(SurfaceId, String)> {
    state
        .surfaces
        .iter()
        .filter(|(surface, _)| state.pane_of(**surface).is_some())
        .filter_map(|(surface, runtime)| {
            runtime.presented_directory().map(|directory| (*surface, directory))
        })
        .collect()
}

fn tab_is_pinned(state: &State, presentation: &PresentationSnapshot, surface: SurfaceId) -> bool {
    state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .is_some_and(|tab| presentation.pinned_tabs.contains(tab.as_str()))
}

pub(super) fn tab_changed_delta(
    state: &State,
    decorations: &TreeDecorations,
    surface: SurfaceId,
) -> Option<TreeDelta> {
    let pane = state.pane_of(surface)?;
    let (workspace, screen) = state.screen_of(pane)?;
    let entity =
        crate::server::tree_entity_json(state, decorations, TreeDeltaKind::TabChanged, surface)?;
    let index = state.panes.get(&pane)?.tabs.iter().position(|candidate| *candidate == surface);
    Some(TreeDelta {
        kind: TreeDeltaKind::TabChanged,
        workspace: state.workspaces[workspace].id,
        screen: Some(state.workspaces[workspace].screens[screen].id),
        pane: Some(pane),
        surface: Some(surface),
        index,
        entity,
        workspace_revision: None,
        transaction: None,
    })
}

/// Result of one group mutation: the group, its final index, and whether the
/// call changed durable state (a retried create returns `false`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceGroupChange {
    pub group: WorkspaceGroupRecord,
    pub index: usize,
    pub changed: bool,
}

impl Mux {
    pub fn presentation_snapshot(&self) -> Arc<PresentationSnapshot> {
        self.presentation.lock().unwrap().clone()
    }

    /// Reload the presentation snapshot from the registry. The caller holds
    /// the registry lock, so no other commit can interleave.
    pub(super) fn reload_presentation(&self, registry: &WorkspaceRegistry) -> anyhow::Result<()> {
        let snapshot = registry.presentation_snapshot()?;
        *self.presentation.lock().unwrap() = Arc::new(snapshot);
        Ok(())
    }

    /// Notifications, presentation, and tab directories for serializing the
    /// whole tree. Git HEAD lookups run after the state lock is released.
    pub fn tree_decorations(&self) -> TreeDecorations {
        let presentation = self.presentation_snapshot();
        let (notifications, directories) = {
            let state = self.state.lock().unwrap();
            (self.surface_notifications_in_state(&state), surface_directories_in_state(&state))
        };
        let directories = self.resolve_tab_directories(directories, true);
        TreeDecorations { notifications, presentation, directories }
    }

    /// The same as [`Self::tree_decorations`] for a caller that already
    /// holds the state lock. It never touches the filesystem, so git HEADs
    /// come from the cache only.
    pub(crate) fn tree_decorations_in_state(&self, state: &State) -> TreeDecorations {
        let presentation = self.presentation_snapshot();
        let notifications = self.surface_notifications_in_state(state);
        let directories = self.resolve_tab_directories(surface_directories_in_state(state), false);
        TreeDecorations { notifications, presentation, directories }
    }

    fn resolve_tab_directories(
        &self,
        directories: Vec<(SurfaceId, String)>,
        refresh: bool,
    ) -> HashMap<SurfaceId, TabDirectory> {
        let now = Instant::now();
        let mut heads: HashMap<String, Option<GitHead>> = HashMap::new();
        let mut result = HashMap::with_capacity(directories.len());
        for (surface, cwd) in directories {
            let head = match heads.get(&cwd) {
                Some(head) => head.clone(),
                None => {
                    let head = self.git_head(&cwd, now, refresh);
                    heads.insert(cwd.clone(), head.clone());
                    head
                }
            };
            result.insert(
                surface,
                TabDirectory {
                    git_branch: head.as_ref().map(|head| head.name.clone()),
                    git_detached: head.as_ref().is_some_and(|head| head.detached),
                    cwd: Some(cwd),
                },
            );
        }
        result
    }

    fn git_head(&self, cwd: &str, now: Instant, refresh: bool) -> Option<GitHead> {
        {
            let cache = self.git_heads.lock().unwrap();
            if let Some((checked, head)) = cache.get(cwd)
                && (!refresh || now.saturating_duration_since(*checked) < GIT_HEAD_TTL)
            {
                return head.clone();
            }
        }
        if !refresh {
            return None;
        }
        let head = read_git_head(Path::new(cwd));
        let mut cache = self.git_heads.lock().unwrap();
        if cache.len() >= GIT_HEAD_CACHE_LIMIT {
            cache.clear();
        }
        cache.insert(cwd.to_string(), (now, head.clone()));
        head
    }

    /// Tell subscribers that one tab's metadata (pin, directory, git HEAD,
    /// unread marker) changed, with the refreshed tab entity.
    pub(crate) fn emit_tab_changed(&self, surface: SurfaceId) {
        self.emit_tab_changed_for_transaction(surface, None);
    }

    /// Refresh the git HEAD for a terminal whose directory changed and emit
    /// `tab-changed` for each of its placements.
    pub(crate) fn emit_terminal_tabs_changed(&self, terminal: &TerminalPublicId) {
        let placements = self.with_state(|state| {
            state.placements_of_content(&ContentPublicId::Terminal(terminal.clone())).to_vec()
        });
        if placements.is_empty() {
            return;
        }
        let decorations = self.tree_decorations();
        let deltas = {
            let state = self.state.lock().unwrap();
            placements
                .iter()
                .filter_map(|surface| tab_changed_delta(&state, &decorations, *surface))
                .collect::<Vec<_>>()
        };
        for delta in deltas {
            self.emit(MuxEvent::TreeDelta(delta));
        }
    }

    /// Pin or unpin a tab placement. Pinned tabs sort first in their pane:
    /// pinning moves the tab to the end of the pinned run, unpinning moves
    /// it to the start of the unpinned run. The flag is durable and keyed by
    /// the public tab id, so it survives restarts and cross-pane moves.
    pub fn set_tab_pinned(
        self: &Arc<Self>,
        surface: SurfaceId,
        pinned: bool,
    ) -> anyhow::Result<TabPinChange> {
        let tab_id = self
            .with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        let changed = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let changed = registry.set_tab_pinned(tab_id.as_str(), pinned)?;
            self.reload_presentation(&registry)?;
            changed
        };
        let presentation = self.presentation_snapshot();
        let target = self.with_state(|state| {
            let pane_id = state.pane_of(surface)?;
            let pane = state.panes.get(&pane_id)?;
            let old_index = pane.tabs.iter().position(|candidate| *candidate == surface)?;
            let other_pinned = pane
                .tabs
                .iter()
                .filter(|candidate| **candidate != surface)
                .filter(|candidate| tab_is_pinned(state, &presentation, **candidate))
                .count();
            Some((pane_id, old_index, other_pinned))
        });
        let (pane, old_index, final_index) =
            target.ok_or_else(|| anyhow::anyhow!("surface {surface} has no pane"))?;
        if final_index != old_index {
            let insertion = if final_index > old_index { final_index + 1 } else { final_index };
            self.move_tab(surface, pane, insertion);
        }
        let index = self
            .with_state(|state| {
                state.panes.get(&pane)?.tabs.iter().position(|candidate| *candidate == surface)
            })
            .unwrap_or(old_index);
        if changed {
            self.publish_journal_event();
            self.emit_tab_changed(surface);
        }
        Ok(TabPinChange { changed, index })
    }

    /// Clamp a `move-tab` insertion index so pinned tabs stay ahead of
    /// unpinned ones in the destination pane.
    pub fn pinned_tab_move_index(&self, surface: SurfaceId, pane: PaneId, index: usize) -> usize {
        let presentation = self.presentation_snapshot();
        self.with_state(|state| {
            let Some(target) = state.panes.get(&pane) else { return index };
            let pinned = tab_is_pinned(state, &presentation, surface);
            let others = target.tabs.iter().filter(|candidate| **candidate != surface);
            let other_pinned = others
                .clone()
                .filter(|candidate| tab_is_pinned(state, &presentation, **candidate))
                .count();
            let other_count = others.count();
            let old_index = (state.pane_of(surface) == Some(pane))
                .then(|| target.tabs.iter().position(|candidate| *candidate == surface))
                .flatten();
            let final_index = match old_index {
                Some(old) if index > old => index - 1,
                _ => index,
            }
            .min(other_count);
            let clamped =
                if pinned { final_index.min(other_pinned) } else { final_index.max(other_pinned) };
            match old_index {
                Some(old) if clamped > old => clamped + 1,
                _ => clamped,
            }
        })
    }

    pub fn workspace_groups(&self) -> Vec<WorkspaceGroupRecord> {
        self.presentation_snapshot().groups.clone()
    }

    /// Create a sidebar group. A caller-chosen `id` makes retries
    /// idempotent: the same id and name return the stored group unchanged.
    pub fn create_workspace_group(
        &self,
        id: Option<String>,
        name: String,
        color: Option<String>,
        collapsed: bool,
        index: Option<usize>,
    ) -> anyhow::Result<WorkspaceGroupChange> {
        let id = id.unwrap_or_else(new_workspace_group_id);
        let mut registry = self.workspace_registry.lock().unwrap();
        let (group, changed) =
            registry.create_workspace_group(&id, &name, color.as_deref(), collapsed, index)?;
        self.reload_presentation(&registry)?;
        drop(registry);
        self.finish_group_change(group, changed)
    }

    /// Rename, recolor (`Some(None)` clears), or collapse a group.
    pub fn update_workspace_group(
        &self,
        id: &str,
        name: Option<String>,
        color: Option<Option<String>>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<WorkspaceGroupChange> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let before = self.presentation_snapshot().group(id).cloned();
        let group = registry.update_workspace_group(
            id,
            name.as_deref(),
            color.as_ref().map(Option::as_deref),
            collapsed,
        )?;
        self.reload_presentation(&registry)?;
        drop(registry);
        let changed = before.as_ref() != Some(&group);
        self.finish_group_change(group, changed)
    }

    /// Delete a group. Its workspaces keep their registry order and become
    /// ungrouped. Returns the keys of the ungrouped workspaces.
    pub fn delete_workspace_group(&self, id: &str) -> anyhow::Result<Vec<String>> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let ungrouped = registry.delete_workspace_group(id)?;
        self.reload_presentation(&registry)?;
        drop(registry);
        self.publish_journal_event();
        self.emit(MuxEvent::TreeChanged);
        Ok(ungrouped)
    }

    /// Move a group to an insertion index among groups (the same
    /// insertion-point rule as `move-workspace`).
    pub fn move_workspace_group(
        &self,
        id: &str,
        index: usize,
    ) -> anyhow::Result<WorkspaceGroupChange> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let before = self.presentation_snapshot().group_index(id);
        registry.move_workspace_group(id, index)?;
        self.reload_presentation(&registry)?;
        drop(registry);
        let snapshot = self.presentation_snapshot();
        let group = snapshot
            .group(id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown workspace group {id}"))?;
        let changed = before != snapshot.group_index(id);
        self.finish_group_change(group, changed)
    }

    fn finish_group_change(
        &self,
        group: WorkspaceGroupRecord,
        changed: bool,
    ) -> anyhow::Result<WorkspaceGroupChange> {
        let index = self
            .presentation_snapshot()
            .group_index(&group.id)
            .ok_or_else(|| anyhow::anyhow!("unknown workspace group {}", group.id))?;
        if changed {
            self.publish_journal_event();
            // Groups are session-level, not tree entities; frontends refetch
            // `list-workspaces`, which carries the ordered `groups` array.
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(WorkspaceGroupChange { group, index, changed })
    }

    /// Put a workspace in a group (`None` = ungrouped) and optionally
    /// reorder it among that section's members.
    ///
    /// Group membership is a partition over the one durable workspace
    /// order, so the in-group order is the registry order filtered by group.
    /// `index` is the workspace's final zero-based position among the
    /// destination members; `None` keeps its registry position. A group move
    /// commits one workspace-registry revision, so `origin`/`mutation_id`
    /// retries and `expected_revision` guards work as for `move-workspace`.
    #[allow(clippy::too_many_arguments)]
    pub fn move_workspace_to_group(
        &self,
        workspace: Option<WorkspaceId>,
        requested_key: Option<&str>,
        group: Option<String>,
        index: Option<usize>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        if let Some(group) = &group {
            validate_workspace_group_id(group)?;
        }
        let fingerprint = serde_json::json!({
            "op": "move-workspace-to-group",
            "workspace": workspace,
            "key": requested_key,
            "group": group,
            "index": index,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            return workspace_mutation_result(&commit);
        }
        let (delta, result) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let old_idx = resolve_workspace_index(&state, workspace, requested_key)?;
            let workspace_id = state.workspaces[old_idx].id;
            let key = state.workspaces[old_idx].key.clone();
            let presentation = self.presentation_snapshot();
            if let Some(group) = &group {
                anyhow::ensure!(
                    presentation.group(group).is_some(),
                    "unknown workspace group {group}"
                );
            }
            let group_of = |index: usize| {
                presentation
                    .workspace(&state.workspaces[index].key)
                    .and_then(|record| record.group.as_deref())
            };
            let remaining =
                (0..state.workspaces.len()).filter(|index| *index != old_idx).collect::<Vec<_>>();
            let members = remaining
                .iter()
                .copied()
                .filter(|index| group_of(*index) == group.as_deref())
                .collect::<Vec<_>>();
            let position_in_remaining = |target: usize| {
                remaining.iter().position(|candidate| *candidate == target).unwrap_or(old_idx)
            };
            let new_idx = match (index, members.first(), members.last()) {
                (Some(index), Some(_), Some(_)) if index < members.len() => {
                    position_in_remaining(members[index])
                }
                (Some(_), Some(_), Some(last)) => position_in_remaining(*last) + 1,
                _ => old_idx,
            }
            .min(state.workspaces.len().saturating_sub(1));
            let previous_group = group_of(old_idx).map(str::to_string);
            let changed = new_idx != old_idx || previous_group != group;
            let mut desired = self.registry_projection(&state);
            let moved = desired.remove(old_idx);
            desired.insert(new_idx, moved);
            let update = WorkspacePresentationUpdate {
                group: Some(group.clone()),
                ..WorkspacePresentationUpdate::default()
            };
            let commit = {
                let desired_active_workspace = state
                    .workspaces
                    .get(state.active_workspace)
                    .map(|workspace| &workspace.public_id);
                registry.commit_workspace_presentation(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-moved",
                    &key,
                    &desired,
                    desired_active_workspace,
                    &update,
                    &serde_json::json!({
                        "workspace": workspace_id,
                        "key": key.clone(),
                        "index": new_idx,
                        "group": group,
                        "changed": changed,
                    }),
                )?
            };
            let resource_revision = registry.snapshot()?.resource_revision;
            self.reload_presentation(&registry)?;
            let active_id = state.workspaces.get(state.active_workspace).map(|ws| ws.id);
            state.move_workspace(old_idx, new_idx);
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            Self::rebuild_split_screen_index(&mut state);
            state.workspace_revision = commit.revision;
            state.resource_revision = resource_revision;
            let decorations = self.tree_decorations_in_state(&state);
            let entity = crate::server::tree_entity_json(
                &state,
                &decorations,
                TreeDeltaKind::WorkspaceMoved,
                workspace_id,
            )
            .expect("grouped workspace is present in tree snapshot");
            (
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceMoved,
                    workspace: workspace_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(new_idx),
                    entity,
                    workspace_revision: Some(commit.revision),
                    transaction: None,
                },
                workspace_mutation_result(&commit)?,
            )
        };
        self.emit_committed_workspace_delta(&registry, delta, false);
        drop(registry);
        self.publish_resource_event();
        Ok(result)
    }
}

impl Mux {
    /// Set, clear, or keep a workspace's shared color, icon, and custom
    /// title. The write commits one workspace-registry revision (the
    /// registry order is unchanged), so it takes the durable mutation
    /// envelope and emits `workspace-changed` with the full entity.
    pub fn set_workspace_metadata(
        &self,
        workspace: Option<WorkspaceId>,
        requested_key: Option<&str>,
        update: WorkspacePresentationUpdate,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        anyhow::ensure!(update.group.is_none(), "use move-workspace-to-group to change a group");
        update.validate()?;
        let fingerprint = serde_json::json!({
            "op": "set-workspace-metadata",
            "workspace": workspace,
            "key": requested_key,
            "color": update.color,
            "icon": update.icon,
            "title": update.title,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            return workspace_mutation_result(&commit);
        }
        let (delta, result) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, workspace, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            let key = state.workspaces[index].key.clone();
            let before = self.presentation_snapshot().workspace(&key).cloned().unwrap_or_default();
            let mut after = before.clone();
            if let Some(color) = &update.color {
                after.color = color.clone();
            }
            if let Some(icon) = &update.icon {
                after.icon = icon.clone();
            }
            if let Some(title) = &update.title {
                after.title = title.clone();
            }
            let changed = before != after;
            let desired = self.registry_projection(&state);
            let commit = {
                let desired_active_workspace = state
                    .workspaces
                    .get(state.active_workspace)
                    .map(|workspace| &workspace.public_id);
                registry.commit_workspace_presentation(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-changed",
                    &key,
                    &desired,
                    desired_active_workspace,
                    &update,
                    &serde_json::json!({
                        "workspace": workspace_id,
                        "key": key.clone(),
                        "index": index,
                        "changed": changed,
                    }),
                )?
            };
            let resource_revision = registry.snapshot()?.resource_revision;
            self.reload_presentation(&registry)?;
            state.workspace_revision = commit.revision;
            state.resource_revision = resource_revision;
            let decorations = self.tree_decorations_in_state(&state);
            let entity = crate::server::tree_entity_json(
                &state,
                &decorations,
                TreeDeltaKind::WorkspaceChanged,
                workspace_id,
            )
            .expect("changed workspace is present in tree snapshot");
            (
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceChanged,
                    workspace: workspace_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                    workspace_revision: Some(commit.revision),
                    transaction: None,
                },
                workspace_mutation_result(&commit)?,
            )
        };
        self.emit_committed_workspace_delta(&registry, delta, false);
        drop(registry);
        self.publish_resource_event();
        Ok(result)
    }
}

impl Mux {
    /// Whether this browser surface's page is rendered by a frontend
    /// (WebKit or CEF) instead of a daemon-attached CDP target.
    pub(crate) fn is_frontend_browser_surface(&self, surface: &Surface) -> bool {
        self.frontend_browser_id(surface).is_some()
    }

    fn frontend_browser_id(&self, surface: &Surface) -> Option<BrowserPublicId> {
        let identity = surface.resource_identity()?;
        let ContentPublicId::Browser(id) = &identity.content_id else { return None };
        self.presentation_snapshot().frontend_browsers.contains_key(id.as_str()).then(|| id.clone())
    }

    /// The frontend record of a browser surface, if it is frontend-rendered.
    pub fn frontend_browser(&self, surface: &Surface) -> Option<FrontendBrowserRecord> {
        let id = self.frontend_browser_id(surface)?;
        self.presentation_snapshot().frontend_browsers.get(id.as_str()).cloned()
    }

    /// Create a browser tab whose page the frontend renders. The record is
    /// registered durably before the tab commits, under the browser id the
    /// creation then uses, so neither a live daemon nor a restarted one ever
    /// bootstraps a CDP target for it. A failed creation removes the record.
    pub fn new_frontend_browser_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        record: FrontendBrowserRecord,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        record.validate()?;
        let browser_id = BrowserPublicId::random()?;
        {
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.put_frontend_browser(browser_id.as_str(), &record)?;
            self.reload_presentation(&registry)?;
        }
        let fields = Map::from_iter([(
            "frontend_browser_id".to_string(),
            Value::String(browser_id.as_str().to_string()),
        )]);
        match self.new_browser_tab_with_fields(record.url.clone(), pane, size, fields) {
            Ok(surface) => {
                if let Some(runtime) = surface.as_browser()
                    && runtime.set_frontend_location(None, record.title)
                {
                    self.emit_tab_changed(surface.id);
                }
                self.publish_journal_event();
                Ok(surface)
            }
            Err(error) => {
                let mut registry = self.workspace_registry.lock().unwrap();
                if registry.delete_frontend_browser(browser_id.as_str()).is_ok() {
                    let _ = self.reload_presentation(&registry);
                }
                Err(error)
            }
        }
    }

    /// Record the URL, title, or favicon a frontend-rendered browser
    /// reports. `favicon_url: Some(None)` clears the favicon.
    pub fn update_frontend_browser_tab(
        &self,
        surface: SurfaceId,
        url: Option<String>,
        title: Option<String>,
        favicon_url: Option<Option<String>>,
    ) -> anyhow::Result<(FrontendBrowserRecord, bool)> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        let browser_id = self.frontend_browser_id(&runtime).ok_or_else(|| {
            anyhow::anyhow!("surface {surface} is not a frontend-rendered browser")
        })?;
        let (record, changed) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let result = registry.update_frontend_browser(
                browser_id.as_str(),
                url.as_deref(),
                title.as_deref(),
                favicon_url.as_ref().map(Option::as_deref),
            )?;
            if result.1 {
                self.reload_presentation(&registry)?;
            }
            result
        };
        if changed {
            if let Some(browser) = runtime.as_browser() {
                browser.set_frontend_location(url, title.clone());
            }
            self.publish_journal_event();
            if let Some(title) = title {
                self.emit(MuxEvent::TitleChanged { surface, title: Arc::from(title) });
            }
            self.emit_tab_changed(surface);
        }
        Ok((record, changed))
    }
}

/// Result of `ack-tab-notifications`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabNotificationAck {
    /// Whether the tab had an unread marker that this call cleared.
    pub cleared: bool,
    /// Retained notifications of the tab's content now acknowledged.
    pub acknowledged: Vec<NotificationPublicId>,
}

impl Mux {
    /// Acknowledge a tab's notifications explicitly, independent of focus
    /// or selection: clear the shared unread marker of the tab's content
    /// (every view of one terminal shares it) and durably record the
    /// acknowledgement, so a restart does not bring the marker back.
    pub fn acknowledge_tab_notifications(
        &self,
        surface: SurfaceId,
    ) -> anyhow::Result<TabNotificationAck> {
        let (terminal, placements) = {
            let state = self.state.lock().unwrap();
            let runtime = state
                .surfaces
                .get(&surface)
                .or_else(|| state.terminal_runtime_by_id(surface))
                .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
            let terminal = runtime.terminal_public_id().cloned();
            let placements = match &terminal {
                Some(terminal) => state
                    .placements_of_content(&ContentPublicId::Terminal(terminal.clone()))
                    .to_vec(),
                None => vec![surface],
            };
            (terminal, placements)
        };
        let cleared = match &terminal {
            Some(terminal) => {
                self.terminal_notifications.lock().unwrap().remove(terminal).is_some()
            }
            None => self.placement_notifications.lock().unwrap().remove(&surface).is_some(),
        };
        let acknowledged = self.persist_notification_acks(terminal.as_ref(), surface)?;
        if cleared {
            for placement in placements {
                self.emit_tab_changed(placement);
            }
        }
        Ok(TabNotificationAck { cleared, acknowledged })
    }

    /// Durably acknowledge the retained notifications of one terminal, or
    /// of one non-terminal placement.
    pub(crate) fn persist_notification_acks(
        &self,
        terminal: Option<&TerminalPublicId>,
        surface: SurfaceId,
    ) -> anyhow::Result<Vec<NotificationPublicId>> {
        let ids = self
            .notification_ledger
            .lock()
            .unwrap()
            .iter()
            .filter(|entry| match terminal {
                Some(terminal) => entry.terminal_id.as_ref() == Some(terminal),
                None => entry.terminal_id.is_none() && entry.surface == Some(surface),
            })
            .map(|entry| entry.id.clone())
            .collect::<Vec<_>>();
        if ids.is_empty() {
            return Ok(ids);
        }
        let strings = ids.iter().map(|id| id.as_str().to_string()).collect::<Vec<_>>();
        let subjects = terminal
            .map(|terminal| crate::JournalSubject {
                kind: "terminal".into(),
                id: terminal.as_str().to_string(),
            })
            .into_iter()
            .collect();
        self.workspace_registry.lock().unwrap().ack_notifications_durable(
            &strings,
            now_ms(),
            subjects,
        )?;
        self.publish_journal_event();
        Ok(ids)
    }

    /// Retained notifications, newest first, with whether each was
    /// acknowledged.
    pub fn notification_rows(
        &self,
        limit: usize,
    ) -> anyhow::Result<Vec<(ResourceNotification, bool)>> {
        let rows = self.resource_notifications(limit);
        let acked = self.workspace_registry.lock().unwrap().acked_notification_ids()?;
        Ok(rows
            .into_iter()
            .map(|row| {
                let acknowledged = acked.contains(row.id.as_str());
                (row, acknowledged)
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) struct PresentationTestSession {
        root: std::path::PathBuf,
        session: &'static str,
    }

    impl PresentationTestSession {
        pub(super) fn new(session: &'static str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "cmux-presentation-{session}-{}",
                WorkspacePublicId::random().unwrap()
            ));
            Self { root, session }
        }

        pub(super) fn open(&self) -> Arc<Mux> {
            let registry = WorkspaceRegistry::open(&self.root, self.session).unwrap();
            Mux::from_workspace_registry(
                self.session.into(),
                SurfaceOptions::default(),
                registry,
                ProviderWorkspaceState::default(),
                true,
            )
            .unwrap()
        }
    }

    impl Drop for PresentationTestSession {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn keys(mux: &Mux) -> Vec<String> {
        mux.with_state(|state| state.workspaces.iter().map(|ws| ws.key.clone()).collect())
    }

    fn group_of(mux: &Mux, key: &str) -> Option<String> {
        mux.presentation_snapshot().workspace(key).and_then(|record| record.group.clone())
    }

    fn move_to_group(mux: &Mux, key: &str, group: Option<&str>, index: Option<usize>) {
        mux.move_workspace_to_group(
            None,
            Some(key),
            group.map(str::to_string),
            index,
            None,
            None,
            &WorkspaceMutation::local("presentation-test"),
        )
        .unwrap();
    }

    #[test]
    fn cmux_next_workspace_groups_survive_restart_with_order_membership_and_collapse() {
        let session = PresentationTestSession::new("groups");
        let mux = session.open();
        let a = mux.create_empty_workspace(Some("a".into()), None, None).unwrap().key;
        let b = mux.create_empty_workspace(Some("b".into()), None, None).unwrap().key;
        let c = mux.create_empty_workspace(Some("c".into()), None, None).unwrap().key;

        let work = mux
            .create_workspace_group(Some("work".into()), "Work".into(), None, false, None)
            .unwrap();
        assert_eq!((work.index, work.changed), (0, true));
        let personal = mux
            .create_workspace_group(
                Some("personal".into()),
                "Personal".into(),
                Some("gray".into()),
                false,
                Some(0),
            )
            .unwrap();
        assert_eq!(personal.index, 0);
        // A retried create with the same id and name is a no-op.
        let retry = mux
            .create_workspace_group(Some("work".into()), "Work".into(), None, false, None)
            .unwrap();
        assert!(!retry.changed);
        assert!(
            mux.create_workspace_group(Some("work".into()), "Other".into(), None, false, None)
                .is_err()
        );

        move_to_group(&mux, &a, Some("work"), None);
        // `c` lands before `a` inside `work`: its final in-group index is 0.
        move_to_group(&mux, &c, Some("work"), Some(0));
        assert_eq!(keys(&mux), vec![c.clone(), a.clone(), b.clone()]);
        assert_eq!(group_of(&mux, &a).as_deref(), Some("work"));
        assert_eq!(group_of(&mux, &c).as_deref(), Some("work"));
        assert_eq!(group_of(&mux, &b), None);
        // Reordering within the group moves only relative to its members.
        move_to_group(&mux, &c, Some("work"), Some(1));
        assert_eq!(keys(&mux), vec![a.clone(), c.clone(), b.clone()]);
        assert!(
            mux.move_workspace_to_group(
                None,
                Some(&b),
                Some("missing".into()),
                None,
                None,
                None,
                &WorkspaceMutation::local("presentation-test"),
            )
            .is_err()
        );

        mux.update_workspace_group("work", None, Some(Some("#445566".into())), Some(true)).unwrap();
        let moved = mux.move_workspace_group("work", 0).unwrap();
        assert_eq!(moved.index, 0);
        drop(mux);

        let mux = session.open();
        let groups = mux.workspace_groups();
        assert_eq!(
            groups.iter().map(|group| group.id.as_str()).collect::<Vec<_>>(),
            vec!["work", "personal"]
        );
        assert!(groups[0].collapsed);
        assert_eq!(groups[0].color.as_deref(), Some("#445566"));
        assert_eq!(groups[1].color.as_deref(), Some("gray"));
        assert_eq!(keys(&mux), vec![a.clone(), c.clone(), b.clone()]);
        assert_eq!(group_of(&mux, &a).as_deref(), Some("work"));

        // Deleting a group ungroups its workspaces in place.
        let mut ungrouped = mux.delete_workspace_group("work").unwrap();
        ungrouped.sort();
        let mut expected = vec![a.clone(), c.clone()];
        expected.sort();
        assert_eq!(ungrouped, expected);
        assert_eq!(group_of(&mux, &a), None);
        assert_eq!(keys(&mux), vec![a, c, b]);
        drop(mux);
        let mux = session.open();
        assert_eq!(mux.workspace_groups().len(), 1);
    }

    #[test]
    fn cmux_next_workspace_metadata_survives_restart_and_emits_workspace_changed() {
        let session = PresentationTestSession::new("metadata");
        let mux = session.open();
        let key = mux.create_empty_workspace(Some("repo".into()), None, None).unwrap().key;
        let events = mux.subscribe();
        let update = WorkspacePresentationUpdate {
            group: None,
            color: Some(Some("gray".into())),
            icon: Some(Some("terminal.fill".into())),
            title: Some(Some("Release train".into())),
        };
        let result = mux
            .set_workspace_metadata(
                None,
                Some(&key),
                update.clone(),
                None,
                None,
                &WorkspaceMutation::new("meta-1", "presentation-test").unwrap(),
            )
            .unwrap();
        assert!(result.changed);
        let delta = std::iter::from_fn(|| events.try_recv().ok())
            .find_map(|event| match event {
                MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::WorkspaceChanged => {
                    Some(delta)
                }
                _ => None,
            })
            .expect("workspace-changed delta");
        assert_eq!(delta.workspace_revision, Some(result.revision));
        assert_eq!(delta.entity["color"], "gray");
        assert_eq!(delta.entity["icon"], "terminal.fill");
        assert_eq!(delta.entity["title"], "Release train");
        // Absent fields are unchanged; null clears one field.
        mux.set_workspace_metadata(
            None,
            Some(&key),
            WorkspacePresentationUpdate { title: Some(None), ..Default::default() },
            None,
            None,
            &WorkspaceMutation::local("presentation-test"),
        )
        .unwrap();
        for bad in [
            WorkspacePresentationUpdate {
                icon: Some(Some("Bad Icon".into())),
                ..Default::default()
            },
            WorkspacePresentationUpdate { color: Some(Some("#12".into())), ..Default::default() },
            WorkspacePresentationUpdate { title: Some(Some(" ".into())), ..Default::default() },
        ] {
            assert!(
                mux.set_workspace_metadata(
                    None,
                    Some(&key),
                    bad,
                    None,
                    None,
                    &WorkspaceMutation::local("presentation-test"),
                )
                .is_err()
            );
        }
        drop(events);
        drop(mux);

        let mux = session.open();
        let record = mux.presentation_snapshot().workspace(&key).cloned().unwrap();
        assert_eq!(record.color.as_deref(), Some("gray"));
        assert_eq!(record.icon.as_deref(), Some("terminal.fill"));
        assert_eq!(record.title, None);
        let replay = mux
            .set_workspace_metadata(
                None,
                Some(&key),
                update,
                None,
                None,
                &WorkspaceMutation::new("meta-1", "presentation-test").unwrap(),
            )
            .unwrap();
        assert!(replay.replayed);
    }

    fn pane_tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
        mux.with_state(|state| state.panes[&pane].tabs.clone())
    }

    #[test]
    fn cmux_next_pinned_tabs_sort_first_and_survive_restart() {
        let session = PresentationTestSession::new("pins");
        let mux = session.open();
        let first = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
        let second = mux.new_tab(Some(pane), None, None).unwrap().id;
        let third = mux.new_tab(Some(pane), None, None).unwrap().id;
        assert_eq!(pane_tabs(&mux, pane), vec![first, second, third]);

        let pinned = mux.set_tab_pinned(third, true).unwrap();
        assert_eq!(pinned, TabPinChange { changed: true, index: 0 });
        assert_eq!(pane_tabs(&mux, pane), vec![third, first, second]);
        let pinned = mux.set_tab_pinned(second, true).unwrap();
        assert_eq!(pinned.index, 1);
        assert_eq!(pane_tabs(&mux, pane), vec![third, second, first]);
        assert!(!mux.set_tab_pinned(second, true).unwrap().changed);

        // An unpinned tab cannot move ahead of the pinned run, and a pinned
        // tab cannot move behind it.
        let clamped = mux.pinned_tab_move_index(first, pane, 0);
        mux.move_tab(first, pane, clamped);
        assert_eq!(pane_tabs(&mux, pane), vec![third, second, first]);
        let clamped = mux.pinned_tab_move_index(third, pane, 3);
        mux.move_tab(third, pane, clamped);
        assert_eq!(pane_tabs(&mux, pane), vec![second, third, first]);

        let unpinned = mux.set_tab_pinned(second, false).unwrap();
        assert_eq!(unpinned.index, 1);
        assert_eq!(pane_tabs(&mux, pane), vec![third, second, first]);
        let pinned_tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&third].clone());
        // The flag is durable: the registry itself reports it.
        let durable = mux.workspace_registry.lock().unwrap().presentation_snapshot().unwrap();
        assert_eq!(durable.pinned_tabs.len(), 1);
        assert!(durable.pinned_tabs.contains(pinned_tab_id.as_str()));
        let decorations = mux.tree_decorations();
        let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
        let tabs =
            tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"].as_array().unwrap().clone();
        assert_eq!(tabs[0]["pinned"], true);
        assert_eq!(tabs[1]["pinned"], false);
    }

    #[test]
    fn cmux_next_git_head_reads_branches_worktrees_and_detached_heads() {
        let root = std::env::temp_dir()
            .join(format!("cmux-git-head-{}", WorkspacePublicId::random().unwrap()));
        let repo = root.join("repo");
        let nested = repo.join("src").join("deep");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/feature/tabs\n").unwrap();
        assert_eq!(
            read_git_head(&nested),
            Some(GitHead { name: "feature/tabs".into(), detached: false })
        );

        let worktree = root.join("worktree");
        let worktree_git = root.join("gitdirs").join("worktree");
        std::fs::create_dir_all(&worktree).unwrap();
        std::fs::create_dir_all(&worktree_git).unwrap();
        std::fs::write(worktree.join(".git"), "gitdir: ../gitdirs/worktree\n").unwrap();
        std::fs::write(worktree_git.join("HEAD"), "0123456789abcdef0123456789abcdef01234567\n")
            .unwrap();
        assert_eq!(
            read_git_head(&worktree),
            Some(GitHead { name: "0123456".into(), detached: true })
        );
        assert_eq!(read_git_head(&root.join("gitdirs")), None);

        let mux = Mux::new_for_test("git-heads", SurfaceOptions::default());
        let nested_path = nested.to_string_lossy().into_owned();
        let directories = mux.resolve_tab_directories(vec![(7, nested_path.clone())], true);
        assert_eq!(
            directories[&7],
            TabDirectory {
                cwd: Some(nested_path.clone()),
                git_branch: Some("feature/tabs".into()),
                git_detached: false,
            }
        );
        // Cache-only resolution (used under the state lock) never reads disk.
        let cached = mux.resolve_tab_directories(vec![(8, nested_path)], false);
        assert_eq!(cached[&8].git_branch.as_deref(), Some("feature/tabs"));
        let unknown = mux.resolve_tab_directories(vec![(9, "/nonexistent-cmux".into())], false);
        assert_eq!(unknown[&9].git_branch, None);
        let _ = std::fs::remove_dir_all(&root);
    }

    fn tab_json(mux: &Mux, surface: SurfaceId) -> Value {
        let decorations = mux.tree_decorations();
        mux.with_state(|state| {
            crate::server::tree_entity_json(state, &decorations, TreeDeltaKind::TabChanged, surface)
        })
        .expect("tab is present in the tree")
    }

    #[test]
    fn cmux_next_frontend_browser_tabs_persist_without_a_cdp_target() {
        let session = PresentationTestSession::new("frontend-browser");
        let mux = session.open();
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let record = FrontendBrowserRecord {
            engine: "webkit".into(),
            url: "https://example.com/start".into(),
            title: Some("Example".into()),
            favicon_url: None,
            profile_id: Some("default".into()),
        };
        assert!(
            mux.new_frontend_browser_tab(
                Some(pane),
                FrontendBrowserRecord { engine: "gecko".into(), ..record.clone() },
                None,
            )
            .is_err()
        );
        let browser = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap();
        assert_eq!(browser.kind(), SurfaceKind::Browser);
        assert!(mux.is_frontend_browser_surface(&browser));
        assert_eq!(mux.presentation_snapshot().frontend_browsers.len(), 1);
        let tab = tab_json(&mux, browser.id);
        assert_eq!(tab["kind"], "browser");
        assert_eq!(tab["browser_renderer"], "frontend");
        assert_eq!(tab["browser_engine"], "webkit");
        assert_eq!(tab["browser_profile_id"], "default");
        assert_eq!(tab["url"], "https://example.com/start");
        assert_eq!(tab["title"], "Example");
        assert!(tab["browser_status"].is_null());

        let (updated, changed) = mux
            .update_frontend_browser_tab(
                browser.id,
                Some("https://example.com/next".into()),
                Some("Next".into()),
                Some(Some("https://example.com/favicon.ico".into())),
            )
            .unwrap();
        assert!(changed);
        assert_eq!(updated.url, "https://example.com/next");
        let tab = tab_json(&mux, browser.id);
        assert_eq!(tab["url"], "https://example.com/next");
        assert_eq!(tab["title"], "Next");
        assert_eq!(tab["favicon_url"], "https://example.com/favicon.ico");
        // A PTY tab is not a frontend browser.
        assert!(mux.update_frontend_browser_tab(terminal, None, Some("x".into()), None).is_err());
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&browser.id].clone());
        drop(browser);
        drop(mux);

        let mux = session.open();
        let restored = mux
            .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
            .and_then(|surface| mux.surface(surface))
            .expect("frontend browser tab restored");
        assert!(mux.is_frontend_browser_surface(&restored));
        let tab = tab_json(&mux, restored.id);
        assert_eq!(tab["url"], "https://example.com/next");
        assert_eq!(tab["title"], "Next");
        assert_eq!(tab["browser_renderer"], "frontend");
        assert_eq!(tab["favicon_url"], "https://example.com/favicon.ico");
    }

    #[test]
    fn cmux_next_remote_terminal_tabs_persist_across_restart() {
        let session = PresentationTestSession::new("remote-terminal");
        let mux = session.open();
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let record = RemoteTerminalRecord {
            session_id: "0b7f2c1e-4d3a-4f6b-9c8d-1a2b3c4d5e6f".into(),
            terminal_id: "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f".into(),
            session_name: "build-box".into(),
            title: Some("cargo build".into()),
        };
        let remote = mux.new_remote_terminal_tab(Some(pane), record, None).unwrap();
        assert!(mux.is_frontend_rendered_surface(&remote));
        assert!(mux.frontend_browser(&remote).is_none(), "a remote terminal is not a browser record");
        mux.update_remote_terminal_tab(
            remote.id,
            RemoteTerminalUpdate { snapshot: Some(Some("$ cargo build\n".into())), ..Default::default() },
        )
        .unwrap();
        let tab = tab_json(&mux, remote.id);
        assert_eq!(tab["kind"], "remote-terminal");
        assert_eq!(tab["title"], "cargo build");
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&remote.id].clone());
        drop(remote);
        drop(mux);

        let mux = session.open();
        let restored = mux
            .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
            .and_then(|surface| mux.surface(surface))
            .expect("remote-terminal tab restored");
        assert!(mux.is_frontend_rendered_surface(&restored));
        let tab = tab_json(&mux, restored.id);
        assert_eq!(tab["kind"], "remote-terminal");
        assert_eq!(tab["title"], "cargo build");
        assert_eq!(tab["remote"]["session_name"], "build-box");
        assert_eq!(tab["remote"]["terminal_id"], "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f");
        assert_eq!(
            mux.remote_terminal_snapshot(restored.id).unwrap().as_deref(),
            Some("$ cargo build\n")
        );
    }

    fn durable_unread(mux: &Mux) -> Vec<bool> {
        let projections = mux.workspace_registry.lock().unwrap().public_projections().unwrap();
        projections.notifications.iter().map(|notification| notification.unread).collect()
    }

    #[test]
    fn cmux_next_tab_notification_ack_is_explicit_and_durable() {
        let session = PresentationTestSession::new("notification-ack");
        let mux = session.open();
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal = surface.terminal_public_id().cloned().expect("terminal tab");
        let surface = surface.id;
        mux.post_notification(
            "build done".into(),
            "".into(),
            NotificationLevel::Info,
            Some(surface),
        )
        .unwrap();
        assert!(mux.terminal_notification(&terminal).is_some_and(|marker| marker.unread));
        let decorations = mux.tree_decorations();
        let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
        assert_eq!(tree["workspaces"][0]["unread_count"], 1);
        assert_eq!(durable_unread(&mux), vec![true]);

        let ack = mux.acknowledge_tab_notifications(surface).unwrap();
        assert!(ack.cleared);
        assert_eq!(ack.acknowledged.len(), 1);
        assert!(mux.terminal_notification(&terminal).is_none());
        let rows = mux.notification_rows(10).unwrap();
        assert!(rows.iter().all(|(_, acknowledged)| *acknowledged));
        // The acknowledgement is what a restart restores from.
        assert_eq!(durable_unread(&mux), vec![false]);
        // A second acknowledgement is a no-op, not an error.
        assert!(!mux.acknowledge_tab_notifications(surface).unwrap().cleared);

        // A new notification is unread again until acknowledged; the legacy
        // clear (selecting the tab) persists its acknowledgement too.
        mux.post_notification(
            "tests failed".into(),
            "".into(),
            NotificationLevel::Error,
            Some(surface),
        )
        .unwrap();
        assert_eq!(durable_unread(&mux), vec![false, true]);
        assert!(mux.clear_surface_notification(surface));
        assert_eq!(durable_unread(&mux), vec![false, false]);
    }

    #[test]
    fn cmux_next_workspace_group_move_replays_by_mutation_id() {
        let session = PresentationTestSession::new("group-replay");
        let mux = session.open();
        let a = mux.create_empty_workspace(None, None, None).unwrap().key;
        mux.create_empty_workspace(None, None, None).unwrap();
        mux.create_workspace_group(Some("g".into()), "G".into(), None, false, None).unwrap();
        let mutation = WorkspaceMutation::new("group-move-1", "presentation-test").unwrap();
        let first = mux
            .move_workspace_to_group(None, Some(&a), Some("g".into()), None, None, None, &mutation)
            .unwrap();
        assert!(first.changed && !first.replayed);
        let replay = mux
            .move_workspace_to_group(None, Some(&a), Some("g".into()), None, None, None, &mutation)
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.revision, first.revision);
        // The same mutation id with a different payload is refused.
        assert!(
            mux.move_workspace_to_group(None, Some(&a), None, None, None, None, &mutation).is_err()
        );
        let decorations = mux.tree_decorations();
        let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
        assert_eq!(tree["groups"][0]["id"], "g");
        assert_eq!(tree["workspaces"][0]["group"], "g");
        assert!(tree["workspaces"][1]["group"].is_null());
    }
}
