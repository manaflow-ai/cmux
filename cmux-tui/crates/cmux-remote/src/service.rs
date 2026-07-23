use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fmt;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{FrameFlags, Lane, MAX_FRAME_PAYLOAD, Service, ServiceControl};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, watch};

use crate::connection::{ClientConnection, ConnectionError};
use crate::daemon::{DaemonError, ServerConnection};
use crate::session::ReceivedFrame;

const MAX_OPEN_STREAMS: usize = 256;
// Covers the default aggregate replay window (4,096 frames on each of four
// lanes), so a resumed slow lane cannot outlive the closed-stream memory.
const MAX_CLOSED_STREAM_TOMBSTONES: usize = 16 * 1024;
const MAX_BUFFERED_STREAM_BYTES: usize = 32 * 1024 * 1024;
const STREAM_LOCAL_FIN: u8 = 1 << 0;
const STREAM_REMOTE_FIN: u8 = 1 << 1;
const STREAM_RESET: u8 = 1 << 2;
const LANE_INTERACTIVE_BIT: u8 = 1 << 0;
const LANE_CONTROL_BIT: u8 = 1 << 1;
const LANE_BULK_BIT: u8 = 1 << 2;
const LANE_TUNNEL_BIT: u8 = 1 << 3;
const MULTI_LANE_TERMINAL_MASK: u8 = LANE_INTERACTIVE_BIT | LANE_CONTROL_BIT | LANE_BULK_BIT;
const TERMINAL_RESET_DEADLINE: Duration = Duration::from_secs(2);
const MAX_TERMINAL_CLEANUPS: usize = 64;

#[async_trait]
pub trait SessionEndpoint: Send + Sync {
    async fn send_frame(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError>;
    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError>;
    fn subscribe_generation(&self) -> watch::Receiver<u64>;
    async fn close_session(&self) -> Result<(), ServiceError>;
}

#[async_trait]
impl SessionEndpoint for ClientConnection {
    async fn send_frame(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        self.send_in_generation(expected_generation, lane, stream, payload, flags)
            .await
            .map_err(Into::into)
    }

    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
        self.receive().await.map_err(Into::into)
    }

    fn subscribe_generation(&self) -> watch::Receiver<u64> {
        ClientConnection::subscribe_generation(self)
    }

    async fn close_session(&self) -> Result<(), ServiceError> {
        self.close().await.map_err(Into::into)
    }
}

#[async_trait]
impl SessionEndpoint for ServerConnection {
    async fn send_frame(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        self.send_in_generation(expected_generation, lane, stream, payload, flags)
            .await
            .map_err(Into::into)
    }

    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
        self.receive().await.map_err(Into::into)
    }

    fn subscribe_generation(&self) -> watch::Receiver<u64> {
        ServerConnection::subscribe_generation(self)
    }

    async fn close_session(&self) -> Result<(), ServiceError> {
        self.close().await.map_err(Into::into)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointRole {
    Client,
    Daemon,
}

pub struct ServiceMultiplexer {
    endpoint: Arc<dyn SessionEndpoint>,
    streams: Arc<Mutex<HashMap<u64, StreamRegistration>>>,
    closed: Arc<Mutex<ClosedStreams>>,
    accepted: Mutex<mpsc::Receiver<IncomingStream>>,
    next_stream: AtomicU64,
    generation: watch::Receiver<u64>,
    fatal: watch::Receiver<Option<String>>,
    reader: ReaderTask,
    cleanup: Arc<TerminalCleanup>,
}

#[derive(Default)]
struct ClosedStreams {
    ids: HashSet<u64>,
    order: VecDeque<u64>,
}

impl ClosedStreams {
    fn insert(&mut self, stream: u64) -> bool {
        if !self.ids.insert(stream) {
            return false;
        }
        self.order.push_back(stream);
        while self.order.len() > MAX_CLOSED_STREAM_TOMBSTONES {
            if let Some(expired) = self.order.pop_front() {
                self.ids.remove(&expired);
            }
        }
        true
    }
}

struct TerminalCleanup {
    slots: Arc<Semaphore>,
    escalating: AtomicBool,
    deadline: Duration,
}

impl TerminalCleanup {
    fn new() -> Arc<Self> {
        Self::with_deadline(TERMINAL_RESET_DEADLINE)
    }

    fn with_deadline(deadline: Duration) -> Arc<Self> {
        Arc::new(Self {
            slots: Arc::new(Semaphore::new(MAX_TERMINAL_CLEANUPS)),
            escalating: AtomicBool::new(false),
            deadline,
        })
    }

    fn spawn(
        self: &Arc<Self>,
        endpoint: Arc<dyn SessionEndpoint>,
        generation: Option<u64>,
        lane: Lane,
        stream: u64,
        completion: Option<(Arc<AtomicU8>, Service)>,
    ) {
        if self.escalating.load(Ordering::Acquire) {
            return;
        }
        match self.slots.clone().try_acquire_owned() {
            Ok(permit) => {
                let cleanup = self.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    send_reset_or_close_session(
                        endpoint,
                        generation,
                        lane,
                        stream,
                        completion,
                        &cleanup.escalating,
                        cleanup.deadline,
                    )
                    .await;
                });
            }
            Err(_) if !self.escalating.swap(true, Ordering::AcqRel) => {
                tokio::spawn(async move {
                    let _ = endpoint.close_session().await;
                });
            }
            Err(_) => {}
        }
    }
}

struct StreamRegistration {
    service: Service,
    generation: Option<u64>,
    chunks: mpsc::Sender<StreamChunk>,
    failure: watch::Sender<Option<StreamFailure>>,
    state: Arc<AtomicU8>,
    terminal: Arc<LaneTerminalState>,
}

struct LaneTerminalState {
    required: u8,
    local: AtomicU8,
    remote: AtomicU8,
    closing: AtomicBool,
}

impl LaneTerminalState {
    fn new(service: Service) -> Arc<Self> {
        Arc::new(Self {
            required: terminal_lane_mask(service),
            local: AtomicU8::new(0),
            remote: AtomicU8::new(0),
            closing: AtomicBool::new(false),
        })
    }
}

struct ReaderTask {
    shutdown: watch::Sender<bool>,
    handle: StdMutex<Option<tokio::task::JoinHandle<()>>>,
}

struct ReaderLoop {
    endpoint: Arc<dyn SessionEndpoint>,
    streams: Arc<Mutex<HashMap<u64, StreamRegistration>>>,
    closed: Arc<Mutex<ClosedStreams>>,
    cleanup: Arc<TerminalCleanup>,
    accepted: mpsc::Sender<IncomingStream>,
    fatal: watch::Sender<Option<String>>,
    generation: watch::Receiver<u64>,
    shutdown: watch::Receiver<bool>,
    role: EndpointRole,
    incoming_budget: Arc<Semaphore>,
}

impl ReaderTask {
    async fn shutdown(&self) {
        self.shutdown.send_replace(true);
        let task = self.handle.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        if let Some(task) = task {
            let _ = task.await;
        }
    }
}

impl Drop for ReaderTask {
    fn drop(&mut self) {
        self.shutdown.send_replace(true);
        // Dropping a Tokio JoinHandle detaches it. The shutdown watch is part
        // of the reader select, so even an idle receive future is cancelled
        // and releases its endpoint on the next runtime poll.
        self.handle.get_mut().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum StreamFailure {
    GenerationChanged(u64),
    Reset(String),
    Transport(String),
}

impl fmt::Debug for ServiceMultiplexer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ServiceMultiplexer")
            .field("next_stream", &self.next_stream.load(Ordering::Relaxed))
            .finish_non_exhaustive()
    }
}

impl ServiceMultiplexer {
    pub fn new(endpoint: Arc<dyn SessionEndpoint>, role: EndpointRole) -> Arc<Self> {
        Self::new_with_incoming_budget(endpoint, role, MAX_BUFFERED_STREAM_BYTES)
    }

