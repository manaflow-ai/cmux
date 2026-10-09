//! Launch snapshots: the launch snapshot path and subscription. Shell
//! command history is `mux/command_history.rs`.

use super::*;

impl Mux {
    /// The launch snapshot file (`launch-snapshot-v1`) while its writer runs.
    pub fn launch_snapshot_path(&self) -> Option<std::path::PathBuf> {
        self.launch_snapshot_path.lock().unwrap().clone()
    }

    pub(crate) fn set_launch_snapshot_path(&self, path: Option<std::path::PathBuf>) {
        *self.launch_snapshot_path.lock().unwrap() = path;
    }

    /// Events that can change the launch snapshot.
    pub(crate) fn subscribe_launch_snapshot(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_launch_snapshot()
    }
}
