//! `list-workspaces {since: {epoch, seq}}` (`workspace-list-delta-v1`): only the workspace
//! entries that changed since the client's cursor, keyed by their `id`, instead of the whole
//! tree on one change.
//!
//! The daemon keeps one digest per workspace entry of the last tree a `since` request read, and
//! a bounded ring of the ids whose entry changed (or that went away), keyed by a sequence number
//! that moves once for each read that found a change. A client that holds the cursor
//! `{epoch, seq}` of an earlier reply gets the entries of every id the ring holds past its `seq`,
//! as the current tree renders them, and the ids of those no longer there. The digests come from
//! the rendered tree itself, so no event has to say which workspace it touched: whatever the tree
//! shows (a title, an unread marker, a branch) moves exactly the entry that shows it.
//!
//! `epoch` is random per daemon run. A cursor from another run, or one older than the ring holds,
//! gets the whole tree with a fresh cursor, as `list-workspaces` answers today.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, PoisonError};

use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

use crate::Mux;

/// `since` on `list-workspaces`: the changed entries keyed by id against a cursor.
pub const WORKSPACE_LIST_DELTA_CAPABILITY: &str = "workspace-list-delta-v1";

/// The changed or removed ids the ring holds at most. Past it, the oldest seqs leave the ring,
/// and a cursor from before them gets the whole tree.
pub(crate) const WORKSPACE_DELTA_RING_IDS: usize = 256;

/// A client's cursor (`since`): the `epoch` and `seq` of the last reply it applied.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub(crate) struct DeltaCursor {
    pub(crate) epoch: String,
    pub(crate) seq: u64,
}

/// What changed past a cursor: the ids to send (as changed entries or as removed ids), and
/// whether the sidebar order or the groups changed.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Delta {
    pub(crate) ids: BTreeSet<u64>,
    pub(crate) order: bool,
    pub(crate) groups: bool,
}

/// The digests of the last tree read and the ring of what changed, by seq.
pub(crate) struct WorkspaceDeltaRing {
    epoch: String,
    seq: u64,
    /// A cursor at or past this seq is answered from the ring: every seq after it is held.
    floor: u64,
    ring: VecDeque<(u64, Vec<u64>)>,
    held: usize,
    capacity: usize,
    baseline: bool,
    entries: HashMap<u64, u64>,
    order: Vec<u64>,
    groups: u64,
    order_seq: u64,
    groups_seq: u64,
}

impl WorkspaceDeltaRing {
    pub(crate) fn new(epoch: String, capacity: usize) -> Self {
        Self {
            epoch,
            seq: 0,
            floor: 0,
            ring: VecDeque::new(),
            held: 0,
            capacity: capacity.max(1),
            baseline: false,
            entries: HashMap::new(),
            order: Vec::new(),
            groups: 0,
            order_seq: 0,
            groups_seq: 0,
        }
    }

    pub(crate) fn epoch(&self) -> &str {
        &self.epoch
    }

    pub(crate) fn seq(&self) -> u64 {
        self.seq
    }

    /// Records a read of the tree: `entries` are each workspace's id and the digest of its
    /// entry, in the tree's order. Moves `seq` when anything differs from the last read.
    pub(crate) fn record(&mut self, entries: &[(u64, u64)], groups: u64) -> u64 {
        let order = entries.iter().map(|(id, _)| *id).collect::<Vec<_>>();
        let digests = entries.iter().copied().collect::<HashMap<_, _>>();
        if !self.baseline {
            self.baseline = true;
            self.seq = 1;
            self.floor = 1;
            self.entries = digests;
            self.order = order;
            self.groups = groups;
            return self.seq;
        }
        let mut ids = entries
            .iter()
            .filter(|(id, digest)| self.entries.get(id) != Some(digest))
            .map(|(id, _)| *id)
            .collect::<Vec<_>>();
        ids.extend(self.entries.keys().filter(|id| !digests.contains_key(id)).copied());
        let order_changed = order != self.order;
        let groups_changed = groups != self.groups;
        if ids.is_empty() && !order_changed && !groups_changed {
            return self.seq;
        }
        self.seq += 1;
        if order_changed {
            self.order_seq = self.seq;
        }
        if groups_changed {
            self.groups_seq = self.seq;
        }
        self.held += ids.len();
        self.ring.push_back((self.seq, ids));
        while self.held > self.capacity {
            let Some((seq, ids)) = self.ring.pop_front() else { break };
            self.held -= ids.len();
            self.floor = seq;
        }
        self.entries = digests;
        self.order = order;
        self.groups = groups;
        self.seq
    }

    /// What changed past `cursor`, or `None` when the ring cannot say (another daemon run, a
    /// seq older than the ring, or one it never gave out).
    pub(crate) fn since(&self, cursor: &DeltaCursor) -> Option<Delta> {
        if !self.baseline
            || cursor.epoch != self.epoch
            || cursor.seq < self.floor
            || cursor.seq > self.seq
        {
            return None;
        }
        let ids = self
            .ring
            .iter()
            .filter(|(seq, _)| *seq > cursor.seq)
            .flat_map(|(_, ids)| ids.iter().copied())
            .collect();
        Some(Delta {
            ids,
            order: self.order_seq > cursor.seq,
            groups: self.groups_seq > cursor.seq,
        })
    }
}