    fn new_with_incoming_budget(
        endpoint: Arc<dyn SessionEndpoint>,
        role: EndpointRole,
        incoming_budget_bytes: usize,
    ) -> Arc<Self> {
        let streams = Arc::new(Mutex::new(HashMap::new()));
        let closed = Arc::new(Mutex::new(ClosedStreams::default()));
        let cleanup = TerminalCleanup::new();
        let (accepted_tx, accepted) = mpsc::channel(128);
        let (fatal_tx, fatal) = watch::channel(None);
        let incoming_budget = Arc::new(Semaphore::new(incoming_budget_bytes));
        let generation = endpoint.subscribe_generation();
        let (shutdown, shutdown_rx) = watch::channel(false);
        let handle = tokio::spawn(reader_loop(ReaderLoop {
            endpoint: endpoint.clone(),
            streams: streams.clone(),
            closed: closed.clone(),
            cleanup: cleanup.clone(),
            accepted: accepted_tx,
            fatal: fatal_tx,
            generation: generation.clone(),
            shutdown: shutdown_rx,
            role,
            incoming_budget,
        }));
        Arc::new(Self {
            endpoint,
            streams,
            closed,
            accepted: Mutex::new(accepted),
            next_stream: AtomicU64::new(match role {
                EndpointRole::Client => 1,
                EndpointRole::Daemon => 2,
            }),
            generation,
            fatal,
            reader: ReaderTask { shutdown, handle: StdMutex::new(Some(handle)) },
            cleanup,
        })
    }

    pub async fn open(
        self: &Arc<Self>,
        service: Service,
        metadata: BTreeMap<String, String>,
    ) -> Result<ServiceStream, ServiceError> {
        let stream = self
            .next_stream
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| value.checked_add(2))
            .map_err(|_| ServiceError::StreamIdsExhausted)?;
        let (sender, receiver) = mpsc::channel(256);
        let generation = generation_for_service(service, *self.generation.borrow());
        let (failure, failure_changed) = watch::channel(None);
        let state = Arc::new(AtomicU8::new(0));
        let terminal = LaneTerminalState::new(service);
        let mut streams = self.streams.lock().await;
        if let Some(message) = self.fatal.borrow().clone() {
            return Err(ServiceError::Transport(message));
        }
        if streams.len() >= MAX_OPEN_STREAMS {
            return Err(ServiceError::TooManyStreams);
        }
        streams.insert(
            stream,
            StreamRegistration {
                service,
                generation,
                chunks: sender,
                failure: failure.clone(),
                state: state.clone(),
                terminal: terminal.clone(),
            },
        );
        drop(streams);
        let mut pending = PendingOpenGuard::new(
            stream,
            service,
            generation,
            self.endpoint.clone(),
            self.streams.clone(),
            self.closed.clone(),
            self.cleanup.clone(),
            failure.clone(),
            state.clone(),
        );
        let payload = serde_json::to_vec(&ServiceControl::Open { service, metadata })?;
        if let Err(error) = self
            .endpoint
            .send_frame(
                generation,
                open_lane(service),
                stream,
                Bytes::from(payload),
                FrameFlags::OPEN,
            )
            .await
        {
            pending.cleanup("service open failed before completion").await;
            return Err(error);
        }
        pending.disarm();
        Ok(ServiceStream {
            id: stream,
            service,
            default_lane: default_lane(service),
            endpoint: self.endpoint.clone(),
            registrations: self.streams.clone(),
            closed: self.closed.clone(),
            cleanup: self.cleanup.clone(),
            receiver: Mutex::new(StreamReceiver {
                chunks: receiver,
                failure_changed,
                remote_finished_delivered: false,
            }),
            generation,
            failure,
            state,
            terminal,
            outbound: Mutex::new(()),
        })
    }

    pub async fn accept(&self) -> Result<Option<IncomingStream>, ServiceError> {
        if let Some(message) = self.fatal.borrow().clone() {
            return Err(ServiceError::Transport(message));
        }
        let incoming = self.accepted.lock().await.recv().await;
        if incoming.is_none()
            && let Some(message) = self.fatal.borrow().clone()
        {
            return Err(ServiceError::Transport(message));
        }
        Ok(incoming)
    }

    /// Observe terminal reader failures without polling an application stream.
    /// The initial value is `None`; a present message is permanent for this
    /// multiplexer and means callers should tear down their local bridge.
    pub fn subscribe_fatal(&self) -> watch::Receiver<Option<String>> {
        self.fatal.clone()
    }

    /// Stop the background reader and wait until its endpoint receive future
    /// and all stream registrations have been released.
    pub async fn shutdown(&self) {
        self.reader.shutdown().await;
    }
}

pub struct IncomingStream {
    pub service: Service,
    pub metadata: BTreeMap<String, String>,
    pub stream: ServiceStream,
}

struct PendingOpenGuard {
    id: u64,
    service: Service,
    generation: Option<u64>,
    endpoint: Arc<dyn SessionEndpoint>,
    registrations: Arc<Mutex<HashMap<u64, StreamRegistration>>>,
    closed: Arc<Mutex<ClosedStreams>>,
    cleanup: Arc<TerminalCleanup>,
    failure: watch::Sender<Option<StreamFailure>>,
    state: Arc<AtomicU8>,
    armed: bool,
}

impl PendingOpenGuard {
    #[allow(clippy::too_many_arguments)]
    fn new(
        id: u64,
        service: Service,
        generation: Option<u64>,
        endpoint: Arc<dyn SessionEndpoint>,
        registrations: Arc<Mutex<HashMap<u64, StreamRegistration>>>,
        closed: Arc<Mutex<ClosedStreams>>,
        cleanup: Arc<TerminalCleanup>,
        failure: watch::Sender<Option<StreamFailure>>,
        state: Arc<AtomicU8>,
    ) -> Self {
        Self {
            id,
            service,
            generation,
            endpoint,
            registrations,
            closed,
            cleanup,
            failure,
            state,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }

    async fn cleanup(&mut self, reason: &str) {
        if !self.armed {
            return;
        }
        self.state.store(STREAM_LOCAL_FIN | STREAM_REMOTE_FIN | STREAM_RESET, Ordering::Release);
        self.failure.send_replace(Some(StreamFailure::Reset(reason.into())));
        self.closed.lock().await.insert(self.id);
        self.registrations.lock().await.remove(&self.id);
        self.cleanup.spawn(
            self.endpoint.clone(),
            self.generation,
            open_lane(self.service),
            self.id,
            None,
        );
        self.armed = false;
    }
}

impl Drop for PendingOpenGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        self.armed = false;
        self.state.store(STREAM_LOCAL_FIN | STREAM_REMOTE_FIN | STREAM_RESET, Ordering::Release);
        self.failure.send_replace(Some(StreamFailure::Reset("service open was cancelled".into())));
        let registrations = self.registrations.clone();
        let closed = self.closed.clone();
        let endpoint = self.endpoint.clone();
        let cleanup = self.cleanup.clone();
        let generation = self.generation;
        let lane = open_lane(self.service);
        let id = self.id;
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                closed.lock().await.insert(id);
                registrations.lock().await.remove(&id);
                cleanup.spawn(endpoint, generation, lane, id, None);
            });
        } else if let Ok(mut registrations) = registrations.try_lock() {
            registrations.remove(&id);
        }
    }
}

pub struct ServiceStream {
    id: u64,
    service: Service,
    default_lane: Lane,
    endpoint: Arc<dyn SessionEndpoint>,
    registrations: Arc<Mutex<HashMap<u64, StreamRegistration>>>,
    closed: Arc<Mutex<ClosedStreams>>,
    cleanup: Arc<TerminalCleanup>,
    receiver: Mutex<StreamReceiver>,
    generation: Option<u64>,
    failure: watch::Sender<Option<StreamFailure>>,
    state: Arc<AtomicU8>,
    terminal: Arc<LaneTerminalState>,
    outbound: Mutex<()>,
}

struct StreamReceiver {
    chunks: mpsc::Receiver<StreamChunk>,
    failure_changed: watch::Receiver<Option<StreamFailure>>,
    remote_finished_delivered: bool,
}

impl fmt::Debug for ServiceStream {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ServiceStream")
            .field("id", &self.id)
            .field("service", &self.service)
            .finish_non_exhaustive()
    }
}

impl ServiceStream {
    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn service(&self) -> Service {
        self.service
    }

    pub async fn send(&self, payload: Bytes) -> Result<(), ServiceError> {
        self.send_on(self.default_lane, payload).await
    }

