//! Archive on close (ARCHIVE-1, cx-gzh.4.1, plans/cmux-next/reopen-closed.md
//! section 3, S3).
//!
//! A close ends a terminal that still runs in one of two places: the reaper
//! ends a terminal whose last tab closed (Cmd-W, after the reap grace), and a
//! batch close with `end_terminals` (Close Workspace) ends it in the close
//! commit. Both capture with [`Mux::capture_terminal_archives`] before the
//! host is asked to stop and store only once the close committed. Only a
//! terminal that closed history can reopen is archived. Per terminal it keeps
//! (`workspace_registry::terminal_archive_store`, bounded and deleted with
//! its closed-history group):
//!
//! - the screen with its newest scrollback, as VT replay; a full-screen
//!   program (alternate screen) as the plain text of its visible rows, since
//!   the reopened shell must leave the alternate screen;
//! - the program the close stops: the PTY's foreground job when it is not the
//!   shell (one query of the terminal's own child, never a process scan), or
//!   the program of a command terminal. Only its basename is kept.
//!
//! The directory and environment are already in the relaunch record, which
//! the closed tab copied (`relaunch_store`: allowlisted keys only, never a
//! key that names a secret). Reopen Closed ([`Mux::reopen_terminal_spawn`])
//! starts a new shell there whose host shows the archived screen, then, only
//! when the close stopped a program, one dim line that names it.

use super::*;
use crate::workspace_registry::relaunch_store::RelaunchKind;
use crate::workspace_registry::terminal_archive_store::{
    ARCHIVE_BLOB_BUDGET_BYTES, ARCHIVE_MAX_SCREEN_BYTES, ArchiveRow,
};

/// The mutation origin of the commit that publishes groups whose archive
/// lost its screen to the byte budget.
const ARCHIVE_EVICTION_MUTATION_ORIGIN: &str = "cmux-tui-terminal-archive";

/// What one archived terminal keeps (see the module docs).
pub(crate) struct TerminalArchive {
    /// The public terminal id.
    terminal_id: String,
    /// The incarnation the close stops.
    generation: String,
    /// (cols, rows, VT bytes).
    screen: Option<(u16, u16, Vec<u8>)>,
    stopped: Option<String>,
}

