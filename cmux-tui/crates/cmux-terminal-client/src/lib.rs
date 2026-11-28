use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::future::Future;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration as StdDuration, Instant};

use base64::Engine;
use bytes::Bytes;
use cmux_json::JsonSet as _;
use cmux_remote::MuxLineClient;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::{
    ClientIdentityStore, EnrollmentInvitation, KnownDaemon, KnownDaemonAuth,
    credential_free_route_hint,
};
use cmux_remote::provider::{
    ConnectRequest, Dialer, DirectWebSocketProvider, IrohProvider, IrohProviderConfig, OsTcpDialer,
    ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL, TransportProvider, WireGuardDialer,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer, ServiceStream};
use cmux_remote_protocol::{
    Lane, LanePolicy, Service, ServiceControl, SessionId, TERMINAL_BYTES_VIEWER_SIZE_PRIORITY,
    TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED,
};
use cmux_tui_core::apply_terminal_color_overrides;
use cmux_tui_core::resource::{TerminalPublicId, WorkspacePublicId};
use cmux_tui_core::terminal_host_protocol::{
    Frame, FrameDecoder, MAX_FRAME_PAYLOAD, MessageKind, RESIZE_ACK_CANONICAL_CHANGED, encode_frame,
};
use cmux_tui_core::terminal_host_runtime::{
    decode_host_snapshot_payload, decode_terminal_color_overrides,
};
use cmux_wg::{IpNetwork, WgConfig, WgNet};
use ghostty_vt::{
    Callbacks, CellWidth, KeyAction, KeyEncoder, RenderState, Terminal, key_input_from_chord,
};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::runtime::Runtime;
use url::Url;
use zeroize::Zeroizing;

mod route;
mod state;
mod stream;

use route::*;
use stream::*;

const CONNECTION_TIMEOUT_ERROR: &str = "terminal connection timed out";
const INVALID_OPENED: &str = "terminal service returned an invalid Opened acknowledgement";
/// Service rejection code a daemon returns for unknown open metadata.
const INVALID_ARGUMENT: &str = "invalid-argument";
/// A dropped terminal stream is opened again on this back-off for as long as its connection may
/// still carry it: a slow or dropped link is never a count of tries. It ends when the daemon no
/// longer has the session, when the connection's reader failed for good, or when the daemon has
/// refused the open this many times in a row (the terminal is gone; a daemon still restoring it
/// gets the back-off's first ~20 s). Leo, 2026-11-24: "let's just keep optimistically connecting
/// and reinforcing the connection".
const TERMINAL_REOPEN_REFUSALS: u32 = 8;
const TERMINAL_RECONNECT_INITIAL_DELAY: StdDuration = StdDuration::from_millis(250);
const TERMINAL_RECONNECT_MAX_DELAY: StdDuration = StdDuration::from_secs(4);

pub struct CmuxTerminalClient {
    runtime: Runtime,
    connection: Arc<ClientConnection>,
    transport: ClientTransport,
    multiplexer: Arc<ServiceMultiplexer>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
    raw_output: Arc<RawOutput>,
    terminal: Mutex<Option<ActiveTerminal>>,
    mux: tokio::sync::Mutex<Option<Arc<MuxLineClient>>>,
    next_request: AtomicU64,
    /// Read when an attach begins; see `TerminalOpenOptions`.
    viewer_size_priority: AtomicBool,
    viewer_size_priority_unsupported: Arc<AtomicBool>,
}

/// The carrier a client was connected over. Iroh owns an endpoint that must
/// be closed; a direct WebSocket provider owns nothing past its links.
enum ClientTransport {
    Iroh(Arc<IrohProvider>),
    Direct(Arc<DirectWebSocketProvider>),
}

impl ClientTransport {
    async fn close(&self) {
        match self {
            Self::Iroh(provider) => provider.close().await,
            Self::Direct(_) => {}
        }
    }
}

/// An in-process WireGuard tunnel shared by any number of clients. The
/// driver runs on its own runtime so a client's runtime can be torn down
/// without stopping the tunnel other clients still use.
pub struct CmuxWireGuardNet {
    _runtime: Runtime,
    net: Arc<WgNet>,
}

/// Raw terminal output delivered to an embedding renderer instead of being
/// decoded into text frames here.
///
/// `kind` is one of the `CMUX_TERMINAL_OUTPUT_*` constants in the header:
/// `1` snapshot (the replay bytes for a fresh parser sized `cols` x `rows`),
/// `2` output bytes, `3` resize (`cols` x `rows`, no bytes), `4` exit.
type TerminalOutputCallback = unsafe extern "C" fn(*mut c_void, u32, *const u8, usize, u16, u16);

const OUTPUT_KIND_SNAPSHOT: u32 = 1;
const OUTPUT_KIND_OUTPUT: u32 = 2;
const OUTPUT_KIND_RESIZED: u32 = 3;
const OUTPUT_KIND_EXIT: u32 = 4;

#[derive(Clone, Copy)]
struct OutputCallbackRegistration {
    callback: TerminalOutputCallback,
    context: usize,
}

#[derive(Default)]
struct RawOutput {
    callback: Mutex<Option<OutputCallbackRegistration>>,
}

impl RawOutput {
    fn set_callback(&self, callback: Option<TerminalOutputCallback>, context: *mut c_void) {
        *self.callback.lock().unwrap() = callback
            .map(|callback| OutputCallbackRegistration { callback, context: context as usize });
    }

    fn is_installed(&self) -> bool {
        self.callback.lock().unwrap().is_some()
    }

    fn emit(&self, event: &RawEvent) {
        let registered = self.callback.lock().unwrap();
        let Some(registered) = *registered else {
            return;
        };
        let (kind, bytes, cols, rows): (u32, &[u8], u16, u16) = match event {
            RawEvent::Snapshot { cols, rows, replay } => {
                (OUTPUT_KIND_SNAPSHOT, replay.as_slice(), *cols, *rows)
            }
            RawEvent::Output(bytes) => (OUTPUT_KIND_OUTPUT, bytes.as_ref(), 0, 0),
            RawEvent::Resized { cols, rows } => (OUTPUT_KIND_RESIZED, &[], *cols, *rows),
            RawEvent::Exit => (OUTPUT_KIND_EXIT, &[], 0, 0),
        };
        // SAFETY: the FFI caller owns the callback context; the registration
        // mutex is held across the invocation so removal waits for it, which
        // is what lets the embedder release `context` once `set_callback`
        // returns. The cost is that the callback cannot re-enter
        // `set_callback` (it would deadlock on this mutex), which the header
        // states. Releasing the guard first would make re-entry legal but
        // would let a concurrent clear return while a callback is still
        // running, so the embedder could free `context` under it.
        unsafe {
            (registered.callback)(
                registered.context as *mut c_void,
                kind,
                bytes.as_ptr(),
                bytes.len(),
                cols,
                rows,
            );
        };
    }
}

#[derive(Debug)]
enum RawEvent {
    Snapshot { cols: u16, rows: u16, replay: Vec<u8> },
    Output(Bytes),
    Resized { cols: u16, rows: u16 },
    Exit,
}

type TerminalUpdateCallback = unsafe extern "C" fn(*mut c_void);