    pub async fn send_on(&self, lane: Lane, payload: Bytes) -> Result<(), ServiceError> {
        let _outbound = self.outbound.lock().await;
        self.require_active()?;
        if self.terminal.closing.load(Ordering::Acquire) {
            return Err(ServiceError::Closed);
        }
        let state = self.state.load(Ordering::Acquire);
        let closed = if self.service == Service::TcpTunnel {
            state & (STREAM_LOCAL_FIN | STREAM_RESET) != 0
        } else {
            state != 0
        };
        if closed {
            return Err(ServiceError::Closed);
        }
        let lane = if self.service == Service::TcpTunnel { Lane::Tunnel } else { lane };
        if payload.is_empty() {
            self.endpoint
                .send_frame(self.generation, lane, self.id, payload, FrameFlags::empty())
                .await?;
            return Ok(());
        }
        for chunk in payload.chunks(MAX_FRAME_PAYLOAD) {
            self.endpoint
                .send_frame(
                    self.generation,
                    lane,
                    self.id,
                    Bytes::copy_from_slice(chunk),
                    FrameFlags::empty(),
                )
                .await?;
        }
        Ok(())
    }

    pub async fn receive(&self) -> Result<Option<StreamChunk>, ServiceError> {
        let mut receiver = self.receiver.lock().await;
        let initial_failure = receiver.failure_changed.borrow().clone();
        if let Some(failure) = initial_failure {
            let error = self.failure_error(failure);
            drain_failed_receiver(&mut receiver);
            return Err(error);
        }
        if receiver.remote_finished_delivered {
            return Ok(None);
        }
        let StreamReceiver { chunks, failure_changed, .. } = &mut *receiver;
        let received = tokio::select! {
            biased;
            changed = failure_changed.changed() => {
                if changed.is_ok()
                    && let Some(failure) = failure_changed.borrow().clone()
                {
                    Err(self.failure_error(failure))
                } else {
                    Ok(None)
                }
            }
            chunk = chunks.recv() => Ok(chunk),
        };
        let chunk = match received {
            Ok(chunk) => chunk,
            Err(error) => {
                drain_failed_receiver(&mut receiver);
                return Err(error);
            }
        };
        if chunk.is_none() {
            let terminal_failure = receiver.failure_changed.borrow().clone();
            if let Some(failure) = terminal_failure {
                let error = self.failure_error(failure);
                drain_failed_receiver(&mut receiver);
                return Err(error);
            }
            let state = self.state.load(Ordering::Acquire);
            if state & (STREAM_LOCAL_FIN | STREAM_REMOTE_FIN)
                == STREAM_LOCAL_FIN | STREAM_REMOTE_FIN
                && state & STREAM_RESET == 0
            {
                return Ok(None);
            }
            return Err(ServiceError::Transport(
                "service stream delivery ended without FIN or RESET".into(),
            ));
        }
        if let Some(chunk) = &chunk
            && (chunk.finished || chunk.reset)
        {
            receiver.remote_finished_delivered = true;
            if self.service == Service::TcpTunnel {
                let flag =
                    if chunk.reset { STREAM_REMOTE_FIN | STREAM_RESET } else { STREAM_REMOTE_FIN };
                self.state.fetch_or(flag, Ordering::AcqRel);
            } else {
                let state = STREAM_LOCAL_FIN
                    | STREAM_REMOTE_FIN
                    | if chunk.reset { STREAM_RESET } else { 0 };
                self.state.store(state, Ordering::Release);
            }
        }
        Ok(chunk)
    }

    pub async fn close(&self) -> Result<(), ServiceError> {
        self.close_on(self.default_lane).await
    }

    pub async fn close_on(&self, lane: Lane) -> Result<(), ServiceError> {
        let _outbound = self.outbound.lock().await;
        self.require_active()?;
        if self.state.load(Ordering::Acquire) & STREAM_LOCAL_FIN != 0 {
            return Ok(());
        }
        self.terminal.closing.store(true, Ordering::Release);
        let lane = if self.service == Service::TcpTunnel { Lane::Tunnel } else { lane };
        let lanes = close_lanes(self.service, &lane);
        for lane in lanes {
            let bit = lane_bit(*lane);
            if self.terminal.local.load(Ordering::Acquire) & bit != 0 {
                continue;
            }
            self.endpoint
                .send_frame(self.generation, *lane, self.id, Bytes::new(), FrameFlags::FIN)
                .await?;
            self.terminal.local.fetch_or(bit, Ordering::AcqRel);
        }
        self.require_active()?;
        let committed = if self.service == Service::TcpTunnel {
            STREAM_LOCAL_FIN
        } else {
            STREAM_LOCAL_FIN | STREAM_REMOTE_FIN
        };
        let previous = self.state.fetch_or(committed, Ordering::AcqRel);
        if self.service != Service::TcpTunnel || previous & STREAM_REMOTE_FIN != 0 {
            self.closed.lock().await.insert(self.id);
            self.registrations.lock().await.remove(&self.id);
        }
        Ok(())
    }

    pub async fn reject(&self, code: String, message: String) -> Result<(), ServiceError> {
        let payload = serde_json::to_vec(&ServiceControl::Rejected { code, message })?;
        self.send_on(Lane::Control, Bytes::from(payload)).await?;
        // Rejection and its terminal FIN share the control lane so an isolated
        // interactive carrier cannot deliver FIN ahead of the reason.
        self.close_on(Lane::Control).await
    }

    fn require_active(&self) -> Result<(), ServiceError> {
        if let Some(failure) = self.failure.borrow().clone() {
            Err(self.failure_error(failure))
        } else {
            Ok(())
        }
    }

    pub(crate) async fn wait_for_failure(&self) -> ServiceError {
        let mut failure = self.failure.subscribe();
        loop {
            if let Some(failure) = failure.borrow().clone() {
                return self.failure_error(failure);
            }
            if failure.changed().await.is_err() {
                return ServiceError::Transport("service stream failure monitor closed".into());
            }
        }
    }

    fn failure_error(&self, failure: StreamFailure) -> ServiceError {
        match failure {
            StreamFailure::GenerationChanged(actual) => self.generation_error(actual),
            StreamFailure::Reset(message) => ServiceError::Reset(message),
            StreamFailure::Transport(message) => ServiceError::Transport(message),
        }
    }

    fn generation_error(&self, actual: u64) -> ServiceError {
        ServiceError::GenerationChanged { expected: self.generation.unwrap_or(actual), actual }
    }
}

fn drain_failed_receiver(receiver: &mut StreamReceiver) {
    receiver.chunks.close();
    while receiver.chunks.try_recv().is_ok() {}
}

impl Drop for ServiceStream {
    fn drop(&mut self) {
        let previous = self.state.fetch_or(STREAM_RESET, Ordering::AcqRel);
        let complete = if self.service == Service::TcpTunnel {
            previous & (STREAM_LOCAL_FIN | STREAM_REMOTE_FIN)
                == STREAM_LOCAL_FIN | STREAM_REMOTE_FIN
        } else {
            previous & (STREAM_LOCAL_FIN | STREAM_REMOTE_FIN | STREAM_RESET) != 0
        };
        let registrations = self.registrations.clone();
        let closed = self.closed.clone();
        let endpoint = self.endpoint.clone();
        let cleanup = self.cleanup.clone();
        let generation = self.generation;
        let lane = reset_lane(self.service);
        let id = self.id;
        let state = self.state.clone();
        let service = self.service;
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                closed.lock().await.insert(id);
                registrations.lock().await.remove(&id);
                if !complete {
                    cleanup.spawn(endpoint, generation, lane, id, Some((state, service)));
                }
            });
        } else if let Ok(mut registrations) = registrations.try_lock() {
            registrations.remove(&id);
        }
    }
}

#[derive(Debug)]
pub struct StreamChunk {
    pub lane: Lane,
    pub sequence: u64,
    pub payload: Bytes,
    pub finished: bool,
    pub reset: bool,
    budget: Option<OwnedSemaphorePermit>,
}

impl StreamChunk {
    pub(crate) fn take_budget(&mut self) -> Option<OwnedSemaphorePermit> {
        self.budget.take()
    }
}

