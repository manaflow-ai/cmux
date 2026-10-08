//! Archive on close (ARCHIVE-1, cx-gzh.4.1, plans/cmux-next/reopen-closed.md
//! section 3, S3).
//!
//! A close ends a terminal that still runs in one of two places: the reaper
//! ends a terminal whose last tab closed (Cmd-W, after the reap grace), and a
//! batch close with `end_terminals` (Close Workspace) ends it in the close
//! commit. Both call [`Mux::archive_terminal_runtimes`] before the host is
//! asked to stop. It keeps, per terminal:
//!
//! - the screen with its scrollback (bounded `cmux.vt-replay.v1`), stored as
//!   the terminal's exit snapshot, the same record a process end keeps;
//! - the program the close stops: the PTY's foreground job when it is not the
//!   shell (one query of the terminal's own child, never a process scan), or
//!   the program of a command terminal. Only its basename is kept, never its
//!   arguments.
//!
//! The directory and environment are already in the relaunch record, which
//! the closed tab copied (`relaunch_store`: allowlisted keys only, never a
//! key that names a secret). Reopen Closed ([`Mux::reopen_terminal_spawn`])
//! starts a new shell there whose host applies the archived screen and one
//! dim line that names the stopped program before the shell's first byte.

use super::*;
use crate::workspace_registry::JournalContentBlob;
use crate::workspace_registry::relaunch_store::RelaunchKind;

/// What one archived terminal keeps (see the module docs).
pub(crate) struct TerminalArchive {
    /// The public terminal id.
    pub(crate) terminal_id: String,
    /// The incarnation the close stops.
    pub(crate) generation: String,
    pub(crate) screen: Option<JournalContentBlob>,
    pub(crate) stopped: Option<String>,
}

impl Mux {
    /// Archive `runtimes`, the terminals a committed close is about to stop.
    /// Best effort: a failure costs the reopened tab its screen, never the
    /// close.
    pub(crate) fn archive_terminal_runtimes(&self, runtimes: &[Arc<Surface>]) {
        if runtimes.is_empty() {
            return;
        }
        // The replay and the journaled output must describe the same bytes.
        if let Err(error) = self.flush_terminal_journal() {
            eprintln!("cmux-tui: archive could not settle terminal output: {error:#}");
        }
        let archives =
            runtimes.iter().filter_map(|runtime| self.capture_terminal_archive(runtime)).collect();
        self.store_terminal_archives(archives);
    }

    /// Store `archives` in one registry transaction.
    pub(crate) fn store_terminal_archives(&self, archives: Vec<TerminalArchive>) {
        if archives.is_empty() {
            return;
        }
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(error) = registry.put_terminal_archives(&archives) {
            eprintln!(
                "cmux-tui: could not store {} terminal archive(s): {error:#}",
                archives.len()
            );
        }
    }

    /// The archive of one live PTY runtime; the caller flushed the journal.
    pub(crate) fn capture_terminal_archive(
        &self,
        runtime: &Arc<Surface>,
    ) -> Option<TerminalArchive> {
        if runtime.kind() != SurfaceKind::Pty {
            return None;
        }
        let public_id = runtime.terminal_public_id()?.clone();
        let identity = self.resource_terminal_host_identity(runtime)?;
        let screen = match crate::journal_checkpoint::terminal_replay_blob(runtime, &public_id) {
            Ok(blob) => Some(blob),
            Err(error) => {
                eprintln!("cmux-tui: terminal {public_id} archive has no screen: {error:#}");
                None
            }
        };
        let stopped = runtime.process_id().and_then(|pid| {
            crate::platform::foreground_job_name(pid).or_else(|| {
                // A command terminal's own child is the program.
                let registry =
                    self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
                let record = registry.terminal_relaunch_record(&identity.terminal_id).ok()??;
                (record.kind == RelaunchKind::Command).then_some(record.program).flatten()
            })
        });
        Some(TerminalArchive {
            terminal_id: public_id.as_str().to_string(),
            generation: identity.incarnation,
            screen,
            stopped,
        })
    }

    /// How Reopen Closed starts a closed terminal tab `tab` (its closed
    /// record) that no longer runs: in its recorded directory with its
    /// allowlisted environment, and, when the closed terminal is known, on
    /// a reserved terminal id whose launch is seeded with the terminal's
    /// archived screen and one marker line. The returned guard removes an
    /// unused seed when it drops, so a failed creation leaves none behind.
    pub(crate) fn reopen_terminal_spawn(
        &self,
        tab: &Value,
    ) -> (TerminalSpawnOptions, SeedGuard<'_>) {
        let (cwd, env) = crate::workspace_registry::relaunch_store::replay(tab);
        let mut spawn = TerminalSpawnOptions::new(cwd, env);
        let mut guard = SeedGuard { mux: self, terminal_id: None };
        #[cfg(unix)]
        if let Some(closed) = tab["terminal_id"].as_str()
            && let Ok(reserved) = TerminalId::random()
        {
            let reserved = reserved.to_hex();
            self.terminal_respawns.stash_seed(&reserved, self.archived_terminal_seed(closed));
            spawn.terminal_id = Some(reserved.clone());
            guard.terminal_id = Some(reserved);
        }
        (spawn, guard)
    }

    /// The seed of a reopened archived terminal: the closed terminal's last
    /// screen (its exit snapshot) and one dim line that names the program
    /// its close stopped.
    #[cfg(unix)]
    fn archived_terminal_seed(&self, closed_terminal: &str) -> Vec<u8> {
        let (screen, stopped) = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let screen = registry.terminal_exit_snapshot(closed_terminal).unwrap_or_else(|error| {
                eprintln!("cmux-tui: terminal {closed_terminal} archive is unreadable: {error:#}");
                None
            });
            let stopped = registry.terminal_archive_stop(closed_terminal).unwrap_or_else(|error| {
                eprintln!("cmux-tui: terminal {closed_terminal} stop is unreadable: {error:#}");
                None
            });
            (screen, stopped)
        };
        let marker = crate::terminal_respawn_text::reopened_marker(stopped.as_deref());
        terminal_respawn::launch::respawn_seed(screen.map(|screen| screen.replay_bytes), &marker)
    }
}

/// Removes a reserved terminal's seed that its launch did not take.
pub(crate) struct SeedGuard<'a> {
    mux: &'a Mux,
    terminal_id: Option<String>,
}

impl Drop for SeedGuard<'_> {
    fn drop(&mut self) {
        if let Some(terminal_id) = self.terminal_id.take() {
            let _ = self.mux.terminal_respawns.take_seed(&terminal_id);
        }
    }
}
