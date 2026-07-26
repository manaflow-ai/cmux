use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::mem::size_of;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, SyncSender, TryRecvError, TrySendError, channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tungstenite::client::IntoClientRequest;
use tungstenite::{Error as WsError, Message, WebSocket, client};

/// Maximum number of pending events in each bounded CDP event queue.
///
/// Downstream queue implementations use the same limit so moving an event
/// between CDP layers cannot expand the maximum pending event count.
pub const CDP_EVENT_QUEUE_CAPACITY: usize = 64;
const CDP_INGRESS_EVENT_CAPACITY: usize = 1024;
/// Maximum estimated retained bytes in each bounded CDP event queue.
///
/// The estimate covers dynamically retained event payloads and uses saturating
/// arithmetic. It is a queue-enforcement budget, not an exact allocator usage
/// measurement.
pub const CDP_EVENT_QUEUE_MAX_BYTES: usize = 32 * 1024 * 1024;
const MAX_ENCODED_FRAME_BYTES: usize = 16 * 1024 * 1024;
const MAX_DECODED_FRAME_BYTES: usize = 12 * 1024 * 1024;

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

    pub fn latest_navigation(&self) -> u64 {
        self.latest_navigation.load(Ordering::Acquire)
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationResult {
    pub error_text: Option<String>,
    pub is_download: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CdpEvent {
    ScreencastFrame(ScreencastFrame),
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
    },
    TargetCreated(TargetCreated),
    TargetInfoChanged(TargetInfo),
    Other {
        method: String,
        params: Value,
        session_id: Option<String>,
    },
    Closed(String),
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

fn cdp_debug() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("CMUX_MUX_CDP_DEBUG").is_some())
}

#[derive(Clone)]
pub struct CdpClient {
    inner: Arc<Inner>,
}

struct Inner {
    outbound: Sender<Outbound>,
    pending: Mutex<HashMap<u64, PendingCall>>,
    events: Arc<EventQueue>,
    frame_epochs: Mutex<HashMap<String, FrameSession>>,
    next_id: AtomicU64,
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
    minimum_screencast_timestamp: Option<f64>,
}

struct PendingDocument {
    frame_id: String,
    loader_id: String,
    navigation_epoch: u64,
}

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

    fn close(&self, reason: &str) {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return;
        }
        state.events.clear();
        let event = CdpEvent::Closed(reason.to_string());
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
        CdpEvent::FrameNavigated { params, session_id, .. } => session_id
            .len()
            .saturating_add(json_retained_bytes(params))
            .saturating_add(size_of::<u64>()),
        CdpEvent::DocumentPainted { session_id, frame_id, loader_id, .. } => session_id
            .len()
            .saturating_add(frame_id.len())
            .saturating_add(loader_id.len())
            .saturating_add(size_of::<u64>()),
        CdpEvent::NavigatedWithinDocument { params, session_id, frame_id, loader_id } => session_id
            .len()
            .saturating_add(frame_id.len())
            .saturating_add(loader_id.len())
            .saturating_add(json_retained_bytes(params)),
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
        CdpEvent::Closed(reason) => reason.len(),
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
        self.events.close("CDP client dropped");
    }
}

enum Outbound {
    Message(String),
    Flush(Sender<()>),
}