async fn reader_loop(reader: ReaderLoop) {
    let ReaderLoop {
        endpoint,
        streams,
        closed,
        cleanup,
        accepted,
        fatal,
        mut generation,
        mut shutdown,
        role,
        incoming_budget,
    } = reader;
    loop {
        let received = tokio::select! {
            biased;
            _ = shutdown.changed() => break,
            changed = generation.changed() => {
                if changed.is_err() {
                    break;
                }
                let current_generation = *generation.borrow();
                reset_tunnel_streams(&streams, current_generation).await;
                continue;
            }
            received = endpoint.receive_frame() => received,
        };
        let frame = match received {
            Ok(Some(frame)) => frame,
            Ok(None) => {
                let _ = fatal.send(Some("remote session closed".into()));
                break;
            }
            Err(error) => {
                let _ = fatal.send(Some(error.to_string()));
                break;
            }
        };
        if frame.flags.contains(FrameFlags::OPEN) {
            let peer_stream_is_valid = match role {
                EndpointRole::Client => frame.stream % 2 == 0,
                EndpointRole::Daemon => frame.stream % 2 == 1,
            };
            if !peer_stream_is_valid
                || frame.flags.contains(FrameFlags::FIN)
                || frame.flags.contains(FrameFlags::RESET)
            {
                let _ = fatal.send(Some(format!("invalid peer stream id {}", frame.stream)));
                break;
            }
            let control = match serde_json::from_slice::<ServiceControl>(&frame.payload) {
                Ok(ServiceControl::Open { service, metadata }) => (service, metadata),
                Ok(_) | Err(_) => {
                    let _ = fatal.send(Some("invalid service open frame".into()));
                    break;
                }
            };
            if (control.0 == Service::TcpTunnel && frame.lane != Lane::Tunnel)
                || (control.0 != Service::TcpTunnel && frame.lane == Lane::Tunnel)
            {
                let _ = fatal.send(Some("service open frame used an invalid lane".into()));
                break;
            }
            let stream_generation = generation_for_service(control.0, frame.generation);
            if stream_generation.is_some() && frame.generation != *generation.borrow() {
                continue;
            }
            if closed.lock().await.ids.contains(&frame.stream) {
                let _ =
                    fatal.send(Some(format!("closed stream {} was opened again", frame.stream)));
                break;
            }
            let (sender, receiver) = mpsc::channel(256);
            let (failure, failure_changed) = watch::channel(None);
            let state = Arc::new(AtomicU8::new(0));
            let terminal = LaneTerminalState::new(control.0);
            let mut table = streams.lock().await;
            if table.len() >= MAX_OPEN_STREAMS {
                drop(table);
                closed.lock().await.insert(frame.stream);
                cleanup.spawn(
                    endpoint.clone(),
                    stream_generation,
                    reset_lane(control.0),
                    frame.stream,
                    None,
                );
                continue;
            }
            if table
                .insert(
                    frame.stream,
                    StreamRegistration {
                        service: control.0,
                        generation: stream_generation,
                        chunks: sender,
                        failure: failure.clone(),
                        state: state.clone(),
                        terminal: terminal.clone(),
                    },
                )
                .is_some()
            {
                let _ = fatal.send(Some(format!("stream {} was opened twice", frame.stream)));
                break;
            }
            drop(table);
            let stream = ServiceStream {
                id: frame.stream,
                service: control.0,
                default_lane: default_lane(control.0),
                endpoint: endpoint.clone(),
                registrations: streams.clone(),
                closed: closed.clone(),
                cleanup: cleanup.clone(),
                receiver: Mutex::new(StreamReceiver {
                    chunks: receiver,
                    failure_changed,
                    remote_finished_delivered: false,
                }),
                generation: stream_generation,
                failure,
                state,
                terminal,
                outbound: Mutex::new(()),
            };
            match accepted.try_send(IncomingStream {
                service: control.0,
                metadata: control.1,
                stream,
            }) {
                Ok(()) => {}
                Err(mpsc::error::TrySendError::Closed(_)) => break,
                Err(mpsc::error::TrySendError::Full(incoming)) => {
                    closed.lock().await.insert(frame.stream);
                    if let Some(registration) = streams.lock().await.remove(&frame.stream) {
                        fail_registration(
                            registration,
                            StreamFailure::Reset("too many pending service streams".into()),
                        );
                    }
                    cleanup.spawn(
                        endpoint.clone(),
                        stream_generation,
                        reset_lane(control.0),
                        frame.stream,
                        None,
                    );
                    drop(incoming);
                }
            }
            continue;
        }
        let registration = streams.lock().await.get(&frame.stream).map(|registration| {
            (
                registration.service,
                registration.generation,
                registration.chunks.clone(),
                registration.state.clone(),
                registration.terminal.clone(),
            )
        });
        let Some((service, stream_generation, sender, state, terminal)) = registration else {
            // RESET is idempotent. A cancelled local OPEN can enqueue its
            // cleanup RESET before the peer has observed the OPEN.
            if frame.flags.contains(FrameFlags::RESET) || frame.flags.contains(FrameFlags::FIN) {
                continue;
            }
            if closed.lock().await.ids.contains(&frame.stream) {
                continue;
            }
            if frame.lane == Lane::Tunnel && frame.generation != *generation.borrow() {
                continue;
            }
            let _ = fatal.send(Some(format!("frame for unknown stream {}", frame.stream)));
            break;
        };
        if service == Service::TcpTunnel
            && (frame.lane != Lane::Tunnel || stream_generation != Some(frame.generation))
        {
            let _ = fatal.send(Some("tunnel stream frame crossed its generation boundary".into()));
            break;
        }
        if service == Service::MuxControl && frame.lane == Lane::Tunnel {
            reset_registered_stream(
                &streams,
                &closed,
                frame.stream,
                "mux-control frame used the tunnel lane",
            )
            .await;
            cleanup.spawn(endpoint.clone(), stream_generation, Lane::Tunnel, frame.stream, None);
            continue;
        }
        let inbound_lane = lane_bit(frame.lane);
        if terminal.remote.load(Ordering::Acquire) & inbound_lane != 0 {
            if frame.flags.contains(FrameFlags::FIN)
                && !frame.flags.contains(FrameFlags::RESET)
                && frame.payload.is_empty()
            {
                continue;
            }
            reset_registered_stream(
                &streams,
                &closed,
                frame.stream,
                "peer sent a frame after FIN on the same lane",
            )
            .await;
            cleanup.spawn(endpoint.clone(), stream_generation, frame.lane, frame.stream, None);
            continue;
        }
        let reset = frame.flags.contains(FrameFlags::RESET);
        if reset {
            reset_registered_stream(
                &streams,
                &closed,
                frame.stream,
                "remote peer reset the stream",
            )
            .await;
            continue;
        }
        let lane_finished = frame.flags.contains(FrameFlags::FIN);
        let budget = if frame.payload.is_empty() {
            None
        } else {
            let Ok(bytes) = u32::try_from(frame.payload.len()) else {
                reset_registered_stream(
                    &streams,
                    &closed,
                    frame.stream,
                    "incoming frame length exceeded the stream budget representation",
                )
                .await;
                continue;
            };
            match incoming_budget.clone().try_acquire_many_owned(bytes) {
                Ok(permit) => Some(permit),
                Err(_) => {
                    reset_registered_stream(
                        &streams,
                        &closed,
                        frame.stream,
                        "incoming stream byte budget was exhausted",
                    )
                    .await;
                    cleanup.spawn(
                        endpoint.clone(),
                        stream_generation,
                        frame.lane,
                        frame.stream,
                        None,
                    );
                    continue;
                }
            }
        };
        let finished = if lane_finished {
            let remote = terminal.remote.fetch_or(inbound_lane, Ordering::AcqRel) | inbound_lane;
            terminal.required == 0 || remote & terminal.required == terminal.required
        } else {
            false
        };
        if lane_finished && !finished && frame.payload.is_empty() {
            continue;
        }
        let chunk = StreamChunk {
            lane: frame.lane,
            sequence: frame.sequence,
            payload: frame.payload,
            finished,
            reset,
            budget,
        };
        let prior_state = if finished {
            state.fetch_or(STREAM_REMOTE_FIN, Ordering::AcqRel)
        } else {
            state.load(Ordering::Acquire)
        };
        match sender.try_send(chunk) {
            Ok(()) if !finished => {}
            Ok(())
                if service != Service::TcpTunnel
                    || reset
                    || prior_state & STREAM_LOCAL_FIN != 0 =>
            {
                streams.lock().await.remove(&frame.stream);
                closed.lock().await.insert(frame.stream);
            }
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Closed(_)) => {
                streams.lock().await.remove(&frame.stream);
                closed.lock().await.insert(frame.stream);
            }
            Err(mpsc::error::TrySendError::Full(_)) => {
                reset_registered_stream(
                    &streams,
                    &closed,
                    frame.stream,
                    "incoming stream frame queue was exhausted",
                )
                .await;
                cleanup.spawn(endpoint.clone(), stream_generation, frame.lane, frame.stream, None);
            }
        }
    }
    let message =
        fatal.borrow().clone().unwrap_or_else(|| "service multiplexer reader stopped".into());
    fatal.send_replace(Some(message.clone()));
    fail_all_streams(&streams, StreamFailure::Transport(message)).await;
}

