//! Archive on close (ARCHIVE-1, cx-gzh.4.1, plans/cmux-next/reopen-closed.md
//! section 3, S3).
//!
//! A close ends a terminal that still runs in one of two places: the reaper
//! ends a terminal whose last tab closed (Cmd-W, after the reap grace), and a
//! batch close with `end_terminals` (Close Workspace) ends it in the close
//! commit. Both capture with [`Mux::capture_terminal_archives`] before the
//! host is asked to stop and store only once the close committed. Only a
//! terminal that closed history can reopen is archived. It keeps, per
//! terminal:
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

/// Captures that saw output arrive mid-capture are retried this many times.
const CAPTURE_ATTEMPTS: usize = 3;

/// What one archived terminal keeps (see the module docs).
pub(crate) struct TerminalArchive {
    /// The public terminal id.
    pub(crate) terminal_id: String,
    /// The incarnation the close stops.
    pub(crate) generation: String,
    /// The screen and the journaled output offset it covers, read with it.
    pub(crate) screen: Option<(JournalContentBlob, u64)>,
    pub(crate) stopped: Option<String>,
}

impl Mux {
    /// Capture the archives of `runtimes`, the terminals a close is about
    /// to stop, keeping only terminals that closed history can reopen (a
    /// terminal of an ephemeral workspace, an unplaced API terminal or a
    /// close kept out of history is never archived). Unix only: only Unix
    /// reopens a terminal seeded with its archive. Store them with
    /// [`Self::store_terminal_archives`] once the close committed.
    pub(crate) fn capture_terminal_archives(
        &self,
        runtimes: &[Arc<Surface>],
    ) -> Vec<TerminalArchive> {
        if !cfg!(unix) || runtimes.is_empty() {
            return Vec::new();
        }
        let reopenable = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            runtimes
                .iter()
                .filter(|runtime| {
                    runtime.terminal_public_id().is_some_and(|public_id| {
                        registry
                            .closed_history_mentions_terminal(public_id.as_str())
                            .unwrap_or(false)
                    })
                })
                .cloned()
                .collect::<Vec<_>>()
        };
        if reopenable.is_empty() {
            return Vec::new();
        }
        reopenable.iter().filter_map(|runtime| self.capture_terminal_archive(runtime)).collect()
    }

    /// Store `archives` in one registry transaction. Best effort: a failure
    /// costs the reopened tab its screen, never the close.
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

    /// The archive of one live PTY runtime.
    fn capture_terminal_archive(&self, runtime: &Arc<Surface>) -> Option<TerminalArchive> {
        if runtime.kind() != SurfaceKind::Pty {
            return None;
        }
        let public_id = runtime.terminal_public_id()?.clone();
        let identity = self.resource_terminal_host_identity(runtime)?;
        let screen = (0..CAPTURE_ATTEMPTS)
            .find_map(|_| self.capture_archive_screen(runtime, &public_id, &identity.incarnation));
        if screen.is_none() {
            eprintln!("cmux-tui: terminal {public_id} archive has no screen");
        }
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

    /// One capture of the screen and the output offset it covers: settle
    /// the journal, read the offset, capture, and accept only when no output
    /// arrived in between (the per-terminal ingress epoch did not move).
    fn capture_archive_screen(
        &self,
        runtime: &Arc<Surface>,
        public_id: &TerminalPublicId,
        generation: &str,
    ) -> Option<(JournalContentBlob, u64)> {
        self.flush_terminal_journal().ok()?;
        let epoch = runtime.terminal_journal_capture_epoch()?;
        let covered = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            registry.terminal_journal_offset(public_id.as_str(), generation).ok()?
        };
        let blob =
            crate::journal_checkpoint::terminal_replay_blob_with(runtime, public_id, true).ok()?;
        (runtime.terminal_journal_capture_epoch() == Some(epoch) && epoch & 1 == 0)
            .then_some((blob, covered))
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
            // A stop names a program of the archived screen's incarnation
            // only; a screen a later process end stored has no stop.
            let stopped = stopped
                .filter(|(generation, _)| {
                    screen.as_ref().is_none_or(|screen| &screen.generation == generation)
                })
                .map(|(_, program)| program);
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
