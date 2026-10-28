//! Layout undo: undo with confirmation tokens, including the resource-effect path.

use super::*;
use crate::panic_free::{JsonFields, RecoverPoison};

impl Mux {
    /// Forget the layout-undo history of `pane`'s screen: its layout was
    /// rebuilt for the user (a reopened screen), not changed by them, so
    /// undo must not fold those splits back.
    pub(crate) fn forget_layout_undo(&self, pane: PaneId) {
        let mut state = self.state.lock().recover_poison();
        if let Some((workspace, screen)) = state.screen_of(pane)
            && let Some(screen) = state
                .workspaces
                .get_mut(workspace)
                .and_then(|workspace| workspace.screens.get_mut(screen))
        {
            screen.invalidate_layout_undo();
        }
    }

    /// Undo the latest structural layout transaction on `pane`'s screen.
    ///
    /// Transactions that created panes return a confirmation preview first.
    /// The preview is read only. The caller must retry with its exact current
    /// layout revision and `confirm_close=true`; structural or created-pane tab
    /// membership changes advance that revision before the retry can commit.
    #[track_caller]
    pub fn undo_layout_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        expected_revision: Option<u64>,
        confirm_close: bool,
    ) -> anyhow::Result<LayoutUndoResult> {
        let (screen_id, current_revision, created_panes) = {
            let state = self.state.lock().recover_poison();
            let Some(screen) = state.screen_of(pane).and_then(|(workspace_index, screen_index)| {
                state.workspaces.get(workspace_index)?.screens.get(screen_index)
            }) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo target is no longer available".to_string(),
                )
                .into());
            };
            let Some(entry) = screen.layout_undo.back() else {
                return Err(LayoutUndoError::Unavailable.into());
            };
            if entry.after_revision != screen.layout_revision {
                return Err(LayoutUndoError::Stale(
                    "layout changed since the last undoable action".to_string(),
                )
                .into());
            }
            if let Some(expected) = expected_revision
                && expected != entry.after_revision
            {
                return Err(LayoutUndoError::Stale(format!(
                    "layout revision conflict: expected {expected}, current {}",
                    entry.after_revision
                ))
                .into());
            }
            for created in &entry.created_panes {
                if !state.panes.contains_key(created) {
                    return Err(LayoutUndoError::Stale(format!(
                        "created pane {created} disappeared before undo preview"
                    ))
                    .into());
                }
            }
            (screen.id, entry.after_revision, entry.created_panes.clone())
        };
        if !created_panes.is_empty() && !confirm_close {
            return Ok(LayoutUndoResult::ConfirmationRequired {
                screen: screen_id,
                revision: current_revision,
                closes_panes: created_panes,
            });
        }
        if !created_panes.is_empty() && expected_revision.is_none() {
            return Err(LayoutUndoError::Stale(
                "confirmed layout undo requires the preview revision".to_string(),
            )
            .into());
        }

        let selectors = self.ordinary_screen_selectors(screen_id).ok_or_else(|| {
            LayoutUndoError::Stale("layout undo target is no longer available".to_string())
        })?;
        let mut fields = Map::from_iter([("confirm_close".into(), Value::Bool(confirm_close))]);
        fields.insert("expected_layout_revision".into(), Value::from(current_revision));
        // The confirmation token fences exactly what closes; it is computed
        // once. The resource revision is only the commit's precondition, so a
        // conflict from an unrelated commit between reading it and committing
        // is retried (bounded) with the same token: the commit re-checks the
        // token against the state it commits on.
        if !created_panes.is_empty() {
            let registry = self.workspace_registry.lock().recover_poison();
            let state = self.lock_state_pinned(&registry).recover_poison();
            let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo target disappeared before confirmation".to_string(),
                )
                .into());
            };
            let details =
                layout_undo_confirmation_details(&state, &registry, workspace_index, screen_index)?;
            let token = details
                .field("confirmation_token")
                .as_str()
                .context("layout undo confirmation omitted its token")?;
            fields.insert("confirmation_token".into(), Value::String(token.to_string()));
        }
        let commit =
            self.commit_confirmed_layout_undo(actor, selectors, fields, !created_panes.is_empty())?;
        let screen = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
            .unwrap_or(screen_id);
        let revision = self
            .with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| workspace.screens.iter())
                    .find(|candidate| candidate.id == screen)
                    .map(|screen| screen.layout_revision)
            })
            .ok_or_else(|| {
                LayoutUndoError::Stale(
                    "layout undo screen disappeared after the change committed".to_string(),
                )
            })?;
        Ok(LayoutUndoResult::Undone { screen, revision })
    }

    #[track_caller]
    pub(super) fn undo_layout_with_confirmation_token_for_resource_effect(
        &self,
        pane: PaneId,
        expected_revision: Option<u64>,
        confirm_close: bool,
        confirmation_token: Option<&str>,
    ) -> anyhow::Result<LayoutUndoResult> {
        let (workspace, screen_id, preview) = {
            let state = self.state.lock().recover_poison();
            let Some((workspace, screen)) =
                state.screen_of(pane).and_then(|(workspace_index, screen_index)| {
                    let workspace = state.workspaces.get(workspace_index)?;
                    Some((workspace.id, workspace.screens.get(screen_index)?))
                })
            else {
                return Err(LayoutUndoError::Stale(
                    "layout undo target is no longer available".to_string(),
                )
                .into());
            };
            let screen_id = screen.id;
            let entry = {
                let Some(entry) = screen.layout_undo.back().cloned() else {
                    return Err(LayoutUndoError::Unavailable.into());
                };
                if entry.after_revision != screen.layout_revision {
                    return Err(LayoutUndoError::Stale(
                        "layout changed since the last undoable action".to_string(),
                    )
                    .into());
                }
                entry
            };
            if let Some(expected) = expected_revision
                && expected != entry.after_revision
            {
                return Err(LayoutUndoError::Stale(format!(
                    "layout revision conflict: expected {expected}, current {}",
                    entry.after_revision
                ))
                .into());
            }
            if !entry.created_panes.is_empty() && !confirm_close {
                for created in &entry.created_panes {
                    if !state.panes.contains_key(created) {
                        return Err(LayoutUndoError::Stale(format!(
                            "created pane {created} disappeared before undo preview"
                        ))
                        .into());
                    }
                }
                return Ok(LayoutUndoResult::ConfirmationRequired {
                    screen: screen_id,
                    revision: entry.after_revision,
                    closes_panes: entry.created_panes,
                });
            }
            (workspace, screen_id, entry)
        };
        if !preview.created_panes.is_empty() && expected_revision.is_none() {
            return Err(LayoutUndoError::Stale(
                "confirmed layout undo requires the preview revision".to_string(),
            )
            .into());
        }
        if preview.created_panes.is_empty() {
            let revision = {
                let mut state = self.state.lock().recover_poison();
                let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                    return Err(LayoutUndoError::Stale(
                        "layout undo target disappeared before the change could commit".to_string(),
                    )
                    .into());
                };
                let missing = || {
                    LayoutUndoError::Stale(
                        "layout undo target disappeared before the change could commit".to_string(),
                    )
                };
                let entry = {
                    let screen = state
                        .workspaces
                        .get_mut(workspace_index)
                        .and_then(|workspace| workspace.screens.get_mut(screen_index))
                        .ok_or_else(missing)?;
                    let Some(entry) = screen.layout_undo.pop_back() else {
                        return Err(
                            LayoutUndoError::Stale("layout undo disappeared".to_string()).into()
                        );
                    };
                    if entry.after_revision != screen.layout_revision
                        || expected_revision
                            .is_some_and(|expected| expected != entry.after_revision)
                    {
                        screen.layout_undo.push_back(entry);
                        return Err(LayoutUndoError::Stale(
                            "layout changed before undo could commit".to_string(),
                        )
                        .into());
                    }
                    entry
                };
                if let Some(restore) = entry.tab_restore
                    && let Err(error) = restore_dragged_tab(
                        self,
                        &mut state,
                        workspace_index,
                        screen_index,
                        restore,
                    )
                {
                    if let Some(screen) = state
                        .workspaces
                        .get_mut(workspace_index)
                        .and_then(|workspace| workspace.screens.get_mut(screen_index))
                    {
                        screen.layout_undo.push_back(entry);
                    }
                    return Err(error);
                }
                let screen = state
                    .workspaces
                    .get_mut(workspace_index)
                    .and_then(|workspace| workspace.screens.get_mut(screen_index))
                    .ok_or_else(missing)?;
                let revision = screen.layout_revision.saturating_add(1);
                screen.restore_layout_snapshot(entry.before);
                screen.layout_revision = revision;
                if let Some(previous) = screen.layout_undo.back_mut() {
                    previous.after_revision = revision;
                    previous.coalesce = None;
                }
                Self::rebuild_split_screen_index(&mut state);
                revision
            };
            self.emit(MuxEvent::TreeChanged);
            self.emit_layout_changed(screen_id, None);
            return Ok(LayoutUndoResult::Undone { screen: screen_id, revision });
        }

        let lifecycle = self.workspace_lifecycle(workspace);
        let _workspace_lifecycle = lifecycle.lock().recover_poison();
        let notifications = self.tree_decorations();
        let registry = self.workspace_registry.lock().recover_poison();
        let (removed, deltas, selection_resync, revision) = {
            let mut state = self.lock_state_pinned(&registry).recover_poison();
            let Some(workspace_index) = state.workspace_index(workspace) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo workspace is no longer available".to_string(),
                )
                .into());
            };
            let Some((screen_index, screen)) =
                state.workspaces.get(workspace_index).and_then(|workspace| {
                    workspace.screens.iter().enumerate().find(|(_, screen)| screen.id == screen_id)
                })
            else {
                return Err(LayoutUndoError::Stale(
                    "layout undo screen is no longer available".to_string(),
                )
                .into());
            };
            let entry = {
                let Some(entry) = screen.layout_undo.back().cloned() else {
                    return Err(
                        LayoutUndoError::Stale("layout undo disappeared".to_string()).into()
                    );
                };
                if entry.after_revision != screen.layout_revision
                    || expected_revision != Some(entry.after_revision)
                {
                    return Err(LayoutUndoError::Stale(
                        "layout changed before confirmed undo could commit".to_string(),
                    )
                    .into());
                }
                entry
            };
            let mut remaining_history = screen.layout_undo.clone();
            remaining_history.pop_back();

            let mut before_panes = Vec::new();
            entry.before.root.pane_ids(&mut before_panes);
            let before_panes = before_panes.into_iter().collect::<HashSet<_>>();
            let mut current_panes = Vec::new();
            screen.root.pane_ids(&mut current_panes);
            let expected_panes = before_panes
                .iter()
                .copied()
                .chain(entry.created_panes.iter().copied())
                .collect::<HashSet<_>>();
            if current_panes.into_iter().collect::<HashSet<_>>() != expected_panes {
                return Err(LayoutUndoError::Stale(
                    "screen panes changed since the action being undone".to_string(),
                )
                .into());
            }
            if let Some(expected_token) = confirmation_token {
                let details = layout_undo_confirmation_details(
                    &state,
                    &registry,
                    workspace_index,
                    screen_index,
                )?;
                if details.field("confirmation_token").as_str() != Some(expected_token) {
                    return Err(anyhow::Error::new(ResourceError::new(
                        "confirmation.required",
                        "layout undo confirmation is stale",
                        details,
                        false,
                    )));
                }
            }

            let selection_before = active_tree_selection(&state);
            let mut tabs = Vec::new();
            let mut deltas = Vec::new();
            for created in &entry.created_panes {
                let Some(pane) = state.panes.get(created) else {
                    return Err(LayoutUndoError::Stale(format!(
                        "created pane {created} disappeared before undo"
                    ))
                    .into());
                };
                tabs.extend(pane.tabs.iter().copied());
                if let Some(delta) = close_pane_delta(&state, &notifications, *created) {
                    deltas.push(delta);
                }
            }
            let mut removed = Vec::new();
            for surface in tabs {
                if let (Some(surface), _) = remove_surface(self, &mut state, surface) {
                    removed.push(surface);
                }
            }
            let Some(screen) = state.workspaces.get_mut(workspace_index).and_then(|workspace| {
                workspace.screens.iter_mut().find(|screen| screen.id == screen_id)
            }) else {
                return Err(LayoutUndoError::Stale(
                    "layout changed while undo was closing panes".to_string(),
                )
                .into());
            };
            let revision = screen.layout_revision.max(entry.after_revision).saturating_add(1);
            screen.restore_layout_snapshot(entry.before);
            screen.layout_revision = revision;
            screen.layout_undo = remaining_history;
            if let Some(previous) = screen.layout_undo.back_mut() {
                previous.after_revision = revision;
                previous.coalesce = None;
            }
            Self::rebuild_split_screen_index(&mut state);
            let selection_resync = selection_before != active_tree_selection(&state);
            (removed, deltas, selection_resync, revision)
        };
        drop(registry);

        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        if deltas.is_empty() {
            self.emit(MuxEvent::TreeChanged);
        } else {
            for delta in deltas {
                self.emit_tree_delta(delta, selection_resync);
            }
        }
        self.emit_layout_changed(screen_id, None);
        Ok(LayoutUndoResult::Undone { screen: screen_id, revision })
    }
}
