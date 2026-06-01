//! Socket authentication using SO_PEERCRED.

use std::io;

/// Information about the connected peer process.
#[derive(Debug)]
pub struct PeerInfo {
    pub pid: u32,
    pub uid: u32,
    pub gid: u32,
}

/// Authenticate a connected peer using SO_PEERCRED.
///
/// On Linux, this retrieves the PID, UID, and GID of the connected process
/// from the kernel.
pub fn authenticate_peer(stream: &tokio::net::UnixStream) -> io::Result<PeerInfo> {
    let cred = stream.peer_cred()?;

    Ok(PeerInfo {
        pid: cred.pid().and_then(|p| u32::try_from(p).ok()).unwrap_or(0),
        uid: cred.uid(),
        gid: cred.gid(),
    })
}

/// Check if the peer is the same user as the cmux process.
pub fn is_same_user(peer: &PeerInfo) -> bool {
    peer.uid == unsafe { libc::getuid() }
}

/// Socket control mode matching macOS cmux.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SocketControlMode {
    /// Only allow connections from cmux child processes (same UID + descendant PID).
    CmuxOnly,
    /// Allow any connection from the same local user (same UID).
    LocalUser,
    /// Allow any local connection (no auth check).
    AllowAll,
}

impl SocketControlMode {
    /// Parse from environment variable or config.
    pub fn from_env() -> Self {
        match std::env::var("CMUX_SOCKET_MODE").as_deref() {
            Ok("allowAll") => Self::AllowAll,
            Ok("localUser") => Self::LocalUser,
            _ => Self::CmuxOnly,
        }
    }
}

/// Check whether a peer is authorized under the given control mode.
/// `server_pid` should be the cmux server process ID (used for CmuxOnly descendant check).
pub fn is_authorized(peer: &PeerInfo, mode: SocketControlMode, server_pid: u32) -> bool {
    match mode {
        SocketControlMode::AllowAll => true,
        SocketControlMode::LocalUser => is_same_user(peer),
        SocketControlMode::CmuxOnly => {
            // Same UID + peer must be a descendant of the cmux process.
            is_same_user(peer) && is_descendant(peer.pid, server_pid)
        }
    }
}

/// Check if `pid` is a descendant of `ancestor_pid` by walking /proc/PID/status.
fn is_descendant(pid: u32, ancestor_pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let mut current = pid;
    // Walk up the process tree (bounded to prevent infinite loops)
    for _ in 0..64 {
        if current == ancestor_pid {
            return true;
        }
        if current <= 1 {
            return false;
        }
        match read_ppid(current) {
            Some(ppid) if ppid != current => current = ppid,
            _ => return false,
        }
    }
    false
}

fn read_ppid(pid: u32) -> Option<u32> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("PPid:") {
            return rest.trim().parse().ok();
        }
    }
    None
}
