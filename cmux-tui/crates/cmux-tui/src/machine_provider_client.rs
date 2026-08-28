//! Synchronous client for the versioned machine-provider protocol.
//!
//! This module intentionally has no `App` or CLI integration yet. It owns the
//! security and framing boundary between a provider daemon and cmux's existing
//! `RemoteTransport` abstraction, so later runtime wiring does not need to know
//! how provider requests, events, authentication, or one-use stream tickets are
//! represented on the wire.

#![allow(dead_code)]

#[cfg(unix)]
use std::collections::{BTreeMap, HashMap, VecDeque};
#[cfg(unix)]
use std::fmt;
#[cfg(unix)]
use std::io::{self, BufRead, BufReader, Write};
#[cfg(unix)]
use std::path::Path;
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(unix)]
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
#[cfg(unix)]
use std::sync::{Arc, Condvar, Mutex, Weak};
#[cfg(unix)]
use std::time::{Duration, Instant};

#[cfg(unix)]
use cmux_tui_machine_protocol::{
    AcknowledgeNoticeParams, AcknowledgeNoticeResult, ActionValue, BearerToken,
    CLIENT_CAPABILITY_NEGOTIATION_CAPABILITY, CONNECTION_PROGRESS_CLIENT_CAPABILITY,
    ClientDescriptor, CloseMachineParams, CloseMachineResult, ConnectExternalMachineParams,
    ConnectExternalMachineResult, CreateMachineParams, CreateMachineResult, CreateWorkspaceParams,
    CreateWorkspaceResult, DURABLE_NOTICES_CAPABILITY, EXTERNAL_MACHINE_CONNECT_CAPABILITY,
    EventEnvelope, ExternalMachineSpecifier, HelloParams, HelloResult, InvokeActionParams,
    InvokeActionResult, MACHINE_LIFECYCLE_CAPABILITY, MachineLifecycleSnapshotParams,
    MachineLifecycleSnapshotResult, MachineMutationParams, MachineMutationResult,
    NegotiateClientCapabilitiesParams, NegotiateClientCapabilitiesResult, NoticeDelivery, OpaqueId,
    OpenMachineParams, OpenMachineResult, PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY, Protocol,
    ProviderError, ProviderEvent, ProviderRequest, ProviderResponse, RenameMachineParams,
    RenameWorkspaceParams, RequestEnvelope, ResponseEnvelope, SelectScopeParams, SelectScopeResult,
    SnapshotParams, SnapshotResult, SubscribeNoticesParams, SubscribeNoticesResult,
    TransportDescriptor, TransportHandshake, TransportHandshakeResult, TransportRole, Version,
    WORKSPACE_LIFECYCLE_CAPABILITY, WorkspaceCreateMode, WorkspaceMutationParams,
    WorkspaceMutationResult, WorkspaceSnapshotParams, WorkspaceSnapshotResult,
};
#[cfg(unix)]
use serde::Serialize;
#[cfg(unix)]
use serde::de::DeserializeOwned;
#[cfg(unix)]
use serde_json::Value;
#[cfg(unix)]
use zeroize::Zeroize;

#[cfg(unix)]
use crate::session::{
    RemoteMessageReader, RemoteMessageWriter, RemoteTransport, RemoteTransportAbort,
};

#[cfg(unix)]
#[path = "machine_provider_transport.rs"]
mod machine_provider_transport;
#[cfg(unix)]
#[allow(unused_imports)] // Consumed by the upcoming runtime/CLI migration.
pub(crate) use machine_provider_transport::{
    CommandProviderConnector, MachineProviderConnector, SshProviderConnector, UnixProviderConnector,
};
#[cfg(unix)]
use machine_provider_transport::{
    MachineStreamConnector, ProviderIo, ProviderIoGuard, ProviderIoParts,
};

/// Provider control frames are metadata, not terminal or browser payloads.
#[cfg(unix)]
const MAX_CONTROL_FRAME_BYTES: usize = 1024 * 1024;
/// Remote session frames can include encoded browser frames and scrollback.
#[cfg(unix)]
const MAX_TRANSPORT_FRAME_BYTES: usize = 64 * 1024 * 1024;
#[cfg(unix)]
const PROVIDER_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(unix)]
// A suspended cloud machine may spend up to two minutes resuming and another
// two minutes waiting for its relay. Keep the client deadline above that
// server-side bound so the control generation owns cancellation.
const PROVIDER_OPEN_TIMEOUT: Duration = Duration::from_secs(5 * 60);
#[cfg(unix)]
const PROVIDER_EVENT_QUEUE_CAPACITY: usize = 64;

#[cfg(unix)]
#[derive(Debug)]
pub(crate) enum ProviderClientError {
    Io(io::Error),
    Json(serde_json::Error),
    Provider(ProviderError),
    FrameTooLarge { limit: usize },
    Disconnected,
    Timeout,
    NotAuthenticated,
    AlreadyAuthenticated,
    UnsupportedCapability(&'static str),
    Protocol(String),
    StatePoisoned(&'static str),
    TransportRejected,
}

#[cfg(unix)]
impl fmt::Display for ProviderClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "machine provider I/O failed: {error}"),
            Self::Json(error) => write!(formatter, "machine provider sent invalid JSON: {error}"),
            Self::Provider(error) => write!(
                formatter,
                "machine provider rejected the request ({}): {}",
                error.code.as_str(),
                error.message
            ),
            Self::FrameTooLarge { limit } => {
                write!(formatter, "machine provider frame exceeds the {limit}-byte limit")
            }
            Self::Disconnected => formatter.write_str("machine provider disconnected"),
            Self::Timeout => formatter.write_str("machine provider did not respond"),
            Self::NotAuthenticated => {
                formatter.write_str("machine provider has not been authenticated")
            }
            Self::AlreadyAuthenticated => {
                formatter.write_str("machine provider authentication was already attempted")
            }
            Self::UnsupportedCapability(capability) => {
                write!(formatter, "machine provider does not advertise {capability}")
            }
            Self::Protocol(message) => {
                write!(formatter, "machine provider protocol error: {message}")
            }
            Self::StatePoisoned(name) => {
                write!(formatter, "machine provider {name} state is poisoned")
            }
            Self::TransportRejected => {
                formatter.write_str("machine provider rejected the transport ticket")
            }
        }
    }
}

#[cfg(unix)]
impl std::error::Error for ProviderClientError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(unix)]
impl From<io::Error> for ProviderClientError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[cfg(unix)]
impl From<serde_json::Error> for ProviderClientError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

#[cfg(unix)]
type ProviderResult<T> = Result<T, ProviderClientError>;

#[cfg(unix)]
#[derive(Debug, Clone)]
enum ReaderFailure {
    Disconnected,
    FrameTooLarge { limit: usize },
    InvalidFrame(String),
    Io(String),
}

#[cfg(unix)]
impl From<ReaderFailure> for ProviderClientError {
    fn from(failure: ReaderFailure) -> Self {
        match failure {
            ReaderFailure::Disconnected => Self::Disconnected,
            ReaderFailure::FrameTooLarge { limit } => Self::FrameTooLarge { limit },
            ReaderFailure::InvalidFrame(message) => Self::Protocol(message),
            ReaderFailure::Io(message) => Self::Io(io::Error::other(message)),
        }
    }
}

#[cfg(unix)]
type PendingResponse = Result<Vec<u8>, ReaderFailure>;

#[cfg(unix)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ReceivedProviderEvent {
    pub(crate) event: ProviderEvent,
    pub(crate) delivery: Option<NoticeDelivery>,
}

#[cfg(unix)]
#[derive(Default)]
struct ProviderEventQueueState {
    events: VecDeque<ReceivedProviderEvent>,
    disconnected: bool,
}

#[cfg(unix)]
struct ProviderEventQueue {
    state: Mutex<ProviderEventQueueState>,
    ready: Condvar,
}

#[cfg(unix)]
impl ProviderEventQueue {
    fn new() -> Self {
        Self { state: Mutex::new(ProviderEventQueueState::default()), ready: Condvar::new() }
    }

    fn publish(&self, event: ReceivedProviderEvent) -> Result<(), ()> {
        let Ok(mut state) = self.state.lock() else {
            return Err(());
        };
        if state.disconnected {
            return Err(());
        }

        if let Some(delivery) = event.delivery.as_ref()
            && let Some(index) = state.events.iter().position(|queued| {
                queued
                    .delivery
                    .as_ref()
                    .is_some_and(|queued| queued.notice_id == delivery.notice_id)
            })
        {
            if state.events[index] != event {
                state.events.clear();
                state.disconnected = true;
                drop(state);
                self.ready.notify_all();
                return Err(());
            }
            drop(state);
            self.ready.notify_one();
            return Ok(());
        }

        if let ProviderEvent::ConnectionClosed(closed) = &event.event
            && let Some(index) = state.events.iter().position(|queued| {
                matches!(
                    &queued.event,
                    ProviderEvent::ConnectionClosed(queued)
                        if queued.connection_id == closed.connection_id
                            && queued.machine_id == closed.machine_id
                )
            })
        {
            // One connection can only be closed once. Retain its latest
            // provider reason without growing the priority queue.
            state.events[index] = event;
            drop(state);
            self.ready.notify_one();
            return Ok(());
        }

        let priority =
            event.delivery.is_some() || matches!(&event.event, ProviderEvent::ConnectionClosed(_));
        if state.events.len() >= PROVIDER_EVENT_QUEUE_CAPACITY {
            if !priority {
                return Ok(());
            }
            let best_effort = state.events.iter().position(|queued| {
                queued.delivery.is_none()
                    && !matches!(&queued.event, ProviderEvent::ConnectionClosed(_))
            });
            let Some(best_effort) = best_effort else {
                // Durable notices and connection closures are loss-intolerant.
                // Force the control generation to reconnect and replay instead
                // of dropping one when its bounded priority budget is exhausted.
                state.events.clear();
                state.disconnected = true;
                drop(state);
                self.ready.notify_all();
                return Err(());
            };
            state.events.remove(best_effort);
        }
        state.events.push_back(event);
        drop(state);
        self.ready.notify_one();
        Ok(())
    }

    fn disconnect(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.disconnected = true;
        }
        self.ready.notify_all();
    }
}

