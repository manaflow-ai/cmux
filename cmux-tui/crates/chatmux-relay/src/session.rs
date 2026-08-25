//! Connected state: hello negotiation, heartbeats, trust sync, reconnect
//! with jittered exponential backoff, and the exec/PTY frame dispatch.
//! Behavior port of `stayOnline` / `relaySession` in
//! `packages/relay/bin/cmux-relay.mjs`.
//!
//! Slices 2/3: `action_request` runs the exec verbs (`actions`); the
//! `pty_*` family drives the PtyManager (`pty`). Both re-check the machine's
//! own reconciled trust locally. The PtyManager is a per-process singleton
//! held across reconnects (sessions persist; only attachments detach on a
//! socket drop). Output from spawned exec/PTY tasks rides an outbound
//! channel so the socket stays single-writer; `pending_bytes` approximates
//! the server-directed backpressure the JS relay read from `ws.bufferedAmount`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::sync::{Mutex as AsyncMutex, OwnedSemaphorePermit, Semaphore};
use tokio::task::JoinSet;
use tokio::time::timeout;
use tokio_tungstenite::connect_async_with_config;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{Error as TungsteniteError, Message};
use tokio_util::sync::CancellationToken;

use crate::actions::{ActionContext, perform_action, process_env_snapshot, scrubbed_env};
use crate::config::{Config, save_config};
use crate::error::RelayError;
use crate::pairing::websocket_url;
use crate::pty::FrameContext;
#[cfg(unix)]
use crate::pty::PtyManager;
use crate::trust::{
    DEFAULT_RELAY_TRUST, Trust, clear_invalid_yolo_confirmation, effective_local_trust,
    has_yolo_confirmation, relay_trust,
};
use crate::wire::{
    CLI_VERSION, EXEC_PROTOCOL_VERSION, FRAME_VERSION, HelloFrame,
    PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION, PTY_PROTOCOL_VERSION, ServerFrame,
    advertised_protocol, heartbeat_frame, parse_server_frame, set_trust_frame,
};

const MAX_OUTBOUND_FRAMES: usize = 256;
const MAX_WATCH_OUTBOUND_FRAMES: usize = 64;
const MAX_OUTBOUND_BYTES: usize = 8 << 20;
const MAX_PTY_INGRESS_FRAMES: usize = 64;
// Keep room for the workspace fs_write 2 MiB payload plus its JSON envelope.
const MAX_INBOUND_FRAME_BYTES: usize = 4 << 20;
const CONNECTION_TASK_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

pub struct SessionState {
    pub first_connect: bool,
    pub first_run: bool,
    pub managed: bool,
}

/// The machine-side authority read at each exec/PTY dispatch: reconciled
/// trust, allowed roots, and the paired owner. Updated on hello_accepted and
/// trust_ack; never the frame's echo alone.
#[derive(Clone, Default)]
struct AuthSnapshot {
    trust: String,
    roots: Option<Vec<String>>,
    owner: Option<String>,
    negotiated_version: u64,
}

/// Own one producer's contribution to the socket backlog gauge. The token is
/// created before queue admission so cancellation while waiting for capacity
/// also releases the contribution.
pub(crate) struct PendingBytes {
    counter: Option<Arc<AtomicU64>>,
    bytes: u64,
}

impl PendingBytes {
    pub(crate) fn none() -> PendingBytes {
        PendingBytes { counter: None, bytes: 0 }
    }

    pub(crate) fn new(counter: Arc<AtomicU64>, bytes: u64) -> PendingBytes {
        counter.fetch_add(bytes, Ordering::SeqCst);
        PendingBytes { counter: Some(counter), bytes }
    }
}

impl Drop for PendingBytes {
    fn drop(&mut self) {
        if let Some(counter) = self.counter.take() {
            release_pending_bytes(&counter, self.bytes);
        }
    }
}

pub(crate) struct OutboundFrame {
    pub(crate) text: String,
    pub(crate) live: Option<Arc<AtomicBool>>,
    pub(crate) ack: Option<tokio::sync::oneshot::Sender<()>>,
    pending: Option<PendingBytes>,
    _bytes: OwnedSemaphorePermit,
}

impl OutboundFrame {
    pub(crate) fn is_live(&self) -> bool {
        self.live.as_ref().is_none_or(|live| live.load(Ordering::Acquire))
    }

    /// Complete a producer waiting for this frame to leave the writer. The
    /// sender is optional for lossy frames, and sending is best effort because
    /// the producer may have been cancelled already.
    pub(crate) fn acknowledge(&mut self) {
        // Release accounting before waking a producer waiting for this ack.
        drop(self.pending.take());
        if let Some(ack) = self.ack.take() {
            let _ = ack.send(());
        }
    }
}

impl Drop for OutboundFrame {
    fn drop(&mut self) {
        // Covers queue teardown and producer send errors. The writer calls
        // `acknowledge` explicitly for stale, sent, and failed frames; Drop
        // makes the shutdown/EOF path safe even if a receiver is discarded.
        self.acknowledge();
    }
}

async fn send_socket_message<S>(
    socket: &Arc<AsyncMutex<S>>,
    message: Message,
    cancellation: &CancellationToken,
) -> Result<(), ()>
where
    S: futures_util::Sink<Message> + Unpin,
{
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err(()),
        result = async {
            socket.lock().await.send(message).await
        } => result.map_err(|_| ()),
    }
}

async fn send_socket_text<S>(
    socket: &Arc<AsyncMutex<S>>,
    text: String,
    cancellation: &CancellationToken,
) -> Result<(), ()>
where
    S: futures_util::Sink<Message> + Unpin,
{
    send_socket_message(socket, Message::Text(text.into()), cancellation).await
}

