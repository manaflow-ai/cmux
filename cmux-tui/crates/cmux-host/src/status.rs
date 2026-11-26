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
    /// The session host's restart budget on the supervisor contract (`cmux-supervise-core`):
    /// today's faults, and `restart-budget-exceeded` with their causes above it. Absent from an
    /// agent that predates it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restart_budget: Option<cmux_supervise_core::BudgetState>,
    /// What this VM is: its spec, its uptime, and whether it served a session before this agent
    /// started. Absent from an agent that predates it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<MachineFacts>,
}

/// The VM's spec and history, so a Cloud session can say what it ran on and whether the VM was reused.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineFacts {
    pub vcpus: u32,
    pub memory_mib: u64,
    /// Size of the root filesystem and what is free on it, in MiB.
    pub disk_mib: u64,
    pub disk_free_mib: u64,
    /// Seconds since the VM booted (`/proc/uptime`).
    pub uptime_secs: u64,
    /// Unix seconds the first agent on this VM disk started (the marker file's content).
    pub first_agent_start_unix: u64,
    /// An earlier agent run already recorded itself on this VM disk: the VM was reused, not fresh.
    pub reused: bool,
}

/// Parses the first field of `/proc/uptime` into whole seconds.
pub fn parse_uptime(text: &str) -> Option<u64> {
    let first = text.split_whitespace().next()?;
    first.split('.').next()?.parse().ok()
}

/// `MemTotal` of `/proc/meminfo` in MiB.
pub fn parse_mem_total_mib(text: &str) -> Option<u64> {
    let line = text.lines().find(|l| l.starts_with("MemTotal:"))?;
    let kib: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib / 1024)
}

impl MachineFacts {
    /// Reads the live machine. `marker` is a persistent file: absent on a fresh VM disk (the agent
    /// writes `now_unix` into it, `reused` false), present afterwards (`reused` true). Reads nothing it
    /// cannot get: a missing field is zero.
    pub fn read(marker: &Path, now_unix: u64) -> Self {
        let (first, reused) = Self::mark(marker, now_unix);
        Self::live(first, reused)
    }

    /// The marker once, at agent start: (first start, reused).
    pub fn mark(marker: &Path, now_unix: u64) -> (u64, bool) {
        let prior = std::fs::read_to_string(marker).ok().and_then(|t| t.trim().parse::<u64>().ok());
        if prior.is_none() {
            if let Some(dir) = marker.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(marker, format!("{now_unix}\n"));
        }
        (prior.unwrap_or(now_unix), prior.is_some())
    }

    /// The machine's current numbers with the marker's answer; call at each publish so uptime moves.
    pub fn live(first_agent_start_unix: u64, reused: bool) -> Self {
        let (disk_mib, disk_free_mib) = root_disk_mib();
        Self {
            vcpus: std::thread::available_parallelism().map(|n| n.get() as u32).unwrap_or(0),
            memory_mib: std::fs::read_to_string("/proc/meminfo")
                .ok()
                .and_then(|t| parse_mem_total_mib(&t))
                .unwrap_or(0),
            disk_mib,
            disk_free_mib,
            uptime_secs: std::fs::read_to_string("/proc/uptime")
                .ok()
                .and_then(|t| parse_uptime(&t))
                .unwrap_or(0),
            first_agent_start_unix,
            reused,
        }
    }
}

/// Windows has no statvfs; the disk reads as unknown (0, 0) there, as a failed read does.
#[cfg(not(unix))]
fn root_disk_mib() -> (u64, u64) {
    (0, 0)
}

#[cfg(unix)]
fn root_disk_mib() -> (u64, u64) {
    let Ok(path) = std::ffi::CString::new("/") else {
        return (0, 0);
    };
    // SAFETY: statvfs fills a zeroed struct for a valid C string.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut st) } != 0 {
        return (0, 0);
    }
    let frag = st.f_frsize as u64;
    ((st.f_blocks as u64 * frag) >> 20, (st.f_bavail as u64 * frag) >> 20)
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
mod machine_facts_tests {
    use super::*;

    #[test]
    fn parses_proc_files() {
        assert_eq!(parse_uptime("172800.55 340000.10\n"), Some(172800));
        assert_eq!(parse_mem_total_mib("MemTotal:        3984000 kB\nMemFree: 1 kB\n"), Some(3890));
        assert_eq!(parse_uptime(""), None);
    }

    #[test]
    fn first_read_is_fresh_second_is_reused() {
        let dir = std::env::temp_dir().join(format!("cmux-host-facts-{}", std::process::id()));
        let marker = dir.join("first-agent-start");
        let _ = std::fs::remove_dir_all(&dir);
        let first = MachineFacts::read(&marker, 1000);
        assert!(!first.reused);
        assert_eq!(first.first_agent_start_unix, 1000);
        let second = MachineFacts::read(&marker, 5000);
        assert!(second.reused);
        assert_eq!(second.first_agent_start_unix, 1000);
        assert!(second.vcpus >= 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
