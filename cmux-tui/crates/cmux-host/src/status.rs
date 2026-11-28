//! `cmux host status --json`: the agent publishes its state to
//! `/run/cmux-host/status.json` after every wake; the verb reads that file
//! and checks that the agent process is still alive. No socket, no request
//! to the agent.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::roles::RoleStatus;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    pub agent_pid: u32,
    /// Set by the reader: the agent process exists.
    pub agent_running: bool,
    pub instance_id: Option<String>,
    pub parked: bool,
    /// `down`, `running`, `stopping` or `backoff`.
    pub daemon: String,
    pub daemon_pid: Option<u32>,
    /// Consecutive short-lived session host exits.
    pub fast_exits: u32,
    /// Each role with its `last_error`.
    pub roles: Vec<RoleStatus>,
    /// The first wake of the last loop turn.
    pub last_wake: String,
    /// Loop turns since the agent started.
    pub wakes: u64,
}

impl Status {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_owned())
    }

    pub fn from_json(text: &str) -> Option<Self> {
        serde_json::from_str(text).ok()
    }

    /// One human line.
    pub fn summary(&self) -> String {
        format!(
            "agent {} (pid {}), instance {}, {}, session host {}{}",
            if self.agent_running { "running" } else { "not running" },
            self.agent_pid,
            self.instance_id.as_deref().unwrap_or("unbound"),
            if self.parked { "parked" } else { "active" },
            self.daemon,
            self.daemon_pid.map(|pid| format!(" (pid {pid})")).unwrap_or_default(),
        )
    }
}

/// Reads the status file; `alive` answers whether a pid exists.
pub fn read(path: &Path, alive: impl Fn(u32) -> bool) -> Option<Status> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut status = Status::from_json(&text)?;
    status.agent_running = alive(status.agent_pid);
    Some(status)
}