/// The ring and the last tree it read, for `list-workspaces {since}`. One request reads, diffs
/// and answers at a time, so the digests always follow the trees in the order they were read.
pub(crate) struct WorkspaceDelta {
    state: Mutex<WorkspaceDeltaState>,
}

struct WorkspaceDeltaState {
    ring: WorkspaceDeltaRing,
    /// The tree revision read before the last tree, and that tree.
    read: Option<(String, Arc<Value>)>,
}

impl Default for WorkspaceDelta {
    fn default() -> Self {
        Self::new(WORKSPACE_DELTA_RING_IDS)
    }
}

impl WorkspaceDelta {
    pub(crate) fn new(capacity: usize) -> Self {
        Self {
            state: Mutex::new(WorkspaceDeltaState {
                ring: WorkspaceDeltaRing::new(random_epoch(), capacity),
                read: None,
            }),
        }
    }
}

fn random_epoch() -> String {
    let mut bytes = [0u8; 8];
    if getrandom::fill(&mut bytes).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos() as u64);
        bytes = (nanos ^ u64::from(std::process::id())).to_le_bytes();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn digest(value: &Value) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    value.to_string().hash(&mut hasher);
    hasher.finish()
}

fn entry_id(entry: &Value) -> Option<u64> {
    entry.get("id").and_then(Value::as_u64)
}

/// The id and digest of each workspace entry of `tree`, in its order, and the groups' digest.
fn digests_of(tree: &Value) -> (Vec<(u64, u64)>, u64) {
    let entries = tree
        .get("workspaces")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| Some((entry_id(entry)?, digest(entry))))
        .collect();
    (entries, digest(tree.get("groups").unwrap_or(&Value::Null)))
}

/// `list-workspaces {since}` for a client that sees every workspace. A client that holds
/// nothing sends a cursor no ring knows (`{"epoch": "", "seq": 0}`) and gets the whole tree with
/// its first cursor.
pub(super) fn list_workspaces_reply_delta(mux: &Mux, since: &DeltaCursor) -> anyhow::Result<Value> {
    // As with `known`: a branch switch reaches the tree through the background refresh.
    mux.revalidate_git_heads();
    let mut state = mux.workspace_delta.state.lock().unwrap_or_else(PoisonError::into_inner);
    let revision = mux.tree_revision();
    let tree = match &state.read {
        // Nothing the tree shows changed since the last read: answer from it, with no read.
        Some((read_at, tree)) if *read_at == revision => tree.clone(),
        _ => {
            let tree = Arc::new(super::list_workspaces_reply(mux)?);
            let (entries, groups) = digests_of(&tree);
            state.ring.record(&entries, groups);
            state.read = Some((revision, tree.clone()));
            tree
        }
    };
    let (epoch, seq) = (state.ring.epoch().to_string(), state.ring.seq());
    let delta = state.ring.since(since);
    drop(state);
    let Some(delta) = delta else {
        let mut whole = Value::clone(&tree);
        whole.set("epoch", json!(epoch));
        whole.set("seq", json!(seq));
        return Ok(whole);
    };
    Ok(delta_reply(&tree, &delta, epoch, seq))
}

/// The reply for `delta` against `tree`: the identity and revisions of the whole tree, its
/// changed entries as it renders them, the ids it no longer holds, and the order and the groups
/// when they changed.
fn delta_reply(tree: &Value, delta: &Delta, epoch: String, seq: u64) -> Value {
    let mut reply = Map::new();
    if let Some(fields) = tree.as_object() {
        for (key, value) in fields {
            if !matches!(key.as_str(), "workspaces" | "groups") {
                reply.insert(key.clone(), value.clone());
            }
        }
    }
    let entries = tree.get("workspaces").and_then(Value::as_array).cloned().unwrap_or_default();
    let changed = entries
        .iter()
        .filter(|entry| entry_id(entry).is_some_and(|id| delta.ids.contains(&id)))
        .cloned()
        .collect::<Vec<_>>();
    let present = entries.iter().filter_map(entry_id).collect::<BTreeSet<_>>();
    let removed = delta.ids.iter().filter(|id| !present.contains(id)).copied().collect::<Vec<_>>();
    if delta.groups {
        reply.insert("groups".into(), tree.get("groups").cloned().unwrap_or(json!([])));
    }
    if delta.order {
        reply.insert("order".into(), json!(present_in_order(&entries)));
    }
    reply.insert("delta".into(), json!(true));
    reply.insert("epoch".into(), json!(epoch));
    reply.insert("seq".into(), json!(seq));
    reply.insert("changed".into(), Value::Array(changed));
    reply.insert("removed".into(), json!(removed));
    // Empty, so a typed SDK still decodes the reply as the `Tree` it declares.
    reply.insert("workspaces".into(), json!([]));
    Value::Object(reply)
}

fn present_in_order(entries: &[Value]) -> Vec<u64> {
    entries.iter().filter_map(entry_id).collect()
}

#[cfg(test)]
#[path = "list_workspaces_delta_tests.rs"]
mod list_workspaces_delta_tests;
