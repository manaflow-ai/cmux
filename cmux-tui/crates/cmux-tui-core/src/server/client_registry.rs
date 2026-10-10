//! The control-client registry: one record per connection (transport,
//! writer, identity, capabilities, resource streams and waits, attached
//! surfaces and view leases) and the daemon handoff reservation. Attach and
//! view-lease methods are in `client_registry_views`.

use super::CREATION_ATTEMPT_KEYS_CAPABILITY;
use super::CREATION_RECEIPTS_CAPABILITY;
use super::CREATION_SELECTOR_FALLBACKS_CAPABILITY;
use super::ClientIdentityWire;
use super::GUARDED_BROWSER_POINTER_CAPABILITY;
use super::LOOPBACK_FORWARD_CAPABILITY;
use super::MessageWriter;
use super::OPEN_DEVICE_KINDS_CAPABILITY;
use super::OutboundStream;
use super::RESOURCE_STREAMS_PER_CLIENT_CAPACITY;
use super::RESOURCE_STREAMS_SERVER_CAPACITY;
use super::RESOURCE_WAITS_PER_CLIENT_CAPACITY;
use super::RESOURCE_WAITS_SERVER_CAPACITY;
use super::ResourceWorkerAdmission;
use super::ResourceWorkerAdmissionError;
use super::ResourceWorkerPermit;
use super::SHARED_SIZING_CAPABILITY;
use super::SIZING_VIEW_DETACH_CAPABILITY;
use super::TERMINAL_COLOR_OVERRIDES_CAPABILITY;
use super::TERMINAL_FRONTEND_SHELL_INTEGRATION_CAPABILITY;
use super::TERMINAL_PENDING_SEQUENCE_CAPABILITY;
use super::VIEW_ATTACHMENT_DETACH_CAPABILITY;
use super::VIEW_ATTACHMENT_LEASE_CAPABILITY;
#[cfg(unix)]
use super::agent_session_attach;
use super::sanitize_window_title;
use super::size_state_event_json;
use super::{
    app_trust, clipboard_read, conversation_tabs_wire, loopback_forward, terminal_snapshot,
    url_open,
};
use crate::SurfaceId;
use crate::browser::BrowserPointerOwner;
use crate::mux::ClientSizingIdentity;
use crate::mux::ResourceWaitWake;
use crate::resource::RequestId as ResourceRequestId;
use crate::resource::ResourceError;
use crate::resource::StreamPublicId;
use crate::sizing_policy::TerminalSizingState;
use base64::Engine;
use serde_json::Value;
use serde_json::json;
use std::collections::BTreeMap;
use std::collections::HashMap;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Instant;

/// First-attach announcement payload: (transport, name, kind).
pub(super) type ClientAnnouncement = (String, Option<String>, Option<String>);
/// Size-report update payload: (changed, name, kind, previous size).
pub(crate) type ClientSizeUpdate = (bool, Option<String>, Option<String>, Option<(u16, u16)>);
pub(super) const RETIRED_VIEW_LEASE_CAPACITY: usize = 1024;

#[derive(Clone, Copy)]
pub(super) enum ClientTransport {
    Unix,
    WebSocket,
    /// A `cmux link` peer stream through the remote entry (remote_entry.rs).
    Remote,
}

impl ClientTransport {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Unix => "unix",
            Self::WebSocket => "ws",
            Self::Remote => "remote",
        }
    }
}

#[derive(Default)]
pub(super) struct AttachedSurface {
    pub(super) streams: BTreeMap<u64, OutboundStream>,
    pub(super) pending_streams: BTreeMap<u64, OutboundStream>,
    pub(super) size_rollbacks: BTreeMap<u64, crate::mux::ClientSizeRollback>,
    pub(super) size: Option<(u16, u16)>,
    pub(super) committed_size: Option<(u16, u16)>,
    pub(super) current_report_order: Option<u64>,
    pub(super) lease_by_stream: BTreeMap<u64, String>,
    pub(super) view_sizes: HashMap<String, Option<(u16, u16)>>,
    pub(super) geometry_lease: Option<String>,
}

