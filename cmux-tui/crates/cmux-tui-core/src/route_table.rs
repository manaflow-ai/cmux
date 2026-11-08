//! The session's surface routing tables (`State::surfaces`, `State::terminal_catalog`,
//! `State::terminal_catalog_by_runtime`), with a route generation per surface id that every write of that id's route
//! moves (TYPING UNDER LOAD F4).
//!
//! A frontend client keeps the terminal its keys go to, so the person's typing never takes the
//! session lock (`server::cmd_terminal_io::input_surface`). A kept terminal is used only while the
//! route generation of the id its keys name is the one it was kept at: a respawn, a close, a move, a projection or
//! any other change of which surface that id routes to makes the next key look its terminal up again, so a key never
//! goes to a terminal that no longer owns the id. Reads deref to the map; the only writes are [`RouteTable::insert`]
//! and [`RouteTable::remove`], so the compiler finds every write and none can skip the generation.
//!
//! Scoped, not global (TYPING FIX 2): a write moves only the generations of the ids whose route it changes
//! ([`RouteKey`]), so a tab created or closed in another workspace leaves every other client's kept terminal in place
//! (O(changed), not O(clients)). An id routes through `surfaces[id]`, else through
//! `terminal_catalog[terminal_catalog_by_runtime[id]]`, whose owner shares the runtime `id` names; so a `surfaces`
//! or `terminal_catalog_by_runtime` write moves its key's id, and a `terminal_catalog` write moves the runtime ids of
//! the owner it removes and the owner it puts in.
//!
//! The generations live in a fixed array of slots, an id in slot `id % ROUTE_SLOTS`: bounded memory with nothing to
//! remove when a surface goes, lock-free reads. Two ids in one slot only make a key look its terminal up once more
//! (never use a stale one); surface ids are sequential, so ids that share a slot are `ROUTE_SLOTS` creates apart.
//!
//! A whole-state replace (a rollback `*state = before`, a projected state swapped in) happens under the same state
//! guard as the insert or remove it undoes or installs, so a key either looked its terminal up before that guard (and
//! its kept generation is stale now) or after it (and keeps the route that is live). Clones and drops of the state
//! route nothing and leave the generations alone: every durable mutation clones the state, and moving them there would
//! send every key back to the session lock (the F4 delay).
//!
//! The generations are process-wide: a daemon runs one `Mux`, and the test runner (nextest) runs each test in its own
//! process, so no other mux moves them under a test.
//!
//! R-DAEMON-STATE stage S1 (`CMUX_TUI_RDS_INPUT`, handoff/rewrites/R-DAEMON-STATE/DESIGN.md section 2.6) replaces the
//! kept terminal and its generations with a published snapshot of the three tables ([`RouteSnapshot`]): each table
//! is copy-on-write behind an `Arc`, and the session state's guard publishes the tables it changed when it drops,
//! while it still holds the lock. A key reads the snapshot with one atomic load, so it finds the terminal its id
//! routes to now (a respawn, close, move, rollback or projection included) and never takes the session lock. There
//! is no cache to invalidate. The generations stay for the old path until the stage's switch is deleted.

use std::collections::HashMap;
use std::hash::Hash;
use std::ops::Deref;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::resource::TerminalPublicId;
use crate::{Surface, SurfaceId};

const ROUTE_SLOTS: usize = 1024;

static ROUTE_GENERATIONS: [AtomicU64; ROUTE_SLOTS] = [const { AtomicU64::new(0) }; ROUTE_SLOTS];

fn slot(id: SurfaceId) -> &'static AtomicU64 {
    let index = usize::try_from(id % ROUTE_SLOTS as u64).unwrap_or_default();
    // The remainder is below ROUTE_SLOTS, so `get` always finds a slot; a shared fallback slot keeps it panic-free.
    ROUTE_GENERATIONS.get(index).unwrap_or(&ROUTE_GENERATIONS_FALLBACK)
}