/// One socket's bounded outbound capacity. Critical request responses wait
/// for capacity; lossy watch/stream events fail immediately and let their
/// producer coalesce the loss into a later overflow frame.
#[derive(Clone)]
pub(crate) struct OutboundSink {
    critical: mpsc::Sender<OutboundFrame>,
    watch: mpsc::Sender<OutboundFrame>,
    bytes: Arc<Semaphore>,
    critical_overflow: Arc<std::sync::atomic::AtomicBool>,
}

impl OutboundSink {
    pub(crate) fn channels()
    -> (OutboundSink, mpsc::Receiver<OutboundFrame>, mpsc::Receiver<OutboundFrame>) {
        let (critical, critical_rx) = mpsc::channel(MAX_OUTBOUND_FRAMES);
        let (watch, watch_rx) = mpsc::channel(MAX_WATCH_OUTBOUND_FRAMES);
        (
            OutboundSink {
                critical,
                watch,
                bytes: Arc::new(Semaphore::new(MAX_OUTBOUND_BYTES)),
                critical_overflow: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            },
            critical_rx,
            watch_rx,
        )
    }

    fn encode(frame: Value) -> Option<String> {
        serde_json::to_string(&frame).ok()
    }

    pub(crate) async fn critical_value(&self, frame: Value) -> Result<(), ()> {
        self.critical_value_with_pending(frame, PendingBytes::none()).await
    }

    pub(crate) async fn critical_value_with_pending(
        &self,
        frame: Value,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        let Some(text) = Self::encode(frame) else { return Err(()) };
        self.critical_text_with_token_ack_pending(text, None, None, pending).await
    }

    pub(crate) async fn critical_text(&self, text: String) -> Result<(), ()> {
        self.critical_text_with_token_ack_pending(text, None, None, PendingBytes::none()).await
    }

    pub(crate) async fn critical_text_with_token(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
    ) -> Result<(), ()> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.critical_text_with_token_ack(text, live, Some(tx)).await?;
        rx.await.map_err(|_| ())
    }

    pub(crate) async fn critical_text_with_token_ack(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
        ack: Option<tokio::sync::oneshot::Sender<()>>,
    ) -> Result<(), ()> {
        self.critical_text_with_token_ack_pending(text, live, ack, PendingBytes::none()).await
    }

    pub(crate) async fn critical_text_with_token_ack_pending(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
        ack: Option<tokio::sync::oneshot::Sender<()>>,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        let bytes = u32::try_from(text.len()).map_err(|_| ())?;
        if bytes as usize > MAX_OUTBOUND_BYTES {
            self.critical_overflow.store(true, Ordering::Release);
            return Err(());
        }
        let permit = Arc::clone(&self.bytes).acquire_many_owned(bytes).await.map_err(|_| ())?;
        let result = self
            .critical
            .send(OutboundFrame { text, live, ack, pending: Some(pending), _bytes: permit })
            .await
            .map_err(|_| ());
        if result.is_err() {
            self.critical_overflow.store(true, Ordering::Release);
        }
        result
    }

    pub(crate) fn try_watch_value(&self, frame: Value) -> Result<(), ()> {
        self.try_watch_value_with_pending(frame, PendingBytes::none())
    }

    pub(crate) fn try_watch_value_with_pending(
        &self,
        frame: Value,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        self.try_watch_value_with_token_pending(frame, None, pending)
    }

    pub(crate) fn try_watch_value_with_token(
        &self,
        frame: Value,
        live: Option<Arc<AtomicBool>>,
    ) -> Result<(), ()> {
        self.try_watch_value_with_token_pending(frame, live, PendingBytes::none())
    }

    pub(crate) fn try_watch_value_with_token_pending(
        &self,
        frame: Value,
        live: Option<Arc<AtomicBool>>,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        let Some(text) = Self::encode(frame) else { return Err(()) };
        self.try_watch_text_with_token_pending(text, live, pending)
    }

    pub(crate) fn try_critical_value(&self, frame: Value) -> Result<(), ()> {
        self.try_critical_value_with_token_pending(frame, None, PendingBytes::none())
    }

    pub(crate) fn try_critical_value_with_token(
        &self,
        frame: Value,
        live: Option<Arc<AtomicBool>>,
    ) -> Result<(), ()> {
        self.try_critical_value_with_token_pending(frame, live, PendingBytes::none())
    }

    pub(crate) fn try_critical_value_with_token_pending(
        &self,
        frame: Value,
        live: Option<Arc<AtomicBool>>,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        let result = (|| {
            let text = Self::encode(frame).ok_or(())?;
            let bytes = u32::try_from(text.len()).map_err(|_| ())?;
            if bytes as usize > MAX_OUTBOUND_BYTES {
                return Err(());
            }
            let permit = Arc::clone(&self.bytes).try_acquire_many_owned(bytes).map_err(|_| ())?;
            self.critical
                .try_send(OutboundFrame {
                    text,
                    live,
                    ack: None,
                    pending: Some(pending),
                    _bytes: permit,
                })
                .map_err(|_| ())
        })();
        if result.is_err() {
            self.critical_overflow.store(true, Ordering::Release);
        }
        result
    }

    pub(crate) fn try_critical_text(&self, text: String) -> Result<(), ()> {
        self.try_critical_text_with_token_pending(text, None, PendingBytes::none())
    }

    pub(crate) fn try_critical_text_with_token(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
    ) -> Result<(), ()> {
        self.try_critical_text_with_token_pending(text, live, PendingBytes::none())
    }

    pub(crate) fn try_critical_text_with_token_pending(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        let result = (|| {
            let bytes = u32::try_from(text.len()).map_err(|_| ())?;
            if bytes as usize > MAX_OUTBOUND_BYTES {
                return Err(());
            }
            let permit = Arc::clone(&self.bytes).try_acquire_many_owned(bytes).map_err(|_| ())?;
            self.critical
                .try_send(OutboundFrame {
                    text,
                    live,
                    ack: None,
                    pending: Some(pending),
                    _bytes: permit,
                })
                .map_err(|_| ())
        })();
        if result.is_err() {
            self.critical_overflow.store(true, Ordering::Release);
        }
        result
    }

    fn critical_overflowed(&self) -> bool {
        self.critical_overflow.load(Ordering::Acquire)
    }

    pub(crate) fn try_watch_text(&self, text: String) -> Result<(), ()> {
        self.try_watch_text_with_token(text, None)
    }

    pub(crate) fn try_watch_text_with_token(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
    ) -> Result<(), ()> {
        self.try_watch_text_with_token_pending(text, live, PendingBytes::none())
    }

    pub(crate) fn try_watch_text_with_token_pending(
        &self,
        text: String,
        live: Option<Arc<AtomicBool>>,
        pending: PendingBytes,
    ) -> Result<(), ()> {
        let bytes = u32::try_from(text.len()).map_err(|_| ())?;
        let permit = Arc::clone(&self.bytes).try_acquire_many_owned(bytes).map_err(|_| ())?;
        self.watch
            .try_send(OutboundFrame {
                text,
                live,
                ack: None,
                pending: Some(pending),
                _bytes: permit,
            })
            .map_err(|_| ())
    }
}

