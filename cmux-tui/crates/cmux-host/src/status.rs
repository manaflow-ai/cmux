//! `cmux host status --json`: the agent publishes its state to
//! `/run/cmux-host/status.json` after every wake; the verb reads that file
//! and checks that the agent process is still alive. No socket, no request
//! to the agent.

use std::path::Path;

use serde::{Deserialize, Serialize};

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
    pub roles: Vec<String>,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_marks_dead_agents() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("status.json");
        let status = Status {
            agent_pid: 7,
            agent_running: true,
            instance_id: Some("vm-1".to_owned()),
            parked: false,
            daemon: "running".to_owned(),
            daemon_pid: Some(9),
            fast_exits: 0,
            roles: vec![],
            last_wake: "clock".to_owned(),
            wakes: 3,
        };
        std::fs::write(&path, status.to_json()).unwrap();
        let read_back = read(&path, |_| false).unwrap();
        assert!(!read_back.agent_running);
        assert_eq!(read_back.instance_id.as_deref(), Some("vm-1"));
        assert!(read_back.summary().contains("not running"));
        assert!(read(&dir.path().join("missing"), |_| true).is_none());
    }
}