async fn reset_registered_stream(
    streams: &Mutex<HashMap<u64, StreamRegistration>>,
    closed: &Mutex<ClosedStreams>,
    stream: u64,
    reason: &str,
) -> bool {
    let registration = streams.lock().await.remove(&stream);
    closed.lock().await.insert(stream);
    if let Some(registration) = registration {
        fail_registration(registration, StreamFailure::Reset(reason.into()));
        true
    } else {
        false
    }
}

async fn fail_all_streams(
    streams: &Mutex<HashMap<u64, StreamRegistration>>,
    failure: StreamFailure,
) {
    let registrations =
        streams.lock().await.drain().map(|(_, registration)| registration).collect::<Vec<_>>();
    for registration in registrations {
        fail_registration(registration, failure.clone());
    }
}

fn fail_registration(registration: StreamRegistration, failure: StreamFailure) {
    registration.terminal.closing.store(true, Ordering::Release);
    registration.terminal.local.store(u8::MAX, Ordering::Release);
    registration.terminal.remote.store(u8::MAX, Ordering::Release);
    registration
        .state
        .store(STREAM_LOCAL_FIN | STREAM_REMOTE_FIN | STREAM_RESET, Ordering::Release);
    registration.failure.send_replace(Some(failure));
}

async fn send_reset_or_close_session(
    endpoint: Arc<dyn SessionEndpoint>,
    generation: Option<u64>,
    lane: Lane,
    stream: u64,
    completion: Option<(Arc<AtomicU8>, Service)>,
    escalating: &AtomicBool,
    reset_deadline: Duration,
) {
    let deadline = tokio::time::Instant::now() + reset_deadline;
    let mut backoff = Duration::from_millis(2);
    loop {
        if escalating.load(Ordering::Acquire) {
            return;
        }
        if reset_no_longer_needed(completion.as_ref()) {
            return;
        }
        let send = endpoint.send_frame(generation, lane, stream, Bytes::new(), FrameFlags::RESET);
        match tokio::time::timeout_at(deadline, send).await {
            Ok(Ok(_)) => return,
            Ok(Err(error)) if terminal_send_is_retryable(&error) => {
                if tokio::time::Instant::now() >= deadline {
                    break;
                }
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_millis(32));
            }
            Ok(Err(error)) if terminal_send_is_already_closed(&error) => return,
            Ok(Err(_)) | Err(_) => break,
        }
    }
    if !reset_no_longer_needed(completion.as_ref()) && !escalating.swap(true, Ordering::AcqRel) {
        let _ = endpoint.close_session().await;
    }
}

fn reset_no_longer_needed(completion: Option<&(Arc<AtomicU8>, Service)>) -> bool {
    let Some((state, service)) = completion else { return false };
    let state = state.load(Ordering::Acquire);
    if *service == Service::TcpTunnel {
        state & (STREAM_LOCAL_FIN | STREAM_REMOTE_FIN) == STREAM_LOCAL_FIN | STREAM_REMOTE_FIN
    } else {
        state & (STREAM_LOCAL_FIN | STREAM_REMOTE_FIN) != 0
    }
}

fn terminal_send_is_retryable(error: &ServiceError) -> bool {
    use crate::session::SessionError;

    let retryable = |error: &SessionError| {
        matches!(error, SessionError::QueueFull(_) | SessionError::ReplayFull(_))
    };
    match error {
        ServiceError::Client(ConnectionError::Session(error))
        | ServiceError::Daemon(DaemonError::Session(error))
        | ServiceError::Daemon(DaemonError::Connection(ConnectionError::Session(error))) => {
            retryable(error)
        }
        _ => false,
    }
}

fn terminal_send_is_already_closed(error: &ServiceError) -> bool {
    matches!(
        error,
        ServiceError::Closed
            | ServiceError::GenerationChanged { .. }
            | ServiceError::Client(ConnectionError::Closed)
            | ServiceError::Client(ConnectionError::GenerationChanged { .. })
            | ServiceError::Daemon(DaemonError::Closed)
            | ServiceError::Daemon(DaemonError::Generation { .. })
            | ServiceError::Daemon(DaemonError::Connection(ConnectionError::Closed))
            | ServiceError::Daemon(DaemonError::Connection(
                ConnectionError::GenerationChanged { .. }
            ))
    )
}

async fn reset_tunnel_streams(streams: &Mutex<HashMap<u64, StreamRegistration>>, generation: u64) {
    let registrations = {
        let mut streams = streams.lock().await;
        let stale = streams
            .iter()
            .filter(|(_, registration)| {
                registration.service == Service::TcpTunnel
                    && registration.generation != Some(generation)
            })
            .map(|(stream, _)| *stream)
            .collect::<Vec<_>>();
        stale.into_iter().filter_map(|stream| streams.remove(&stream)).collect::<Vec<_>>()
    };
    for registration in registrations {
        fail_registration(registration, StreamFailure::GenerationChanged(generation));
    }
}

fn default_lane(service: Service) -> Lane {
    match service {
        Service::MuxControl | Service::ProcessStream | Service::ComputerUse => Lane::Interactive,
        Service::WorkspaceRpc => Lane::Control,
        Service::TcpTunnel => Lane::Tunnel,
    }
}

const MULTI_LANE_TERMINAL_LANES: [Lane; 3] = [Lane::Interactive, Lane::Control, Lane::Bulk];

fn terminal_lane_mask(service: Service) -> u8 {
    if service == Service::MuxControl { MULTI_LANE_TERMINAL_MASK } else { 0 }
}

fn close_lanes(service: Service, lane: &Lane) -> &[Lane] {
    if terminal_lane_mask(service) == MULTI_LANE_TERMINAL_MASK {
        &MULTI_LANE_TERMINAL_LANES
    } else {
        std::slice::from_ref(lane)
    }
}

fn lane_bit(lane: Lane) -> u8 {
    match lane {
        Lane::Interactive => LANE_INTERACTIVE_BIT,
        Lane::Control => LANE_CONTROL_BIT,
        Lane::Bulk => LANE_BULK_BIT,
        Lane::Tunnel => LANE_TUNNEL_BIT,
    }
}

fn open_lane(service: Service) -> Lane {
    if service == Service::TcpTunnel { Lane::Tunnel } else { Lane::Control }
}

fn reset_lane(service: Service) -> Lane {
    if service == Service::TcpTunnel { Lane::Tunnel } else { Lane::Control }
}

fn generation_for_service(service: Service, generation: u64) -> Option<u64> {
    (service == Service::TcpTunnel).then_some(generation)
}

#[derive(Debug)]
pub enum ServiceError {
    Client(ConnectionError),
    Daemon(DaemonError),
    Json(serde_json::Error),
    Transport(String),
    StreamIdsExhausted,
    TooManyStreams,
    Closed,
    Reset(String),
    GenerationChanged { expected: u64, actual: u64 },
}

impl fmt::Display for ServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Client(error) => error.fmt(formatter),
            Self::Daemon(error) => error.fmt(formatter),
            Self::Json(error) => write!(formatter, "service control JSON failed: {error}"),
            Self::Transport(message) => write!(formatter, "service transport failed: {message}"),
            Self::StreamIdsExhausted => formatter.write_str("service stream identifiers exhausted"),
            Self::TooManyStreams => formatter.write_str("too many open service streams"),
            Self::Closed => formatter.write_str("service stream is closed"),
            Self::Reset(message) => write!(formatter, "service stream was reset: {message}"),
            Self::GenerationChanged { expected, actual } => {
                write!(formatter, "service stream generation changed from {expected} to {actual}")
            }
        }
    }
}

