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

/// Each terminal's own result, then the last revision committed, if any.
pub(super) type AdoptingCommit = (Vec<Result<(), String>>, Option<u64>);

/// Mark every terminal in `terminals` adopting with its host's incarnation
/// in one registry transaction: one commit each cost a daemon start 2.6 ms
/// per surviving host before its first answer
/// (plans/cmux-next/service-start-PERF.md 5b). Each result is that
/// terminal's own; a failed one keeps its row. Returns the last revision
/// committed, if any.
pub(super) fn commit_terminals_adopting(
    registry: &mut WorkspaceRegistry,
    terminals: &[(RegistryTerminal, String)],
) -> anyhow::Result<AdoptingCommit> {
    let generation = registry.generation().to_string();
    let mut intents = Vec::with_capacity(terminals.len());
    for (terminal, incarnation) in terminals {
        // One mutation each: a shared mutation id would replay the first.
        let mutation = WorkspaceMutation::daemon_local("cmux-tui-runtime");
        let mut terminal = terminal.clone();
        terminal.lifecycle = TerminalLifecycle::Adopting;
        terminal.incarnation = Some(incarnation.clone());
        terminal.exit = None;
        intents.push(registry.prepare_terminal_commit(
            &mutation,
            &serde_json::json!({
                "op": "adopt-terminal",
                "terminal_id": terminal.terminal_id,
                "incarnation": terminal.incarnation,
                "lifecycle": terminal.lifecycle,
            }),
            Some(&generation),
            None,
            "terminal-adopting",
            &terminal,
            &serde_json::json!({
                "terminal_id": terminal.terminal_id,
                "workspace_key": terminal.workspace_key,
                "incarnation": terminal.incarnation,
                "state": terminal.lifecycle,
            }),
        )?);
    }
    let mut last_revision = None;
    let results = registry
        .commit_terminals_together(intents)?
        .into_iter()
        .map(|commit| {
            commit.map(|commit| {
                last_revision = Some(commit.revision);
            })
        })
        .collect();
    Ok((results, last_revision))
}