#[cfg(unix)]
pub(crate) struct ProviderEventReceiver {
    queue: Arc<ProviderEventQueue>,
}

#[cfg(unix)]
impl ProviderEventReceiver {
    pub(crate) fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> Result<ReceivedProviderEvent, RecvTimeoutError> {
        let deadline = Instant::now() + timeout;
        let mut state = self.queue.state.lock().map_err(|_| RecvTimeoutError::Disconnected)?;
        loop {
            if let Some(event) = state.events.pop_front() {
                return Ok(event);
            }
            if state.disconnected {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            let (next, timed_out) = self
                .queue
                .ready
                .wait_timeout(state, remaining)
                .map_err(|_| RecvTimeoutError::Disconnected)?;
            state = next;
            if timed_out.timed_out() && state.events.is_empty() {
                return Err(RecvTimeoutError::Timeout);
            }
        }
    }
}

#[cfg(unix)]
#[derive(Clone, Copy, Default, Eq, PartialEq)]
enum DurableSubscriptionState {
    #[default]
    NotStarted,
    WaitingForCursor,
    Active,
}

#[cfg(unix)]
#[derive(Default)]
struct ProviderEventHubState {
    retained_durable: VecDeque<ReceivedProviderEvent>,
    acknowledged_sequence: u64,
    durable_subscription: DurableSubscriptionState,
    subscribers: Vec<Weak<ProviderEventQueue>>,
}

#[cfg(unix)]
struct ProviderClientInner {
    writer: Mutex<Box<dyn Write + Send>>,
    control_guard: ProviderIoGuard,
    streams: Arc<dyn MachineStreamConnector>,
    pending: Mutex<HashMap<String, SyncSender<PendingResponse>>>,
    events: Mutex<ProviderEventHubState>,
    snapshot_subscribers: Mutex<Vec<SyncSender<u64>>>,
    next_request_id: AtomicU64,
    live: AtomicBool,
    hello_started: AtomicBool,
    authenticated: AtomicBool,
    token: Mutex<Option<BearerToken>>,
    provider_capabilities: Mutex<Vec<String>>,
    negotiated_client_capabilities: Mutex<Vec<String>>,
}

#[cfg(unix)]
impl ProviderClientInner {
    fn cancel_pending(&self, failure: ReaderFailure) {
        let Ok(mut pending) = self.pending.lock() else {
            return;
        };
        for (_, response) in pending.drain() {
            let _ = response.try_send(Err(failure.clone()));
        }
    }

    fn mark_disconnected(&self, failure: ReaderFailure) {
        self.live.store(false, Ordering::Release);
        self.cancel_pending(failure);
        if let Ok(mut events) = self.events.lock() {
            for subscriber in
                events.subscribers.drain(..).filter_map(|subscriber| subscriber.upgrade())
            {
                subscriber.disconnect();
            }
        }
        if let Ok(mut subscribers) = self.snapshot_subscribers.lock() {
            subscribers.clear();
        }
    }

    fn publish_snapshot_revision(&self, revision: u64) {
        let Ok(mut subscribers) = self.snapshot_subscribers.lock() else {
            return;
        };
        subscribers.retain(|subscriber| match subscriber.try_send(revision) {
            Ok(()) => true,
            // A queued revision is enough because consumers fetch the latest
            // snapshot instead of applying revision deltas.
            Err(TrySendError::Full(_)) => true,
            Err(TrySendError::Disconnected(_)) => false,
        });
    }

    fn publish_to_event_subscribers(
        events: &mut ProviderEventHubState,
        event: ReceivedProviderEvent,
    ) -> Result<(), ReaderFailure> {
        let mut overflowed = false;
        events.subscribers.retain(|subscriber| {
            let Some(subscriber) = subscriber.upgrade() else {
                return false;
            };
            if subscriber.publish(event.clone()).is_err() {
                overflowed = true;
            }
            true
        });
        if overflowed {
            Err(ReaderFailure::InvalidFrame(
                "durable provider event subscriber exceeded its bounded capacity".into(),
            ))
        } else {
            Ok(())
        }
    }

    fn publish_event(&self, event: ReceivedProviderEvent) -> Result<(), ReaderFailure> {
        let mut events = self
            .events
            .lock()
            .map_err(|_| ReaderFailure::InvalidFrame("event state is poisoned".into()))?;
        if let Some(delivery) = event.delivery.as_ref() {
            if events.durable_subscription == DurableSubscriptionState::NotStarted {
                return Err(ReaderFailure::InvalidFrame(
                    "durable notice arrived before subscription".into(),
                ));
            }
            if events.durable_subscription == DurableSubscriptionState::Active
                && delivery.sequence <= events.acknowledged_sequence
            {
                return Ok(());
            }
            if let Some(retained) = events.retained_durable.iter().find(|retained| {
                retained
                    .delivery
                    .as_ref()
                    .is_some_and(|retained| retained.notice_id == delivery.notice_id)
            }) {
                return if retained == &event {
                    Ok(())
                } else {
                    Err(ReaderFailure::InvalidFrame(format!(
                        "durable notice {} changed after replay",
                        delivery.notice_id
                    )))
                };
            }
            let retained_sequence = events
                .retained_durable
                .back()
                .and_then(|retained| retained.delivery.as_ref())
                .map(|retained| retained.sequence);
            if let Some(retained_sequence) = retained_sequence.or_else(|| {
                (events.durable_subscription == DurableSubscriptionState::Active)
                    .then_some(events.acknowledged_sequence)
            }) {
                let Some(expected_sequence) = retained_sequence.checked_add(1) else {
                    return Err(ReaderFailure::InvalidFrame(format!(
                        "durable notice sequence overflowed after {retained_sequence}",
                    )));
                };
                if delivery.sequence != expected_sequence {
                    return Err(ReaderFailure::InvalidFrame(format!(
                        "durable notice sequence {} did not match expected sequence {expected_sequence}",
                        delivery.sequence,
                    )));
                }
            }
            if events.retained_durable.len() >= PROVIDER_EVENT_QUEUE_CAPACITY {
                return Err(ReaderFailure::InvalidFrame(
                    "durable notice backlog exceeded its bounded capacity".into(),
                ));
            }
            events.retained_durable.push_back(event.clone());
            if events.durable_subscription == DurableSubscriptionState::WaitingForCursor {
                return Ok(());
            }
        }

        Self::publish_to_event_subscribers(&mut events, event)
    }

    fn begin_notice_subscription(&self) -> ProviderResult<()> {
        let mut events =
            self.events.lock().map_err(|_| ProviderClientError::StatePoisoned("event"))?;
        if events.durable_subscription != DurableSubscriptionState::NotStarted {
            return Err(ProviderClientError::Protocol(
                "durable notice subscription was already started".into(),
            ));
        }
        events.durable_subscription = DurableSubscriptionState::WaitingForCursor;
        Ok(())
    }

    fn cancel_notice_subscription(&self) {
        let Ok(mut events) = self.events.lock() else {
            return;
        };
        if events.durable_subscription == DurableSubscriptionState::WaitingForCursor {
            events.durable_subscription = DurableSubscriptionState::NotStarted;
            events.retained_durable.clear();
        }
    }

    fn complete_notice_subscription(&self, sequence: u64) -> Result<(), ReaderFailure> {
        let mut events = self
            .events
            .lock()
            .map_err(|_| ReaderFailure::InvalidFrame("event state is poisoned".into()))?;
        if events.durable_subscription != DurableSubscriptionState::WaitingForCursor {
            return Err(ReaderFailure::InvalidFrame(
                "durable notice subscription cursor arrived without a pending subscription".into(),
            ));
        }
        if let Some(first_sequence) = events
            .retained_durable
            .front()
            .and_then(|event| event.delivery.as_ref())
            .map(|delivery| delivery.sequence)
        {
            let Some(expected_sequence) = sequence.checked_add(1) else {
                return Err(ReaderFailure::InvalidFrame(format!(
                    "durable notice sequence overflowed after {sequence}",
                )));
            };
            if first_sequence != expected_sequence {
                return Err(ReaderFailure::InvalidFrame(format!(
                    "durable notice sequence {first_sequence} did not match resumed sequence {expected_sequence}",
                )));
            }
        }
        events.acknowledged_sequence = sequence;
        events.durable_subscription = DurableSubscriptionState::Active;
        for index in 0..events.retained_durable.len() {
            let event = events.retained_durable[index].clone();
            Self::publish_to_event_subscribers(&mut events, event)?;
        }
        Ok(())
    }

