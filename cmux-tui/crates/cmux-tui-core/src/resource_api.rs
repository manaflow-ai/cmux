//! Transport-independent machine routing for `cmux.protocol/2`.
//!
//! The session mux owns local terminal state. Machine catalogs and providers
//! live in the outer runtime, so the public router crosses this injected
//! boundary instead of importing provider implementation details into core.

#[cfg(test)]
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::Weak;

use anyhow::Context;
use serde_json::{Map, Value, json};

use crate::resource::{
    ContentPublicId, FrontendProjectionPublicId, MachinePublicId, PanePublicId, ResourceError,
    ResourceOperation, Selector, SessionPublicId, TabPublicId, TerminalPublicId,
};
use crate::resource_screen::{public_screen_value, tabs_by_pane};
use crate::sidebar_resource::{sidebar_snapshot, sidebar_view_id};
use crate::workspace_registry::{
    FrontendProjection, RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserSource,
    RegistryBrowserStatus, RegistryTab, RegistryTerminal, ResourceEffectOutcome,
    ResourceEffectPreparation, TerminalLifecycle,
};
use crate::{Mux, ResourceSelectors};

#[cfg(test)]
thread_local! {
    static SNAPSHOT_BEFORE_PROJECTION_HOOK: RefCell<Option<Box<dyn FnOnce()>>> =
        RefCell::new(None);
}

pub(crate) fn public_frontend_projection_snapshot(
    session_id: &SessionPublicId,
    id: &FrontendProjectionPublicId,
    stored: &FrontendProjection,
) -> Result<Value, ResourceError> {
    let malformed = || {
        ResourceError::operation_failed(
            "frontend_projection.get",
            "stored frontend projection is malformed",
            json!({"frontend_projection":id}),
        )
    };
    let envelope = stored.projection.as_object().ok_or_else(&malformed)?;
    let frontend_id = envelope.get("frontend_id").and_then(Value::as_str).ok_or_else(&malformed)?;
    let window_id = envelope.get("window_id").and_then(Value::as_str).ok_or_else(&malformed)?;
    let generation = envelope.get("generation").and_then(Value::as_str).ok_or_else(&malformed)?;
    let projection = envelope.get("projection").cloned().ok_or_else(&malformed)?;
    Ok(json!({
        "id":id,
        "session_id":session_id,
        "frontend_id":frontend_id,
        "window_id":window_id,
        "generation":generation,
        "projection":projection,
        "projection_revision":stored.projection_revision.to_string(),
    }))
}

#[cfg(test)]
pub(crate) fn set_snapshot_before_projection_hook(hook: impl FnOnce() + 'static) {
    SNAPSHOT_BEFORE_PROJECTION_HOOK.with(|slot| {
        *slot.borrow_mut() = Some(Box::new(hook));
    });
}

#[cfg(test)]
fn run_snapshot_before_projection_hook() {
    SNAPSHOT_BEFORE_PROJECTION_HOOK.with(|slot| {
        if let Some(hook) = slot.borrow_mut().take() {
            hook();
        }
    });
}

#[derive(Debug, Clone)]
pub struct ResourceMachineRequest {
    pub operation: ResourceOperation,
    pub selectors: ResourceSelectors,
    pub fields: Map<String, Value>,
    pub idempotency_key: Option<String>,
    /// Who sends it, set by the daemon's dispatcher.
    pub actor: crate::Actor,
}

pub trait ResourceMachineService: Send + Sync {
    fn dispatch(&self, request: &ResourceMachineRequest) -> Result<Value, ResourceError>;
}

#[derive(Debug, Clone)]
pub(crate) struct LocalResourceContext {
    pub machine_id: MachinePublicId,
    pub session_id: SessionPublicId,
    pub session_name: String,
    pub generation: String,
    pub revision: u64,
}

pub(crate) struct LocalResourceMachineService {
    mux: Weak<Mux>,
}

impl LocalResourceMachineService {
    pub(crate) fn new(mux: Weak<Mux>) -> Self {
        Self { mux }
    }

    fn context(&self) -> Result<LocalResourceContext, ResourceError> {
        self.mux
            .upgrade()
            .ok_or_else(|| ResourceError::transport_closed("the local session has closed"))?
            .local_resource_context()
            .map_err(operation_failed)
    }
}

