//! The session's side of a freed terminal's shell state (`crate::shell_state`):
//! where its files live, the save a park asks for, and the question the
//! freeing policy asks before it parks a shell ("is its state saved?").

use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use super::*;
use crate::shell_state::{SAVE_TIMEOUT, SaveOutcome, ShellStateDir};

/// A save this recent is not asked again: the policy's check and the park
/// that follows it share one save.
const FRESH: Duration = Duration::from_secs(5);

impl Mux {
    /// The session's shell-state directory, beside its output store (the
    /// registry directory). `None` without one (tests, a memory-only
    /// session).
    pub(crate) fn shell_state_dir(&self) -> Option<ShellStateDir> {
        self.output_store.directory().and_then(Path::parent).map(crate::shell_state::directory_in)
    }

    /// The prefix terminal `terminal`'s shell gets in
    /// [`crate::shell_state::SHELL_STATE_ENV`], given its launch
    /// environment `env`; `None` gives it none (it saves nothing). An
    /// incognito terminal's shell (its launch environment carries
    /// [`crate::shell_integration::INCOGNITO_ENV`], as every incognito
    /// launch and respawn sets it) gets none: its cwd and exported variables
    /// never reach the disk (design/spaces.md "Incognito": nothing kept).
    /// Reads no registry, so a terminal being built takes no lock here.
    pub(crate) fn shell_state_prefix(
        &self,
        terminal: &TerminalPublicId,
        env: &[(String, String)],
    ) -> Option<std::path::PathBuf> {
        let incognito =
            env.iter().rev().find(|(key, _)| key == crate::shell_integration::INCOGNITO_ENV);
        if incognito.is_some_and(|(_, value)| value == "1") {
            return None;
        }
        self.shell_state_dir()?.prefix(terminal)
    }

    /// A respawn of terminal `terminal`: a parked tab's restart (`parked`)
    /// hands its last shell's saved state to the new shell, which reads it
    /// after the startup files and deletes it; any other respawn starts a
    /// fresh shell, with no older state left to read. An incognito
    /// terminal's files are only removed, never handed on.
    pub(crate) fn hand_shell_state_to_respawn(&self, terminal: &TerminalPublicId, parked: bool) {
        let Some(dir) = self.shell_state_dir() else { return };
        if parked && !self.output_store.is_private(self, terminal) {
            dir.take_for_restore(terminal);
        } else {
            dir.discard(terminal);
        }
    }

    /// Asks the shells of `terminals` to save their state, all at once, and
    /// waits at most [`SAVE_TIMEOUT`] for every answer. A terminal with no
    /// live shell at its prompt (a program it started in front, no process)
    /// is [`SaveOutcome::NoAck`]. A state saved in the last [`FRESH`] counts
    /// as saved without asking again. Takes and releases the state lock
    /// before it waits; holds no lock while it waits.
    pub(crate) fn save_shell_states(
        &self,
        terminals: &[TerminalPublicId],
    ) -> HashMap<TerminalPublicId, SaveOutcome> {
        let mut outcomes: HashMap<TerminalPublicId, SaveOutcome> =
            terminals.iter().map(|id| (id.clone(), SaveOutcome::NoAck)).collect();
        let Some(dir) = self.shell_state_dir() else { return outcomes };
        // An incognito shell is never asked to save (it has no prefix to
        // save under), and any file of its terminal is removed.
        let (private, terminals): (Vec<&TerminalPublicId>, Vec<&TerminalPublicId>) =
            terminals.iter().partition(|id| self.output_store.is_private(self, id));
        for id in private {
            dir.discard(id);
        }
        let pids: Vec<(TerminalPublicId, u32)> = self.with_state(|state| {
            terminals
                .iter()
                .filter_map(|&id| {
                    let surface = state.terminal_catalog.get(id)?;
                    (!surface.is_dead()).then_some(())?;
                    Some((id.clone(), surface.process_id()?))
                })
                .collect()
        });
        let mut targets = Vec::new();
        for (id, pid) in pids {
            if dir.saved_within(&id, FRESH) {
                outcomes.insert(id, SaveOutcome::Saved);
            } else if let Some(shell) = crate::shell_state::shell_pid(pid) {
                targets.push((id, shell));
            }
        }
        if !targets.is_empty() {
            outcomes.extend(crate::shell_state::save_all(
                &dir,
                &targets,
                SAVE_TIMEOUT,
                &crate::shell_state::signal_shell,
            ));
        }
        outcomes
    }

    /// Whether the shell of the terminal the tab at `surface` shows has its
    /// state saved now, fresh (asked now, or in the last [`FRESH`]): the
    /// freeing policy parks a shell only when this holds, since a shell
    /// whose state is unknown or unsaveable (jobs, an fd it opened, no
    /// integration, no answer in [`SAVE_TIMEOUT`]) would come back changed.
    /// Blocks the caller up to [`SAVE_TIMEOUT`].
    #[allow(dead_code)] // The freeing policy's gate; its caller has not landed yet.
    pub(crate) fn shell_state_saved(&self, surface: SurfaceId) -> bool {
        let terminal =
            self.with_state(|state| match state.resource_indexes.content_ids.get(&surface) {
                Some(ContentPublicId::Terminal(id)) => Some(id.clone()),
                _ => None,
            });
        terminal.is_some_and(|terminal| {
            self.save_shell_states(std::slice::from_ref(&terminal)).get(&terminal)
                == Some(&SaveOutcome::Saved)
        })
    }
}