#[derive(Clone, Copy)]
struct UpdateCallbackRegistration {
    callback: TerminalUpdateCallback,
    context: usize,
}

#[derive(Default)]
struct ClientUpdates {
    callback: Mutex<Option<UpdateCallbackRegistration>>,
}

impl ClientUpdates {
    fn set_callback(&self, callback: Option<TerminalUpdateCallback>, context: *mut c_void) {
        let mut registered = self.callback.lock().unwrap();
        *registered = callback
            .map(|callback| UpdateCallbackRegistration { callback, context: context as usize });
        if let Some(registered) = *registered {
            // SAFETY: the FFI caller owns the callback context and the callback
            // mutex makes replacement/removal wait for any invocation to finish.
            unsafe { (registered.callback)(registered.context as *mut c_void) };
        }
    }

    fn notify(&self) {
        let registered = self.callback.lock().unwrap();
        if let Some(registered) = *registered {
            // SAFETY: set_callback documents the context lifetime contract and
            // holds this same mutex across invocation and synchronous removal.
            unsafe { (registered.callback)(registered.context as *mut c_void) };
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ResizeRequest {
    request_id: u64,
    cols: u16,
    rows: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ResizeAcknowledgement {
    request_id: u64,
    cols: u16,
    rows: u16,
    canonical_changed: bool,
}

#[derive(Default)]
struct ResizeDelivery {
    desired: Mutex<Option<ResizeRequest>>,
    acknowledged_request: AtomicU64,
    changed: tokio::sync::Notify,
}

impl ResizeDelivery {
    fn request(&self, request: ResizeRequest) {
        *self.desired.lock().unwrap() = Some(request);
        self.changed.notify_one();
    }

    fn desired(&self) -> Option<ResizeRequest> {
        *self.desired.lock().unwrap()
    }

    fn acknowledge(&self, request_id: u64) {
        self.acknowledged_request.store(request_id, Ordering::Release);
        self.changed.notify_one();
    }

    fn is_acknowledged(&self, request_id: u64) -> bool {
        self.acknowledged_request.load(Ordering::Acquire) == request_id
    }

    fn complete_if_current(&self, request_id: u64) {
        let mut desired = self.desired.lock().unwrap();
        if desired.is_some_and(|request| request.request_id == request_id) {
            *desired = None;
        }
    }
}

struct ActiveTerminal {
    terminal_id: TerminalPublicId,
    streams: tokio::sync::watch::Sender<Option<Arc<ServiceStream>>>,
    closed: Arc<AtomicBool>,
    close_notify: Arc<tokio::sync::Notify>,
    command_sender: tokio::sync::mpsc::Sender<Bytes>,
    resize_delivery: Arc<ResizeDelivery>,
    receiver_task: tokio::task::JoinHandle<()>,
    command_task: tokio::task::JoinHandle<()>,
    resize_task: tokio::task::JoinHandle<()>,
}

impl ActiveTerminal {
    async fn close(self) {
        self.closed.store(true, Ordering::Release);
        self.close_notify.notify_waiters();
        self.receiver_task.abort();
        self.command_task.abort();
        self.resize_task.abort();
        let stream = self.streams.send_replace(None);
        let _ = self.command_task.await;
        let _ = self.resize_task.await;
        if let Some(stream) = stream {
            let _ = stream.close().await;
        }
        let _ = self.receiver_task.await;
    }
}

struct ClientState {
    /// Deliver bytes to the embedding renderer instead of a local parser.
    raw_mode: bool,
    terminal: Option<Terminal>,
    key_encoder: KeyEncoder,
    render: RenderState,
    frame_text: String,
    frame_rows: Vec<String>,
    frame_dirty_rows: Vec<u16>,
    render_dirty: bool,
    status: String,
    transport_provider: String,
    transport_path: String,
    generation: u64,
    terminal_id: TerminalPublicId,
    snapshot_boundary: u64,
    snapshot_applied: bool,
    snapshot_bytes: u64,
    bootstrap_frames: u64,
    bootstrap_committed: bool,
    ready: bool,
    exited: bool,
    raw_bytes: u64,
    raw_frames: u64,
    local_parser_cursor: u64,
    source_cursor: u64,
    resync_count: u64,
    expected_sequence: Option<u64>,
    cols: u16,
    rows: u16,
    cell_pixels: (u16, u16),
    resize_delivery: Option<Arc<ResizeDelivery>>,
    resize_acknowledgement: Option<ResizeAcknowledgement>,
}

#[derive(Serialize)]
struct Diagnostics<'a> {
    carrier: &'a str,
    path: &'a str,
    generation: u64,
    terminal: &'a str,
    service: &'static str,
    status: &'a str,
    snapshot_boundary: u64,
    snapshot_bytes: u64,
    bootstrap_frames: u64,
    ready: bool,
    raw_bytes: u64,
    raw_frames: u64,
    local_parser_cursor: u64,
    source_cursor: u64,
    resync_count: u64,
    server_snapshot_rpc_count: u64,
    cols: u16,
    rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FrameEffect {
    Continue,
    Restart,
    Stop,
}

/// Terminal-open choices fixed when an attach begins, like raw output
/// delivery, so every reconnect of that attachment repeats them.
#[derive(Clone, Default)]
struct TerminalOpenOptions {
    viewer_size_priority: bool,
    /// Shared by the client's attachments: set once its daemon rejects the
    /// priority metadata key, so later opens skip the extra round trip.
    priority_unsupported: Arc<AtomicBool>,
}

enum TerminalOpenError {
    Rejected { code: String, message: String },
    Failed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamOutcome {
    Restart,
    Stop,
}

struct TerminalStreamSupervisor {
    multiplexer: Arc<ServiceMultiplexer>,
    terminal_id: TerminalPublicId,
    initial_stream: Arc<ServiceStream>,
    streams: tokio::sync::watch::Sender<Option<Arc<ServiceStream>>>,
    closed: Arc<AtomicBool>,
    close_notify: Arc<tokio::sync::Notify>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
    raw_output: Arc<RawOutput>,
    open_options: TerminalOpenOptions,
}

impl CmuxTerminalClient {
    fn attach_terminal(
        &self,
        terminal_id: TerminalPublicId,
        timeout: Option<StdDuration>,
    ) -> Result<(), String> {
        let mut terminal = self.terminal.lock().unwrap();
        if attach_target_already_satisfied(
            terminal
                .as_ref()
                .map(|active| (&active.terminal_id, active.closed.load(Ordering::Acquire))),
            &terminal_id,
        )? {
            return Ok(());
        }
        if let Some(stale) = terminal.take() {
            self.runtime.block_on(stale.close());
        }
        // Viewer-size priority, like the delivery mode below, is fixed per
        // attach and repeated by every reconnect of this attachment.
        let open_options = TerminalOpenOptions {
            viewer_size_priority: self.viewer_size_priority.load(Ordering::Acquire),
            priority_unsupported: self.viewer_size_priority_unsupported.clone(),
        };
        let stream = self.runtime.block_on(open_terminal_stream_with_timeout(
            &self.multiplexer,
            &terminal_id,
            &open_options,
            timeout,
        ))?;
        let snapshot = self.runtime.block_on(self.connection.snapshot());
        let path = snapshot
            .transport
            .selected_path
            .as_ref()
            .map(|path| format!("{:?}", path.kind).to_lowercase())
            .unwrap_or_else(|| snapshot.transport.route.clone());
        let mut next_state = match ClientState::new(
            snapshot.transport.provider,
            path,
            snapshot.generation,
            terminal_id.clone(),
        ) {
            Ok(state) => state,
            Err(error) => {
                self.runtime.block_on(async {
                    let _ = stream.close().await;
                });
                return Err(error);
            }
        };
        // The delivery mode is fixed per attach: a renderer that installs its
        // callback after the snapshot would miss the replay.
        next_state.raw_mode = self.raw_output.is_installed();
        *self.state.lock().unwrap() = next_state;
        self.updates.notify();
        *terminal = Some(start_terminal_tasks(
            &self.runtime,
            stream,
            self.multiplexer.clone(),
            terminal_id,
            self.state.clone(),
            self.updates.clone(),
            self.raw_output.clone(),
            open_options,
        ));
        Ok(())
    }

    fn detach_terminal(&self) {
        let terminal = self.terminal.lock().unwrap().take();
        if let Some(terminal) = terminal {
            self.runtime.block_on(terminal.close());
        }
        let mut state = self.state.lock().unwrap();
        state.bootstrap_committed = false;
        state.ready = false;
        state.exited = false;
        state.resize_delivery = None;
        state.resize_acknowledgement = None;
        state.status = "detached".into();
        drop(state);
        self.updates.notify();
    }
}

fn attach_target_already_satisfied(
    attached: Option<(&TerminalPublicId, bool)>,
    requested: &TerminalPublicId,
) -> Result<bool, String> {
    let Some((attached, closed)) = attached else {
        return Ok(false);
    };
    if attached == requested {
        return Ok(!closed);
    }
    Err(format!("terminal {attached} is already attached; detach it before attaching {requested}"))
}

fn copy_utf8(value: &str, buffer: *mut c_char, capacity: usize) -> usize {
    if !buffer.is_null() && capacity > 0 {
        let mut count = value.len().min(capacity - 1);
        while !value.is_char_boundary(count) {
            count -= 1;
        }
        // SAFETY: the caller promises `capacity` writable bytes. We copy at
        // most capacity - 1 and then write the terminator inside that range.
        unsafe {
            std::ptr::copy_nonoverlapping(value.as_ptr(), buffer.cast::<u8>(), count);
            *buffer.add(count) = 0;
        }
    }
    value.len()
}

fn enqueue_command(client: &CmuxTerminalClient, frame: Frame) -> bool {
    let Ok(encoded) = encode_frame(&frame) else {
        return false;
    };
    let terminal = client.terminal.lock().unwrap();
    let Some(terminal) = terminal.as_ref() else {
        return false;
    };
    if terminal.closed.load(Ordering::Acquire) {
        return false;
    }
    terminal.command_sender.try_send(Bytes::from(encoded)).is_ok()
}

unsafe fn terminal_id_from_ffi(terminal_id: *const c_char) -> Result<TerminalPublicId, String> {
    if terminal_id.is_null() {
        return Err("terminal ID is null".into());
    }
    // SAFETY: the C API requires a readable NUL-terminated terminal ID.
    let terminal_id = unsafe { CStr::from_ptr(terminal_id) }
        .to_str()
        .map_err(|error| format!("terminal ID is not UTF-8: {error}"))?;
    TerminalPublicId::parse(terminal_id.to_owned())
        .map_err(|error| format!("terminal ID is invalid: {error}"))
}

async fn connect_with_timeout<T>(
    future: impl Future<Output = Result<T, String>>,
    timeout: StdDuration,
) -> Result<T, String> {
    tokio::time::timeout(timeout, future).await.map_err(|_| {
        format!("{CONNECTION_TIMEOUT_ERROR}: no connection within {} ms", timeout.as_millis())
    })?
}

/// The connect deadline when the caller names none (the untimed entry point, or a timeout of 0):
/// one reconnect attempt for an enrolled or carrier connect, and the daemon's approval window on
/// top of that for an invitation, whose welcome waits on a person. A connect had no deadline at
/// all here before, so a carrier that accepted and never answered (a WireGuard tunnel whose first
/// handshake never completes, a socket black-holed mid-open) held the embedding app's call forever.
fn default_connect_timeout(invitation: bool) -> StdDuration {
    let attempt = ReconnectPolicy::default().attempt_timeout;
    if invitation { attempt + cmux_remote::identity::APPROVAL_TIMEOUT } else { attempt }
}

unsafe fn connect_terminal_client(
    invitation_uri: *const c_char,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout: Option<StdDuration>,
) -> *mut CmuxTerminalClient {
    if invitation_uri.is_null() {
        copy_utf8("invitation URI is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: checked non-null above; the C API requires a NUL-terminated URI.
    let invitation = unsafe { CStr::from_ptr(invitation_uri) };
    let invitation = match invitation.to_str() {
        Ok(value) => value,
        Err(error) => {
            copy_utf8(
                &format!("invitation URI is not UTF-8: {error}"),
                error_buffer,
                error_capacity,
            );
            return std::ptr::null_mut();
        }
    };
    let terminal_id = match unsafe { terminal_id_from_ffi(terminal_id) } {
        Ok(terminal_id) => terminal_id,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            copy_utf8(&error.to_string(), error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    // This entry point always enrolls with an invitation.
    let timeout = timeout.unwrap_or_else(|| default_connect_timeout(true));
    let connection = runtime
        .block_on(connect_with_timeout(connect_client(invitation, terminal_id.clone()), timeout));
    match connection {
        Ok((stream, connection, provider, multiplexer, state)) => {
            let updates = Arc::new(ClientUpdates::default());
            let raw_output = Arc::new(RawOutput::default());
            spawn_diagnostics(&runtime, &connection, &state, &updates);
            let terminal = start_terminal_tasks(
                &runtime,
                stream,
                multiplexer.clone(),
                terminal_id,
                state.clone(),
                updates.clone(),
                raw_output.clone(),
                TerminalOpenOptions::default(),
            );
            Box::into_raw(Box::new(CmuxTerminalClient {
                runtime,
                connection,
                transport: ClientTransport::Iroh(provider),
                multiplexer,
                state,
                updates,
                raw_output,
                terminal: Mutex::new(Some(terminal)),
                mux: tokio::sync::Mutex::new(None),
                next_request: AtomicU64::new(1),
                viewer_size_priority: AtomicBool::new(false),
                viewer_size_priority_unsupported: Arc::default(),
            }))
        }
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Connects a terminal client and returns an owning handle, or null on failure.
/// The connect ends with an error after the default deadline: one reconnect
/// attempt plus the daemon's approval window, since this always enrolls.
///
/// # Safety
///
/// `invitation_uri` must point to a readable NUL-terminated byte string for the
/// duration of this call. `error_buffer` may be null; otherwise, when
/// `error_capacity` is nonzero, it must point to `error_capacity` writable
/// bytes. A non-null returned handle must eventually be passed exactly once to
/// [`cmux_terminal_client_disconnect`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_connect(
    invitation_uri: *const c_char,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> *mut CmuxTerminalClient {
    // SAFETY: this function forwards its documented pointer contract unchanged.
    unsafe {
        connect_terminal_client(invitation_uri, terminal_id, error_buffer, error_capacity, None)
    }
}

/// Connects a terminal client and cancels the underlying enrollment future
/// when `timeout_milliseconds` elapses.
///
/// # Safety
///
/// The pointer and ownership contract matches [`cmux_terminal_client_connect`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_connect_with_timeout(
    invitation_uri: *const c_char,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut CmuxTerminalClient {
    // SAFETY: this function forwards its documented pointer contract unchanged.
    unsafe {
        connect_terminal_client(
            invitation_uri,
            terminal_id,
            error_buffer,
            error_capacity,
            Some(StdDuration::from_millis(timeout_milliseconds)),
        )
    }
}

/// Reopens the terminal service on an already enrolled transport.
///
/// # Safety
///
/// `client` must be a live handle returned by
/// [`cmux_terminal_client_connect`]. `error_buffer` follows the same writable
/// buffer contract as the connect function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_attach(
    client: *mut CmuxTerminalClient,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> bool {
    // SAFETY: this function forwards its documented pointer contract unchanged.
    unsafe { attach_terminal_client(client, terminal_id, error_buffer, error_capacity, None) }
}

/// Reopens the terminal service with a deadline on an already enrolled transport.
///
/// # Safety
///
/// The pointer and ownership contract matches [`cmux_terminal_client_attach`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_attach_with_timeout(
    client: *mut CmuxTerminalClient,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> bool {
    // SAFETY: this function forwards its documented pointer contract unchanged.
    unsafe {
        attach_terminal_client(
            client,
            terminal_id,
            error_buffer,
            error_capacity,
            Some(StdDuration::from_millis(timeout_milliseconds)),
        )
    }
}

unsafe fn attach_terminal_client(
    client: *mut CmuxTerminalClient,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout: Option<StdDuration>,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        copy_utf8("terminal client is null", error_buffer, error_capacity);
        return false;
    };
    let terminal_id = match unsafe { terminal_id_from_ffi(terminal_id) } {
        Ok(terminal_id) => terminal_id,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return false;
        }
    };
    match client.attach_terminal(terminal_id, timeout) {
        Ok(()) => true,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            false
        }
    }
}

/// Closes only the terminal service while retaining the enrolled transport.
///
/// # Safety
///
/// `client` must be null or a live handle returned by
/// [`cmux_terminal_client_connect`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_detach(client: *mut CmuxTerminalClient) {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return;
    };
    client.detach_terminal();
}

/// Registers a lightweight notification invoked whenever frame or diagnostic
/// state changes. Passing null clears the callback synchronously.
///
/// # Safety
///
/// `client` must be null or a live handle returned by
/// [`cmux_terminal_client_connect`]. While registered, `context` must remain
/// valid for every callback invocation. Clearing the callback waits for any
/// invocation already in progress before returning. The callback runs while
/// the registration is locked and must not call any terminal-client API.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_set_update_callback(
    client: *mut CmuxTerminalClient,
    callback: Option<TerminalUpdateCallback>,
    context: *mut c_void,
) {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return;
    };
    client.updates.set_callback(callback, context);
}

/// Disconnects and consumes an owning terminal client handle.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`] that has not already been disconnected. The
/// caller must prevent concurrent calls that use the handle and must not use it
/// again after this function begins.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_disconnect(client: *mut CmuxTerminalClient) {
    if client.is_null() {
        return;
    }
    // SAFETY: ownership of a pointer returned by connect transfers exactly once.
    let client = unsafe { Box::from_raw(client) };
    client.updates.set_callback(None, std::ptr::null_mut());
    client.raw_output.set_callback(None, std::ptr::null_mut());
    // Connection teardown may wait on the carrier. Transfer ownership to a
    // background thread so the C call is nonblocking for AppKit.
    let _ = std::thread::Builder::new().name("cmux-terminal-disconnect".into()).spawn(move || {
        let terminal = client.terminal.lock().unwrap().take();
        client.runtime.block_on(async {
            if let Some(terminal) = terminal {
                terminal.close().await;
            }
            if let Some(mux) = client.mux.lock().await.take() {
                let _ = mux.close().await;
            }
            client.multiplexer.shutdown().await;
            let _ = client.connection.close().await;
            client.transport.close().await;
        });
    });
}

unsafe fn bytes_from_ffi<'a>(bytes: *const u8, length: usize) -> Option<&'a [u8]> {
    if length == 0 {
        return Some(&[]);
    }
    if bytes.is_null() {
        return None;
    }
    // SAFETY: the C caller promises `length` readable bytes.
    Some(unsafe { std::slice::from_raw_parts(bytes, length) })
}

/// Queues raw terminal input bytes for the connected terminal.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call. When `length` is nonzero, `bytes` must point to `length` readable
/// bytes for the duration of this call; when `length` is zero, `bytes` may be
/// null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_send(
    client: *mut CmuxTerminalClient,
    bytes: *const u8,
    length: usize,
) -> bool {
    // SAFETY: forwarded C buffer contract is validated by bytes_from_ffi.
    let Some((client, bytes)) =
        (unsafe { client.as_ref() }).zip(unsafe { bytes_from_ffi(bytes, length) })
    else {
        return false;
    };
    enqueue_command(client, Frame::new(MessageKind::Input, bytes.to_vec()))
}

/// Encodes a named key chord with the local libghostty terminal modes and
/// queues the resulting PTY input.
///
/// # Safety
///
/// `client` must be a live handle returned by
/// [`cmux_terminal_client_connect`]. `chord` must point to a readable
/// NUL-terminated UTF-8 string for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_send_key(
    client: *mut CmuxTerminalClient,
    chord: *const c_char,
    repeat: bool,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return false;
    };
    if chord.is_null() {
        return false;
    }
    // SAFETY: checked non-null above; the C API requires a NUL-terminated chord.
    let chord = unsafe { CStr::from_ptr(chord) };
    let chord = match chord.to_str() {
        Ok(chord) => chord,
        Err(error) => {
            client.state.lock().unwrap().status = format!("key: {error}");
            client.updates.notify();
            return false;
        }
    };
    let key_result = client.state.lock().unwrap().encode_key(chord, repeat);
    let encoded = match key_result {
        Ok(encoded) => encoded,
        Err(error) => {
            client.state.lock().unwrap().status = format!("key: {error}");
            client.updates.notify();
            return false;
        }
    };
    if encoded.is_empty() {
        return true;
    }
    enqueue_command(client, Frame::new(MessageKind::Input, encoded))
}