impl ResourceMachineService for LocalResourceMachineService {
    fn dispatch(&self, request: &ResourceMachineRequest) -> Result<Value, ResourceError> {
        let context = self.context()?;
        match request.operation {
            ResourceOperation::MachineList => {
                require_no_selectors(&request.selectors)?;
                Ok(json!([machine_snapshot(&context)]))
            }
            ResourceOperation::MachineGet => {
                resolve_local_machine(&request.selectors, &context)?;
                Ok(machine_snapshot(&context))
            }
            ResourceOperation::SessionList => {
                resolve_local_machine(&request.selectors, &context)?;
                require_absent(
                    &request.selectors.session,
                    "session",
                    "session.list does not select one session",
                )?;
                Ok(json!([session_snapshot(&context)]))
            }
            ResourceOperation::SessionGet => {
                resolve_local_session(&request.selectors, &context)?;
                Ok(session_snapshot(&context))
            }
            ResourceOperation::SessionOpen => self.open_local_session(request, &context),
            operation => Err(ResourceError::operation_failed(
                operation.wire_name().to_owned(),
                "operation was routed to the wrong machine service",
                json!({}),
            )),
        }
    }
}

impl LocalResourceMachineService {
    fn open_local_session(
        &self,
        request: &ResourceMachineRequest,
        context: &LocalResourceContext,
    ) -> Result<Value, ResourceError> {
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| ResourceError::transport_closed("the local session has closed"))?;
        let key = request.idempotency_key.as_deref().ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("idempotency_key"),
                "session.open requires an idempotency key",
            )
        })?;
        let fingerprint = json!({
            "operation":"session.open",
            "selectors":request.selectors,
            "fields":request.fields,
        });
        if let Some(preparation) = mux
            .lookup_resource_effect(key, "session.open", &fingerprint)
            .map_err(operation_failed)?
        {
            return resolve_local_open_preparation(&mux, key, &fingerprint, preparation);
        }

        resolve_local_session(&request.selectors, context)?;
        let expected_revision = request
            .fields
            .get("expected_revision")
            .and_then(Value::as_str)
            .map(|revision| revision.parse::<u64>())
            .transpose()
            .map_err(|_| {
                ResourceError::validation_invalid(
                    Some("expected_revision"),
                    "session.open expected_revision is invalid",
                )
            })?;
        let intent = json!({"session_id":context.session_id});
        let preparation = mux
            .prepare_resource_effect(
                &crate::WorkspaceMutation::new(key, "resource-api", request.actor.clone())
                    .map_err(operation_failed)?,
                "session.open",
                &fingerprint,
                &intent,
                None,
                expected_revision,
            )
            .map_err(operation_failed)?;
        resolve_local_open_preparation(&mux, key, &fingerprint, preparation)
    }
}

fn resolve_local_open_preparation(
    mux: &Arc<Mux>,
    key: &str,
    fingerprint: &Value,
    preparation: ResourceEffectPreparation,
) -> Result<Value, ResourceError> {
    match preparation {
        ResourceEffectPreparation::Committed { outcome, revision } => match outcome {
            ResourceEffectOutcome::Success(value) => {
                local_mutation_result(mux, value, revision, true)
            }
            ResourceEffectOutcome::Failure(error) => Err(error),
        },
        ResourceEffectPreparation::Indeterminate => {
            Err(local_indeterminate_error(key, "session.open"))
        }
        ResourceEffectPreparation::Execute { .. } => {
            mux.mark_resource_effect_executing(key, "session.open", fingerprint)
                .map_err(operation_failed)?;
            let mut context = mux.local_resource_context().map_err(operation_failed)?;
            context.revision = context.revision.saturating_add(1);
            let value = session_snapshot(&context);
            let outcome = ResourceEffectOutcome::Success(value.clone());
            let revision = mux
                .commit_resource_effect(
                    key,
                    "session.open",
                    fingerprint,
                    &outcome,
                    Some(&json!([])),
                )
                .map_err(|_| {
                    let _ = mux.mark_resource_effect_indeterminate(key);
                    local_indeterminate_error(key, "session.open")
                })?;
            local_mutation_result(mux, value, revision, false)
        }
    }
}

