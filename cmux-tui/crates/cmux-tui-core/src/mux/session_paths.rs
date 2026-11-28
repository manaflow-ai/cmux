//! The session's durable state directory and its launch snapshot projections
//! (moved out of mux.rs, behavior unchanged).

use super::*;

impl Mux {
    /// The directory of this session's durable registry, or none for an
    /// in-memory session.
    pub(crate) fn session_state_directory(&self) -> Option<std::path::PathBuf> {
        let database = self.workspace_registry.lock().unwrap().session_journal_database_path()?;
        database.parent().map(Path::to_path_buf)
    }

    pub(crate) fn launch_snapshot_frontend_projections(
        &self,
    ) -> anyhow::Result<Vec<FrontendProjection>> {
        self.workspace_registry.lock().unwrap().native_frontend_projections()
    }
}