/// Queues opaque paste bytes for the connected terminal.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call. When `length` is nonzero, `bytes` must point to `length` readable
/// bytes for the duration of this call; when `length` is zero, `bytes` may be
/// null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_paste(
    client: *mut CmuxTerminalClient,
    bytes: *const u8,
    length: usize,
) -> bool {
    // SAFETY: forwarded C buffer contract is validated by bytes_from_ffi.
    let Some((client, bytes)) =
        (unsafe { client.as_ref() }).zip(unsafe { bytes_from_ffi(bytes, length) })
    else {
        return false;
    };
    enqueue_command(client, Frame::new(MessageKind::Paste, bytes.to_vec()))
}

/// Queues a terminal viewport resize.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_resize(
    client: *mut CmuxTerminalClient,
    cols: u16,
    rows: u16,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return false;
    };
    queue_resize(client, cols, rows).is_some()
}

/// Queues a coalesced viewport resize and returns its protocol request ID.
///
/// # Safety
///
/// `client` follows [`cmux_terminal_client_resize`]'s pointer contract.
/// `request_id` must be non-null and writable for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_resize_with_request_id(
    client: *mut CmuxTerminalClient,
    cols: u16,
    rows: u16,
    request_id: *mut u64,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return false;
    };
    if request_id.is_null() {
        return false;
    }
    let Some(queued_request_id) = queue_resize(client, cols, rows) else {
        return false;
    };
    // SAFETY: the output was checked non-null, and the caller promises writable
    // storage for the duration of this call.
    unsafe { request_id.write(queued_request_id) };
    true
}