fn local_mutation_result(
    mux: &Mux,
    value: Value,
    revision: u64,
    replayed: bool,
) -> Result<Value, ResourceError> {
    let context = mux.local_resource_context().map_err(operation_failed)?;
    Ok(json!({
        "value":value,
        "generation":context.generation,
        "revision":revision.to_string(),
        "replayed":replayed,
    }))
}

fn local_indeterminate_error(key: &str, operation: &str) -> ResourceError {
    ResourceError::new(
        "mutation.indeterminate",
        "the external effect may have run before its outcome was recorded",
        json!({
            "idempotency_key":key,
            "operation":operation,
            "recovery":"inspect_state_then_retry_with_new_key",
        }),
        false,
    )
}

fn machine_snapshot(context: &LocalResourceContext) -> Value {
    json!({
        "id": context.machine_id,
        "name": "local",
        "origin": "local",
        "status": "running",
        "connectable": true,
        "deleted": false,
        "recoverable": false,
    })
}

fn session_snapshot(context: &LocalResourceContext) -> Value {
    json!({
        "id": context.session_id,
        "machine_id": context.machine_id,
        "name": context.session_name,
        "generation": context.generation,
        "revision": context.revision.to_string(),
        "connected": true,
    })
}

fn resolve_local_session(
    selectors: &ResourceSelectors,
    context: &LocalResourceContext,
) -> Result<(), ResourceError> {
    resolve_local_machine(selectors, context)?;
    resolve_singleton(
        "session",
        selectors.session.as_deref(),
        context.session_id.as_str(),
        Some(&context.session_name),
    )
}

fn resolve_local_machine(
    selectors: &ResourceSelectors,
    context: &LocalResourceContext,
) -> Result<(), ResourceError> {
    resolve_singleton(
        "machine",
        selectors.machine.as_deref(),
        context.machine_id.as_str(),
        Some("local"),
    )
}

fn resolve_singleton(
    kind: &str,
    raw: Option<&str>,
    expected_id: &str,
    expected_name: Option<&str>,
) -> Result<(), ResourceError> {
    let raw = raw.ok_or_else(|| {
        ResourceError::selector_invalid(
            kind,
            "<missing>",
            format!("missing required {kind} selector"),
        )
    })?;
    match Selector::parse(raw)? {
        Selector::Current => Ok(()),
        Selector::Id(id) if id == expected_id => Ok(()),
        Selector::Name(name) if expected_name == Some(name.as_str()) => Ok(()),
        Selector::Id(_) | Selector::Name(_) => Err(ResourceError::not_found(kind, raw)),
    }
}

fn require_no_selectors(selectors: &ResourceSelectors) -> Result<(), ResourceError> {
    let value = serde_json::to_value(selectors).map_err(|error| {
        ResourceError::operation_failed(
            "machine.list",
            "could not validate selectors",
            json!({"error":error.to_string()}),
        )
    })?;
    if value.as_object().is_none_or(Map::is_empty) {
        Ok(())
    } else {
        Err(ResourceError::selector_invalid(
            "machine",
            "<selectors>",
            "machine.list does not accept selectors",
        ))
    }
}

fn require_absent(
    selector: &Option<String>,
    kind: &str,
    message: &str,
) -> Result<(), ResourceError> {
    if selector.is_none() {
        Ok(())
    } else {
        Err(ResourceError::selector_invalid(
            kind,
            selector.as_deref().expect("checked selector presence"),
            message,
        ))
    }
}

pub(crate) fn operation_failed(error: anyhow::Error) -> ResourceError {
    if let Some(resource) = error.downcast_ref::<ResourceError>() {
        return resource.clone();
    }
    ResourceError::operation_failed("resource.runtime", error.to_string(), json!({}))
}

