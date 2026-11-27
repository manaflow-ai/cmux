//! Transport-independent machine routing for `cmux.protocol/2`.
//!
//! The session mux owns local terminal state. Machine catalogs and providers
//! live in the outer runtime, so the public router crosses this injected
//! boundary instead of importing provider implementation details into core.

use cmux_json::JsonSet as _;

#[cfg(test)]
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::Weak;

mod committed_snapshot;
#[cfg(test)]
pub(crate) use committed_snapshot::{
    decorated_snapshot_values_for_test, retained_public_bytes_for_test,
    undecorated_snapshot_values_for_test,
};
mod machines;
pub(crate) mod scoped_get;
mod terminal_extra;

pub(crate) const MACHINE_CATALOG_READ_CAPABILITY: &str = "machine-catalog-read-v1";

use anyhow::Context;
use serde_json::{Map, Value, json};

use crate::resource::{
    ContentPublicId, FrontendProjectionPublicId, MachinePublicId, PanePublicId, ResourceError,
    ResourceOperation, ScreenPublicId, Selector, SessionPublicId, TabPublicId, TerminalPublicId,
    WorkspacePublicId,
};
use crate::resource_screen::{panes_by_id, public_screen_value, tabs_by_pane};
use crate::sidebar_resource::{sidebar_snapshot, sidebar_view_id};
use crate::workspace_registry::{
    FrontendProjection, RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserSource,
    RegistryBrowserStatus, RegistryTab, RegistryTerminal, ResourceEffectOutcome,
    ResourceEffectPreparation, TerminalLifecycle,
};
use crate::{Mux, ResourceSelectors};

pub(crate) use committed_snapshot::CommittedSnapshots;
#[cfg(test)]
pub(crate) use committed_snapshot::{
    route_wait_times_on_this_thread, route_waits_on_this_thread,
    set_live_terminal_hook_on_this_thread, set_route_wait_start_hook_on_this_thread,
};

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
thread_local! {
    /// Runs once on this thread, in the next snapshot read, after the read loaded its route tables and before
    /// it walks them: a test changes the session under a read that already holds its routes.
    static SNAPSHOT_AFTER_ROUTES_HOOK: RefCell<Option<Box<dyn FnOnce()>>> = RefCell::new(None);
}

#[cfg(test)]
pub(crate) fn set_snapshot_after_routes_hook(hook: impl FnOnce() + 'static) {
    SNAPSHOT_AFTER_ROUTES_HOOK.with(|slot| {
        *slot.borrow_mut() = Some(Box::new(hook));
    });
}

