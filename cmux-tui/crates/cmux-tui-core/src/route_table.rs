//! The session's surface routing tables (`State::surfaces`, `State::terminal_catalog`), with a
//! process-wide route generation that every write moves (TYPING UNDER LOAD F4).
//!
//! A frontend client keeps the terminal its keys go to, so the person's typing never takes the
//! session lock (`server::cmd_terminal_io::input_surface`). A kept terminal is used only while the
//! route generation it was kept at is current: a respawn, a close, a move, a projection, a rollback
//! or any other change of which surface an id routes to makes the next key look its terminal up
//! again, so a key never goes to a terminal that no longer owns the id. Reads deref to the map;
//! the only writes are [`RouteTable::insert`] and [`RouteTable::remove`], so the compiler finds
//! every write and none can skip the generation.

use std::collections::HashMap;
use std::hash::Hash;
use std::ops::Deref;
use std::sync::atomic::{AtomicU64, Ordering};

static ROUTE_GENERATION: AtomicU64 = AtomicU64::new(0);

/// The current route generation: it moves on every write of a routing table.
pub fn route_generation() -> u64 {
    ROUTE_GENERATION.load(Ordering::Acquire)
}

fn route_changed() {
    ROUTE_GENERATION.fetch_add(1, Ordering::AcqRel);
}

/// A routing map whose writes move [`route_generation`].
#[derive(Clone, Debug)]
pub struct RouteTable<K, V>(HashMap<K, V>);

impl<K, V> Default for RouteTable<K, V> {
    fn default() -> Self {
        Self(HashMap::new())
    }
}

impl<K: Eq + Hash, V> RouteTable<K, V> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, key: K, value: V) -> Option<V> {
        route_changed();
        self.0.insert(key, value)
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        route_changed();
        self.0.remove(key)
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

impl<K: Eq + Hash, V> FromIterator<(K, V)> for RouteTable<K, V> {
    fn from_iter<I: IntoIterator<Item = (K, V)>>(iter: I) -> Self {
        route_changed();
        Self(iter.into_iter().collect())
    }
}

impl<'a, K, V> IntoIterator for &'a RouteTable<K, V> {
    type Item = (&'a K, &'a V);
    type IntoIter = std::collections::hash_map::Iter<'a, K, V>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}