fn queue_resize(client: &CmuxTerminalClient, cols: u16, rows: u16) -> Option<u64> {
    let terminal = client.terminal.lock().unwrap();
    let terminal = terminal.as_ref()?;
    if terminal.closed.load(Ordering::Acquire) {
        return None;
    }
    let request_id = client.next_request.fetch_add(1, Ordering::Relaxed);
    if request_id == 0 {
        return None;
    }
    terminal.resize_delivery.request(ResizeRequest {
        request_id,
        cols: cols.max(1),
        rows: rows.max(1),
    });
    Some(request_id)
}

/// Copies the newest acknowledged terminal resize into caller-owned outputs.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call. Every output pointer must be non-null and writable for its value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_last_resize_ack(
    client: *const CmuxTerminalClient,
    request_id: *mut u64,
    cols: *mut u16,
    rows: *mut u16,
    canonical_changed: *mut bool,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return false;
    };
    if request_id.is_null() || cols.is_null() || rows.is_null() || canonical_changed.is_null() {
        return false;
    }
    let state = client.state.lock().unwrap();
    let Some(acknowledgement) = state.resize_acknowledgement else {
        return false;
    };
    // SAFETY: all outputs were checked non-null, and the caller promises each
    // points to writable storage for the duration of this call.
    unsafe {
        request_id.write(acknowledgement.request_id);
        cols.write(acknowledgement.cols);
        rows.write(acknowledgement.rows);
        canonical_changed.write(acknowledgement.canonical_changed);
    }
    true
}