#[cfg(test)]
fn run_snapshot_after_routes_hook() {
    let hook = SNAPSHOT_AFTER_ROUTES_HOOK.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook();
    }
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
    /// The session journal head at this read (`session-journal.md`, "Session
    /// list rows"). A viewer holds a row's "new" state and notifications while
    /// its own journal cursor for the session is below it.
    pub journal_head: u64,
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
        let catalog = request.fields.get("catalog") == Some(&Value::Bool(true));
        match request.operation {
            ResourceOperation::MachineList => {
                require_no_selectors(&request.selectors)?;
                let mut machines = vec![machine_snapshot(&context, catalog)];
                if catalog {
                    machines.extend(self.remote_machine_snapshots());
                }
                Ok(json!(machines))
            }
            ResourceOperation::MachineGet => {
                if catalog && resolve_local_machine(&request.selectors, &context).is_err() {
                    return self.remote_machine_snapshot(&request.selectors);
                }
                resolve_local_machine(&request.selectors, &context)?;
                Ok(machine_snapshot(&context, catalog))
            }
            ResourceOperation::SessionList => {
                resolve_local_machine(&request.selectors, &context)?;
                require_absent(
                    &request.selectors.session,
                    "session",
                    "session.list does not select one session",
                )?;
                Ok(json!([session_list_row(&context)]))
            }
            ResourceOperation::SessionGet => {
                resolve_local_session(&request.selectors, &context)?;
                Ok(session_list_row(&context))
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
            mux.report_resource_effect_indeterminate(key, "session.open", EARLIER_ATTEMPT_CAUSE);
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
                .map_err(|error| {
                    mux.report_resource_effect_indeterminate(
                        key,
                        "session.open",
                        &format!("the outcome commit failed: {error:#}"),
                    );
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

/// Cause logged when a request replays a key whose earlier attempt left an
/// indeterminate outcome.
pub(crate) const EARLIER_ATTEMPT_CAUSE: &str =
    "an earlier attempt with this key has an indeterminate outcome";

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

fn machine_snapshot(context: &LocalResourceContext, catalog: bool) -> Value {
    let mut machine = json!({
        "id": context.machine_id,
        "name": "local",
        "origin": "local",
        "status": "running",
        "connectable": true,
        "deleted": false,
        "recoverable": false,
    });
    if catalog {
        // Strict older SDKs reject these fields, even on a local record.
        // The reader opts in; this metadata grants no execution authority.
        machine.set("platform", machine_platform());
        machine.set("capabilities", machine_capabilities());
    }
    machine
}

pub(crate) fn machine_platform() -> Value {
    json!({
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
    })
}

pub(crate) fn machine_capabilities() -> Value {
    json!(["terminal", "workspace", "agent_session"])
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

/// A `session.list` / `session.get` row: the snapshot and the journal head of
/// the read (`session-journal.md`, "Session list rows"). In `extra`, not a
/// sibling field: an SDK that predates it rejects unknown siblings but keeps
/// `extra` (`SessionSnapshot` in resource-operations-v2.json). Decimal, like
/// every journal cursor. The full `session.snapshot` leaves it out: its cut
/// already names its own cursor.
fn session_list_row(context: &LocalResourceContext) -> Value {
    let mut row = session_snapshot(context);
    if let Some(fields) = row.as_object_mut() {
        fields.insert(
            "extra".to_owned(),
            json!({"journal_head_sequence": context.journal_head.to_string()}),
        );
    }
    row
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
        terminal.set("stream_revision", json!(revision.to_string()));
    }
    if let Some(cwd) = surface.and_then(crate::Surface::presented_directory) {
        terminal.set("cwd", json!(cwd));
    }
    let extra = terminal_extra::extra(surface, durable.lifecycle == TerminalLifecycle::Running);
    if !extra.is_empty() {
        terminal.set("extra", Value::Object(extra));
    }
    // `terminal-exit-status-v1`: the last command the shell finished (OSC
    // 133 D), with its exit code when the shell sent one. Absent without
    // shell integration, so a missing field never reads as success.
    if durable.lifecycle == TerminalLifecycle::Running
        && let Some(last) = surface.and_then(crate::Surface::terminal_last_command)
    {
        terminal["extra"] = json!({
            "last_command": crate::terminal_command::last_command_json(last),
        });
    }
    if durable.lifecycle == TerminalLifecycle::Exited {
        terminal.set(
            "exit",
            durable.exit.clone().context("exited terminal omitted its durable outcome")?,
        );
    } else {
        debug_assert!(
            durable.exit.is_none(),
            "non-exited terminal unexpectedly has a durable outcome"
        );
    }
    Ok(terminal)
}

pub(crate) fn public_session_snapshot(mux: &Mux) -> Result<Value, ResourceError> {
    session_snapshot_with_journal_head(mux, true).map(|(snapshot, _)| snapshot)
}

/// Returns the public session snapshot together with the session journal head
/// of the same committed revision (one read transaction, `committed_snapshot.rs`;
/// no registry lock, and no state lock but one try by the first read after a
/// commit). The pair is one consistent cut: every
/// journal record at or below the returned head is reflected in the durable
/// rows of the snapshot, and every later record is not. Checkpoint capture
/// keys its consistency fence to this cut so a journal write that merely
/// precedes the cut cannot spuriously abort the capture. The live values
/// (terminal and browser runtime) are those of the published route tables at
/// the time of the read: they are not part of the cut, but they are never
/// older than a commit the rows show.
///
/// A checkpoint is written to disk, so this snapshot leaves out what the daemon
/// keeps in memory only (`mux/agent_prompts.rs`): an agent's last reply
/// (`extra.last_reply`) and a terminal's last harness session
/// (`extra.agent_session_id`).
pub(crate) fn public_session_snapshot_with_journal_head(
    mux: &Mux,
) -> Result<(Value, u64), ResourceError> {
    session_snapshot_with_journal_head(mux, false)
}

/// The snapshot of [`public_session_snapshot_with_journal_head`]; `memory_only`
/// adds the values the daemon keeps in memory only, for a read that is not stored.
fn session_snapshot_with_journal_head(
    mux: &Mux,
    memory_only: bool,
) -> Result<(Value, u64), ResourceError> {
    // No pending terminal directory is published here: a read runs no
    // write. Terminal output, resize, reconnect and every committed graph
    // change publish a pending one (`publish_resource_event`).
    // Collect the auxiliary runtime first, as the read did when it held the
    // registry + state projection lock (sidebar status locks its own
    // lifecycle and then looks up a surface).
    let (sidebar_status, sidebar_last_size, sidebar_configured) =
        mux.sidebar_plugin_resource_status();
    let sidebar_surface = sidebar_status.surface.and_then(|surface| mux.surface(surface));
    // Taken before the walk, like the sidebar status (memory only).
    let (last_replies, last_sessions) = if memory_only {
        (mux.agent_last_replies(), mux.agent_last_sessions())
    } else {
        (HashMap::new(), HashMap::new())
    };
    // Taken before the projection lock, like the sidebar status (memory only).
    let last_sessions = mux.agent_last_sessions();
    #[cfg(test)]
    run_snapshot_before_projection_hook();
    // No registry lock and no state lock across this walk: the durable rows are one committed revision
    // (`committed_snapshot.rs`), the live surfaces are the published route tables, loaded after the rows and
    // never older than a commit of the rows that changed a route in its state hold.
    (|| -> anyhow::Result<(Value, u64)> {
        let committed = committed_snapshot::committed_snapshot(mux)?;
        let routes = mux.published_routes()?;
        #[cfg(test)]
        run_snapshot_after_routes_hook();
        let browser_surfaces = routes.browser_surfaces_by_content();
        let journal_head = committed.rows.journal_head;
        let topology = &committed.rows.topology;
        let terminal_registry = &committed.rows.terminals;
        let terminal_resource_ids = &committed.rows.terminal_resource_ids;
        let public_projections = committed.rows.projections.clone();
        let context = LocalResourceContext {
            machine_id: mux.machine_public_id.clone(),
            session_id: mux.session_public_id.clone(),
            session_name: mux.session.clone(),
            generation: topology.generation.clone(),
            revision: topology.revision,
            journal_head,
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

<<<<<<< ours
        // One builder for the snapshot and `terminal.list` (`public_terminal_values`). The live surface of a
        // terminal is its routed runtime, from the published table, read with no lock. The identity of an
        // in-process runtime is in a table of the mux, which a close purges after it releases the state
        // guard (`purge_terminal_runtime_side_tables`) and which the first view of an app terminal fills
        // after its row commits (`finish_app_terminal_first_view`). A routed runtime with no identity is
        // thus one that closes or gets its first view under this read: it gives no live values (the durable
        // row still shows) and it never fails the whole snapshot, which every client shows as "machine
        // unreachable". The identity is read ONE time, here, and the builder checks that same value: a close
        // after this read cannot fail the snapshot, however many terminals close under one read.
        let live_terminal = |terminal_id: &TerminalPublicId| {
            let routed = routes.catalog_terminal(terminal_id)?;
            let Some(host) = mux.resource_terminal_host_identity(routed) else {
=======
        let tabs_by_pane = tabs_by_pane(&topology.tabs);
        let panes_by_id = panes_by_id(&topology.panes);
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
>>>>>>> theirs
                eprintln!(
                    "cmux-tui: snapshot shows terminal {terminal_id} with no live values: its runtime has no durable identity"
                );
<<<<<<< ours
                return None;
            };
            Some(LiveTerminal { surface: routed.clone(), host: Some(host) })
        };
        let terminals = public_terminal_values(
            &terminal_registry.terminals,
            terminal_resource_ids.clone(),
            &topology.tabs,
            live_terminal,
            &last_sessions,
        )?;
=======
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
                    .map(|terminal| crate::mux::with_agent_session(terminal, &last_sessions))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
>>>>>>> theirs

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
                let surface = match browser_surfaces.get(&tab.content_id).map(Vec::as_slice) {
                    Some([surface]) => Some(*surface),
                    _ => None,
                };
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
                    snapshot.set("terminal_id", json!(terminal_id));
                }
                if let Some(subtitle) = notification.subtitle {
                    snapshot.set("subtitle", json!(subtitle));
                }
                snapshot.set("extra", json!({"source": notification.source.as_str()}));
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
            .map(|agent| crate::mux::with_last_reply(agent, &last_replies))
            .map(|agent| crate::mux::with_kept_session(agent, &last_sessions))
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

        // The rows built for this request move in; `json!` would copy each of
        // them (a deep copy of every terminal, notification and agent value).
        // The committed parts are parsed from the compact text the cached
        // snapshot keeps. A map's keys serialize sorted, so the reply bytes do
        // not change.
        let mut snapshot = json!({
            "machine": machine_snapshot(&context, false),
            "session": session_snapshot(&context),
            "clients": [],
            "cursor": {
                "generation": topology.generation,
                "revision": topology.revision.to_string(),
            },
        });
        for (name, part) in [
            ("workspaces", &committed.workspaces),
            ("screens", &committed.screens),
            ("panes", &committed.panes),
            ("tabs", &committed.tabs),
        ] {
            snapshot.set(name, part.value()?);
        }
        for (name, rows) in [
            ("terminals", terminals),
            ("browsers", browsers),
            ("notifications", notifications),
            ("agents", agents),
            ("frontend_projections", frontend_projections),
            ("sidebar_views", sidebar_views),
        ] {
            snapshot.set(name, Value::Array(rows));
        }
        let state = committed.state.value()?;
        snapshot.set("extra", Value::Object(Map::from_iter([("state".into(), state)])));
        Ok((snapshot, journal_head))
    })()
    .map_err(operation_failed)
}

/// The public workspaces before decoration, in session order: one builder
/// for the session snapshot and the workspace list.
fn public_workspace_values(
    registry_snapshot: &crate::workspace_registry::RegistrySnapshot,
    topology: &crate::workspace_registry::ResourceTopologySnapshot,
) -> anyhow::Result<Vec<Value>> {
    registry_snapshot
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
                "extra": crate::resource_name::workspace_name_extra(
                    workspace.name_source,
                    workspace.name_revision,
                ),
            }))
        })
        .collect()
}

