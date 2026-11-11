//! The walks that collect tree decorations from the live state: the unread marker and the
//! directory of each surface.
//!
//! Two forms: over every surface of the session (the whole tree), and over the surfaces of one
//! workspace (a close serializes only the workspace it closes, so its cost does not follow the
//! size of the session). The session forms count what they visit in test builds
//! (`crate::walk_counters`), so a test can say that a request ran none of them.

use super::*;

/// The directory of every placed surface of the session.
pub(super) fn surface_directories_in_state(state: &State) -> Vec<(SurfaceId, String)> {
    #[cfg(test)]
    crate::walk_counters::decoration_walk_visited(state.surfaces.len());
    state
        .surfaces
        .iter()
        .filter(|(surface, _)| state.pane_of(**surface).is_some())
        .filter_map(|(surface, runtime)| {
            runtime.presented_directory().map(|directory| (*surface, directory))
        })
        .collect()
}

impl Mux {
    /// The unread marker of every surface of the session.
    pub(in crate::mux) fn surface_notifications_in_state(
        &self,
        state: &State,
    ) -> HashMap<SurfaceId, SurfaceNotification> {
        let placement_notifications =
            self.placement_notifications.lock().unwrap_or_else(PoisonError::into_inner);
        let terminal_notifications =
            self.terminal_notifications.lock().unwrap_or_else(PoisonError::into_inner);
        #[cfg(test)]
        crate::walk_counters::decoration_walk_visited(
            state.surfaces.len() + state.resource_indexes.content_ids.len(),
        );
        let mut result = HashMap::new();
        for (surface_id, surface) in &state.surfaces {
            let notification = match surface.terminal_public_id() {
                Some(terminal_id) => terminal_notifications.get(terminal_id),
                None => placement_notifications.get(surface_id),
            };
            if let Some(notification) = notification {
                result.insert(*surface_id, *notification);
            }
        }
        // A terminal tab with no runtime surface yet (its host still adopts
        // after a restart, 81577dcd4b3) keeps its terminal's marker through
        // the tab's content binding, which exists before the adoption: the
        // ring and the workspace's unread count never blink out.
        for (surface_id, content) in &state.resource_indexes.content_ids {
            if state.surfaces.contains_key(surface_id) {
                continue;
            }
            if let ContentPublicId::Terminal(terminal_id) = content
                && let Some(notification) = terminal_notifications.get(terminal_id)
            {
                result.insert(*surface_id, *notification);
            }
        }
        result
    }

    /// [`Self::surface_notifications_in_state`] for `surfaces` only: the same marker each of them
    /// gets there, with no walk of the other surfaces.
    fn surface_notifications_of(
        &self,
        state: &State,
        surfaces: &[SurfaceId],
    ) -> HashMap<SurfaceId, SurfaceNotification> {
        let placement_notifications =
            self.placement_notifications.lock().unwrap_or_else(PoisonError::into_inner);
        let terminal_notifications =
            self.terminal_notifications.lock().unwrap_or_else(PoisonError::into_inner);
        let mut result = HashMap::new();
        for surface_id in surfaces {
            let notification = match state.surfaces.get(surface_id) {
                Some(surface) => match surface.terminal_public_id() {
                    Some(terminal_id) => terminal_notifications.get(terminal_id),
                    None => placement_notifications.get(surface_id),
                },
                // A terminal tab with no runtime surface yet keeps its terminal's marker.
                None => match state.resource_indexes.content_ids.get(surface_id) {
                    Some(ContentPublicId::Terminal(terminal_id)) => {
                        terminal_notifications.get(terminal_id)
                    }
                    _ => None,
                },
            };
            if let Some(notification) = notification {
                result.insert(*surface_id, *notification);
            }
        }
        result
    }

    /// [`Self::tree_decorations`] for a delta that serializes `workspace` only (its close): the
    /// notifications and directories of that workspace's surfaces, and git HEADs from the cache
    /// only. The full form walked every surface of the session and read each directory's git
    /// HEAD from disk for one closed workspace, so a close cost more in a bigger session.
    #[track_caller]
    pub(crate) fn tree_decorations_of_workspace(&self, workspace: WorkspaceId) -> TreeDecorations {
        let presentation = self.presentation_snapshot();
        let (notifications, directories) = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let surfaces = state
                .workspace_by_id(workspace)
                .into_iter()
                .flat_map(|workspace| &workspace.screens)
                .flat_map(|screen| screen_tabs(&state, screen))
                .collect::<Vec<_>>();
            let directories = surfaces
                .iter()
                .filter_map(|surface| {
                    let directory = state.surfaces.get(surface)?.presented_directory()?;
                    Some((*surface, directory))
                })
                .collect::<Vec<_>>();
            (self.surface_notifications_of(&state, &surfaces), directories)
        };
        let directories = self.resolve_tab_directories(directories, false);
        let pending_terminals = self.pending_terminals_snapshot();
        let terminal_ends = self.terminal_ends_snapshot();
        TreeDecorations {
            notifications,
            presentation,
            directories,
            pending_terminals,
            terminal_ends,
            terminal_loss_causes: self.terminal_loss_causes_snapshot(),
        }
    }
}