impl std::error::Error for ServiceError {}

impl From<ConnectionError> for ServiceError {
    fn from(error: ConnectionError) -> Self {
        Self::Client(error)
    }
}

impl From<DaemonError> for ServiceError {
    fn from(error: DaemonError) -> Self {
        Self::Daemon(error)
    }
}

impl From<serde_json::Error> for ServiceError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

#[cfg(test)]
mod tests {
    use std::future::pending;
    use std::sync::atomic::{AtomicBool, AtomicUsize};
    use std::time::Duration;

    use super::*;
    use tokio::sync::Notify;

    struct TestEndpoint {
        outgoing: mpsc::Sender<ReceivedFrame>,
        incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
        next_sequence: AtomicU64,
        generation: watch::Sender<u64>,
    }

    impl TestEndpoint {
        fn advance_generation(&self, generation: u64) {
            self.generation.send_replace(generation);
        }
    }

    #[async_trait]
    impl SessionEndpoint for TestEndpoint {
        async fn send_frame(
            &self,
            expected_generation: Option<u64>,
            lane: Lane,
            stream: u64,
            payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            let generation = *self.generation.borrow();
            if let Some(expected) = expected_generation
                && expected != generation
            {
                return Err(ServiceError::GenerationChanged { expected, actual: generation });
            }
            let sequence = self.next_sequence.fetch_add(1, Ordering::Relaxed) + 1;
            self.outgoing
                .send(ReceivedFrame { generation, lane, stream, sequence, flags, payload })
                .await
                .map_err(|_| ServiceError::Transport("test peer closed".into()))?;
            Ok(sequence)
        }

        async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
            Ok(self.incoming.lock().await.recv().await)
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> {
            self.generation.subscribe()
        }

        async fn close_session(&self) -> Result<(), ServiceError> {
            Ok(())
        }
    }

    fn endpoint_pair() -> (Arc<TestEndpoint>, Arc<TestEndpoint>) {
        let (left_tx, left_rx) = mpsc::channel(32);
        let (right_tx, right_rx) = mpsc::channel(32);
        let (left_generation, _) = watch::channel(0);
        let (right_generation, _) = watch::channel(0);
        (
            Arc::new(TestEndpoint {
                outgoing: left_tx,
                incoming: Mutex::new(right_rx),
                next_sequence: AtomicU64::new(0),
                generation: left_generation,
            }),
            Arc::new(TestEndpoint {
                outgoing: right_tx,
                incoming: Mutex::new(left_rx),
                next_sequence: AtomicU64::new(0),
                generation: right_generation,
            }),
        )
    }

    struct ClosedEndpoint {
        generation: watch::Sender<u64>,
    }

    struct BlockingEndpoint {
        generation: watch::Sender<u64>,
        open_active: AtomicBool,
        receive_active: AtomicBool,
        activity_changed: Notify,
        sent: Mutex<Vec<FrameFlags>>,
    }

    struct FlakyEndpoint {
        generation: watch::Sender<u64>,
        fin_attempts: AtomicUsize,
        reset_attempts: AtomicUsize,
        reset_failures: usize,
        close_count: AtomicUsize,
    }

    impl FlakyEndpoint {
        fn new(reset_failures: usize) -> Arc<Self> {
            let (generation, _) = watch::channel(0);
            Arc::new(Self {
                generation,
                fin_attempts: AtomicUsize::new(0),
                reset_attempts: AtomicUsize::new(0),
                reset_failures,
                close_count: AtomicUsize::new(0),
            })
        }
    }

    #[async_trait]
    impl SessionEndpoint for FlakyEndpoint {
        async fn send_frame(
            &self,
            _expected_generation: Option<u64>,
            lane: Lane,
            _stream: u64,
            _payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            use crate::session::SessionError;

            if flags.contains(FrameFlags::FIN) {
                let attempt = self.fin_attempts.fetch_add(1, Ordering::AcqRel);
                if attempt == 0 {
                    return Err(ConnectionError::Session(SessionError::QueueFull(lane)).into());
                }
            }
            if flags.contains(FrameFlags::RESET) {
                let attempt = self.reset_attempts.fetch_add(1, Ordering::AcqRel);
                if attempt < self.reset_failures {
                    return Err(ConnectionError::Session(SessionError::QueueFull(lane)).into());
                }
            }
            Ok(1)
        }

        async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
            pending().await
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> {
            self.generation.subscribe()
        }

        async fn close_session(&self) -> Result<(), ServiceError> {
            self.close_count.fetch_add(1, Ordering::AcqRel);
            Ok(())
        }
    }