<<<<<<< ours
/// The session snapshot's `terminals`, in its order: each terminal that a
/// tab shows, in the tabs' order, then each other live terminal in creation
/// order. `tabs` are the session's tabs in the full load's order (a tab of
/// other content is skipped); `live_of` gives a terminal's live surface with
/// the durable identity of that runtime. The builder does not read the
/// identity again: a terminal that closes under the read cannot change it
/// between two reads.
/// One builder for the session snapshot and the terminal list.
fn public_terminal_values(
    durable_terminals: &[RegistryTerminal],
    terminal_resource_ids: Vec<(String, TerminalPublicId)>,
    tabs: &[RegistryTab],
    live_of: impl Fn(&TerminalPublicId) -> Option<LiveTerminal>,
    last_sessions: &HashMap<String, (String, Option<String>)>,
) -> anyhow::Result<Vec<Value>> {
    let terminals_by_id = durable_terminals
        .iter()
        .map(|terminal| (terminal.terminal_id.as_str(), terminal))
        .collect::<HashMap<_, _>>();
    let terminal_resources_by_host =
        terminal_resource_ids.iter().cloned().collect::<HashMap<_, _>>();
    let terminal_hosts_by_resource = terminal_resource_ids
        .into_iter()
        .map(|(host_id, terminal_id)| (terminal_id, host_id))
        .collect::<HashMap<_, _>>();

    let mut terminal_order = Vec::new();
    let mut seen_terminals = HashSet::new();
    for tab in tabs {
        if let ContentPublicId::Terminal(terminal_id) = &tab.content_id {
            if seen_terminals.insert(terminal_id.clone()) {
                terminal_order.push(terminal_id.clone());
            }
            let host_id = terminal_hosts_by_resource
                .get(terminal_id)
                .with_context(|| format!("terminal {terminal_id} omitted its durable identity"))?;
            if let Some(tab_host_id) = &tab.terminal_id {
                anyhow::ensure!(
                    tab_host_id == host_id,
                    "terminal {terminal_id} references a mismatched durable host"
                );
            }
        }
    }
    let mut tab_ids_by_terminal =
        terminal_tab_ids_in_canonical_order(tabs.iter().filter_map(|tab| match &tab.content_id {
            ContentPublicId::Terminal(terminal_id) => Some((
                terminal_id.clone(),
                tab.pane_id.clone(),
                tab.position,
                tab.public_id.clone(),
            )),
            ContentPublicId::Browser(_) => None,
        }));
    for durable in durable_terminals {
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

    terminal_order
        .into_iter()
        .map(|terminal_id| {
            let live = live_of(&terminal_id);
            #[cfg(test)]
            if let Some(live) = &live {
                committed_snapshot::run_live_terminal_hook(&live.surface);
            }
            let host_id = terminal_hosts_by_resource
                .get(&terminal_id)
                .with_context(|| format!("terminal {terminal_id} omitted its durable identity"))?;
            if let Some(live) = &live {
                let runtime_host = live.host.as_ref().with_context(|| {
                    format!("terminal {terminal_id} runtime omitted its durable identity")
                })?;
                anyhow::ensure!(
                    runtime_host.terminal_id == *host_id,
                    "terminal {terminal_id} runtime references a mismatched durable host"
                );
            }
            let durable = terminals_by_id
                .get(host_id.as_str())
                .with_context(|| format!("terminal {terminal_id} references missing {host_id}"))?;
            let tab_ids = tab_ids_by_terminal.remove(&terminal_id).unwrap_or_default();
            let surface = live.as_ref().map(|live| &*live.surface);
            public_terminal_snapshot(&terminal_id, durable, surface, tab_ids)
                .map(|terminal| crate::mux::with_agent_session(terminal, last_sessions))
        })
        .collect()
}

/// A terminal's live surface and the durable identity of that runtime, read
/// one time by the caller of [`public_terminal_values`]. `host` is `None`
/// for a runtime with no identity, which the builder refuses.
struct LiveTerminal {
    surface: Arc<crate::Surface>,
    host: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
}

impl LiveTerminal {
    fn read(mux: &Mux, surface: &Arc<crate::Surface>) -> Self {
        Self { surface: surface.clone(), host: mux.resource_terminal_host_identity(surface) }
    }
}

/// The stored rows a terminal list is built from: the terminal rows, each
/// live terminal resource with its host, and the terminal tabs.
type TerminalListRows = (Vec<RegistryTerminal>, Vec<(String, TerminalPublicId)>, Vec<RegistryTab>);

fn load_terminal_list_rows(connection: &rusqlite::Connection) -> anyhow::Result<TerminalListRows> {
    Ok((
        crate::workspace_registry::load_terminal_rows(connection)?,
        crate::workspace_registry::load_live_terminal_resource_ids(connection)?,
        crate::workspace_registry::load_terminal_tabs(connection)?,
    ))
}

/// The session snapshot's `terminals`, built alone (`terminal.list` with no
/// scope): the same values in the same order. At 826 workspaces the whole
/// snapshot held the registry lock and the state lock for each `terminal
/// list` of a script or an agent. This reads the stored rows as one
/// committed read (no registry lock on a file registry), takes the state
/// lock one time to copy each terminal's live surface handle, and builds the
/// values with no lock held. A surface that changes after the read gives its
/// newer live fields (title, size, directory), as it does to a list that
/// runs a moment later.
pub(crate) fn public_terminals(mux: &Mux) -> Result<Vec<Value>, ResourceError> {
    // Memory only, as in the snapshot: not under a session lock.
    let last_sessions = mux.agent_last_sessions();
    let (durable_terminals, terminal_resource_ids, tabs) =
        read_committed_registry(mux, |connection, _| load_terminal_list_rows(connection))
            .map_err(operation_failed)?;
    let surfaces = mux.with_state(|state| {
        terminal_resource_ids
            .iter()
            .filter_map(|(_, terminal_id)| {
                let surface = state.terminal_catalog.get(terminal_id)?;
                Some((terminal_id.clone(), surface.clone()))
            })
            .collect::<HashMap<_, _>>()
    });
    if let Ok(terminals) = public_terminal_values(
        &durable_terminals,
        terminal_resource_ids,
        &tabs,
        |terminal_id| surfaces.get(terminal_id).map(|surface| LiveTerminal::read(mux, surface)),
        &last_sessions,
    ) {
        return Ok(terminals);
    }
    // The rows and the surfaces are two cuts. A terminal that ended between
    // them (its runtime gave up its durable identity while this list held
    // its handle) fails the identity checks of the builder. Read the two as
    // one cut, under the registry and state locks, as the snapshot does: a
    // real mismatch gives the snapshot's error.
    mux.with_resource_projection(|registry, state| {
        let (durable_terminals, terminal_resource_ids, tabs) =
            registry.read_state(load_terminal_list_rows)?;
        public_terminal_values(
            &durable_terminals,
            terminal_resource_ids,
            &tabs,
            |terminal_id| {
                state
                    .terminal_catalog
                    .get(terminal_id)
                    .map(|surface| LiveTerminal::read(mux, surface))
            },
            &last_sessions,
        )
    })
    .map_err(operation_failed)
}

/// The session snapshot's `panes`, built alone (`pane.list` with no scope):
/// the same values in the same order, from the stored screens and panes as
/// one committed read. It reads no tabs, terminals, browsers, notifications,
/// agents or live state, and takes no registry lock (on a file registry) and
/// no state lock.
pub(crate) fn public_panes(mux: &Mux) -> Result<Vec<Value>, ResourceError> {
    read_committed_registry(mux, |connection, ids| {
        let topology = crate::workspace_registry::load_session_panes(
            connection,
            ids.session_id.clone(),
            ids.generation.clone(),
        )?;
        let screens_by_id = topology
            .screens
            .iter()
            .map(|screen| (&screen.public_id, screen))
            .collect::<HashMap<_, _>>();
        public_pane_values(&topology, &screens_by_id)
    })
    .map_err(operation_failed)
}

/// The session snapshot's `tabs`, built alone (`tab.list` with no scope):
/// the same decorated values in the same order, from the stored panes and
/// tabs as one committed read. It reads no screens, terminal hosts,
/// notifications, agents or live state, and takes no registry lock (on a
/// file registry) and no state lock.
pub(crate) fn public_tabs(mux: &Mux) -> Result<Vec<Value>, ResourceError> {
    read_committed_registry(mux, |connection, ids| {
        let topology = crate::workspace_registry::load_session_tabs(
            connection,
            ids.session_id.clone(),
            ids.generation.clone(),
        )?;
        let panes_by_id =
            topology.panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
        let mut tabs = public_tab_values(&topology, &panes_by_id)?;
        // One statement set for the list: each state table is read one time,
        // not one time for each tab.
        crate::state::values::decorate_session_tabs(connection, &mut tabs)?;
        Ok(tabs)
    })
    .map_err(operation_failed)
}

/// The session snapshot's `workspaces`, built alone (`workspace.list`, the
/// list agents' CLI calls make most): the same decorated values, from the
/// workspace rows and the topology frame. It reads no screens, panes, tabs,
/// terminals, notifications, agents or live state, and holds only the
/// registry lock, not state.
pub(crate) fn public_workspaces(mux: &Mux) -> Result<Vec<Value>, ResourceError> {
    read_committed_registry(mux, |connection, ids| {
        let registry_snapshot = crate::workspace_registry::registry_snapshot_in(
            connection,
            &ids.registry_id,
            &ids.generation,
            &ids.session_id,
        )?;
        let frame = crate::workspace_registry::load_topology_frame(
            connection,
            ids.session_id.clone(),
            ids.generation.clone(),
        )?;
        anyhow::ensure!(
            registry_snapshot.generation == frame.generation
                && registry_snapshot.resource_revision == frame.revision,
            "resource projection changed while listing workspaces"
        );
        let mut workspaces = public_workspace_values(&registry_snapshot, &frame)?;
        crate::state::values::decorate_workspaces(connection, &mut workspaces)?;
        Ok(workspaces)
    })
    .map_err(operation_failed)
}

/// What a committed registry read needs besides its connection.
pub(crate) struct RegistryReadIds {
    registry_id: String,
    generation: String,
    session_id: SessionPublicId,
}

/// Run `read` on committed registry rows, in one read transaction (one
/// consistent cut: no writer commit lands between its statements). On a
/// file registry it reads the read-only WAL connection and takes no
/// registry lock, so a writer that holds the lock across its commit (a
/// state mutation: 281 ms max under the L1 storm, STATUS 6838) never
/// delays a list or a ping. An in-memory registry has no reader: the read
/// runs on the registry's own connection under its lock, as before.
pub(crate) fn read_committed_registry<T>(
    mux: &Mux,
    read: impl FnOnce(&rusqlite::Connection, &RegistryReadIds) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let (registry_id, generation) = mux.registry_identity();
    let ids =
        RegistryReadIds { registry_id, generation, session_id: mux.session_public_id.clone() };
    let mut read = Some(read);
    let committed = mux.registry_connection.read_committed(|connection| {
        let Some(read) = read.take() else { anyhow::bail!("committed registry read ran twice") };
        let transaction = connection.unchecked_transaction()?;
        let value = read(&transaction, &ids)?;
        transaction.finish()?;
        Ok(value)
    });
    if let Some(result) = committed {
        return result;
    }
    let Some(read) = read.take() else { anyhow::bail!("committed registry read ran twice") };
    let registry = mux.workspace_registry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let connection = registry.connection.get();
    read(&connection, &ids)
}

/// The public panes and tabs of `topology`, in its order: one builder for
/// the session snapshot and the lists.
fn public_pane_and_tab_values(
    topology: &crate::workspace_registry::ResourceTopologySnapshot,
    screens_by_id: &HashMap<&ScreenPublicId, &crate::workspace_registry::RegistryScreen>,
    panes_by_id: &HashMap<&PanePublicId, &crate::workspace_registry::RegistryPane>,
) -> anyhow::Result<(Vec<Value>, Vec<Value>)> {
    Ok((public_pane_values(topology, screens_by_id)?, public_tab_values(topology, panes_by_id)?))
}

/// The public panes of `topology`, in its order.
fn public_pane_values(
    topology: &crate::workspace_registry::ResourceTopologySnapshot,
    screens_by_id: &HashMap<&ScreenPublicId, &crate::workspace_registry::RegistryScreen>,
) -> anyhow::Result<Vec<Value>> {
    let active_screens = topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
    topology
        .panes
        .iter()
        .map(|pane| {
            let screen = screens_by_id
                .get(&pane.screen_id)
                .ok_or_else(|| anyhow::anyhow!("pane references a missing screen"))?;
            let screen_focused = topology.active_workspace.as_ref() == Some(&screen.workspace_id)
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
        .collect()
}

/// The public tabs of `topology` before decoration, in its order.
fn public_tab_values(
    topology: &crate::workspace_registry::ResourceTopologySnapshot,
    panes_by_id: &HashMap<&PanePublicId, &crate::workspace_registry::RegistryPane>,
) -> anyhow::Result<Vec<Value>> {
    topology
        .tabs
        .iter()
        .map(|tab| {
            let pane = panes_by_id
                .get(&tab.pane_id)
                .ok_or_else(|| anyhow::anyhow!("tab references a missing pane"))?;
            checked_index(tab.position)?;
            Ok(tab.public_value(pane.active_tab.as_ref() == Some(&tab.public_id)))
        })
        .collect()
}

/// The session snapshot's `screens` (id and workspace only), `panes` and
/// `tabs` of one workspace, for a `pane.list` or `tab.list` scoped to a
/// workspace, screen or pane (CLI-1): the same values in the same order,
/// from the workspace's stored subtree. It reads no other workspace, no
/// terminals, projections or journal, and holds only the registry lock, not
/// state, so a list costs the workspace's size, not the session's.
pub(crate) fn public_workspace_topology(
    mux: &Mux,
    workspace: &WorkspacePublicId,
) -> Result<Value, ResourceError> {
    read_committed_registry(mux, |connection, ids| {
        let mut topology = crate::workspace_registry::load_resource_topology_scoped(
            connection,
            ids.session_id.clone(),
            ids.generation.clone(),
            std::slice::from_ref(workspace),
        )?;
        // The full load's order (topology_load.rs): panes by screen id, then
        // creation; tabs by pane id, then position. The scoped load walks
        // screens by position, so sort to match.
        topology.panes.sort_by(|left, right| {
            (&left.screen_id, left.creation_ordinal, &left.public_id).cmp(&(
                &right.screen_id,
                right.creation_ordinal,
                &right.public_id,
            ))
        });
        topology.tabs.sort_by(|left, right| {
            (&left.pane_id, left.position).cmp(&(&right.pane_id, right.position))
        });
        let screens_by_id = topology
            .screens
            .iter()
            .map(|screen| (&screen.public_id, screen))
            .collect::<HashMap<_, _>>();
        let panes_by_id =
            topology.panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
        let (panes, mut tabs) =
            public_pane_and_tab_values(&topology, &screens_by_id, &panes_by_id)?;
        for tab in &mut tabs {
            crate::state::values::decorate_value(connection, "tab", tab)?;
        }
        let screens = topology
            .screens
            .iter()
            .map(|screen| json!({"id": screen.public_id, "workspace_id": screen.workspace_id}))
            .collect::<Vec<_>>();
        Ok(json!({"screens": screens, "panes": panes, "tabs": tabs}))
    })
    .map_err(operation_failed)
}

/// The session snapshot's `cursor` alone (`session.ping`): the registry
/// generation and the committed resource revision. The revision is one meta
/// row, read on the registry's point reader, so a ping waits for no heavy
/// read and walks no workspace (the topology frame it read before walked
/// every workspace for an active-screen list the cursor does not show; its
/// generation is the registry's, as here).
pub(crate) fn public_session_cursor(mux: &Mux) -> Result<Value, ResourceError> {
    let (_, generation) = mux.registry_identity();
    let revision = match mux.registry_connection.committed_resource_revision() {
        Some(revision) => revision,
        None => mux
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .resource_revision(),
    }
    .map_err(operation_failed)?;
    Ok(json!({"generation": generation, "revision": revision.to_string()}))
}

fn checked_index(index: usize) -> anyhow::Result<u32> {
    u32::try_from(index).map_err(|_| anyhow::anyhow!("resource index exceeds uint32"))
}

=======
>>>>>>> theirs
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
<<<<<<< ours
#[path = "resource_api_tests.rs"]
mod tests;
=======
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use crate::resource::{ScreenPublicId, SplitPublicId, TabPublicId, WorkspacePublicId};
    use crate::resource_screen::public_layout_document;
    use crate::workspace_registry::{
        RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryViewport, RegistryViewportColumn,
    };

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
    fn cloud_cwd_snapshot_presents_the_launch_directory_until_the_shell_reports() {
        // https://github.com/manaflow-ai/cmux/issues/10756: the daemon spawned
        // the shell in a known directory, and a shell that has not reported
        // (or never will, without shell integration) still presents it.
        let mux = Mux::new_for_test(
            "cloud-cwd-launch",
            SurfaceOptions { cwd: Some("/tmp".into()), ..SurfaceOptions::default() },
        );
        let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
        let terminal_id = surface.terminal_public_id().unwrap();
        let cwd = |mux: &Mux| {
            public_session_snapshot(mux).unwrap()["terminals"]
                .as_array()
                .unwrap()
                .iter()
                .find(|terminal| terminal["id"] == terminal_id.as_str())
                .unwrap()["cwd"]
                .clone()
        };
        assert_eq!(cwd(&mux), "/tmp");
        // A report replaces the launch directory; an explicit clear removes the
        // directory instead of resurrecting the launch directory.
        surface.set_test_pwd(Some("file://localhost/srv/live".into()));
        assert_eq!(cwd(&mux), "/srv/live");
        surface.set_test_pwd(None);
        assert!(cwd(&mux).is_null());
        mux.shutdown();
    }

    #[test]
    fn cloud_cwd_snapshot_follows_reported_directory_instead_of_launch_directory() {
        let mux = Mux::new_for_test(
            "cloud-cwd",
            SurfaceOptions { cwd: Some("/tmp".into()), ..SurfaceOptions::default() },
        );
        let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
        let terminal_id = surface.terminal_public_id().unwrap();
        for directory in ["/srv/first", "/srv/second"] {
            surface.set_test_pwd(Some(format!("file://localhost{directory}")));
            let snapshot = public_session_snapshot(&mux).unwrap();
            let terminal = snapshot["terminals"]
                .as_array()
                .unwrap()
                .iter()
                .find(|terminal| terminal["id"] == terminal_id.as_str())
                .unwrap();
            assert_eq!(terminal["cwd"], directory);
        }
        mux.shutdown();
    }

    #[test]
    fn cloud_cwd_changes_publish_ordered_terminal_deltas_and_clear_untrusted_reports() {
        let mux = Mux::new_for_test("cloud-cwd-events", SurfaceOptions::default());
        let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
        let initial = public_session_snapshot(&mux).unwrap();
        let mut revision = initial["cursor"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
        for raw in [
            Some("file://localhost/srv/one"),
            Some("file://localhost/srv/two"),
            Some("file://unrelated.invalid/Users/local"),
        ] {
            surface.set_test_pwd(raw.map(str::to_string));
            let snapshot = public_session_snapshot(&mux).unwrap();
            let page = mux.resource_events_after(revision).unwrap();
            assert_eq!(page.batches.len(), 1);
            let batch = &page.batches[0];
            assert_eq!(batch.previous_revision, revision);
            assert_eq!(batch.revision, revision + 1);
            assert_eq!(batch.changes[0]["resource"], "terminal");
            assert_eq!(batch.changes[0]["value"]["cwd"], snapshot["terminals"][0]["cwd"]);
            assert_eq!(batch.changes[0]["value"], snapshot["terminals"][0]);
            assert_eq!(snapshot["tabs"], initial["tabs"]);
            revision = batch.revision;
            let _ = public_session_snapshot(&mux).unwrap();
            assert!(mux.resource_events_after(revision).unwrap().batches.is_empty());
        }
        assert!(public_session_snapshot(&mux).unwrap()["terminals"][0]["cwd"].is_null());
        mux.shutdown();
    }

    #[cfg(unix)]
    #[test]
    fn cloud_cwd_live_osc7_reaches_snapshot_and_event_feed() {
        // `Mux::new_for_test` surfaces never run their command, so these OSC 7
        // tests need the real local PTY runtime.
        let mux = Mux::new(
            "cloud-cwd-osc",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "printf '\\033]7;file://localhost/srv/live\\007'; read value".into(),
                ]),
                ..SurfaceOptions::default()
            },
        );
        let _surface = mux.new_workspace(Some("osc".into()), None).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let epoch = mux.resource_event_epoch();
            let snapshot = public_session_snapshot(&mux).unwrap();
            if snapshot["terminals"][0]["cwd"] == "/srv/live" {
                break;
            }
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!remaining.is_zero(), "OSC 7 cwd never reached the public graph");
            mux.wait_for_resource_event(epoch, remaining);
        }
        assert!(mux.resource_events_after(0).unwrap().batches.iter().any(|batch| {
            batch.changes.as_array().unwrap().iter().any(|change| {
                change["resource"] == "terminal" && change["value"]["cwd"] == "/srv/live"
            })
        }));
        mux.shutdown();
    }

    #[cfg(unix)]
    #[test]
    fn cloud_cwd_live_osc7_clear_reaches_snapshot() {
        // A shell that reports a directory and later reports none (an empty
        // OSC 7, as when it leaves the host it described) must clear the
        // published cwd through the same incremental parser path.
        let mux = Mux::new(
            "cloud-cwd-osc-clear",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "printf '\\033]7;file://localhost/srv/live\\007'; read value; printf '\\033]7;\\007'; read value"
                        .into(),
                ]),
                ..SurfaceOptions::default()
            },
        );
        let surface = mux.new_workspace(Some("osc-clear".into()), None).unwrap();
        let wait_for_cwd = |expected: Option<&str>, message: &str| {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            loop {
                let epoch = mux.resource_event_epoch();
                let cwd = &public_session_snapshot(&mux).unwrap()["terminals"][0]["cwd"];
                let reached = match expected {
                    Some(directory) => cwd == directory,
                    None => cwd.is_null(),
                };
                if reached {
                    break;
                }
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                assert!(!remaining.is_zero(), "{message}");
                mux.wait_for_resource_event(epoch, remaining);
            }
        };
        wait_for_cwd(Some("/srv/live"), "OSC 7 cwd never reached the public graph");
        surface.write_bytes(b"\n").unwrap();
        wait_for_cwd(None, "an empty OSC 7 report never cleared the published cwd");
        mux.shutdown();
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
                "state":"blocked",
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
            name_source: Default::default(),
            name_revision: 0,
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

    #[test]
    fn an_indeterminate_session_open_reports_its_cause_to_the_daemon_log() {
        let mux = Mux::new_for_test("dev", SurfaceOptions::default());
        let diagnostics = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let sink = diagnostics.clone();
        assert!(mux.set_diagnostic_reporter(Arc::new(move |message| {
            sink.lock().unwrap().push(message.to_string());
        })));
        let context = mux.local_resource_context().unwrap();
        let service = LocalResourceMachineService::new(Arc::downgrade(&mux));
        let request = ResourceMachineRequest {
            operation: ResourceOperation::SessionOpen,
            selectors: ResourceSelectors {
                machine: Some(context.machine_id.to_string()),
                session: Some(context.session_id.to_string()),
                ..Default::default()
            },
            fields: Map::new(),
            idempotency_key: Some("session-open-cause".to_string()),
        };
        mux.reject_resource_effect_commits_for_test();

        assert_eq!(service.dispatch(&request).unwrap_err().code, "mutation.indeterminate");
        assert_eq!(service.dispatch(&request).unwrap_err().code, "mutation.indeterminate");

        let diagnostics = diagnostics.lock().unwrap().clone();
        let reports = |cause: &str| {
            diagnostics
                .iter()
                .filter(|message| {
                    message.contains("session.open")
                        && message.contains("session-open-cause")
                        && message.contains(cause)
                })
                .count()
        };
        assert_eq!(
            reports("injected outcome commit failure"),
            1,
            "the daemon log has no cause for the indeterminate open: {diagnostics:?}"
        );
        assert_eq!(
            reports("an earlier attempt"),
            1,
            "the daemon log has no cause for the indeterminate replay: {diagnostics:?}"
        );
    }
}
>>>>>>> theirs
