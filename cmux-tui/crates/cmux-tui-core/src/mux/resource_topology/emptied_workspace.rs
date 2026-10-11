//! LAST-TAB-CLOSES-WORKSPACE (cmux-next-spec decisions.md, 2026-10-06): a
//! close that leaves a workspace without a tab closes that workspace in the
//! same plan, so it commits with the tab in one transaction and every client
//! (Mac, iOS, GPUI, CLI, plain cmux-tui) sees one change. The owner decides
//! it (OWNERSHIP-PRINCIPLES: destructive policy at the owner, in the same
//! commit); no client infers a close from its mirror.
//!
//! It applies to every explicit close (tab, pane, screen, terminal,
//! `close-tabs`, tab group) and to a process end that detaches the last
//! view. It never applies to a host loss (invariant 3: nothing detaches),
//! the store's home workspace (`home_not_closable`; HomeService owns its
//! content), a provider-managed session (the provider owns workspace
//! lifecycle, so a tab close never stops or deletes a Cloud VM), or a
//! workspace that had no tab before the close (an empty workspace made for
//! the New Tab flow stays).
//!
//! The explicit `close-workspace` plan uses the same removal
//! ([`Mux::remove_workspace_for_close`]), so the selection after a cascade
//! follows the close-workspace rule.

use super::*;

/// The workspace close a tab close cascades into.
pub(super) struct EmptiedWorkspaceClose {
    pub(super) close: ResourceWorkspaceClose,
    /// `workspace-closed` for one workspace. None when several closed or the
    /// caller has no tree decorations: clients then take a snapshot.
    pub(super) delta: Option<TreeDelta>,
    /// Every screen the closed workspaces had.
    pub(super) changed_screens: Vec<ScreenId>,
    /// Whether one of them was the active workspace.
    pub(super) was_active: bool,
}

impl Mux {
    /// Remove `workspace` from `projected` as an explicit close does:
    /// refused for the home workspace; the active workspace keeps its id or
    /// falls back to the last one. Returns whether it was active.
    pub(super) fn remove_workspace_for_close(
        &self,
        registry: &WorkspaceRegistry,
        projected: &mut State,
        workspace: WorkspaceId,
        workspace_key: &str,
    ) -> anyhow::Result<bool> {
        // `home_not_closable`: refused before any terminal ends.
        registry.read_state(|connection| {
            crate::state::home_store::refuse_close_key(connection, workspace_key)
        })?;
        let index = projected
            .workspace_index(workspace)
            .context("workspace disappeared while planning close")?;
        let was_active = projected.active_workspace == index;
        let previous_active = projected.active_pane();
        let active_id =
            projected.workspaces.get(projected.active_workspace).map(|workspace| workspace.id);
        projected.remove_workspace(index);
        projected.active_workspace = active_id
            .and_then(|id| projected.workspace_index(id))
            .unwrap_or_else(|| projected.workspaces.len().saturating_sub(1));
        stamp_changed_active_pane(self, projected, previous_active);
        Ok(was_active)
    }

    /// The registry side of closing `workspace` (index `index` before the
    /// close), with `projected` already without it.
    pub(super) fn workspace_close_record(
        &self,
        projected: &State,
        workspace: WorkspaceId,
        workspace_key: &str,
        index: usize,
    ) -> ResourceWorkspaceClose {
        ResourceWorkspaceClose {
            workspace_key: workspace_key.to_string(),
            remaining_workspaces: self.registry_projection(projected),
            active_workspace: projected
                .workspaces
                .get(projected.active_workspace)
                .map(|workspace| workspace.public_id.clone()),
            legacy_result: json!({
                "workspace":workspace,
                "key":workspace_key,
                "index":index,
                "changed":true,
            }),
        }
    }

    /// Close in `projected` every workspace that had a tab in `before` and
    /// has none in `projected`. None when no closable workspace emptied.
    pub(super) fn close_emptied_workspaces_locked(
        &self,
        registry: &WorkspaceRegistry,
        before: &State,
        projected: &mut State,
        notifications: Option<&TreeDecorations>,
    ) -> anyhow::Result<Option<EmptiedWorkspaceClose>> {
        if self.provider_managed.load(Ordering::Acquire) {
            return Ok(None);
        }
        let emptied = before
            .workspaces
            .iter()
            .enumerate()
            .filter(|(_, workspace)| !workspace.screens.is_empty())
            .filter(|(_, workspace)| {
                projected
                    .workspace_index(workspace.id)
                    .is_some_and(|index| projected.workspaces[index].screens.is_empty())
            })
            .collect::<Vec<_>>();
        let mut closed = Vec::new();
        let mut was_active = false;
        for (index, workspace) in emptied {
            let home = registry
                .read_state(|connection| {
                    crate::state::home_store::refuse_close_key(connection, &workspace.key)
                })
                .is_err();
            if home {
                continue;
            }
            was_active |=
                self.remove_workspace_for_close(registry, projected, workspace.id, &workspace.key)?;
            closed.push((index, workspace));
        }
        let Some(&(index, first)) = closed.first() else { return Ok(None) };
        let delta = match (closed.len(), notifications) {
            (1, Some(notifications)) => close_workspace_delta(before, notifications, first.id),
            _ => None,
        };
        let changed_screens = closed
            .iter()
            .flat_map(|(_, workspace)| workspace.screens.iter().map(|screen| screen.id))
            .collect();
        Self::rebuild_split_screen_index(projected);
        Ok(Some(EmptiedWorkspaceClose {
            close: self.workspace_close_record(projected, first.id, &first.key, index),
            delta,
            changed_screens,
            was_active,
        }))
    }

    pub(super) fn close_emptied_workspaces_for_resource_close_locked(
        &self,
        registry: &WorkspaceRegistry,
        before: &State,
        projected: &mut State,
        notifications: &TreeDecorations,
        close_emptied_workspaces: bool,
    ) -> anyhow::Result<Option<EmptiedWorkspaceClose>> {
        if !close_emptied_workspaces {
            return Ok(None);
        }
        self.close_emptied_workspaces_locked(registry, before, projected, Some(notifications))
    }

    /// Publish a workspace close delta that carries its workspace revision
    /// before the registry guard is released, so it orders with the
    /// registry's own events; other deltas publish after the commit.
    pub(super) fn publish_revisioned_workspace_delta(
        &self,
        registry: &WorkspaceRegistry,
        effects: &mut ResourceCloseEffects,
    ) {
        if !matches!(
            &effects.tree_publication,
            ResourceCloseTreePublication::PendingDelta(delta)
                if delta.workspace_revision.is_some()
        ) {
            return;
        }
        let ResourceCloseTreePublication::PendingDelta(delta) = std::mem::replace(
            &mut effects.tree_publication,
            ResourceCloseTreePublication::Published,
        ) else {
            return;
        };
        self.emit_committed_workspace_delta(registry, delta, effects.selection_resync);
    }
}
