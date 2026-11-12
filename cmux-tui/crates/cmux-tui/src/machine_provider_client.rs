//! Synchronous client for the versioned machine-provider protocol.
//!
//! `machine_provider_runtime` uses this client to back the machine controller,
//! while startup's provider CLI and configuration paths select the transport
//! connector. This module owns the security and framing boundary between a
//! provider daemon and cmux's existing `RemoteTransport` abstraction, keeping
//! provider requests, events, authentication, and one-use stream tickets out
//! of the runtime and UI layers.

#[cfg(unix)]
use std::collections::{HashMap, VecDeque};
#[cfg(unix)]
use std::fmt;
#[cfg(unix)]
use std::io::{self, BufRead, BufReader, Write};
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(unix)]
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender, TrySendError};
#[cfg(unix)]
use std::sync::{Arc, Condvar, Mutex, Weak};
#[cfg(unix)]
use std::time::{Duration, Instant};

#[cfg(unix)]
use cmux_tui_machine_protocol::{
    AcknowledgeNoticeParams, AcknowledgeNoticeResult, BearerToken,
    CLIENT_CAPABILITY_NEGOTIATION_CAPABILITY, CONNECTION_PROGRESS_CLIENT_CAPABILITY,
    ClientDescriptor, CloseMachineParams, CloseMachineResult, DURABLE_NOTICES_CAPABILITY,
    EXTERNAL_MACHINE_CONNECT_CAPABILITY, EventEnvelope, HelloParams, HelloResult,
    MACHINE_LIFECYCLE_CAPABILITY, MACHINE_METADATA_CLIENT_CAPABILITY,
    MachineLifecycleSnapshotParams, MachineLifecycleSnapshotResult,
    NegotiateClientCapabilitiesParams, NegotiateClientCapabilitiesResult, NoticeDelivery, OpaqueId,
    OpenMachineParams, OpenMachineResult, PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY, Protocol,
    ProviderError, ProviderEvent, ProviderRequest, ProviderResponse, RequestEnvelope,
    ResponseEnvelope, SelectScopeParams, SelectScopeResult, SnapshotParams, SnapshotResult,
    SubscribeNoticesParams, SubscribeNoticesResult, TransportDescriptor, TransportHandshake,
    TransportHandshakeResult, TransportRole, Version, WORKSPACE_LIFECYCLE_CAPABILITY,
    WorkspaceSnapshotParams, WorkspaceSnapshotResult,
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
// Snapshots, selection, notices, and metadata mutations answer in well under
// a second. This bound only catches a wedged provider.
const PROVIDER_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(unix)]
// A suspended cloud machine may spend up to two minutes resuming and another
// two minutes waiting for its relay. Keep the client deadline above that
// server-side bound so the control generation owns cancellation.
const PROVIDER_OPEN_TIMEOUT: Duration = Duration::from_secs(5 * 60);
#[cfg(unix)]
// A cloud create claims a ready spare or boots a new machine. Measured creates
// take 8 to 28 seconds, the server may wait 35 seconds for its carrier, and it
// holds the reservation for 120 seconds. Keep the client deadline above that
// reservation so a slow create finishes instead of showing an error while the
// machine is still coming up. A create that still times out keeps its
// mutation_id, so the retry replays it instead of making a second machine.
const PROVIDER_CREATE_TIMEOUT: Duration = Duration::from_secs(150);

/// How long the client waits for each provider request's response.
///
/// `for_request` names every request kind, so a new request has to choose its
/// bound instead of inheriting the 30 second control default.
#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ProviderRequestDeadlines {
    pub(crate) control: Duration,
    pub(crate) create: Duration,
    pub(crate) open: Duration,
}

#[cfg(unix)]
impl ProviderRequestDeadlines {
    pub(crate) const PRODUCTION: Self = Self {
        control: PROVIDER_REQUEST_TIMEOUT,
        create: PROVIDER_CREATE_TIMEOUT,
        open: PROVIDER_OPEN_TIMEOUT,
    };