/// Copies the latest rendered frame as a NUL-terminated UTF-8 string.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call. `buffer` may be null; otherwise, when `capacity` is nonzero, it
/// must point to `capacity` writable bytes that do not overlap memory owned by
/// `client`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_copy_frame(
    client: *const CmuxTerminalClient,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return 0;
    };
    let mut state = client.state.lock().unwrap();
    if let Err(error) = state.materialize_frame() {
        state.status = format!("render: {error}");
    }
    copy_utf8(&state.frame_text, buffer, capacity)
}

/// Copies the row indexes changed by the latest materialized frame. A null
/// buffer or undersized capacity returns the required number of entries.
///
/// # Safety
///
/// The client pointer may be null. A non-null value must be a live handle
/// returned by cmux_terminal_client_connect, and it must not be disconnected
/// during this call. The buffer pointer may be null; otherwise, when capacity is
/// nonzero, it must point to capacity writable u16 values that do not overlap
/// memory owned by the client.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_copy_frame_dirty_rows(
    client: *const CmuxTerminalClient,
    buffer: *mut u16,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return 0;
    };
    let mut state = client.state.lock().unwrap();
    if let Err(error) = state.materialize_frame() {
        state.status = format!("render: {error}");
    }
    let required = state.frame_dirty_rows.len();
    if buffer.is_null() || capacity < required {
        return required;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(state.frame_dirty_rows.as_ptr(), buffer, required);
    }
    required
}

/// Returns the number of rows in the latest materialized viewport frame.
///
/// # Safety
///
/// The client pointer may be null. A non-null value must be a live handle
/// returned by cmux_terminal_client_connect, and it must not be disconnected
/// during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_frame_row_count(
    client: *const CmuxTerminalClient,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return 0;
    };
    let mut state = client.state.lock().unwrap();
    if let Err(error) = state.materialize_frame() {
        state.status = format!("render: {error}");
    }
    state.frame_rows.len()
}

/// Copies one row from the latest materialized frame as a NUL-terminated
/// UTF-8 string. The row index is zero-based.
///
/// # Safety
///
/// The client pointer may be null. A non-null value must be a live handle
/// returned by cmux_terminal_client_connect, and it must not be disconnected
/// during this call. The buffer pointer may be null; otherwise, when capacity is
/// nonzero, it must point to capacity writable bytes that do not overlap memory
/// owned by the client.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_copy_frame_row(
    client: *const CmuxTerminalClient,
    row: u16,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return 0;
    };
    let mut state = client.state.lock().unwrap();
    if let Err(error) = state.materialize_frame() {
        state.status = format!("render: {error}");
    }
    state.frame_rows.get(row as usize).map(|value| copy_utf8(value, buffer, capacity)).unwrap_or(0)
}

/// Copies current client diagnostics as a NUL-terminated UTF-8 string.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call. `buffer` may be null; otherwise, when `capacity` is nonzero, it
/// must point to `capacity` writable bytes that do not overlap memory owned by
/// `client`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_copy_diagnostics(
    client: *const CmuxTerminalClient,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return 0;
    };
    copy_utf8(&client.state.lock().unwrap().diagnostics(), buffer, capacity)
}

/// Returns whether the attached PTY has exited.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by
/// [`cmux_terminal_client_connect`], and it must not be disconnected during
/// this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_has_exited(
    client: *const CmuxTerminalClient,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return false;
    };
    client.state.lock().unwrap().exited
}

/// Keep the diagnostics snapshot current across carrier generations.
fn spawn_diagnostics(
    runtime: &Runtime,
    connection: &Arc<ClientConnection>,
    state: &Arc<Mutex<ClientState>>,
    updates: &Arc<ClientUpdates>,
) {
    let connection = connection.clone();
    let state = state.clone();
    let updates = updates.clone();
    let mut generation = connection.subscribe_generation();
    runtime.spawn(async move {
        while generation.changed().await.is_ok() {
            let snapshot = connection.snapshot().await;
            let path = snapshot
                .transport
                .selected_path
                .as_ref()
                .map(|path| format!("{:?}", path.kind).to_lowercase())
                .unwrap_or_else(|| snapshot.transport.route.clone());
            let mut state = state.lock().unwrap();
            state.transport_provider = snapshot.transport.provider;
            state.transport_path = path;
            state.generation = snapshot.generation;
            drop(state);
            updates.notify();
        }
    });
}

/// Placeholder for a client that has not attached a terminal yet.
fn unattached_terminal_id() -> TerminalPublicId {
    TerminalPublicId::parse("term_00000000000000000000000000000000")
        .expect("placeholder terminal id is well-formed")
}