    fn acknowledge_sequence(&self, sequence: u64) -> ProviderResult<()> {
        let mut events =
            self.events.lock().map_err(|_| ProviderClientError::StatePoisoned("event"))?;
        if events.durable_subscription != DurableSubscriptionState::Active {
            return Err(ProviderClientError::Protocol(
                "durable notice acknowledgement preceded subscription".into(),
            ));
        }
        if sequence < events.acknowledged_sequence {
            return Err(ProviderClientError::Protocol(format!(
                "durable notice cursor moved backward from {} to {sequence}",
                events.acknowledged_sequence
            )));
        }
        events.acknowledged_sequence = sequence;
        events.retained_durable.retain(|event| {
            event.delivery.as_ref().is_some_and(|delivery| delivery.sequence > sequence)
        });
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for ProviderClientInner {
    fn drop(&mut self) {
        if let Ok(events) = self.events.get_mut() {
            for subscriber in
                events.subscribers.drain(..).filter_map(|subscriber| subscriber.upgrade())
            {
                subscriber.disconnect();
            }
        }
    }
}

/// One authenticated connection to a machine provider.
///
/// The bearer token is retained privately only because every separately
/// authorized transport socket requires it. It is never returned, formatted,
/// logged, or included in control requests after the one-shot `hello` call.
#[cfg(unix)]
pub(crate) struct ProviderClient {
    inner: Arc<ProviderClientInner>,
}

#[cfg(unix)]
impl ProviderClient {
    pub(crate) fn connect(socket_path: impl AsRef<Path>) -> ProviderResult<Self> {
        let (control, streams) =
            UnixProviderConnector::open_unauthenticated(socket_path.as_ref().to_path_buf())?;
        Self::from_transport(control, streams)
    }

    fn from_transport(
        control: ProviderIo,
        streams: Arc<dyn MachineStreamConnector>,
    ) -> ProviderResult<Self> {
        let ProviderIoParts { reader, writer, guard } = control.into_parts();
        let inner = Arc::new(ProviderClientInner {
            writer: Mutex::new(writer),
            control_guard: guard.clone(),
            streams,
            pending: Mutex::new(HashMap::new()),
            events: Mutex::new(ProviderEventHubState::default()),
            snapshot_subscribers: Mutex::new(Vec::new()),
            next_request_id: AtomicU64::new(1),
            live: AtomicBool::new(true),
            hello_started: AtomicBool::new(false),
            authenticated: AtomicBool::new(false),
            token: Mutex::new(None),
            provider_capabilities: Mutex::new(Vec::new()),
            negotiated_client_capabilities: Mutex::new(Vec::new()),
        });
        let weak = Arc::downgrade(&inner);
        std::thread::Builder::new()
            .name("machine-provider-reader".to_string())
            .spawn(move || control_reader_loop(reader, guard, weak))?;
        Ok(Self { inner })
    }

    pub(crate) fn connect_authenticated(
        socket_path: impl AsRef<Path>,
        token: BearerToken,
        client: ClientDescriptor,
    ) -> ProviderResult<(Self, HelloResult)> {
        Self::connect_authenticated_with(
            Arc::new(UnixProviderConnector::new(socket_path.as_ref().to_path_buf(), token)),
            client,
        )
    }

    /// Opens and authenticates one transport-neutral provider generation.
    pub(crate) fn connect_authenticated_with(
        connector: Arc<dyn MachineProviderConnector>,
        client: ClientDescriptor,
    ) -> ProviderResult<(Self, HelloResult)> {
        let (token, control, streams) = connector.connect()?.into_parts();
        let provider = Self::from_transport(control, streams)?;
        let hello = provider.hello(token, client)?;
        provider.negotiate_supported_client_capabilities()?;
        Ok((provider, hello))
    }

    /// Authenticate this control socket exactly once.
    pub(crate) fn hello(
        &self,
        token: BearerToken,
        client: ClientDescriptor,
    ) -> ProviderResult<HelloResult> {
        if self
            .inner
            .hello_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(ProviderClientError::AlreadyAuthenticated);
        }

        // Keep the original private and move only a temporary clone into the
        // one hello frame. Failed authentication is not retried implicitly.
        let result = self.request_unchecked_with_metadata(
            ProviderRequest::Hello(HelloParams { token: token.clone(), client }),
            PROVIDER_REQUEST_TIMEOUT,
        );
        match result {
            Ok((hello, capabilities)) => {
                *self
                    .inner
                    .provider_capabilities
                    .lock()
                    .map_err(|_| ProviderClientError::StatePoisoned("capabilities"))? =
                    capabilities;
                *self
                    .inner
                    .token
                    .lock()
                    .map_err(|_| ProviderClientError::StatePoisoned("credential"))? = Some(token);
                self.inner.authenticated.store(true, Ordering::Release);
                Ok(hello)
            }
            Err(error) => Err(error),
        }
    }

    pub(crate) fn snapshot(&self, known_revision: Option<u64>) -> ProviderResult<SnapshotResult> {
        let mut snapshot =
            self.request(ProviderRequest::Snapshot(SnapshotParams { known_revision }))?;
        self.retain_negotiated_actions(&mut snapshot)?;
        Ok(snapshot)
    }

    pub(crate) fn select_scope(&self, scope_id: OpaqueId) -> ProviderResult<SelectScopeResult> {
        let mut result: SelectScopeResult =
            self.request(ProviderRequest::SelectScope(SelectScopeParams { scope_id }))?;
        self.retain_negotiated_actions(&mut result.snapshot)?;
        Ok(result)
    }

    pub(crate) fn create_machine(
        &self,
        scope_id: OpaqueId,
        mutation_id: OpaqueId,
    ) -> ProviderResult<CreateMachineResult> {
        self.request(ProviderRequest::CreateMachine(CreateMachineParams { scope_id, mutation_id }))
    }

    pub(crate) fn connect_external_machine(
        &self,
        scope_id: OpaqueId,
        specifier: ExternalMachineSpecifier,
        mutation_id: OpaqueId,
    ) -> ProviderResult<ConnectExternalMachineResult> {
        self.require_capability(EXTERNAL_MACHINE_CONNECT_CAPABILITY)?;
        self.request(ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
            scope_id,
            specifier,
            mutation_id,
        }))
    }

    pub(crate) fn machine_lifecycle_snapshot(
        &self,
        scope_id: OpaqueId,
        known_revision: Option<u64>,
    ) -> ProviderResult<MachineLifecycleSnapshotResult> {
        self.require_capability(MACHINE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::MachineLifecycleSnapshot(MachineLifecycleSnapshotParams {
            scope_id,
            known_revision,
        }))
    }

    pub(crate) fn rename_machine(
        &self,
        params: RenameMachineParams,
    ) -> ProviderResult<MachineMutationResult> {
        self.require_capability(MACHINE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::RenameMachine(params))
    }

    pub(crate) fn delete_machine(
        &self,
        params: MachineMutationParams,
    ) -> ProviderResult<MachineMutationResult> {
        self.require_capability(MACHINE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::DeleteMachine(params))
    }

    pub(crate) fn restore_machine(
        &self,
        params: MachineMutationParams,
    ) -> ProviderResult<MachineMutationResult> {
        self.require_capability(MACHINE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::RestoreMachine(params))
    }

    pub(crate) fn purge_machine(
        &self,
        params: MachineMutationParams,
    ) -> ProviderResult<MachineMutationResult> {
        self.require_capability(MACHINE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::PurgeMachine(params))
    }

    pub(crate) fn open_machine(
        &self,
        machine_id: OpaqueId,
        workspace_mirror_authority: bool,
    ) -> ProviderResult<OpenMachineResult> {
        self.request(ProviderRequest::OpenMachine(OpenMachineParams {
            machine_id,
            workspace_mirror_authority,
        }))
    }

    pub(crate) fn create_workspace(
        &self,
        machine_id: OpaqueId,
        mode: WorkspaceCreateMode,
        mutation_id: OpaqueId,
    ) -> ProviderResult<CreateWorkspaceResult> {
        self.request(ProviderRequest::CreateWorkspace(CreateWorkspaceParams {
            machine_id,
            mode,
            mutation_id,
        }))
    }

    pub(crate) fn workspace_snapshot(
        &self,
        machine_id: OpaqueId,
        known_revision: Option<u64>,
    ) -> ProviderResult<WorkspaceSnapshotResult> {
        self.require_capability(WORKSPACE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::WorkspaceSnapshot(WorkspaceSnapshotParams {
            machine_id,
            known_revision,
        }))
    }

    pub(crate) fn rename_workspace(
        &self,
        params: RenameWorkspaceParams,
    ) -> ProviderResult<WorkspaceMutationResult> {
        self.require_capability(WORKSPACE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::RenameWorkspace(params))
    }

    pub(crate) fn delete_workspace(
        &self,
        params: WorkspaceMutationParams,
    ) -> ProviderResult<WorkspaceMutationResult> {
        self.require_capability(WORKSPACE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::DeleteWorkspace(params))
    }

    pub(crate) fn restore_workspace(
        &self,
        params: WorkspaceMutationParams,
    ) -> ProviderResult<WorkspaceMutationResult> {
        self.require_capability(WORKSPACE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::RestoreWorkspace(params))
    }

    pub(crate) fn purge_workspace(
        &self,
        params: WorkspaceMutationParams,
    ) -> ProviderResult<WorkspaceMutationResult> {
        self.require_capability(WORKSPACE_LIFECYCLE_CAPABILITY)?;
        self.request(ProviderRequest::PurgeWorkspace(params))
    }

    pub(crate) fn invoke_action(
        &self,
        action_id: OpaqueId,
        values: BTreeMap<String, ActionValue>,
        machine_id: Option<OpaqueId>,
        workspace_id: Option<OpaqueId>,
        mutation_id: OpaqueId,
    ) -> ProviderResult<InvokeActionResult> {
        self.request(ProviderRequest::InvokeAction(InvokeActionParams {
            action_id,
            values,
            machine_id,
            workspace_id,
            mutation_id,
        }))
    }

    pub(crate) fn close_machine(
        &self,
        connection_id: OpaqueId,
    ) -> ProviderResult<CloseMachineResult> {
        self.request(ProviderRequest::CloseMachine(CloseMachineParams { connection_id }))
    }

    /// Register this process as a durable-notice consumer.
    ///
    /// Providers may send replayed events before the response. The control
    /// reader retains those deliveries until a local subscriber is installed.
    pub(crate) fn subscribe_notices(
        &self,
        consumer_id: OpaqueId,
    ) -> ProviderResult<SubscribeNoticesResult> {
        self.require_capability(DURABLE_NOTICES_CAPABILITY)?;
        self.inner.begin_notice_subscription()?;
        let result: SubscribeNoticesResult = match self
            .request(ProviderRequest::SubscribeNotices(SubscribeNoticesParams { consumer_id }))
        {
            Ok(result) => result,
            Err(error) => {
                self.inner.cancel_notice_subscription();
                self.inner.mark_disconnected(ReaderFailure::Disconnected);
                return Err(error);
            }
        };
        if let Err(failure) = self.inner.complete_notice_subscription(result.sequence) {
            self.inner.mark_disconnected(failure.clone());
            return Err(failure.into());
        }
        Ok(result)
    }

