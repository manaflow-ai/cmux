use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::mem::size_of;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{
    Receiver, Sender, SyncSender, TryRecvError, TrySendError, channel,
    sync_channel as bounded_channel,
};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use anyhow::Context;
use base64::Engine;
use serde_json::{Value, json};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::http::header::AUTHORIZATION;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Error as WsError, Message, WebSocket, client_with_config};

/// Maximum number of pending events in each bounded CDP event queue.
///
/// Downstream queue implementations use the same limit so moving an event
/// between CDP layers cannot expand the maximum pending event count.
pub const CDP_EVENT_QUEUE_CAPACITY: usize = 64;
const CDP_INGRESS_EVENT_CAPACITY: usize = 1024;
// Navigation may invalidate a frame tree while its response is in flight.
// Bound retries so a continuously navigating page cannot block the caller forever.
const MAIN_FRAME_SNAPSHOT_ATTEMPTS: usize = 8;
/// Maximum estimated retained bytes in each bounded CDP event queue.
///
/// The estimate covers dynamically retained event payloads and uses saturating
/// arithmetic. It is a queue-enforcement budget, not an exact allocator usage
/// measurement.
pub const CDP_EVENT_QUEUE_MAX_BYTES: usize = 32 * 1024 * 1024;
/// Maximum number of commands waiting for the CDP reader thread.
///
/// A bounded command queue keeps a stalled browser from retaining an
/// unbounded number of JSON messages. Callers fail fast when the queue is
/// full, so a blocked reader cannot block the TUI thread indefinitely.
const CDP_OUTBOUND_QUEUE_CAPACITY: usize = 256;
const CDP_OUTBOUND_QUEUE_MAX_BYTES: usize = 8 * 1024 * 1024;
// Include tungstenite's default 128 KiB staging buffer and frame overhead in
// addition to the largest message admitted by the outbound byte budget.
const CDP_SOCKET_WRITE_BUFFER_MAX_BYTES: usize = CDP_OUTBOUND_QUEUE_MAX_BYTES + 256 * 1024;
const CDP_CONNECTION_UNAVAILABLE_MESSAGE: &str =
    "browser connection unavailable; retry the command";
const CDP_OUTBOUND_QUEUE_BYTE_BUDGET_DETAIL: &str = "CDP outbound queue byte budget exceeded";
const MAX_ENCODED_FRAME_BYTES: usize = 16 * 1024 * 1024;
const MAX_DECODED_FRAME_BYTES: usize = 12 * 1024 * 1024;
const TIMESTAMPLESS_CAPTURE_INTERVAL: Duration = Duration::from_secs(1);
const SCREENCAST_CLOCK_RECOVERY_BUDGET: Duration = Duration::from_secs(1);

#[cfg(test)]
static RETAINED_SIZE_CALLS: AtomicU64 = AtomicU64::new(0);

/// Monotonic browser-frame generation shared by CDP ingress and one surface.
///
/// Navigation events and successful capture restarts advance the generation
/// before later frames enter either bounded event queue.
#[derive(Debug, Default)]
pub struct FrameEpoch {
    current: AtomicU64,
    latest_navigation: AtomicU64,
    latest_same_document_navigation: AtomicU64,
    pointer_motion_generation: AtomicU64,
    wait_lock: Mutex<()>,
    changed: Condvar,
}

impl FrameEpoch {
    pub fn current(&self) -> u64 {
        self.current.load(Ordering::Acquire)
    }

    pub fn advance(&self) -> u64 {
        let _guard = self.wait_lock.lock().unwrap();
        let epoch = self.current.fetch_add(1, Ordering::AcqRel).wrapping_add(1);
        self.changed.notify_all();
        epoch
    }

    pub fn advance_navigation(&self) -> u64 {
        let _guard = self.wait_lock.lock().unwrap();
        let epoch = self.current.fetch_add(1, Ordering::AcqRel).wrapping_add(1);
        self.latest_navigation.store(epoch, Ordering::Release);
        self.changed.notify_all();
        epoch
    }

    pub fn advance_same_document(&self) -> u64 {
        let _guard = self.wait_lock.lock().unwrap();
        // Odd values mark the ingress transition itself. Captured motion sees
        // the mismatch immediately, while new presses reject the unstable
        // token until the frame epoch has advanced.
        self.pointer_motion_generation.fetch_add(1, Ordering::AcqRel);
        let epoch = self.current.fetch_add(1, Ordering::AcqRel).wrapping_add(1);
        self.latest_same_document_navigation.store(epoch, Ordering::Release);
        self.pointer_motion_generation.fetch_add(1, Ordering::AcqRel);
        self.changed.notify_all();
        epoch
    }

    pub fn latest_navigation(&self) -> u64 {
        self.latest_navigation.load(Ordering::Acquire)
    }

    pub fn latest_same_document_navigation(&self) -> u64 {
        self.latest_same_document_navigation.load(Ordering::Acquire)
    }

    pub fn pointer_motion_generation(&self) -> u64 {
        self.pointer_motion_generation.load(Ordering::Acquire)
    }