/// Process-lifetime state shared across reconnects. The PtyManager singleton
/// keeps sessions alive while attachments detach with each socket.
pub struct SessionRuntime {
    home: PathBuf,
    base_env: HashMap<String, String>,
    pub(crate) workspace: Arc<crate::workspace::SharedRuntime>,
    #[cfg(unix)]
    pty: Arc<PtyManager>,
}

impl SessionRuntime {
    pub fn new() -> SessionRuntime {
        Self::with_roots(None)
    }

    pub fn with_roots(local_roots: Option<Vec<String>>) -> SessionRuntime {
        let base_env = process_env_snapshot();
        let home = base_env.get("HOME").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
        #[cfg(unix)]
        let pty = {
            let deps = Arc::new(crate::pty_deps::RealPtyDeps::new(base_env.clone()));
            Arc::new(PtyManager::new(deps, home.clone(), base_env.clone()))
        };
        SessionRuntime {
            home,
            base_env,
            workspace: Arc::new(crate::workspace::SharedRuntime::new(local_roots)),
            #[cfg(unix)]
            pty,
        }
    }
}

impl Default for SessionRuntime {
    fn default() -> SessionRuntime {
        SessionRuntime::new()
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

fn jitter() -> f64 {
    let mut byte = [0_u8; 1];
    let _ = getrandom::fill(&mut byte);
    0.5 + f64::from(byte[0]) / 512.0
}

/// Wait for one reconnect backoff interval without making shutdown wait for
/// the current delay. The biased cancellation branch makes a signal that
/// races the timer resolve as a shutdown, never as one more dial attempt.
async fn wait_for_reconnect(cancellation: &CancellationToken, delay: Duration) -> bool {
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => false,
        _ = tokio::time::sleep(delay) => true,
    }
}

/// Cancel and await all work admitted by one physical socket. The timeout is
/// a final guard for provider code that does not reach an async cancellation
/// point; dropping the JoinSet after the timeout aborts the remaining handles.
async fn shutdown_connection_tasks(
    connection_tasks: &mut JoinSet<()>,
    cancellation: &CancellationToken,
) -> bool {
    cancellation.cancel();
    timeout(CONNECTION_TASK_SHUTDOWN_TIMEOUT, connection_tasks.shutdown()).await.is_ok()
}

/// Resolve acknowledgements for frames that were accepted by a producer but
/// never reached the socket because the writer stopped at EOF or shutdown.
fn acknowledge_pending_frames(
    critical_rx: &mut mpsc::Receiver<OutboundFrame>,
    watch_rx: &mut mpsc::Receiver<OutboundFrame>,
) {
    while let Ok(mut frame) = critical_rx.try_recv() {
        frame.acknowledge();
    }
    while let Ok(mut frame) = watch_rx.try_recv() {
        frame.acknowledge();
    }
}

/// Release bytes from the approximate socket backlog without allowing
/// concurrent producers to subtract the same bytes twice.
fn release_pending_bytes(pending: &AtomicU64, bytes: u64) {
    if bytes == 0 {
        return;
    }
    let mut current = pending.load(Ordering::SeqCst);
    loop {
        let next = current.saturating_sub(bytes);
        match pending.compare_exchange_weak(current, next, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => return,
            Err(actual) => current = actual,
        }
    }
}

/// Keep the machine online until the process cancellation token is raised.
/// Fatal errors are returned to the CLI; transient errors ride a jittered
/// exponential backoff with a 30s ceiling.
pub async fn stay_online(
    mut config: Config,
    config_path: &Path,
    mut state: SessionState,
    cancellation: CancellationToken,
) -> Result<(), RelayError> {
    let runtime = SessionRuntime::with_roots(config.allowed_roots.clone());
    let mut attempt: u32 = 0;
    loop {
        if cancellation.is_cancelled() {
            return Ok(());
        }
        match relay_session(&mut config, config_path, &mut state, &runtime, &cancellation).await {
            Ok(was_connected) => {
                if was_connected {
                    attempt = 0;
                }
            }
            Err(RelayError::Fatal { message, exit_code }) => {
                return Err(RelayError::Fatal { message, exit_code });
            }
            Err(error) => {
                eprintln!("Relay offline: {error}");
            }
        }
        if cancellation.is_cancelled() {
            return Ok(());
        }
        let ceiling = 500_u64.saturating_mul(1_u64 << attempt.min(10)).min(30_000);
        attempt = attempt.saturating_add(1);
        let delay = (ceiling as f64 * jitter()).round().max(0.0) as u64;
        if !wait_for_reconnect(&cancellation, Duration::from_millis(delay)).await {
            return Ok(());
        }
    }
}

fn save(config: &Config, config_path: &Path) {
    if let Err(error) = save_config(config_path, config) {
        eprintln!("Could not save the relay config: {error}");
    }
}

/// Non-Unix builds cannot allocate or attach a PTY. Keep the protocol v4
/// surface usable by answering the required open/list requests explicitly;
/// control frames remain idempotent and have no response in the wire contract.
#[cfg(not(unix))]
fn unsupported_platform_pty_reply(frame_type: &str, raw: &Value) -> Option<Value> {
    match frame_type {
        "pty_open" => raw.get("ptyId").and_then(Value::as_str).map(|pty_id| {
            serde_json::json!({
                "version": PTY_PROTOCOL_VERSION,
                "type": "pty_error",
                "ptyId": pty_id,
                "code": "failed",
                "message": "terminals are not available on this relay platform",
            })
        }),
        "surface_list" => raw.get("requestId").and_then(Value::as_str).map(|request_id| {
            serde_json::json!({
                "version": PTY_PROTOCOL_VERSION,
                "type": "surface_list_result",
                "requestId": request_id,
                "surfaces": [],
            })
        }),
        _ => None,
    }
}

/// Build a per-frame FrameContext reading the current reconciled auth.
fn make_context(out: &OutboundSink, pending: &Arc<AtomicU64>, auth: &AuthSnapshot) -> FrameContext {
    let sender = out.clone();
    let pending_send = Arc::clone(pending);
    let pending_probe = Arc::clone(pending);
    FrameContext {
        send: Arc::new(move |frame: Value| {
            let size = serde_json::to_string(&frame).map(|text| text.len() as u64).unwrap_or(0);
            let pending_frame = PendingBytes::new(Arc::clone(&pending_send), size);
            let critical = matches!(
                frame.get("type").and_then(Value::as_str),
                Some(
                    "pty_opened" | "pty_error" | "pty_exit" | "pty_closed" | "surface_list_result"
                )
            );
            let result = if critical {
                sender.try_critical_value_with_token_pending(frame, None, pending_frame)
            } else {
                sender.try_watch_value_with_token_pending(frame, None, pending_frame)
            };
            if result.is_err() {
                eprintln!(
                    "Dropping relay outbound frame because its bounded queue is full; mandatory={critical}"
                );
            }
        }),
        buffered_amount: Arc::new(move || pending_probe.load(Ordering::SeqCst)),
        negotiated_version: auth.negotiated_version,
        trust: auth.trust.clone(),
        local_roots: auth.roots.clone(),
        owner_user_id: auth.owner.clone(),
    }
}

async fn relay_session(
    config: &mut Config,
    config_path: &Path,
    state: &mut SessionState,
    runtime: &SessionRuntime,
    cancellation: &CancellationToken,
) -> Result<bool, RelayError> {
    if config.backend.is_empty() {
        return Err(RelayError::fatal(
            "The relay config has no backend URL. Re-pair with: npx cmux-relay --pair",
        ));
    }
    let socket_url =
        websocket_url(&format!("{}/v2/relays/{}/socket", config.backend, config.device_id));
    // Reject oversized websocket messages during framing, before JSON parsing.
    let websocket_config = WebSocketConfig::default()
        .max_message_size(Some(MAX_INBOUND_FRAME_BYTES))
        .max_frame_size(Some(MAX_INBOUND_FRAME_BYTES));
    let connect = connect_async_with_config(socket_url.as_str(), Some(websocket_config), true);
    let (socket, _response) = tokio::select! {
        biased;
        _ = cancellation.cancelled() => return Ok(false),
        result = connect => result.map_err(|error| RelayError::transient(error.to_string()))?,
    };
    let socket = Arc::new(AsyncMutex::new(socket));

    let local_roots = config.allowed_roots.clone().filter(|roots| !roots.is_empty());
    let hello = HelloFrame {
        version: FRAME_VERSION,
        frame_type: "hello",
        relay_protocol_version: advertised_protocol(),
        cli_version: CLI_VERSION,
        machine_id: &config.device_id,
        token: &config.token,
        allowed_roots: local_roots.as_ref(),
        managed_enrollment: if state.managed { config.managed.as_ref() } else { None },
    };
    let hello_text =
        serde_json::to_string(&hello).map_err(|error| RelayError::transient(error.to_string()))?;
    if send_socket_text(&socket, hello_text, cancellation).await.is_err() {
        return Ok(false);
    }

    // Outbound frame channel (exec/PTY tasks -> socket) + backpressure gauge.
    let (out_tx, mut critical_rx, mut watch_rx) = OutboundSink::channels();
    let pending = Arc::new(AtomicU64::new(0));
    let action_slots = Arc::new(Semaphore::new(8));
    let auth = Arc::new(std::sync::Mutex::new(AuthSnapshot {
        trust: String::new(),
        roots: None,
        owner: None,
        negotiated_version: 0,
    }));
    let workspace_runtime = Arc::clone(&runtime.workspace);
    let workspace = crate::workspace::Connection::new(workspace_runtime, out_tx.clone());
    // A child token ends every task admitted by this physical connection on
    // disconnect. The parent token is the process-level signal cancellation;
    // this child is also raised for ordinary reconnects.
    let connection_cancellation = cancellation.child_token();
    let mut connection_tasks = JoinSet::new();

    // Ordered PTY frame dispatch on its own task so a slow open (daemon
    // spawn) never stalls heartbeats or other frames.
    #[cfg(unix)]
    let manager_direct = Arc::clone(&runtime.pty);
    #[cfg(unix)]
    let auth_direct = Arc::clone(&auth);
    #[cfg(unix)]
    let pty_tx = {
        let (pty_tx, mut pty_rx) = mpsc::channel::<Value>(MAX_PTY_INGRESS_FRAMES);
        let manager = Arc::clone(&runtime.pty);
        let out = out_tx.clone();
        let pending = Arc::clone(&pending);
        let auth = Arc::clone(&auth);
        let cancellation = connection_cancellation.clone();
        connection_tasks.spawn(async move {
            loop {
                let frame = tokio::select! {
                    biased;
                    _ = cancellation.cancelled() => break,
                    frame = pty_rx.recv() => {
                        let Some(frame) = frame else { break };
                        frame
                    }
                };
                let snapshot = auth.lock().expect("auth lock").clone();
                let context = make_context(&out, &pending, &snapshot);
                tokio::select! {
                    biased;
                    _ = cancellation.cancelled() => break,
                    _ = manager.handle_frame(&frame, &context) => {}
                }
            }
        });
        pty_tx
    };

    let mut connected = false;
    let mut negotiated_version: u64 = 0;
    const UNKNOWN_TYPE_DIAGNOSTIC_CAP: usize = 64;
    let mut unknown_types: HashSet<String> = HashSet::new();
    let mut unknown_type_order: VecDeque<String> = VecDeque::new();
    let mut heartbeat: Option<tokio::time::Interval> = None;
    let mut critical_burst = 0_u8;

    let result = loop {
        // Retire completed per-request tasks before accepting more work. A
        // long-lived relay connection can otherwise retain one JoinSet entry
        // for every completed action until socket shutdown.
        let mut task_failure = None;
        while let Some(joined) = connection_tasks.try_join_next() {
            if let Err(error) = joined {
                task_failure = Some(if error.is_panic() {
                    RelayError::transient("relay request task panicked; reconnecting".to_owned())
                } else {
                    RelayError::transient(
                        "relay request task was cancelled unexpectedly; reconnecting".to_owned(),
                    )
                });
                break;
            }
        }
        if let Some(error) = task_failure {
            break Err(error);
        }
        enum Wake {
            Shutdown,
            Heartbeat,
            Outbound(bool, Option<OutboundFrame>),
            Incoming(Option<Result<Message, TungsteniteError>>),
        }
        let wake = {
            let mut guard = socket.lock().await;
            if critical_burst >= 8 {
                critical_burst = 0;
                tokio::select! {
                    frame = critical_rx.recv() => Wake::Outbound(true, frame),
                    frame = watch_rx.recv() => Wake::Outbound(false, frame),
                    _ = async {
                        match heartbeat.as_mut() {
                            Some(interval) => interval.tick().await,
                            None => std::future::pending().await,
                        }
                    }, if heartbeat.is_some() => Wake::Heartbeat,
                    _ = cancellation.cancelled() => Wake::Shutdown,
                    incoming = guard.next() => Wake::Incoming(incoming),
                }
            } else {
                tokio::select! {
                    biased;
                    frame = critical_rx.recv() => Wake::Outbound(true, frame),
                    frame = watch_rx.recv() => Wake::Outbound(false, frame),
                    _ = async {
                        match heartbeat.as_mut() {
                            Some(interval) => interval.tick().await,
                            None => std::future::pending().await,
                        }
                    }, if heartbeat.is_some() => Wake::Heartbeat,
                    _ = cancellation.cancelled() => Wake::Shutdown,
                    incoming = guard.next() => Wake::Incoming(incoming),
                }
            }
        };
        match wake {
            Wake::Shutdown => break Ok(connected),
            Wake::Heartbeat => {
                critical_burst = 0;
                let frame = heartbeat_frame(now_ms()).to_string();
                if send_socket_text(&socket, frame, cancellation).await.is_err() {
                    break Ok(connected);
                }
            }
            Wake::Outbound(is_critical, Some(frame)) => {
                let mut frame = frame;
                if !frame.is_live() {
                    frame.acknowledge();
                    continue;
                }
                if is_critical {
                    critical_burst += 1;
                } else {
                    critical_burst = 0;
                }
                let text = std::mem::take(&mut frame.text);
                let sent = send_socket_text(&socket, text, cancellation).await;
                if sent.is_err() {
                    frame.acknowledge();
                    break Ok(connected);
                }
                frame.acknowledge();
            }
            Wake::Outbound(_, None) => {
                critical_burst = 0;
            }
            Wake::Incoming(incoming) => {
                critical_burst = 0;
                let message = match incoming {
                    Some(Ok(message)) => message,
                    Some(Err(error)) => break Err(RelayError::transient(error.to_string())),
                    None => break Ok(connected),
                };
                let text = match message {
                    Message::Text(text) => text,
                    Message::Ping(payload) => {
                        let _ = send_socket_message(&socket, Message::Pong(payload), cancellation)
                            .await;
                        continue;
                    }
                    Message::Close(_) => break Ok(connected),
                    _ => continue,
                };
                if text.len() > MAX_INBOUND_FRAME_BYTES {
                    eprintln!("Ignoring oversized relay frame ({} bytes)", text.len());
                    continue;
                }
                // Unreadable frames are ignored; the socket stays open.
                let Some(frame) = parse_server_frame(&text) else { continue };
                match frame {
                    ServerFrame::HelloAccepted(hello) => {
                        connected = true;
                        negotiated_version = hello.relay_protocol_version;
                        clear_invalid_yolo_confirmation(config);
                        let configured = relay_trust(
                            config.pending_trust.as_deref().or(config.trust.as_deref()),
                        );
                        let local_trust = if state.managed {
                            DEFAULT_RELAY_TRUST
                        } else {
                            effective_local_trust(config)
                        };
                        if !state.managed
                            && (configured != local_trust || local_trust == Trust::Autonomous)
                        {
                            config.pending_trust = Some(local_trust.as_str().to_owned());
                            save(config, config_path);
                        }
                        if let Some(owner) = hello.owner_user_id {
                            config.owner_user_id = Some(owner);
                        }
                        if state.managed {
                            match hello
                                .managed_session_token
                                .as_deref()
                                .filter(|token| token.len() >= 32)
                            {
                                Some(token) => config.token = token.to_owned(),
                                None => {
                                    if !config.enrollment_claimed {
                                        break Err(RelayError::fatal(
                                            "Managed enrollment was not accepted.",
                                        ));
                                    }
                                }
                            }
                            config.enrollment_claimed = true;
                        }
                        let display_name = if hello.machine_name.is_empty() {
                            config.name.clone().unwrap_or_default()
                        } else {
                            hello.machine_name.clone()
                        };
                        let shown_trust = if state.managed {
                            hello.trust.clone()
                        } else {
                            local_trust.as_str().to_owned()
                        };
                        println!(
                            "Connected as {display_name} (protocol v{}, trust {shown_trust}, scope {}).",
                            hello.relay_protocol_version, hello.scope,
                        );
                        if state.first_connect {
                            state.first_connect = false;
                            println!(
                                "{}",
                                if state.first_run {
                                    "Leave this terminal running, or rely on autostart to keep \
                                     this machine reachable."
                                } else {
                                    "Leave this running; chatmux can now reach this machine."
                                }
                            );
                        }
                        if !state.managed
                            && (local_trust.as_str() != hello.trust
                                || local_trust == Trust::Autonomous)
                        {
                            let frame = set_trust_frame(local_trust.as_str()).to_string();
                            if send_socket_text(&socket, frame, cancellation).await.is_err() {
                                break Ok(connected);
                            }
                        } else if !state.managed {
                            config.trust = Some(local_trust.as_str().to_owned());
                            config.pending_trust = None;
                            save(config, config_path);
                        } else {
                            config.trust = Some(hello.trust.clone());
                        }
                        // Publish the reconciled auth for exec/PTY dispatch.
                        {
                            let effective_trust = if state.managed {
                                hello.trust.clone()
                            } else {
                                local_trust.as_str().to_owned()
                            };
                            let local_observe = effective_trust == Trust::Observe.as_str();
                            let mut snapshot = auth.lock().expect("auth lock");
                            snapshot.trust = effective_trust;
                            snapshot.roots = local_roots.clone();
                            snapshot.owner = config.owner_user_id.clone();
                            snapshot.negotiated_version = negotiated_version;
                            workspace.set_local_observe(local_observe);
                        }
                        let mut interval = tokio::time::interval(Duration::from_millis(
                            hello.heartbeat_interval_ms,
                        ));
                        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                        interval.reset();
                        heartbeat = Some(interval);
                    }
                    ServerFrame::UpgradeRequired { min_version, message } => {
                        let advertised = advertised_protocol();
                        break Err(RelayError::fatal(format!(
                            "This cmux-relay speaks relay protocol v{advertised}, but the server \
                             requires v{min_version} or newer.\n{message}\n\nUpgrade:\n  npx \
                             cmux-relay@latest        # npx fetches the latest release each run\n  \
                             npm i -g cmux-relay@latest   # if you installed it globally"
                        )));
                    }
                    ServerFrame::HeartbeatAck => {}
                    ServerFrame::TrustAck { trust } => {
                        let Some(ack) = Trust::parse(&trust) else { continue };
                        // A trust acknowledgement is only valid as the response to
                        // the exact local reconciliation request. Managed relays
                        // never accept server trust ACKs as local authority because
                        // their session trust is supplied by hello_accepted.
                        if state.managed || config.pending_trust.as_deref() != Some(ack.as_str()) {
                            eprintln!("Ignoring unsolicited trust acknowledgement for {ack}.");
                            continue;
                        }
                        if ack == Trust::Autonomous && !has_yolo_confirmation(config) {
                            config.trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
                            config.pending_trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
                            clear_invalid_yolo_confirmation(config);
                            if !state.managed {
                                save(config, config_path);
                            }
                            let frame = set_trust_frame(DEFAULT_RELAY_TRUST.as_str()).to_string();
                            let _ = send_socket_text(&socket, frame, cancellation).await;
                            workspace.set_local_observe(DEFAULT_RELAY_TRUST == Trust::Observe);
                            eprintln!(
                                "Refused an autonomous trust acknowledgement without this \
                                 machine's local YOLO receipt."
                            );
                            continue;
                        }
                        config.trust = Some(ack.as_str().to_owned());
                        config.pending_trust = None;
                        if ack != Trust::Autonomous {
                            config.yolo_confirmed_at = None;
                        }
                        if !state.managed {
                            save(config, config_path);
                        }
                        auth.lock().expect("auth lock").trust = ack.as_str().to_owned();
                        workspace.set_local_observe(ack == Trust::Observe);
                        println!("Trust level set to {ack}.");
                    }
                    ServerFrame::ActionRequest { action_id, verb, raw } => {
                        // Managed sandbox relays serve terminals, not verbs;
                        // below the exec dialect the server never sends these.
                        if negotiated_version < EXEC_PROTOCOL_VERSION || state.managed {
                            continue;
                        }
                        let snapshot = auth.lock().expect("auth lock").clone();
                        let action = ActionContext {
                            trust: snapshot.trust,
                            local_roots: snapshot.roots,
                            home: runtime.home.clone(),
                            env: scrubbed_env(&runtime.base_env),
                        };
                        let out = out_tx.clone();
                        let pending = Arc::clone(&pending);
                        let action_slots = Arc::clone(&action_slots);
                        let version = raw.get("version").cloned().unwrap_or(Value::from(1));
                        let actor = raw
                            .get("actorId")
                            .and_then(Value::as_str)
                            .unwrap_or("chatmux")
                            .to_owned();
                        let task_cancellation = connection_cancellation.clone();
                        let permit = match action_slots.try_acquire_owned() {
                            Ok(permit) => permit,
                            Err(_) => {
                                let result = serde_json::json!({
                                    "type": "action_result",
                                    "version": version,
                                    "actionId": action_id,
                                    "ok": false,
                                    // `busy` is not a RelayActionErrorCode. Keep the
                                    // retry guidance in the message and use the
                                    // contract's generic retryable failure code.
                                    "code": "failed",
                                    "message": "relay is busy; retry this action",
                                });
                                let size = serde_json::to_string(&result)
                                    .map(|text| text.len() as u64)
                                    .unwrap_or(0);
                                let pending_frame = PendingBytes::new(Arc::clone(&pending), size);
                                let _ = tokio::select! {
                                    biased;
                                    _ = connection_cancellation.cancelled() => Err(()),
                                    result = out.critical_value_with_pending(result, pending_frame) => result,
                                };
                                continue;
                            }
                        };
                        connection_tasks.spawn(async move {
                            let _permit = permit;
                            let result = tokio::select! {
                                biased;
                                _ = task_cancellation.cancelled() => return,
                                result = perform_action(&raw, &action) => result,
                            };
                            let ok = result.get("ok").and_then(Value::as_bool).unwrap_or(false);
                            if ok {
                                println!(
                                    "Ran {verb} for {actor} (action {}).",
                                    action_id.chars().take(8).collect::<String>()
                                );
                            } else {
                                let code =
                                    result.get("code").and_then(Value::as_str).unwrap_or("failed");
                                println!("Refused {verb} ({code}) for {actor}.");
                            }
                            let size = serde_json::to_string(&result)
                                .map(|text| text.len() as u64)
                                .unwrap_or(0);
                            let pending_frame = PendingBytes::new(Arc::clone(&pending), size);
                            let _ = tokio::select! {
                                biased;
                                _ = task_cancellation.cancelled() => Err(()),
                                result = out.critical_value_with_pending(result, pending_frame) => result,
                            };
                        });
                    }
                    ServerFrame::Pty { frame_type, raw } => {
                        if negotiated_version < PTY_PROTOCOL_VERSION {
                            continue;
                        }
                        if frame_type == "pty_open" {
                            let session = raw.get("session").and_then(Value::as_str).unwrap_or("?");
                            let actor =
                                raw.get("actorId").and_then(Value::as_str).unwrap_or("chatmux");
                            println!("Terminal attach to session \"{session}\" for {actor}.");
                        }
                        #[cfg(unix)]
                        {
                            let is_slow =
                                matches!(frame_type.as_str(), "pty_open" | "surface_list");
                            if frame_type == "pty_close" {
                                // Close must always release its attachment, even when the
                                // bounded work queue is saturated. The manager close path is
                                // synchronous and short, so this cannot create an unbounded wait.
                                let snapshot = auth_direct.lock().expect("auth lock").clone();
                                let context = make_context(&out_tx, &pending, &snapshot);
                                tokio::select! {
                                    biased;
                                    _ = cancellation.cancelled() => break Ok(connected),
                                    _ = manager_direct.handle_frame(&raw, &context) => {}
                                }
                                continue;
                            }
                            match pty_tx.try_send(raw) {
                                Ok(()) => {}
                                Err(mpsc::error::TrySendError::Closed(_)) => break Ok(connected),
                                Err(mpsc::error::TrySendError::Full(raw)) => {
                                    // Never silently discard a terminal command. A PTY
                                    // refusal uses the v7 `busy` code only after the
                                    // negotiated feature gate. Surface listing has no
                                    // error response in the wire schema, so close the
                                    // connection instead of fabricating an empty or
                                    // invalid result.
                                    let reply = raw.get("ptyId").and_then(Value::as_str).map(|id| {
                                        serde_json::json!({
                                            "version": PTY_PROTOCOL_VERSION,
                                            "type": "pty_error",
                                            "ptyId": id,
                                            "code": if negotiated_version >= PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION { "busy" } else { "failed" },
                                            "message": if is_slow { "relay is busy; retry this terminal request" } else { "relay is busy; retry this terminal command" },
                                        })
                                    });
                                    if let Some(reply) = reply {
                                        // This response is mandatory. Send it directly so a full
                                        // outbound queue cannot block this loop and stop socket
                                        // ingress from being drained.
                                        let text = reply.to_string();
                                        let sent = socket
                                            .lock()
                                            .await
                                            .send(Message::Text(text.into()))
                                            .await;
                                        if sent.is_err() {
                                            break Ok(connected);
                                        }
                                    } else if raw.get("requestId").is_some() {
                                        eprintln!(
                                            "Closing relay connection because surface_list was rejected by a full ingress queue"
                                        );
                                        break Ok(connected);
                                    }
                                }
                            }
                        }
                        #[cfg(not(unix))]
                        {
                            // Non-Unix relays cannot allocate PTYs; answer typed.
                            let reply = unsupported_platform_pty_reply(&frame_type, &raw);
                            if let Some(reply) = reply {
                                let _ = tokio::select! {
                                    biased;
                                    _ = connection_cancellation.cancelled() => Err(()),
                                    result = out_tx.critical_value(reply) => result,
                                };
                            }
                        }
                    }
                    ServerFrame::Workspace { frame } => {
                        if negotiated_version >= crate::workspace::WORKSPACE_FRAME_VERSION as u64 {
                            let snapshot = auth.lock().expect("auth lock").clone();
                            workspace.set_local_observe(snapshot.trust == "observe");
                            workspace.handle_frame(frame);
                        }
                    }
                    ServerFrame::Error { code, message } => {
                        if code == "unauthorized" || code == "machine_mismatch" {
                            break Err(RelayError::fatal(format!(
                                "The server refused this machine's credential ({code}). The \
                                 pairing may have been replaced or revoked. Re-pair with: npx \
                                 cmux-relay --pair"
                            )));
                        }
                        let suffix = message.map(|text| format!(" — {text}")).unwrap_or_default();
                        eprintln!("Server error: {code}{suffix}");
                    }
                    ServerFrame::Unknown { frame_type } => {
                        if unknown_types.insert(frame_type.clone()) {
                            unknown_type_order.push_back(frame_type.clone());
                            if unknown_type_order.len() > UNKNOWN_TYPE_DIAGNOSTIC_CAP
                                && let Some(evicted) = unknown_type_order.pop_front()
                            {
                                unknown_types.remove(&evicted);
                            }
                            eprintln!(
                                "Ignoring unknown server frame type \"{frame_type}\" (a newer server?)."
                            );
                        }
                    }
                }
            }
        }
        if out_tx.critical_overflowed() {
            break Ok(connected);
        }
    };

    // Drop workspace-owned request/watch tasks before draining the outbound
    // queues. This retires watch tokens and prevents more frames from being
    // admitted while the writer is shutting down.
    drop(workspace);

    // Handlers are owned by this socket. Cancel them before returning so a
    // dropped connection cannot leave work sending into a dead session. A
    // handler may be inside a non-cooperative provider call, so retain a hard
    // deadline for the final await instead of letting reconnect or process
    // shutdown wait forever.
    if !shutdown_connection_tasks(&mut connection_tasks, &connection_cancellation).await {
        eprintln!(
            "Relay connection task shutdown exceeded {CONNECTION_TASK_SHUTDOWN_TIMEOUT:?}; abandoning remaining handlers."
        );
    }

    acknowledge_pending_frames(&mut critical_rx, &mut watch_rx);

    // Attachments die with the socket; sessions persist (docs/TERMINAL.md).
    #[cfg(unix)]
    runtime.pty.detach_all();
    result
}

#[cfg(all(test, not(unix)))]
mod tests {
    use super::*;