impl Mux {
    /// Capture the archives of `runtimes`, the terminals a close is about
    /// to stop, keeping only terminals that closed history can reopen (a
    /// terminal of an ephemeral workspace, an unplaced API terminal or a
    /// close kept out of history is never archived). Unix only: only Unix
    /// reopens a terminal seeded with its archive. Store them with
    /// [`Self::store_terminal_archives`] once the close committed.
    #[track_caller]
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
        reopenable.iter().filter_map(|runtime| self.capture_terminal_archive(runtime)).collect()
    }

    /// Archive each terminal that `closed_views` left with no placement. The
    /// reaper archives such a terminal again when it ends it after the reap
    /// grace; a crash or power loss inside the grace would otherwise lose its
    /// screen, so a Reopen Closed after the restart had only its directory
    /// (cx-jc9vh).
    #[track_caller]
    pub(crate) fn archive_unplaced_terminals(&self, closed_views: &[Arc<Surface>]) {
        if !cfg!(unix) || closed_views.is_empty() {
            return;
        }
        let runtimes = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let placed: HashSet<SurfaceId> =
                state.surfaces.values().filter_map(|view| view.terminal_runtime_id()).collect();
            let mut seen = HashSet::new();
            closed_views
                .iter()
                .filter_map(|view| view.terminal_public_id().cloned())
                .filter(|public_id| seen.insert(public_id.clone()))
                .filter_map(|public_id| {
                    let runtime = state.terminal_catalog.get(&public_id)?;
                    let content = ContentPublicId::Terminal(public_id);
                    let viewed =
                        runtime.terminal_runtime_id().is_some_and(|id| placed.contains(&id));
                    (!viewed && state.placements_of_content(&content).is_empty())
                        .then(|| runtime.clone())
                })
                .collect::<Vec<_>>()
        };
        self.store_terminal_archives(self.capture_terminal_archives(&runtimes));
    }

    /// Store `archives` in one registry transaction. Best effort: a failure
    /// costs the reopened tab its screen, never the close.
    #[track_caller]
    pub(crate) fn store_terminal_archives(&self, archives: Vec<TerminalArchive>) {
        if archives.is_empty() {
            return;
        }
        let rows = archives
            .iter()
            .map(|archive| ArchiveRow {
                terminal_id: &archive.terminal_id,
                generation: &archive.generation,
                program: archive.stopped.as_deref(),
                cols: archive.screen.as_ref().map_or(1, |screen| screen.0),
                rows: archive.screen.as_ref().map_or(1, |screen| screen.1),
                screen: archive.screen.as_ref().map(|screen| screen.2.as_slice()),
            })
            .collect::<Vec<_>>();
        self.put_terminal_archive_rows(&rows, ARCHIVE_BLOB_BUDGET_BYTES);
    }

    /// Store `rows` within `blob_budget_bytes` of screens across all
    /// archives ([`ARCHIVE_BLOB_BUDGET_BYTES`] outside tests). Best effort,
    /// as [`Self::store_terminal_archives`]. The closed groups whose screen
    /// the budget cleared are published again in the next commit, so a
    /// client that follows the change stream shows `scrollback_not_kept`.
    #[track_caller]
    pub(crate) fn put_terminal_archive_rows(
        &self,
        rows: &[ArchiveRow<'_>],
        blob_budget_bytes: u64,
    ) {
        let now = crate::workspace_registry::session_journal::unix_epoch_ms().unwrap_or_default();
        let evicted = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            match registry.put_terminal_archives(rows, now, blob_budget_bytes) {
                Ok(evicted) => evicted,
                Err(error) => {
                    eprintln!(
                        "cmux-tui: could not store {} terminal archive(s): {error:#}",
                        rows.len()
                    );
                    return;
                }
            }
        };
        if evicted.is_empty() {
            return;
        }
        let fingerprint = serde_json::json!({ "closed": evicted });
        let published = self.commit_state(
            &WorkspaceMutation::daemon_local(ARCHIVE_EVICTION_MUTATION_ORIGIN),
            "closed.scrollback_evicted",
            &fingerprint,
            None,
            crate::state::commit::StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let changes =
                    crate::state::closed_history_query::closed_upserts(transaction, &evicted)?;
                Ok(crate::state::store::StateChanges::new(fingerprint.clone(), changes))
            },
        );
        if let Err(error) = published {
            eprintln!("cmux-tui: could not publish evicted terminal archives: {error:#}");
        }
    }

    /// The archive of one live PTY runtime.
    #[track_caller]
    fn capture_terminal_archive(&self, runtime: &Arc<Surface>) -> Option<TerminalArchive> {
        if runtime.kind() != SurfaceKind::Pty {
            return None;
        }
        let public_id = runtime.terminal_public_id()?.clone();
        let identity = self.resource_terminal_host_identity(runtime)?;
        // terminal.persistence.mode memory: the archive keeps no screen.
        let screen = if self.output_store.memory_only() {
            None
        } else {
            runtime.try_with_terminal(archive_screen).ok().flatten()
        };
        if screen.is_none() && !self.output_store.memory_only() {
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

    /// How Reopen Closed starts a closed terminal tab `tab` (its closed
    /// record) that no longer runs: in its recorded directory with its
    /// allowlisted environment, and, when the closed terminal has an
    /// archive, on a reserved terminal id whose launch is seeded with it.
    /// The returned guard removes an unused seed when it drops, so a failed
    /// creation leaves none behind.
    #[track_caller]
    pub(crate) fn reopen_terminal_spawn(
        &self,
        tab: &Value,
    ) -> (TerminalSpawnOptions, SeedGuard<'_>, Option<(u16, u16)>) {
        let (cwd, env) = crate::workspace_registry::relaunch_store::replay(tab);
        let mut spawn = TerminalSpawnOptions::new(cwd, env);
        let mut guard = SeedGuard { mux: self, terminal_id: None };
        let mut size = None;
        #[cfg(any(unix, windows))]
        if let Some(seed) =
            tab["terminal_id"].as_str().and_then(|id| self.archived_terminal_seed(id))
            && let Ok(reserved) = TerminalId::random()
        {
            let reserved = reserved.to_hex();
            self.terminal_respawns.stash_seed(&reserved, seed);
            spawn.terminal_id = Some(reserved.clone());
            guard.terminal_id = Some(reserved);
            size = tab["terminal_id"].as_str().and_then(|id| self.archived_terminal_size(id));
        }
        (spawn, guard, size)
    }

    /// The archived terminal's original viewport, used to seed the new PTY
    /// before the frontend resizes it to the current pane.
    #[cfg(any(unix, windows))]
    #[track_caller]
    fn archived_terminal_size(&self, closed_terminal: &str) -> Option<(u16, u16)> {
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        registry
            .terminal_archive(closed_terminal)
            .ok()
            .flatten()
            .map(|archive| (archive.cols, archive.rows))
    }

    /// The seed of a reopened archived terminal: its screen, and one dim
    /// line that names the program its close stopped (none when nothing
    /// ran). `None` without an archive.
    #[cfg(any(unix, windows))]
    #[track_caller]
    fn archived_terminal_seed(&self, closed_terminal: &str) -> Option<Vec<u8>> {
        let archive = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            registry.terminal_archive(closed_terminal).unwrap_or_else(|error| {
                eprintln!("cmux-tui: terminal {closed_terminal} archive is unreadable: {error:#}");
                None
            })?
        };
        let marker = archive.program.as_deref().map(crate::terminal_respawn_text::stopped_marker);
        Some(terminal_respawn::launch::respawn_seed(archive.screen, marker.as_deref()))
    }
}

