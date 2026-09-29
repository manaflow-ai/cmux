//! Shared presentation metadata for frontends: workspace groups and the
//! per-workspace group membership.
//!
//! The durable rows live in the workspace registry
//! (`workspace_registry/presentation_store.rs`). The mux keeps one immutable
//! snapshot of them, replaced after every commit while the registry lock is
//! held, so tree serialization never reads SQLite.

use super::*;
use crate::workspace_registry::{
    PresentationSnapshot, WorkspaceGroupRecord, WorkspacePresentationUpdate,
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
        Self { notifications, presentation: Arc::default() }
    }
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
    fn reload_presentation(&self, registry: &WorkspaceRegistry) -> anyhow::Result<()> {
        let snapshot = registry.presentation_snapshot()?;
        *self.presentation.lock().unwrap() = Arc::new(snapshot);
        Ok(())
    }

    /// Notifications and presentation for serializing the whole tree.
    pub fn tree_decorations(&self) -> TreeDecorations {
        let presentation = self.presentation_snapshot();
        let state = self.state.lock().unwrap();
        let notifications = self.surface_notifications_in_state(&state);
        TreeDecorations { notifications, presentation }
    }

    /// The same as [`Self::tree_decorations`] for a caller that already
    /// holds the state lock.
    pub(crate) fn tree_decorations_in_state(&self, state: &State) -> TreeDecorations {
        let presentation = self.presentation_snapshot();
        let notifications = self.surface_notifications_in_state(state);
        TreeDecorations { notifications, presentation }
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
