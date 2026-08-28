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
use crate::sidebar_resource::{sidebar_snapshot, sidebar_view_id};
use crate::workspace_registry::{
    FrontendProjection, RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserSource,
    RegistryBrowserStatus, RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryTab,
    RegistryTerminal, RegistryViewport, ResourceEffectOutcome, ResourceEffectPreparation,
    TerminalLifecycle,
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
                resource_operation_name(operation),
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
                key,
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

fn resource_operation_name(operation: ResourceOperation) -> String {
    serde_json::to_value(operation)
        .expect("resource operation serializes")
        .as_str()
        .expect("resource operation serializes as a string")
        .to_string()
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
    if let Some(cwd) = surface.and_then(crate::Surface::spawn_cwd) {
        terminal["cwd"] = json!(cwd);
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
        let journal_head = registry.session_journal_after(0, 1)?.head_sequence;
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
            .map(|screen| {
                let focused = topology.active_workspace.as_ref() == Some(&screen.workspace_id)
                    && active_screens.get(&screen.workspace_id).and_then(Option::as_ref)
                        == Some(&screen.public_id);
                Ok(json!({
                    "id": screen.public_id,
                    "workspace_id": screen.workspace_id,
                    "name": screen.name,
                    "index": checked_index(screen.position)?,
                    "focused": focused,
                    "layout": public_layout_document(screen, &tabs_by_pane, &panes_by_id)?,
                }))
            })
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
                let content_kind = match tab.content_id {
                    ContentPublicId::Terminal(_) => "terminal",
                    ContentPublicId::Browser(_) => "browser",
                };
                Ok(json!({
                    "id": tab.public_id,
                    "pane_id": tab.pane_id,
                    "name": tab.name,
                    "index": checked_index(tab.position)?,
                    "focused": pane.active_tab.as_ref() == Some(&tab.public_id),
                    "content_kind": content_kind,
                    "content_id": tab.content_id.as_str(),
                }))
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
                });
                if let Some(terminal_id) = notification.terminal_id {
                    snapshot["terminal_id"] = json!(terminal_id);
                }
                snapshot
            })
            .collect::<Vec<_>>();
        let mut agents = public_projections
            .agents
            .into_iter()
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

        let snapshot = json!({
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
        Ok((snapshot, journal_head))
    })
    .map_err(operation_failed)
}

fn checked_index(index: usize) -> anyhow::Result<u32> {
    u32::try_from(index).map_err(|_| anyhow::anyhow!("resource index exceeds uint32"))
}

fn tabs_by_pane(tabs: &[RegistryTab]) -> HashMap<&PanePublicId, Vec<&RegistryTab>> {
    let mut by_pane = HashMap::<_, Vec<_>>::new();
    for tab in tabs {
        by_pane.entry(&tab.pane_id).or_default().push(tab);
    }
    for pane_tabs in by_pane.values_mut() {
        pane_tabs.sort_by_key(|tab| tab.position);
    }
    by_pane
}

fn public_layout_document(
    screen: &RegistryScreen,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    let root = if screen.viewport.columns.is_empty() {
        public_layout_node(&screen.layout, tabs_by_pane, panes_by_id)?
    } else {
        public_viewport_node(&screen.viewport, tabs_by_pane, panes_by_id)?
    };
    Ok(json!({
        "version": 1,
        "screen_id": screen.public_id,
        "active_pane_id": screen.active_pane,
        "zoomed_pane_id": screen.zoomed_pane,
        "root": root,
    }))
}

