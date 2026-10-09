//! A terminal's relation to its host as clients see it: the connection state
//! to a hosted terminal's host (tab JSON `terminal_state`; read by
//! `metadata.rs`), and why a terminal runs in the daemon process although
//! hosts are on (tab JSON `terminal_host_fallback`, cx-ko2e).

use super::Surface;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TerminalHostConnectionState {
    Connected = 0,
    Reconnecting = 1,
    Exited = 2,
    Failed = 3,
}

impl TerminalHostConnectionState {
    pub(super) fn from_u8(value: u8) -> Self {
        match value {
            1 => Self::Reconnecting,
            2 => Self::Exited,
            3 => Self::Failed,
            _ => Self::Connected,
        }
    }
}

/// Why a terminal runs in the daemon process while terminal hosts are on, so
/// it ends with the daemon instead of surviving a restart
/// (plans/cmux-next/windows-terminal-hosts.md). Clients read an unknown
/// value as a fallback for another reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalHostFallback {
    /// Windows: the daemon runs in a Job Object that does not allow
    /// breakaway (`CREATE_BREAKAWAY_FROM_JOB` gave `ERROR_ACCESS_DENIED`), so
    /// a host would end with the daemon's job; the daemon owns the ConPTY.
    BreakawayDenied,
}

impl TerminalHostFallback {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BreakawayDenied => "breakaway_denied",
        }
    }
}

impl Surface {
    /// Why this terminal runs in the daemon process although terminal hosts
    /// are on (tab JSON `terminal_host_fallback`): it ends with the daemon.
    pub fn terminal_host_fallback(&self) -> Option<TerminalHostFallback> {
        self.as_pty().and_then(|pty| pty.host_fallback.get().copied())
    }

    /// Record why this terminal could not get its own host. Call it before
    /// the surface is published; a later call keeps the first reason.
    // Called by the Windows host spawn (terminal_host_runtime/windows, cx-ko2e).
    #[allow(dead_code)]
    pub(crate) fn mark_terminal_host_fallback(&self, reason: TerminalHostFallback) {
        if let Some(pty) = self.as_pty() {
            let _ = pty.host_fallback.set(reason);
        }
    }
}
