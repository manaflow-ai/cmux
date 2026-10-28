//! What one PTY surface holds in the daemon, for `memory-report`
//! (server/memory_report.rs) and `server-stats` `memory`
//! (server/memory_stats.rs).

use super::*;

/// Where a PTY surface's shell runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PtyHome {
    /// A PTY this daemon reads itself.
    Daemon,
    /// The holder runs the shell; `ring_bytes` is the ring segment the
    /// daemon keeps a copy of, `None` when it keeps none.
    Holder { ring_bytes: Option<u64> },
    /// A terminal host process runs it; the daemon's terminal mirrors it.
    Host,
    /// The hosted terminal ended.
    Exited,
}

impl PtyHome {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Daemon => "daemon",
            Self::Holder { .. } => "holder",
            Self::Host => "host",
            Self::Exited => "exited",
        }
    }
}

/// The daemon's libghostty-vt terminal of a PTY surface, read without
/// restoring a cold one (surface/terminal_runtime/cold_terminal.rs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TerminalMemory {
    /// Live: its pages, per screen, and Kitty images, and the scrollback
    /// rows above its viewport.
    Hot { usage: ghostty_vt::TerminalMemoryUsage, scrollback_rows: u64 },
    /// Compressed whole by the cold-scrollback codec (p07-memory-041).
    Cold {
        /// Bytes it holds: the compressed snapshot and the Kitty replay.
        held_bytes: u64,
        /// The snapshot's bytes before compression.
        snapshot_bytes: u64,
    },
}

/// One PTY surface's memory as the daemon holds it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SurfaceMemory {
    pub(crate) home: PtyHome,
    /// `None` while the terminal moves between hot and cold, or when
    /// libghostty-vt cannot report it.
    pub(crate) terminal: Option<TerminalMemory>,
}

impl SurfaceMemory {
    /// The holder ring segment the daemon keeps a copy of; 0 when it keeps
    /// none.
    pub(crate) fn ring_bytes(&self) -> u64 {
        match self.home {
            PtyHome::Holder { ring_bytes: Some(bytes) } => bytes,
            PtyHome::Holder { ring_bytes: None }
            | PtyHome::Daemon
            | PtyHome::Host
            | PtyHome::Exited => 0,
        }
    }

    /// Every byte the daemon holds for this terminal: a hot terminal's pages
    /// of both screens (compressed pages at their compressed size) and its
    /// Kitty images, a cold terminal's compressed state, and the holder ring
    /// copy. A terminal it could not read adds only its ring.
    pub(crate) fn bytes(&self) -> u64 {
        let terminal = match self.terminal {
            Some(TerminalMemory::Hot { usage, .. }) => usage
                .primary
                .resident_bytes
                .saturating_add(usage.alternate.resident_bytes)
                .saturating_add(usage.primary.image_bytes)
                .saturating_add(usage.alternate.image_bytes),
            Some(TerminalMemory::Cold { held_bytes, .. }) => held_bytes,
            None => 0,
        };
        terminal.saturating_add(self.ring_bytes())
    }
}

impl Surface {
    /// This surface's memory, `None` for a browser surface. The runtime lock
    /// is released before the terminal lock is taken, and the holder's ring
    /// is measured after both. A cold terminal stays cold.
    pub(crate) fn memory_usage(&self) -> Option<SurfaceMemory> {
        let pty = self.as_pty()?;
        #[cfg(unix)]
        let mut holder = None;
        let home = match &*pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner) {
            #[cfg(unix)]
            PtyRuntime::Local { holder: Some(terminal), .. } => {
                holder = Some(terminal.clone());
                PtyHome::Holder { ring_bytes: None }
            }
            PtyRuntime::Local { .. } => PtyHome::Daemon,
            #[cfg(any(unix, windows))]
            PtyRuntime::Hosted(_) => PtyHome::Host,
            #[cfg(any(unix, windows))]
            PtyRuntime::ExitedHosted => PtyHome::Exited,
        };
        let terminal = pty.term.memory();
        #[cfg(unix)]
        let home = match holder {
            Some(holder) => PtyHome::Holder { ring_bytes: holder.ring_bytes() },
            None => home,
        };
        Some(SurfaceMemory { home, terminal })
    }
}