    pub fn wait_until_at_least(&self, expected: u64, timeout: Duration) -> bool {
        if self.current() >= expected {
            return true;
        }
        let deadline = Instant::now() + timeout;
        let mut guard = self.wait_lock.lock().unwrap();
        loop {
            if self.current() >= expected {
                return true;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next_guard, wait) = self.changed.wait_timeout(guard, remaining).unwrap();
            guard = next_guard;
            if wait.timed_out() && self.current() < expected {
                return false;
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreencastFrame {
    pub session_id: String,
    pub data_b64: String,
    pub css_width: u32,
    pub css_height: u32,
    pub image_width: u32,
    pub image_height: u32,
    pub ack_id: u64,
    pub frame_epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedFrame {
    pub data_b64: String,
    pub css_width: u32,
    pub css_height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetInfo {
    pub session_id: Option<String>,
    pub target_id: String,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetCreated {
    pub target_id: String,
    pub opener_id: Option<String>,
    pub target_type: String,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationEntry {
    pub id: u64,
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationHistory {
    pub current_index: usize,
    pub entries: Vec<NavigationEntry>,
}

/// A connection close classification that is safe to pass across crate and
/// UI boundaries. Transport details stay in the reader's diagnostic stream;
/// callers receive only this stable recovery message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CdpCloseReason {
    EventReceiverClosed,
    TransportFailure,
    SocketClosed,
    EventQueueOverflow,
    OutboundQueueOverflow,
    ConnectionClosed,
    ClientDropped,
    RuntimeClosed,
    SurfaceClosed,
}

impl CdpCloseReason {
    pub const fn public_message(self) -> &'static str {
        CDP_CONNECTION_UNAVAILABLE_MESSAGE
    }
}

impl std::fmt::Display for CdpCloseReason {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.public_message())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationResult {
    pub error_text: Option<String>,
    pub is_download: bool,
    pub loader_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MainFrameSnapshot {
    pub frame_id: String,
    pub loader_id: String,
    pub same_document_navigation_epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CdpEvent {
    ScreencastFrame(ScreencastFrame),
    ScreencastFrameCaptureRequested {
        session_id: String,
        frame_id: String,
        loader_id: String,
        request_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    },
    FrameNavigated {
        params: Value,
        session_id: String,
        frame_epoch: u64,
    },
    DocumentPainted {
        session_id: String,
        frame_id: String,
        loader_id: String,
        navigation_epoch: u64,
    },
    NavigatedWithinDocument {
        params: Value,
        session_id: String,
        frame_id: String,
        loader_id: String,
        frame_epoch: u64,
    },
    TargetCreated(TargetCreated),
    TargetInfoChanged(TargetInfo),
    Other {
        method: String,
        params: Value,
        session_id: Option<String>,
    },
    Closed(CdpCloseReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CdpKeyEvent<'a> {
    pub event_type: &'a str,
    pub key: &'a str,
    pub code: &'a str,
    pub windows_virtual_key_code: u32,
    pub modifiers: u32,
    pub text: Option<&'a str>,
}

fn key_event_params(event: CdpKeyEvent<'_>) -> Value {
    let mut params = json!({
        "type": event.event_type,
        "key": event.key,
        "modifiers": event.modifiers,
    });
    if !event.code.is_empty() {
        params["code"] = json!(event.code);
    }
    if event.windows_virtual_key_code != 0 {
        params["windowsVirtualKeyCode"] = json!(event.windows_virtual_key_code);
        params["nativeVirtualKeyCode"] = json!(event.windows_virtual_key_code);
    }
    if let Some(text) = event.text {
        params["text"] = json!(text);
        params["unmodifiedText"] = json!(text);
    }
    params
}

fn wheel_event_params(x: f64, y: f64, delta_x: f64, delta_y: f64) -> Value {
    json!({
        "type": "mouseWheel",
        "x": x,
        "y": y,
        "deltaX": delta_x,
        "deltaY": delta_y,
    })
}

fn cdp_debug() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("CMUX_MUX_CDP_DEBUG").is_some())
}

#[derive(Clone)]
pub struct CdpClient {
    inner: Arc<Inner>,
}

struct Inner {
    outbound: SyncSender<Outbound>,
    outbound_bytes: AtomicU64,
    outbound_byte_budget: usize,
    pending: Mutex<HashMap<u64, PendingCall>>,
    events: Arc<EventQueue>,
    frame_epochs: Mutex<HashMap<String, FrameSession>>,
    next_id: AtomicU64,
    next_screencast_capture_request_id: AtomicU64,
    closed: AtomicBool,
    timeout: Duration,
    #[cfg(test)]
    reader_stopped: Arc<AtomicBool>,
}

struct PendingCall {
    response: Sender<Result<Value, String>>,
    frame_barrier: Option<Arc<FrameEpoch>>,
}

struct FrameSession {
    epoch: Arc<FrameEpoch>,
    main_frame_id: Option<String>,
    main_loader_id: Option<String>,
    pending_document: Option<PendingDocument>,
    screencast_barrier: Option<ScreencastBarrier>,
    pending_timestampless_capture: Option<PendingTimestamplessCapture>,
    timestampless_capture_throttle: Option<TimestamplessCaptureThrottle>,
    suppressed_timestampless_epoch: Option<u64>,
}

#[derive(Clone, Copy)]
enum ScreencastBarrier {
    Timestamp(f64),
    LoaderVerifiedCapture,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct PendingTimestamplessCapture {
    request_id: u64,
    frame_epoch: u64,
    navigation_epoch: u64,
}

#[derive(Clone, Copy)]
struct TimestamplessCaptureThrottle {
    frame_epoch: u64,
    navigation_epoch: u64,
    retry_at: Instant,
}

struct PendingDocument {
    frame_id: String,
    loader_id: String,
    navigation_epoch: u64,
}

#[derive(Debug)]
struct MainFrameSnapshotInvalidated;

impl std::fmt::Display for MainFrameSnapshotInvalidated {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Page.getFrameTree snapshot was invalidated by concurrent navigation")
    }
}

impl std::error::Error for MainFrameSnapshotInvalidated {}

struct EventQueue {
    state: Mutex<EventQueueState>,
}

#[derive(Default)]
struct EventQueueState {
    events: VecDeque<QueuedEvent>,
    retained_bytes: usize,
    closed: bool,
}

struct QueuedEvent {
    event: CdpEvent,
    retained_bytes: usize,
}

impl EventQueue {
    fn new() -> Self {
        Self { state: Mutex::new(EventQueueState::default()) }
    }

    fn push(&self, event: CdpEvent) -> Result<(), ()> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(());
        }
        let event_bytes = event_retained_bytes(&event);
        if let Some(index) =
            state.events.iter().position(|queued| same_replaceable(&queued.event, &event))
        {
            let previous_bytes = state.events[index].retained_bytes;
            let retained_bytes = state
                .retained_bytes
                .checked_sub(previous_bytes)
                .and_then(|bytes| bytes.checked_add(event_bytes))
                .ok_or(())?;
            if retained_bytes > CDP_EVENT_QUEUE_MAX_BYTES {
                return Err(());
            }
            state.events.remove(index);
            state.events.push_back(QueuedEvent { event, retained_bytes: event_bytes });
            state.retained_bytes = retained_bytes;
        } else {
            let retained_bytes = state.retained_bytes.checked_add(event_bytes).ok_or(())?;
            if state.events.len() >= CDP_INGRESS_EVENT_CAPACITY
                || retained_bytes > CDP_EVENT_QUEUE_MAX_BYTES
            {
                return Err(());
            }
            state.events.push_back(QueuedEvent { event, retained_bytes: event_bytes });
            state.retained_bytes = retained_bytes;
        }
        Ok(())
    }

    fn drain_into(&self, output: &SyncSender<CdpEvent>) -> Result<(), ()> {
        let mut state = self.state.lock().unwrap();
        while let Some(queued) = state.events.pop_front() {
            state.retained_bytes = state.retained_bytes.saturating_sub(queued.retained_bytes);
            match output.try_send(queued.event) {
                Ok(()) => {}
                Err(TrySendError::Full(event)) => {
                    state.retained_bytes =
                        state.retained_bytes.saturating_add(queued.retained_bytes);
                    state
                        .events
                        .push_front(QueuedEvent { event, retained_bytes: queued.retained_bytes });
                    return Ok(());
                }
                Err(TrySendError::Disconnected(_)) => return Err(()),
            }
        }
        Ok(())
    }

    fn close(&self, reason: CdpCloseReason) {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return;
        }
        state.events.clear();
        let event = CdpEvent::Closed(reason);
        let retained_bytes = event_retained_bytes(&event);
        state.retained_bytes = retained_bytes;
        state.events.push_back(QueuedEvent { event, retained_bytes });
        state.closed = true;
    }
}

fn same_replaceable(queued: &CdpEvent, incoming: &CdpEvent) -> bool {
    match (queued, incoming) {
        (CdpEvent::ScreencastFrame(queued), CdpEvent::ScreencastFrame(incoming)) => {
            queued.session_id == incoming.session_id
        }
        (
            CdpEvent::ScreencastFrameCaptureRequested { session_id: queued, .. },
            CdpEvent::ScreencastFrameCaptureRequested { session_id: incoming, .. },
        ) => queued == incoming,
        (CdpEvent::TargetInfoChanged(queued), CdpEvent::TargetInfoChanged(incoming)) => {
            queued.target_id == incoming.target_id
        }
        _ => false,
    }
}

/// Estimates the bytes retained by a CDP event for bounded-queue accounting.
///
/// The result includes dynamically owned strings and JSON data, plus the frame
/// container size, using saturating arithmetic. Callers should compare it with
/// [`CDP_EVENT_QUEUE_MAX_BYTES`], not treat it as exact allocator usage.
pub fn event_retained_bytes(event: &CdpEvent) -> usize {
    #[cfg(test)]
    RETAINED_SIZE_CALLS.fetch_add(1, Ordering::Relaxed);
    match event {
        CdpEvent::ScreencastFrame(frame) => frame
            .data_b64
            .len()
            .saturating_add(frame.session_id.len())
            .saturating_add(size_of::<ScreencastFrame>()),
        CdpEvent::ScreencastFrameCaptureRequested { session_id, frame_id, loader_id, .. } => {
            session_id
                .len()
                .saturating_add(frame_id.len())
                .saturating_add(loader_id.len())
                .saturating_add(size_of::<u64>().saturating_mul(3))
        }
        CdpEvent::FrameNavigated { params, session_id, .. } => session_id
            .len()
            .saturating_add(json_retained_bytes(params))
            .saturating_add(size_of::<u64>()),
        CdpEvent::DocumentPainted { session_id, frame_id, loader_id, .. } => session_id
            .len()
            .saturating_add(frame_id.len())
            .saturating_add(loader_id.len())
            .saturating_add(size_of::<u64>()),
        CdpEvent::NavigatedWithinDocument { params, session_id, frame_id, loader_id, .. } => {
            session_id
                .len()
                .saturating_add(frame_id.len())
                .saturating_add(loader_id.len())
                .saturating_add(json_retained_bytes(params))
                .saturating_add(size_of::<u64>())
        }
        CdpEvent::TargetCreated(target) => target
            .target_id
            .len()
            .saturating_add(target.opener_id.as_ref().map_or(0, String::len))
            .saturating_add(target.target_type.len())
            .saturating_add(target.title.len())
            .saturating_add(target.url.len()),
        CdpEvent::TargetInfoChanged(info) => info
            .session_id
            .as_ref()
            .map_or(0, String::len)
            .saturating_add(info.target_id.len())
            .saturating_add(info.title.len())
            .saturating_add(info.url.len()),
        CdpEvent::Other { method, params, session_id } => method
            .len()
            .saturating_add(json_retained_bytes(params))
            .saturating_add(session_id.as_ref().map_or(0, String::len)),
        CdpEvent::Closed(reason) => reason.public_message().len(),
    }
}

fn json_retained_bytes(value: &Value) -> usize {
    let base = size_of::<Value>();
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => base,
        Value::String(value) => base.saturating_add(value.capacity()),
        Value::Array(values) => values.iter().fold(
            base.saturating_add(values.capacity().saturating_mul(size_of::<Value>())),
            |bytes, value| bytes.saturating_add(json_retained_bytes(value)),
        ),
        Value::Object(values) => values.iter().fold(base, |bytes, (key, value)| {
            bytes
                .saturating_add(size_of::<String>())
                .saturating_add(size_of::<Value>())
                .saturating_add(key.capacity())
                .saturating_add(json_retained_bytes(value))
        }),
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.events.close(CdpCloseReason::ClientDropped);
    }
}

enum Outbound {
    Message(String),
    Flush(Sender<()>),
}

impl CdpClient {
    pub fn connect(web_socket_url: &str, events: SyncSender<CdpEvent>) -> anyhow::Result<Self> {
        Self::connect_with_bearer(web_socket_url, None, events)
    }

    pub fn connect_with_bearer(
        web_socket_url: &str,
        bearer_token: Option<&str>,
        events: SyncSender<CdpEvent>,
    ) -> anyhow::Result<Self> {
        let endpoint = WsEndpoint::parse(web_socket_url)?;
        let mut addrs = (endpoint.host.as_str(), endpoint.port).to_socket_addrs()?;
        let addr = addrs.next().ok_or_else(|| {
            anyhow::anyhow!("no socket address for {}:{}", endpoint.host, endpoint.port)
        })?;
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))?;
        stream.set_nodelay(true)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let mut request = web_socket_url.into_client_request()?;
        if let Some(token) = bearer_token {
            let value = HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|error| anyhow::anyhow!("invalid CDP bearer token: {error}"))?;
            request.headers_mut().insert(AUTHORIZATION, value);
        }
        let (ws, _) = client_with_config(request, stream, Some(cdp_websocket_config()))?;
        // The reader thread owns the socket and drains queued outbound
        // writes before each read poll. A message enqueued just after a
        // read starts can wait for this window, but writers never contend
        // on the socket itself.
        ws.get_ref().set_read_timeout(Some(Duration::from_millis(20)))?;
        ws.get_ref().set_write_timeout(Some(Duration::from_secs(5)))?;
        let (outbound_tx, outbound_rx) = bounded_channel(CDP_OUTBOUND_QUEUE_CAPACITY);
        let event_queue = Arc::new(EventQueue::new());
        let client = CdpClient {
            inner: Arc::new(Inner {
                outbound: outbound_tx,
                outbound_bytes: AtomicU64::new(0),
                outbound_byte_budget: CDP_OUTBOUND_QUEUE_MAX_BYTES,
                pending: Mutex::new(HashMap::new()),
                events: event_queue,
                frame_epochs: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
                next_screencast_capture_request_id: AtomicU64::new(1),
                closed: AtomicBool::new(false),
                timeout: Duration::from_secs(30),
                #[cfg(test)]
                reader_stopped: Arc::new(AtomicBool::new(false)),
            }),
        };
        client.spawn_reader(ws, outbound_rx, events)?;
        Ok(client)
    }

    fn spawn_reader(
        &self,
        ws: WebSocket<TcpStream>,
        outbound: Receiver<Outbound>,
        event_output: SyncSender<CdpEvent>,
    ) -> anyhow::Result<()> {
        let weak = Arc::downgrade(&self.inner);
        #[cfg(test)]
        let reader_stopped = self.inner.reader_stopped.clone();
        std::thread::Builder::new().name("cmux-tui-cdp-reader".into()).spawn(move || {
            reader_loop(&weak, ws, &outbound, &event_output);
            #[cfg(test)]
            reader_stopped.store(true, Ordering::Release);
        })?;
        Ok(())
    }

    /// JSON-RPC call. Page-scoped commands pass a flat-session
    /// `session_id`, which is emitted as the top-level CDP `sessionId`.
    pub fn call(
        &self,
        method: &str,
        params: Value,
        session_id: Option<&str>,
    ) -> anyhow::Result<Value> {
        self.call_inner(method, params, session_id, None, None)
    }

    fn call_before(
        &self,
        method: &str,
        params: Value,
        session_id: Option<&str>,
        deadline: Instant,
    ) -> anyhow::Result<Value> {
        self.call_inner(method, params, session_id, None, Some(deadline))
    }

    fn call_with_frame_barrier(
        &self,
        method: &str,
        params: Value,
        session_id: &str,
        frame_barrier: Arc<FrameEpoch>,
    ) -> anyhow::Result<Value> {
        self.call_inner(method, params, Some(session_id), Some(frame_barrier), None)
    }

    fn call_with_frame_barrier_before(
        &self,
        method: &str,
        params: Value,
        session_id: &str,
        frame_barrier: Arc<FrameEpoch>,
        deadline: Instant,
    ) -> anyhow::Result<Value> {
        self.call_inner(method, params, Some(session_id), Some(frame_barrier), Some(deadline))
    }

    fn call_inner(
        &self,
        method: &str,
        params: Value,
        session_id: Option<&str>,
        frame_barrier: Option<Arc<FrameEpoch>>,
        deadline: Option<Instant>,
    ) -> anyhow::Result<Value> {
        let timeout = match deadline {
            Some(deadline) => {
                let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                    anyhow::bail!("CDP call {method} timed out");
                };
                self.inner.timeout.min(remaining)
            }
            None => self.inner.timeout,
        };
        if timeout.is_zero() {
            anyhow::bail!("CDP call {method} timed out");
        }
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = channel();
        self.inner.pending.lock().unwrap().insert(id, PendingCall { response: tx, frame_barrier });

        let mut msg = json!({
            "id": id,
            "method": method,
            "params": null,
        });
        msg["params"] = params;
        if let Some(session_id) = session_id {
            msg["sessionId"] = json!(session_id);
        }
        if let Err(e) = self.send_value(&msg) {
            self.inner.pending.lock().unwrap().remove(&id);
            return Err(e);
        }

        match rx.recv_timeout(timeout) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(e)) => anyhow::bail!("{e}"),
            Err(_) => {
                self.inner.pending.lock().unwrap().remove(&id);
                anyhow::bail!("CDP call {method} timed out")
            }
        }
    }

    pub fn register_frame_epoch(&self, session_id: &str, frame_epoch: Arc<FrameEpoch>) {
        self.inner.frame_epochs.lock().unwrap().insert(
            session_id.to_string(),
            FrameSession {
                epoch: frame_epoch,
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                screencast_barrier: None,
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );
    }

    pub fn unregister_frame_epoch(&self, session_id: &str) {
        self.inner.frame_epochs.lock().unwrap().remove(session_id);
    }

    pub fn set_discover_targets(&self, discover: bool) -> anyhow::Result<()> {
        self.call("Target.setDiscoverTargets", json!({ "discover": discover }), None).map(|_| ())
    }

    pub fn browser_version(&self) -> anyhow::Result<String> {
        let result = self.call("Browser.getVersion", json!({}), None)?;
        result
            .get("userAgent")
            .and_then(|value| value.as_str())
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("Browser.getVersion response missing userAgent"))
    }

    pub fn create_target(&self, url: &str) -> anyhow::Result<String> {
        let result = self.call("Target.createTarget", json!({ "url": url }), None)?;
        result
            .get("targetId")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("Target.createTarget response missing targetId"))
    }

    pub fn attach_to_target(&self, target_id: &str) -> anyhow::Result<String> {
        let result = self.call(
            "Target.attachToTarget",
            json!({ "targetId": target_id, "flatten": true }),
            None,
        )?;
        result
            .get("sessionId")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("Target.attachToTarget response missing sessionId"))
    }

    pub fn close_target(&self, target_id: &str) -> anyhow::Result<()> {
        self.call("Target.closeTarget", json!({ "targetId": target_id }), None).map(|_| ())
    }

    pub fn close_target_detached(&self, target_id: &str) -> anyhow::Result<()> {
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let msg = json!({
            "id": id,
            "method": "Target.closeTarget",
            "params": { "targetId": target_id },
        });
        self.send_value(&msg)
    }

    /// Release one flattened target session without closing the page it
    /// belongs to. Provider-owned browser tabs outlive cmux-tui renderers, so
    /// their teardown must detach instead of sending `Target.closeTarget`.
    pub fn detach_from_target_detached(&self, session_id: &str) -> anyhow::Result<()> {
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let msg = json!({
            "id": id,
            "method": "Target.detachFromTarget",
            "params": { "sessionId": session_id },
        });
        self.send_value(&msg)
    }

    /// Wait until every command queued before this call has been written to
    /// the socket. Responses remain asynchronous.
    pub fn flush_outbound(&self, timeout: Duration) -> anyhow::Result<()> {
        if self.inner.closed.load(Ordering::Acquire) {
            anyhow::bail!("CDP connection is closed");
        }
        let (tx, rx) = channel();
        self.inner.outbound.try_send(Outbound::Flush(tx)).map_err(outbound_send_error)?;
        rx.recv_timeout(timeout).map_err(|_| anyhow::anyhow!("timed out flushing CDP commands"))
    }

    pub fn page_enable(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.enable", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn set_lifecycle_events_enabled(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.setLifecycleEventsEnabled", json!({ "enabled": true }), Some(session_id))
            .map(|_| ())
    }

    pub fn seed_main_frame(&self, session_id: &str) -> anyhow::Result<()> {
        self.snapshot_main_frame_with_retry(session_id).map(|_| ())
    }

    pub fn snapshot_main_frame_with_retry(
        &self,
        session_id: &str,
    ) -> anyhow::Result<MainFrameSnapshot> {
        let mut remaining_attempts = MAIN_FRAME_SNAPSHOT_ATTEMPTS;
        loop {
            match self.snapshot_main_frame(session_id) {
                Ok(snapshot) => return Ok(snapshot),
                Err(error)
                    if error.is::<MainFrameSnapshotInvalidated>() && remaining_attempts > 1 =>
                {
                    remaining_attempts -= 1;
                }
                Err(error) => return Err(error),
            }
        }
    }

    pub fn snapshot_main_frame(&self, session_id: &str) -> anyhow::Result<MainFrameSnapshot> {
        let (frame_epoch, observed_epoch, observed_same_document_navigation_epoch) = {
            let frame_epochs = self.inner.frame_epochs.lock().unwrap();
            let frame_session = frame_epochs.get(session_id).ok_or_else(|| {
                anyhow::anyhow!("missing frame epoch for CDP session {session_id}")
            })?;
            (
                frame_session.epoch.clone(),
                frame_session.epoch.current(),
                frame_session.epoch.latest_same_document_navigation(),
            )
        };
        let result = self.call("Page.getFrameTree", json!({}), Some(session_id))?;
        let frame = result
            .get("frameTree")
            .and_then(|frame_tree| frame_tree.get("frame"))
            .ok_or_else(|| anyhow::anyhow!("Page.getFrameTree response missing root frame"))?;
        let frame_id = frame
            .get("id")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Page.getFrameTree root frame missing id"))?;
        let loader_id = frame
            .get("loaderId")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow::anyhow!("Page.getFrameTree root frame missing loaderId"))?;
        if !commit_main_frame_snapshot(
            &self.inner,
            session_id,
            &frame_epoch,
            observed_epoch,
            frame_id,
            loader_id,
        ) {
            return Err(MainFrameSnapshotInvalidated.into());
        }
        Ok(MainFrameSnapshot {
            frame_id: frame_id.to_string(),
            loader_id: loader_id.to_string(),
            same_document_navigation_epoch: observed_same_document_navigation_epoch,
        })
    }

    pub fn set_user_agent(&self, session_id: &str, user_agent: &str) -> anyhow::Result<()> {
        self.call(
            "Emulation.setUserAgentOverride",
            json!({ "userAgent": user_agent }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn start_screencast(
        &self,
        session_id: &str,
        max_width: u32,
        max_height: u32,
    ) -> anyhow::Result<()> {
        self.call(
            "Page.startScreencast",
            json!({
                "format": "png",
                "maxWidth": max_width,
                "maxHeight": max_height,
                "everyNthFrame": 1,
            }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn start_screencast_with_frame_barrier(
        &self,
        session_id: &str,
        max_width: u32,
        max_height: u32,
    ) -> anyhow::Result<u64> {
        self.start_screencast_with_frame_barrier_deadline(session_id, max_width, max_height, None)
    }

    pub fn start_screencast_with_frame_barrier_before(
        &self,
        session_id: &str,
        max_width: u32,
        max_height: u32,
        deadline: Instant,
    ) -> anyhow::Result<u64> {
        self.start_screencast_with_frame_barrier_deadline(
            session_id,
            max_width,
            max_height,
            Some(deadline),
        )
    }

    fn start_screencast_with_frame_barrier_deadline(
        &self,
        session_id: &str,
        max_width: u32,
        max_height: u32,
        deadline: Option<Instant>,
    ) -> anyhow::Result<u64> {
        let (frame_epoch, main_frame_id) = {
            let frame_sessions = self.inner.frame_epochs.lock().unwrap();
            let frame_session = frame_sessions.get(session_id).ok_or_else(|| {
                anyhow::anyhow!("missing frame epoch for CDP session {session_id}")
            })?;
            let main_frame_id = frame_session.main_frame_id.clone().ok_or_else(|| {
                anyhow::anyhow!("missing main frame for CDP session {session_id}")
            })?;
            (frame_session.epoch.clone(), main_frame_id)
        };
        let screencast_barrier = self
            .chrome_wall_time_upper_bound(session_id, &main_frame_id, deadline)
            .map_or(ScreencastBarrier::LoaderVerifiedCapture, ScreencastBarrier::Timestamp);
        {
            let mut frame_sessions = self.inner.frame_epochs.lock().unwrap();
            let frame_session = frame_sessions.get_mut(session_id).ok_or_else(|| {
                anyhow::anyhow!("missing frame epoch for CDP session {session_id}")
            })?;
            if !Arc::ptr_eq(&frame_session.epoch, &frame_epoch)
                || frame_session.main_frame_id.as_deref() != Some(main_frame_id.as_str())
            {
                anyhow::bail!(
                    "main frame changed while establishing screencast barrier for {session_id}"
                );
            }
            // Chromium records this timestamp when pixels enter the screencast
            // pipeline, before asynchronous encoding. A frame captured before
            // stopScreencast may otherwise be emitted after this restart with
            // the new Chromium session id.
            // When JavaScript execution is unavailable, streamed timestamps
            // have no trustworthy cutoff. Keep the stream alive and verify
            // its pixels through the bounded loader-bracketed capture path.
            frame_session.screencast_barrier = Some(screencast_barrier);
            frame_session.pending_timestampless_capture = None;
            frame_session.timestampless_capture_throttle = None;
            frame_session.suppressed_timestampless_epoch = None;
        }
        let params = json!({
            "format": "png",
            "maxWidth": max_width,
            "maxHeight": max_height,
            "everyNthFrame": 1,
        });
        match deadline {
            Some(deadline) => self.call_with_frame_barrier_before(
                "Page.startScreencast",
                params,
                session_id,
                frame_epoch.clone(),
                deadline,
            )?,
            None => self.call_with_frame_barrier(
                "Page.startScreencast",
                params,
                session_id,
                frame_epoch.clone(),
            )?,
        };
        Ok(frame_epoch.current())
    }

    /// Complete one loader-verified recovery request and restore timestamp
    /// admission when Chrome's wall clock is available again.
    pub fn settle_timestampless_screencast_capture(
        &self,
        session_id: &str,
        request_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let expected = PendingTimestamplessCapture { request_id, frame_epoch, navigation_epoch };
        let recovery_frame = {
            let frame_sessions = self.inner.frame_epochs.lock().unwrap();
            let Some(frame_session) = frame_sessions.get(session_id) else {
                return false;
            };
            if frame_session.epoch.current() != frame_epoch
                || frame_session.pending_timestampless_capture != Some(expected)
            {
                return false;
            }
            matches!(
                frame_session.screencast_barrier,
                Some(ScreencastBarrier::LoaderVerifiedCapture)
            )
            .then(|| frame_session.main_frame_id.clone())
            .flatten()
        };
        let recovered_barrier = recovery_frame.and_then(|frame_id| {
            self.chrome_wall_time_upper_bound(
                session_id,
                &frame_id,
                Some(Instant::now() + SCREENCAST_CLOCK_RECOVERY_BUDGET),
            )
            .ok()
            .map(ScreencastBarrier::Timestamp)
        });
        let mut frame_sessions = self.inner.frame_epochs.lock().unwrap();
        let Some(frame_session) = frame_sessions.get_mut(session_id) else {
            return false;
        };
        if frame_session.epoch.current() != frame_epoch
            || frame_session.pending_timestampless_capture != Some(expected)
        {
            return false;
        }
        frame_session.pending_timestampless_capture = None;
        if let Some(barrier) = recovered_barrier {
            frame_session.screencast_barrier = Some(barrier);
            frame_session.timestampless_capture_throttle = None;
            frame_session.suppressed_timestampless_epoch = None;
        }
        true
    }

    /// Release a recovery request without treating cancellation or
    /// displacement as loader verification.
    pub fn cancel_timestampless_screencast_capture(
        &self,
        session_id: &str,
        request_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let mut frame_sessions = self.inner.frame_epochs.lock().unwrap();
        let Some(frame_session) = frame_sessions.get_mut(session_id) else {
            return false;
        };
        let expected = PendingTimestamplessCapture { request_id, frame_epoch, navigation_epoch };
        if frame_session.epoch.current() != frame_epoch
            || frame_session.pending_timestampless_capture != Some(expected)
        {
            return false;
        }
        frame_session.pending_timestampless_capture = None;
        true
    }

    /// Reject timestamp-less screencast frames only when the failed capture
    /// still owns recovery for this exact stream and navigation generation.
    pub fn suppress_timestampless_screencast_capture(
        &self,
        session_id: &str,
        request_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let mut frame_sessions = self.inner.frame_epochs.lock().unwrap();
        let Some(frame_session) = frame_sessions.get_mut(session_id) else {
            return false;
        };
        let expected = PendingTimestamplessCapture { request_id, frame_epoch, navigation_epoch };
        if frame_session.epoch.current() != frame_epoch
            || frame_session.pending_timestampless_capture != Some(expected)
        {
            return false;
        }
        frame_session.pending_timestampless_capture = None;
        frame_session.suppressed_timestampless_epoch = Some(frame_epoch);
        true
    }

    fn chrome_wall_time_upper_bound(
        &self,
        session_id: &str,
        frame_id: &str,
        deadline: Option<Instant>,
    ) -> anyhow::Result<f64> {
        let world_params = json!({
            "frameId": frame_id,
            "worldName": "cmux-screencast-barrier",
            "grantUniversalAccess": false,
        });
        let world = match deadline {
            Some(deadline) => self.call_before(
                "Page.createIsolatedWorld",
                world_params,
                Some(session_id),
                deadline,
            )?,
            None => self.call("Page.createIsolatedWorld", world_params, Some(session_id))?,
        };
        let context_id =
            world.get("executionContextId").and_then(Value::as_u64).ok_or_else(|| {
                anyhow::anyhow!("Page.createIsolatedWorld response missing executionContextId")
            })?;
        let evaluate_params = json!({
            "expression": "globalThis.Date.now()",
            "contextId": context_id,
            "returnByValue": true,
            "silent": true,
        });
        let evaluated = match deadline {
            Some(deadline) => {
                self.call_before("Runtime.evaluate", evaluate_params, Some(session_id), deadline)?
            }
            None => self.call("Runtime.evaluate", evaluate_params, Some(session_id))?,
        };
        if evaluated.get("exceptionDetails").is_some() {
            anyhow::bail!("Runtime.evaluate failed while reading Chrome wall time");
        }
        let milliseconds = evaluated
            .get("result")
            .and_then(|result| result.get("value"))
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite() && *value >= 0.0)
            .ok_or_else(|| {
                anyhow::anyhow!("Runtime.evaluate returned an invalid Chrome wall time")
            })?;
        // Date.now() has millisecond resolution. Adding one millisecond makes
        // this an upper bound on the evaluation instant, so no pre-stop
        // capture can slip through a truncated value. A first post-start
        // capture inside this millisecond may be skipped; later frames pass.
        Ok(milliseconds / 1_000.0 + 0.001)
    }

    pub fn stop_screencast(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.stopScreencast", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn stop_screencast_before(
        &self,
        session_id: &str,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        self.call_before("Page.stopScreencast", json!({}), Some(session_id), deadline).map(|_| ())
    }

    /// Capture the presented viewport only while the main frame remains
    /// attached to `loader_id`. The before/after checks make the returned
    /// pixels document authority instead of inferring identity from event
    /// arrival order.
    pub fn capture_main_frame_for_loader(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
    ) -> anyhow::Result<CapturedFrame> {
        self.capture_main_frame_for_loader_deadline(session_id, frame_id, loader_id, None)
    }

    pub fn capture_main_frame_for_loader_before(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        deadline: Instant,
    ) -> anyhow::Result<CapturedFrame> {
        self.capture_main_frame_for_loader_deadline(session_id, frame_id, loader_id, Some(deadline))
    }

    fn capture_main_frame_for_loader_deadline(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        deadline: Option<Instant>,
    ) -> anyhow::Result<CapturedFrame> {
        self.require_main_frame_loader(session_id, frame_id, loader_id, deadline)?;
        let params = json!({
            "format": "png",
            "fromSurface": true,
            "captureBeyondViewport": false,
        });
        let result = match deadline {
            Some(deadline) => {
                self.call_before("Page.captureScreenshot", params, Some(session_id), deadline)?
            }
            None => self.call("Page.captureScreenshot", params, Some(session_id))?,
        };
        self.require_main_frame_loader(session_id, frame_id, loader_id, deadline)?;
        let data_b64 = result
            .get("data")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow::anyhow!("Page.captureScreenshot response missing data"))?;
        let decoded_len = canonical_base64_decoded_len(data_b64)
            .ok_or_else(|| anyhow::anyhow!("Page.captureScreenshot returned invalid base64"))?;
        if data_b64.len() > MAX_ENCODED_FRAME_BYTES || decoded_len > MAX_DECODED_FRAME_BYTES {
            anyhow::bail!("Page.captureScreenshot returned an oversized frame");
        }
        let (css_width, css_height) = png_dimensions(data_b64)
            .ok_or_else(|| anyhow::anyhow!("Page.captureScreenshot returned an invalid PNG"))?;
        Ok(CapturedFrame { data_b64: data_b64.to_string(), css_width, css_height })
    }

    fn require_main_frame_loader(
        &self,
        session_id: &str,
        expected_frame_id: &str,
        expected_loader_id: &str,
        deadline: Option<Instant>,
    ) -> anyhow::Result<()> {
        let result = match deadline {
            Some(deadline) => {
                self.call_before("Page.getFrameTree", json!({}), Some(session_id), deadline)?
            }
            None => self.call("Page.getFrameTree", json!({}), Some(session_id))?,
        };
        let frame = result
            .get("frameTree")
            .and_then(|tree| tree.get("frame"))
            .ok_or_else(|| anyhow::anyhow!("Page.getFrameTree response missing root frame"))?;
        let frame_id = frame.get("id").and_then(Value::as_str).unwrap_or_default();
        let loader_id = frame.get("loaderId").and_then(Value::as_str).unwrap_or_default();
        if frame_id != expected_frame_id || loader_id != expected_loader_id {
            anyhow::bail!(
                "main document changed while authorizing captured pixels \
                 (expected frame {expected_frame_id} loader {expected_loader_id})"
            );
        }
        Ok(())
    }

    pub fn navigate(&self, session_id: &str, url: &str) -> anyhow::Result<NavigationResult> {
        let result = self.call("Page.navigate", json!({ "url": url }), Some(session_id))?;
        let error_text = result
            .get("errorText")
            .and_then(|value| value.as_str())
            .filter(|error| !error.is_empty())
            .map(ToOwned::to_owned);
        let is_download = result.get("isDownload").and_then(Value::as_bool).unwrap_or(false);
        let loader_id = result
            .get("loaderId")
            .and_then(Value::as_str)
            .filter(|loader_id| !loader_id.is_empty())
            .map(ToOwned::to_owned);
        Ok(NavigationResult { error_text, is_download, loader_id })
    }

    pub fn stop_loading(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.stopLoading", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn navigation_history(&self, session_id: &str) -> anyhow::Result<NavigationHistory> {
        let result = self.call("Page.getNavigationHistory", json!({}), Some(session_id))?;
        let current_index = result
            .get("currentIndex")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow::anyhow!("Page.getNavigationHistory missing currentIndex"))?
            as usize;
        let entries = result
            .get("entries")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow::anyhow!("Page.getNavigationHistory missing entries"))?
            .iter()
            .filter_map(|entry| {
                Some(NavigationEntry {
                    id: entry.get("id")?.as_u64()?,
                    url: entry.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
                    title: entry
                        .get("title")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string(),
                })
            })
            .collect();
        Ok(NavigationHistory { current_index, entries })
    }

    pub fn navigate_to_history_entry(&self, session_id: &str, entry_id: u64) -> anyhow::Result<()> {
        self.call("Page.navigateToHistoryEntry", json!({ "entryId": entry_id }), Some(session_id))
            .map(|_| ())
    }

    pub fn reload(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.reload", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn activate_target(&self, target_id: &str, session_id: &str) -> anyhow::Result<()> {
        self.call("Target.activateTarget", json!({ "targetId": target_id }), None)?;
        let _ = self.call("Page.bringToFront", json!({}), Some(session_id));
        Ok(())
    }

    pub fn handle_javascript_dialog(&self, session_id: &str, accept: bool) -> anyhow::Result<()> {
        self.call("Page.handleJavaScriptDialog", json!({ "accept": accept }), Some(session_id))
            .map(|_| ())
    }

    pub fn set_device_metrics(
        &self,
        session_id: &str,
        width: u32,
        height: u32,
    ) -> anyhow::Result<()> {
        self.call(
            "Emulation.setDeviceMetricsOverride",
            json!({
                "width": width.max(1),
                "height": height.max(1),
                "deviceScaleFactor": 1,
                "mobile": false,
            }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn dispatch_mouse_event(
        &self,
        session_id: &str,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        let mut params = json!({
            "type": event_type,
            "x": x,
            "y": y,
        });
        if let Some(button) = button {
            params["button"] = json!(button);
        }
        if let Some(click_count) = click_count {
            params["clickCount"] = json!(click_count);
        }
        self.call("Input.dispatchMouseEvent", params, Some(session_id)).map(|_| ())
    }

    pub fn dispatch_wheel(
        &self,
        session_id: &str,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
    ) -> anyhow::Result<()> {
        self.call(
            "Input.dispatchMouseEvent",
            wheel_event_params(x, y, delta_x, delta_y),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn dispatch_key_event(
        &self,
        session_id: &str,
        event: CdpKeyEvent<'_>,
    ) -> anyhow::Result<()> {
        self.call("Input.dispatchKeyEvent", key_event_params(event), Some(session_id)).map(|_| ())
    }

    pub fn insert_text(&self, session_id: &str, text: &str) -> anyhow::Result<()> {
        self.call("Input.insertText", json!({ "text": text }), Some(session_id)).map(|_| ())
    }

    fn send_value(&self, value: &Value) -> anyhow::Result<()> {
        if self.inner.closed.load(Ordering::Acquire) {
            anyhow::bail!("CDP connection is closed");
        }
        let text = serde_json::to_string(value)?;
        if cdp_debug() {
            eprintln!("cdp-> {text}");
        }
        reserve_outbound_bytes(&self.inner, text.len())?;
        if let Err(error) = self.inner.outbound.try_send(Outbound::Message(text)) {
            outbound_bytes_sub(&self.inner, outbound_bytes(&error));
            return Err(outbound_send_error(error));
        }
        Ok(())
    }
}

fn cdp_websocket_config() -> WebSocketConfig {
    WebSocketConfig::default().max_write_buffer_size(CDP_SOCKET_WRITE_BUFFER_MAX_BYTES)
}

fn outbound_bytes(error: &TrySendError<Outbound>) -> usize {
    match error {
        TrySendError::Full(Outbound::Message(text))
        | TrySendError::Disconnected(Outbound::Message(text)) => text.len(),
        _ => 0,
    }
}

fn outbound_send_error(error: TrySendError<Outbound>) -> anyhow::Error {
    match error {
        TrySendError::Full(_) => anyhow::anyhow!("CDP outbound queue is full"),
        TrySendError::Disconnected(_) => anyhow::anyhow!("CDP connection is closed"),
    }
}

fn reserve_outbound_bytes(inner: &Inner, bytes: usize) -> anyhow::Result<()> {
    let bytes = u64::try_from(bytes).unwrap_or(u64::MAX);
    loop {
        let current = inner.outbound_bytes.load(Ordering::Acquire);
        let next = current.checked_add(bytes).ok_or_else(outbound_byte_budget_error)?;
        if next > inner.outbound_byte_budget as u64 {
            return Err(outbound_byte_budget_error());
        }
        if inner
            .outbound_bytes
            .compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            return Ok(());
        }
    }
}

fn outbound_byte_budget_error() -> anyhow::Error {
    anyhow::anyhow!(CDP_OUTBOUND_QUEUE_BYTE_BUDGET_DETAIL)
        .context(CDP_CONNECTION_UNAVAILABLE_MESSAGE)
}

pub fn is_connection_unavailable(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| cause.to_string() == CDP_CONNECTION_UNAVAILABLE_MESSAGE)
}

fn outbound_bytes_sub(inner: &Inner, bytes: usize) {
    inner.outbound_bytes.fetch_sub(bytes as u64, Ordering::AcqRel);
}

pub fn resolve_browser_ws_url(input: &str) -> anyhow::Result<String> {
    let trimmed = input.trim();
    if trimmed.starts_with("ws://") {
        return Ok(trimmed.to_string());
    }
    if trimmed.starts_with("http://") {
        let endpoint = HttpEndpoint::parse(trimmed)?;
        return fetch_json_version(&endpoint.host, endpoint.port);
    }
    anyhow::bail!("CDP URL must start with ws:// or http://, got {input:?}")
}

pub fn discover_browser_ws_url(ports: &[u16]) -> Option<String> {
    ports.iter().find_map(|port| fetch_json_version("127.0.0.1", *port).ok())
}

fn reader_loop(
    weak: &Weak<Inner>,
    mut ws: WebSocket<TcpStream>,
    outbound: &Receiver<Outbound>,
    event_output: &SyncSender<CdpEvent>,
) {
    loop {
        let Some(inner) = weak.upgrade() else { break };
        if inner.events.drain_into(event_output).is_err() {
            close_inner(&inner, CdpCloseReason::EventReceiverClosed);
            break;
        }
        if inner.closed.load(Ordering::Acquire) {
            break;
        }
        if let Err(err) = drain_outbound(&inner, &mut ws, outbound) {
            close_inner_with_detail(&inner, CdpCloseReason::TransportFailure, err);
            break;
        }
        let message = ws.read();
        match message {
            Ok(Message::Text(text)) => handle_text(&inner, &text),
            Ok(Message::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    handle_text(&inner, &text);
                }
            }
            Ok(Message::Close(_)) => {
                close_inner(&inner, CdpCloseReason::SocketClosed);
                let _ = inner.events.drain_into(event_output);
                break;
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) | Ok(Message::Frame(_)) => {}
            Err(WsError::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(e) => {
                close_inner_with_detail(&inner, CdpCloseReason::TransportFailure, e);
                let _ = inner.events.drain_into(event_output);
                break;
            }
        }
    }
}

trait OutboundWriter {
    fn send_text(&mut self, text: String) -> anyhow::Result<()>;
}

impl OutboundWriter for WebSocket<TcpStream> {
    fn send_text(&mut self, text: String) -> anyhow::Result<()> {
        self.send(Message::Text(text.into()))?;
        Ok(())
    }
}

fn drain_outbound<W: OutboundWriter>(
    inner: &Arc<Inner>,
    ws: &mut W,
    outbound: &Receiver<Outbound>,
) -> anyhow::Result<()> {
    loop {
        match outbound.try_recv() {
            Ok(Outbound::Message(text)) => {
                let bytes = text.len();
                // Keep the reservation while the socket write is in progress.
                // Release it only after the write returns, including errors.
                match ws.send_text(text) {
                    Ok(()) => outbound_bytes_sub(inner, bytes),
                    Err(error) => {
                        outbound_bytes_sub(inner, bytes);
                        return Err(error);
                    }
                }
            }
            Ok(Outbound::Flush(done)) => {
                let _ = done.send(());
            }
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => return Ok(()),
        }
    }
}

fn handle_text(inner: &Arc<Inner>, text: &str) {
    if cdp_debug() {
        eprintln!("cdp<- {}", &text[..text.len().min(300)]);
    }
    let Ok(value) = serde_json::from_str::<Value>(text) else { return };
    if let Some(id) = value.get("id").and_then(|v| v.as_u64()) {
        if let Some(pending) = inner.pending.lock().unwrap().remove(&id) {
            let response = if let Some(error) = value.get("error") {
                Err(error.to_string())
            } else {
                Ok(value.get("result").cloned().unwrap_or(Value::Null))
            };
            if response.is_ok()
                && let Some(frame_barrier) = pending.frame_barrier
            {
                frame_barrier.advance();
            }
            let _ = pending.response.send(response);
        }
        return;
    }

    let Some(method) = value.get("method").and_then(|v| v.as_str()) else { return };
    let params = value.get("params").unwrap_or(&Value::Null);
    let session_id = value.get("sessionId").and_then(|v| v.as_str()).map(str::to_string);
    match method {
        "Page.screencastFrame" => {
            if let Some(target_session) = session_id.as_deref() {
                let Some(ack_id) = params.get("sessionId").and_then(|value| value.as_u64()) else {
                    return;
                };
                ack_screencast_frame(inner, target_session, ack_id, |message| {
                    eprintln!("{message}");
                });
                let (
                    frame_epoch,
                    navigation_epoch,
                    screencast_barrier,
                    suppressed_timestampless_epoch,
                ) = inner.frame_epochs.lock().unwrap().get(target_session).map_or(
                    (0, 0, None, None),
                    |frame_session| {
                        (
                            frame_session.epoch.current(),
                            frame_session.epoch.latest_navigation(),
                            frame_session.screencast_barrier,
                            frame_session.suppressed_timestampless_epoch,
                        )
                    },
                );
                let capture_timestamp = params
                    .get("metadata")
                    .and_then(|metadata| metadata.get("timestamp"))
                    .and_then(Value::as_f64)
                    .filter(|value| value.is_finite());
                if let Some(ScreencastBarrier::Timestamp(minimum_timestamp)) = screencast_barrier
                    && capture_timestamp.is_some_and(|timestamp| timestamp < minimum_timestamp)
                {
                    return;
                }
                let needs_loader_verified_capture =
                    matches!(screencast_barrier, Some(ScreencastBarrier::LoaderVerifiedCapture))
                        || matches!(screencast_barrier, Some(ScreencastBarrier::Timestamp(_)))
                            && capture_timestamp.is_none();
                if needs_loader_verified_capture {
                    if suppressed_timestampless_epoch == Some(frame_epoch) {
                        return;
                    }
                    let mut frame_sessions = inner.frame_epochs.lock().unwrap();
                    let Some(frame_session) = frame_sessions.get_mut(target_session) else {
                        return;
                    };
                    let now = Instant::now();
                    if frame_session.epoch.current() != frame_epoch
                        || frame_session.epoch.latest_navigation() != navigation_epoch
                        || frame_session.suppressed_timestampless_epoch == Some(frame_epoch)
                        || frame_session.pending_timestampless_capture.is_some_and(|pending| {
                            pending.frame_epoch == frame_epoch
                                && pending.navigation_epoch == navigation_epoch
                        })
                        || frame_session.timestampless_capture_throttle.is_some_and(|throttle| {
                            throttle.frame_epoch == frame_epoch
                                && throttle.navigation_epoch == navigation_epoch
                                && now < throttle.retry_at
                        })
                    {
                        return;
                    }
                    let (Some(frame_id), Some(loader_id)) =
                        (frame_session.main_frame_id.clone(), frame_session.main_loader_id.clone())
                    else {
                        return;
                    };
                    let request_id =
                        inner.next_screencast_capture_request_id.fetch_add(1, Ordering::Relaxed);
                    frame_session.pending_timestampless_capture =
                        Some(PendingTimestamplessCapture {
                            request_id,
                            frame_epoch,
                            navigation_epoch,
                        });
                    frame_session.timestampless_capture_throttle =
                        Some(TimestamplessCaptureThrottle {
                            frame_epoch,
                            navigation_epoch,
                            retry_at: now + TIMESTAMPLESS_CAPTURE_INTERVAL,
                        });
                    drop(frame_sessions);
                    dispatch_event(
                        inner,
                        CdpEvent::ScreencastFrameCaptureRequested {
                            session_id: target_session.to_string(),
                            frame_id,
                            loader_id,
                            request_id,
                            frame_epoch,
                            navigation_epoch,
                        },
                    );
                    return;
                }
                let Some(frame) = screencast_frame(params, target_session, frame_epoch) else {
                    return;
                };
                if capture_timestamp.is_some()
                    && let Some(frame_session) =
                        inner.frame_epochs.lock().unwrap().get_mut(target_session)
                    && frame_session.epoch.current() == frame_epoch
                {
                    // A timestamped post-barrier frame can reopen bounded
                    // loader verification without granting authority to any
                    // later timestamp-less pixels.
                    frame_session.pending_timestampless_capture = None;
                    frame_session.timestampless_capture_throttle = None;
                    frame_session.suppressed_timestampless_epoch = None;
                }
                dispatch_event(inner, CdpEvent::ScreencastFrame(frame));
            }
        }
        "Target.targetCreated" => {
            if let Some(created) = target_created(params) {
                dispatch_event(inner, CdpEvent::TargetCreated(created));
            }
        }
        "Target.targetInfoChanged" => {
            if let Some(info) = target_info(params, session_id.as_deref()) {
                dispatch_event(inner, CdpEvent::TargetInfoChanged(info));
            }
        }
        "Page.frameNavigated" if session_id.is_some() => {
            let session_id = session_id.expect("guarded above");
            if let Some((frame_epoch, restored_document)) =
                main_frame_navigation_epoch(inner, params, &session_id)
            {
                dispatch_event(
                    inner,
                    CdpEvent::FrameNavigated {
                        params: params.clone(),
                        session_id: session_id.clone(),
                        frame_epoch,
                    },
                );
                if let Some(restored_document) = restored_document {
                    dispatch_event(inner, restored_document);
                }
            }
        }
        "Page.lifecycleEvent" if session_id.is_some() => {
            let session_id = session_id.expect("guarded above");
            if let Some(event) = main_frame_document_paint(inner, params, &session_id) {
                dispatch_event(inner, event);
            }
        }
        "Page.navigatedWithinDocument" if session_id.is_some() => {
            let session_id = session_id.expect("guarded above");
            if let Some(event) =
                main_frame_same_document_navigation(inner, params.clone(), session_id)
            {
                dispatch_event(inner, event);
            }
        }
        _ => {
            dispatch_event(
                inner,
                CdpEvent::Other { method: method.to_string(), params: params.clone(), session_id },
            );
        }
    }
}

fn commit_main_frame_snapshot(
    inner: &Inner,
    session_id: &str,
    frame_epoch: &Arc<FrameEpoch>,
    observed_epoch: u64,
    frame_id: &str,
    loader_id: &str,
) -> bool {
    let mut frame_epochs = inner.frame_epochs.lock().unwrap();
    let Some(frame_session) = frame_epochs.get_mut(session_id) else {
        return false;
    };
    if !Arc::ptr_eq(&frame_session.epoch, frame_epoch)
        || frame_session.epoch.current() != observed_epoch
    {
        return false;
    }
    frame_session.main_frame_id = Some(frame_id.to_string());
    frame_session.main_loader_id = Some(loader_id.to_string());
    true
}

fn main_frame_navigation_epoch(
    inner: &Inner,
    params: &Value,
    session_id: &str,
) -> Option<(u64, Option<CdpEvent>)> {
    let mut frame_epochs = inner.frame_epochs.lock().unwrap();
    let frame_session = frame_epochs.get_mut(session_id)?;
    let frame = params.get("frame")?;
    if frame.get("parentId").is_some() {
        return None;
    }
    let frame_id = frame.get("id")?.as_str()?.to_string();
    let loader_id = frame.get("loaderId").and_then(Value::as_str).map(str::to_string);
    let navigation_epoch = frame_session.epoch.advance_navigation();
    frame_session.main_frame_id = Some(frame_id.clone());
    frame_session.main_loader_id = loader_id.clone();
    frame_session.pending_document =
        loader_id.map(|loader_id| PendingDocument { frame_id, loader_id, navigation_epoch });
    let restored_document =
        if params.get("type").and_then(Value::as_str) == Some("BackForwardCacheRestore") {
            frame_session
                .pending_document
                .as_ref()
                .map(|pending| pending_document_paint_event(pending, session_id))
        } else {
            None
        };
    Some((navigation_epoch, restored_document))
}

fn main_frame_document_paint(inner: &Inner, params: &Value, session_id: &str) -> Option<CdpEvent> {
    if !matches!(
        params.get("name").and_then(Value::as_str),
        Some("firstPaint" | "firstContentfulPaint" | "load")
    ) {
        return None;
    }
    let frame_id = params.get("frameId")?.as_str()?;
    let lifecycle_loader_id = params.get("loaderId").and_then(Value::as_str).unwrap_or_default();
    let frame_epochs = inner.frame_epochs.lock().unwrap();
    let pending = frame_epochs.get(session_id)?.pending_document.as_ref()?;
    if pending.frame_id != frame_id
        || !lifecycle_loader_id.is_empty() && pending.loader_id != lifecycle_loader_id
    {
        return None;
    }
    Some(pending_document_paint_event(pending, session_id))
}

fn pending_document_paint_event(pending: &PendingDocument, session_id: &str) -> CdpEvent {
    CdpEvent::DocumentPainted {
        session_id: session_id.to_string(),
        frame_id: pending.frame_id.clone(),
        loader_id: pending.loader_id.clone(),
        navigation_epoch: pending.navigation_epoch,
    }
}

fn main_frame_same_document_navigation(
    inner: &Inner,
    params: Value,
    session_id: String,
) -> Option<CdpEvent> {
    let frame_id = params.get("frameId")?.as_str()?.to_string();
    let frame_epochs = inner.frame_epochs.lock().unwrap();
    let frame_session = frame_epochs.get(&session_id)?;
    if frame_session.main_frame_id.as_deref() != Some(frame_id.as_str()) {
        return None;
    }
    let loader_id = frame_session.main_loader_id.clone()?;
    // Advance at CDP ingress, before the bounded event queue, so guarded
    // pointer input fails closed even if surface event handling is delayed.
    let frame_epoch = frame_session.epoch.advance_same_document();
    Some(CdpEvent::NavigatedWithinDocument { params, session_id, frame_id, loader_id, frame_epoch })
}

fn dispatch_event(inner: &Arc<Inner>, event: CdpEvent) {
    if inner.events.push(event).is_err() {
        close_inner(inner, CdpCloseReason::EventQueueOverflow);
    }
}

const CDP_ACK_REJECTED_DIAGNOSTIC: &str = "cmux-tui-cdp: screencast acknowledgment rejected";

fn ack_screencast_frame(
    inner: &Arc<Inner>,
    target_session: &str,
    frame_session: u64,
    report: impl FnOnce(&str),
) {
    let id = inner.next_id.fetch_add(1, Ordering::Relaxed);
    let msg = json!({
        "id": id,
        "method": "Page.screencastFrameAck",
        "sessionId": target_session,
        "params": { "sessionId": frame_session },
    });
    let Ok(text) = serde_json::to_string(&msg) else { return };
    if reserve_outbound_bytes(inner, text.len()).is_err() {
        // Keep queue and protocol details out of stderr. The close event
        // carries the stable recovery message to callers.
        report(CDP_ACK_REJECTED_DIAGNOSTIC);
        close_inner(inner, CdpCloseReason::OutboundQueueOverflow);
        return;
    }
    if let Err(error) = inner.outbound.try_send(Outbound::Message(text)) {
        outbound_bytes_sub(inner, outbound_bytes(&error));
        let reason = match error {
            TrySendError::Full(_) => CdpCloseReason::OutboundQueueOverflow,
            TrySendError::Disconnected(_) => CdpCloseReason::ConnectionClosed,
        };
        close_inner(inner, reason);
    }
}

fn screencast_frame(params: &Value, session_id: &str, frame_epoch: u64) -> Option<ScreencastFrame> {
    let supplied = params.get("data")?.as_str()?;
    if supplied.len() > MAX_ENCODED_FRAME_BYTES {
        return None;
    }
    if canonical_base64_decoded_len(supplied)? > MAX_DECODED_FRAME_BYTES {
        return None;
    }
    let ack_id = params.get("sessionId")?.as_u64()?;
    let metadata = params.get("metadata").unwrap_or(&Value::Null);
    let css_width = metadata
        .get("deviceWidth")
        .and_then(|v| v.as_u64())
        .or_else(|| metadata.get("width").and_then(|v| v.as_u64()))
        .and_then(|width| u32::try_from(width).ok())
        .unwrap_or(0);
    let css_height = metadata
        .get("deviceHeight")
        .and_then(|v| v.as_u64())
        .or_else(|| metadata.get("height").and_then(|v| v.as_u64()))
        .and_then(|height| u32::try_from(height).ok())
        .unwrap_or(0);
    let (image_width, image_height) = png_dimensions(supplied).unwrap_or((css_width, css_height));
    Some(ScreencastFrame {
        session_id: session_id.to_string(),
        data_b64: supplied.to_string(),
        css_width,
        css_height,
        image_width,
        image_height,
        ack_id,
        frame_epoch,
    })
}

fn png_dimensions(data_b64: &str) -> Option<(u32, u32)> {
    const PNG_HEADER_BYTES: usize = 24;
    const PNG_HEADER_BASE64_BYTES: usize = 32;
    const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

    let encoded_header = data_b64.get(..PNG_HEADER_BASE64_BYTES)?;
    let mut header = [0_u8; PNG_HEADER_BYTES];
    let decoded =
        base64::engine::general_purpose::STANDARD.decode_slice(encoded_header, &mut header).ok()?;
    if decoded != PNG_HEADER_BYTES
        || &header[..8] != PNG_SIGNATURE
        || header[8..12] != [0, 0, 0, 13]
        || &header[12..16] != b"IHDR"
    {
        return None;
    }
    let width = u32::from_be_bytes(header[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(header[20..24].try_into().ok()?);
    (width > 0 && height > 0).then_some((width, height))
}

fn canonical_base64_decoded_len(input: &str) -> Option<usize> {
    let bytes = input.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let padding = bytes.iter().rev().take_while(|byte| **byte == b'=').count();
    if padding > 2 {
        return None;
    }
    let data_len = bytes.len().checked_sub(padding)?;
    if !bytes[..data_len].iter().all(|byte| base64_value(*byte).is_some()) {
        return None;
    }
    if !bytes[data_len..].iter().all(|byte| *byte == b'=') {
        return None;
    }
    if padding == 1 && base64_value(*bytes.get(data_len.checked_sub(1)?)?)? & 0b11 != 0 {
        return None;
    }
    if padding == 2 && base64_value(*bytes.get(data_len.checked_sub(1)?)?)? & 0b1111 != 0 {
        return None;
    }
    bytes.len().checked_div(4)?.checked_mul(3)?.checked_sub(padding)
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn target_info(params: &Value, session_id: Option<&str>) -> Option<TargetInfo> {
    let info = params.get("targetInfo")?;
    Some(TargetInfo {
        session_id: session_id.map(str::to_string),
        target_id: info.get("targetId")?.as_str()?.to_string(),
        title: info.get("title").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        url: info.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
    })
}

fn target_created(params: &Value) -> Option<TargetCreated> {
    let info = params.get("targetInfo")?;
    Some(TargetCreated {
        target_id: info.get("targetId")?.as_str()?.to_string(),
        opener_id: info.get("openerId").and_then(|v| v.as_str()).map(str::to_string),
        target_type: info.get("type").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        title: info.get("title").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        url: info.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
    })
}

fn close_inner(inner: &Arc<Inner>, reason: CdpCloseReason) {
    if inner.closed.swap(true, Ordering::AcqRel) {
        return;
    }
    let message = reason.public_message();
    for (_, pending) in inner.pending.lock().unwrap().drain() {
        let _ = pending.response.send(Err(message.to_string()));
    }
    inner.events.close(reason);
}

fn close_inner_with_detail<D: std::fmt::Display>(
    inner: &Arc<Inner>,
    reason: CdpCloseReason,
    _detail: D,
) {
    // Keep transport diagnostics out of the public error and event channels.
    // The detail is intentionally not formatted here because websocket
    // errors can contain endpoint URLs and server-provided text.
    close_inner(inner, reason);
}

struct WsEndpoint {
    host: String,
    port: u16,
}

struct HttpEndpoint {
    host: String,
    port: u16,
}

impl HttpEndpoint {
    fn parse(url: &str) -> anyhow::Result<Self> {
        let rest = url
            .strip_prefix("http://")
            .ok_or_else(|| anyhow::anyhow!("CDP discovery URL must be http://, got {url:?}"))?;
        let host_port = rest.split('/').next().unwrap_or(rest);
        let (host, port) = match host_port.rsplit_once(':') {
            Some((host, port)) => (host, port.parse::<u16>()?),
            None => (host_port, 80),
        };
        Ok(HttpEndpoint { host: host.trim_matches(['[', ']']).to_string(), port })
    }
}

fn fetch_json_version(host: &str, port: u16) -> anyhow::Result<String> {
    let mut addrs = (host, port).to_socket_addrs()?;
    let addr =
        addrs.next().ok_or_else(|| anyhow::anyhow!("no socket address for {host}:{port}"))?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(250))?;
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    write!(
        stream,
        "GET /json/version HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n"
    )?;
    stream.flush()?;
    let response = read_http_response(&mut stream)?;
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, body)| body)
        .ok_or_else(|| anyhow::anyhow!("bad /json/version response from {host}:{port}"))?;
    let value: Value = serde_json::from_str(body)?;
    value
        .get("webSocketDebuggerUrl")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("/json/version missing webSocketDebuggerUrl"))
}

fn read_http_response(stream: &mut TcpStream) -> anyhow::Result<String> {
    read_http_response_with_limits(stream, 64 * 1024, Duration::from_secs(2))
}

fn read_http_response_with_limits(
    stream: &mut TcpStream,
    max_bytes: usize,
    timeout: Duration,
) -> anyhow::Result<String> {
    let deadline = Instant::now() + timeout;
    let mut bytes = Vec::new();
    let mut buf = [0u8; 1024];
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| anyhow::anyhow!("CDP discovery deadline exceeded"))?;
        stream.set_read_timeout(Some(remaining.min(Duration::from_millis(500))))?;
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let new_len = bytes
                    .len()
                    .checked_add(n)
                    .ok_or_else(|| anyhow::anyhow!("CDP discovery response size overflow"))?;
                if new_len > max_bytes {
                    anyhow::bail!("CDP discovery response exceeds size limit");
                }
                bytes.extend_from_slice(&buf[..n]);
                if complete_http_response(&bytes, max_bytes)? {
                    break;
                }
            }
            Err(e) if !bytes.is_empty() && e.kind() == std::io::ErrorKind::ConnectionReset => {
                break;
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if Instant::now() >= deadline {
                    anyhow::bail!("CDP discovery deadline exceeded");
                }
                continue;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(String::from_utf8(bytes)?)
}

fn complete_http_response(bytes: &[u8], max_bytes: usize) -> anyhow::Result<bool> {
    let Some(header_end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") else {
        return Ok(false);
    };
    let headers = String::from_utf8_lossy(&bytes[..header_end]);
    let Some(content_len) = headers.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().ok())?
    }) else {
        return Ok(false);
    };
    if content_len > max_bytes {
        anyhow::bail!("CDP discovery response exceeds size limit");
    }
    let expected_len = header_end
        .checked_add(4)
        .and_then(|length| length.checked_add(content_len))
        .ok_or_else(|| anyhow::anyhow!("CDP discovery response size overflow"))?;
    if expected_len > max_bytes {
        anyhow::bail!("CDP discovery response exceeds size limit");
    }
    Ok(bytes.len() >= expected_len)
}