    #[test]
    fn unsupported_pty_requests_get_typed_replies() {
        let open =
            unsupported_platform_pty_reply("pty_open", &serde_json::json!({"ptyId": "pty_1"}))
                .expect("pty open refusal");
        assert_eq!(open["type"], "pty_error");
        assert_eq!(open["ptyId"], "pty_1");
        assert_eq!(open["code"], "failed");

        let list = unsupported_platform_pty_reply(
            "surface_list",
            &serde_json::json!({"requestId": "list_1"}),
        )
        .expect("surface list response");
        assert_eq!(list["type"], "surface_list_result");
        assert_eq!(list["requestId"], "list_1");
        assert_eq!(list["surfaces"], serde_json::json!([]));
    }
}

#[cfg(test)]
mod cancellation_tests {
    use super::{shutdown_connection_tasks, wait_for_reconnect};
    use std::time::Duration;

    use tokio::task::JoinSet;
    use tokio_util::sync::CancellationToken;

    #[tokio::test]
    async fn reconnect_backoff_stops_when_process_is_cancelled() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        assert!(!wait_for_reconnect(&cancellation, Duration::from_secs(60)).await);
    }

    #[tokio::test]
    async fn reconnect_backoff_completes_without_cancellation() {
        let cancellation = CancellationToken::new();
        assert!(wait_for_reconnect(&cancellation, Duration::from_millis(1)).await);
    }