impl CdpClient {
    pub fn connect(web_socket_url: &str, events: SyncSender<CdpEvent>) -> anyhow::Result<Self> {
        let endpoint = WsEndpoint::parse(web_socket_url)?;
        let mut addrs = (endpoint.host.as_str(), endpoint.port).to_socket_addrs()?;
        let addr = addrs.next().ok_or_else(|| {
            anyhow::anyhow!("no socket address for {}:{}", endpoint.host, endpoint.port)
        })?;
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))?;
        stream.set_nodelay(true)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let request = web_socket_url.into_client_request()?;
        let (ws, _) = client(request, stream)?;
        // The reader thread owns the socket and drains queued outbound
        // writes before each read poll. A message enqueued just after a
        // read starts can wait for this window, but writers never contend
        // on the socket itself.
        ws.get_ref().set_read_timeout(Some(Duration::from_millis(20)))?;
        ws.get_ref().set_write_timeout(Some(Duration::from_secs(5)))?;
        let (outbound_tx, outbound_rx) = channel();
        let event_queue = Arc::new(EventQueue::new());
        let client = CdpClient {
            inner: Arc::new(Inner {
                outbound: outbound_tx,
                pending: Mutex::new(HashMap::new()),
                events: event_queue,
                frame_epochs: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
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
        self.call_inner(method, params, session_id, None)
    }

    fn call_with_frame_barrier(
        &self,
        method: &str,
        params: Value,
        session_id: &str,
        frame_barrier: Arc<FrameEpoch>,
    ) -> anyhow::Result<Value> {
        self.call_inner(method, params, Some(session_id), Some(frame_barrier))
    }

    fn call_inner(
        &self,
        method: &str,
        params: Value,
        session_id: Option<&str>,
        frame_barrier: Option<Arc<FrameEpoch>>,
    ) -> anyhow::Result<Value> {
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

        match rx.recv_timeout(self.inner.timeout) {
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
                minimum_screencast_timestamp: None,
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

    /// Wait until every command queued before this call has been written to
    /// the socket. Responses remain asynchronous.
    pub fn flush_outbound(&self, timeout: Duration) -> anyhow::Result<()> {
        if self.inner.closed.load(Ordering::Acquire) {
            anyhow::bail!("CDP connection is closed");
        }
        let (tx, rx) = channel();
        self.inner
            .outbound
            .send(Outbound::Flush(tx))
            .map_err(|_| anyhow::anyhow!("CDP connection is closed"))?;
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
        let mut frame_epochs = self.inner.frame_epochs.lock().unwrap();
        let frame_session = frame_epochs
            .get_mut(session_id)
            .ok_or_else(|| anyhow::anyhow!("missing frame epoch for CDP session {session_id}"))?;
        frame_session.main_frame_id = Some(frame_id.to_string());
        frame_session.main_loader_id = Some(loader_id.to_string());
        Ok(())
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
        let minimum_screencast_timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| anyhow::anyhow!("system clock precedes Unix epoch: {error}"))?
            .as_secs_f64();
        let frame_epoch = {
            let mut frame_sessions = self.inner.frame_epochs.lock().unwrap();
            let frame_session = frame_sessions.get_mut(session_id).ok_or_else(|| {
                anyhow::anyhow!("missing frame epoch for CDP session {session_id}")
            })?;
            // Chromium records this timestamp when pixels enter the screencast
            // pipeline, before asynchronous encoding. A frame captured before
            // stopScreencast may otherwise be emitted after this restart with
            // the new Chromium session id.
            frame_session.minimum_screencast_timestamp = Some(minimum_screencast_timestamp);
            frame_session.epoch.clone()
        };
        self.call_with_frame_barrier(
            "Page.startScreencast",
            json!({
                "format": "png",
                "maxWidth": max_width,
                "maxHeight": max_height,
                "everyNthFrame": 1,
            }),
            session_id,
            frame_epoch.clone(),
        )?;
        Ok(frame_epoch.current())
    }

    pub fn stop_screencast(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.stopScreencast", json!({}), Some(session_id)).map(|_| ())
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
        self.require_main_frame_loader(session_id, frame_id, loader_id)?;
        let result = self.call(
            "Page.captureScreenshot",
            json!({
                "format": "png",
                "fromSurface": true,
                "captureBeyondViewport": false,
            }),
            Some(session_id),
        )?;
        self.require_main_frame_loader(session_id, frame_id, loader_id)?;
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
    ) -> anyhow::Result<()> {
        let result = self.call("Page.getFrameTree", json!({}), Some(session_id))?;
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
        Ok(NavigationResult { error_text, is_download })
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
        delta_y: f64,
    ) -> anyhow::Result<()> {
        self.call(
            "Input.dispatchMouseEvent",
            json!({
                "type": "mouseWheel",
                "x": x,
                "y": y,
                "deltaX": 0,
                "deltaY": delta_y,
            }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn dispatch_key_event(
        &self,
        session_id: &str,
        event: CdpKeyEvent<'_>,
    ) -> anyhow::Result<()> {
        let mut params = json!({
            "type": event.event_type,
            "key": event.key,
            "code": event.code,
            "windowsVirtualKeyCode": event.windows_virtual_key_code,
            "nativeVirtualKeyCode": event.windows_virtual_key_code,
            "modifiers": event.modifiers,
        });
        if let Some(text) = event.text {
            params["text"] = json!(text);
            params["unmodifiedText"] = json!(text);
        }
        self.call("Input.dispatchKeyEvent", params, Some(session_id)).map(|_| ())
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
        self.inner
            .outbound
            .send(Outbound::Message(text))
            .map_err(|_| anyhow::anyhow!("CDP connection is closed"))?;
        Ok(())
    }
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
            close_inner(&inner, "CDP event receiver closed");
            break;
        }
        if inner.closed.load(Ordering::Acquire) {
            break;
        }
        if let Err(err) = drain_outbound(&mut ws, outbound) {
            close_inner(&inner, &format!("CDP socket error: {err}"));
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
                close_inner(&inner, "CDP socket closed");
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
                close_inner(&inner, &format!("CDP socket error: {e}"));
                let _ = inner.events.drain_into(event_output);
                break;
            }
        }
    }
}

fn drain_outbound(
    ws: &mut WebSocket<TcpStream>,
    outbound: &Receiver<Outbound>,
) -> anyhow::Result<()> {
    loop {
        match outbound.try_recv() {
            Ok(Outbound::Message(text)) => ws.send(Message::Text(text.into()))?,
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
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let session_id = value.get("sessionId").and_then(|v| v.as_str()).map(str::to_string);
    match method {
        "Page.screencastFrame" => {
            if let Some(target_session) = session_id.as_deref() {
                let Some(ack_id) = params.get("sessionId").and_then(|value| value.as_u64()) else {
                    return;
                };
                ack_screencast_frame(inner, target_session, ack_id);
                let (frame_epoch, minimum_screencast_timestamp) = inner
                    .frame_epochs
                    .lock()
                    .unwrap()
                    .get(target_session)
                    .map_or((0, None), |frame_session| {
                        (frame_session.epoch.current(), frame_session.minimum_screencast_timestamp)
                    });
                let Some(frame) = screencast_frame(
                    &params,
                    target_session,
                    frame_epoch,
                    minimum_screencast_timestamp,
                ) else {
                    return;
                };
                dispatch_event(inner, CdpEvent::ScreencastFrame(frame));
            }
        }
        "Target.targetCreated" => {
            if let Some(created) = target_created(&params) {
                dispatch_event(inner, CdpEvent::TargetCreated(created));
            }
        }
        "Target.targetInfoChanged" => {
            if let Some(info) = target_info(&params, session_id.as_deref()) {
                dispatch_event(inner, CdpEvent::TargetInfoChanged(info));
            }
        }
        "Page.frameNavigated" if session_id.is_some() => {
            let session_id = session_id.expect("guarded above");
            if let Some(frame_epoch) = main_frame_navigation_epoch(inner, &params, &session_id) {
                dispatch_event(inner, CdpEvent::FrameNavigated { params, session_id, frame_epoch });
            }
        }
        "Page.lifecycleEvent" if session_id.is_some() => {
            let session_id = session_id.expect("guarded above");
            if let Some(event) = main_frame_document_paint(inner, &params, &session_id) {
                dispatch_event(inner, event);
            }
        }
        "Page.navigatedWithinDocument" if session_id.is_some() => {
            let session_id = session_id.expect("guarded above");
            if let Some(event) = main_frame_same_document_navigation(inner, params, session_id) {
                dispatch_event(inner, event);
            }
        }
        _ => {
            dispatch_event(
                inner,
                CdpEvent::Other { method: method.to_string(), params, session_id },
            );
        }
    }
}

fn main_frame_navigation_epoch(inner: &Inner, params: &Value, session_id: &str) -> Option<u64> {
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
    Some(navigation_epoch)
}

fn main_frame_document_paint(inner: &Inner, params: &Value, session_id: &str) -> Option<CdpEvent> {
    if !matches!(
        params.get("name").and_then(Value::as_str),
        Some("firstPaint" | "firstContentfulPaint")
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
    Some(CdpEvent::DocumentPainted {
        session_id: session_id.to_string(),
        frame_id: pending.frame_id.clone(),
        loader_id: pending.loader_id.clone(),
        navigation_epoch: pending.navigation_epoch,
    })
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
    Some(CdpEvent::NavigatedWithinDocument {
        params,
        session_id,
        frame_id,
        loader_id: frame_session.main_loader_id.clone()?,
    })
}

fn dispatch_event(inner: &Arc<Inner>, event: CdpEvent) {
    if inner.events.push(event).is_err() {
        close_inner(inner, "CDP event queue overflow");
    }
}

fn ack_screencast_frame(inner: &Arc<Inner>, target_session: &str, frame_session: u64) {
    let id = inner.next_id.fetch_add(1, Ordering::Relaxed);
    let msg = json!({
        "id": id,
        "method": "Page.screencastFrameAck",
        "sessionId": target_session,
        "params": { "sessionId": frame_session },
    });
    let Ok(text) = serde_json::to_string(&msg) else { return };
    let _ = inner.outbound.send(Outbound::Message(text));
}

fn screencast_frame(
    params: &Value,
    session_id: &str,
    frame_epoch: u64,
    minimum_timestamp: Option<f64>,
) -> Option<ScreencastFrame> {
    let supplied = params.get("data")?.as_str()?;
    if supplied.len() > MAX_ENCODED_FRAME_BYTES {
        return None;
    }
    if canonical_base64_decoded_len(supplied)? > MAX_DECODED_FRAME_BYTES {
        return None;
    }
    let ack_id = params.get("sessionId")?.as_u64()?;
    let metadata = params.get("metadata").unwrap_or(&Value::Null);
    if let Some(minimum_timestamp) = minimum_timestamp {
        let capture_timestamp =
            metadata.get("timestamp").and_then(Value::as_f64).filter(|value| value.is_finite())?;
        if capture_timestamp < minimum_timestamp {
            return None;
        }
    }
    let css_width = metadata
        .get("deviceWidth")
        .and_then(|v| v.as_u64())
        .or_else(|| metadata.get("width").and_then(|v| v.as_u64()))
        .unwrap_or(0) as u32;
    let css_height = metadata
        .get("deviceHeight")
        .and_then(|v| v.as_u64())
        .or_else(|| metadata.get("height").and_then(|v| v.as_u64()))
        .unwrap_or(0) as u32;
    Some(ScreencastFrame {
        session_id: session_id.to_string(),
        data_b64: supplied.to_string(),
        css_width,
        css_height,
        ack_id,
        frame_epoch,
    })
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

fn png_dimensions(data_b64: &str) -> Option<(u32, u32)> {
    const HEADER_BASE64_BYTES: usize = 32;
    const PNG_HEADER_BYTES: usize = 24;
    let encoded = data_b64.as_bytes().get(..HEADER_BASE64_BYTES)?;
    let mut decoded = [0_u8; PNG_HEADER_BYTES];
    for (encoded, decoded) in encoded.chunks_exact(4).zip(decoded.chunks_exact_mut(3)) {
        let a = base64_value(encoded[0])?;
        let b = base64_value(encoded[1])?;
        let c = base64_value(encoded[2])?;
        let d = base64_value(encoded[3])?;
        decoded[0] = a << 2 | b >> 4;
        decoded[1] = b << 4 | c >> 2;
        decoded[2] = c << 6 | d;
    }
    if decoded[..8] != [137, 80, 78, 71, 13, 10, 26, 10]
        || decoded[8..12] != 13_u32.to_be_bytes()
        || decoded[12..16] != *b"IHDR"
    {
        return None;
    }
    let width = u32::from_be_bytes(decoded[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(decoded[20..24].try_into().ok()?);
    (width != 0 && height != 0).then_some((width, height))
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

fn close_inner(inner: &Arc<Inner>, why: &str) {
    if inner.closed.swap(true, Ordering::AcqRel) {
        return;
    }
    for (_, pending) in inner.pending.lock().unwrap().drain() {
        let _ = pending.response.send(Err(why.to_string()));
    }
    inner.events.close(why);
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

    use tungstenite::{Message, accept};

    use super::*;

    fn test_inner() -> (Arc<Inner>, Receiver<Outbound>) {
        let (outbound, outbound_rx) = channel();
        (
            Arc::new(Inner {
                outbound,
                pending: Mutex::new(HashMap::new()),
                events: Arc::new(EventQueue::new()),
                frame_epochs: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
                closed: AtomicBool::new(false),
                timeout: Duration::from_secs(1),
                reader_stopped: Arc::new(AtomicBool::new(false)),
            }),
            outbound_rx,
        )
    }

    #[test]
    fn screencast_frame_rejects_terminal_control_bytes() {
        let params = json!({
            "data": "AAAA\u{1b}_Ga=T,f=100;AAAA\u{1b}\\",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        assert!(screencast_frame(&params, "session-1", 0, None).is_none());
    }

    #[test]
    fn screencast_frame_preserves_valid_canonical_base64() {
        let params = json!({
            "data": "aGk=",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        assert_eq!(screencast_frame(&params, "session-1", 0, None).unwrap().data_b64, "aGk=");
    }

    #[test]
    fn screencast_frame_rejects_noncanonical_padding_bits() {
        let params = json!({
            "data": "aGl=",
            "sessionId": 7,
            "metadata": {"deviceWidth": 80, "deviceHeight": 24}
        });

        assert!(screencast_frame(&params, "session-1", 0, None).is_none());
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
                minimum_screencast_timestamp: None,
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
    fn same_document_navigation_does_not_advance_main_frame_epoch() {
        let (inner, _outbound_rx) = test_inner();
        let frame_epoch = Arc::new(FrameEpoch::default());
        inner.frame_epochs.lock().unwrap().insert(
            "session-1".to_string(),
            FrameSession {
                epoch: frame_epoch.clone(),
                main_frame_id: None,
                main_loader_id: None,
                pending_document: None,
                minimum_screencast_timestamp: None,
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
            1,
            "same-document navigation must not invalidate the current document's pointer authority"
        );
        let (event_tx, event_rx) = sync_channel(2);
        inner.events.drain_into(&event_tx).unwrap();
        assert!(matches!(event_rx.recv().unwrap(), CdpEvent::FrameNavigated { .. }));
        assert!(matches!(
            event_rx.recv().unwrap(),
            CdpEvent::NavigatedWithinDocument {
                frame_id,
                loader_id,
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
            for expected in ["Page.stopScreencast", "Page.startScreencast"] {
                let request = ws.read().unwrap();
                let Message::Text(request) = request else { panic!("expected text request") };
                let request: Value = serde_json::from_str(&request).unwrap();
                assert_eq!(request["method"], expected);
                ws.send(Message::Text(
                    json!({"id": request["id"], "result": {}}).to_string().into(),
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
                            "timestamp": 1.0
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

        client.stop_screencast("session-1").unwrap();
        client.start_screencast_with_frame_barrier("session-1", 80, 24).unwrap();

        let delayed = event_rx.recv_timeout(Duration::from_millis(200));
        assert!(
            !matches!(delayed, Ok(CdpEvent::ScreencastFrame(_))),
            "a pre-restart capture emitted by a delayed encoder crossed the authority barrier: \
             {delayed:?}"
        );
        server.join().unwrap();
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