    /// Acknowledge one visible durable notice and advance its cumulative cursor.
    pub(crate) fn acknowledge_notice(
        &self,
        delivery: NoticeDelivery,
    ) -> ProviderResult<AcknowledgeNoticeResult> {
        self.require_capability(DURABLE_NOTICES_CAPABILITY)?;
        let expected_sequence = delivery.sequence;
        let result: AcknowledgeNoticeResult =
            self.request(ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams {
                notice_id: delivery.notice_id,
                sequence: expected_sequence,
            }))?;
        if result.sequence != expected_sequence {
            return Err(ProviderClientError::Protocol(format!(
                "durable notice acknowledgement returned {} for sequence {expected_sequence}",
                result.sequence
            )));
        }
        self.inner.acknowledge_sequence(result.sequence)?;
        Ok(result)
    }

    /// Subscribe to revision invalidations. Receivers are removed after drop.
    pub(crate) fn subscribe_snapshot_changes(&self) -> ProviderResult<Receiver<u64>> {
        self.ensure_live()?;
        let (sender, receiver) = mpsc::sync_channel(1);
        self.inner
            .snapshot_subscribers
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("subscriber"))?
            .push(sender);
        Ok(receiver)
    }

    /// Subscribe to every provider event, including notices and remote
    /// connection closures. Receivers are removed after drop.
    pub(crate) fn subscribe_events(&self) -> ProviderResult<ProviderEventReceiver> {
        let queue = Arc::new(ProviderEventQueue::new());
        let mut events = self
            .inner
            .events
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("subscriber"))?;
        // Recheck while holding the same lock used by disconnection cleanup so
        // a receiver cannot be registered after the cleanup drain has passed.
        self.ensure_live()?;
        if events.durable_subscription == DurableSubscriptionState::Active {
            for retained in events.retained_durable.iter().cloned() {
                queue.publish(retained).map_err(|()| {
                    ProviderClientError::Protocol(
                        "retained durable notice backlog exceeded subscriber capacity".into(),
                    )
                })?;
            }
        }
        events.subscribers.push(Arc::downgrade(&queue));
        Ok(ProviderEventReceiver { queue })
    }

    pub(crate) fn has_retained_durable_notices(&self) -> ProviderResult<bool> {
        let events =
            self.inner.events.lock().map_err(|_| ProviderClientError::StatePoisoned("event"))?;
        Ok(events.durable_subscription == DurableSubscriptionState::Active
            && !events.retained_durable.is_empty())
    }

    pub(crate) fn is_live(&self) -> bool {
        self.inner.live.load(Ordering::Acquire)
    }

    /// Consume a provider-issued, one-use ticket into cmux's normal remote
    /// session transport. This function deliberately makes one connection and
    /// one handshake attempt. Callers cannot retry because the descriptor is
    /// moved in and the ticket is never returned from an error.
    pub(crate) fn consume_transport(
        &self,
        descriptor: TransportDescriptor,
    ) -> ProviderResult<RemoteTransport> {
        self.ensure_authenticated()?;
        let provider_token = self
            .inner
            .token
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("credential"))?
            .clone()
            .ok_or(ProviderClientError::NotAuthenticated)?;
        let TransportDescriptor::ProviderStream { ticket, expires_at: _ } = descriptor;

        let ProviderIoParts { reader, mut writer, guard } = self.inner.streams.open()?.into_parts();
        let deadline = guard.deadline(PROVIDER_REQUEST_TIMEOUT)?;
        let mut reader = BufReader::new(reader);
        // The child learns this one-use credential only through the handshake.
        // Register it before writing so echoed or traced input is never retained
        // in diagnostics that can be surfaced after a failed handshake.
        guard.add_diagnostic_redaction(ticket.expose());
        let handshake = TransportHandshake {
            protocol: Protocol,
            version: Version,
            role: TransportRole::Transport,
            token: provider_token,
            ticket,
        };
        write_json_frame(&mut writer, &handshake, MAX_CONTROL_FRAME_BYTES)?;

        let response = match read_bounded_frame(&mut reader, MAX_CONTROL_FRAME_BYTES)
            .map_err(ProviderClientError::from)?
        {
            Some(response) => response,
            None if deadline.timed_out() => return Err(ProviderClientError::Timeout),
            None => return Err(disconnected_transport_error(&guard)),
        };
        let result: TransportHandshakeResult = serde_json::from_slice(&response)?;
        if !result.accepted {
            guard.close();
            return Err(ProviderClientError::TransportRejected);
        }

        drop(deadline);
        Ok(RemoteTransport::new(
            Box::new(BoundedRemoteReader { inner: reader, guard: guard.clone() }),
            Box::new(BoundedRemoteWriter { inner: writer, guard: guard.clone() }),
            Arc::new(ProviderRemoteAbort { guard }),
        ))
    }

    fn request<T>(&self, request: ProviderRequest) -> ProviderResult<T>
    where
        T: DeserializeOwned,
    {
        self.ensure_authenticated()?;
        let timeout = if matches!(request, ProviderRequest::OpenMachine(_)) {
            PROVIDER_OPEN_TIMEOUT
        } else {
            PROVIDER_REQUEST_TIMEOUT
        };
        self.request_unchecked(request, timeout)
    }

    pub(crate) fn supports_capability(&self, capability: &str) -> ProviderResult<bool> {
        self.ensure_authenticated()?;
        self.advertises_capability(capability)
    }

    fn advertises_capability(&self, capability: &str) -> ProviderResult<bool> {
        let capabilities = self
            .inner
            .provider_capabilities
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("capabilities"))?;
        Ok(capabilities.iter().any(|candidate| candidate == capability))
    }

    fn negotiate_supported_client_capabilities(&self) -> ProviderResult<()> {
        if !self.advertises_capability(CLIENT_CAPABILITY_NEGOTIATION_CAPABILITY)? {
            return Ok(());
        }
        let requested = vec![
            PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY.to_string(),
            CONNECTION_PROGRESS_CLIENT_CAPABILITY.to_string(),
        ];
        let result: NegotiateClientCapabilitiesResult =
            self.request(ProviderRequest::NegotiateClientCapabilities(
                NegotiateClientCapabilitiesParams { capabilities: requested.clone() },
            ))?;
        if result.capabilities.iter().any(|capability| !requested.contains(capability)) {
            return Err(ProviderClientError::Protocol(
                "provider accepted an unrequested client capability".to_string(),
            ));
        }
        *self
            .inner
            .negotiated_client_capabilities
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("client-capabilities"))? =
            result.capabilities;
        Ok(())
    }

    fn retain_negotiated_actions(&self, snapshot: &mut SnapshotResult) -> ProviderResult<()> {
        let capabilities = self
            .inner
            .negotiated_client_capabilities
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("client-capabilities"))?;
        snapshot.retain_actions_for_client_capabilities(&capabilities);
        Ok(())
    }

    fn require_capability(&self, capability: &'static str) -> ProviderResult<()> {
        self.supports_capability(capability)?
            .then_some(())
            .ok_or(ProviderClientError::UnsupportedCapability(capability))
    }

    fn request_unchecked<T>(&self, request: ProviderRequest, timeout: Duration) -> ProviderResult<T>
    where
        T: DeserializeOwned,
    {
        self.request_unchecked_with_metadata(request, timeout).map(|(result, _)| result)
    }

    fn request_unchecked_with_metadata<T>(
        &self,
        request: ProviderRequest,
        timeout: Duration,
    ) -> ProviderResult<(T, Vec<String>)>
    where
        T: DeserializeOwned,
    {
        self.ensure_live()?;
        let sequence = self.inner.next_request_id.fetch_add(1, Ordering::Relaxed);
        let id = OpaqueId::new(format!("cmux-{sequence}"))
            .map_err(|error| ProviderClientError::Protocol(error.to_string()))?;
        let id_key = id.as_str().to_string();
        let envelope = RequestEnvelope::new(id.clone(), request);
        // A request has exactly one response. Keep one slot so a late or
        // duplicated response cannot accumulate memory after cancellation.
        let (sender, receiver) = mpsc::sync_channel(1);
        {
            let mut pending = self
                .inner
                .pending
                .lock()
                .map_err(|_| ProviderClientError::StatePoisoned("pending-request"))?;
            if pending.insert(id_key.clone(), sender).is_some() {
                return Err(ProviderClientError::Protocol(
                    "request identifier wrapped while still in use".to_string(),
                ));
            }
        }

        let write_result = self
            .inner
            .writer
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("writer"))
            .and_then(|mut writer| {
                write_json_frame(&mut *writer, &envelope, MAX_CONTROL_FRAME_BYTES)
            });
        if let Err(error) = write_result {
            self.remove_pending(&id_key);
            self.inner.mark_disconnected(ReaderFailure::Disconnected);
            return Err(error);
        }

        let mut frame = match receiver.recv_timeout(timeout) {
            Ok(Ok(frame)) => frame,
            Ok(Err(failure)) => return Err(failure.into()),
            Err(RecvTimeoutError::Timeout) => {
                self.remove_pending(&id_key);
                return Err(ProviderClientError::Timeout);
            }
            Err(RecvTimeoutError::Disconnected) => return Err(ProviderClientError::Disconnected),
        };
        let decoded = serde_json::from_slice(&frame);
        frame.zeroize();
        let response: ResponseEnvelope<T> = decoded?;
        if response.id != id {
            return Err(ProviderClientError::Protocol(
                "response identifier did not match its request".to_string(),
            ));
        }
        match response.response {
            ProviderResponse::Success(result) => Ok((result, response.capabilities)),
            ProviderResponse::Failure(error) => Err(ProviderClientError::Provider(error)),
        }
    }

    fn remove_pending(&self, id: &str) {
        if let Ok(mut pending) = self.inner.pending.lock() {
            pending.remove(id);
        }
    }

    fn ensure_live(&self) -> ProviderResult<()> {
        if self.inner.live.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(ProviderClientError::Disconnected)
        }
    }

    fn ensure_authenticated(&self) -> ProviderResult<()> {
        self.ensure_live()?;
        if self.inner.authenticated.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(ProviderClientError::NotAuthenticated)
        }
    }
}

#[cfg(unix)]
impl Drop for ProviderClient {
    fn drop(&mut self) {
        self.inner.live.store(false, Ordering::Release);
        self.inner.cancel_pending(ReaderFailure::Disconnected);
        self.inner.control_guard.close();
        if let Ok(mut token) = self.inner.token.lock() {
            *token = None;
        }
    }
}

#[cfg(unix)]
fn control_reader_loop(
    stream: Box<dyn io::Read + Send>,
    guard: ProviderIoGuard,
    inner: Weak<ProviderClientInner>,
) {
    let mut reader = BufReader::new(stream);
    let failure = loop {
        let frame = match read_bounded_frame(&mut reader, MAX_CONTROL_FRAME_BYTES) {
            Ok(Some(frame)) => frame,
            Ok(None) => {
                break guard.diagnostic().map_or(ReaderFailure::Disconnected, |diagnostic| {
                    ReaderFailure::Io(format!(
                        "machine-provider command disconnected: {diagnostic}"
                    ))
                });
            }
            Err(failure) => break failure.into(),
        };
        let Some(inner) = inner.upgrade() else {
            return;
        };
        if let Err(failure) = dispatch_control_frame(&inner, frame) {
            break failure;
        }
    };
    if let Some(inner) = inner.upgrade() {
        inner.mark_disconnected(failure);
    }
}