    #[tokio::test]
    async fn connection_shutdown_cancels_and_joins_owned_tasks() {
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let mut tasks = JoinSet::new();
        tasks.spawn(async move {
            worker_cancellation.cancelled().await;
        });

        assert!(shutdown_connection_tasks(&mut tasks, &cancellation).await);
        assert!(cancellation.is_cancelled());
        assert!(tasks.is_empty());
    }
}

#[cfg(test)]
mod outbound_tests {
    use super::{OutboundSink, PendingBytes, acknowledge_pending_frames};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

    #[tokio::test]
    async fn accounted_stale_frame_releases_only_its_owned_bytes() {
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let live = Arc::new(AtomicBool::new(true));
        let pending = Arc::new(AtomicU64::new(11));
        let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
        sink.critical_text_with_token_ack_pending(
            "stale".to_owned(),
            Some(Arc::clone(&live)),
            Some(ack_tx),
            PendingBytes::new(Arc::clone(&pending), 5),
        )
        .await
        .expect("queue stale frame");
        assert_eq!(pending.load(Ordering::SeqCst), 16);
        live.store(false, Ordering::Release);
        let mut frame = critical.try_recv().expect("queued critical frame");
        assert!(!frame.is_live());
        frame.acknowledge();
        assert_eq!(pending.load(Ordering::SeqCst), 11);
        assert!(ack_rx.await.is_ok());
        acknowledge_pending_frames(&mut critical, &mut watch);
    }

