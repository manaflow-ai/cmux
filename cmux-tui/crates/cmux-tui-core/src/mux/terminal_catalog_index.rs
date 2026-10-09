//! Host-id lookup of the terminal catalog (nx-scale W2). A create binds its
//! terminal by host id under the registry and state locks.

use super::*;

#[cfg(test)]
thread_local! {
    static CATALOG_SCANS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Catalog scans by host id on this thread (test hook).
#[cfg(test)]
pub(super) fn catalog_scans_for_test() -> u64 {
    CATALOG_SCANS.with(std::cell::Cell::get)
}

impl Mux {
    /// The catalog owner of host terminal `terminal_id`; two owners with that
    /// identity are `duplicate_terminal_id`.
    pub(super) fn catalog_terminal_by_host(
        &self,
        state: &State,
        terminal_id: &str,
    ) -> anyhow::Result<Option<Arc<Surface>>> {
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

#[cfg(test)]
mod tests;