/// Largest carrier frame on a direct WebSocket route; matches the sidecar.
const DIRECT_ROUTE_MAX_FRAME_BYTES: usize = 65_535;

struct RouteConnectOptions<'a> {
    route: &'a str,
    state_dir: &'a Path,
    device_name: &'a str,
    invitation_uri: Option<&'a str>,
    trusted_carrier: bool,
    wireguard: Option<Arc<WgNet>>,
}

struct RouteConnection {
    transport: ClientTransport,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    state: Arc<Mutex<ClientState>>,
}

unsafe fn optional_str_from_ffi<'a>(
    value: *const c_char,
    what: &str,
) -> Result<Option<&'a str>, String> {
    if value.is_null() {
        return Ok(None);
    }
    // SAFETY: checked non-null; the C API requires a NUL-terminated string.
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(Some)
        .map_err(|error| format!("{what} is not UTF-8: {error}"))
}

unsafe fn required_str_from_ffi<'a>(value: *const c_char, what: &str) -> Result<&'a str, String> {
    // SAFETY: forwards the documented pointer contract.
    unsafe { optional_str_from_ffi(value, what) }?.ok_or_else(|| format!("{what} is null"))
}

/// Connects to a daemon by route with a persistent device identity.
///
/// `route` is `ws://`, `wss://`, or `iroh://`. `state_dir` holds this device's
/// key and the daemons it has enrolled with (created 0700 when missing).
/// `invitation_uri` enrolls on first contact and may be NULL afterwards, when
/// the enrolled key is used. `wireguard` may be NULL; when set, addresses
/// inside that tunnel's routes are dialed through it. `timeout_milliseconds`
/// of zero means the default deadline: one reconnect attempt (15 s), plus the
/// daemon's approval window (5 min) when enrolling with an invitation. No terminal is attached; call
/// [`cmux_terminal_client_attach`] after installing an output callback.
///
/// # Safety
///
/// String arguments must be NUL-terminated and readable for the call.
/// `wireguard` must be null or a live handle from [`cmux_wireguard_net_start`]
/// that outlives every client using it. `error_buffer` follows the connect
/// buffer contract. A non-null result is owned and must be passed exactly
/// once to [`cmux_terminal_client_disconnect`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_connect_route(
    route: *const c_char,
    state_dir: *const c_char,
    device_name: *const c_char,
    invitation_uri: *const c_char,
    wireguard: *const CmuxWireGuardNet,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut CmuxTerminalClient {
    // SAFETY: forwards the documented pointer and ownership contract.
    unsafe {
        connect_route_from_ffi(
            route,
            state_dir,
            device_name,
            invitation_uri,
            false,
            wireguard,
            error_buffer,
            error_capacity,
            timeout_milliseconds,
        )
    }
}

/// Connects using a Cloud server's explicit private-tunnel trust grant.
/// The route must be a literal WebSocket IP covered by `wireguard`, which
/// must be non-null. No invitation or prior daemon enrollment is required.
/// The original route entrypoint retains its enrolled-device semantics.
///
/// # Safety
///
/// The strings, live tunnel handle, error buffer and returned client obey the
/// same contract as [`cmux_terminal_client_connect_route`]. The caller must
/// select this entrypoint only after the authenticated Cloud API opts in.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_connect_trusted_route(
    route: *const c_char,
    state_dir: *const c_char,
    device_name: *const c_char,
    wireguard: *const CmuxWireGuardNet,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut CmuxTerminalClient {
    // SAFETY: forwards the documented pointer and ownership contract.
    unsafe {
        connect_route_from_ffi(
            route,
            state_dir,
            device_name,
            std::ptr::null(),
            true,
            wireguard,
            error_buffer,
            error_capacity,
            timeout_milliseconds,
        )
    }
}

#[allow(clippy::too_many_arguments)]
unsafe fn connect_route_from_ffi(
    route: *const c_char,
    state_dir: *const c_char,
    device_name: *const c_char,
    invitation_uri: *const c_char,
    trusted_carrier: bool,
    wireguard: *const CmuxWireGuardNet,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut CmuxTerminalClient {
    let fail = |error: String| {
        copy_utf8(&error, error_buffer, error_capacity);
        std::ptr::null_mut()
    };
    let strings = || -> Result<_, String> {
        // SAFETY: each string forwards the documented pointer contract.
        unsafe {
            Ok((
                required_str_from_ffi(route, "route")?,
                required_str_from_ffi(state_dir, "state_dir")?,
                required_str_from_ffi(device_name, "device_name")?,
                optional_str_from_ffi(invitation_uri, "invitation_uri")?,
            ))
        }
    };
    let (route, state_dir, device_name, invitation_uri) = match strings() {
        Ok(values) => values,
        Err(error) => return fail(error),
    };
    if device_name.trim().is_empty() {
        return fail("device_name is empty".into());
    }
    // SAFETY: null is permitted; otherwise the caller guarantees a live handle.
    let wireguard = unsafe { wireguard.as_ref() }.map(|net| net.net.clone());
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => return fail(error.to_string()),
    };
    let connect = connect_route_client(RouteConnectOptions {
        route,
        state_dir: Path::new(state_dir),
        device_name,
        invitation_uri,
        trusted_carrier,
        wireguard,
    });
    let timeout = timeout_from_millis(timeout_milliseconds)
        .unwrap_or_else(|| default_connect_timeout(invitation_uri.is_some()));
    let connected = runtime.block_on(connect_with_timeout(connect, timeout));
    match connected {
        Ok(RouteConnection { transport, connection, multiplexer, state }) => {
            let updates = Arc::new(ClientUpdates::default());
            spawn_diagnostics(&runtime, &connection, &state, &updates);
            Box::into_raw(Box::new(CmuxTerminalClient {
                runtime,
                connection,
                transport,
                multiplexer,
                state,
                updates,
                raw_output: Arc::new(RawOutput::default()),
                terminal: Mutex::new(None),
                mux: tokio::sync::Mutex::new(None),
                next_request: AtomicU64::new(1),
                viewer_size_priority: AtomicBool::new(false),
                viewer_size_priority_unsupported: Arc::default(),
            }))
        }
        Err(error) => fail(error),
    }
}

