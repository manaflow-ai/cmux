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

/// `State::terminal_catalog`: the runtime id the owner is found under (`terminal_catalog_by_runtime`).
impl RouteKey<Arc<Surface>> for TerminalPublicId {
    fn routed_id(&self, value: &Arc<Surface>) -> Option<SurfaceId> {
        value.terminal_runtime_id()
    }
}

/// A routing map whose writes move the [`route_generation`] of the ids they route.
#[derive(Clone, Debug)]
pub struct RouteTable<K, V>(HashMap<K, V>);

impl<K, V> Default for RouteTable<K, V> {
    fn default() -> Self {
        Self(HashMap::new())
    }
}

impl<K: Eq + Hash + RouteKey<V>, V> RouteTable<K, V> {
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
        self.0.insert(key, value)
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        let removed = self.0.remove(key)?;
        if let Some(id) = key.routed_id(&removed) {
            route_changed(id);
        }
        Some(removed)
    }

    /// Room for `additional` more entries (a mutation plan reserves before it commits); routes nothing.
    pub fn try_reserve(
        &mut self,
        additional: usize,
    ) -> Result<(), std::collections::TryReserveError> {
        self.0.try_reserve(additional)
    }
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
