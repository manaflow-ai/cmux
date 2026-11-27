//! Tab events (titles, OSC 7501 program status) patched into the cached tree,
//! and reapplied over a refresh whose response predates them.

use super::*;
use cmux_tui_core::ShownProgramStatus;

pub(super) struct ProgramStatusUpdate {
    generation: u64,
    status: Option<ShownProgramStatus>,
}

impl RemoteTreeCache {
    /// A response snapshot can predate tab events received while its
    /// request was in flight. Reapply only those later authoritative events;
    /// older events are already represented by the response. Events for a
    /// surface the response lacks wait for a later topology.
    pub(super) fn reapply_tab_updates(&mut self, refresh_generation: u64) {
        let titles = std::mem::take(&mut self.title_updates);
        for (surface_id, update) in titles {
            if update.generation <= refresh_generation {
                continue;
            }
            if self.surface_tabs.contains_key(&surface_id) {
                self.update_view_title(surface_id, update.title);
            } else {
                self.title_updates.insert(surface_id, update);
            }
        }
        let statuses = std::mem::take(&mut self.program_status_updates);
        for (surface_id, update) in statuses {
            if update.generation <= refresh_generation {
                continue;
            }
            if self.update_view_program_status(surface_id, update.status).is_none() {
                self.program_status_updates.insert(surface_id, update);
            }
        }
    }

    /// Patches a `program-status-changed` event into the tree; false when
    /// the tree does not know the surface yet.
    pub(super) fn update_program_status(
        &mut self,
        surface_id: SurfaceId,
        status: Option<ShownProgramStatus>,
    ) -> bool {
        // Titles and statuses share one counter: the refresh boundary reads it.
        self.title_generation = self.title_generation.saturating_add(1);
        let update = ProgramStatusUpdate { generation: self.title_generation, status };
        self.program_status_updates.insert(surface_id, update);
        self.update_view_program_status(surface_id, status).is_some()
    }

    fn update_view_program_status(
        &mut self,
        surface_id: SurfaceId,
        status: Option<ShownProgramStatus>,
    ) -> Option<()> {
        let location = self.surface_tabs.get(&surface_id).copied()?;
        self.view.update_program_status_at(surface_id, location, status)
    }
}