/// Starts an in-process WireGuard tunnel from wg-quick config text.
///
/// The text must carry `PrivateKey`; it is parsed in memory and never written.
/// The returned tunnel can back any number of clients and stays up until
/// [`cmux_wireguard_net_free`].
///
/// # Safety
///
/// `config` must be a readable NUL-terminated string for the call.
/// `error_buffer` follows the connect buffer contract. A non-null result must
/// be freed exactly once, after every client that used it has disconnected.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wireguard_net_start(
    config: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> *mut CmuxWireGuardNet {
    let fail = |error: String| {
        copy_utf8(&error, error_buffer, error_capacity);
        std::ptr::null_mut()
    };
    // SAFETY: forwards the documented pointer contract.
    let text = match unsafe { required_str_from_ffi(config, "config") } {
        Ok(text) => Zeroizing::new(text.to_owned()),
        Err(error) => return fail(error),
    };
    let mut parsed = match WgConfig::parse_wg_quick(&text) {
        Ok(parsed) => parsed,
        Err(error) => return fail(format!("wireguard config: {error}")),
    };
    // Settings' Ultra Connection Mode (`remote.ultra`, Auto by default),
    // read at each start; `CMUX_WG_ULTRA` still wins over it.
    parsed.ultra = match cmux_tui_core::user_settings::ultra() {
        cmux_tui_core::user_settings::UltraConnection::Off => cmux_wg::UltraChoice::Off,
        cmux_tui_core::user_settings::UltraConnection::Auto => cmux_wg::UltraChoice::AUTO,
        cmux_tui_core::user_settings::UltraConnection::Always => cmux_wg::UltraChoice::ALWAYS,
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .thread_name("cmux-wireguard")
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return fail(error.to_string()),
    };
    match runtime.block_on(WgNet::start_with_new_socket(parsed)) {
        Ok(net) => {
            Box::into_raw(Box::new(CmuxWireGuardNet { _runtime: runtime, net: Arc::new(net) }))
        }
        Err(error) => fail(format!("wireguard: {error}")),
    }
}

/// Checks whether a trusted-carrier route is a literal WebSocket IP covered
/// by the tunnel's AllowedIPs without opening a connection.
///
/// # Safety
///
/// The caller must pass pointers that are valid for reads for the duration of
/// this call, or null where the API permits it. A non-null `route` must point
/// to a NUL-terminated C string, including its terminator, within one readable
/// allocation for the duration of the call. The output buffer must be valid
/// for writes of up to `error_capacity` bytes when an error is reported.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wireguard_net_route_is_allowed(
    net: *const CmuxWireGuardNet,
    route: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> bool {
    let fail = |error: String| {
        copy_utf8(&error, error_buffer, error_capacity);
        false
    };
    let Some(net) = (unsafe { net.as_ref() }) else {
        return fail("wireguard tunnel is null".into());
    };
    let route = match unsafe { required_str_from_ffi(route, "route") } {
        Ok(route) => route,
        Err(error) => return fail(error),
    };
    let parsed = match Url::parse(route) {
        Ok(parsed) => parsed,
        Err(error) => return fail(format!("route: {error}")),
    };
    match validate_trusted_route(&parsed, Some(net.net.routes())) {
        Ok(()) => true,
        Err(error) => fail(error),
    }
}

/// Stops the tunnel and frees the handle.
///
/// # Safety
///
/// `net` must be null or a handle from [`cmux_wireguard_net_start`] that no
/// live client still references. The pointer must not be used afterward.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wireguard_net_free(net: *mut CmuxWireGuardNet) {
    if net.is_null() {
        return;
    }
    // SAFETY: ownership transfers exactly once per the documented contract.
    let net = unsafe { Box::from_raw(net) };
    // The driver task lives on this runtime; drop it off the caller's thread so
    // an AppKit or UIKit caller never blocks on socket teardown.
    let _ = std::thread::Builder::new().name("cmux-wireguard-free".into()).spawn(move || drop(net));
}

/// Installs the raw output callback, or clears it with NULL.
///
/// Install before attaching a terminal: the delivery mode is fixed when the
/// attach begins, so a client attached without a callback keeps decoding text
/// frames locally until it is detached and attached again.
///
/// # Safety
///
/// `client` must be a live handle. `context` must remain valid until the
/// callback is cleared or the client is disconnected. The callback runs on
/// internal worker threads; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_set_output_callback(
    client: *mut CmuxTerminalClient,
    callback: Option<TerminalOutputCallback>,
    context: *mut c_void,
) {
    if client.is_null() {
        return;
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    client.raw_output.set_callback(callback, context);
}

/// Chooses whether the next attach asks for viewer-size priority, so the
/// terminal grid follows this client's size instead of the smallest attached
/// viewer's. Returns false only for a null client.
///
/// Like the output callback's delivery mode, the choice is read when an
/// attach begins and holds for that attachment and its reconnects. A daemon
/// that predates priority keeps the smallest-viewer behavior.
///
/// # Safety
///
/// `client` may be null. A non-null value must be a live handle returned by a
/// connect function, and it must not be disconnected during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_set_viewer_size_priority(
    client: *mut CmuxTerminalClient,
    preferred: bool,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return false;
    };
    client.viewer_size_priority.store(preferred, Ordering::Release);
    true
}

/// Bytes of a `cmux.protocol/2` request id or idempotency key.
fn random_token() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

impl CmuxTerminalClient {
    async fn mux_client(&self) -> Result<Arc<MuxLineClient>, String> {
        let mut slot = self.mux.lock().await;
        if let Some(existing) = slot.as_ref() {
            return Ok(existing.clone());
        }
        let opened = Arc::new(
            MuxLineClient::open(&self.multiplexer)
                .await
                .map_err(|error| format!("open mux control: {error}"))?,
        );
        *slot = Some(opened.clone());
        Ok(opened)
    }

    /// Issue one `cmux.protocol/2` operation and return its `result`.
    fn resource_operation(
        &self,
        operation: &str,
        mut params: serde_json::Map<String, Value>,
        mutation: bool,
        timeout: Option<StdDuration>,
    ) -> Result<Value, String> {
        params.entry("machine").or_insert_with(|| json!("current"));
        params.entry("session").or_insert_with(|| json!("current"));
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": random_token()?,
            "operation": operation,
            "params": Value::Object(params),
        });
        if mutation {
            request.set("idempotency_key", json!(random_token()?));
        }
        let call = async {
            let mux = self.mux_client().await?;
            match mux.request(&request).await {
                Ok(reply) => Ok(reply),
                Err(error) => {
                    // A failed stream is not reused; the next call reopens it.
                    self.mux.lock().await.take();
                    let _ = mux.close().await;
                    Err(format!("{operation}: {error}"))
                }
            }
        };
        let reply = match timeout {
            Some(timeout) => {
                match self.runtime.block_on(async { tokio::time::timeout(timeout, call).await }) {
                    Ok(reply) => reply?,
                    Err(_) => {
                        // The reply may still arrive later on this stream and would
                        // be mistaken for nothing, but a stale reply must never be
                        // matched to a future request; drop the stream instead.
                        if let Some(mux) = self.runtime.block_on(self.mux.lock()).take() {
                            self.runtime.block_on(mux.close()).ok();
                        }
                        return Err(format!("{operation}: {CONNECTION_TIMEOUT_ERROR}"));
                    }
                }
            }
            None => self.runtime.block_on(call)?,
        };
        if reply.get("ok").and_then(Value::as_bool) == Some(true) {
            return reply.get("result").cloned().ok_or_else(|| format!("{operation}: no result"));
        }
        let error = reply.get("error");
        let code =
            error.and_then(|error| error.get("code")).and_then(Value::as_str).unwrap_or("error");
        let message = error
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("operation failed");
        Err(format!("{operation}: {code}: {message}"))
    }
}

fn json_to_c_string(value: &Value) -> Result<*mut c_char, String> {
    let text = serde_json::to_string(value).map_err(|error| error.to_string())?;
    CString::new(text).map(CString::into_raw).map_err(|error| error.to_string())
}