pub(super) struct DetachedSurface {
    pub(super) final_stream: bool,
    pub(super) rollback: Option<crate::mux::ClientSizeRollback>,
    pub(super) geometry_replacement: Option<Option<(u16, u16)>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ViewLeaseStatus {
    Current { geometry_owner: bool },
    Superseded,
}

pub(super) enum ViewResizePreparation {
    GeometryOwner { update: ClientSizeUpdate, previous_view_size: Option<(u16, u16)> },
    Passive { changed: bool, name: Option<String>, kind: Option<String> },
    Superseded,
}

pub(super) enum ViewReleasePreparation {
    GeometryOwner { changed: bool, name: Option<String>, kind: Option<String> },
    Passive,
    Superseded,
}

pub(super) fn mint_view_lease() -> anyhow::Result<String> {
    let mut bytes = [0_u8; 24];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("could not mint view attachment lease: {error}"))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

pub(super) struct ResourceClientStream {
    pub(super) outbound: OutboundStream,
    pub(super) canceled: Arc<AtomicBool>,
    pub(super) _worker_permit: ResourceWorkerPermit,
}

impl Drop for ResourceClientStream {
    fn drop(&mut self) {
        self.canceled.store(true, Ordering::Release);
        self.outbound.close();
    }
}

pub(super) struct ResourceClientWait {
    pub(super) canceled: Arc<ResourceWaitCancellation>,
    pub(super) _worker_permit: ResourceWorkerPermit,
}

impl Drop for ResourceClientWait {
    fn drop(&mut self) {
        self.canceled.cancel();
    }
}

#[derive(Default)]
pub(super) struct ResourceWaitCancellation {
    pub(super) canceled: AtomicBool,
    pub(super) wakeups: Mutex<Vec<Weak<ResourceWaitWake>>>,
    pub(super) lifecycle: Mutex<ResourceWaitLifecycleState>,
    pub(super) lifecycle_changed: Condvar,
}

#[derive(Default)]
pub(super) struct ResourceWaitLifecycleState {
    pub(super) completion_started: bool,
    pub(super) response_attempted: bool,
    pub(super) worker_finished: bool,
}

impl ResourceWaitCancellation {
    pub(super) fn is_canceled(&self) -> bool {
        self.canceled.load(Ordering::Acquire)
    }

    pub(super) fn register(&self, wake: &Arc<ResourceWaitWake>) {
        let mut wakeups = self.wakeups.lock().unwrap();
        wakeups.retain(|registered| registered.strong_count() > 0);
        if self.is_canceled() {
            drop(wakeups);
            wake.notify();
        } else {
            wakeups.push(Arc::downgrade(wake));
        }
    }

    pub(super) fn cancel(&self) {
        if self.canceled.swap(true, Ordering::AcqRel) {
            return;
        }
        let wakeups = std::mem::take(&mut *self.wakeups.lock().unwrap());
        for wake in wakeups.into_iter().filter_map(|wake| wake.upgrade()) {
            wake.notify();
        }
    }

    pub(super) fn begin_completion(&self) -> bool {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        if self.is_canceled() || lifecycle.completion_started {
            return false;
        }
        lifecycle.completion_started = true;
        true
    }

    pub(super) fn completion_started(&self) -> bool {
        self.lifecycle.lock().unwrap().completion_started
    }

    pub(super) fn mark_response_attempted(&self) {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        lifecycle.response_attempted = true;
        self.lifecycle_changed.notify_all();
    }

    pub(super) fn wait_for_response_attempt(&self) -> bool {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        while !lifecycle.response_attempted && !lifecycle.worker_finished {
            lifecycle = self.lifecycle_changed.wait(lifecycle).unwrap();
        }
        lifecycle.response_attempted
    }

    pub(super) fn mark_worker_finished(&self) {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        lifecycle.worker_finished = true;
        self.lifecycle_changed.notify_all();
    }

