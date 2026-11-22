//! Frontend, notification and agent command handlers: frontend projections
//! and journal events, notify and notification lists, agent reports and
//! lists, sidebar plugins, ids, and creation receipts. Each function is one
//! `Command` arm of `handle_command_with_cancellation`.

use super::CREATION_ATTEMPT_KEYS_CAPABILITY;
use super::CREATION_RECEIPTS_CAPABILITY;
use super::CREATION_SELECTOR_FALLBACKS_CAPABILITY;
use super::MAX_CREATION_SELECTOR_FALLBACKS;
use super::origin_gate;
use super::paired_surface_size;
use crate::WorkspaceMutation;
use crate::resource::ResourceOperation;

use crate::AgentRecord;
use crate::AgentSource;
use crate::AgentState;
use crate::NotificationLevel;
use crate::SidebarPluginStatus;
use crate::assign_short_ids;
use crate::model::State;

use super::CreateSurfaceWithReceiptRequest;
use super::MutationRequest;
use super::get_surface;
use super::public_client_id;
use super::workspace_mutation;
use crate::Actor;
use crate::Mux;
use crate::NotificationSource;
use crate::SurfaceId;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn get_frontend_projection(
    mux: &Arc<Mux>,
    frontend: String,
    scope: String,
    subject_key: String,
) -> anyhow::Result<Value> {
    let projection = mux.get_frontend_projection(&frontend, &scope, &subject_key)?;
    Ok(match projection {
        Some(projection) => serde_json::to_value(projection)?,
        None => json!({
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "schema_version": 0,
            "projection_revision": 0,
            "projection": null,
        }),
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn put_frontend_projection(
    mux: &Arc<Mux>,
    client: u64,
    frontend: String,
    scope: String,
    subject_key: String,
    schema_version: u32,
    expected_projection_revision: Option<u64>,
    projection: Value,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let commit = mux.put_frontend_projection(
        &workspace_mutation,
        &frontend,
        &scope,
        &subject_key,
        schema_version,
        expected_projection_revision,
        &projection,
    )?;
    let mut value = serde_json::to_value(commit.projection)?;
    value["replayed"] = json!(commit.replayed);
    Ok(value)
}

pub(super) fn journal_frontend_event(
    mux: &Arc<Mux>,
    client: u64,
    event: crate::FrontendJournalEvent,
) -> anyhow::Result<Value> {
    let session_id = mux.session_public_id();
    let principal_id = public_client_id(&session_id, client)?.to_string();
    mux.journal_frontend_event(principal_id, event)?;
    Ok(json!({"committed":true}))
}

pub(super) fn sidebar_plugin(
    mux: &Arc<Mux>,
    cols: u16,
    rows: u16,
    relaunch: bool,
) -> anyhow::Result<Value> {
    Ok(sidebar_plugin_status_json(mux.ensure_sidebar_plugin(cols, rows, relaunch)))
}

pub(super) fn create_surface_with_receipt_command(
    mux: &Arc<Mux>,
    client: u64,
    request: Box<CreateSurfaceWithReceiptRequest>,
) -> anyhow::Result<Value> {
    create_surface_with_receipt(mux, client, *request)
}

pub(super) fn ids(mux: &Arc<Mux>, kind: Option<String>) -> anyhow::Result<Value> {
    mux.with_state(|state| ids_json(state, kind.as_deref()))
}

pub(super) fn notify(
    mux: &Arc<Mux>,
    actor: Actor,
    title: String,
    body: String,
    level: Option<String>,
    surface: Option<SurfaceId>,
    source: Option<String>,
) -> anyhow::Result<Value> {
    if title.is_empty() {
        anyhow::bail!("title is required");
    }
    let level = parse_notification_level(level.as_deref().unwrap_or("info"))?;
    let source = match source.as_deref() {
        None => NotificationSource::Cli,
        Some(source) => NotificationSource::parse(source)
            .ok_or_else(|| anyhow::anyhow!("bad source {source}"))?,
    };
    if let Some(surface) = surface {
        get_surface(mux, surface)?;
    }
    let notification = mux.post_notification_as(&actor, title, body, level, surface, source)?;
    Ok(json!({ "notification": notification }))
}

pub(super) fn list_agents(
    mux: &Arc<Mux>,
    surface: Option<SurfaceId>,
    state: Option<String>,
) -> anyhow::Result<Value> {
    if let Some(surface) = surface {
        get_surface(mux, surface)?;
    }
    let state = match state {
        Some(state) => Some(parse_agent_state(&state)?),
        None => None,
    };
    let agents = mux.list_agents(surface, state).iter().map(agent_json).collect::<Vec<_>>();
    Ok(json!({ "agents": agents }))
}

pub(super) fn report_agent(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    state: String,
    source: String,
    session: Option<String>,
) -> anyhow::Result<Value> {
    get_surface(mux, surface)?;
    let state = parse_agent_state(&state)?;
    let source = parse_agent_source(&source)?;
    let record = mux.report_agent(surface, state, source, session)?;
    Ok(json!({
        "surface": record.surface,
        "state": record.state.as_str(),
        "source": record.source.as_str(),
        "session": record.session,
    }))
}

pub(super) fn list_notifications(mux: &Arc<Mux>, limit: Option<usize>) -> anyhow::Result<Value> {
    let rows = mux.notification_rows(limit.unwrap_or(256).min(256))?;
    Ok(json!({
        "notifications": rows
            .iter()
            .map(|(row, acknowledged)| {
                json!({
                    "id": row.id,
                    "title": row.title,
                    "subtitle": row.subtitle,
                    "body": row.body,
                    "level": row.level.as_str(),
                    "terminal_id": row.terminal_id,
                    "surface": row.surface,
                    "created_at_ms": row.created_at_ms,
                    "source": row.source.as_str(),
                    "acknowledged": acknowledged,
                })
            })
            .collect::<Vec<_>>(),
    }))
}

fn agent_json(record: &AgentRecord) -> Value {
    json!({
        "surface": record.surface,
        "state": record.state.as_str(),
        "source": record.source.as_str(),
        "session": record.session,
        "agent": record.agent,
        "updated_at_ms": record.updated_at_ms,
    })
}

fn ids_json(state: &State, kind: Option<&str>) -> anyhow::Result<Value> {
    let allowed = ["workspace", "screen", "pane", "surface"];
    if let Some(kind) = kind
        && !allowed.contains(&kind)
    {
        anyhow::bail!("bad kind {kind}");
    }
    let mut raw = Vec::new();
    for ws in &state.workspaces {
        raw.push(("workspace", ws.id));
        for screen in &ws.screens {
            raw.push(("screen", screen.id));
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            for pane in panes {
                raw.push(("pane", pane));
            }
        }
    }
    raw.extend(state.surfaces.keys().copied().map(|id| ("surface", id)));
    let short_ids = assign_short_ids(raw.iter().map(|(_, id)| *id));
    Ok(json!({
        "ids": raw
            .into_iter()
            .filter(|(item_kind, _)| kind.is_none_or(|kind| kind == *item_kind))
            .map(|(kind, id)| json!({
                "kind": kind,
                "id": id,
                "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
            }))
            .collect::<Vec<_>>()
    }))
}

fn parse_agent_source(source: &str) -> anyhow::Result<AgentSource> {
    match source {
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("bad source {other}; raw report-agent accepts only socket or hook"),
    }
}

fn parse_agent_state(state: &str) -> anyhow::Result<AgentState> {
    match state {
        "working" => Ok(AgentState::Working),
        "blocked" => Ok(AgentState::Blocked),
        "idle" => Ok(AgentState::Idle),
        "done" => Ok(AgentState::Done),
        "unknown" => Ok(AgentState::Unknown),
        other => anyhow::bail!("bad state {other}"),
    }
}

fn parse_notification_level(level: &str) -> anyhow::Result<NotificationLevel> {
    match level {
        "info" => Ok(NotificationLevel::Info),
        "warning" => Ok(NotificationLevel::Warning),
        "error" => Ok(NotificationLevel::Error),
        other => anyhow::bail!("bad level {other}"),
    }
}

fn sidebar_plugin_status_json(status: SidebarPluginStatus) -> Value {
    let retry_after_ms = status.retry_after.map(|duration| duration.as_millis() as u64);
    json!({
        "surface": status.surface,
        "error": status.error,
        "retry_after_ms": retry_after_ms,
    })
}

fn create_surface_with_receipt(
    mux: &Arc<Mux>,
    client: u64,
    request: CreateSurfaceWithReceiptRequest,
) -> anyhow::Result<Value> {
    let CreateSurfaceWithReceiptRequest {
        operation,
        origin,
        receipt,
        idempotency_key,
        selectors: supplied_selectors,
        selector_fallbacks,
        pane,
        workspace,
        argv,
        cwd,
        url,
        width,
        cols,
        rows,
    } = request;
    anyhow::ensure!(
        mux.control_clients.supports_capability(client, CREATION_RECEIPTS_CAPABILITY),
        "client did not negotiate {CREATION_RECEIPTS_CAPABILITY}"
    );
    anyhow::ensure!(
        idempotency_key.is_none()
            || mux.control_clients.supports_capability(client, CREATION_ATTEMPT_KEYS_CAPABILITY),
        "client did not negotiate {CREATION_ATTEMPT_KEYS_CAPABILITY}"
    );
    let actor = origin_gate::connection_actor(mux, client);
    let mutation =
        WorkspaceMutation::new(idempotency_key.unwrap_or_else(|| receipt.clone()), origin, actor)?;
    let size = paired_surface_size("create-surface-with-receipt", cols, rows)?;
    let mut fields = serde_json::Map::new();
    if let Some((cols, rows)) = size {
        fields.insert("cols".to_string(), json!(cols));
        fields.insert("rows".to_string(), json!(rows));
    }
    fields.insert("correlation_key".to_string(), json!(receipt));
    let session_selectors = || crate::ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..crate::ResourceSelectors::default()
    };
    let pane_selectors = |pane| {
        supplied_selectors.clone().map(Ok).unwrap_or_else(|| mux.resource_selectors_for_pane(pane))
    };
    let workspace_selectors = |workspace| {
        supplied_selectors
            .clone()
            .map(Ok)
            .unwrap_or_else(|| mux.resource_selectors_for_workspace(workspace))
    };
    let (resource_operation, selectors) = match operation.as_str() {
        "new-tab" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && url.is_none() && width.is_none(),
                "new-tab received fields that belong to another creation operation"
            );
            if let Some(cwd) = cwd {
                fields.insert("cwd".to_string(), json!(cwd));
            }
            (ResourceOperation::TabCreateTerminal, pane_selectors(pane)?)
        }
        "run-command" => {
            anyhow::ensure!(
                workspace.is_none() && url.is_none() && width.is_none(),
                "run-command received fields that belong to another creation operation"
            );
            let argv = argv
                .filter(|argv| !argv.is_empty())
                .ok_or_else(|| anyhow::anyhow!("run-command omitted argv"))?;
            fields.insert("argv".to_string(), json!(argv));
            if let Some(cwd) = cwd {
                fields.insert("cwd".to_string(), json!(cwd));
            }
            (ResourceOperation::PaneRun, pane_selectors(pane)?)
        }
        "new-browser-tab" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && cwd.is_none() && width.is_none(),
                "new-browser-tab received fields that belong to another creation operation"
            );
            let url = url
                .filter(|url| !url.is_empty())
                .ok_or_else(|| anyhow::anyhow!("browser creation omitted URL"))?;
            fields.insert("url".to_string(), json!(url));
            if let Some((cols, rows)) = size {
                let (cell_width, cell_height) = mux.cell_pixel_size();
                fields.remove("cols");
                fields.remove("rows");
                fields
                    .insert("width_px".to_string(), json!(u64::from(cols) * u64::from(cell_width)));
                fields.insert(
                    "height_px".to_string(),
                    json!(u64::from(rows) * u64::from(cell_height)),
                );
            }
            (ResourceOperation::TabCreateBrowser, pane_selectors(pane)?)
        }
        "new-workspace" => {
            anyhow::ensure!(
                pane.is_none()
                    && workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-workspace received fields that belong to another creation operation"
            );
            fields.insert("initial_content".to_string(), json!("terminal"));
            (
                ResourceOperation::WorkspaceCreate,
                supplied_selectors.clone().unwrap_or_else(session_selectors),
            )
        }
        "new-screen" => {
            anyhow::ensure!(
                pane.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-screen received fields that belong to another creation operation"
            );
            (ResourceOperation::ScreenCreate, workspace_selectors(workspace)?)
        }
        "new-pane" => {
            anyhow::ensure!(
                workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-pane received fields that belong to another creation operation"
            );
            (ResourceOperation::PaneCreate, pane_selectors(pane)?)
        }
        "new-pane-right" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && cwd.is_none() && url.is_none(),
                "new-pane-right received fields that belong to another creation operation"
            );
            let width =
                width.ok_or_else(|| anyhow::anyhow!("new-pane-right omitted viewport width"))?;
            fields.insert("direction".to_string(), json!("right"));
            fields.insert("viewport_width".to_string(), json!(width));
            (ResourceOperation::PaneSplit, pane_selectors(pane)?)
        }
        "split-right" | "split-down" => {
            anyhow::ensure!(
                workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "split creation received fields that belong to another creation operation"
            );
            fields.insert(
                "direction".to_string(),
                json!(if operation == "split-right" { "right" } else { "down" }),
            );
            (ResourceOperation::PaneSplit, pane_selectors(pane)?)
        }
        other => anyhow::bail!("unknown receipted creation operation {other:?}"),
    };
    anyhow::ensure!(
        selector_fallbacks.len() <= MAX_CREATION_SELECTOR_FALLBACKS,
        "creation accepts at most {MAX_CREATION_SELECTOR_FALLBACKS} selector fallbacks"
    );
    anyhow::ensure!(
        selector_fallbacks.is_empty()
            || mux
                .control_clients
                .supports_capability(client, CREATION_SELECTOR_FALLBACKS_CAPABILITY),
        "client did not negotiate {CREATION_SELECTOR_FALLBACKS_CAPABILITY}"
    );
    anyhow::ensure!(
        selector_fallbacks.is_empty()
            || matches!(
                resource_operation,
                ResourceOperation::PaneSplit
                    | ResourceOperation::PaneCreate
                    | ResourceOperation::PaneRun
                    | ResourceOperation::TabCreateTerminal
                    | ResourceOperation::TabCreateBrowser
            ),
        "selector fallbacks require a pane-targeted creation"
    );
    let mut selector_candidates = Vec::with_capacity(1 + selector_fallbacks.len());
    selector_candidates.push(selectors);
    for fallback in selector_fallbacks {
        if !selector_candidates.contains(&fallback) {
            selector_candidates.push(fallback);
        }
    }
    let (surface, replayed) =
        mux.receipted_surface_creation(resource_operation, selector_candidates, fields, &mutation)?;
    Ok(json!({"surface": surface, "replayed": replayed}))
}