/// The screen of `terminal` for an archive: VT replay of at most
/// [`ARCHIVE_MAX_SCREEN_BYTES`] (the oldest scrollback goes first), or the
/// plain text of the visible rows on the alternate screen or when even the
/// visible screen does not fit.
fn archive_screen(terminal: &mut ghostty_vt::Terminal) -> Option<(u16, u16, Vec<u8>)> {
    let (cols, rows) = (terminal.cols(), terminal.rows());
    let replay = (terminal.active_screen() == ghostty_vt::Screen::Primary)
        .then(|| terminal.vt_replay_bounded(ARCHIVE_MAX_SCREEN_BYTES).ok())
        .flatten()
        .map(|replay| replay.self_contained_bytes().into_owned())
        .filter(|bytes| bytes.len() <= ARCHIVE_MAX_SCREEN_BYTES);
    let bytes = match replay {
        Some(bytes) => bytes,
        None => plain_screen_bytes(&terminal.active_text().ok()?),
    };
    (!bytes.is_empty() && bytes.len() <= ARCHIVE_MAX_SCREEN_BYTES).then_some((cols, rows, bytes))
}

/// VT bytes that draw `text` (rows separated by newlines) from the top left
/// of a cleared screen; control characters in the text are dropped.
fn plain_screen_bytes(text: &str) -> Vec<u8> {
    let mut bytes = b"\x1b[0m\x1b[H\x1b[2J".to_vec();
    for (index, line) in text.lines().enumerate() {
        if index > 0 {
            bytes.extend_from_slice(b"\r\n");
        }
        bytes.extend(line.chars().filter(|c| !c.is_control()).collect::<String>().bytes());
    }
    bytes
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_screen_bytes_draw_rows_without_control_characters() {
        assert_eq!(plain_screen_bytes("a\u{1b}b\nc"), b"\x1b[0m\x1b[H\x1b[2Jab\r\nc".to_vec());
    }
}
