//! What the host and worker ask of the OS: process identity (start time,
//! executable, parent chain), the local transport with its kernel peer
//! checks, private files, owner-only configuration, and the desktop session.

use std::path::PathBuf;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::*;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

/// One process instance: its id and start time, so a reused id never matches
/// an earlier process (Linux: `/proc/<pid>/stat` field 22 in clock ticks;
/// Windows: the creation FILETIME).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct ProcessStamp {
    pub pid: u32,
    pub start: u64,
}

impl ProcessStamp {
    /// The stamp of a live process.
    pub fn of(pid: u32) -> Option<Self> {
        process_start(pid).map(|start| Self { pid, start })
    }

    /// Whether this exact process still runs.
    pub fn is_alive(&self) -> bool {
        process_start(self.pid) == Some(self.start)
    }
}

/// What the kernel says about a connected local peer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerFacts {
    /// Runs as this user (uid, or the token's SID).
    pub same_user: bool,
    pub stamp: ProcessStamp,
    /// The running image (Linux `/proc/<pid>/exe`; Windows the image path).
    pub executable: Option<PathBuf>,
    /// SHA-256 of the running image.
    pub executable_sha256: Option<String>,
    /// Parent chain, nearest first.
    pub ancestors: Vec<ProcessStamp>,
}

impl PeerFacts {
    /// Facts about `pid`, read after the kernel named it as the peer. Fails
    /// when the process is gone or changed while reading (start time again).
    pub fn of(pid: u32, same_user: bool) -> Option<Self> {
        let stamp = ProcessStamp::of(pid)?;
        let executable = process_exe(pid);
        let executable_sha256 = process_exe_sha256(pid);
        let ancestors = ancestors(pid);
        stamp.is_alive().then_some(Self { same_user, stamp, executable, executable_sha256, ancestors })
    }
}

/// The parent chain of `pid`, nearest first, stopping at a parent that started
/// after its child (a reused id) or at the init process.
pub fn ancestors(pid: u32) -> Vec<ProcessStamp> {
    let mut chain = Vec::new();
    let mut current = pid;
    for _ in 0..64 {
        let Some(child_start) = process_start(current) else { break };
        let Some(parent) = parent_pid(current).filter(|parent| *parent > 1 && *parent != current) else { break };
        let Some(stamp) = ProcessStamp::of(parent) else { break };
        if stamp.start > child_start {
            break;
        }
        chain.push(stamp);
        current = parent;
    }
    chain
}

/// This machine's name, for the approval card.
pub fn machine_name() -> String {
    for name in ["CMUX_MACHINE_NAME", "COMPUTERNAME", "HOSTNAME"] {
        if let Some(value) = std::env::var_os(name).filter(|value| !value.is_empty()) {
            return value.to_string_lossy().into_owned();
        }
    }
    std::fs::read_to_string("/etc/hostname").map(|text| text.trim().to_owned()).unwrap_or_else(|_| "unknown".into())
}
