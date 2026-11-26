//! The placement table: workspace slug -> where the workspace runs now.
//!
//! Each entry is an immutable [`Placement`] behind an `Arc`. A move replaces the `Arc` in one
//! write; a reader that already cloned the old `Arc` (an accepted connection) keeps it, so open
//! connections never see a half-updated target and keep their old backend until they close.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, RwLock};

use serde::{Deserialize, Serialize};

use crate::messages::PlacementMessage;

/// One backend address, `host:port`, as the dialer takes it (a hostname, an IPv4 or a bracketed
/// IPv6 literal). Kept as text so a tailnet name or a relay name works as well as an IP.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Backend(pub String);

impl Backend {
    pub fn new(addr: impl Into<String>) -> Self {
        Self(addr.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Where one workspace runs now.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Placement {
    /// The workspace's SSH server, if it serves one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<Backend>,
    /// Preview port (the port the workspace's app listens on, as the user knows it) -> where that
    /// port is reachable now.
    ///
    /// On the wire the keys are strings (`{"3000": "host:3000"}`, as JSON maps need), read
    /// through [`port_keys`]: serde's integer-key parsing fails inside an internally tagged
    /// enum, which every [`crate::PlacementMessage`] is.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty", with = "port_keys")]
    pub previews: BTreeMap<u16, Backend>,
}

/// Preview maps with string port keys on the wire.
mod port_keys {
    use std::collections::BTreeMap;

    use serde::de::Error as _;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    use super::Backend;

    pub fn serialize<S: Serializer>(
        map: &BTreeMap<u16, Backend>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        let as_text: BTreeMap<String, &Backend> =
            map.iter().map(|(port, b)| (port.to_string(), b)).collect();
        as_text.serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<BTreeMap<u16, Backend>, D::Error> {
        let as_text = BTreeMap::<String, Backend>::deserialize(deserializer)?;
        as_text
            .into_iter()
            .map(|(port, b)| {
                port.parse::<u16>()
                    .map(|p| (p, b))
                    .map_err(|_| D::Error::custom(format!("preview port {port:?} is not a port")))
            })
            .collect()
    }
}

/// One table entry: the placement and the generation it was written at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub placement: Arc<Placement>,
    /// The table generation of the write that put this placement in. Strictly increasing per
    /// table, so "which target did this connection get" is answerable after the fact.
    pub generation: u64,
}

/// What [`PlacementTable::apply`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    /// The workspace now has this placement (set or moved).
    Placed { generation: u64 },
    /// The workspace's placement was removed (it had one).
    Removed,
    /// Nothing changed: a remove of an unknown workspace, a move whose `from_generation` is not
    /// the current one, or a message kind this build does not know.
    Ignored,
}

#[derive(Debug, Default)]
struct Inner {
    entries: HashMap<String, Entry>,
    generation: u64,
}

/// The runtime table. Cheap to share (`Arc<PlacementTable>`); every method takes `&self`.
#[derive(Debug, Default)]
pub struct PlacementTable {
    inner: RwLock<Inner>,
}

impl PlacementTable {
    pub fn new() -> Self {
        Self::default()
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, Inner> {
        // A panic while holding the lock cannot leave Inner half-written (every write is one
        // insert or remove), so a poisoned lock's data is still good.
        self.inner.read().unwrap_or_else(|e| e.into_inner())
    }

    fn write(&self) -> std::sync::RwLockWriteGuard<'_, Inner> {
        self.inner.write().unwrap_or_else(|e| e.into_inner())
    }

    /// Put (or replace) a workspace's placement. Returns the new generation.
    pub fn set(&self, workspace: &str, placement: Placement) -> u64 {
        let mut inner = self.write();
        inner.generation += 1;
        let generation = inner.generation;
        inner
            .entries
            .insert(workspace.to_owned(), Entry { placement: Arc::new(placement), generation });
        generation
    }

    /// Move a workspace: swap its placement atomically. With `from_generation`, the move only
    /// happens when the current entry is still that generation (a stale move from a racing
    /// orchestrator is dropped). Returns the new generation, or `None` when it was dropped.
    pub fn move_to(
        &self,
        workspace: &str,
        placement: Placement,
        from_generation: Option<u64>,
    ) -> Option<u64> {
        let mut inner = self.write();
        if let Some(expected) = from_generation {
            let current = inner.entries.get(workspace).map(|e| e.generation);
            if current != Some(expected) {
                return None;
            }
        }
        inner.generation += 1;
        let generation = inner.generation;
        inner
            .entries
            .insert(workspace.to_owned(), Entry { placement: Arc::new(placement), generation });
        Some(generation)
    }

    /// Remove a workspace. Open connections keep their target; new ones find nothing.
    pub fn remove(&self, workspace: &str) -> bool {
        self.write().entries.remove(workspace).is_some()
    }

    /// The workspace's current entry, cloned out (an `Arc` clone), so the caller holds no lock.
    pub fn get(&self, workspace: &str) -> Option<Entry> {
        self.read().entries.get(workspace).cloned()
    }

    /// The workspace's current SSH target.
    pub fn ssh_target(&self, workspace: &str) -> Option<(Backend, u64)> {
        let entry = self.get(workspace)?;
        let backend = entry.placement.ssh.clone()?;
        Some((backend, entry.generation))
    }

    /// The workspace's current target for one preview port.
    pub fn preview_target(&self, workspace: &str, port: u16) -> Option<(Backend, u64)> {
        let entry = self.get(workspace)?;
        let backend = entry.placement.previews.get(&port).cloned()?;
        Some((backend, entry.generation))
    }

    /// Every workspace slug in the table, sorted.
    pub fn workspaces(&self) -> Vec<String> {
        let mut out: Vec<String> = self.read().entries.keys().cloned().collect();
        out.sort();
        out
    }

    /// Apply one wire message.
    pub fn apply(&self, message: &PlacementMessage) -> Applied {
        match message {
            PlacementMessage::Set { workspace, placement, .. } => {
                Applied::Placed { generation: self.set(workspace, placement.clone()) }
            }
            PlacementMessage::Moved { workspace, placement, from_generation, .. } => {
                match self.move_to(workspace, placement.clone(), *from_generation) {
                    Some(generation) => Applied::Placed { generation },
                    None => Applied::Ignored,
                }
            }
            PlacementMessage::Removed { workspace, .. } => {
                if self.remove(workspace) {
                    Applied::Removed
                } else {
                    Applied::Ignored
                }
            }
            PlacementMessage::Unknown => Applied::Ignored,
        }
    }
}

#[cfg(test)]
#[path = "placement_tests.rs"]
mod tests;