#[cfg(unix)]
fn dispatch_control_frame(
    inner: &ProviderClientInner,
    mut frame: Vec<u8>,
) -> Result<(), ReaderFailure> {
    let decoded = serde_json::from_slice(&frame);
    let mut value: Value = match decoded {
        Ok(value) => value,
        Err(error) => {
            frame.zeroize();
            return Err(ReaderFailure::InvalidFrame(error.to_string()));
        }
    };
    let object = value
        .as_object()
        .ok_or_else(|| ReaderFailure::InvalidFrame("top-level frame is not an object".into()))?;
    let has_event = object.contains_key("event");
    let has_id = object.contains_key("id");
    match (has_event, has_id) {
        (true, true) => {
            Err(ReaderFailure::InvalidFrame("frame is both an event and a response".to_string()))
        }
        (true, false) => {
            let event: EventEnvelope = serde_json::from_value(value)
                .map_err(|error| ReaderFailure::InvalidFrame(error.to_string()))?;
            frame.zeroize();
            if event.delivery.is_some() && !matches!(&event.event, ProviderEvent::Notice(_)) {
                return Err(ReaderFailure::InvalidFrame(
                    "durable delivery metadata accompanied a non-notice event".into(),
                ));
            }
            if event.delivery.is_some()
                && !inner
                    .provider_capabilities
                    .lock()
                    .map_err(|_| {
                        ReaderFailure::InvalidFrame("provider capability state is poisoned".into())
                    })?
                    .iter()
                    .any(|capability| capability == DURABLE_NOTICES_CAPABILITY)
            {
                return Err(ReaderFailure::InvalidFrame(
                    "durable delivery metadata was not negotiated".into(),
                ));
            }
            if let ProviderEvent::SnapshotChanged(change) = &event.event {
                inner.publish_snapshot_revision(change.revision);
            }
            inner.publish_event(ReceivedProviderEvent {
                event: event.event,
                delivery: event.delivery,
            })
        }
        (false, true) => {
            let id = object
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| ReaderFailure::InvalidFrame("response id is not a string".into()))?
                .to_string();
            OpaqueId::new(id.clone())
                .map_err(|error| ReaderFailure::InvalidFrame(error.to_string()))?;
            let response = inner
                .pending
                .lock()
                .map_err(|_| ReaderFailure::InvalidFrame("pending state is poisoned".into()))?
                .remove(&id);
            zeroize_json_strings(&mut value);
            if let Some(response) = response {
                match response.try_send(Ok(frame)) {
                    Ok(()) => {}
                    Err(TrySendError::Full(Ok(mut frame)))
                    | Err(TrySendError::Disconnected(Ok(mut frame))) => frame.zeroize(),
                    Err(TrySendError::Full(Err(_))) | Err(TrySendError::Disconnected(Err(_))) => {}
                }
            } else {
                frame.zeroize();
            }
            Ok(())
        }
        (false, false) => {
            Err(ReaderFailure::InvalidFrame("frame is neither an event nor a response".to_string()))
        }
    }
}

#[cfg(unix)]
fn zeroize_json_strings(value: &mut Value) {
    match value {
        Value::String(value) => value.zeroize(),
        Value::Array(values) => values.iter_mut().for_each(zeroize_json_strings),
        Value::Object(values) => values.values_mut().for_each(zeroize_json_strings),
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

#[cfg(unix)]
#[derive(Debug)]
enum FrameReadFailure {
    Io(io::Error),
    TooLarge { limit: usize },
    Truncated,
}

#[cfg(unix)]
impl From<FrameReadFailure> for ReaderFailure {
    fn from(failure: FrameReadFailure) -> Self {
        match failure {
            FrameReadFailure::Io(error) => ReaderFailure::Io(error.to_string()),
            FrameReadFailure::TooLarge { limit } => ReaderFailure::FrameTooLarge { limit },
            FrameReadFailure::Truncated => {
                ReaderFailure::InvalidFrame("unterminated JSON-lines frame".to_string())
            }
        }
    }
}

#[cfg(unix)]
impl From<FrameReadFailure> for ProviderClientError {
    fn from(failure: FrameReadFailure) -> Self {
        ReaderFailure::from(failure).into()
    }
}

#[cfg(unix)]
fn read_bounded_frame<R: BufRead>(
    reader: &mut R,
    limit: usize,
) -> Result<Option<Vec<u8>>, FrameReadFailure> {
    read_bounded_frame_with_progress(reader, limit, &mut |_| {})
}

#[cfg(unix)]
fn read_bounded_frame_with_progress<R: BufRead>(
    reader: &mut R,
    limit: usize,
    on_progress: &mut dyn FnMut(&[u8]),
) -> Result<Option<Vec<u8>>, FrameReadFailure> {
    let mut frame = Vec::new();
    loop {
        let available = reader.fill_buf().map_err(FrameReadFailure::Io)?;
        if available.is_empty() {
            return if frame.is_empty() { Ok(None) } else { Err(FrameReadFailure::Truncated) };
        }

        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            if frame.len().saturating_add(newline) > limit {
                return Err(FrameReadFailure::TooLarge { limit });
            }
            frame.extend_from_slice(&available[..newline]);
            reader.consume(newline + 1);
            on_progress(&frame);
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return Ok(Some(frame));
        }

        if frame.len().saturating_add(available.len()) > limit {
            return Err(FrameReadFailure::TooLarge { limit });
        }
        let consumed = available.len();
        frame.extend_from_slice(available);
        reader.consume(consumed);
        on_progress(&frame);
    }
}

#[cfg(unix)]
fn write_json_frame<W: Write, T: Serialize>(
    writer: &mut W,
    value: &T,
    limit: usize,
) -> ProviderResult<()> {
    let mut encoded = serde_json::to_vec(value)?;
    if encoded.len() > limit {
        encoded.zeroize();
        return Err(ProviderClientError::FrameTooLarge { limit });
    }
    let result = writer
        .write_all(&encoded)
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush());
    // Frames can contain credentials. Clear the reusable allocation before it
    // is freed so normal allocator reuse does not expose their serialized form.
    encoded.zeroize();
    result.map_err(ProviderClientError::Io)
}

#[cfg(unix)]
struct BoundedRemoteReader {
    inner: BufReader<Box<dyn io::Read + Send>>,
    guard: ProviderIoGuard,
}

#[cfg(unix)]
impl RemoteMessageReader for BoundedRemoteReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        self.receive_with_progress(&mut |_| {})
    }

    fn receive_with_progress(
        &mut self,
        on_progress: &mut dyn FnMut(&[u8]),
    ) -> io::Result<Option<String>> {
        let frame = read_bounded_frame_with_progress(
            &mut self.inner,
            MAX_TRANSPORT_FRAME_BYTES,
            on_progress,
        )
        .map_err(frame_read_io_error)?;
        frame
            .map(|bytes| {
                String::from_utf8(bytes)
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
            })
            .transpose()
    }
}

#[cfg(unix)]
struct BoundedRemoteWriter {
    inner: Box<dyn Write + Send>,
    guard: ProviderIoGuard,
}

#[cfg(unix)]
struct ProviderRemoteAbort {
    guard: ProviderIoGuard,
}

#[cfg(unix)]
impl RemoteTransportAbort for ProviderRemoteAbort {
    fn abort(&self) -> io::Result<()> {
        self.guard.close();
        Ok(())
    }
}

#[cfg(unix)]
impl RemoteMessageWriter for BoundedRemoteWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        if message.len() > MAX_TRANSPORT_FRAME_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("remote frame exceeds the {MAX_TRANSPORT_FRAME_BYTES}-byte limit"),
            ));
        }
        if message.bytes().any(|byte| byte == b'\n' || byte == b'\r') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "remote message contains a JSON-lines delimiter",
            ));
        }
        self.inner.write_all(message.as_bytes())?;
        self.inner.write_all(b"\n")?;
        self.inner.flush()
    }

    fn close(&mut self) -> io::Result<()> {
        self.guard.close();
        Ok(())
    }
}

#[cfg(unix)]
fn disconnected_transport_error(guard: &ProviderIoGuard) -> ProviderClientError {
    guard.diagnostic().map_or(ProviderClientError::Disconnected, |diagnostic| {
        ProviderClientError::Io(io::Error::other(format!(
            "machine-provider command disconnected: {diagnostic}"
        )))
    })
}