    pub(crate) fn for_request(&self, request: &ProviderRequest) -> Duration {
        match request {
            ProviderRequest::OpenMachine(_) => self.open,
            ProviderRequest::CreateMachine(_) | ProviderRequest::CreateWorkspace(_) => self.create,
            ProviderRequest::Hello(_)
            | ProviderRequest::NegotiateClientCapabilities(_)
            | ProviderRequest::SubscribeNotices(_)
            | ProviderRequest::AcknowledgeNotice(_)
            | ProviderRequest::Snapshot(_)
            | ProviderRequest::SelectScope(_)
            | ProviderRequest::ConnectExternalMachine(_)
            | ProviderRequest::MachineLifecycleSnapshot(_)
            | ProviderRequest::RenameMachine(_)
            | ProviderRequest::DeleteMachine(_)
            | ProviderRequest::RestoreMachine(_)
            | ProviderRequest::PurgeMachine(_)
            | ProviderRequest::WorkspaceSnapshot(_)
            | ProviderRequest::RenameWorkspace(_)
            | ProviderRequest::DeleteWorkspace(_)
            | ProviderRequest::RestoreWorkspace(_)
            | ProviderRequest::PurgeWorkspace(_)
            | ProviderRequest::InvokeAction(_)
            | ProviderRequest::CloseMachine(_) => self.control,
        }
    }
}

/// The idempotency key of a mutating request, or `None` for a read.
///
/// The provider treats an exact replay of one `mutation_id` as the same
/// mutation, so callers keep this key until they see a definite answer.
#[cfg(unix)]
pub(crate) fn request_mutation_id_mut(request: &mut ProviderRequest) -> Option<&mut OpaqueId> {
    match request {
        ProviderRequest::CreateMachine(params) => Some(&mut params.mutation_id),
        ProviderRequest::ConnectExternalMachine(params) => Some(&mut params.mutation_id),
        ProviderRequest::RenameMachine(params) => Some(&mut params.mutation_id),
        ProviderRequest::DeleteMachine(params)
        | ProviderRequest::RestoreMachine(params)
        | ProviderRequest::PurgeMachine(params) => Some(&mut params.mutation_id),
        ProviderRequest::CreateWorkspace(params) => Some(&mut params.mutation_id),
        ProviderRequest::RenameWorkspace(params) => Some(&mut params.mutation_id),
        ProviderRequest::DeleteWorkspace(params)
        | ProviderRequest::RestoreWorkspace(params)
        | ProviderRequest::PurgeWorkspace(params) => Some(&mut params.mutation_id),
        ProviderRequest::InvokeAction(params) => Some(&mut params.mutation_id),
        ProviderRequest::Hello(_)
        | ProviderRequest::NegotiateClientCapabilities(_)
        | ProviderRequest::SubscribeNotices(_)
        | ProviderRequest::AcknowledgeNotice(_)
        | ProviderRequest::Snapshot(_)
        | ProviderRequest::OpenMachine(_)
        | ProviderRequest::SelectScope(_)
        | ProviderRequest::MachineLifecycleSnapshot(_)
        | ProviderRequest::WorkspaceSnapshot(_)
        | ProviderRequest::CloseMachine(_) => None,
    }
}

