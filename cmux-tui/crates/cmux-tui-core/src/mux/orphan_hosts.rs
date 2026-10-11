//! A starting owner never ends a live terminal host it cannot place
//! (cx-0tgl LC). Ending one would end its shell, and with it whatever the
//! user ran there.
//!
//! A live, placed host whose registry row is gone (the registry was lost or
//! reset) is recovered: the owner creates one workspace for every such host
//! of this start and imports each as a terminal there, placed on adoption
//! like a Cloud snapshot's template terminal ([`recoverable`] says which). A host proven dead, or one whose
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

/// A host without a registry row that the owner recovers instead of ending:
/// it is proven live, it was placed (its record names a workspace; a
/// prelaunched host that was never activated has none and runs no shell),
/// it left no exit sidecar, and this is not a Cloud template start (whose
/// fresh registry claims its warm host first and ends the others).
#[cfg(unix)]
pub(super) fn recoverable(
    options: &SurfaceOptions,
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> bool {
    !options.adopt_template_terminal
        && !record.workspace_key.is_empty()
        && !record_path.with_extension("exit").exists()
        && terminal_host_record_liveness(record_path, record) == TerminalHostLiveness::Live
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
        drop(registry);
        eprintln!(
            "cmux-tui: terminal {} had a live host but no registry row; recovered it into \
             workspace {}",
            recovered.terminal_id, recovered.workspace_key
        );
        Ok(recovered)
    }
}