#[cfg(unix)]
fn frame_read_io_error(failure: FrameReadFailure) -> io::Error {
    match failure {
        FrameReadFailure::Io(error) => error,
        FrameReadFailure::TooLarge { limit } => io::Error::new(
            io::ErrorKind::InvalidData,
            format!("remote frame exceeds the {limit}-byte limit"),
        ),
        FrameReadFailure::Truncated => {
            io::Error::new(io::ErrorKind::UnexpectedEof, "unterminated JSON-lines frame")
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::{Arc, mpsc};
    use std::thread;
    use std::time::{Duration, Instant};

    use cmux_tui_machine_protocol::{
        ConnectionClosedEvent, EventEnvelope, HelloResult, NoticeLevel, OpenMachineResult,
        ProviderErrorCode, ProviderNotice, ResponseEnvelope, SnapshotChangedEvent,
        TransportDescriptor, TransportHandshake,
    };

    use super::*;

    static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(1);

    struct TestSocket {
        path: PathBuf,
        listener: UnixListener,
    }

    impl TestSocket {
        fn bind() -> Self {
            let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("cmux-machine-provider-client-{}-{id}.sock", std::process::id()));
            let _ = fs::remove_file(&path);
            let listener = UnixListener::bind(&path).expect("bind fake provider socket");
            Self { path, listener }
        }

        fn listener(&self) -> UnixListener {
            self.listener.try_clone().expect("clone fake provider listener")
        }
    }

    #[test]
    fn a_full_snapshot_queue_coalesces_without_unsubscribing() {
        let socket = TestSocket::bind();
        let provider = ProviderClient::connect(&socket.path).expect("connect provider client");
        let (sender, receiver) = mpsc::sync_channel(1);
        provider.inner.snapshot_subscribers.lock().unwrap().push(sender);

        provider.inner.publish_snapshot_revision(1);
        provider.inner.publish_snapshot_revision(2);
        assert_eq!(receiver.recv().unwrap(), 1);

        provider.inner.publish_snapshot_revision(3);
        assert_eq!(receiver.recv().unwrap(), 3);
        assert_eq!(provider.inner.snapshot_subscribers.lock().unwrap().len(), 1);
    }

    impl Drop for TestSocket {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.path);
        }
    }

    fn id(value: &str) -> OpaqueId {
        OpaqueId::new(value).expect("valid test id")
    }

    fn token(value: &str) -> BearerToken {
        BearerToken::new(value).expect("valid test token")
    }

    fn received(event: ProviderEvent) -> ReceivedProviderEvent {
        ReceivedProviderEvent { event, delivery: None }
    }

    fn durable_notice(notice_id: &str, sequence: u64, message: &str) -> ReceivedProviderEvent {
        ReceivedProviderEvent {
            event: ProviderEvent::Notice(ProviderNotice {
                level: NoticeLevel::Warning,
                message: message.to_string(),
            }),
            delivery: Some(NoticeDelivery { notice_id: id(notice_id), sequence }),
        }
    }

    fn client_descriptor() -> ClientDescriptor {
        ClientDescriptor {
            name: "cmux-test".to_string(),
            version: "0.1.0".to_string(),
            supported_versions: vec![1],
        }
    }

    fn read_test_frame<T: DeserializeOwned>(reader: &mut BufReader<UnixStream>) -> T {
        let frame = read_bounded_frame(reader, MAX_CONTROL_FRAME_BYTES)
            .expect("read fake provider frame")
            .expect("fake provider peer disconnected");
        serde_json::from_slice(&frame).expect("decode fake provider frame")
    }

    fn write_test_frame<T: Serialize>(stream: &mut UnixStream, frame: &T) {
        write_json_frame(stream, frame, MAX_CONTROL_FRAME_BYTES)
            .expect("write fake provider frame");
    }

    fn accept_hello(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        expected_token: &str,
    ) {
        accept_hello_with_capabilities(stream, reader, expected_token, &[]);
    }

    fn accept_hello_with_capabilities(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        expected_token: &str,
        capabilities: &[&str],
    ) {
        let request: RequestEnvelope = read_test_frame(reader);
        let ProviderRequest::Hello(params) = request.request else {
            panic!("first request was not hello");
        };
        assert_eq!(params.token.expose(), expected_token);
        assert_eq!(params.client, client_descriptor());
        write_test_frame(
            stream,
            &ResponseEnvelope::success(
                request.id,
                HelloResult {
                    provider_id: id("fake-provider"),
                    provider_name: "Fake Provider".to_string(),
                    negotiated_version: Version,
                },
            )
            .with_capabilities(capabilities.iter().copied()),
        );
    }

    #[test]
    fn hello_capabilities_enable_only_advertised_lifecycle_requests() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello_with_capabilities(
                &mut stream,
                &mut reader,
                "provider-secret",
                &[MACHINE_LIFECYCLE_CAPABILITY],
            );

            let request: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(
                &request.request,
                ProviderRequest::MachineLifecycleSnapshot(params)
                    if params.scope_id == id("personal")
            ));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(
                    request.id,
                    MachineLifecycleSnapshotResult {
                        revision: 1,
                        scope_id: id("personal"),
                        machines: Vec::new(),
                    },
                ),
            );

            stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let mut unexpected = String::new();
            match reader.read_line(&mut unexpected) {
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) => {}
                Ok(0) => panic!("provider client disconnected while authenticated"),
                Ok(_) => panic!("provider received an unadvertised request: {unexpected}"),
                Err(error) => panic!("provider read failed: {error}"),
            }
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        assert!(provider.supports_capability(MACHINE_LIFECYCLE_CAPABILITY).unwrap());
        assert!(!provider.supports_capability(WORKSPACE_LIFECYCLE_CAPABILITY).unwrap());
        provider
            .machine_lifecycle_snapshot(id("personal"), None)
            .expect("advertised machine lifecycle request");
        let error = provider
            .workspace_snapshot(id("machine-1"), None)
            .expect_err("unadvertised workspace lifecycle must be rejected locally");
        assert!(matches!(
            error,
            ProviderClientError::UnsupportedCapability(WORKSPACE_LIFECYCLE_CAPABILITY)
        ));
        let error = provider
            .connect_external_machine(
                id("team"),
                ExternalMachineSpecifier::new("PAIR 4J7K").unwrap(),
                id("connect-mutation"),
            )
            .expect_err("unadvertised external-machine connect must be rejected locally");
        assert!(matches!(
            error,
            ProviderClientError::UnsupportedCapability(EXTERNAL_MACHINE_CONNECT_CAPABILITY)
        ));

        server.join().expect("join fake provider");
    }

    #[test]
    fn durable_notice_subscription_retains_pre_receiver_delivery_and_acknowledges_it() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello_with_capabilities(
                &mut stream,
                &mut reader,
                "provider-secret",
                &[DURABLE_NOTICES_CAPABILITY],
            );

            let subscribe: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(
                subscribe.request,
                ProviderRequest::SubscribeNotices(SubscribeNoticesParams {
                    ref consumer_id
                }) if consumer_id == &id("cmux-process-1")
            ));
            let delivery = NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 };
            let notice = ProviderNotice {
                level: NoticeLevel::Warning,
                message: "trial has one hour remaining".to_string(),
            };
            write_test_frame(
                &mut stream,
                &EventEnvelope::with_delivery(
                    ProviderEvent::Notice(notice.clone()),
                    delivery.clone(),
                ),
            );
            // A replay before ACK has the same stable identity and must not
            // create a second local delivery.
            write_test_frame(
                &mut stream,
                &EventEnvelope::with_delivery(ProviderEvent::Notice(notice), delivery),
            );
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 0 }),
            );

            let acknowledge: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(
                acknowledge.request,
                ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams {
                    ref notice_id,
                    sequence: 1,
                }) if notice_id == &id("usage-warning-80")
            ));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(acknowledge.id, AcknowledgeNoticeResult { sequence: 1 }),
            );
            finished.recv().expect("hold provider connection open");
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        assert_eq!(
            provider.subscribe_notices(id("cmux-process-1")).unwrap(),
            SubscribeNoticesResult { sequence: 0 }
        );
        assert!(
            provider.has_retained_durable_notices().unwrap(),
            "replayed durable notice was not retained before the local receiver subscribed"
        );

        let events = provider.subscribe_events().expect("subscribe to retained events");
        let received =
            events.recv_timeout(Duration::from_secs(2)).expect("receive retained durable notice");
        assert_eq!(
            received.delivery,
            Some(NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 })
        );
        assert!(matches!(
            received.event,
            ProviderEvent::Notice(ProviderNotice {
                level: NoticeLevel::Warning,
                ref message,
            }) if message == "trial has one hour remaining"
        ));
        assert_eq!(
            events.recv_timeout(Duration::from_millis(20)),
            Err(RecvTimeoutError::Timeout),
            "duplicate replay was delivered twice"
        );

        provider
            .acknowledge_notice(received.delivery.expect("durable metadata"))
            .expect("acknowledge durable notice");
        assert!(
            !provider.has_retained_durable_notices().unwrap(),
            "acknowledged durable notice still appeared in the retained-notice query"
        );
        let after_ack = provider.subscribe_events().expect("resubscribe after ACK");
        assert_eq!(
            after_ack.recv_timeout(Duration::from_millis(20)),
            Err(RecvTimeoutError::Timeout),
            "acknowledged notice remained in the retained backlog"
        );

        finish.send(()).expect("finish provider server");
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn durable_notice_replay_waits_for_the_resumed_subscription_cursor() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello_with_capabilities(
                &mut stream,
                &mut reader,
                "provider-secret",
                &[DURABLE_NOTICES_CAPABILITY],
            );

            let subscribe: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(
                subscribe.request,
                ProviderRequest::SubscribeNotices(SubscribeNoticesParams {
                    ref consumer_id
                }) if consumer_id == &id("cmux-process-1")
            ));
            for (notice_id, sequence) in [("usage-warning-90", 42), ("usage-warning-91", 43)] {
                write_test_frame(
                    &mut stream,
                    &EventEnvelope::with_delivery(
                        ProviderEvent::Notice(ProviderNotice {
                            level: NoticeLevel::Warning,
                            message: format!("trial warning {sequence}"),
                        }),
                        NoticeDelivery { notice_id: id(notice_id), sequence },
                    ),
                );
            }
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 41 }),
            );
            finished.recv().expect("hold provider connection open");
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        assert_eq!(
            provider.subscribe_notices(id("cmux-process-1")).expect("resume durable subscription"),
            SubscribeNoticesResult { sequence: 41 }
        );
        assert!(provider.is_live(), "valid replay closed the provider connection");
        let events = provider.subscribe_events().expect("subscribe to retained events");
        let first = events
            .recv_timeout(Duration::from_secs(2))
            .expect("receive first replay after cursor initialization");
        assert_eq!(
            first.delivery,
            Some(NoticeDelivery { notice_id: id("usage-warning-90"), sequence: 42 })
        );
        assert!(matches!(
            first.event,
            ProviderEvent::Notice(ProviderNotice { ref message, .. }) if message == "trial warning 42"
        ));
        let second = events
            .recv_timeout(Duration::from_secs(2))
            .expect("receive second replay after cursor initialization");
        assert_eq!(
            second.delivery,
            Some(NoticeDelivery { notice_id: id("usage-warning-91"), sequence: 43 })
        );
        assert!(matches!(
            second.event,
            ProviderEvent::Notice(ProviderNotice { ref message, .. }) if message == "trial warning 43"
        ));

        finish.send(()).expect("finish provider server");
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn durable_notice_methods_are_rejected_without_the_capability() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let mut unexpected = String::new();
            match reader.read_line(&mut unexpected) {
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) => {}
                Ok(0) => {}
                Ok(_) => panic!("provider received an unadvertised request: {unexpected}"),
                Err(error) => panic!("provider read failed: {error}"),
            }
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        assert!(matches!(
            provider.subscribe_notices(id("cmux-process-1")),
            Err(ProviderClientError::UnsupportedCapability(DURABLE_NOTICES_CAPABILITY))
        ));
        assert!(matches!(
            provider.acknowledge_notice(NoticeDelivery {
                notice_id: id("usage-warning-80"),
                sequence: 1,
            }),
            Err(ProviderClientError::UnsupportedCapability(DURABLE_NOTICES_CAPABILITY))
        ));

        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn unnegotiated_durable_delivery_fails_the_control_connection_closed() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            write_test_frame(
                &mut stream,
                &EventEnvelope::with_delivery(
                    ProviderEvent::Notice(ProviderNotice {
                        level: NoticeLevel::Warning,
                        message: "unnegotiated".into(),
                    }),
                    NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 },
                ),
            );
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let deadline = Instant::now() + Duration::from_secs(1);
        while provider.is_live() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(5));
        }
        assert!(!provider.is_live(), "unnegotiated durable delivery remained connected");
        assert!(provider.subscribe_events().is_err());
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn durable_notice_sequences_must_be_contiguous() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello_with_capabilities(
                &mut stream,
                &mut reader,
                "provider-secret",
                &[DURABLE_NOTICES_CAPABILITY],
            );
            let subscribe: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(subscribe.request, ProviderRequest::SubscribeNotices(_)));
            write_test_frame(
                &mut stream,
                &EventEnvelope::with_delivery(
                    ProviderEvent::Notice(ProviderNotice {
                        level: NoticeLevel::Warning,
                        message: "skipped".into(),
                    }),
                    NoticeDelivery { notice_id: id("usage-warning-skipped"), sequence: 2 },
                ),
            );
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 0 }),
            );
            finished.recv().expect("hold provider connection open");
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        assert!(provider.subscribe_notices(id("cmux-process-1")).is_err());
        assert!(!provider.is_live());
        finish.send(()).expect("finish provider server");
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn acknowledge_notice_requires_the_exact_provider_cursor() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello_with_capabilities(
                &mut stream,
                &mut reader,
                "provider-secret",
                &[DURABLE_NOTICES_CAPABILITY],
            );
            let subscribe: RequestEnvelope = read_test_frame(&mut reader);
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 0 }),
            );
            let acknowledge: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(
                acknowledge.request,
                ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams { sequence: 1, .. })
            ));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(acknowledge.id, AcknowledgeNoticeResult { sequence: 2 }),
            );
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        provider.subscribe_notices(id("cmux-process-1")).expect("subscribe notices");
        let error = provider
            .acknowledge_notice(NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 })
            .expect_err("provider advanced past the requested notice");
        assert!(matches!(
            error,
            ProviderClientError::Protocol(ref message)
                if message.contains("returned 2 for sequence 1")
        ));
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn external_machine_connect_replays_one_idempotent_provider_result() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello_with_capabilities(
                &mut stream,
                &mut reader,
                "provider-secret",
                &[EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );

            for _ in 0..2 {
                let request: RequestEnvelope = read_test_frame(&mut reader);
                let ProviderRequest::ConnectExternalMachine(params) = request.request else {
                    panic!("expected connect_external_machine request");
                };
                assert_eq!(params.scope_id, id("team"));
                assert_eq!(params.specifier.expose(), "PAIR 4J7K");
                assert_eq!(params.mutation_id, id("connect-mutation"));
                write_test_frame(
                    &mut stream,
                    &ResponseEnvelope::success(
                        request.id,
                        ConnectExternalMachineResult {
                            machine_id: id("paired-machine"),
                            revision: 8,
                            notice: Some(ProviderNotice {
                                level: NoticeLevel::Info,
                                message: "Machine connected".into(),
                            }),
                        },
                    ),
                );
            }
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let connect = || {
            provider.connect_external_machine(
                id("team"),
                ExternalMachineSpecifier::new("PAIR 4J7K").unwrap(),
                id("connect-mutation"),
            )
        };
        let first = connect().expect("connect external machine");
        let replay = connect().expect("replay external-machine mutation");

        assert_eq!(replay, first);
        assert_eq!(first.machine_id, id("paired-machine"));
        assert_eq!(first.revision, 8);
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn authenticates_once_and_delivers_general_and_snapshot_events() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let (send_event, receive_event) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            receive_event.recv().expect("wait for subscriber");
            write_test_frame(
                &mut stream,
                &EventEnvelope::new(ProviderEvent::SnapshotChanged(SnapshotChangedEvent {
                    revision: 42,
                })),
            );
            write_test_frame(
                &mut stream,
                &EventEnvelope::new(ProviderEvent::Notice(ProviderNotice {
                    level: NoticeLevel::Warning,
                    message: "trial has one day remaining".to_string(),
                })),
            );
            write_test_frame(
                &mut stream,
                &EventEnvelope::new(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                    connection_id: id("connection-1"),
                    machine_id: id("machine-1"),
                    reason: "machine suspended".to_string(),
                })),
            );
        });

        let (provider, hello) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        assert_eq!(hello.provider_id, id("fake-provider"));
        assert!(format!("{:?}", token("provider-secret")).contains("[redacted]"));
        assert!(matches!(
            provider.hello(token("do-not-replay"), client_descriptor()),
            Err(ProviderClientError::AlreadyAuthenticated)
        ));

        let events = provider.subscribe_events().expect("subscribe to all events");
        let revisions =
            provider.subscribe_snapshot_changes().expect("subscribe to snapshot changes");
        send_event.send(()).expect("trigger provider event");
        let event = events.recv_timeout(Duration::from_secs(2)).expect("receive provider event");
        assert!(matches!(
            event.event,
            ProviderEvent::SnapshotChanged(SnapshotChangedEvent { revision: 42 })
        ));
        let event = events.recv_timeout(Duration::from_secs(2)).expect("receive provider notice");
        assert!(matches!(
            event.event,
            ProviderEvent::Notice(ProviderNotice {
                level: NoticeLevel::Warning,
                ref message,
            }) if message == "trial has one day remaining"
        ));
        let event =
            events.recv_timeout(Duration::from_secs(2)).expect("receive connection closure");
        assert!(matches!(
            event.event,
            ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                ref connection_id,
                ref machine_id,
                ref reason,
            }) if connection_id == &id("connection-1")
                && machine_id == &id("machine-1")
                && reason == "machine suspended"
        ));
        assert_eq!(revisions.recv_timeout(Duration::from_secs(2)).expect("receive revision"), 42);
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn full_event_queue_preserves_connection_closed_control_state() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let (send_events, receive_events) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            receive_events.recv().expect("wait for subscriber");
            for index in 0..PROVIDER_EVENT_QUEUE_CAPACITY {
                write_test_frame(
                    &mut stream,
                    &EventEnvelope::new(ProviderEvent::Notice(ProviderNotice {
                        level: NoticeLevel::Info,
                        message: format!("queued notice {index}"),
                    })),
                );
            }
            write_test_frame(
                &mut stream,
                &EventEnvelope::new(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                    connection_id: id("revoked-connection"),
                    machine_id: id("machine-1"),
                    reason: "machine access revoked".to_string(),
                })),
            );

            // The response is ordered after every event on the provider stream.
            // Receiving it proves the client reader has handled the saturated burst.
            let request: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(
                    request.id,
                    SnapshotResult {
                        revision: 1,
                        scopes: Vec::new(),
                        selected_scope_id: id("personal"),
                        machines: Vec::new(),
                        selected_machine_id: None,
                        capabilities: cmux_tui_machine_protocol::ProviderCapabilities {
                            create_machine: false,
                            connect_external_machine: false,
                        },
                        actions: Vec::new(),
                        notice: None,
                    },
                ),
            );
            finished.recv().expect("hold provider connection open");
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let events = provider.subscribe_events().expect("subscribe to all events");
        send_events.send(()).expect("trigger provider events");
        provider.snapshot(None).expect("synchronize after event burst");

        let mut saw_closure = false;
        while let Ok(event) = events.recv_timeout(Duration::from_millis(20)) {
            if matches!(
                event.event,
                ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                    ref connection_id,
                    ref machine_id,
                    ..
                }) if connection_id == &id("revoked-connection")
                    && machine_id == &id("machine-1")
            ) {
                saw_closure = true;
                break;
            }
        }
        finish.send(()).expect("finish provider server");
        drop(provider);
        server.join().expect("join fake provider");

        assert!(saw_closure, "connection closure was dropped behind best-effort events");
    }

    #[test]
    fn repeated_connection_closed_events_coalesce_the_latest_reason() {
        let queue = Arc::new(ProviderEventQueue::new());
        let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
        for index in 0..(PROVIDER_EVENT_QUEUE_CAPACITY * 2) {
            queue
                .publish(received(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                    connection_id: id("connection-1"),
                    machine_id: id("machine-1"),
                    reason: format!("revision {index}"),
                })))
                .unwrap();
        }

        let event = events
            .recv_timeout(Duration::from_millis(20))
            .expect("receive coalesced connection closure");
        assert!(matches!(
            event.event,
            ProviderEvent::ConnectionClosed(ConnectionClosedEvent { ref reason, .. })
                if reason == &format!("revision {}", PROVIDER_EVENT_QUEUE_CAPACITY * 2 - 1)
        ));
        assert_eq!(events.recv_timeout(Duration::from_millis(1)), Err(RecvTimeoutError::Timeout));
    }

    #[test]
    fn durable_notices_displace_best_effort_events_and_coalesce_by_notice_id() {
        let queue = Arc::new(ProviderEventQueue::new());
        let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
        for index in 0..PROVIDER_EVENT_QUEUE_CAPACITY {
            queue
                .publish(received(ProviderEvent::Notice(ProviderNotice {
                    level: NoticeLevel::Info,
                    message: format!("best effort {index}"),
                })))
                .unwrap();
        }

        queue.publish(durable_notice("usage-warning-80", 1, "stable message")).unwrap();
        queue.publish(durable_notice("usage-warning-80", 1, "stable message")).unwrap();

        let mut received_count = 0;
        let mut durable_messages = Vec::new();
        while let Ok(event) = events.recv_timeout(Duration::from_millis(1)) {
            received_count += 1;
            if event.delivery.is_some()
                && let ProviderEvent::Notice(notice) = event.event
            {
                durable_messages.push(notice.message);
            }
        }
        assert_eq!(received_count, PROVIDER_EVENT_QUEUE_CAPACITY);
        assert_eq!(durable_messages, vec!["stable message"]);
    }

    #[test]
    fn distinct_durable_notice_burst_fails_closed_at_priority_capacity() {
        let queue = Arc::new(ProviderEventQueue::new());
        let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
        for index in 0..PROVIDER_EVENT_QUEUE_CAPACITY {
            queue
                .publish(durable_notice(
                    &format!("usage-warning-{index}"),
                    index as u64 + 1,
                    "usage warning",
                ))
                .unwrap();
        }
        assert!(
            queue
                .publish(durable_notice(
                    "usage-warning-overflow",
                    PROVIDER_EVENT_QUEUE_CAPACITY as u64 + 1,
                    "overflow",
                ))
                .is_err()
        );

        let state = queue.state.lock().unwrap();
        assert!(state.events.is_empty());
        assert!(state.disconnected, "durable overflow must force a provider resync");
        drop(state);
        assert_eq!(
            events.recv_timeout(Duration::from_millis(1)),
            Err(RecvTimeoutError::Disconnected)
        );
    }

    #[test]
    fn durable_notice_id_cannot_change_sequence() {
        let queue = Arc::new(ProviderEventQueue::new());
        let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
        queue.publish(durable_notice("usage-warning-80", 1, "first")).unwrap();
        assert!(queue.publish(durable_notice("usage-warning-80", 2, "changed")).is_err());
        assert_eq!(
            events.recv_timeout(Duration::from_millis(1)),
            Err(RecvTimeoutError::Disconnected)
        );
    }

    #[test]
    fn durable_notice_replay_cannot_change_content() {
        let queue = Arc::new(ProviderEventQueue::new());
        let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
        queue.publish(durable_notice("usage-warning-80", 1, "first")).unwrap();
        assert!(queue.publish(durable_notice("usage-warning-80", 1, "changed")).is_err());
        assert_eq!(
            events.recv_timeout(Duration::from_millis(1)),
            Err(RecvTimeoutError::Disconnected)
        );
    }

    #[test]
    fn distinct_connection_closed_burst_fails_closed_at_priority_capacity() {
        let queue = Arc::new(ProviderEventQueue::new());
        let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
        for index in 0..=PROVIDER_EVENT_QUEUE_CAPACITY {
            let _ =
                queue.publish(received(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                    connection_id: id(&format!("connection-{index}")),
                    machine_id: id(&format!("machine-{index}")),
                    reason: "connection revoked".into(),
                })));
        }

        let state = queue.state.lock().unwrap();
        assert!(state.events.len() <= PROVIDER_EVENT_QUEUE_CAPACITY);
        assert!(state.disconnected, "priority overflow must force a provider resync");
        drop(state);
        assert_eq!(
            events.recv_timeout(Duration::from_millis(1)),
            Err(RecvTimeoutError::Disconnected)
        );
    }

    #[test]
    fn preserves_typed_provider_errors() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            let request: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::<SnapshotResult>::failure(
                    request.id,
                    ProviderError {
                        code: ProviderErrorCode::PermissionDenied,
                        message: "team access was revoked".to_string(),
                        retryable: false,
                    },
                ),
            );
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let error = provider.snapshot(None).expect_err("snapshot should be rejected");
        let ProviderClientError::Provider(error) = error else {
            panic!("expected typed provider error, got {error:?}");
        };
        assert_eq!(error.code, ProviderErrorCode::PermissionDenied);
        assert_eq!(error.message, "team access was revoked");
        assert!(!error.retryable);
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn rejects_oversized_control_frame_without_waiting_for_timeout() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            let request: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
            let accept_rejection_close = |result: io::Result<()>| {
                if let Err(error) = result {
                    assert!(
                        matches!(
                            error.kind(),
                            io::ErrorKind::BrokenPipe
                                | io::ErrorKind::ConnectionAborted
                                | io::ErrorKind::ConnectionReset
                        ),
                        "write oversized frame: {error}"
                    );
                }
            };
            accept_rejection_close(stream.write_all(&vec![b'x'; MAX_CONTROL_FRAME_BYTES + 1]));
            accept_rejection_close(stream.write_all(b"\n"));
            accept_rejection_close(stream.flush());
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let started = Instant::now();
        let error = provider.snapshot(None).expect_err("oversized response must fail");
        assert!(matches!(
            error,
            ProviderClientError::FrameTooLarge { limit: MAX_CONTROL_FRAME_BYTES }
        ));
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(provider);
        server.join().expect("join fake provider");
    }

    #[test]
    fn consumes_transport_ticket_in_exactly_one_handshake() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let handshakes = Arc::new(AtomicUsize::new(0));
        let server_handshakes = handshakes.clone();
        let server = thread::spawn(move || {
            let (mut control, _) = listener.accept().expect("accept control socket");
            let mut control_reader =
                BufReader::new(control.try_clone().expect("clone control socket"));
            accept_hello(&mut control, &mut control_reader, "provider-secret");

            let request: RequestEnvelope = read_test_frame(&mut control_reader);
            let ProviderRequest::OpenMachine(params) = request.request else {
                panic!("expected open_machine request");
            };
            assert_eq!(params.machine_id, id("machine-1"));
            write_test_frame(
                &mut control,
                &ResponseEnvelope::success(
                    request.id,
                    OpenMachineResult {
                        connection_id: id("connection-1"),
                        transport: TransportDescriptor::ProviderStream {
                            ticket: token("one-use-ticket"),
                            expires_at: "2026-07-21T12:00:00Z".to_string(),
                        },
                        workspace_mirror_authority: None,
                    },
                ),
            );

            let (mut transport, _) = listener.accept().expect("accept transport socket");
            let mut transport_reader =
                BufReader::new(transport.try_clone().expect("clone transport socket"));
            let mut handshake_frame = String::new();
            transport_reader
                .read_line(&mut handshake_frame)
                .expect("read exact transport handshake");
            assert_eq!(
                handshake_frame,
                concat!(
                    r#"{"protocol":"cmux.machine-provider","version":1,"role":"transport","token":"provider-secret","ticket":"one-use-ticket"}"#,
                    "\n"
                ),
                "transport-neutral connectors must preserve the v1 handshake bytes"
            );
            let handshake: TransportHandshake =
                serde_json::from_str(handshake_frame.trim_end()).expect("decode handshake");
            server_handshakes.fetch_add(1, Ordering::Relaxed);
            assert_eq!(handshake.role, TransportRole::Transport);
            assert_eq!(handshake.token.expose(), "provider-secret");
            assert_eq!(handshake.ticket.expose(), "one-use-ticket");
            write_test_frame(&mut transport, &TransportHandshakeResult { accepted: true });
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let opened = provider.open_machine(id("machine-1"), false).expect("open machine");
        let transport =
            provider.consume_transport(opened.transport).expect("consume one-use transport ticket");
        drop(transport);
        drop(provider);
        server.join().expect("join fake provider");
        assert_eq!(handshakes.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn redacts_transport_ticket_from_command_stream_diagnostics() {
        let script_path = std::env::temp_dir().join(format!(
            "cmux-machine-provider-ticket-redaction-{}-{}.sh",
            std::process::id(),
            NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::write(
            &script_path,
            concat!(
                "#!/bin/sh\n",
                "set -eu\n",
                "role=$1\n",
                "if [ \"$role\" = control ]; then\n",
                "  IFS= read -r _hello\n",
                "  printf '%s\\n' '{\"protocol\":\"cmux.machine-provider\",\"version\":1,\"id\":\"cmux-1\",\"result\":{\"provider_id\":\"fake-provider\",\"provider_name\":\"Fake Provider\",\"negotiated_version\":1}}'\n",
                "  IFS= read -r _open\n",
                "  printf '%s\\n' '{\"protocol\":\"cmux.machine-provider\",\"version\":1,\"id\":\"cmux-2\",\"result\":{\"connection_id\":\"connection-1\",\"transport\":{\"kind\":\"provider_stream\",\"ticket\":\"one-use-ticket\",\"expires_at\":\"2026-07-21T12:00:00Z\"}}}'\n",
                "  while IFS= read -r _line; do :; done\n",
                "else\n",
                "  IFS= read -r handshake\n",
                "  printf '%s\\n' \"$handshake\" >&2\n",
                // Fill more than the stderr pipe so the diagnostic worker must
                // consume the handshake before the process can close stdout.
                "  i=0\n",
                "  while [ \"$i\" -lt 20000 ]; do\n",
                "    printf ' diagnostic-padding' >&2\n",
                "    i=$((i + 1))\n",
                "  done\n",
                "fi\n",
            ),
        )
        .expect("write provider command");
        fs::set_permissions(&script_path, fs::Permissions::from_mode(0o700))
            .expect("make provider command executable");

        let connector = Arc::new(
            CommandProviderConnector::new([script_path.clone().into_os_string()])
                .expect("create command connector"),
        );
        let (provider, _) =
            ProviderClient::connect_authenticated_with(connector, client_descriptor())
                .expect("authenticate command provider");
        let opened = provider.open_machine(id("machine-1"), false).expect("open machine");
        let Err(error) = provider.consume_transport(opened.transport) else {
            panic!("stream command must disconnect during its handshake");
        };
        let diagnostic = error.to_string();

        drop(provider);
        let _ = fs::remove_file(script_path);
        assert!(diagnostic.contains("[redacted]"), "credential was not redacted: {diagnostic}");
        assert!(
            !diagnostic.contains("one-use-ticket"),
            "one-use transport ticket leaked through diagnostics"
        );
    }

    #[test]
    fn cancels_pending_request_when_provider_reaches_eof() {
        let socket = TestSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");
            let request: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
            // Dropping the stream produces EOF while the request is pending.
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        let started = Instant::now();
        let error = provider.snapshot(None).expect_err("EOF must cancel the request");
        assert!(matches!(error, ProviderClientError::Disconnected));
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(provider);
        server.join().expect("join fake provider");
    }
}
