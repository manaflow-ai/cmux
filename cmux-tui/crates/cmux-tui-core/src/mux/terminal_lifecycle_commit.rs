//! The registry commit of a terminal lifecycle change (moved out of mux.rs).

use super::*;

/// Advance only renderer lifecycle fields from the latest durable row. This
/// deliberately re-reads under the registry writer mutex and uses the
/// terminal revision as a CAS: a GUI move committed while a host launch or
/// adoption was in flight can never be overwritten by a stale row clone.
pub(super) fn commit_terminal_lifecycle(
    registry: &mut WorkspaceRegistry,
    event_kind: &str,
    operation: &str,
    terminal_id: &str,
    lifecycle: TerminalLifecycle,
    incarnation: Option<&str>,
    exit: Option<Value>,
) -> anyhow::Result<(RegistryTerminal, u64)> {
    // Only the revision fence is needed: reading every terminal row here made
    // each launch O(terminals) under the registry lock.
    let (generation, revision) = (registry.generation().to_string(), registry.terminal_revision()?);
    let mut terminal = registry
        .terminal_record(terminal_id)?
        .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
    terminal.lifecycle = lifecycle;
    if let Some(incarnation) = incarnation {
        terminal.incarnation = Some(incarnation.to_string());
    }
    terminal.exit = exit;
    let mutation = WorkspaceMutation::daemon_local("cmux-tui-runtime");
    let commit = registry.commit_terminal(
        &mutation,
        &serde_json::json!({
            "op": operation,
            "terminal_id": terminal.terminal_id,
            "incarnation": terminal.incarnation,
            "lifecycle": terminal.lifecycle,
        }),
        Some(&generation),
        Some(revision),
        event_kind,
        &terminal,
        &serde_json::json!({
            "terminal_id": terminal.terminal_id,
            "workspace_key": terminal.workspace_key,
            "incarnation": terminal.incarnation,
            "state": terminal.lifecycle,
        }),
    )?;
    Ok((terminal, commit.revision))
}