impl WsEndpoint {
    fn parse(url: &str) -> anyhow::Result<Self> {
        let rest = url.strip_prefix("ws://").ok_or_else(|| {
            anyhow::anyhow!("CDP endpoint must be an unencrypted ws:// URL, got {url:?}")
        })?;
        let host_port = rest.split('/').next().unwrap_or(rest);
        let (host, port) = match host_port.rsplit_once(':') {
            Some((host, port)) => (host, port.parse::<u16>()?),
            None => (host_port, 80),
        };
        Ok(WsEndpoint { host: host.trim_matches(['[', ']']).to_string(), port })
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::net::TcpListener;
    use std::sync::mpsc::sync_channel;
    use std::sync::{Arc, Barrier};
    use std::thread;
    use std::time::{Duration, Instant};

    use tungstenite::{Message, accept, accept_hdr};

    use super::*;

    fn test_inner() -> (Arc<Inner>, Receiver<Outbound>) {
        test_inner_with_limits(256, CDP_OUTBOUND_QUEUE_MAX_BYTES)
    }

    fn test_inner_with_capacity(capacity: usize) -> (Arc<Inner>, Receiver<Outbound>) {
        test_inner_with_limits(capacity, CDP_OUTBOUND_QUEUE_MAX_BYTES)
    }

    fn test_inner_with_limits(
        capacity: usize,
        outbound_byte_budget: usize,
    ) -> (Arc<Inner>, Receiver<Outbound>) {
        let (outbound, outbound_rx) = std::sync::mpsc::sync_channel(capacity);
        (
            Arc::new(Inner {
                outbound,
                outbound_bytes: AtomicU64::new(0),
                outbound_byte_budget,
                pending: Mutex::new(HashMap::new()),
                events: Arc::new(EventQueue::new()),
                frame_epochs: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
                next_screencast_capture_request_id: AtomicU64::new(1),
                closed: AtomicBool::new(false),
                timeout: Duration::from_secs(1),
                reader_stopped: Arc::new(AtomicBool::new(false)),
            }),
            outbound_rx,
        )
    }

    #[test]
    fn outbound_commands_fail_fast_at_the_byte_bound() {
        let (inner, _outbound_rx) = test_inner_with_limits(8, 16);
        let client = CdpClient { inner };

        let error = client.send_value(&json!({"payload": "0123456789"})).unwrap_err();
        let public = error.to_string();
        assert_eq!(public, "browser connection unavailable; retry the command");
        assert!(!public.contains("ws://"));
        assert!(!public.contains("CDP outbound queue byte budget exceeded"));
        assert!(format!("{error:#}").contains("CDP outbound queue byte budget exceeded"));
        assert!(is_connection_unavailable(&error));
    }

    #[test]
    fn websocket_write_buffer_is_bounded_to_the_outbound_budget() {
        let config = cdp_websocket_config();

        assert!(config.max_write_buffer_size < usize::MAX);
        assert!(config.max_write_buffer_size >= CDP_OUTBOUND_QUEUE_MAX_BYTES);
    }

    #[test]
    fn protocol_errors_are_not_classified_as_connection_failures() {
        let error = anyhow::anyhow!("browser failed: invalid target");
        assert!(!is_connection_unavailable(&error));
    }

    struct BlockingOutboundWriter {
        started: Arc<Barrier>,
        release: Arc<Barrier>,
    }

    impl OutboundWriter for BlockingOutboundWriter {
        fn send_text(&mut self, _text: String) -> anyhow::Result<()> {
            self.started.wait();
            self.release.wait();
            Ok(())
        }
    }

    #[test]
    fn outbound_bytes_remain_reserved_while_write_is_in_flight() {
        let value = json!({"payload": "0123456789"});
        let message_bytes = serde_json::to_string(&value).unwrap().len();
        let (inner, outbound_rx) = test_inner_with_limits(2, message_bytes);
        let client = CdpClient { inner: inner.clone() };
        client.send_value(&value).unwrap();

        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let writer = BlockingOutboundWriter { started: started.clone(), release: release.clone() };
        let drain_inner = inner.clone();
        let drain = thread::spawn(move || {
            let mut writer = writer;
            drain_outbound(&drain_inner, &mut writer, &outbound_rx).unwrap();
        });

        started.wait();
        let error = client.send_value(&value).unwrap_err();
        assert_eq!(error.to_string(), "browser connection unavailable; retry the command");
        assert!(format!("{error:#}").contains("CDP outbound queue byte budget exceeded"));
        release.wait();
        drain.join().unwrap();
    }

    #[test]
    fn screencast_ack_byte_budget_closure_hides_internal_reason() {
        let (inner, _outbound_rx) = test_inner_with_limits(1, 1);
        let mut diagnostics = Vec::new();
        ack_screencast_frame(&inner, "session-1", 7, |message| {
            diagnostics.push(message.to_string());
        });

        let (event_tx, event_rx) = sync_channel(1);
        inner.events.drain_into(&event_tx).unwrap();
        let CdpEvent::Closed(reason) = event_rx.recv().unwrap() else {
            panic!("expected a close event");
        };
        assert_eq!(reason, "browser connection unavailable; retry the command");
        assert!(!reason.contains("CDP"));
        assert_eq!(diagnostics, vec![CDP_ACK_REJECTED_DIAGNOSTIC.to_string()]);
        assert!(!diagnostics[0].contains("ws://"));
        assert!(!diagnostics[0].contains("queue byte budget"));
    }

    #[test]
    fn transport_close_does_not_publish_socket_details() {
        let (inner, _outbound_rx) = test_inner();
        let (response_tx, response_rx) = channel();
        inner.pending.lock().unwrap().insert(
            7,
            PendingCall { response: response_tx, frame_barrier: None },
        );

        close_inner_with_detail(
            &inner,
            CdpCloseReason::TransportFailure,
            "CDP socket error: ws://secret.example/devtools/browser/token",
        );

        assert_eq!(
            response_rx.recv().unwrap().unwrap_err(),
            CDP_CONNECTION_UNAVAILABLE_MESSAGE
        );
        let (event_tx, event_rx) = sync_channel(1);
        inner.events.drain_into(&event_tx).unwrap();
        let CdpEvent::Closed(reason) = event_rx.recv().unwrap() else {
            panic!("expected a close event");
        };
        assert_eq!(reason, CDP_CONNECTION_UNAVAILABLE_MESSAGE);
        assert!(!reason.contains("ws://"));
        assert!(!reason.contains("secret"));
    }

    #[test]
    fn outbound_commands_fail_fast_at_the_queue_bound() {
        let (inner, _outbound_rx) = test_inner_with_capacity(1);
        let client = CdpClient { inner };

        client.send_value(&json!({"id": 1})).unwrap();
        let error = client.send_value(&json!({"id": 2})).unwrap_err();
        assert!(error.to_string().contains("outbound queue is full"));
    }

    #[test]
    fn call_queue_overflow_removes_pending_call() {
        let (inner, _outbound_rx) = test_inner_with_capacity(0);
        let client = CdpClient { inner: inner.clone() };

        let error = client.call("Test.method", json!({}), None).unwrap_err();

        assert!(error.to_string().contains("outbound queue is full"));
        assert!(inner.pending.lock().unwrap().is_empty());
    }

    #[test]
    fn screencast_ack_queue_overflow_closes_the_connection() {
        let (inner, _outbound_rx) = test_inner_with_capacity(0);
        ack_screencast_frame(&inner, "session-1", 7, |_| {});
        assert!(inner.closed.load(Ordering::Acquire));
    }

    #[test]
    #[allow(clippy::result_large_err)]
    fn bearer_auth_is_sent_on_the_websocket_upgrade() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (header_tx, header_rx) = channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let _ws = accept_hdr(
                stream,
                |request: &tungstenite::handshake::server::Request, response| {
                    header_tx
                        .send(
                            request
                                .headers()
                                .get(AUTHORIZATION)
                                .and_then(|value| value.to_str().ok())
                                .map(str::to_string),
                        )
                        .unwrap();
                    Ok(response)
                },
            )
            .unwrap();
        });
        let (event_tx, _event_rx) = sync_channel(1);
        let _client = CdpClient::connect_with_bearer(
            &format!("ws://{addr}/devtools/browser/fake"),
            Some("test-secret"),
            event_tx,
        )
        .unwrap();
        assert_eq!(
            header_rx.recv_timeout(Duration::from_secs(1)).unwrap().as_deref(),
            Some("Bearer test-secret")
        );
        server.join().unwrap();
    }

    #[test]
    fn wheel_event_preserves_horizontal_and_vertical_deltas() {
        assert_eq!(
            wheel_event_params(12.5, 9.25, -3.75, 8.5),
            json!({
                "type": "mouseWheel",
                "x": 12.5,
                "y": 9.25,
                "deltaX": -3.75,
                "deltaY": 8.5,
            })
        );
    }

    #[test]
    fn key_event_params_omit_unavailable_physical_identity() {
        let params = key_event_params(CdpKeyEvent {
            event_type: "keyDown",
            key: "a",
            code: "",
            windows_virtual_key_code: 0,
            modifiers: 2,
            text: None,
        });

        assert_eq!(params["type"], "keyDown");
        assert_eq!(params["key"], "a");
        assert_eq!(params["modifiers"], 2);
        assert!(params.get("code").is_none());
        assert!(params.get("windowsVirtualKeyCode").is_none());
        assert!(params.get("nativeVirtualKeyCode").is_none());
    }

    #[test]
    fn screencast_frame_rejects_terminal_control_bytes() {
        let params = json!({
            "data": "AAAA\u{1b}_Ga=T,f=100;AAAA\u{1b}\\",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        assert!(screencast_frame(&params, "session-1", 0).is_none());
    }

    #[test]
    fn screencast_frame_preserves_valid_canonical_base64() {
        let params = json!({
            "data": "aGk=",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        let frame = screencast_frame(&params, "session-1", 0).unwrap();
        assert_eq!(frame.data_b64, "aGk=");
        assert_eq!((frame.image_width, frame.image_height), (80, 24));
    }

    #[test]
    fn screencast_frame_preserves_encoded_png_dimensions_separately_from_css_dimensions() {
        let params = json!({
            "data": "iVBORw0KGgoAAAANSUhEUgAAAAMAAAAC",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        let frame = screencast_frame(&params, "session-1", 0).unwrap();
        assert_eq!((frame.css_width, frame.css_height), (80, 24));
        assert_eq!((frame.image_width, frame.image_height), (3, 2));
    }

    #[test]
    fn screencast_frame_rejects_noncanonical_padding_bits() {
        let params = json!({
            "data": "aGl=",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        assert!(screencast_frame(&params, "session-1", 0).is_none());
    }

    #[test]
    fn json_queue_budget_charges_container_allocations() {
        let value = Value::Array(vec![Value::Null; 128]);
        assert!(
            json_retained_bytes(&value) >= 128 * size_of::<Value>(),
            "null container storage was not charged"
        );
    }

    #[test]
    fn backpressured_event_reuses_its_cached_retained_size() {
        RETAINED_SIZE_CALLS.store(0, Ordering::Relaxed);
        let queue = EventQueue::new();
        queue
            .push(CdpEvent::Other {
                method: "Test.large".to_string(),
                params: json!({"payload": "x".repeat(1024 * 1024)}),
                session_id: Some("session-1".to_string()),
            })
            .unwrap();
        let (event_tx, _event_rx) = sync_channel(0);

        queue.drain_into(&event_tx).unwrap();
        let calls_after_first_retry = RETAINED_SIZE_CALLS.load(Ordering::Relaxed);
        queue.drain_into(&event_tx).unwrap();

        assert_eq!(
            RETAINED_SIZE_CALLS.load(Ordering::Relaxed),
            calls_after_first_retry,
            "retry rescanned the retained JSON event"
        );
    }

    #[test]
    fn coalesced_event_keeps_chronological_order() {
        let queue = EventQueue::new();
        let target = |title: &str| {
            CdpEvent::TargetInfoChanged(TargetInfo {
                session_id: Some("session-1".to_string()),
                target_id: "target-1".to_string(),
                title: title.to_string(),
                url: "https://example.test".to_string(),
            })
        };
        queue.push(target("old")).unwrap();
        queue
            .push(CdpEvent::Other {
                method: "Page.frameNavigated".to_string(),
                params: Value::Null,
                session_id: Some("session-1".to_string()),
            })
            .unwrap();
        queue.push(target("new")).unwrap();
        let (event_tx, event_rx) = sync_channel(2);

        queue.drain_into(&event_tx).unwrap();

        assert!(matches!(event_rx.recv().unwrap(), CdpEvent::Other { .. }));
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::TargetInfoChanged(TargetInfo { title, .. }) if title == "new"
        ));
    }

    #[test]
    fn rejected_screencast_frame_is_acknowledged() {
        let (inner, outbound_rx) = test_inner();
        handle_text(
            &inner,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "not base64",
                    "sessionId": 77,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 24}
                }
            })
            .to_string(),
        );

        let Outbound::Message(ack) = outbound_rx.try_recv().expect("rejected frame ack") else {
            panic!("expected a CDP message");
        };
        let ack: Value = serde_json::from_str(&ack).unwrap();
        assert_eq!(ack["method"], "Page.screencastFrameAck");
        assert_eq!(ack["params"]["sessionId"], 77);
    }

    #[test]
    fn frame_navigation_advances_epoch_before_following_frame_enters_the_queue() {
        let (inner, _outbound_rx) = test_inner();
        let frame_epoch = Arc::new(FrameEpoch::default());
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: frame_epoch.clone(),
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                screencast_barrier: None,
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );

        handle_text(
            &inner,
            &json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "frame-1",
                        "loaderId": "loader-1",
                        "url": "https://example.test"
                    }
                }
            })
            .to_string(),
        );
        handle_text(
            &inner,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AAAA",
                    "sessionId": 8,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 24}
                }
            })
            .to_string(),
        );
        handle_text(
            &inner,
            &json!({
                "method": "Page.lifecycleEvent",
                "sessionId": "session-1",
                "params": {
                    "frameId": "frame-1",
                    "loaderId": "loader-1",
                    "name": "firstPaint",
                    "timestamp": 1.0
                }
            })
            .to_string(),
        );

        let (event_tx, event_rx) = sync_channel(3);
        inner.events.drain_into(&event_tx).unwrap();
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::FrameNavigated { frame_epoch: 1, .. }
        ));
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::ScreencastFrame(ScreencastFrame { frame_epoch: 1, .. })
        ));
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::DocumentPainted {
                frame_id,
                loader_id,
                navigation_epoch: 1,
                ..
            } if frame_id == "frame-1" && loader_id == "loader-1"
        ));
        assert_eq!(frame_epoch.current(), 1);
    }

    #[test]
    fn stale_frame_tree_snapshot_cannot_overwrite_newer_navigation() {
        let (inner, _outbound_rx) = test_inner();
        let frame_epoch = Arc::new(FrameEpoch::default());
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: frame_epoch.clone(),
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                screencast_barrier: None,
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );
        let observed_epoch = frame_epoch.current();

        handle_text(
            &inner,
            &json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "new-frame",
                        "loaderId": "new-loader",
                        "url": "https://new.example.test"
                    }
                }
            })
            .to_string(),
        );

        assert!(!commit_main_frame_snapshot(
            &inner,
            "session-1",
            &frame_epoch,
            observed_epoch,
            "stale-frame",
            "stale-loader",
        ));
        let frame_sessions = inner.frame_epochs.lock().unwrap();
        let frame_session = frame_sessions.get("session-1").unwrap();
        assert_eq!(frame_session.main_frame_id.as_deref(), Some("new-frame"));
        assert_eq!(frame_session.main_loader_id.as_deref(), Some("new-loader"));
    }

    #[test]
    fn snapshot_main_frame_rejects_values_invalidated_by_navigation() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (respond_tx, respond_rx) = channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = loop {
                match ws.read().unwrap() {
                    Message::Text(text) => break serde_json::from_str::<Value>(&text).unwrap(),
                    Message::Binary(bytes) => {
                        break serde_json::from_slice::<Value>(&bytes).unwrap();
                    }
                    _ => {}
                }
            };
            assert_eq!(request["method"], "Page.getFrameTree");
            ws.send(Message::Text(
                json!({
                    "method": "Page.frameNavigated",
                    "sessionId": "session-1",
                    "params": {
                        "frame": {
                            "id": "new-frame",
                            "loaderId": "new-loader",
                            "url": "https://new.example.test"
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            respond_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            ws.send(Message::Text(
                json!({
                    "id": request["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "stale-frame",
                                "loaderId": "stale-loader",
                                "url": "https://stale.example.test"
                            }
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
        });
        let (event_tx, event_rx) = sync_channel(1);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        let frame_epoch = Arc::new(FrameEpoch::default());
        client.register_frame_epoch("session-1", frame_epoch.clone());
        let snapshot_client = client.clone();
        let snapshot = thread::spawn(move || snapshot_client.snapshot_main_frame("session-1"));

        assert!(matches!(
            event_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            CdpEvent::FrameNavigated { frame_epoch: 1, .. }
        ));
        assert_eq!(frame_epoch.current(), 1);
        respond_tx.send(()).unwrap();
        let result = snapshot.join().unwrap();
        assert!(
            result.is_err(),
            "a frame-tree response invalidated by navigation returned stale authority: {result:?}"
        );

        drop(client);
        server.join().unwrap();
    }

    #[test]
    fn seed_main_frame_retries_snapshot_invalidated_by_navigation() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let mut ws = accept(stream).unwrap();
            let first = loop {
                match ws.read().unwrap() {
                    Message::Text(text) => break serde_json::from_str::<Value>(&text).unwrap(),
                    Message::Binary(bytes) => {
                        break serde_json::from_slice::<Value>(&bytes).unwrap();
                    }
                    _ => {}
                }
            };
            assert_eq!(first["method"], "Page.getFrameTree");
            ws.send(Message::Text(
                json!({
                    "method": "Page.frameNavigated",
                    "sessionId": "session-1",
                    "params": {
                        "frame": {
                            "id": "new-frame",
                            "loaderId": "new-loader",
                            "url": "https://new.example.test"
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            ws.send(Message::Text(
                json!({
                    "id": first["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "stale-frame",
                                "loaderId": "stale-loader",
                                "url": "https://stale.example.test"
                            }
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();

            let retry = loop {
                match ws.read() {
                    Ok(Message::Text(text)) => {
                        break Some(serde_json::from_str::<Value>(&text).unwrap());
                    }
                    Ok(Message::Binary(bytes)) => {
                        break Some(serde_json::from_slice::<Value>(&bytes).unwrap());
                    }
                    Ok(_) => {}
                    Err(tungstenite::Error::Io(error))
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        break None;
                    }
                    Err(_) => break None,
                }
            };
            let Some(retry) = retry else { return false };
            assert_eq!(retry["method"], "Page.getFrameTree");
            ws.send(Message::Text(
                json!({
                    "id": retry["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "new-frame",
                                "loaderId": "new-loader",
                                "url": "https://new.example.test"
                            }
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            true
        });
        let (event_tx, _event_rx) = sync_channel(2);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));

        let result = client.seed_main_frame("session-1");

        drop(client);
        let retried = server.join().unwrap();
        assert!(
            result.is_ok(),
            "bootstrap rejected a snapshot invalidated by normal navigation: {result:?}"
        );
        assert!(retried, "bootstrap did not request a fresh post-navigation snapshot");
    }

    #[test]
    fn replayed_load_lifecycle_reconciles_pending_document_authority() {
        let (inner, _outbound_rx) = test_inner();
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: Arc::new(FrameEpoch::default()),
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                screencast_barrier: None,
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );

        handle_text(
            &inner,
            &json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "frame-1",
                        "loaderId": "loader-1",
                        "url": "https://example.test"
                    }
                }
            })
            .to_string(),
        );
        handle_text(
            &inner,
            &json!({
                "method": "Page.lifecycleEvent",
                "sessionId": "session-1",
                "params": {
                    "frameId": "frame-1",
                    "loaderId": "loader-1",
                    "name": "load",
                    "timestamp": 1.0
                }
            })
            .to_string(),
        );

        let (event_tx, event_rx) = sync_channel(2);
        inner.events.drain_into(&event_tx).unwrap();
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::FrameNavigated { frame_epoch: 1, .. }
        ));
        assert!(matches!(
            event_rx.recv_timeout(Duration::from_millis(100)).unwrap(),
            CdpEvent::DocumentPainted {
                frame_id,
                loader_id,
                navigation_epoch: 1,
                ..
            } if frame_id == "frame-1" && loader_id == "loader-1"
        ));
    }

    #[test]
    fn back_forward_cache_restore_requests_document_capture_without_new_paint() {
        let (inner, _outbound_rx) = test_inner();
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: Arc::new(FrameEpoch::default()),
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                screencast_barrier: None,
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );

        handle_text(
            &inner,
            &json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "type": "BackForwardCacheRestore",
                    "frame": {
                        "id": "main-frame",
                        "loaderId": "restored-loader",
                        "url": "https://example.test/restored"
                    }
                }
            })
            .to_string(),
        );

        let (event_tx, event_rx) = sync_channel(2);
        inner.events.drain_into(&event_tx).unwrap();
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::FrameNavigated { frame_epoch: 1, .. }
        ));
        assert!(matches!(
            event_rx.recv_timeout(Duration::from_millis(100)).unwrap(),
            CdpEvent::DocumentPainted {
                frame_id,
                loader_id,
                navigation_epoch: 1,
                ..
            } if frame_id == "main-frame" && loader_id == "restored-loader"
        ));
    }

    #[test]
    fn same_document_navigation_advances_only_the_main_frame_epoch() {
        let (inner, _outbound_rx) = test_inner();
        let frame_epoch = Arc::new(FrameEpoch::default());
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: frame_epoch.clone(),
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                screencast_barrier: None,
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );
        handle_text(
            &inner,
            &json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "main-frame",
                        "loaderId": "loader-1",
                        "url": "https://example.test"
                    }
                }
            })
            .to_string(),
        );
        assert_eq!(frame_epoch.current(), 1);

        handle_text(
            &inner,
            &json!({
                "method": "Page.navigatedWithinDocument",
                "sessionId": "session-1",
                "params": {"frameId": "child-frame", "url": "https://iframe.test/#next"}
            })
            .to_string(),
        );

        assert_eq!(
            frame_epoch.current(),
            1,
            "an iframe navigation must not advance top-level pointer authority"
        );
        assert_eq!(frame_epoch.pointer_motion_generation(), 0);

        handle_text(
            &inner,
            &json!({
                "method": "Page.navigatedWithinDocument",
                "sessionId": "session-1",
                "params": {"frameId": "main-frame", "url": "https://example.test/#next"}
            })
            .to_string(),
        );
        assert_eq!(
            frame_epoch.current(),
            2,
            "a top-level same-document navigation must invalidate stale bitmap pointer authority"
        );
        assert_eq!(
            frame_epoch.pointer_motion_generation(),
            2,
            "captured motion must be blocked at ingress before surface event handling"
        );
        let (event_tx, event_rx) = sync_channel(2);
        inner.events.drain_into(&event_tx).unwrap();
        assert!(matches!(event_rx.recv().unwrap(), CdpEvent::FrameNavigated { .. }));
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::NavigatedWithinDocument {
                frame_id,
                loader_id,
                frame_epoch: 2,
                ..
            } if frame_id == "main-frame" && loader_id == "loader-1"
        ));
    }

    #[test]
    fn screenshot_authority_is_bracketed_by_the_committed_loader() {
        const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            for post_loader in ["loader-1", "loader-2"] {
                for expected in ["Page.getFrameTree", "Page.captureScreenshot", "Page.getFrameTree"]
                {
                    let request = loop {
                        match ws.read().unwrap() {
                            Message::Text(text) => {
                                break serde_json::from_str::<Value>(&text).unwrap();
                            }
                            Message::Binary(bytes) => {
                                break serde_json::from_slice::<Value>(&bytes).unwrap();
                            }
                            _ => {}
                        }
                    };
                    assert_eq!(request["method"], expected);
                    let result = match expected {
                        "Page.getFrameTree" => {
                            let loader_id = if request["id"].as_u64().unwrap().is_multiple_of(3) {
                                post_loader
                            } else {
                                "loader-1"
                            };
                            json!({
                                "frameTree": {
                                    "frame": {
                                        "id": "main-frame",
                                        "loaderId": loader_id,
                                        "url": "https://example.test"
                                    }
                                }
                            })
                        }
                        "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                        _ => unreachable!(),
                    };
                    ws.send(Message::Text(
                        json!({"id": request["id"], "result": result}).to_string().into(),
                    ))
                    .unwrap();
                }
            }
        });
        let (event_tx, _event_rx) = sync_channel(1);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();

        let frame =
            client.capture_main_frame_for_loader("session-1", "main-frame", "loader-1").unwrap();
        assert_eq!((frame.css_width, frame.css_height), (1, 1));
        let error = client
            .capture_main_frame_for_loader("session-1", "main-frame", "loader-1")
            .unwrap_err();
        assert!(error.to_string().contains("main document changed"), "{error:#}");

        drop(client);
        server.join().unwrap();
    }

    #[test]
    fn missing_optional_screencast_timestamp_requests_safe_capture_before_parsing_png() {
        let (inner, _outbound_rx) = test_inner();
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: Arc::new(FrameEpoch::default()),
                main_frame_id: Some("main-frame".to_string()),
                main_loader_id: Some("loader-1".to_string()),
                pending_document: None,
                screencast_barrier: Some(ScreencastBarrier::Timestamp(1.0)),
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );

        handle_text(
            &inner,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "not-base64",
                    "sessionId": 7,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 24}
                }
            })
            .to_string(),
        );

        let (event_tx, event_rx) = sync_channel(1);
        inner.events.drain_into(&event_tx).unwrap();
        let recovery = event_rx
            .try_recv()
            .expect("a timestamp-less frame must request a loader-verified replacement");
        assert!(matches!(
            recovery,
            CdpEvent::ScreencastFrameCaptureRequested {
                session_id,
                frame_id,
                loader_id,
                request_id: _,
                frame_epoch: 0,
                navigation_epoch: 0,
            } if session_id == "session-1"
                && frame_id == "main-frame"
                && loader_id == "loader-1"
        ));
    }

    #[test]
    fn timestamped_frame_proof_is_not_reused_for_later_timestampless_pixels() {
        let (inner, _outbound_rx) = test_inner();
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: Arc::new(FrameEpoch::default()),
                main_frame_id: Some("main-frame".to_string()),
                main_loader_id: Some("loader-1".to_string()),
                pending_document: None,
                screencast_barrier: Some(ScreencastBarrier::Timestamp(1.0)),
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );

        handle_text(
            &inner,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AAAA",
                    "sessionId": 7,
                    "metadata": {
                        "deviceWidth": 80,
                        "deviceHeight": 24,
                        "timestamp": 2.0
                    }
                }
            })
            .to_string(),
        );
        handle_text(
            &inner,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "BBBB",
                    "sessionId": 8,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 24}
                }
            })
            .to_string(),
        );

        let (event_tx, event_rx) = sync_channel(2);
        inner.events.drain_into(&event_tx).unwrap();
        let events = event_rx.try_iter().collect::<Vec<_>>();
        assert!(
            matches!(
                events.as_slice(),
                [
                    CdpEvent::ScreencastFrame(ScreencastFrame { ack_id: 7, .. }),
                    CdpEvent::ScreencastFrameCaptureRequested {
                        session_id,
                        frame_id,
                        loader_id,
                        request_id: _,
                        frame_epoch: 0,
                        navigation_epoch: 0,
                    },
                ] if session_id == "session-1"
                    && frame_id == "main-frame"
                    && loader_id == "loader-1"
            ),
            "proof for one timestamped frame authorized unrelated pixels: {events:?}"
        );
    }

    #[test]
    fn settled_timestampless_capture_does_not_recapture_the_next_frame() {
        let (inner, _outbound_rx) = test_inner();
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: Arc::new(FrameEpoch::default()),
                main_frame_id: Some("main-frame".to_string()),
                main_loader_id: Some("loader-1".to_string()),
                pending_document: None,
                screencast_barrier: Some(ScreencastBarrier::Timestamp(1.0)),
                pending_timestampless_capture: None,
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );
        let client = CdpClient { inner: inner.clone() };
        let missing_frame = |ack_id| {
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AAAA",
                    "sessionId": ack_id,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 24}
                }
            })
            .to_string()
        };

        handle_text(&inner, &missing_frame(7));
        let (event_tx, event_rx) = sync_channel(1);
        inner.events.drain_into(&event_tx).unwrap();
        let CdpEvent::ScreencastFrameCaptureRequested {
            request_id,
            frame_epoch,
            navigation_epoch,
            ..
        } = event_rx.try_recv().expect("first bounded recovery")
        else {
            panic!("timestamp-less frame did not request bounded recovery");
        };
        assert!(client.settle_timestampless_screencast_capture(
            "session-1",
            request_id,
            frame_epoch,
            navigation_epoch,
        ));

        handle_text(&inner, &missing_frame(8));
        inner.events.drain_into(&event_tx).unwrap();
        assert!(
            event_rx.try_recv().is_err(),
            "a continuous timestamp-less stream must not capture every incoming frame"
        );

        inner
            .frame_epochs
            .lock()
            .unwrap()
            .get_mut("session-1")
            .and_then(|session| session.timestampless_capture_throttle.as_mut())
            .expect("same-epoch recovery throttle")
            .retry_at = Instant::now();
        handle_text(&inner, &missing_frame(9));
        inner.events.drain_into(&event_tx).unwrap();
        assert!(
            matches!(event_rx.try_recv(), Ok(CdpEvent::ScreencastFrameCaptureRequested { .. })),
            "timestamp-less recovery must resume after its bounded interval"
        );
    }

    #[test]
    fn rejected_timestampless_epoch_stops_recovery_at_ingress() {
        let (inner, _outbound_rx) = test_inner();
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: Arc::new(FrameEpoch::default()),
                main_frame_id: Some("main-frame".to_string()),
                main_loader_id: Some("loader-1".to_string()),
                pending_document: None,
                screencast_barrier: Some(ScreencastBarrier::Timestamp(1.0)),
                pending_timestampless_capture: Some(PendingTimestamplessCapture {
                    request_id: 7,
                    frame_epoch: 0,
                    navigation_epoch: 0,
                }),
                timestampless_capture_throttle: None,
                suppressed_timestampless_epoch: None,
            },
        );
        let client = CdpClient { inner: inner.clone() };
        assert!(client.suppress_timestampless_screencast_capture("session-1", 7, 0, 0));

        handle_text(
            &inner,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AAAA",
                    "sessionId": 8,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 24}
                }
            })
            .to_string(),
        );

        let (event_tx, event_rx) = sync_channel(1);
        inner.events.drain_into(&event_tx).unwrap();
        assert!(
            event_rx.try_recv().is_err(),
            "a rejected epoch must not materialize or route another recovery request"
        );
    }

    #[test]
    fn successful_response_advances_frame_barrier_before_waking_caller() {
        let (inner, _outbound_rx) = test_inner();
        let frame_epoch = Arc::new(FrameEpoch::default());
        let (response, received) = channel();
        inner
            .pending
            .lock()
            .unwrap()
            .insert(7, PendingCall { response, frame_barrier: Some(frame_epoch.clone()) });

        handle_text(&inner, &json!({"id": 7, "result": {}}).to_string());

        assert!(received.recv().unwrap().is_ok());
        assert_eq!(frame_epoch.current(), 1);
    }

    #[test]
    fn screencast_restart_rejects_delayed_frame_captured_before_barrier() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            for expected in [
                "Page.stopScreencast",
                "Page.createIsolatedWorld",
                "Runtime.evaluate",
                "Page.startScreencast",
            ] {
                let request = ws.read().unwrap();
                let Message::Text(request) = request else { panic!("expected text request") };
                let request: Value = serde_json::from_str(&request).unwrap();
                assert_eq!(request["method"], expected);
                if expected == "Page.createIsolatedWorld" {
                    assert_eq!(request["params"]["frameId"], "main-frame");
                    assert_eq!(request["params"]["grantUniversalAccess"], false);
                    assert!(request["params"].get("grantUniveralAccess").is_none());
                } else if expected == "Runtime.evaluate" {
                    assert_eq!(request["params"]["contextId"], 41);
                    assert_eq!(request["params"]["expression"], "globalThis.Date.now()");
                }
                let result = match expected {
                    "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                    "Runtime.evaluate" => {
                        json!({"result": {"type": "number", "value": 10_000.0}})
                    }
                    _ => json!({}),
                };
                ws.send(Message::Text(
                    json!({"id": request["id"], "result": result}).to_string().into(),
                ))
                .unwrap();
            }
            ws.send(Message::Text(
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "AAAA",
                        "sessionId": 7,
                        "metadata": {
                            "deviceWidth": 80,
                            "deviceHeight": 24,
                            "timestamp": 10.0
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let ack = ws.read().unwrap();
            let Message::Text(ack) = ack else { panic!("expected text ack") };
            let ack: Value = serde_json::from_str(&ack).unwrap();
            assert_eq!(ack["method"], "Page.screencastFrameAck");
            ws.send(Message::Text(
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "AQ==",
                        "sessionId": 8,
                        "metadata": {
                            "deviceWidth": 80,
                            "deviceHeight": 24,
                            "timestamp": 10.002
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let ack = ws.read().unwrap();
            let Message::Text(ack) = ack else { panic!("expected text ack") };
            let ack: Value = serde_json::from_str(&ack).unwrap();
            assert_eq!(ack["method"], "Page.screencastFrameAck");
        });
        let (event_tx, event_rx) = sync_channel(2);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
        client.inner.frame_epochs.lock().unwrap().get_mut("session-1").unwrap().main_frame_id =
            Some("main-frame".to_string());

        client.stop_screencast("session-1").unwrap();
        client.start_screencast_with_frame_barrier("session-1", 80, 24).unwrap();

        let first = event_rx.recv_timeout(Duration::from_millis(200));
        assert!(
            matches!(
                first,
                Ok(CdpEvent::ScreencastFrame(ScreencastFrame {
                    ref data_b64,
                    frame_epoch: 1,
                    ..
                })) if data_b64 == "AQ=="
            ),
            "the Chrome-domain barrier did not reject the delayed capture and admit the new one: \
             {first:?}"
        );
        server.join().unwrap();
    }

    #[test]
    fn unavailable_screencast_clock_probe_requests_loader_verified_capture() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            ws.get_mut().set_read_timeout(Some(Duration::from_secs(1))).unwrap();

            let request = ws.read().unwrap();
            let Message::Text(request) = request else { panic!("expected text request") };
            let request: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], "Page.createIsolatedWorld");
            ws.send(Message::Text(
                json!({
                    "id": request["id"],
                    "error": {"message": "scripts unavailable"}
                })
                .to_string()
                .into(),
            ))
            .unwrap();

            let request = ws.read().unwrap();
            let Message::Text(request) = request else { panic!("expected text request") };
            let request: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], "Page.startScreencast");
            ws.send(Message::Text(json!({"id": request["id"], "result": {}}).to_string().into()))
                .unwrap();

            ws.send(Message::Text(
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "not-base64",
                        "sessionId": 7,
                        "metadata": {
                            "deviceWidth": 80,
                            "deviceHeight": 24,
                            "timestamp": 10.0
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let ack = ws.read().unwrap();
            let Message::Text(ack) = ack else { panic!("expected text ack") };
            let ack: Value = serde_json::from_str(&ack).unwrap();
            assert_eq!(ack["method"], "Page.screencastFrameAck");
        });
        let (event_tx, event_rx) = sync_channel(1);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
        {
            let mut frame_sessions = client.inner.frame_epochs.lock().unwrap();
            let frame_session = frame_sessions.get_mut("session-1").unwrap();
            frame_session.main_frame_id = Some("main-frame".to_string());
            frame_session.main_loader_id = Some("loader-1".to_string());
        }

        let result = client.start_screencast_with_frame_barrier("session-1", 80, 24);
        let event = result
            .as_ref()
            .ok()
            .and_then(|_| event_rx.recv_timeout(Duration::from_millis(200)).ok());

        drop(client);
        let server_result = server.join();
        assert!(
            result.is_ok(),
            "an unavailable optional clock probe must not prevent screencast restart: {result:?}"
        );
        server_result.unwrap();
        assert!(
            matches!(
                event,
                Some(CdpEvent::ScreencastFrameCaptureRequested {
                    ref session_id,
                    ref frame_id,
                    ref loader_id,
                    frame_epoch: 1,
                    navigation_epoch: 0,
                    ..
                }) if session_id == "session-1"
                    && frame_id == "main-frame"
                    && loader_id == "loader-1"
            ),
            "a streamed frame without a trustworthy cutoff bypassed loader verification: {event:?}"
        );
    }

    #[test]
    fn loader_verified_capture_recovers_timestamped_screencast_stream() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (recovered_tx, recovered_rx) = sync_channel(1);
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            ws.get_mut().set_read_timeout(Some(Duration::from_secs(1))).unwrap();

            for expected in ["Page.createIsolatedWorld", "Runtime.evaluate"] {
                let Ok(Message::Text(request)) = ws.read() else {
                    return false;
                };
                let request: Value = serde_json::from_str(&request).unwrap();
                assert_eq!(request["method"], expected);
                let result = match expected {
                    "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                    "Runtime.evaluate" => {
                        json!({"result": {"type": "number", "value": 10_000.0}})
                    }
                    _ => unreachable!(),
                };
                ws.send(Message::Text(
                    json!({"id": request["id"], "result": result}).to_string().into(),
                ))
                .unwrap();
            }
            if recovered_rx.recv_timeout(Duration::from_secs(1)).is_err() {
                return false;
            }
            ws.send(Message::Text(
                json!({
                    "method": "Page.screencastFrame",
                    "sessionId": "session-1",
                    "params": {
                        "data": "AAAA",
                        "sessionId": 8,
                        "metadata": {
                            "deviceWidth": 80,
                            "deviceHeight": 24,
                            "timestamp": 10.002
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let Ok(Message::Text(ack)) = ws.read() else {
                return false;
            };
            let ack: Value = serde_json::from_str(&ack).unwrap();
            ack["method"] == "Page.screencastFrameAck"
        });
        let (event_tx, event_rx) = sync_channel(1);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
        {
            let mut frame_sessions = client.inner.frame_epochs.lock().unwrap();
            let frame_session = frame_sessions.get_mut("session-1").unwrap();
            frame_session.main_frame_id = Some("main-frame".to_string());
            frame_session.main_loader_id = Some("loader-1".to_string());
            frame_session.screencast_barrier = Some(ScreencastBarrier::LoaderVerifiedCapture);
            frame_session.pending_timestampless_capture = Some(PendingTimestamplessCapture {
                request_id: 7,
                frame_epoch: 0,
                navigation_epoch: 0,
            });
        }

        let settled = client.settle_timestampless_screencast_capture("session-1", 7, 0, 0);
        let _ = recovered_tx.send(());
        let event = event_rx.recv_timeout(Duration::from_millis(250));

        drop(client);
        let probe_completed = server.join().unwrap();
        assert!(settled);
        assert!(
            probe_completed,
            "a verified capture must retry the clock probe before returning to streamed frames"
        );
        assert!(
            matches!(
                event,
                Ok(CdpEvent::ScreencastFrame(ScreencastFrame { ack_id: 8, frame_epoch: 0, .. }))
            ),
            "a recovered timestamp barrier did not restore the streamed frame rate: {event:?}"
        );
    }

    #[test]
    fn http_discovery_rejects_response_over_limit() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n").unwrap();
            stream.write_all(&vec![b'x'; 65 * 1024]).unwrap();
        });
        let mut stream = TcpStream::connect(addr).unwrap();

        let error = read_http_response(&mut stream).unwrap_err();
        assert!(error.to_string().contains("exceeds size limit"), "{error:#}");
        server.join().unwrap();
    }

    #[test]
    fn http_discovery_enforces_absolute_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for byte in b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" {
                if stream.write_all(&[*byte]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let mut stream = TcpStream::connect(addr).unwrap();

        let started = Instant::now();
        let error =
            read_http_response_with_limits(&mut stream, 64 * 1024, Duration::from_millis(100))
                .unwrap_err();
        assert!(error.to_string().contains("deadline exceeded"), "{error:#}");
        assert!(started.elapsed() < Duration::from_millis(500));
        server.join().unwrap();
    }

    #[test]
    fn http_discovery_retries_idle_timeout_before_absolute_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\n").unwrap();
            thread::sleep(Duration::from_millis(600));
            stream.write_all(b"Content-Length: 2\r\n\r\n{}").unwrap();
        });
        let mut stream = TcpStream::connect(addr).unwrap();

        let response =
            read_http_response_with_limits(&mut stream, 64 * 1024, Duration::from_secs(2)).unwrap();
        assert!(response.ends_with("{}"));
        server.join().unwrap();
    }

    #[test]
    fn concurrent_calls_complete_while_reader_receives_events() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        const CALLS: usize = 12;
        const EMULATION_DEADLINE: Duration = Duration::from_secs(120);

        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            ws.get_ref().set_read_timeout(Some(Duration::from_millis(20))).unwrap();
            ws.get_ref().set_write_timeout(Some(EMULATION_DEADLINE)).unwrap();
            let deadline = Instant::now() + EMULATION_DEADLINE;
            let mut responses = 0usize;

            while responses < CALLS && Instant::now() < deadline {
                ws.send(Message::Text(
                    json!({
                        "method": "Target.targetInfoChanged",
                        "params": {
                            "targetInfo": {
                                "targetId": "target-busy",
                                "title": "busy",
                                "url": "https://busy.test"
                            }
                        }
                    })
                    .to_string()
                    .into(),
                ))
                .unwrap();

                match ws.read() {
                    Ok(Message::Text(text)) => {
                        let request: Value = serde_json::from_str(&text).unwrap();
                        let id = request["id"].clone();
                        ws.send(Message::Text(
                            json!({"id": id, "result": {"method": request["method"]}})
                                .to_string()
                                .into(),
                        ))
                        .unwrap();
                        responses += 1;
                    }
                    Ok(Message::Binary(bytes)) => {
                        let request: Value = serde_json::from_slice(&bytes).unwrap();
                        let id = request["id"].clone();
                        ws.send(Message::Text(
                            json!({"id": id, "result": {"method": request["method"]}})
                                .to_string()
                                .into(),
                        ))
                        .unwrap();
                        responses += 1;
                    }
                    Ok(Message::Ping(_))
                    | Ok(Message::Pong(_))
                    | Ok(Message::Frame(_))
                    | Ok(Message::Close(_)) => {}
                    Err(WsError::Io(err))
                        if matches!(
                            err.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) => {}
                    Err(err) => panic!("server websocket read failed: {err}"),
                }
            }

            assert_eq!(responses, CALLS);
        });

        let (event_tx, _event_rx) = sync_channel(64);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        let barrier = Arc::new(Barrier::new(CALLS));
        let mut workers = Vec::new();
        for idx in 0..CALLS {
            let client = client.clone();
            let barrier = barrier.clone();
            workers.push(thread::spawn(move || {
                barrier.wait();
                let result = client.call("Test.concurrent", json!({ "idx": idx }), None).unwrap();
                assert_eq!(result["method"], "Test.concurrent");
            }));
        }

        for worker in workers {
            worker.join().unwrap();
        }
        server.join().unwrap();
    }

    #[test]
    fn undrained_event_sink_does_not_block_command_responses() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = ws.read().unwrap();
            let Message::Text(request) = request else { panic!("expected text request") };
            let request: Value = serde_json::from_str(&request).unwrap();
            ws.send(Message::Text(
                json!({
                    "method": "Target.targetInfoChanged",
                    "params": {
                        "targetInfo": {
                            "targetId": "target-1",
                            "title": "busy",
                            "url": "https://example.test"
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            ws.send(Message::Text(
                json!({
                    "id": request["id"],
                    "result": {"userAgent": "Mozilla/5.0 Chrome/136.0 Safari/537.36"}
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let _ = stop_rx.recv();
        });
        let (event_tx, event_rx) = sync_channel(0);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        let (result_tx, result_rx) = channel();
        let call_client = client.clone();
        let call = thread::spawn(move || {
            result_tx.send(call_client.browser_version()).unwrap();
        });

        let result = result_rx.recv_timeout(Duration::from_millis(200));
        let retained_event = event_rx.recv_timeout(Duration::from_millis(200));
        drop(client);
        stop_tx.send(()).unwrap();
        server.join().unwrap();
        call.join().unwrap();
        assert!(result.is_ok(), "undrained event sink blocked command response: {result:?}");
        assert!(
            matches!(retained_event, Ok(CdpEvent::TargetInfoChanged(_))),
            "final replaceable event was lost: {retained_event:?}"
        );
    }

    #[test]
    fn saturated_event_sink_preserves_critical_event_and_response() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop_tx, stop_rx) = channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = ws.read().unwrap();
            let Message::Text(request) = request else { panic!("expected text request") };
            let request: Value = serde_json::from_str(&request).unwrap();
            ws.send(Message::Text(
                json!({
                    "method": "Page.javascriptDialogOpening",
                    "sessionId": "session-1",
                    "params": {"type": "alert", "message": "blocked"}
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            ws.send(Message::Text(
                json!({
                    "id": request["id"],
                    "result": {"userAgent": "Mozilla/5.0 Chrome/136.0 Safari/537.36"}
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let _ = stop_rx.recv();
        });
        let (event_tx, event_rx) = sync_channel(0);
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        let (result_tx, result_rx) = channel();
        let call_client = client.clone();
        let call = thread::spawn(move || {
            result_tx.send(call_client.browser_version()).unwrap();
        });

        let result = result_rx.recv_timeout(Duration::from_millis(200));
        let retained_event = event_rx.recv_timeout(Duration::from_millis(200));
        drop(client);
        stop_tx.send(()).unwrap();
        server.join().unwrap();
        call.join().unwrap();
        assert!(matches!(result, Ok(Ok(_))), "critical event blocked command progress: {result:?}");
        assert!(
            matches!(retained_event, Ok(CdpEvent::Other { .. })),
            "critical event was lost: {retained_event:?}"
        );
    }

    #[test]
    fn socket_shutdown_disconnects_a_backpressured_event_receiver() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            ws.close(None).unwrap();
        });
        let (event_tx, event_rx) = sync_channel(1);
        event_tx
            .send(CdpEvent::Other {
                method: "Test.blocked".to_string(),
                params: Value::Null,
                session_id: None,
            })
            .unwrap();
        let client =
            CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
        server.join().unwrap();

        let deadline = Instant::now() + Duration::from_millis(500);
        while !client.inner.reader_stopped.load(Ordering::Acquire) {
            assert!(Instant::now() < deadline, "CDP reader did not stop");
            thread::yield_now();
        }
        assert!(matches!(event_rx.recv(), Ok(CdpEvent::Other { .. })));

        let shutdown = event_rx.recv_timeout(Duration::from_millis(500));
        drop(client);

        assert!(
            matches!(shutdown, Err(std::sync::mpsc::RecvTimeoutError::Disconnected)),
            "reader exit left the event channel live: {shutdown:?}"
        );
    }
}