    #[tokio::test]
    async fn unaccounted_stale_watch_frame_preserves_pending_bytes() {
        let (sink, _critical, mut watch) = OutboundSink::channels();
        let live = Arc::new(AtomicBool::new(true));
        let pending = AtomicU64::new(11);
        sink.try_watch_text_with_token("event".to_owned(), Some(Arc::clone(&live)))
            .expect("queue watch frame");
        live.store(false, Ordering::Release);
        let mut frame = watch.try_recv().expect("queued watch frame");
        assert!(!frame.is_live());
        frame.acknowledge();
        assert_eq!(pending.load(Ordering::SeqCst), 11);
    }

    #[tokio::test]
    async fn shutdown_drain_releases_accounted_frames_before_acknowledging() {
        let (sink, mut critical, mut watch) = OutboundSink::channels();
        let pending = Arc::new(AtomicU64::new(0));
        let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
        sink.critical_text_with_token_ack_pending(
            "eof".to_owned(),
            None,
            Some(ack_tx),
            PendingBytes::new(Arc::clone(&pending), 3),
        )
        .await
        .expect("queue frame");
        acknowledge_pending_frames(&mut critical, &mut watch);
        assert_eq!(pending.load(Ordering::SeqCst), 0);
        assert!(ack_rx.await.is_ok());
    }

    #[tokio::test]
    async fn closed_writer_releases_accounting_on_send_failure() {
        let (sink, critical, _watch) = OutboundSink::channels();
        drop(critical);
        let pending = Arc::new(AtomicU64::new(0));
        let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
        assert!(
            sink.critical_text_with_token_ack_pending(
                "closed".to_owned(),
                None,
                Some(ack_tx),
                PendingBytes::new(Arc::clone(&pending), 6),
            )
            .await
            .is_err()
        );
        assert_eq!(pending.load(Ordering::SeqCst), 0);
        assert!(ack_rx.await.is_ok());
    }
}
