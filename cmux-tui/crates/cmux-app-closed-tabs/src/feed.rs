//! What the closed tabs feed watches (`ClosedTabsFeed.signature(of:)`): it bumps its change
//! counter whenever this signature changes, so Search Tabs and the control snapshot read the
//! mirrored tabs and the closed list together. O(machines) plus the closed ids.

use serde::{Deserialize, Serialize};

/// One machine's daemon as the feed reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FeedMachine {
    /// Its machine id (`DaemonService.machineID`).
    pub machine: String,
    /// Its store's connection is `.connected`.
    pub connected: bool,
    /// Its store loaded its first snapshot (`DaemonStore.isLoaded`).
    pub loaded: bool,
    /// Bumped once per apply that changes its tabs, their panes or order
    /// (`DaemonStore.tabListRevision`).
    pub tab_list_revision: u64,
    /// Its mirrored closed item ids, in the daemon's order (`DaemonStore.closedItems`).
    pub closed: Vec<String>,
}

/// The signature: for each connected, loaded machine in order, `machine:revision` and then its
/// closed item ids. A machine that is not connected or not loaded adds nothing.
pub fn signature(machines: &[FeedMachine]) -> Vec<String> {
    let mut parts = Vec::new();
    for machine in machines.iter().filter(|machine| machine.connected && machine.loaded) {
        parts.push(format!("{}:{}", machine.machine, machine.tab_list_revision));
        parts.extend(machine.closed.iter().cloned());
    }
    parts
}

/// Whether the feed bumps: the signature changed since the last one it saw.
pub fn changed(previous: &[String], machines: &[FeedMachine]) -> bool {
    signature(machines) != previous
}
