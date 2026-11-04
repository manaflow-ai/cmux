//! The session's surface routing tables (`State::surfaces`, `State::terminal_catalog`,
//! `State::terminal_catalog_by_runtime`, `State::terminal_catalog_by_host`) and their published snapshot
//! (R-DAEMON-STATE stage S1, handoff/rewrites/R-DAEMON-STATE/DESIGN.md section 2.6).
//!
//! Each table is copy-on-write behind an `Arc`, and the session state's guard publishes the tables it changed when it
//! drops, while it still holds the lock ([`RouteSnapshot`]). A key reads the snapshot with one atomic load, so it finds
//! the terminal its id routes to now (a respawn, close, move, rollback or projection included) and never takes the
//! session lock (TYPING UNDER LOAD F4). There is no cache to invalidate.

use std::collections::HashMap;
use std::hash::Hash;
use std::ops::Deref;
use std::sync::Arc;

use crate::resource::TerminalPublicId;
use crate::{Surface, SurfaceId};

/// A routing map, copy-on-write behind an `Arc`, so the session state's guard can publish it with no copy
/// ([`RouteSnapshot`]); the first write after a publication copies the map once.
#[derive(Clone, Debug)]
pub struct RouteTable<K, V>(Arc<HashMap<K, V>>);

impl<K, V> Default for RouteTable<K, V> {
    fn default() -> Self {
        Self(Arc::new(HashMap::new()))
    }
}

impl<K: Eq + Hash + Clone, V: Clone> RouteTable<K, V> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, key: K, value: V) -> Option<V> {
        Arc::make_mut(&mut self.0).insert(key, value)
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        // A key that is not there changes nothing, so a map a snapshot shares is not copied for it.
        if !self.0.contains_key(key) {
            return None;
        }
        Arc::make_mut(&mut self.0).remove(key)
    }

    /// Room for `additional` more entries. A mutation plan reserves before its durable commit, so the insert after the
    /// commit allocates nothing (`ResourceMutationPlan::apply`). A map a published snapshot shares is copied here,
    /// before the commit, never by that insert; the plan reserves and applies under one state guard, so no publication
    /// shares the map again in between.
    pub fn try_reserve(
        &mut self,
        additional: usize,
    ) -> Result<(), std::collections::TryReserveError> {
        Arc::make_mut(&mut self.0).try_reserve(additional)
    }
}

impl<K, V> RouteTable<K, V> {
    /// The map as it is now, shared with no copy (a [`RouteSnapshot`]).
    pub(crate) fn shared(&self) -> Arc<HashMap<K, V>> {
        Arc::clone(&self.0)
    }

    fn shares(&self, map: &Arc<HashMap<K, V>>) -> bool {
        Arc::ptr_eq(&self.0, map)
    }
}

/// The session's routing tables as of the last finished change of the session state: what `Mux::surface` reads, with
/// no lock. The session state's guard publishes it when it drops after a change (`signaled_mutex::StateGuard`), so
/// a reader sees each change once its guard is released, as a reader that waited for the lock would.
pub(crate) struct RouteSnapshot {
    surfaces: Arc<HashMap<SurfaceId, Arc<Surface>>>,
    catalog: Arc<HashMap<TerminalPublicId, Arc<Surface>>>,
    by_runtime: Arc<HashMap<SurfaceId, TerminalPublicId>>,
    by_host: Arc<HashMap<String, TerminalPublicId>>,
}

impl RouteSnapshot {
    /// The tables of `state`, shared with no copy.
    pub(crate) fn of(state: &crate::State) -> Self {
        Self {
            surfaces: state.surfaces.shared(),
            catalog: state.terminal_catalog.shared(),
            by_runtime: state.terminal_catalog_by_runtime.shared(),
            by_host: state.terminal_catalog_by_host.shared(),
        }
    }

    /// Whether `state` still has the tables of this snapshot (no route changed since it was taken).
    pub(crate) fn is_current(&self, state: &crate::State) -> bool {
        state.surfaces.shares(&self.surfaces)
            && state.terminal_catalog.shares(&self.catalog)
            && state.terminal_catalog_by_runtime.shares(&self.by_runtime)
            && state.terminal_catalog_by_host.shares(&self.by_host)
    }

    /// The surface `id` routes to: its placement, else the catalog owner of the runtime `id` names (the lookup of
    /// `Mux::surface`).
    pub(crate) fn surface(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.surfaces
            .get(&id)
            .or_else(|| self.by_runtime.get(&id).and_then(|terminal| self.catalog.get(terminal)))
            .cloned()
    }

    /// The live terminal whose host id is `terminal_id` (the lookup of `Mux::live_surface_for_terminal`).
    pub(crate) fn live_terminal(&self, terminal_id: &str) -> Option<Arc<Surface>> {
        live_terminal(&self.surfaces, &self.catalog, &self.by_host, terminal_id).cloned()
    }
}

/// The catalog owner the host index names for host id `terminal_id`, if it still carries that identity: the index
/// is a verified cache (mux/terminal_catalog_index.rs).
pub(crate) fn indexed_owner<'a>(
    catalog: &'a HashMap<TerminalPublicId, Arc<Surface>>,
    by_host: &HashMap<String, TerminalPublicId>,
    terminal_id: &str,
) -> Option<&'a Arc<Surface>> {
    let public_id = by_host.get(terminal_id)?;
    catalog.get(public_id).filter(|surface| {
        surface.terminal_host_identity().is_some_and(|identity| identity.terminal_id == terminal_id)
    })
}

/// The live terminal whose host id is `terminal_id`: the indexed catalog owner while it is placed, else the placement
/// whose terminal has that identity. The session state and a published snapshot answer with these same tables.
pub(crate) fn live_terminal<'a>(
    surfaces: &'a HashMap<SurfaceId, Arc<Surface>>,
    catalog: &'a HashMap<TerminalPublicId, Arc<Surface>>,
    by_host: &HashMap<String, TerminalPublicId>,
    terminal_id: &str,
) -> Option<&'a Arc<Surface>> {
    if let Some(owner) = indexed_owner(catalog, by_host, terminal_id)
        && surfaces.contains_key(&owner.id)
    {
        return Some(owner);
    }
    surfaces.values().find(|surface| {
        surface.terminal_host_identity().is_some_and(|identity| identity.terminal_id == terminal_id)
    })
}

impl<K, V> Deref for RouteTable<K, V> {
    type Target = HashMap<K, V>;

    fn deref(&self) -> &HashMap<K, V> {
        &self.0
    }
}

impl<'a, K, V> IntoIterator for &'a RouteTable<K, V> {
    type Item = (&'a K, &'a V);
    type IntoIter = std::collections::hash_map::Iter<'a, K, V>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::RouteTable;
    use std::sync::Arc;

    /// A mutation plan reserves room before its durable commit and inserts after it, and the insert must allocate
    /// nothing (`ResourceMutationPlan::apply`). A published route snapshot shares the map: the reservation copies it
    /// then, before the commit, so the insert after the commit copies nothing.
    #[test]
    fn a_reservation_unshares_a_published_map_so_the_insert_after_the_commit_allocates_nothing() {
        let mut table = RouteTable::<u32, u32>::new();
        table.try_reserve(8).unwrap();
        let published = table.shared();
        table.try_reserve(1).unwrap();
        let reserved = Arc::as_ptr(&table.0);
        table.insert(1, 1);
        assert_eq!(Arc::as_ptr(&table.0), reserved, "the insert after the commit copied the map");
        assert!(published.is_empty(), "the published snapshot changed");
    }
}