    struct ActivityGuard<'a> {
        active: &'a AtomicBool,
        changed: &'a Notify,
    }

    impl Drop for ActivityGuard<'_> {
        fn drop(&mut self) {
            self.active.store(false, Ordering::Release);
            self.changed.notify_waiters();
        }
    }

    impl BlockingEndpoint {
        fn new() -> Arc<Self> {
            let (generation, _) = watch::channel(0);
            Arc::new(Self {
                generation,
                open_active: AtomicBool::new(false),
                receive_active: AtomicBool::new(false),
                activity_changed: Notify::new(),
                sent: Mutex::new(Vec::new()),
            })
        }

        async fn wait_for(&self, active: &AtomicBool, expected: bool) {
            tokio::time::timeout(Duration::from_secs(1), async {
                loop {
                    let notified = self.activity_changed.notified();
                    if active.load(Ordering::Acquire) == expected {
                        break;
                    }
                    notified.await;
                }
            })
            .await
            .unwrap();
        }
    }

    #[async_trait]
    impl SessionEndpoint for BlockingEndpoint {
        async fn send_frame(
            &self,
            _expected_generation: Option<u64>,
            _lane: Lane,
            _stream: u64,
            _payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            self.sent.lock().await.push(flags);
            if flags.contains(FrameFlags::OPEN) {
                self.open_active.store(true, Ordering::Release);
                self.activity_changed.notify_waiters();
                let _guard =
                    ActivityGuard { active: &self.open_active, changed: &self.activity_changed };
                pending::<()>().await;
            }
            Ok(1)
        }

        async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
            self.receive_active.store(true, Ordering::Release);
            self.activity_changed.notify_waiters();
            let _guard =
                ActivityGuard { active: &self.receive_active, changed: &self.activity_changed };
            pending::<()>().await;
            unreachable!()
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> {
            self.generation.subscribe()
        }

        async fn close_session(&self) -> Result<(), ServiceError> {
            Ok(())
        }
    }

    #[async_trait]
    impl SessionEndpoint for ClosedEndpoint {
        async fn send_frame(
            &self,
            _expected_generation: Option<u64>,
            _lane: Lane,
            _stream: u64,
            _payload: Bytes,
            _flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            Err(ServiceError::Closed)
        }

        async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
            Ok(None)
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> {
            self.generation.subscribe()
        }

        async fn close_session(&self) -> Result<(), ServiceError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn clean_session_eof_is_published_as_a_terminal_failure() {
        let (generation, _) = watch::channel(0);
        let multiplexer =
            ServiceMultiplexer::new(Arc::new(ClosedEndpoint { generation }), EndpointRole::Client);
        let mut fatal = multiplexer.subscribe_fatal();

        tokio::time::timeout(Duration::from_secs(1), async {
            while fatal.borrow().is_none() {
                fatal.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
        assert_eq!(fatal.borrow().as_deref(), Some("remote session closed"));
    }

    #[tokio::test]
    async fn open_after_reader_failure_is_rejected_without_a_registration() {
        let (generation, _) = watch::channel(0);
        let multiplexer =
            ServiceMultiplexer::new(Arc::new(ClosedEndpoint { generation }), EndpointRole::Client);
        let mut fatal = multiplexer.subscribe_fatal();
        tokio::time::timeout(Duration::from_secs(1), async {
            while fatal.borrow().is_none() {
                fatal.changed().await.unwrap();
            }
        })
        .await
        .unwrap();

        let error = multiplexer.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap_err();
        assert!(matches!(error, ServiceError::Transport(_)));
        assert!(multiplexer.streams.lock().await.is_empty());
    }

    #[tokio::test]
    async fn dropping_multiplexer_cancels_an_idle_reader() {
        let endpoint = BlockingEndpoint::new();
        let multiplexer = ServiceMultiplexer::new(endpoint.clone(), EndpointRole::Client);
        endpoint.wait_for(&endpoint.receive_active, true).await;

        drop(multiplexer);

        endpoint.wait_for(&endpoint.receive_active, false).await;
    }

    #[tokio::test]
    async fn cancelling_open_resets_and_deregisters_the_pending_stream() {
        let endpoint = BlockingEndpoint::new();
        let multiplexer = ServiceMultiplexer::new(endpoint.clone(), EndpointRole::Client);
        let open = tokio::spawn({
            let multiplexer = multiplexer.clone();
            async move { multiplexer.open(Service::MuxControl, BTreeMap::new()).await }
        });
        endpoint.wait_for(&endpoint.open_active, true).await;

        open.abort();
        assert!(open.await.unwrap_err().is_cancelled());
        endpoint.wait_for(&endpoint.open_active, false).await;
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let reset_sent = endpoint
                    .sent
                    .lock()
                    .await
                    .iter()
                    .any(|flags| flags.contains(FrameFlags::RESET));
                if multiplexer.streams.lock().await.is_empty() && reset_sent {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn failed_fin_can_be_retried_and_blocks_later_payload() {
        let endpoint = FlakyEndpoint::new(0);
        let multiplexer = ServiceMultiplexer::new(endpoint.clone(), EndpointRole::Client);
        let stream =
            Arc::new(multiplexer.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap());

        let (first, second) = tokio::join!(stream.close(), stream.close());
        assert!(matches!(first, Err(ServiceError::Client(ConnectionError::Session(_)))));
        assert!(second.is_ok());
        assert_eq!(endpoint.fin_attempts.load(Ordering::Acquire), 2);
        assert!(matches!(
            stream.send(Bytes::from_static(b"after-fin")).await,
            Err(ServiceError::Closed)
        ));
        assert!(multiplexer.streams.lock().await.is_empty());
    }

    #[tokio::test]
    async fn terminal_reset_retries_queue_pressure_before_closing_the_session() {
        let endpoint = FlakyEndpoint::new(2);
        let cleanup = TerminalCleanup::new();
        cleanup.spawn(endpoint.clone(), None, Lane::Control, 9, None);

        tokio::time::timeout(Duration::from_secs(1), async {
            while endpoint.reset_attempts.load(Ordering::Acquire) < 3 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(endpoint.close_count.load(Ordering::Acquire), 0);
    }

    #[tokio::test]
    async fn terminal_reset_pressure_fails_closed_once_after_its_deadline() {
        let endpoint = FlakyEndpoint::new(usize::MAX);
        let cleanup = TerminalCleanup::with_deadline(Duration::from_millis(10));
        cleanup.spawn(endpoint.clone(), None, Lane::Control, 9, None);

        tokio::time::timeout(Duration::from_secs(1), async {
            while endpoint.close_count.load(Ordering::Acquire) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        tokio::task::yield_now().await;
        assert_eq!(endpoint.close_count.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn reader_failure_errors_active_stream_instead_of_reporting_eof() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let stream = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();

        drop(daemon_endpoint);

        let error = tokio::time::timeout(Duration::from_secs(1), stream.receive())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ServiceError::Transport(_)));
        assert!(client.streams.lock().await.is_empty());
    }

    #[tokio::test]
    async fn byte_budget_reset_errors_the_local_stream() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client =
            ServiceMultiplexer::new_with_incoming_budget(client_endpoint, EndpointRole::Client, 1);
        let stream = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        daemon_endpoint
            .send_frame(
                None,
                Lane::Control,
                stream.id(),
                Bytes::from_static(b"xx"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let error = tokio::time::timeout(Duration::from_secs(1), stream.receive())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ServiceError::Reset(message) if message.contains("byte budget")));
        assert!(matches!(
            stream.send(Bytes::from_static(b"late")).await,
            Err(ServiceError::Reset(_))
        ));
    }

    #[tokio::test]
    async fn tiny_frame_respects_minimum_aggregate_budget_charge() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new_with_incoming_budget(
            client_endpoint,
            EndpointRole::Client,
            1023,
        );
        let stream = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        daemon_endpoint
            .send_frame(
                None,
                Lane::Control,
                stream.id(),
                Bytes::from_static(b"x"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let error = tokio::time::timeout(Duration::from_secs(1), stream.receive())
            .await
            .expect("reader stalled while enforcing the aggregate byte budget")
            .expect_err("a one-byte frame must consume at least one KiB of aggregate budget");
        assert!(matches!(error, ServiceError::Reset(message) if message.contains("byte budget")));
        assert!(client.streams.lock().await.is_empty());
    }

    #[tokio::test]
    async fn undrained_bulk_stream_does_not_reset_or_block_interactive_stream() {
        const FRAME_COUNT: u64 = 1024;
        const FRAME_BYTES: usize = 1024;

        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new_with_incoming_budget(
            client_endpoint,
            EndpointRole::Client,
            2 * 1024 * 1024,
        );
        let bulk = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let interactive = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();

        for index in 0..FRAME_COUNT {
            let mut payload = vec![0; FRAME_BYTES];
            payload[..size_of::<u64>()].copy_from_slice(&index.to_le_bytes());
            daemon_endpoint
                .send_frame(None, Lane::Bulk, bulk.id(), Bytes::from(payload), FrameFlags::empty())
                .await
                .unwrap();
        }
        daemon_endpoint
            .send_frame(
                None,
                Lane::Interactive,
                interactive.id(),
                Bytes::from_static(b"interactive-marker"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let marker = tokio::time::timeout(Duration::from_secs(1), interactive.receive())
            .await
            .expect("interactive stream was blocked behind the undrained bulk stream")
            .expect("interactive stream reset while the bulk stream was undrained")
            .expect("interactive stream ended before delivering its marker");
        assert_eq!(marker.lane, Lane::Interactive);
        assert_eq!(marker.payload, b"interactive-marker".as_slice());
        assert_eq!(bulk.failure.borrow().clone(), None, "undrained bulk stream was reset");
        assert_eq!(interactive.failure.borrow().clone(), None, "interactive stream was reset");

        tokio::time::timeout(Duration::from_secs(1), async {
            for expected in 0..FRAME_COUNT {
                let chunk = bulk
                    .receive()
                    .await
                    .expect("bulk stream reset while draining its backlog")
                    .expect("bulk stream ended before its backlog was drained");
                assert_eq!(chunk.lane, Lane::Bulk);
                assert_eq!(chunk.payload.len(), FRAME_BYTES);
                assert!(!chunk.finished);
                assert!(!chunk.reset);
                let sequence = u64::from_le_bytes(
                    chunk.payload[..size_of::<u64>()]
                        .try_into()
                        .expect("sequence prefix must be eight bytes"),
                );
                assert_eq!(sequence, expected);
            }
        })
        .await
        .expect("bulk backlog did not drain within one second");
        assert_eq!(bulk.failure.borrow().clone(), None, "bulk stream reset after draining");
        assert_eq!(client.streams.lock().await.len(), 2);
    }

    #[tokio::test]
    async fn completed_stream_does_not_poison_the_next_stream() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);

        let first = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let first_peer = daemon.accept().await.unwrap().unwrap().stream;
        first.close().await.unwrap();
        let finished = first_peer.receive().await.unwrap().unwrap();
        assert!(finished.finished);
        assert!(first.receive().await.unwrap().is_none());
        drop(first_peer);

        let second = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        let second_peer = tokio::time::timeout(Duration::from_secs(1), daemon.accept())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(second_peer.service, Service::WorkspaceRpc);
        second.close().await.unwrap();
    }

    #[tokio::test]
    async fn mux_fin_is_a_three_lane_barrier_and_late_tombstoned_frames_are_ignored() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint.clone(), EndpointRole::Daemon);
        let mut fatal = client.subscribe_fatal();
        let client_stream = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
        let stream_id = client_stream.id();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;

        daemon_stream.send_on(Lane::Bulk, Bytes::from_static(b"last")).await.unwrap();
        daemon_stream.close().await.unwrap();
        assert_eq!(client_stream.receive().await.unwrap().unwrap().payload, b"last".as_slice());
        assert!(client_stream.receive().await.unwrap().unwrap().finished);
        assert!(client_stream.receive().await.unwrap().is_none());

        daemon_endpoint
            .send_frame(None, Lane::Bulk, stream_id, Bytes::new(), FrameFlags::FIN)
            .await
            .unwrap();
        daemon_endpoint
            .send_frame(
                None,
                Lane::Bulk,
                stream_id,
                Bytes::from_static(b"late"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(25), fatal.changed()).await.is_err());
        assert!(fatal.borrow().is_none());
    }

    #[tokio::test]
    async fn mux_payload_after_a_lane_fin_resets_before_the_aggregate_fin() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let stream = client.open(Service::MuxControl, BTreeMap::new()).await.unwrap();

        daemon_endpoint
            .send_frame(None, Lane::Bulk, stream.id(), Bytes::new(), FrameFlags::FIN)
            .await
            .unwrap();
        daemon_endpoint
            .send_frame(None, Lane::Bulk, stream.id(), Bytes::new(), FrameFlags::FIN)
            .await
            .unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(25), stream.receive()).await.is_err());
        daemon_endpoint
            .send_frame(
                None,
                Lane::Bulk,
                stream.id(),
                Bytes::from_static(b"after-fin"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let error = tokio::time::timeout(Duration::from_secs(1), stream.receive())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ServiceError::Reset(message) if message.contains("same lane")));
    }

    #[tokio::test]
    async fn local_close_and_drop_deregister_streams_without_waiting_for_peer_fin() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);

        let explicitly_closed = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        let _peer = daemon.accept().await.unwrap().unwrap();
        assert_eq!(client.streams.lock().await.len(), 1);
        explicitly_closed.close().await.unwrap();
        assert!(client.streams.lock().await.is_empty());

        let dropped = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        let _peer = daemon.accept().await.unwrap().unwrap();
        assert_eq!(client.streams.lock().await.len(), 1);
        drop(dropped);
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if client.streams.lock().await.is_empty() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn tcp_fin_half_closes_one_direction_until_the_response_fin_arrives() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);

        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;
        client_stream.send(Bytes::from_static(b"request")).await.unwrap();
        client_stream.close().await.unwrap();
        assert_eq!(client.streams.lock().await.len(), 1);

        let request = daemon_stream.receive().await.unwrap().unwrap();
        assert_eq!(request.payload, b"request".as_slice());
        let request_fin = daemon_stream.receive().await.unwrap().unwrap();
        assert!(request_fin.finished);
        assert!(!request_fin.reset);
        assert!(daemon_stream.receive().await.unwrap().is_none());

        daemon_stream.send(Bytes::from_static(b"response")).await.unwrap();
        daemon_stream.close().await.unwrap();
        let response = client_stream.receive().await.unwrap().unwrap();
        assert_eq!(response.payload, b"response".as_slice());
        let response_fin = client_stream.receive().await.unwrap().unwrap();
        assert!(response_fin.finished);
        assert!(!response_fin.reset);
        assert!(client_stream.receive().await.unwrap().is_none());

        assert!(client.streams.lock().await.is_empty());
        assert!(daemon.streams.lock().await.is_empty());
    }

    #[tokio::test]
    async fn tcp_payload_after_fin_resets_the_stream() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let stream_id = client_stream.id();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;

        client_stream.close().await.unwrap();
        assert!(daemon_stream.receive().await.unwrap().unwrap().finished);
        client_endpoint
            .send_frame(
                Some(0),
                Lane::Tunnel,
                stream_id,
                Bytes::from_static(b"after-fin"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let reset = tokio::time::timeout(Duration::from_secs(1), client_stream.receive())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(reset, ServiceError::Reset(_)));
        assert!(client.streams.lock().await.is_empty());
        assert!(daemon.streams.lock().await.is_empty());
    }

    #[tokio::test]
    async fn tcp_reset_after_fin_replaces_previously_graceful_eof_with_an_error() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint.clone(), EndpointRole::Daemon);
        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let stream_id = client_stream.id();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;

        daemon_stream.close().await.unwrap();
        assert!(client_stream.receive().await.unwrap().unwrap().finished);
        assert!(client_stream.receive().await.unwrap().is_none());
        daemon_endpoint
            .send_frame(Some(0), Lane::Tunnel, stream_id, Bytes::new(), FrameFlags::RESET)
            .await
            .unwrap();

        let failure =
            tokio::time::timeout(Duration::from_secs(1), client_stream.wait_for_failure())
                .await
                .unwrap();
        assert!(matches!(failure, ServiceError::Reset(_)));
        let error = tokio::time::timeout(Duration::from_secs(1), client_stream.receive())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ServiceError::Reset(_)));
        assert!(matches!(
            client_stream.send(Bytes::from_static(b"late")).await,
            Err(ServiceError::Reset(_))
        ));
    }

    #[tokio::test]
    async fn generation_change_after_fin_replaces_previously_graceful_eof_with_an_error() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;

        daemon_stream.close().await.unwrap();
        assert!(client_stream.receive().await.unwrap().unwrap().finished);
        assert!(client_stream.receive().await.unwrap().is_none());
        client_endpoint.advance_generation(1);

        let failure =
            tokio::time::timeout(Duration::from_secs(1), client_stream.wait_for_failure())
                .await
                .unwrap();
        assert!(matches!(failure, ServiceError::GenerationChanged { expected: 0, actual: 1 }));
        let error = tokio::time::timeout(Duration::from_secs(1), client_stream.receive())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ServiceError::GenerationChanged { expected: 0, actual: 1 }));
    }

    #[tokio::test]
    async fn message_stream_rejects_frames_outside_its_declared_lane() {
        use bytes::{BufMut, BytesMut};

        use crate::services::{MessageStream, ServicesError};

        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let client_stream = client
            .open(Service::WorkspaceRpc, BTreeMap::from([("lane".into(), "bulk".into())]))
            .await
            .unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;
        let messages = MessageStream::with_lane(Arc::new(daemon_stream), Lane::Bulk);
        let mut encoded = BytesMut::new();
        encoded.put_u32(3);
        encoded.extend_from_slice(b"bad");
        client_stream.send_on(Lane::Control, encoded.freeze()).await.unwrap();
        assert!(matches!(
            messages.receive().await,
            Err(ServicesError::UnexpectedLane { expected: Lane::Bulk, actual: Lane::Control })
        ));
        assert!(messages.receive().await.unwrap().is_none());
        client_stream.close_on(Lane::Bulk).await.unwrap();

        let client_stream = client
            .open(Service::WorkspaceRpc, BTreeMap::from([("lane".into(), "bulk".into())]))
            .await
            .unwrap();
        let daemon_stream = daemon.accept().await.unwrap().unwrap().stream;
        let messages = MessageStream::with_lane(Arc::new(daemon_stream), Lane::Bulk);
        let mut encoded = BytesMut::new();
        encoded.put_u32(4);
        encoded.extend_from_slice(b"good");
        client_stream.send_on(Lane::Bulk, encoded.freeze()).await.unwrap();
        assert_eq!(messages.receive().await.unwrap().unwrap(), b"good".as_slice());
        client_stream.close_on(Lane::Bulk).await.unwrap();
    }

    #[tokio::test]
    async fn reconnect_resets_tunnels_on_both_sides_but_keeps_resumable_streams() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint.clone(), EndpointRole::Daemon);

        let client_tunnel = client.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let daemon_tunnel = daemon.accept().await.unwrap().unwrap().stream;
        let client_workspace = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        let daemon_workspace = daemon.accept().await.unwrap().unwrap().stream;

        client_endpoint.advance_generation(1);
        daemon_endpoint.advance_generation(1);

        for stream in [&client_tunnel, &daemon_tunnel] {
            let error = tokio::time::timeout(Duration::from_secs(1), stream.receive())
                .await
                .expect("tunnel stream did not reset after reconnect")
                .unwrap_err();
            assert!(matches!(error, ServiceError::GenerationChanged { expected: 0, actual: 1 }));
            assert!(matches!(
                stream.send(Bytes::from_static(b"stale")).await,
                Err(ServiceError::GenerationChanged { expected: 0, actual: 1 })
            ));
        }

        client_workspace.send(Bytes::from_static(b"resumed")).await.unwrap();
        let chunk = tokio::time::timeout(Duration::from_secs(1), daemon_workspace.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(chunk.payload, b"resumed".as_slice());
        assert_eq!(chunk.lane, Lane::Control);
    }
}
