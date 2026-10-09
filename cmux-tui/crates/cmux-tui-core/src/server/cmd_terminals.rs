//! Terminal lifecycle command handlers: create, list, resolve, close and
//! move terminals, keep and idle-close policy, terminal events, history,
//! read ranges, resources, process info, the command-history switch and
//! renderer grants. Each function is one `Command` arm of
//! `handle_command_with_cancellation`.

use super::MutationRequest;
use super::frontend_shell;
use super::get_surface;
use super::keep_created_terminal;
use super::paired_surface_size;
use super::renderer_grant;
use super::require_pty;
use super::shell_argv;
use super::terminal_history;
use super::terminal_resources;
use super::workspace_mutation;
use crate::Actor;
use crate::Mux;
use crate::SurfaceId;
use crate::WorkspaceId;
use crate::platform;
use crate::workspace_registry::TerminalLifecycle;
use serde_json::Value;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::Arc;

pub(super) fn set_terminal_command_history(
    mux: &Arc<Mux>,
    client: u64,
    enabled: bool,
) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("terminal command history requires a trusted local connection");
    }
    mux.set_terminal_command_history(enabled);
    Ok(json!({ "enabled": enabled }))
}

pub(super) fn list_terminals(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    let snapshot = mux.terminal_registry_snapshot()?;
    let terminals = snapshot
        .terminals
        .into_iter()
        .map(|terminal| {
            json!({
                "terminal_id":terminal.terminal_id,
                "workspace_key":terminal.workspace_key,
                "terminal_incarnation":terminal.incarnation,
                "lifecycle":terminal.lifecycle,
                "launch_spec":terminal.launch_spec,
                "exit":terminal.exit,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "registry_id":snapshot.registry_id,
        "generation":snapshot.generation,
        "terminal_revision":snapshot.revision,
        "terminals":terminals,
    }))
}

pub(super) fn terminal_events(mux: &Arc<Mux>, after_revision: u64) -> anyhow::Result<Value> {
    let (snapshot, events) = mux.terminal_registry_events_page(after_revision)?;
    let events = events
        .into_iter()
        .map(|event| {
            json!({
                "terminal_revision":event.revision,
                "kind":event.kind,
                "terminal_id":event.terminal_id,
                "workspace_key":event.workspace_key,
                "origin":event.origin,
                "mutation_id":event.mutation_id,
                "result":event.result,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "registry_id":snapshot.registry_id,
        "generation":snapshot.generation,
        "terminal_revision":snapshot.revision,
        "events":events,
    }))
}

pub(super) fn mint_terminal_renderer(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    ttl_ms: u64,
) -> anyhow::Result<Value> {
    renderer_grant::mint_by_surface(mux, client, surface, ttl_ms)
}

pub(super) fn mint_terminal_renderer_by_terminal(
    mux: &Arc<Mux>,
    client: u64,
    terminal: String,
    ttl_ms: u64,
) -> anyhow::Result<Value> {
    renderer_grant::mint_by_terminal(mux, client, terminal, ttl_ms)
}

pub(super) fn resolve_terminal(mux: &Arc<Mux>, terminal_id: String) -> anyhow::Result<Value> {
    let Some(resolution) = mux.resolve_terminal(&terminal_id)? else {
        anyhow::bail!("terminal_not_found");
    };
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "surface": resolution.surface,
        "terminal_id": resolution.terminal.terminal_id,
        "terminal_incarnation": resolution.terminal.incarnation,
        "workspace_key": resolution.terminal.workspace_key,
        "lifecycle": resolution.terminal.lifecycle,
        "launch_spec": resolution.terminal.launch_spec,
        "exit": resolution.terminal.exit,
        "terminal_revision": resolution.terminal_revision,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

pub(super) fn close_terminal(
    mux: &Arc<Mux>,
    client: u64,
    terminal_id: String,
    terminal_incarnation: Option<String>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = mux.close_terminal_with_mutation(
        &terminal_id,
        terminal_incarnation.as_deref(),
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "surface": result.surface,
        "terminal_id": result.terminal_id,
        "terminal_incarnation": result.terminal_incarnation,
        "already_closed": result.already_closed,
        "closed": true,
        "terminal_revision": result.terminal_revision,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

pub(super) fn set_terminal_idle_policy(
    mux: &Arc<Mux>,
    surface: Option<SurfaceId>,
    terminal_id: Option<String>,
    idle_close_seconds: Option<u64>,
) -> anyhow::Result<Value> {
    let terminal_id = match (surface, terminal_id) {
        (Some(surface), None) => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let identity = mux.resource_terminal_host_identity(&surface);
            identity.ok_or_else(|| anyhow::anyhow!("terminal_not_hosted"))?.terminal_id
        }
        (None, Some(terminal_id)) => {
            let resolution = mux.resolve_terminal(&terminal_id)?;
            let resolution = resolution.ok_or_else(|| anyhow::anyhow!("terminal_not_found"))?;
            resolution.terminal.terminal_id
        }
        _ => anyhow::bail!("bad request: exactly one of surface or terminal_id"),
    };
    mux.set_terminal_idle_policy(&terminal_id, idle_close_seconds)?;
    Ok(json!({
        "terminal_id": terminal_id,
        "idle_close_seconds": idle_close_seconds,
    }))
}

pub(super) fn set_terminal_keep(
    mux: &Arc<Mux>,
    surface: Option<SurfaceId>,
    terminal_id: Option<String>,
    keep: bool,
) -> anyhow::Result<Value> {
    let terminal_id = match (surface, terminal_id) {
        (Some(surface), None) => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let identity = mux.resource_terminal_host_identity(&surface);
            identity.ok_or_else(|| anyhow::anyhow!("terminal_not_hosted"))?.terminal_id
        }
        (None, Some(terminal_id)) => {
            let resolution = mux.resolve_terminal(&terminal_id)?;
            let resolution = resolution.ok_or_else(|| anyhow::anyhow!("terminal_not_found"))?;
            resolution.terminal.terminal_id
        }
        _ => anyhow::bail!("bad request: exactly one of surface or terminal_id"),
    };
    mux.set_terminal_keep(&terminal_id, keep)?;
    Ok(json!({ "terminal_id": terminal_id, "keep": keep }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn create_terminal(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    argv: Option<Vec<String>>,
    shell_args: Option<Vec<String>>,
    command: Option<String>,
    cwd: Option<String>,
    name: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
    terminal_id: Option<String>,
    env: Option<BTreeMap<String, String>>,
    keep: bool,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let env = env.as_ref().map(crate::mux::validate_terminal_env).transpose()?.unwrap_or_default();
    if argv.is_some() && command.is_some() {
        anyhow::bail!("argv and command are mutually exclusive");
    }
    if shell_args.is_some() && (argv.is_some() || command.is_some()) {
        anyhow::bail!("shell_args cannot be combined with argv or command");
    }
    let argv = match (argv, command) {
        (Some(argv), None) if !argv.is_empty() => Some(argv),
        (None, Some(command)) if !command.is_empty() => {
            Some(vec![platform::default_shell(), "-lc".to_string(), command])
        }
        (None, None) => shell_argv(&env, shell_args, frontend_shell(mux, client)),
        _ => anyhow::bail!("argv or command must be non-empty when provided"),
    };
    let size = paired_surface_size("create-terminal", cols, rows)?;
    let resolved = resolve_workspace(mux, workspace, key.as_deref());
    let (registry_id, generation) = mux.registry_identity();
    // A per-terminal environment rides the receipted path, which is
    // the only one that carries a spawn reservation.
    if terminal_id.is_some() || mutation.mutation_id.is_some() || !env.is_empty() {
        let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
        // A keyed retry whose workspace has closed since replays by key.
        let (workspace, key) = match (resolved, key) {
            (Ok((workspace, key)), _) => (Some(workspace), key),
            (Err(_), Some(key)) => (None, key),
            (Err(error), None) => return Err(error),
        };
        let result = mux.create_raw_terminal_in_workspace_with_mutation(
            workspace,
            &key,
            argv,
            cwd,
            name,
            size,
            terminal_id.as_deref(),
            mutation.expected_generation.as_deref(),
            mutation.expected_revision,
            &workspace_mutation,
            env,
        )?;
        let projection_fingerprint = json!({
            "terminal_id":result.terminal_id,
            "workspace_key":key,
        });
        mux.commit_full_resource_projection_with_mutation(
            &workspace_mutation,
            "raw.terminal.create",
            &projection_fingerprint,
            json!({
                "terminal_id":result.terminal_id,
                "workspace_key":key,
            }),
        )?;
        mux.activate_created_terminal_surface(result.created_surface)?;
        mux.reap_created_terminal_surface(result.created_surface);
        let created = mux.created_terminal_run_result(&result.terminal_id)?;
        if keep {
            keep_created_terminal(mux, Some(created.terminal.terminal_id.as_str()))?;
        }
        let placement = created.placement;
        let already_exited = created.terminal.lifecycle == TerminalLifecycle::Exited;
        Ok(json!({
            "surface": placement.as_ref().map(|placement| placement.surface),
            "terminal_id": created.terminal.terminal_id,
            "terminal_incarnation": created.terminal.incarnation,
            "pane": placement.as_ref().map(|placement| placement.pane),
            "screen": placement.as_ref().map(|placement| placement.screen),
            "workspace": placement.as_ref().map(|placement| placement.workspace),
            "key": key,
            "lifecycle": created.terminal.lifecycle,
            "exit": created.terminal.exit,
            "already_exited": already_exited,
            "terminal_revision": created.terminal_revision,
            "replayed": result.replayed,
            "registry_id": registry_id,
            "generation": generation,
        }))
    } else {
        let (workspace, key) = resolved?;
        let created =
            mux.create_terminal_result_in_workspace_as(&actor, workspace, argv, cwd, name, size)?;
        if keep {
            keep_created_terminal(mux, Some(created.terminal.terminal_id.as_str()))?;
        }
        let placement = created.placement;
        let already_exited = created.terminal.lifecycle == TerminalLifecycle::Exited;
        Ok(json!({
            "surface": placement.as_ref().map(|placement| placement.surface),
            "terminal_id": created.terminal.terminal_id,
            "terminal_incarnation": created.terminal.incarnation,
            "pane": placement.as_ref().map(|placement| placement.pane),
            "screen": placement.as_ref().map(|placement| placement.screen),
            "workspace": placement.as_ref().map(|placement| placement.workspace),
            "key": key,
            "lifecycle": created.terminal.lifecycle,
            "exit": created.terminal.exit,
            "already_exited": already_exited,
            "terminal_revision": created.terminal_revision,
            "replayed": false,
            "registry_id": registry_id,
            "generation": generation,
        }))
    }
}

pub(super) fn process_info(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    Ok(json!({
        "pid": surface.process_id(),
        "command": surface.spawn_command(),
        "cwd": surface.local_cwd(),
        "foreground_cwd": surface.process_id().and_then(platform::foreground_cwd),
        "foreground_executable": surface
            .process_id()
            .and_then(platform::foreground_process_name),
    }))
}

pub(super) fn terminal_resources(
    mux: &Arc<Mux>,
    surfaces: Option<Vec<SurfaceId>>,
) -> anyhow::Result<Value> {
    Ok(terminal_resources::terminal_resources(mux, surfaces))
}

pub(super) fn move_terminal(
    mux: &Arc<Mux>,
    client: u64,
    terminal_id: String,
    workspace_key: String,
    terminal_incarnation: Option<String>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = mux.move_terminal_with_mutation(
        &terminal_id,
        &workspace_key,
        terminal_incarnation.as_deref(),
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "surface":result.placement.as_ref().map(|placement| placement.surface),
        "pane":result.placement.as_ref().map(|placement| placement.pane),
        "screen":result.placement.as_ref().map(|placement| placement.screen),
        "workspace":result.placement.as_ref().map(|placement| placement.workspace),
        "terminal_id":result.terminal.terminal_id,
        "terminal_incarnation":result.terminal.incarnation,
        "workspace_key":result.terminal.workspace_key,
        "lifecycle":result.terminal.lifecycle,
        "changed":result.changed,
        "replayed":result.replayed,
        "terminal_revision":result.terminal_revision,
        "registry_id":registry_id,
        "generation":generation,
    }))
}

pub(super) fn terminal_history(
    mux: &Arc<Mux>,
    params: terminal_history::TerminalHistoryParams,
) -> anyhow::Result<Value> {
    terminal_history::history(mux, params)
}

pub(super) fn terminal_read_range(
    mux: &Arc<Mux>,
    params: terminal_history::TerminalReadRangeParams,
) -> anyhow::Result<Value> {
    terminal_history::read_range(mux, params)
}

fn resolve_workspace(
    mux: &Mux,
    id: Option<WorkspaceId>,
    key: Option<&str>,
) -> anyhow::Result<(WorkspaceId, String)> {
    mux.with_state(|state| {
        let by_id = id.and_then(|id| state.workspace_by_id(id));
        let by_key = key.and_then(|key| state.workspace_by_key(key));
        let workspace = match (id, key, by_id, by_key) {
            (None, None, _, _) => anyhow::bail!("workspace or key is required"),
            (Some(id), None, Some(workspace), _) if workspace.id == id => workspace,
            (Some(id), None, None, _) => anyhow::bail!("unknown workspace {id}"),
            (None, Some(key), _, Some(workspace)) if workspace.key == key => workspace,
            (None, Some(key), _, None) => anyhow::bail!("unknown workspace key {key}"),
            (Some(_), Some(_), Some(by_id), Some(by_key)) if by_id.id == by_key.id => by_id,
            (Some(_), Some(_), _, _) => {
                anyhow::bail!("workspace id and key do not identify the same workspace")
            }
            _ => unreachable!("workspace selector cases are exhaustive"),
        };
        Ok((workspace.id, workspace.key.clone()))
    })
}
