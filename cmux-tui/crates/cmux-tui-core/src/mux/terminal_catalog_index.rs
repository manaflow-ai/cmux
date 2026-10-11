//! Host-id index of the terminal catalog (nx-scale W2). A create binds its
//! terminal by host id under the registry and state locks; a scan of every
//! catalog entry made each create O(terminals). The index is a verified
//! cache: a hit is checked against the catalog entry, and a miss (an
//! in-process terminal whose identity Mux holds, or an unknown id) scans.

use super::*;

#[cfg(test)]
thread_local! {
    static CATALOG_SCANS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Catalog scans by host id on this thread (test hook).
#[cfg(all(test, unix))]
pub(super) fn catalog_scans_for_test() -> u64 {
    CATALOG_SCANS.with(std::cell::Cell::get)
}

impl State {
    /// The catalog owner of daemon-local runtime `id`.
    pub(crate) fn terminal_runtime_by_id(&self, id: SurfaceId) -> Option<&Arc<Surface>> {
        self.terminal_catalog_by_runtime
            .get(&id)
            .and_then(|terminal| self.terminal_catalog.get(terminal))
    }

    /// The catalog owner indexed under host id `terminal_id`, if the index
    /// names one that still carries that host identity.
    fn indexed_catalog_terminal(&self, terminal_id: &str) -> Option<&Arc<Surface>> {
        let public_id = self.terminal_catalog_by_host.get(terminal_id)?;
        self.terminal_catalog.get(public_id).filter(|surface| {
            surface
                .terminal_host_identity()
                .is_some_and(|identity| identity.terminal_id == terminal_id)
        })
    }

    /// Insert a catalog owner and index its host id. A different runtime
    /// already indexed under the same host id is `duplicate_terminal_id`.
    pub(super) fn insert_catalog_terminal(
        &mut self,
        terminal_id: &TerminalPublicId,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<()> {
        if let Some(identity) = surface.terminal_host_identity() {
            if let Some(existing) = self.indexed_catalog_terminal(&identity.terminal_id) {
                anyhow::ensure!(existing.shares_terminal_runtime(surface), "duplicate_terminal_id");
            }
            self.terminal_catalog_by_host.insert(identity.terminal_id, terminal_id.clone());
        }
        self.terminal_catalog.insert(terminal_id.clone(), surface.clone());
        Ok(())
    }

    /// Remove a catalog owner with its runtime and host index entries.
    pub(super) fn remove_catalog_terminal(
        &mut self,
        terminal_id: &TerminalPublicId,
    ) -> Option<Arc<Surface>> {
        let removed = self.terminal_catalog.remove(terminal_id)?;
        if let Some(runtime_id) = removed.terminal_runtime_id() {
            self.terminal_catalog_by_runtime.remove(&runtime_id);
        }
        if let Some(identity) = removed.terminal_host_identity()
            && self.terminal_catalog_by_host.get(&identity.terminal_id) == Some(terminal_id)
        {
            self.terminal_catalog_by_host.remove(&identity.terminal_id);
        }
        Some(removed)
    }
}

impl Mux {
    /// The catalog owner of host terminal `terminal_id`; two owners with that
    /// identity are `duplicate_terminal_id`.
    pub(super) fn catalog_terminal_by_host(
        &self,
        state: &State,
        terminal_id: &str,
    ) -> anyhow::Result<Option<Arc<Surface>>> {
        if let Some(surface) = state.indexed_catalog_terminal(terminal_id) {
            return Ok(Some(surface.clone()));
        }
        #[cfg(test)]
        CATALOG_SCANS.with(|scans| scans.set(scans.get() + 1));
        unique_terminal_match(
            terminal_id,
            state.terminal_catalog.values().filter_map(|surface| {
                self.resource_terminal_host_identity(surface)
                    .map(|identity| (surface.clone(), identity))
            }),
        )
        .map(|matched| matched.map(|(surface, _)| surface))
    }
}

// The tests build hosted placeholders, which exist on Unix only.
#[cfg(all(test, unix))]
mod tests;