    pub(super) fn wait_for_worker_finish(&self) {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        while !lifecycle.worker_finished {
            lifecycle = self.lifecycle_changed.wait(lifecycle).unwrap();
        }
    }
}

pub(super) enum ResourceWaitCancel {
    Missing,
    Canceled(Arc<ResourceWaitCancellation>),
    Completing(Arc<ResourceWaitCancellation>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResourceStreamInstallError {
    UnknownClient,
    Duplicate,
    ClientCapacity,
    ServerCapacity,
}

impl From<ResourceWorkerAdmissionError> for ResourceStreamInstallError {
    fn from(error: ResourceWorkerAdmissionError) -> Self {
        match error {
            ResourceWorkerAdmissionError::ClientCapacity => Self::ClientCapacity,
            ResourceWorkerAdmissionError::ServerCapacity => Self::ServerCapacity,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResourceWaitInstallError {
    UnknownClient,
    Duplicate,
    ClientCapacity,
    ServerCapacity,
}

impl From<ResourceWorkerAdmissionError> for ResourceWaitInstallError {
    fn from(error: ResourceWorkerAdmissionError) -> Self {
        match error {
            ResourceWorkerAdmissionError::ClientCapacity => Self::ClientCapacity,
            ResourceWorkerAdmissionError::ServerCapacity => Self::ServerCapacity,
        }
    }
}

pub(super) struct ClientRecord {
    pub(super) transport: ClientTransport,
    pub(super) connected_at: Instant,
    pub(super) name: Option<String>,
    pub(super) kind: Option<String>,
    /// Shared-sizing identity from `set-client-info`. `user_id` is asserted
    /// by the connection; this daemon has no Stack session to verify it.
    pub(super) identity: ClientIdentityWire,
    pub(super) capabilities: HashSet<String>,
    pub(super) browser_pointer_owner: Option<BrowserPointerOwner>,
    pub(super) attached: BTreeMap<SurfaceId, AttachedSurface>,
    pub(super) view_leases: HashMap<String, (SurfaceId, u64)>,
    pub(super) retired_view_leases: HashMap<String, SurfaceId>,
    pub(super) retired_view_lease_order: VecDeque<String>,
    pub(super) retired_surfaces: HashSet<SurfaceId>,
    pub(super) retired_surface_order: VecDeque<SurfaceId>,
    pub(super) resource_streams: HashMap<String, ResourceClientStream>,
    pub(super) resource_waits: HashMap<ResourceRequestId, ResourceClientWait>,
    pub(super) announced_attached: bool,
    pub(super) writer: MessageWriter,
    /// Hello role, peer and confirmations (request_origin.rs).
    pub(super) origin: crate::request_origin::ConnectionOrigin,
}

#[derive(Clone)]
pub(super) struct ResourceClientRecord {
    pub(super) client: u64,
    pub(super) transport: &'static str,
    pub(super) connected_seconds: u64,
    pub(super) name: Option<String>,
    pub(super) kind: Option<String>,
    pub(super) attached: Vec<(SurfaceId, Option<(u16, u16)>)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum DaemonHandoffReservation {
    Pending(u64),
    Committed(u64),
}

#[derive(Default)]
pub(super) struct ClientRegistryState {
    pub(super) clients: BTreeMap<u64, ClientRecord>,
    pub(super) attached_by_surface: HashMap<SurfaceId, HashSet<u64>>,
    /// Newest attach sequence per surface. The idle-close reaper compares it
    /// across ticks so a detach and reattach between two ticks still resets
    /// a terminal's idle clock.
    pub(super) attach_epochs: HashMap<SurfaceId, u64>,
    pub(super) next_attach_epoch: u64,
    /// Shares the registry lock with registration so accepting a handoff and
    /// admitting a new owner cannot pass each other.
    pub(super) daemon_handoff: Option<DaemonHandoffReservation>,
}

pub(crate) struct ClientRegistry {
    /// Called when a surface loses its last attached client (the idle-close
    /// reaper starts that terminal's unattached period).
    pub(super) detach_waker: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
    /// Called after any client connects or leaves (orphan_shutdown.rs).
    pub(super) client_presence_observer: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
    pub(super) url_opens: url_open::URLRequests,
    pub(crate) clipboard_reads: clipboard_read::ClipboardReads,
    /// Connection-scoped loopback streams (`loopback-forward-v1`).
    pub(super) loopback: loopback_forward::LoopbackForwarder,
    /// Connection-scoped browser hosts (`browser-runtime-v1`).
    #[cfg(unix)]
    pub(super) browser_runtimes: super::browser_runtime::BrowserRuntimes,
    /// Connection-scoped agent session attachments (`agent-session-attach-v1`).
    #[cfg(unix)]
    pub(super) agent_sessions: agent_session_attach::AgentSessions,
    pub(crate) snapshot_viewers: terminal_snapshot::SnapshotViewers,
    pub(super) apps: crate::apps::AppsSlot,
    /// Script sessions by connection (`script-*`, crate::scripts).
    pub(crate) scripts: crate::scripts::ScriptsSlot,
    pub(super) origin_clock: crate::request_origin::OriginClock,
    pub(crate) browser_host: crate::browser_host::BrowserHostSupervisor,
    pub(super) app_trust: app_trust::AppTrust,
    pub(super) next_id: AtomicU64,
    pub(super) resource_stream_admission: Arc<ResourceWorkerAdmission>,
    pub(super) resource_wait_admission: Arc<ResourceWorkerAdmission>,
    pub(super) state: Mutex<ClientRegistryState>,
}

/// `browser-runtime-v1` is negotiable only where the daemon has runtimes.
#[cfg(unix)]
fn browser_runtime_capability(capability: &str) -> bool {
    capability == super::BROWSER_RUNTIME_CAPABILITY
}

#[cfg(not(unix))]
fn browser_runtime_capability(_capability: &str) -> bool {
    false
}

pub(super) fn clamp_client_label(value: String) -> String {
    sanitize_window_title(&value).chars().take(64).collect()
}

fn validate_resource_client_label(
    field: &'static str,
    value: Option<String>,
) -> Result<Option<String>, ResourceError> {
    let Some(value) = value else { return Ok(None) };
    if value.chars().count() > 64 {
        return Err(ResourceError::validation_invalid(
            Some(field),
            "client metadata labels cannot exceed 64 characters",
        ));
    }
    if value.chars().any(char::is_control) {
        return Err(ResourceError::validation_invalid(
            Some(field),
            "client metadata labels cannot contain control characters",
        ));
    }
    Ok(Some(value))
}

impl ClientRegistry {
    pub(crate) fn new() -> Self {
        Self {
            detach_waker: Mutex::new(None),
            client_presence_observer: Mutex::new(None),
            next_id: AtomicU64::new(1),
            url_opens: url_open::URLRequests::default(),
            clipboard_reads: Default::default(),
            loopback: loopback_forward::LoopbackForwarder::default(),
            #[cfg(unix)]
            browser_runtimes: Default::default(),
            #[cfg(unix)]
            agent_sessions: Default::default(),
            snapshot_viewers: Default::default(),
            apps: crate::apps::AppsSlot::default(),
            scripts: crate::scripts::ScriptsSlot::default(),
            origin_clock: Default::default(),
            browser_host: Default::default(),
            app_trust: app_trust::AppTrust::default(),
            resource_stream_admission: ResourceWorkerAdmission::new(
                RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
                RESOURCE_STREAMS_SERVER_CAPACITY,
            ),
            resource_wait_admission: ResourceWorkerAdmission::new(
                RESOURCE_WAITS_PER_CLIENT_CAPACITY,
                RESOURCE_WAITS_SERVER_CAPACITY,
            ),
            state: Mutex::new(ClientRegistryState::default()),
        }
    }

    pub(super) fn register(&self, transport: ClientTransport, writer: MessageWriter) -> u64 {
        let client = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut state = self.state.lock().unwrap();
        if state.daemon_handoff.is_some() {
            drop(state);
            writer.close();
            return client;
        }
        state.clients.insert(
            client,
            ClientRecord {
                transport,
                connected_at: Instant::now(),
                name: None,
                kind: None,
                identity: ClientIdentityWire::default(),
                capabilities: HashSet::new(),
                browser_pointer_owner: None,
                attached: BTreeMap::new(),
                view_leases: HashMap::new(),
                retired_view_leases: HashMap::new(),
                retired_view_lease_order: VecDeque::new(),
                retired_surfaces: HashSet::new(),
                retired_surface_order: VecDeque::new(),
                resource_streams: HashMap::new(),
                resource_waits: HashMap::new(),
                announced_attached: false,
                writer,
                origin: Default::default(),
            },
        );
        drop(state);
        self.notify_client_presence();
        client
    }

    pub(super) fn client_ids(&self) -> Vec<u64> {
        self.state.lock().unwrap().clients.keys().copied().collect()
    }

    #[cfg(test)]
    pub(super) fn daemon_handoff_pending(&self) -> bool {
        self.state.lock().unwrap().daemon_handoff.is_some()
    }

    pub(crate) fn daemon_handoff_in_progress(&self) -> bool {
        self.state.lock().unwrap().daemon_handoff.is_some()
    }

    pub(crate) fn daemon_handoff_committed(&self) -> bool {
        matches!(
            self.state.lock().unwrap().daemon_handoff,
            Some(DaemonHandoffReservation::Committed(_))
        )
    }

    pub(super) fn install_resource_stream(
        &self,
        client: u64,
        stream_id: &StreamPublicId,
        outbound: OutboundStream,
    ) -> Result<(Arc<AtomicBool>, ResourceWorkerPermit), ResourceStreamInstallError> {
        let mut state = self.state.lock().unwrap();
        let record =
            state.clients.get_mut(&client).ok_or(ResourceStreamInstallError::UnknownClient)?;
        if record.resource_streams.contains_key(stream_id.as_str()) {
            return Err(ResourceStreamInstallError::Duplicate);
        }
        let worker_permit = self.resource_stream_admission.try_reserve(client)?;
        let canceled = Arc::new(AtomicBool::new(false));
        record.resource_streams.insert(
            stream_id.to_string(),
            ResourceClientStream {
                outbound,
                canceled: canceled.clone(),
                _worker_permit: worker_permit.clone(),
            },
        );
        Ok((canceled, worker_permit))
    }

    pub(super) fn take_resource_stream(
        &self,
        client: u64,
        stream_id: &StreamPublicId,
    ) -> Option<ResourceClientStream> {
        self.state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)?
            .resource_streams
            .remove(stream_id.as_str())
    }

    pub(super) fn finish_resource_stream(
        &self,
        client: u64,
        stream_id: &StreamPublicId,
        outbound_id: u64,
    ) {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else { return };
        if record
            .resource_streams
            .get(stream_id.as_str())
            .is_some_and(|stream| stream.outbound.id == outbound_id)
        {
            record.resource_streams.remove(stream_id.as_str());
        }
    }

    pub(super) fn install_resource_wait(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
    ) -> Result<(Arc<ResourceWaitCancellation>, ResourceWorkerPermit), ResourceWaitInstallError>
    {
        let mut state = self.state.lock().unwrap();
        let record =
            state.clients.get_mut(&client).ok_or(ResourceWaitInstallError::UnknownClient)?;
        if record.resource_waits.contains_key(request_id) {
            return Err(ResourceWaitInstallError::Duplicate);
        }
        let worker_permit = self.resource_wait_admission.try_reserve(client)?;
        let canceled = Arc::new(ResourceWaitCancellation::default());
        record.resource_waits.insert(
            request_id.clone(),
            ResourceClientWait {
                canceled: canceled.clone(),
                _worker_permit: worker_permit.clone(),
            },
        );
        Ok((canceled, worker_permit))
    }

    /// Atomically claim completion for one exact request registration.
    ///
    /// The cancellation identity check prevents an old worker from removing a
    /// replacement that reused the same public request id after cancellation.
    pub(super) fn begin_resource_wait_completion(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
        canceled: &Arc<ResourceWaitCancellation>,
    ) -> bool {
        let state = self.state.lock().unwrap();
        let Some(record) = state.clients.get(&client) else { return false };
        record
            .resource_waits
            .get(request_id)
            .filter(|wait| Arc::ptr_eq(&wait.canceled, canceled))
            .is_some_and(|_| canceled.begin_completion())
    }

    pub(super) fn finish_resource_wait(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
        canceled: &Arc<ResourceWaitCancellation>,
    ) -> bool {
        let removed = {
            let mut state = self.state.lock().unwrap();
            let Some(record) = state.clients.get_mut(&client) else { return false };
            if record
                .resource_waits
                .get(request_id)
                .is_some_and(|wait| Arc::ptr_eq(&wait.canceled, canceled))
            {
                record.resource_waits.remove(request_id)
            } else {
                None
            }
        };
        removed.is_some()
    }

    /// Remove and wake a detached wait by its public request id. Removal is
    /// the cancellation linearization point, so repeated and late requests
    /// return false and a worker that lost this race cannot send a response.
    pub(super) fn cancel_resource_wait(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
    ) -> ResourceWaitCancel {
        {
            let mut state = self.state.lock().unwrap();
            let Some(record) = state.clients.get_mut(&client) else {
                return ResourceWaitCancel::Missing;
            };
            let Some(wait) = record.resource_waits.get(request_id) else {
                return ResourceWaitCancel::Missing;
            };
            if wait.canceled.completion_started() {
                ResourceWaitCancel::Completing(wait.canceled.clone())
            } else {
                let canceled = wait.canceled.clone();
                record.resource_waits.remove(request_id);
                ResourceWaitCancel::Canceled(canceled)
            }
        }
    }

    pub(super) fn set_info(
        &self,
        client: u64,
        name: Option<String>,
        kind: Option<String>,
        capabilities: Option<Vec<String>>,
    ) -> anyhow::Result<(Option<String>, Option<String>)> {
        let mut state = self.state.lock().unwrap();
        if kind.as_deref() == Some("native-browser") && state.daemon_handoff.is_some() {
            anyhow::bail!("daemon handoff is already in progress");
        }
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some(name) = name {
            record.name = Some(clamp_client_label(name));
        }
        if let Some(kind) = kind {
            record.kind = Some(clamp_client_label(kind));
        }
        if let Some(capabilities) = capabilities {
            record.capabilities.extend(capabilities.into_iter().filter(|capability| {
                capability == GUARDED_BROWSER_POINTER_CAPABILITY
                    || capability == VIEW_ATTACHMENT_LEASE_CAPABILITY
                    || capability == VIEW_ATTACHMENT_DETACH_CAPABILITY
                    || capability == SHARED_SIZING_CAPABILITY
                    || capability == SIZING_VIEW_DETACH_CAPABILITY
                    || capability == OPEN_DEVICE_KINDS_CAPABILITY
                    || capability == TERMINAL_COLOR_OVERRIDES_CAPABILITY
                    || capability == TERMINAL_PENDING_SEQUENCE_CAPABILITY
                    || capability == CREATION_RECEIPTS_CAPABILITY
                    || capability == CREATION_ATTEMPT_KEYS_CAPABILITY
                    || capability == CREATION_SELECTOR_FALLBACKS_CAPABILITY
                    || capability == LOOPBACK_FORWARD_CAPABILITY
                    || browser_runtime_capability(capability)
                    || capability == TERMINAL_FRONTEND_SHELL_INTEGRATION_CAPABILITY
                    || conversation_tabs_wire::negotiable(capability)
            }));
            record.writer.negotiate_conversation_tabs(record.capabilities.iter());
        }
        Ok((record.name.clone(), record.kind.clone()))
    }

    /// Merge identity fields: absent fields keep their previous value.
    pub(super) fn set_sizing_identity(&self, client: u64, identity: ClientIdentityWire) {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else { return };
        let current = &mut record.identity;
        if identity.user_id.is_some() {
            current.user_id = identity.user_id;
        }
        if identity.display_name.is_some() {
            current.display_name = identity.display_name;
        }
        if identity.device_kind.is_some() {
            current.device_kind = identity.device_kind;
        }
        if identity.device_name.is_some() {
            current.device_name = identity.device_name;
        }
        if identity.device_id.is_some() {
            current.device_id = identity.device_id;
        }
    }

    /// The connection's identity for shared sizing. Without explicit
    /// fields it falls back to `name` and a device kind parsed from `kind`.
    pub(crate) fn sizing_identity(&self, client: u64) -> Option<ClientSizingIdentity> {
        let state = self.state.lock().unwrap();
        let record = state.clients.get(&client)?;
        let mut identity = record.identity.clone();
        if identity.display_name.is_none() {
            identity.display_name.clone_from(&record.name);
        }
        if identity.device_kind.is_none() {
            identity.device_kind.clone_from(&record.kind);
        }
        Some(identity.into_identity())
    }

    /// Deliver a `size-state` event on every attach stream of `surface`.
    /// A full stream queue terminates that stream with its overflow notice,
    /// so a slow viewer re-attaches instead of silently missing a state.
    pub(crate) fn send_size_state(
        &self,
        surface: SurfaceId,
        runtime: SurfaceId,
        size_state: &TerminalSizingState,
    ) {
        let targets = {
            let state = self.state.lock().unwrap();
            state
                .attached_by_surface
                .get(&surface)
                .into_iter()
                .flatten()
                .filter_map(|client| {
                    let record = state.clients.get(client)?;
                    // Only clients that opted in receive the new event, so
                    // older clients keep their exact attach-stream sequence.
                    if !record.capabilities.contains(SHARED_SIZING_CAPABILITY) {
                        return None;
                    }
                    let open = record.capabilities.contains(OPEN_DEVICE_KINDS_CAPABILITY);
                    Some((
                        (*client, open),
                        record.writer.clone(),
                        Self::event_streams(record, surface),
                    ))
                })
                .collect::<Vec<_>>()
        };
        for (client, writer, streams) in targets {
            let event = size_state_event_json(surface, runtime, size_state, Some(client));
            for stream in streams {
                let _ = writer.send_stream(&event, &stream);
            }
        }
    }

    /// Legacy JSON attach streams of `surface`. Resource-protocol streams
    /// carry framed `stream_item`s and never receive raw events.
    pub(super) fn event_streams(record: &ClientRecord, surface: SurfaceId) -> Vec<OutboundStream> {
        let resource_streams = record
            .resource_streams
            .values()
            .map(|stream| stream.outbound.id)
            .collect::<HashSet<_>>();
        record
            .attached
            .get(&surface)
            .into_iter()
            .flat_map(|attached| attached.streams.values())
            .filter(|stream| !resource_streams.contains(&stream.id))
            .cloned()
            .collect()
    }

    /// Send one event on a client's attach stream for `surface` (the given
    /// stream, else its first one), falling back to the control channel.
    pub(super) fn send_surface_event(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: Option<u64>,
        event: &Value,
    ) -> bool {
        let target = {
            let state = self.state.lock().unwrap();
            state.clients.get(&client).map(|record| {
                let streams = Self::event_streams(record, surface);
                let target = match stream {
                    Some(stream) => {
                        streams.into_iter().find(|candidate| candidate.id == stream).map(Some)
                    }
                    None => Some(streams.into_iter().next()),
                };
                (record.writer.clone(), target)
            })
        };
        let Some((writer, Some(stream))) = target else { return false };
        match stream {
            Some(stream) => writer.send_stream(event, &stream).is_ok(),
            None => writer.send_control(event).is_ok(),
        }
    }

    pub(super) fn set_resource_info(
        &self,
        client: u64,
        name: Option<Option<String>>,
        kind: Option<Option<String>>,
    ) -> Result<(Option<String>, Option<String>), ResourceError> {
        let name = name.map(|name| validate_resource_client_label("name", name)).transpose()?;
        let kind = kind.map(|kind| validate_resource_client_label("kind", kind)).transpose()?;
        let mut state = self.state.lock().unwrap();
        if kind.as_ref().and_then(|kind| kind.as_deref()) == Some("native-browser")
            && state.daemon_handoff.is_some()
        {
            return Err(ResourceError::operation_failed(
                "client.metadata.update",
                "daemon handoff is already in progress",
                json!({}),
            ));
        }
        let record = state.clients.get_mut(&client).ok_or_else(|| {
            ResourceError::operation_failed(
                "client.metadata.update",
                format!("unknown client {client}"),
                json!({}),
            )
        })?;
        if let Some(name) = name {
            record.name = name;
        }
        if let Some(kind) = kind {
            record.kind = kind;
        }
        Ok((record.name.clone(), record.kind.clone()))
    }

    pub(super) fn resource_records(&self) -> Vec<ResourceClientRecord> {
        self.state
            .lock()
            .unwrap()
            .clients
            .iter()
            .map(|(client, record)| ResourceClientRecord {
                client: *client,
                transport: match record.transport {
                    ClientTransport::Unix => "unix",
                    ClientTransport::WebSocket => "websocket",
                    ClientTransport::Remote => "remote",
                },
                connected_seconds: record.connected_at.elapsed().as_secs(),
                name: record.name.clone(),
                kind: record.kind.clone(),
                attached: record
                    .attached
                    .iter()
                    .filter_map(|(surface, attached)| {
                        (!attached.streams.is_empty())
                            .then_some((*surface, attached.committed_size))
                    })
                    .collect(),
            })
            .collect()
    }

    pub(super) fn supports_capability(&self, client: u64, capability: &str) -> bool {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .is_some_and(|record| record.capabilities.contains(capability))
    }

    pub(super) fn surface_attachment_is_current_or_retired(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> bool {
        self.state.lock().unwrap().clients.get(&client).is_some_and(|record| {
            record.attached.contains_key(&surface) || record.retired_surfaces.contains(&surface)
        })
    }

    pub(crate) fn surface_attachment_is_retired_without_current(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> bool {
        self.state.lock().unwrap().clients.get(&client).is_some_and(|record| {
            !record.attached.contains_key(&surface) && record.retired_surfaces.contains(&surface)
        })
    }

    pub(super) fn browser_pointer_owner(&self, client: u64) -> anyhow::Result<BrowserPointerOwner> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some(owner) = record.browser_pointer_owner {
            return Ok(owner);
        }
        let owner = if record.capabilities.contains(GUARDED_BROWSER_POINTER_CAPABILITY) {
            BrowserPointerOwner::Client(client)
        } else {
            BrowserPointerOwner::Legacy
        };
        record.browser_pointer_owner = Some(owner);
        Ok(owner)
    }

    pub(crate) fn begin_daemon_handoff(
        &self,
        requesting_client: u64,
        force: bool,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let requester = state
            .clients
            .get(&requesting_client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {requesting_client}"))?;
        if !matches!(requester.transport, ClientTransport::Unix) {
            anyhow::bail!("daemon shutdown requires a trusted local connection");
        }
        if !force
            && state.clients.iter().any(|(client, record)| {
                *client != requesting_client && record.kind.as_deref() == Some("native-browser")
            })
        {
            anyhow::bail!("another native-browser frontend still owns this daemon");
        }
        if state.daemon_handoff.is_some() {
            anyhow::bail!("daemon handoff is already in progress");
        }
        state.daemon_handoff = Some(DaemonHandoffReservation::Pending(requesting_client));
        Ok(())
    }

    pub(crate) fn commit_daemon_handoff_after_ack(
        &self,
        requesting_client: u64,
        acknowledge: impl FnOnce() -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        match state.daemon_handoff {
            Some(DaemonHandoffReservation::Pending(requester))
                if requester == requesting_client =>
            {
                acknowledge()?;
                state.daemon_handoff = Some(DaemonHandoffReservation::Committed(requesting_client));
                Ok(())
            }
            _ => anyhow::bail!("daemon handoff reservation changed before commit"),
        }
    }

    pub(crate) fn cancel_daemon_handoff(&self, requesting_client: u64) {
        let mut state = self.state.lock().unwrap();
        if state.daemon_handoff == Some(DaemonHandoffReservation::Pending(requesting_client)) {
            state.daemon_handoff = None;
        }
    }

    pub(crate) fn list_json(&self, requesting_client: u64) -> Value {
        let state = self.state.lock().unwrap();
        json!(
            state
                .clients
                .iter()
                .map(|(client, record)| {
                    json!({
                        "client": client,
                        "transport": record.transport.as_str(),
                        "name": record.name,
                        "kind": record.kind,
                        "connected_seconds": record.connected_at.elapsed().as_secs(),
                        "attached": record.attached.iter().filter_map(|(surface, attached)| {
                            (!attached.streams.is_empty()).then_some(*surface)
                        }).collect::<Vec<_>>(),
                        "sizes": record.attached.iter().filter_map(|(surface, attached)| {
                            if attached.streams.is_empty() {
                                return None;
                            }
                            Some(match attached.committed_size {
                                Some((cols, rows)) => json!({
                                    "surface": surface,
                                    "cols": cols,
                                    "rows": rows,
                                }),
                                None => json!({
                                    "surface": surface,
                                    "cols": null,
                                    "rows": null,
                                }),
                            })
                        }).collect::<Vec<_>>(),
                        "self": *client == requesting_client,
                    })
                })
                .collect::<Vec<_>>()
        )
    }
}