pub(crate) fn terminal_tab_ids_in_canonical_order(
    tabs: impl IntoIterator<Item = (TerminalPublicId, PanePublicId, usize, TabPublicId)>,
) -> HashMap<TerminalPublicId, Vec<TabPublicId>> {
    let mut tabs = tabs.into_iter().collect::<Vec<_>>();
    tabs.sort_by(|left, right| {
        left.1
            .as_str()
            .cmp(right.1.as_str())
            .then_with(|| left.2.cmp(&right.2))
            .then_with(|| left.3.as_str().cmp(right.3.as_str()))
    });
    let mut ordered = HashMap::<TerminalPublicId, Vec<TabPublicId>>::new();
    for (terminal_id, _pane_id, _position, tab_id) in tabs {
        ordered.entry(terminal_id).or_default().push(tab_id);
    }
    ordered
}

pub(crate) fn public_terminal_snapshot(
    terminal_id: &TerminalPublicId,
    durable: &RegistryTerminal,
    surface: Option<&crate::Surface>,
    tab_ids: Vec<TabPublicId>,
) -> anyhow::Result<Value> {
    let lifecycle = match durable.lifecycle {
        TerminalLifecycle::Launching | TerminalLifecycle::Adopting => "launching",
        TerminalLifecycle::Running => "running",
        TerminalLifecycle::Exited => "exited",
        TerminalLifecycle::Tombstoned => {
            anyhow::bail!("public terminal projection contains a tombstoned terminal")
        }
    };
    let durable_size = |field: &str, fallback: u16| {
        durable.launch_spec[field]
            .as_u64()
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value > 0)
            .unwrap_or(fallback)
    };
    let (cols, rows) = surface
        .map(crate::Surface::size)
        .unwrap_or_else(|| (durable_size("cols", 80), durable_size("rows", 24)));
    let mut terminal = json!({
        "id": terminal_id,
        "tab_id": tab_ids.first(),
        "tab_ids": tab_ids,
        "title": surface.map(crate::Surface::title).unwrap_or_default(),
        "cols": cols.max(1),
        "rows": rows.max(1),
        "running": durable.lifecycle == TerminalLifecycle::Running,
        "lifecycle": lifecycle,
    });
    if let Some(surface) = surface
        && let Ok(revision) = surface.terminal_stream_revision()
    {
        // This is a coalesced output revision, not the resource revision. It
        // lets external observers skip a full screen read when the PTY did
        // not change.
        terminal["stream_revision"] = json!(revision.to_string());
    }
    if let Some(cwd) = surface.and_then(crate::Surface::presented_directory) {
        terminal["cwd"] = json!(cwd);
    }
    let running = durable.lifecycle == TerminalLifecycle::Running;
    let mut extra = Map::new();
    if let Some(progress) = surface.and_then(crate::Surface::terminal_progress) {
        extra.insert("progress".into(), progress.to_json());
    }
    if let Some(status) = surface.and_then(|surface| surface.terminal_program_status(running)) {
        extra.insert("program_status".into(), status);
    }
    if !extra.is_empty() {
        terminal["extra"] = Value::Object(extra);
    }
    if durable.lifecycle == TerminalLifecycle::Exited {
        terminal["exit"] =
            durable.exit.clone().context("exited terminal omitted its durable outcome")?;
    } else {
        debug_assert!(
            durable.exit.is_none(),
            "non-exited terminal unexpectedly has a durable outcome"
        );
    }
    Ok(terminal)
}

pub(crate) fn public_session_snapshot(mux: &Mux) -> Result<Value, ResourceError> {
    public_session_snapshot_with_journal_head(mux).map(|(snapshot, _)| snapshot)
}

