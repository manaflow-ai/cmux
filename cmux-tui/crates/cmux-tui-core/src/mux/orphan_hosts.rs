//! A starting owner never ends a live terminal host it cannot place
//! (cx-0tgl LC). Ending one would end its shell, and with it whatever the
//! user ran there.
//!
//! A live host whose registry row is gone (the registry was lost or reset)
//! is recovered: the owner creates one workspace for every such host of
//! this start and imports each as a terminal there, placed on adoption like
//! a Cloud snapshot's template terminal. A host proven dead, or one whose
//! terminal the user closed (tombstoned) or that already exited, is cleaned
//! up as before. Not covered: a live host whose incarnation the registry no
//! longer names (a crash-window case); the registry forbids a live
//! incarnation change, so it still ends as `incarnation_mismatch`.

use super::*;

/// Launch spec of a live host recovered into a new workspace because its
/// registry row was gone.
fn recovered_terminal_launch_spec() -> Value {
    serde_json::json!({"recovered_terminal": true})
}

/// A terminal whose first adoption gives it a new placement: a Cloud
/// snapshot's template terminal or a recovered one.
pub(super) fn placed_on_adoption(terminal: &RegistryTerminal) -> bool {
    is_template_terminal(terminal) || terminal.launch_spec == recovered_terminal_launch_spec()
}

/// The host may still run its shell (live, or not provably dead).
#[cfg(unix)]
pub(super) fn host_may_live(
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> bool {
    terminal_host_record_liveness(record_path, record) != TerminalHostLiveness::Dead
}

impl Mux {
    /// Import the live host `record`, which no registry row names, as a
    /// terminal of the recovery workspace (`workspace`, created on first
    /// use). The ordinary adoption handshake follows.
    #[cfg(unix)]
    pub(super) fn recover_orphan_terminal(
        &self,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
        workspace: &mut Option<String>,
    ) -> anyhow::Result<RegistryTerminal> {
        let key = match workspace {
            Some(key) => key.clone(),
            None => {
                let name = crate::terminal_respawn_text::text().recovered_workspace.to_string();
                let key = self.create_empty_workspace(Some(name), None, None)?.key;
                workspace.insert(key).clone()
            }
        };
        let recovered = RegistryTerminal {
            terminal_id: record.terminal_id.clone(),
            workspace_key: key,
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: recovered_terminal_launch_spec(),
            exit: None,
            on_exit: TerminalOnExit::Close,
        };
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let revision = commit_terminal_transition(
            &mut registry,
            "terminal-recovered",
            "recover-orphan-terminal",
            &recovered,
        )?;
        self.emit_terminal_registry_changed(&registry, revision);
        eprintln!(
            "cmux-tui: terminal {} had a live host but no registry row; recovered it into \
             workspace {}",
            recovered.terminal_id, recovered.workspace_key
        );
        Ok(recovered)
    }
}