/// The negotiated capability a mutating request needs, if any.
#[cfg(unix)]
fn mutation_capability(request: &ProviderRequest) -> Option<&'static str> {
    match request {
        ProviderRequest::ConnectExternalMachine(_) => Some(EXTERNAL_MACHINE_CONNECT_CAPABILITY),
        ProviderRequest::RenameMachine(_)
        | ProviderRequest::DeleteMachine(_)
        | ProviderRequest::RestoreMachine(_)
        | ProviderRequest::PurgeMachine(_) => Some(MACHINE_LIFECYCLE_CAPABILITY),
        ProviderRequest::RenameWorkspace(_)
        | ProviderRequest::DeleteWorkspace(_)
        | ProviderRequest::RestoreWorkspace(_)
        | ProviderRequest::PurgeWorkspace(_) => Some(WORKSPACE_LIFECYCLE_CAPABILITY),
        _ => None,
    }
}
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
impl ProviderClientError {
    /// True when the request failed before its frame was written, so the
    /// provider cannot have seen it. `mutate` checks authentication and the
    /// request's capability before it sends anything.
    pub(crate) fn proves_request_unsent(&self) -> bool {
        matches!(self, Self::UnsupportedCapability(_) | Self::NotAuthenticated)
    }
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
pub(crate) type ProviderResult<T> = Result<T, ProviderClientError>;

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
    request_deadlines: Mutex<ProviderRequestDeadlines>,
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
    /// Test-only unauthenticated connection. Runtime callers go through
    /// `connect_authenticated_with` so every generation performs `hello`.
    #[cfg(test)]
    pub(crate) fn connect(socket_path: impl AsRef<std::path::Path>) -> ProviderResult<Self> {
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
            request_deadlines: Mutex::new(ProviderRequestDeadlines::PRODUCTION),
        });
        let weak = Arc::downgrade(&inner);
        std::thread::Builder::new()
            .name("machine-provider-reader".to_string())
            .spawn(move || control_reader_loop(reader, guard, weak))?;
        Ok(Self { inner })
    }

    /// Test-only Unix-socket convenience over `connect_authenticated_with`.
    #[cfg(test)]
    pub(crate) fn connect_authenticated(
        socket_path: impl AsRef<std::path::Path>,
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
        let request = ProviderRequest::Hello(HelloParams { token: token.clone(), client });
        let timeout = self.deadline_for(&request)?;
        let result = self.request_unchecked_with_metadata(request, timeout);
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
        self.retain_negotiated_snapshot(&mut snapshot)?;
        Ok(snapshot)
    }

    pub(crate) fn select_scope(&self, scope_id: OpaqueId) -> ProviderResult<SelectScopeResult> {
        let mut result: SelectScopeResult =
            self.request(ProviderRequest::SelectScope(SelectScopeParams { scope_id }))?;
        self.retain_negotiated_snapshot(&mut result.snapshot)?;
        Ok(result)
    }

    /// Sends one mutating request after checking the capability it needs.
    ///
    /// The runtime owns the request's `mutation_id`: it keeps the same id
    /// across a timeout or disconnect so the provider can replay the result.
    pub(crate) fn mutate<T>(&self, request: ProviderRequest) -> ProviderResult<T>
    where
        T: DeserializeOwned,
    {
        if let Some(capability) = mutation_capability(&request) {
            self.require_capability(capability)?;
        }
        self.request(request)
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
    /// The runtime fetches snapshots on demand and does not subscribe yet.
    #[cfg(test)]
    pub(crate) fn subscribe_snapshot_changes(&self) -> ProviderResult<mpsc::Receiver<u64>> {
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
            Box::new(BoundedRemoteReader { inner: reader, _guard: guard.clone() }),
            Box::new(BoundedRemoteWriter { inner: writer, guard: guard.clone() }),
            Arc::new(ProviderRemoteAbort { guard }),
        ))
    }

    fn request<T>(&self, request: ProviderRequest) -> ProviderResult<T>
    where
        T: DeserializeOwned,
    {
        self.ensure_authenticated()?;
        let timeout = self.deadline_for(&request)?;
        self.request_unchecked(request, timeout)
    }

    fn deadline_for(&self, request: &ProviderRequest) -> ProviderResult<Duration> {
        let deadlines = self
            .inner
            .request_deadlines
            .lock()
            .map_err(|_| ProviderClientError::StatePoisoned("request-deadlines"))?;
        Ok(deadlines.for_request(request))
    }

    /// Scales every request bound so tests can model slow providers quickly.
    #[cfg(test)]
    pub(crate) fn set_request_deadlines(&self, deadlines: ProviderRequestDeadlines) {
        *self.inner.request_deadlines.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            deadlines;
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
            MACHINE_METADATA_CLIENT_CAPABILITY.to_string(),
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

    fn retain_negotiated_snapshot(&self, snapshot: &mut SnapshotResult) -> ProviderResult<()> {
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
    /// Keeps the endpoint cleanup alive for as long as the reader exists.
    _guard: ProviderIoGuard,
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
#[path = "machine_provider_client_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "machine_provider_client_snapshot_tests.rs"]
mod snapshot_tests;