/// Returns the public session snapshot together with the session journal head
/// read under the same registry + state projection lock. The pair is one
/// consistent cut: every journal record at or below the returned head is
/// reflected in the snapshot, and every later record is not. Checkpoint
/// capture keys its consistency fence to this cut so a journal write that
/// merely precedes the cut cannot spuriously abort the capture.
pub(crate) fn public_session_snapshot_with_journal_head(
    mux: &Mux,
) -> Result<(Value, u64), ResourceError> {
    mux.publish_pending_terminal_directories();
    // Collect the auxiliary runtime before taking the registry + state
    // projection lock. Sidebar status locks its own lifecycle and then looks
    // up a surface in State, so doing this inside the projection would invert
    // that lock order.
    let (sidebar_status, sidebar_last_size, sidebar_configured) =
        mux.sidebar_plugin_resource_status();
    let sidebar_surface = sidebar_status.surface.and_then(|surface| mux.surface(surface));
    #[cfg(test)]
    run_snapshot_before_projection_hook();
    mux.with_resource_projection(|registry, state| {
        let journal_head = registry.session_journal_head()?;
        let registry_snapshot = registry.snapshot()?;
        let topology = registry.resource_topology_snapshot()?;
        let terminal_registry = registry.terminal_snapshot()?;
        let terminal_resource_ids = registry.live_terminal_resource_ids()?;
        let public_projections = registry.public_projections()?;
        anyhow::ensure!(
            registry_snapshot.generation == topology.generation
                && registry_snapshot.resource_revision == topology.revision,
            "resource projection changed while snapshotting"
        );
        let context = LocalResourceContext {
            machine_id: registry.machine_id().clone(),
            session_id: registry.session_id().clone(),
            session_name: mux.session.clone(),
            generation: topology.generation.clone(),
            revision: topology.revision,
        };
        let sidebar_id = sidebar_view_id(&context.session_id)?;
        let sidebar_views = if sidebar_configured || sidebar_last_size.is_some() {
            vec![sidebar_snapshot(
                &sidebar_id,
                &context.session_id,
                sidebar_last_size.unwrap_or((1, 1)),
                sidebar_surface.as_ref(),
            )]
        } else {
            Vec::new()
        };

        let tabs_by_pane = tabs_by_pane(&topology.tabs);
        let panes_by_id =
            topology.panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
        let screens_by_id = topology
            .screens
            .iter()
            .map(|screen| (&screen.public_id, screen))
            .collect::<HashMap<_, _>>();
        let active_screens = topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
        let terminals_by_id = terminal_registry
            .terminals
            .iter()
            .map(|terminal| (terminal.terminal_id.as_str(), terminal))
            .collect::<HashMap<_, _>>();
        let terminal_resources_by_host =
            terminal_resource_ids.iter().cloned().collect::<HashMap<_, _>>();
        let terminal_hosts_by_resource = terminal_resource_ids
            .into_iter()
            .map(|(host_id, terminal_id)| (terminal_id, host_id))
            .collect::<HashMap<_, _>>();

        let workspaces = registry_snapshot
            .workspaces
            .iter()
            .enumerate()
            .map(|(index, workspace)| {
                Ok(json!({
                    "id": workspace.public_id,
                    "session_id": topology.session_id,
                    "name": workspace.name,
                    "index": checked_index(index)?,
                    "focused": topology.active_workspace.as_ref() == Some(&workspace.public_id),
                }))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let screens = topology
            .screens
            .iter()
            .map(|screen| public_screen_value(&topology, screen, &tabs_by_pane, &panes_by_id))
            .collect::<anyhow::Result<Vec<_>>>()?;

        let panes = topology
            .panes
            .iter()
            .map(|pane| {
                let screen = screens_by_id
                    .get(&pane.screen_id)
                    .ok_or_else(|| anyhow::anyhow!("pane references a missing screen"))?;
                let screen_focused = topology.active_workspace.as_ref()
                    == Some(&screen.workspace_id)
                    && active_screens.get(&screen.workspace_id).and_then(Option::as_ref)
                        == Some(&screen.public_id);
                Ok(json!({
                    "id": pane.public_id,
                    "screen_id": pane.screen_id,
                    "name": pane.name,
                    "focused": screen_focused && screen.active_pane == pane.public_id,
                    "zoomed": screen.zoomed_pane.as_ref() == Some(&pane.public_id),
                }))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let tabs = topology
            .tabs
            .iter()
            .map(|tab| {
                let pane = panes_by_id
                    .get(&tab.pane_id)
                    .ok_or_else(|| anyhow::anyhow!("tab references a missing pane"))?;
                checked_index(tab.position)?;
                Ok(tab.public_value(pane.active_tab.as_ref() == Some(&tab.public_id)))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let mut terminal_order = Vec::new();
        let mut seen_terminals = HashSet::new();
        for tab in &topology.tabs {
            if let ContentPublicId::Terminal(terminal_id) = &tab.content_id {
                if seen_terminals.insert(terminal_id.clone()) {
                    terminal_order.push(terminal_id.clone());
                }
                let host_id = terminal_hosts_by_resource.get(terminal_id).with_context(|| {
                    format!("terminal {terminal_id} omitted its durable identity")
                })?;
                if let Some(tab_host_id) = &tab.terminal_id {
                    anyhow::ensure!(
                        tab_host_id == host_id,
                        "terminal {terminal_id} references a mismatched durable host"
                    );
                }
            }
        }
        let mut tab_ids_by_terminal =
            terminal_tab_ids_in_canonical_order(topology.tabs.iter().filter_map(|tab| {
                match &tab.content_id {
                    ContentPublicId::Terminal(terminal_id) => Some((
                        terminal_id.clone(),
                        tab.pane_id.clone(),
                        tab.position,
                        tab.public_id.clone(),
                    )),
                    ContentPublicId::Browser(_) => None,
                }
            }));
        for durable in &terminal_registry.terminals {
            if let Some(terminal_id) = terminal_resources_by_host.get(&durable.terminal_id)
                && seen_terminals.insert(terminal_id.clone())
            {
                terminal_order.push(terminal_id.clone());
            }
        }
        for (host_id, terminal_id) in &terminal_resources_by_host {
            if !terminals_by_id.contains_key(host_id.as_str()) {
                // A resource row whose durable host vanished (a close that
                // tombstoned the registry but not the resource row, or a crash
                // between the two writes) must not fail the whole snapshot:
                // every client renders a failed snapshot as "machine
                // unreachable". Skip the dangling row; the close path owns the
                // repair.
                eprintln!(
                    "cmux-tui: snapshot skipping terminal {terminal_id} referencing missing {host_id}"
                );
            }
        }

        let terminals = terminal_order
            .into_iter()
            .map(|terminal_id| {
                let surface = state.terminal_catalog.get(&terminal_id);
                let host_id = terminal_hosts_by_resource.get(&terminal_id).with_context(|| {
                    format!("terminal {terminal_id} omitted its durable identity")
                })?;
                if let Some(surface) = surface {
                    let runtime_host =
                        mux.resource_terminal_host_identity(surface).with_context(|| {
                            format!("terminal {terminal_id} runtime omitted its durable identity")
                        })?;
                    anyhow::ensure!(
                        runtime_host.terminal_id == *host_id,
                        "terminal {terminal_id} runtime references a mismatched durable host"
                    );
                }
                let durable = terminals_by_id.get(host_id.as_str()).with_context(|| {
                    format!("terminal {terminal_id} references missing {host_id}")
                })?;
                let tab_ids = tab_ids_by_terminal.remove(&terminal_id).unwrap_or_default();
                public_terminal_snapshot(&terminal_id, durable, surface.map(Arc::as_ref), tab_ids)
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let browsers_by_id = topology
            .browsers
            .iter()
            .map(|browser| (&browser.public_id, browser))
            .collect::<HashMap<_, _>>();
        let browsers = topology
            .tabs
            .iter()
            .filter_map(|tab| {
                let ContentPublicId::Browser(browser_id) = &tab.content_id else {
                    return None;
                };
                let durable = *browsers_by_id.get(browser_id)?;
                let surface = state.surface_by_content_public_id(&tab.content_id);
                Some(public_browser_snapshot(tab, durable, surface))
            })
            .collect::<Vec<_>>();

        let notifications = public_projections
            .notifications
            .into_iter()
            .rev()
            .map(|notification| {
                let mut snapshot = json!({
                    "id": notification.id,
                    "session_id": topology.session_id,
                    "title": notification.title,
                    "body": notification.body,
                    "level": notification.level,
                    "created_at_ms": notification.created_at_ms.to_string(),
                    "unread": notification
                        .terminal_id
                        .as_ref()
                        .and_then(|terminal_id| mux.terminal_notification(terminal_id))
                        .is_some_and(|notification| notification.unread),
                    "read_by": notification.read_by,
                });
                if let Some(terminal_id) = notification.terminal_id {
                    snapshot["terminal_id"] = json!(terminal_id);
                }
                if let Some(subtitle) = notification.subtitle {
                    snapshot["subtitle"] = json!(subtitle);
                }
                snapshot["extra"] = json!({"source": notification.source.as_str()});
                snapshot
            })
            .collect::<Vec<_>>();
        let mut agents = public_projections
            .agents
            .into_iter()
            .filter(|agent| {
                (agent.source != "hook" || agent.state != "done")
                    && !agent
                        .source_session
                        .as_deref()
                        .is_some_and(|value| value.starts_with("cmux-hook-ended:"))
            })
            .map(|mut agent| {
                if agent.source_session.as_deref().is_some_and(|value| {
                    value.starts_with("cmux-hook-sequence:")
                        || value.starts_with("cmux-hook-ended:")
                }) {
                    agent.source_session = None;
                }
                agent
            })
            .map(|agent| agent.into_public_snapshot(&topology.session_id))
            .collect::<Vec<_>>();
        agents.sort_by(|left, right| {
            left["id"].as_str().unwrap_or_default().cmp(right["id"].as_str().unwrap_or_default())
        });
        let frontend_projections = public_projections
            .frontend_projections
            .into_iter()
            .map(|projection| {
                let id = FrontendProjectionPublicId::parse(projection.subject_key.as_str())?;
                public_frontend_projection_snapshot(&topology.session_id, &id, &projection)
            })
            .collect::<Result<Vec<_>, ResourceError>>()?;
        let _terminal_defaults = public_projections.terminal_defaults;

        let mut snapshot = json!({
            "machine": machine_snapshot(&context),
            "session": session_snapshot(&context),
            "workspaces": workspaces,
            "screens": screens,
            "panes": panes,
            "tabs": tabs,
            "terminals": terminals,
            "browsers": browsers,
            "clients": [],
            "notifications": notifications,
            "agents": agents,
            "frontend_projections": frontend_projections,
            "sidebar_views": sidebar_views,
            "cursor": {
                "generation": topology.generation,
                "revision": topology.revision.to_string(),
            },
        });
        registry.read_state(|connection| {
            crate::state::values::decorate_snapshot(connection, &mut snapshot)?;
            snapshot["extra"] = json!({
                "state": crate::state::store::state_snapshot(connection)?,
            });
            Ok(())
        })?;
        Ok((snapshot, journal_head))
    })
    .map_err(operation_failed)
}

fn checked_index(index: usize) -> anyhow::Result<u32> {
    u32::try_from(index).map_err(|_| anyhow::anyhow!("resource index exceeds uint32"))
}

fn public_browser_snapshot(
    tab: &RegistryTab,
    durable: &RegistryBrowser,
    surface: Option<&Arc<crate::Surface>>,
) -> Value {
    let live_status = surface.and_then(|surface| surface.browser_status());
    let status =
        live_status.as_ref().map(|status| status.as_str()).unwrap_or_else(|| {
            match durable.status {
                RegistryBrowserStatus::Starting => "starting",
                RegistryBrowserStatus::Live => "live",
                RegistryBrowserStatus::Failed => "failed",
            }
        });
    let source = surface
        .and_then(|surface| surface.browser_source())
        .map(|source| source.as_str())
        .unwrap_or_else(|| match durable.source {
            RegistryBrowserSource::External => "external",
            RegistryBrowserSource::Launched => "launched",
            RegistryBrowserSource::Unknown => match durable.launch {
                RegistryBrowserLaunch::Create => "external",
                RegistryBrowserLaunch::Adopted => "external",
            },
        });
    let (cols, rows) =
        surface.map(|surface| surface.size()).unwrap_or((durable.cols, durable.rows));
    json!({
        "id": durable.public_id,
        "tab_id": tab.public_id,
        "url": surface
            .and_then(|surface| surface.browser_url())
            .unwrap_or_else(|| durable.url.clone()),
        "title": surface.map(|surface| surface.title()).unwrap_or_default(),
        "loading": status == "starting",
        "source": source,
        "status": status,
        "error": live_status.and_then(|status| status.error()),
        "frames_stalled": surface
            .and_then(|surface| surface.browser_frames_stalled())
            .unwrap_or(false),
        "size": {
            "cols": cols.max(1),
            "rows": rows.max(1),
        },
    })
}

#[cfg(test)]
mod tests;