fn public_viewport_node(
    viewport: &RegistryViewport,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    let base_width =
        viewport.base_width.ok_or_else(|| anyhow::anyhow!("viewport has no base width"))?;
    anyhow::ensure!(base_width.is_finite(), "viewport base width is not finite");
    let columns = viewport
        .columns
        .iter()
        .map(|column| {
            anyhow::ensure!(column.width.is_finite(), "viewport column width is not finite");
            Ok(json!({
                "column_id": column.id,
                "width": f64::from(column.width),
                "root": public_layout_node(&column.layout, tabs_by_pane, panes_by_id)?,
            }))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok(json!({
        "kind": "viewport",
        "base_width": f64::from(base_width),
        "columns": columns,
    }))
}

fn public_layout_node(
    node: &RegistryLayoutNode,
    tabs_by_pane: &HashMap<&PanePublicId, Vec<&RegistryTab>>,
    panes_by_id: &HashMap<&PanePublicId, &RegistryPane>,
) -> anyhow::Result<Value> {
    match node {
        RegistryLayoutNode::Leaf { pane } => {
            let tabs = tabs_by_pane.get(pane).cloned().unwrap_or_default();
            let pane_record = panes_by_id
                .get(pane)
                .ok_or_else(|| anyhow::anyhow!("layout leaf is missing pane"))?;
            let mut leaf = json!({
                "kind": "leaf",
                "pane_id": pane,
                "tab_ids": tabs.iter().map(|tab| &tab.public_id).collect::<Vec<_>>(),
            });
            if let Some(active_tab) = &pane_record.active_tab {
                leaf["active_tab_id"] = json!(active_tab);
            }
            Ok(leaf)
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            anyhow::ensure!(ratio.is_finite(), "layout split ratio is not finite");
            let direction = match direction.as_str() {
                "right" | "horizontal" => "horizontal",
                "down" | "vertical" => "vertical",
                other => anyhow::bail!("unsupported layout split direction {other:?}"),
            };
            Ok(json!({
                "kind": "split",
                "split_id": split,
                "direction": direction,
                "ratio": f64::from(*ratio),
                "first": public_layout_node(first, tabs_by_pane, panes_by_id)?,
                "second": public_layout_node(second, tabs_by_pane, panes_by_id)?,
            }))
        }
        RegistryLayoutNode::Stack { panes, expanded } => Ok(json!({
            "kind": "stack",
            "pane_ids": panes,
            "expanded_pane_id": expanded,
        })),
    }
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
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use crate::resource::{ScreenPublicId, SplitPublicId, TabPublicId, WorkspacePublicId};
    use crate::workspace_registry::RegistryViewportColumn;

    fn resource_request(
        mux: &Arc<Mux>,
        id: &str,
        operation: &str,
        params: Value,
        idempotency_key: Option<&str>,
    ) -> Value {
        let mut request = json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":id,
            "operation":operation,
            "params":params,
        });
        if let Some(idempotency_key) = idempotency_key {
            request["idempotency_key"] = Value::String(idempotency_key.to_string());
        }
        crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap()
    }

    #[test]
    fn local_machine_service_exposes_only_public_opaque_ids() {
        let mux = Mux::new_for_test("dev", SurfaceOptions::default());
        let service = LocalResourceMachineService::new(Arc::downgrade(&mux));
        let result = service
            .dispatch(&ResourceMachineRequest {
                operation: ResourceOperation::MachineList,
                selectors: ResourceSelectors::default(),
                fields: Map::new(),
                idempotency_key: None,
            })
            .unwrap();
        let machine = &result.as_array().unwrap()[0];
        assert!(machine["id"].as_str().unwrap().starts_with("machine_"));
        assert!(machine.get("key").is_none());
        assert!(machine.get("socket").is_none());
    }

    #[test]
    fn injected_machine_service_is_the_router_boundary() {
        struct Fake;

        impl ResourceMachineService for Fake {
            fn dispatch(&self, request: &ResourceMachineRequest) -> Result<Value, ResourceError> {
                Ok(json!({"operation":request.operation}))
            }
        }

        let mux = Mux::new_for_test("dev", SurfaceOptions::default());
        mux.install_resource_machine_service(Arc::new(Fake)).unwrap();
        let result = mux
            .resource_machine_service()
            .dispatch(&ResourceMachineRequest {
                operation: ResourceOperation::MachineList,
                selectors: ResourceSelectors::default(),
                fields: Map::new(),
                idempotency_key: None,
            })
            .unwrap();
        assert_eq!(result, json!({"operation":"machine.list"}));
        assert!(mux.install_resource_machine_service(Arc::new(Fake)).is_err());
    }

    #[test]
    fn empty_session_snapshot_contains_only_public_identity_shapes() {
        let mux = Mux::new_for_test("dev", SurfaceOptions::default());
        let snapshot = public_session_snapshot(&mux).unwrap();
        assert!(snapshot["machine"]["id"].as_str().unwrap().starts_with("machine_"));
        assert!(snapshot["session"]["id"].as_str().unwrap().starts_with("session_"));
        assert_eq!(snapshot["workspaces"], json!([]));
        assert_eq!(snapshot["cursor"]["revision"], "0");
        assert!(snapshot.get("surface").is_none());
        assert!(snapshot.get("workspace_key").is_none());
    }

    #[test]
    fn snapshot_uses_durable_terminal_state_before_runtime_adoption() {
        let mux = Mux::new_for_test("snapshot-before-adoption", SurfaceOptions::default());
        let surface = mux.new_workspace(Some("restoring".into()), None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().unwrap();

        mux.remove_surface_runtime_for_test(surface.id).unwrap();
        mux.remove_terminal_catalog_for_test(&terminal_id).unwrap();

        let snapshot = public_session_snapshot(&mux).unwrap();
        let terminal = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .expect("durable terminal remains visible while its runtime is not adopted");
        assert_eq!(terminal["cols"], 80);
        assert_eq!(terminal["rows"], 24);
        assert_eq!(terminal["lifecycle"], "running");

        // The daemon owns terminal lifecycle. A renderer snapshot must expose
        // each durable terminal exactly once even when its runtime is absent.
        let terminal_ids = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .map(|terminal| terminal["id"].as_str().expect("terminal id"))
            .collect::<HashSet<_>>();
        assert_eq!(terminal_ids.len(), snapshot["terminals"].as_array().unwrap().len());
    }

    #[test]
    fn snapshot_keeps_exited_terminal_receipt_after_its_last_view_detaches() {
        let mux = Mux::new_for_test("snapshot-exited-receipt", SurfaceOptions::default());
        let surface = mux.new_workspace(Some("exiting".into()), None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().unwrap();

        mux.surface_exited(surface.id);

        let snapshot = public_session_snapshot(&mux).unwrap();
        let terminal = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .expect("durable exit receipt remains publicly addressable until terminal.close");
        assert_eq!(terminal["lifecycle"], "exited");
        assert_eq!(terminal["tab_id"], Value::Null);
        assert_eq!(terminal["tab_ids"], json!([]));
        assert!(terminal["exit"].is_object());
        mux.shutdown();
    }

    #[test]
    fn snapshot_cursor_and_auxiliary_values_share_one_durable_cut() {
        let mux = Mux::new_for_test("snapshot-cut", SurfaceOptions::default());
        let created = resource_request(
            &mux,
            "create",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"snapshot cut",
                "initial_content":"terminal",
            }),
            Some("snapshot-cut-create"),
        );
        let terminal_id = created["result"]["value"]["terminal_id"].as_str().unwrap().to_string();
        resource_request(
            &mux,
            "agent-old",
            "agent.report",
            json!({
                "machine":"current",
                "session":"current",
                "terminal_id":terminal_id,
                "state":"working",
                "source":"hook",
                "source_session":"before",
            }),
            Some("snapshot-cut-agent-old"),
        );

        let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(0);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(0);
        let snapshot_mux = mux.clone();
        let snapshot_thread = std::thread::spawn(move || {
            set_snapshot_before_projection_hook(move || {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
            });
            public_session_snapshot(&snapshot_mux)
        });
        entered_rx.recv().unwrap();

        let agent = resource_request(
            &mux,
            "agent-new",
            "agent.report",
            json!({
                "machine":"current",
                "session":"current",
                "terminal_id":terminal_id,
                "state":"done",
                "source":"hook",
                "source_session":"after",
            }),
            Some("snapshot-cut-agent-new"),
        );
        let notification = resource_request(
            &mux,
            "notification",
            "notification.create",
            json!({
                "machine":"current",
                "session":"current",
                "title":"new durable notification",
                "body":"after snapshot entered",
                "level":"info",
                "terminal_id":terminal_id,
            }),
            Some("snapshot-cut-notification"),
        );
        resource_request(
            &mux,
            "defaults",
            "session.terminal_defaults.update",
            json!({
                "machine":"current",
                "session":"current",
                "foreground":"#123456",
                "complete":true,
            }),
            Some("snapshot-cut-defaults"),
        );
        let projection = resource_request(
            &mux,
            "projection",
            "frontend_projection.put",
            json!({
                "machine":"current",
                "session":"current",
                "frontend_projection":"projection_00000000000000000000000000000001",
                "frontend_id":"cmux-test",
                "window_id":"window-snapshot-cut",
                "generation":"launch-snapshot-cut",
                "projection":{"cut":"after"},
            }),
            Some("snapshot-cut-projection"),
        );
        let expected_revision = projection["result"]["revision"].clone();

        release_tx.send(()).unwrap();
        let snapshot = snapshot_thread.join().unwrap().unwrap();
        assert_eq!(snapshot["cursor"]["revision"], expected_revision);
        assert_eq!(snapshot["session"]["revision"], expected_revision);
        assert!(snapshot["agents"].as_array().unwrap().contains(&agent["result"]["value"]));
        assert!(
            snapshot["notifications"]
                .as_array()
                .unwrap()
                .contains(&notification["result"]["value"])
        );
        assert!(
            snapshot["frontend_projections"]
                .as_array()
                .unwrap()
                .contains(&projection["result"]["value"])
        );
    }

    #[test]
    fn layout_projection_preserves_nested_splits_stacks_and_viewport_columns() {
        let workspace_id = public_id::<WorkspacePublicId>("ws", 1);
        let screen_id = public_id::<ScreenPublicId>("screen", 2);
        let pane_a = public_id::<PanePublicId>("pane", 3);
        let pane_b = public_id::<PanePublicId>("pane", 4);
        let pane_c = public_id::<PanePublicId>("pane", 5);
        let tab_a = public_id::<TabPublicId>("tab", 6);
        let split_a = public_id::<SplitPublicId>("split", 7);
        let split_b = public_id::<SplitPublicId>("split", 8);
        let column_a = public_id::<SplitPublicId>("split", 9);
        let column_b = public_id::<SplitPublicId>("split", 10);
        let nested = RegistryLayoutNode::Split {
            split: split_a,
            direction: "right".into(),
            ratio: 0.4,
            first: Box::new(RegistryLayoutNode::Leaf { pane: pane_a.clone() }),
            second: Box::new(RegistryLayoutNode::Split {
                split: split_b,
                direction: "right".into(),
                ratio: 0.6,
                first: Box::new(RegistryLayoutNode::Leaf { pane: pane_b.clone() }),
                second: Box::new(RegistryLayoutNode::Stack {
                    panes: vec![pane_c.clone()],
                    expanded: pane_c.clone(),
                }),
            }),
        };
        let screen = RegistryScreen {
            public_id: screen_id.clone(),
            workspace_id,
            position: 0,
            name: Some("layout".into()),
            layout: nested.clone(),
            active_pane: pane_b.clone(),
            zoomed_pane: Some(pane_c.clone()),
            auto_layout: None,
            viewport: RegistryViewport {
                base_width: Some(0.4),
                columns: vec![
                    RegistryViewportColumn {
                        id: column_a.clone(),
                        width: 0.4,
                        layout: nested,
                        auto_layout: None,
                    },
                    RegistryViewportColumn {
                        id: column_b.clone(),
                        width: 0.6,
                        layout: RegistryLayoutNode::Stack {
                            panes: vec![pane_c.clone()],
                            expanded: pane_c.clone(),
                        },
                        auto_layout: None,
                    },
                ],
            },
        };
        let panes = [
            RegistryPane {
                public_id: pane_a.clone(),
                screen_id: screen_id.clone(),
                name: None,
                active_tab: Some(tab_a.clone()),
                creation_ordinal: 0,
            },
            RegistryPane {
                public_id: pane_b,
                screen_id: screen_id.clone(),
                name: None,
                active_tab: None,
                creation_ordinal: 1,
            },
            RegistryPane {
                public_id: pane_c.clone(),
                screen_id,
                name: None,
                active_tab: None,
                creation_ordinal: 2,
            },
        ];
        let tabs = vec![RegistryTab {
            public_id: tab_a.clone(),
            pane_id: pane_a,
            position: 0,
            content_id: ContentPublicId::Terminal(TerminalPublicId::random().unwrap()),
            name: None,
            browser_url: None,
            terminal_id: Some("hosted".into()),
        }];
        let tabs_by_pane = tabs_by_pane(&tabs);
        let panes_by_id =
            panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
        let layout = public_layout_document(&screen, &tabs_by_pane, &panes_by_id).unwrap();

        assert_eq!(layout["active_pane_id"], json!(screen.active_pane));
        assert_eq!(layout["zoomed_pane_id"], json!(pane_c));
        assert_eq!(layout["root"]["kind"], "viewport");
        assert_eq!(layout["root"]["columns"][0]["column_id"], json!(column_a));
        assert_eq!(layout["root"]["columns"][1]["column_id"], json!(column_b));
        assert_eq!(layout["root"]["columns"][0]["root"]["second"]["kind"], "split");
        assert_eq!(layout["root"]["columns"][0]["root"]["first"]["tab_ids"], json!([tab_a]));
        assert_eq!(layout["root"]["columns"][1]["root"]["kind"], "stack");
    }

    fn public_id<T>(prefix: &str, value: u128) -> T
    where
        T: serde::de::DeserializeOwned,
    {
        serde_json::from_value(json!(format!("{prefix}_{value:032x}"))).unwrap()
    }
}