fn timeout_from_millis(milliseconds: u64) -> Option<StdDuration> {
    (milliseconds != 0).then(|| StdDuration::from_millis(milliseconds))
}

/// Lists the daemon's terminals as the JSON array `terminal.list` returns.
///
/// Returns an owned NUL-terminated UTF-8 string to free with
/// [`cmux_terminal_client_string_free`], or NULL with the error written.
///
/// # Safety
///
/// `client` must be a live handle. `error_buffer` follows the connect buffer
/// contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_list_terminals(
    client: *mut CmuxTerminalClient,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut c_char {
    if client.is_null() {
        copy_utf8("client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    let result = client
        .resource_operation(
            "terminal.list",
            serde_json::Map::new(),
            false,
            timeout_from_millis(timeout_milliseconds),
        )
        .and_then(|value| json_to_c_string(&value));
    match result {
        Ok(text) => text,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Returns the daemon's public session snapshot as the JSON `session.snapshot`
/// returns: workspaces, screens, panes, tabs, terminals, and the rest of the
/// session. A terminal's `tab_id`, the tab's `pane_id`, the pane's
/// `screen_id`, and the screen's `workspace_id` place it under its workspace,
/// which `terminal.list` alone cannot.
///
/// Returns an owned NUL-terminated UTF-8 string to free with
/// [`cmux_terminal_client_string_free`], or NULL with the error written.
///
/// # Safety
///
/// `client` must be a live handle. `error_buffer` follows the connect buffer
/// contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_session_snapshot(
    client: *mut CmuxTerminalClient,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut c_char {
    if client.is_null() {
        copy_utf8("client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    let result = client
        .resource_operation(
            "session.snapshot",
            serde_json::Map::new(),
            false,
            timeout_from_millis(timeout_milliseconds),
        )
        .and_then(|value| json_to_c_string(&value));
    match result {
        Ok(text) => text,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Creates a workspace holding one new terminal (`workspace.create` with
/// `initial_content: terminal`) and returns the mutation result JSON
/// (`MutationResult<CreatedPath>`), whose `value.terminal_id` names the
/// terminal to attach.
///
/// # Safety
///
/// `client` must be a live handle. `name` may be NULL. `error_buffer` follows
/// the connect buffer contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_create_terminal(
    client: *mut CmuxTerminalClient,
    name: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut c_char {
    if client.is_null() {
        copy_utf8("client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    // SAFETY: null is permitted; otherwise NUL-terminated per the contract.
    let name = match unsafe { optional_str_from_ffi(name, "name") } {
        Ok(name) => name,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let mut params = serde_json::Map::new();
    params.insert("initial_content".into(), json!("terminal"));
    if let Some(name) = name {
        params.insert("name".into(), json!(name));
    }
    let result = client
        .resource_operation(
            "workspace.create",
            params,
            true,
            timeout_from_millis(timeout_milliseconds),
        )
        .and_then(|value| json_to_c_string(&value));
    match result {
        Ok(text) => text,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Creates a terminal tab inside an existing workspace (`tab.create_terminal`
/// with only the `workspace` selector) and returns the mutation result JSON
/// (`MutationResult<CreatedTerminalPath>`), whose `value.terminal_id` names the
/// terminal to attach.
///
/// The daemon adds the tab to the workspace's focused pane (the active pane of
/// its active screen) and makes it that pane's selected tab; a workspace with
/// no screen gets a new screen and pane. When the focused pane is a chat dock
/// or holds an agent chat, the tab goes to a pane on the chat's right instead
/// when there is one; an agent chat that is not docked and is alone on its
/// screen gets a new column there. The session's focused workspace does not
/// change. `workspace_id` must be an opaque `ws_` id: a name or `current`
/// is rejected before any request is sent, so it cannot select another
/// workspace.
///
/// # Safety
///
/// `client` must be a live handle. `workspace_id` must be a NUL-terminated
/// string. `name` may be NULL. `error_buffer` follows the connect buffer
/// contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_create_terminal_in_workspace(
    client: *mut CmuxTerminalClient,
    workspace_id: *const c_char,
    name: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut c_char {
    if client.is_null() {
        copy_utf8("client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    let arguments = || -> Result<_, String> {
        // SAFETY: `workspace_id` is NUL-terminated; `name` is null or
        // NUL-terminated, per the contract.
        let (workspace_id, name) = unsafe {
            (
                required_str_from_ffi(workspace_id, "workspace_id")?,
                optional_str_from_ffi(name, "name")?,
            )
        };
        let workspace_id = WorkspacePublicId::parse(workspace_id)
            .map_err(|error| format!("workspace_id is invalid: {error}"))?;
        Ok((workspace_id, name))
    };
    let (workspace_id, name) = match arguments() {
        Ok(arguments) => arguments,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let mut params = serde_json::Map::new();
    params.insert("workspace".into(), json!(workspace_id.as_str()));
    if let Some(name) = name {
        params.insert("name".into(), json!(name));
    }
    let result = client
        .resource_operation(
            "tab.create_terminal",
            params,
            true,
            timeout_from_millis(timeout_milliseconds),
        )
        .and_then(|value| json_to_c_string(&value));
    match result {
        Ok(text) => text,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Lists the daemon's remote workspaces as returned by `workspace.list`.
///
/// # Safety
///
/// `client` must be a live handle. `error_buffer` follows the connect buffer
/// contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_list_workspaces(
    client: *mut CmuxTerminalClient,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut c_char {
    if client.is_null() {
        copy_utf8("client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    let result = client
        .resource_operation(
            "workspace.list",
            serde_json::Map::new(),
            false,
            timeout_from_millis(timeout_milliseconds),
        )
        .and_then(|value| json_to_c_string(&value));
    match result {
        Ok(text) => text,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Creates a remote workspace. The optional name is sent as the workspace
/// title; the daemon owns the workspace identity and root path.
///
/// # Safety
///
/// `client` must be a live handle. `name` may be NULL. `error_buffer` follows
/// the connect buffer contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_create_workspace(
    client: *mut CmuxTerminalClient,
    name: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut c_char {
    if client.is_null() {
        copy_utf8("client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the caller guarantees a live handle.
    let client = unsafe { &*client };
    // SAFETY: null is permitted; otherwise NUL-terminated per the contract.
    let name = match unsafe { optional_str_from_ffi(name, "name") } {
        Ok(name) => name,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let mut params = serde_json::Map::new();
    params.insert("initial_content".into(), json!("terminal"));
    if let Some(name) = name {
        params.insert("name".into(), json!(name));
    }
    let result = client
        .resource_operation(
            "workspace.create",
            params,
            true,
            timeout_from_millis(timeout_milliseconds),
        )
        .and_then(|value| json_to_c_string(&value));
    match result {
        Ok(text) => text,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Frees a string returned by this library.
///
/// # Safety
///
/// `text` must be null or a pointer returned by this library that has not
/// been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_string_free(text: *mut c_char) {
    if text.is_null() {
        return;
    }
    // SAFETY: ownership transfers exactly once per the documented contract.
    drop(unsafe { CString::from_raw(text) });
}

#[cfg(test)]
#[path = "reconnect_tests.rs"]
mod reconnect_tests;
