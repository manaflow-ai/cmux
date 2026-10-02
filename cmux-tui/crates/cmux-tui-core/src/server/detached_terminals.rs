//! Detached terminals (`detached-terminals-v1`) and kept terminals with no
//! tab here: `create-terminal {detached:true}`, the public id in
//! `set-terminal-keep`'s result, and their view sizing.

use super::*;

/// Detached terminals: `create-terminal {detached:true}` creates a kept
/// terminal with no workspace, pane, screen, or tab (cmux-next "Open Terminal
/// on Machine Here" shows it as a remote-terminal tab in another session).
pub const DETACHED_TERMINALS_CAPABILITY: &str = "detached-terminals-v1";

/// `create-terminal {detached:true}` (`detached-terminals-v1`): a kept
/// terminal with no workspace, pane, screen or tab. The host spawns first;
/// the resource projection then commits in the same receipted mutation and
/// gives the terminal its durable public id before the host is activated. If
/// that commit fails the terminal is ended, because nothing else would end a
/// kept terminal with no tab. A daemon that dies between the two leaves a
/// host that adoption restores as a kept, tabless terminal.
#[allow(clippy::too_many_arguments)]
pub(super) fn create(
    mux: &Arc<Mux>,
    has_destination: bool,
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    name: Option<String>,
    size: Option<(u16, u16)>,
    terminal_id: Option<&str>,
    env: Vec<(String, String)>,
    mutation: &MutationRequest,
) -> anyhow::Result<Value> {
    anyhow::ensure!(!has_destination, "a detached terminal takes no workspace or key");
    let (registry_id, generation) = mux.registry_identity();
    let workspace_mutation = workspace_mutation(mutation)?;
    let result = mux.create_detached_terminal_with_mutation(
        argv,
        cwd,
        name,
        size,
        terminal_id,
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
        env,
    )?;
    let projection = json!({"terminal_id":result.terminal_id, "detached":true});
    if let Err(error) = mux.commit_full_resource_projection_with_mutation(
        &workspace_mutation,
        "raw.terminal.create_detached",
        &projection,
        projection.clone(),
    ) {
        if let Err(close_error) = mux.end_unpublished_detached_terminal(
            &result.terminal_id,
            result.terminal_incarnation.as_deref(),
        ) {
            eprintln!(
                "cmux-tui: could not end detached terminal {} after its creation failed: \
                 {close_error:#}",
                result.terminal_id
            );
        }
        return Err(error);
    }
    mux.activate_created_terminal_surface(result.created_surface)?;
    mux.reap_created_terminal_surface(result.created_surface);
    let terminal = mux
        .resolve_terminal(&result.terminal_id)?
        .context("created terminal has no durable terminal row")?;
    let terminal_resource_id = mux.terminal_public_id_for_host(&result.terminal_id)?;
    let already_exited = terminal.terminal.lifecycle == TerminalLifecycle::Exited;
    Ok(json!({
        "surface": Value::Null,
        "terminal_id": terminal.terminal.terminal_id,
        "terminal_incarnation": terminal.terminal.incarnation,
        "terminal_resource_id": terminal_resource_id,
        "pane": Value::Null,
        "screen": Value::Null,
        "workspace": Value::Null,
        "key": crate::workspace_registry::DETACHED_TERMINAL_WORKSPACE_KEY,
        "lifecycle": terminal.terminal.lifecycle,
        "exit": terminal.terminal.exit,
        "already_exited": already_exited,
        "terminal_revision": terminal.terminal_revision,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

/// `set-terminal-keep`'s result, with the public id an attach by identity
/// needs (a remote-terminal reference knows only the host id).
pub(super) fn keep_result(mux: &Mux, terminal_id: &str, keep: bool) -> anyhow::Result<Value> {
    let terminal_resource_id = mux.terminal_public_id_for_host(terminal_id)?;
    Ok(json!({
        "terminal_id": terminal_id,
        "terminal_resource_id": terminal_resource_id,
        "keep": keep,
    }))
}

/// Whether a view's sizing still has a live target: a tab placement, or a
/// kept terminal with no tab (`set-terminal-keep`). A kept terminal may have
/// its only view in another session's layout (a remote-terminal tab), so an
/// attached geometry owner keeps sizing it; any other unplaced surface is a
/// view whose tab closed.
pub(super) fn accepts_view_sizing(mux: &Mux, id: SurfaceId) -> bool {
    if surface_has_view_placement(mux, id) {
        return true;
    }
    let Some(surface) = mux.surface(id).filter(|surface| !surface.is_dead()) else {
        return false;
    };
    // A kept terminal with no tab here (its view may be a remote-terminal tab
    // in another session) takes its viewer's geometry. A terminal that still
    // has a tab here does not, so a lease on a closed tab of it stays
    // superseded by the placements that remain.
    let unplaced = surface.terminal_public_id().is_none_or(|terminal_id| {
        mux.with_state(|state| {
            state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).is_empty()
        })
    });
    unplaced
        && mux
            .resource_terminal_host_identity(&surface)
            .is_some_and(|identity| mux.terminal_keep(&identity.terminal_id).unwrap_or(false))
}
