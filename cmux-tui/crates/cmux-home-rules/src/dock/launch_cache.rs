//! `HomeSidebarLaunchCache` (CmuxNextHomeEngine/HomeSidebarLaunchCache.swift): the rules of the
//! sidebar's launch cache. The app reads and writes the file and makes the snapshot's shape string
//! (Swift reflection); these rules hash the shape, name the file and coalesce saves.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The snapshot schema: FNV-1a 64 of the shape string, 16 lowercase hex digits.
pub fn fingerprint(shape: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in shape.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// The owner's folder name under `cmux-home/`: letters, digits, `-` and `_` stay, the rest is `-`.
pub fn path_component(owner: &str) -> String {
    owner
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect()
}

/// The relative path of the owner's cache file under the caches folder.
pub fn relative_path(owner: &str) -> String {
    format!("cmux-home/{}/sidebar.json", path_component(owner))
}

/// An inbox's key in the snapshot's replies (`HomeSidebarLaunchSnapshot.key`).
pub fn inbox_key(owners: &[String]) -> String {
    owners.join(",")
}

/// Whether a read file is used: its schema and account are the app's now.
pub fn load_accepts(schema: &str, file_schema: &str, account: &str, file_account: &str) -> bool {
    schema == file_schema && account == file_account
}

/// The save coalescer's state. Snapshots are the app's JSON, compared whole.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SaveState {
    pub pending: Option<Value>,
    pub written: Option<Value>,
    pub scheduled: bool,
}

/// One event of the cache.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SaveEvent {
    /// `save(_:)`.
    Save { snapshot: Value },
    /// The scheduled write runs (`flush()`).
    Flush,
    /// The write of `snapshot` succeeded, or `load` read it.
    Written { snapshot: Value },
}

/// What the app does after a step.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveStep {
    pub state: SaveState,
    /// Start one background flush.
    pub schedule: bool,
    /// Write this snapshot to the file.
    pub write: Option<Value>,
}

/// One step of the coalescer: one write in flight; a save meanwhile replaces what it writes.
pub fn step(mut state: SaveState, event: SaveEvent) -> SaveStep {
    match event {
        SaveEvent::Save { snapshot } => {
            if state.written.as_ref() == Some(&snapshot) {
                state.pending = None;
                return SaveStep { state, ..SaveStep::default() };
            }
            state.pending = Some(snapshot);
            let schedule = !state.scheduled;
            state.scheduled = true;
            SaveStep { state, schedule, write: None }
        }
        SaveEvent::Flush => {
            state.scheduled = false;
            let write = state.pending.take();
            SaveStep { state, schedule: false, write }
        }
        SaveEvent::Written { snapshot } => {
            state.written = Some(snapshot);
            SaveStep { state, ..SaveStep::default() }
        }
    }
}