static ROUTE_GENERATIONS_FALLBACK: AtomicU64 = AtomicU64::new(0);

/// The route generation of `id`: it moves on every write that changes which surface `id` routes to.
pub fn route_generation(id: SurfaceId) -> u64 {
    slot(id).load(Ordering::Acquire)
}

fn route_changed(id: SurfaceId) {
    slot(id).fetch_add(1, Ordering::AcqRel);
}

/// The surface ids whose route a write of `(self, value)` changes.
pub trait RouteKey<V> {
    fn routed_id(&self, value: &V) -> Option<SurfaceId>;
}

/// `State::surfaces`: the placement id itself.
impl RouteKey<Arc<Surface>> for SurfaceId {
    fn routed_id(&self, _: &Arc<Surface>) -> Option<SurfaceId> {
        Some(*self)
    }
}

/// `State::terminal_catalog_by_runtime`: the runtime id itself.
impl RouteKey<TerminalPublicId> for SurfaceId {
    fn routed_id(&self, _: &TerminalPublicId) -> Option<SurfaceId> {
        Some(*self)
    }
}

/// `State::terminal_catalog_by_host`: the host id names a catalog owner, never a placement or runtime id itself.
impl RouteKey<TerminalPublicId> for String {
    fn routed_id(&self, _: &TerminalPublicId) -> Option<SurfaceId> {
        None
    }
}

/// `State::terminal_catalog`: the runtime id the owner is found under (`terminal_catalog_by_runtime`).
impl RouteKey<Arc<Surface>> for TerminalPublicId {
    fn routed_id(&self, value: &Arc<Surface>) -> Option<SurfaceId> {
        value.terminal_runtime_id()
    }
}

/// A routing map whose writes move the [`route_generation`] of the ids they route. The map is copy-on-write behind an
/// `Arc`, so the session state's guard can publish it with no copy ([`RouteSnapshot`]); the first write after a
/// publication copies the map once.
#[derive(Clone, Debug)]
pub struct RouteTable<K, V>(Arc<HashMap<K, V>>);

impl<K, V> Default for RouteTable<K, V> {
    fn default() -> Self {
        Self(Arc::new(HashMap::new()))
    }
}

impl<K: Eq + Hash + Clone + RouteKey<V>, V: Clone> RouteTable<K, V> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, key: K, value: V) -> Option<V> {
        // The owner it replaces (a catalog respawn may put in another runtime) and the one it puts in.
        let unrouted = self.0.get(&key).and_then(|old| key.routed_id(old));
        let routed = key.routed_id(&value);
        if let Some(id) = routed {
            route_changed(id);
        }
        if let Some(id) = unrouted.filter(|id| Some(*id) != routed) {
            route_changed(id);
        }
        Arc::make_mut(&mut self.0).insert(key, value)
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        if !self.0.contains_key(key) {
            return None;
        }
        let removed = Arc::make_mut(&mut self.0).remove(key)?;
        if let Some(id) = key.routed_id(&removed) {
            route_changed(id);
        }
        Some(removed)
    }

    /// Room for `additional` more entries; routes nothing. A mutation plan reserves before its durable commit, so
    /// the insert after the commit allocates nothing (`ResourceMutationPlan::apply`). A map a published snapshot
    /// shares is copied here, before the commit, never by that insert; the plan reserves and applies under one
    /// state guard, so no publication shares the map again in between.
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
#[derive(Default)]
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
    use super::{RouteKey, RouteTable, SurfaceId};
    use std::sync::Arc;

    /// A key that routes no surface (no route generation moves).
    impl RouteKey<u32> for u32 {
        fn routed_id(&self, _: &u32) -> Option<SurfaceId> {
            None
        }
    }

    /// A mutation plan reserves room before its durable commit and inserts after it, and the insert must allocate
    /// nothing (`ResourceMutationPlan::apply`). With stage S1 on, a published route snapshot shares the map: the
    /// reservation copies it then, before the commit, so the insert after the commit copies nothing.
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
