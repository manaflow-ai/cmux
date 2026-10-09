//! A terminal's relation to its host as clients see it: the connection state
//! to a hosted terminal's host (tab JSON `terminal_state`; read by
//! `metadata.rs`), and why a terminal runs in the daemon process although
//! hosts are on or why its host ends with the daemon's job (tab JSON
//! `terminal_host_fallback`, cx-ko2e).

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

/// Why a terminal will not outlive what normally ends only its shell,
/// although terminal hosts are on (plans/cmux-next/windows-terminal-hosts.md,
/// coordinator decision 2026-10-09). Clients read an unknown value as a
/// notice for another reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalHostFallback {
    /// Windows: the daemon's Job Object forbids breakaway and kills its
    /// processes on close, so the terminal's host runs inside that job. It
    /// survives a daemon restart but ends when the program that started the
    /// daemon closes the job.
    BreakawayDenied,
    /// The host process did not start, so the daemon runs the terminal in
    /// its own process (ConPTY): it ends with the daemon.
    HostStartFailed,
}

impl TerminalHostFallback {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BreakawayDenied => "breakaway_denied",
            Self::HostStartFailed => "host_start_failed",
        }
    }
}

impl Surface {
    /// Why this terminal will not outlive what normally ends only its shell
    /// although terminal hosts are on (tab JSON `terminal_host_fallback`).
    pub fn terminal_host_fallback(&self) -> Option<TerminalHostFallback> {
        self.as_pty().and_then(|pty| pty.host_fallback.get().copied())
    }

    /// Record why this terminal could not get a host that outlives the
    /// daemon and its starter. Call it before the surface is published; a
    /// later call keeps the first reason.
    // Called by the Windows host spawn (terminal_host_runtime/windows, cx-ko2e).
    #[allow(dead_code)]
    pub(crate) fn mark_terminal_host_fallback(&self, reason: TerminalHostFallback) {
        if let Some(pty) = self.as_pty() {
            let _ = pty.host_fallback.set(reason);
        }
    }
}
