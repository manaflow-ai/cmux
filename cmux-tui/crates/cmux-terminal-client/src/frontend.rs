use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_remote::mux_codec::{MuxLineAssembler, encode_line};
use cmux_remote::service::{ServiceMultiplexer, ServiceStream, StreamChunk};
use cmux_remote_protocol::{Lane, RESOURCE_PROTOCOL, Service, ServiceControl};
use cmux_terminal_host_protocol::{Frame, MessageKind};
use serde_json::{Value, json};
use tokio::runtime::Runtime;
use tokio::sync::oneshot;

use super::{
    ActiveTerminal, ClientState, ClientUpdates, ConnectedTransport, TerminalUpdateCallback,
    bytes_from_ffi, connect_transport, connect_with_timeout, copy_utf8, encode_frame,
    open_terminal_stream_with_timeout, start_terminal_tasks, terminal_id_from_ffi,
};

const FRONTEND_CONNECTION_TIMEOUT_ERROR: &str = "frontend connection timed out";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const RESOURCE_STREAM_END_NONE: u8 = 0;
const RESOURCE_STREAM_END_COMPLETED: u8 = 1;
const RESOURCE_STREAM_END_CANCELED: u8 = 2;
const RESOURCE_STREAM_END_CLOSED: u8 = 3;
const RESOURCE_STREAM_END_GAP: u8 = 4;
const RESOURCE_STREAM_END_ERROR: u8 = 5;

type PendingResponse = oneshot::Sender<Result<Value, String>>;

struct FrontendControlState {
    pending: Mutex<HashMap<String, PendingResponse>>,
    updates: Arc<ClientUpdates>,
    status: Mutex<String>,
    closed: AtomicBool,
    resource_updates: Mutex<VecDeque<Vec<u8>>>,
    resource_updates_overflowed: AtomicBool,
    resource_stream_ended: AtomicBool,
    resource_stream_end_reason: AtomicU8,
}

impl FrontendControlState {
    fn new(updates: Arc<ClientUpdates>) -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            updates,
            status: Mutex::new("ready".into()),
            closed: AtomicBool::new(false),
            resource_updates: Mutex::new(VecDeque::new()),
            resource_updates_overflowed: AtomicBool::new(false),
            resource_stream_ended: AtomicBool::new(false),
            resource_stream_end_reason: AtomicU8::new(RESOURCE_STREAM_END_NONE),
        }
    }

    fn push_resource_update(&self, value: &Value) {
        let encoded = serde_json::to_vec(value).unwrap_or_default();
        let mut queue = self.resource_updates.lock().unwrap();
        if queue.len() >= 256 {
            self.resource_updates_overflowed.store(true, Ordering::Release);
            return;
        }
        queue.push_back(encoded);
        self.updates.notify();
    }

    fn fail_pending(&self, message: String) {
        let pending = std::mem::take(&mut *self.pending.lock().unwrap());
        for (_, sender) in pending {
            let _ = sender.send(Err(message.clone()));
        }
    }

    fn fail(&self, message: String) {
        *self.status.lock().unwrap() = message.clone();
        self.closed.store(true, Ordering::Release);
        self.fail_pending(message);
        self.updates.notify();
    }

    fn discard_resource_updates_if_overflowed(&self) -> bool {
        let mut queue = self.resource_updates.lock().unwrap();
        if !self.resource_updates_overflowed.swap(false, Ordering::AcqRel) {
            return false;
        }
        queue.clear();
        true
    }

    fn begin_resource_stream(&self) {
        self.resource_stream_end_reason
            .store(RESOURCE_STREAM_END_NONE, Ordering::Release);
        self.resource_stream_ended.store(false, Ordering::Release);
    }
}

struct ActiveControl {
    stream: Arc<ServiceStream>,
    receiver_task: tokio::task::JoinHandle<()>,
}

impl ActiveControl {
    async fn close(self) {
        self.receiver_task.abort();
        let _ = self.stream.close().await;
        let _ = self.receiver_task.await;
    }
}

/// One enrolled smart frontend transport. It owns the public resource control
/// stream and can create many independent terminal renderer attachments.
pub struct CmuxFrontendClient {
    runtime: Runtime,
    connection: Arc<cmux_remote::connection::ClientConnection>,
    provider: Arc<cmux_remote::provider::IrohProvider>,
    multiplexer: Arc<ServiceMultiplexer>,
    control: Mutex<Option<ActiveControl>>,
    control_state: Arc<FrontendControlState>,
    updates: Arc<ClientUpdates>,
    next_message: AtomicU64,
    nonce: String,
    provider_name: String,
    path: String,
    generation: AtomicU64,
}

/// One terminal-bytes-v1 attachment with its own ordered renderer event queue.
pub struct CmuxFrontendTerminal {
    runtime: tokio::runtime::Handle,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
    active: Mutex<Option<ActiveTerminal>>,
    next_request: AtomicU64,
}

/// Ordered session-event envelope. The payload is the original stream_item
/// JSON, including kind, sequence, cursor, and delta changes. `overflowed`
/// requires a full snapshot resync. `ended` reports a stream_end and
/// `end_reason` distinguishes recoverable gaps from terminal ends.
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct CmuxFrontendResourceUpdate {
    pub payload_length: usize,
    pub overflowed: bool,
    pub ended: bool,
    pub end_reason: u32,
}

/// Metadata for one ordered event consumed by a native terminal renderer.
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct CmuxFrontendRenderEvent {
    pub kind: u32,
    pub cols: u16,
    pub rows: u16,
    pub payload_length: usize,
}

unsafe fn copy_resource_update_from_state(
    state: &FrontendControlState,
    update: &mut CmuxFrontendResourceUpdate,
    buffer: *mut u8,
    capacity: usize,
) -> bool {
    update.payload_length = 0;
    update.overflowed = false;
    update.ended = state.resource_stream_ended.load(Ordering::Acquire);
    update.end_reason = u32::from(state.resource_stream_end_reason.load(Ordering::Acquire));
    if state.discard_resource_updates_if_overflowed() {
        update.overflowed = true;
        return true;
    }
    let mut queue = state.resource_updates.lock().unwrap();
    let Some(payload) = queue.front() else {
        return update.ended;
    };
    update.payload_length = payload.len();
    if payload.len() > capacity || (payload.len() > 0 && buffer.is_null()) {
        return true;
    }
    let payload = queue.pop_front().unwrap();
    unsafe { std::ptr::copy_nonoverlapping(payload.as_ptr(), buffer, payload.len()) };
    true
}

async fn open_control_stream(
    multiplexer: &Arc<ServiceMultiplexer>,
) -> Result<(Arc<ServiceStream>, VecDeque<StreamChunk>), String> {
    let stream = Arc::new(
        multiplexer
            .open(Service::MuxControl, BTreeMap::new())
            .await
            .map_err(|error| format!("open mux-control: {error}"))?,
    );
    let handshake = async {
        let mut seen = 0_u8;
        let mut buffered = VecDeque::new();
        while seen != 0b111 {
            let chunk = stream
                .receive()
                .await
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "mux-control closed before every lane was ready".to_string())?;
            let control = serde_json::from_slice::<ServiceControl>(&chunk.payload).ok();
            match control {
                Some(ServiceControl::Opened { service: Service::MuxControl }) => {
                    seen |= match chunk.lane {
                        Lane::Interactive => 0b001,
                        Lane::Control => 0b010,
                        Lane::Bulk => 0b100,
                        Lane::Tunnel => {
                            return Err("mux-control opened on the tunnel lane".into());
                        }
                    };
                }
                Some(ServiceControl::Rejected { message, .. }) => return Err(message),
                _ => buffered.push_back(chunk),
            }
        }
        Ok::<_, String>(buffered)
    };
    match handshake.await {
        Ok(buffered) => Ok((stream, buffered)),
        Err(error) => {
            let _ = stream.close().await;
            Err(error)
        }
    }
}

fn handle_control_line(state: &FrontendControlState, line: &[u8]) {
    let value = match serde_json::from_slice::<Value>(line) {
        Ok(value) => value,
        Err(error) => {
            state.fail(format!("mux-control JSON: {error}"));
            return;
        }
    };
    if value.get("protocol").and_then(Value::as_str) != Some(RESOURCE_PROTOCOL) {
        return;
    }
    if value.get("type").and_then(Value::as_str) == Some("response")
        && let Some(id) = value.get("id").and_then(Value::as_str)
        && let Some(sender) = state.pending.lock().unwrap().remove(id)
    {
        let _ = sender.send(Ok(value));
        return;
    }
    if value.get("type").and_then(Value::as_str) == Some("stream_item") {
        state.push_resource_update(&value);
    }
    if value.get("type").and_then(Value::as_str) == Some("stream_end") {
        let reason = match value.get("reason").and_then(Value::as_str) {
            Some("completed") => RESOURCE_STREAM_END_COMPLETED,
            Some("canceled") => RESOURCE_STREAM_END_CANCELED,
            Some("closed") => RESOURCE_STREAM_END_CLOSED,
            Some("gap") => RESOURCE_STREAM_END_GAP,
            _ => RESOURCE_STREAM_END_ERROR,
        };
        state.resource_stream_end_reason.store(reason, Ordering::Release);
        state.resource_stream_ended.store(true, Ordering::Release);
    }
    if matches!(value.get("type").and_then(Value::as_str), Some("stream_item" | "stream_end")) {
        state.updates.notify();
    }
}

async fn receive_control(
    stream: Arc<ServiceStream>,
    state: Arc<FrontendControlState>,
    mut buffered: VecDeque<StreamChunk>,
) {
    let mut assembler = MuxLineAssembler::default();
    loop {
        let chunk = if let Some(chunk) = buffered.pop_front() {
            Ok(Some(chunk))
        } else {
            stream.receive().await
        };
        let chunk = match chunk {
            Ok(Some(chunk)) => chunk,
            Ok(None) => {
                state.fail("mux-control closed".into());
                return;
            }
            Err(error) => {
                state.fail(format!("mux-control: {error}"));
                return;
            }
        };
        if !chunk.payload.is_empty() {
            match assembler.push(chunk.lane, chunk.payload) {
                Ok(Some((_, line))) => handle_control_line(&state, &line),
                Ok(None) => {}
                Err(error) => {
                    state.fail(format!("mux-control framing: {error}"));
                    return;
                }
            }
        }
        if chunk.finished || chunk.reset {
            state.fail(if chunk.reset {
                "mux-control reset".into()
            } else {
                "mux-control closed".into()
            });
            return;
        }
    }
}

fn random_nonce() -> Result<String, String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn classify_resource_request(operation: &str, mutation: bool) -> Lane {
    if mutation {
        return Lane::Interactive;
    }
    if matches!(
        operation,
        "session.snapshot"
            | "terminal.screen.read"
            | "terminal.state.read"
            | "terminal.history.read"
            | "screen.layout.export"
    ) {
        Lane::Bulk
    } else {
        Lane::Control
    }
}

impl CmuxFrontendClient {
    fn request(&self, operation: &str, params: Value, mutation: bool) -> Result<Value, String> {
        if !params.is_object() {
            return Err("request params must be a JSON object".into());
        }
        if self.control_state.closed.load(Ordering::Acquire) {
            return Err(self.control_state.status.lock().unwrap().clone());
        }
        if operation == "session.events" {
            self.control_state.begin_resource_stream();
        }
        let message = self.next_message.fetch_add(1, Ordering::Relaxed);
        let id = format!("native-{}-{message}", self.nonce);
        let mut envelope = json!({
            "protocol":RESOURCE_PROTOCOL,
            "type":"request",
            "id":id,
            "operation":operation,
            "params":params,
        });
        if mutation {
            envelope["idempotency_key"] = Value::String(format!("native-{}-{message}", self.nonce));
        }
        let mut line = serde_json::to_vec(&envelope).map_err(|error| error.to_string())?;
        line.push(b'\n');
        let packets = encode_line(message, &line).map_err(|error| error.to_string())?;
        let lane = classify_resource_request(operation, mutation);
        let stream = self
            .control
            .lock()
            .unwrap()
            .as_ref()
            .map(|control| control.stream.clone())
            .ok_or_else(|| "mux-control is unavailable".to_string())?;
        let (sender, response) = oneshot::channel();
        self.control_state.pending.lock().unwrap().insert(id.clone(), sender);
        let send_result = self.runtime.block_on(async {
            for packet in packets {
                stream.send_on(lane, packet).await.map_err(|error| error.to_string())?;
            }
            Ok::<(), String>(())
        });
        if let Err(error) = send_result {
            self.control_state.pending.lock().unwrap().remove(&id);
            return Err(error);
        }
        let response = self.runtime.block_on(async {
            tokio::time::timeout(REQUEST_TIMEOUT, response)
                .await
                .map_err(|_| "resource request timed out".to_string())?
                .map_err(|_| "resource response channel closed".to_string())?
        });
        if response.is_err() {
            self.control_state.pending.lock().unwrap().remove(&id);
        }
        let response = response?;
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            Ok(response.get("result").cloned().unwrap_or(Value::Null))
        } else {
            let error = response.get("error").cloned().unwrap_or_else(
                || json!({"code":"operation.failed","message":"resource request failed"}),
            );
            Err(serde_json::to_string(&error).unwrap_or_else(|_| "resource request failed".into()))
        }
    }
}

unsafe fn frontend_connect(
    invitation_uri: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout: Option<Duration>,
) -> *mut CmuxFrontendClient {
    if invitation_uri.is_null() {
        copy_utf8("invitation URI is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: the C API requires a readable NUL-terminated invitation URI.
    let invitation = match unsafe { CStr::from_ptr(invitation_uri) }.to_str() {
        Ok(invitation) => invitation,
        Err(error) => {
            copy_utf8(
                &format!("invitation URI is not UTF-8: {error}"),
                error_buffer,
                error_capacity,
            );
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
    let started = Instant::now();
    let connected = match timeout {
        Some(timeout) => runtime.block_on(connect_with_timeout(
            connect_transport(invitation, "NativeMux Demo"),
            timeout,
        )),
        None => runtime.block_on(connect_transport(invitation, "NativeMux Demo")),
    };
    let ConnectedTransport { connection, provider, multiplexer, provider_name, path, generation } =
        match connected {
            Ok(connected) => connected,
            Err(error) => {
                let error = if error == super::CONNECTION_TIMEOUT_ERROR {
                    FRONTEND_CONNECTION_TIMEOUT_ERROR
                } else {
                    &error
                };
                copy_utf8(error, error_buffer, error_capacity);
                return std::ptr::null_mut();
            }
        };
    let control_result = match timeout {
        Some(timeout) => runtime.block_on(connect_with_timeout(
            open_control_stream(&multiplexer),
            timeout.saturating_sub(started.elapsed()),
        )),
        None => runtime.block_on(open_control_stream(&multiplexer)),
    };
    let (stream, buffered) = match control_result {
        Ok(control) => control,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            runtime.block_on(async {
                multiplexer.shutdown().await;
                let _ = connection.close().await;
                provider.close().await;
            });
            return std::ptr::null_mut();
        }
    };
    let nonce = match random_nonce() {
        Ok(nonce) => nonce,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            runtime.block_on(async {
                let _ = stream.close().await;
                multiplexer.shutdown().await;
                let _ = connection.close().await;
                provider.close().await;
            });
            return std::ptr::null_mut();
        }
    };
    let updates = Arc::new(ClientUpdates::default());
    let control_state = Arc::new(FrontendControlState::new(updates.clone()));
    let receiver_task =
        runtime.spawn(receive_control(stream.clone(), control_state.clone(), buffered));
    Box::into_raw(Box::new(CmuxFrontendClient {
        runtime,
        connection,
        provider,
        multiplexer,
        control: Mutex::new(Some(ActiveControl { stream, receiver_task })),
        control_state,
        updates,
        next_message: AtomicU64::new(1),
        nonce,
        provider_name,
        path,
        generation: AtomicU64::new(generation),
    }))
}

/// Enrolls one native frontend transport and opens its public resource stream.
///
/// # Safety
///
/// Pointers follow the same contract as `cmux_terminal_client_connect`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_connect_with_timeout(
    invitation_uri: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut CmuxFrontendClient {
    // SAFETY: forwards this function's documented C pointer contract.
    unsafe {
        frontend_connect(
            invitation_uri,
            error_buffer,
            error_capacity,
            Some(Duration::from_millis(timeout_milliseconds)),
        )
    }
}

/// Registers a signal-only callback for resource stream or transport changes.
///
/// # Safety
///
/// The client and callback context must remain live until synchronously cleared.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_set_update_callback(
    client: *const CmuxFrontendClient,
    callback: Option<TerminalUpdateCallback>,
    context: *mut c_void,
) {
    let Some(client) = (unsafe { client.as_ref() }) else { return };
    client.updates.set_callback(callback, context);
}

/// Copies and consumes one ordered session stream_item envelope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_copy_resource_update(
    client: *const CmuxFrontendClient,
    update: *mut CmuxFrontendResourceUpdate,
    buffer: *mut u8,
    capacity: usize,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
    let Some(update) = (unsafe { update.as_mut() }) else { return false };
    unsafe {
        copy_resource_update_from_state(&client.control_state, update, buffer, capacity)
    }
}

/// Executes one public resource operation and returns allocated result JSON.
///
/// # Safety
///
/// String pointers must be readable and NUL terminated. The returned string
/// must be released with `cmux_frontend_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_request(
    client: *mut CmuxFrontendClient,
    operation: *const c_char,
    params_json: *const c_char,
    mutation: bool,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> *mut c_char {
    let Some(client) = (unsafe { client.as_ref() }) else {
        copy_utf8("frontend client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    };
    if operation.is_null() || params_json.is_null() {
        copy_utf8("operation and params JSON are required", error_buffer, error_capacity);
        return std::ptr::null_mut();
    }
    // SAFETY: checked non-null; the C API requires NUL-terminated UTF-8 strings.
    let operation = match unsafe { CStr::from_ptr(operation) }.to_str() {
        Ok(operation) => operation,
        Err(error) => {
            copy_utf8(&format!("operation is not UTF-8: {error}"), error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    // SAFETY: checked non-null; the C API requires NUL-terminated UTF-8 strings.
    let params = match unsafe { CStr::from_ptr(params_json) }
        .to_str()
        .map_err(|error| error.to_string())
        .and_then(|params| serde_json::from_str::<Value>(params).map_err(|error| error.to_string()))
    {
        Ok(params) => params,
        Err(error) => {
            copy_utf8(&format!("params JSON: {error}"), error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    match client.request(operation, params, mutation) {
        Ok(result) => match serde_json::to_string(&result)
            .map_err(|error| error.to_string())
            .and_then(|result| CString::new(result).map_err(|error| error.to_string()))
        {
            Ok(result) => result.into_raw(),
            Err(error) => {
                copy_utf8(&error, error_buffer, error_capacity);
                std::ptr::null_mut()
            }
        },
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Releases a string returned by `cmux_frontend_client_request`.
///
/// # Safety
///
/// The pointer may be null. Otherwise it must be returned by this library and
/// must not have been freed already.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: ownership transfers back from the matching allocation API.
        drop(unsafe { CString::from_raw(value) });
    }
}

/// Opens an independent terminal renderer stream on the existing transport.
///
/// # Safety
///
/// `client` must outlive the returned terminal, which must be disconnected once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_attach_terminal(
    client: *mut CmuxFrontendClient,
    terminal_id: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
    timeout_milliseconds: u64,
) -> *mut CmuxFrontendTerminal {
    let Some(client) = (unsafe { client.as_ref() }) else {
        copy_utf8("frontend client is null", error_buffer, error_capacity);
        return std::ptr::null_mut();
    };
    let terminal_id = match unsafe { terminal_id_from_ffi(terminal_id) } {
        Ok(terminal_id) => terminal_id,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let stream = match client.runtime.block_on(open_terminal_stream_with_timeout(
        &client.multiplexer,
        &terminal_id,
        Some(Duration::from_millis(timeout_milliseconds)),
    )) {
        Ok(stream) => stream,
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let state = match ClientState::new(
        client.provider_name.clone(),
        client.path.clone(),
        client.generation.load(Ordering::Acquire),
        terminal_id.clone(),
    ) {
        Ok(mut state) => {
            state.enable_native_render_events();
            Arc::new(Mutex::new(state))
        }
        Err(error) => {
            copy_utf8(&format!("libghostty: {error}"), error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    let updates = Arc::new(ClientUpdates::default());
    let active = start_terminal_tasks(
        &client.runtime,
        stream,
        client.multiplexer.clone(),
        terminal_id,
        state.clone(),
        updates.clone(),
    );
    Box::into_raw(Box::new(CmuxFrontendTerminal {
        runtime: client.runtime.handle().clone(),
        state,
        updates,
        active: Mutex::new(Some(active)),
        next_request: AtomicU64::new(1),
    }))
}

/// Copies and consumes the next ordered native-renderer event.
///
/// A first call with a null/undersized payload buffer returns the event
/// metadata and leases that exact non-empty event. Allocate `payload_length`
/// bytes and call again to copy and consume the lease. A concurrent resync can
/// replace queued events but cannot invalidate the lease. Empty events are
/// consumed by the first call.
///
/// # Safety
///
/// `event` must be writable. A non-null payload buffer must be writable for
/// `capacity` bytes. Calls for one terminal must be serialized by the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_copy_next_render_event(
    terminal: *mut CmuxFrontendTerminal,
    event: *mut CmuxFrontendRenderEvent,
    buffer: *mut u8,
    capacity: usize,
) -> bool {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return false };
    let Some(event_out) = (unsafe { event.as_mut() }) else { return false };
    let mut state = terminal.state.lock().unwrap();
    if state.native_render_event_lease.is_none() {
        state.native_render_event_lease =
            state.native_render_events.as_mut().and_then(VecDeque::pop_front);
    }
    let Some(next) = state.native_render_event_lease.as_ref() else {
        return false;
    };
    *event_out = CmuxFrontendRenderEvent {
        kind: next.kind as u32,
        cols: next.cols,
        rows: next.rows,
        payload_length: next.payload.len(),
    };
    if next.payload.len() > capacity || (!next.payload.is_empty() && buffer.is_null()) {
        return true;
    }
    if !next.payload.is_empty() {
        // SAFETY: the caller provides a writable buffer at least payload_length bytes long.
        unsafe { std::ptr::copy_nonoverlapping(next.payload.as_ptr(), buffer, next.payload.len()) };
    }
    let removed = state.native_render_event_lease.take();
    if let Some(removed) = removed {
        state.native_render_event_bytes =
            state.native_render_event_bytes.saturating_sub(removed.payload.len());
    }
    true
}

fn enqueue_terminal(terminal: &CmuxFrontendTerminal, frame: Frame) -> bool {
    let Ok(encoded) = encode_frame(&frame) else { return false };
    let active = terminal.active.lock().unwrap();
    let Some(active) = active.as_ref() else { return false };
    if active.closed.load(Ordering::Acquire) {
        return false;
    }
    active.command_sender.try_send(Bytes::from(encoded)).is_ok()
}

/// Registers a signal-only callback for one terminal's rendered state.
///
/// # Safety
///
/// The terminal and callback context must remain live until synchronously cleared.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_set_update_callback(
    terminal: *const CmuxFrontendTerminal,
    callback: Option<TerminalUpdateCallback>,
    context: *mut c_void,
) {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return };
    terminal.updates.set_callback(callback, context);
}

/// Queues raw PTY input for one terminal attachment.
///
/// # Safety
///
/// The byte buffer must be readable for `length` bytes during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_send(
    terminal: *mut CmuxFrontendTerminal,
    bytes: *const u8,
    length: usize,
) -> bool {
    let Some((terminal, bytes)) =
        (unsafe { terminal.as_ref() }).zip(unsafe { bytes_from_ffi(bytes, length) })
    else {
        return false;
    };
    enqueue_terminal(terminal, Frame::new(MessageKind::Input, bytes.to_vec()))
}

/// Encodes a named key chord using this terminal's local libghostty modes.
///
/// # Safety
///
/// The chord must be a readable NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_send_key(
    terminal: *mut CmuxFrontendTerminal,
    chord: *const c_char,
    repeat: bool,
) -> bool {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return false };
    if chord.is_null() {
        return false;
    }
    // SAFETY: checked non-null; the C API requires a NUL-terminated chord.
    let chord = match unsafe { CStr::from_ptr(chord) }.to_str() {
        Ok(chord) => chord,
        Err(error) => {
            terminal.state.lock().unwrap().status = format!("key: {error}");
            terminal.updates.notify();
            return false;
        }
    };
    let encoded_result = terminal.state.lock().unwrap().encode_key(chord, repeat);
    let encoded = match encoded_result {
        Ok(encoded) => encoded,
        Err(error) => {
            terminal.state.lock().unwrap().status = format!("key: {error}");
            terminal.updates.notify();
            return false;
        }
    };
    encoded.is_empty() || enqueue_terminal(terminal, Frame::new(MessageKind::Input, encoded))
}

/// Queues opaque paste bytes for one terminal attachment.
///
/// # Safety
///
/// The byte buffer must be readable for `length` bytes during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_paste(
    terminal: *mut CmuxFrontendTerminal,
    bytes: *const u8,
    length: usize,
) -> bool {
    let Some((terminal, bytes)) =
        (unsafe { terminal.as_ref() }).zip(unsafe { bytes_from_ffi(bytes, length) })
    else {
        return false;
    };
    enqueue_terminal(terminal, Frame::new(MessageKind::Paste, bytes.to_vec()))
}

/// Updates one terminal viewer's character dimensions.
///
/// # Safety
///
/// The terminal must remain live during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_resize(
    terminal: *mut CmuxFrontendTerminal,
    cols: u16,
    rows: u16,
) -> bool {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return false };
    let mut payload = Vec::with_capacity(4);
    payload.extend_from_slice(&cols.max(1).to_le_bytes());
    payload.extend_from_slice(&rows.max(1).to_le_bytes());
    let mut frame = Frame::new(MessageKind::ViewerSize, payload);
    frame.request_id = terminal.next_request.fetch_add(1, Ordering::Relaxed);
    enqueue_terminal(terminal, frame)
}

/// Copies the latest plain-text rendering of one terminal.
///
/// # Safety
///
/// The optional output buffer must have `capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_copy_frame(
    terminal: *const CmuxFrontendTerminal,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return 0 };
    let mut state = terminal.state.lock().unwrap();
    if let Err(error) = state.materialize_frame() {
        state.status = format!("render: {error}");
    }
    copy_utf8(&state.frame_text, buffer, capacity)
}

/// Copies renderer diagnostics for one terminal attachment.
///
/// # Safety
///
/// The optional output buffer must have `capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_copy_diagnostics(
    terminal: *const CmuxFrontendTerminal,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return 0 };
    copy_utf8(&terminal.state.lock().unwrap().diagnostics(), buffer, capacity)
}

/// Returns whether the attached PTY emitted an exit frame.
///
/// # Safety
///
/// The terminal must remain live during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_has_exited(
    terminal: *const CmuxFrontendTerminal,
) -> bool {
    let Some(terminal) = (unsafe { terminal.as_ref() }) else { return false };
    terminal.state.lock().unwrap().exited
}

/// Closes and consumes one terminal attachment without closing the frontend.
///
/// # Safety
///
/// A non-null terminal must be consumed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_terminal_disconnect(terminal: *mut CmuxFrontendTerminal) {
    if terminal.is_null() {
        return;
    }
    // SAFETY: ownership transfers exactly once from the attach function.
    let terminal = unsafe { Box::from_raw(terminal) };
    terminal.updates.set_callback(None, std::ptr::null_mut());
    let active = terminal.active.lock().unwrap().take();
    if let Some(active) = active {
        terminal.runtime.block_on(active.close());
    }
}

/// Copies diagnostics for the shared frontend control connection.
///
/// # Safety
///
/// The optional output buffer must have `capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_copy_diagnostics(
    client: *const CmuxFrontendClient,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
    let diagnostics = json!({
        "carrier":client.provider_name,
        "path":client.path,
        "generation":client.generation.load(Ordering::Acquire),
        "service":"mux-control",
        "status":*client.control_state.status.lock().unwrap(),
    })
    .to_string();
    copy_utf8(&diagnostics, buffer, capacity)
}

/// Closes the resource stream and consumes the shared frontend transport.
/// All terminal handles must already have been disconnected.
///
/// # Safety
///
/// A non-null client must be consumed exactly once and not used concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_frontend_client_disconnect(client: *mut CmuxFrontendClient) {
    if client.is_null() {
        return;
    }
    // SAFETY: ownership transfers exactly once from the connect function.
    let client = unsafe { Box::from_raw(client) };
    client.updates.set_callback(None, std::ptr::null_mut());
    client.control_state.closed.store(true, Ordering::Release);
    client.control_state.fail_pending("frontend disconnected".into());
    let join =
        std::thread::Builder::new().name("cmux-frontend-disconnect".into()).spawn(move || {
            let control = client.control.lock().unwrap().take();
            client.runtime.block_on(async {
                if let Some(control) = control {
                    control.close().await;
                }
                client.multiplexer.shutdown().await;
                let _ = client.connection.close().await;
                client.provider.close().await;
            });
        });
    if let Ok(join) = join {
        let _ = join.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{NativeRenderEventKind, TerminalPublicId};

    #[test]
    fn resource_delta_queue_preserves_order_and_fails_closed_on_overflow() {
        let updates = Arc::new(ClientUpdates::default());
        let state = FrontendControlState::new(updates);
        for sequence in 0..256 {
            state.push_resource_update(&json!({"type":"stream_item","sequence":sequence}));
        }
        state.push_resource_update(&json!({"type":"stream_item","sequence":256}));
        assert!(state.resource_updates_overflowed.load(Ordering::Acquire));
        {
            let queue = state.resource_updates.lock().unwrap();
            assert_eq!(queue.len(), 256);
            assert_eq!(
                serde_json::from_slice::<Value>(&queue.front().unwrap()).unwrap()["sequence"],
                0
            );
            assert_eq!(
                serde_json::from_slice::<Value>(&queue.back().unwrap()).unwrap()["sequence"],
                255
            );
        }
        let mut overflow = CmuxFrontendResourceUpdate {
            payload_length: usize::MAX,
            overflowed: false,
            ended: false,
            end_reason: u32::MAX,
        };
        assert!(unsafe {
            copy_resource_update_from_state(&state, &mut overflow, std::ptr::null_mut(), 0)
        });
        assert!(overflow.overflowed);
        assert_eq!(overflow.payload_length, 0);
        assert!(state.resource_updates.lock().unwrap().is_empty());
        assert!(!state.resource_updates_overflowed.load(Ordering::Acquire));
        state.push_resource_update(&json!({"type":"stream_item","sequence":257}));
        state.resource_stream_end_reason
            .store(RESOURCE_STREAM_END_COMPLETED, Ordering::Release);
        state.resource_stream_ended.store(true, Ordering::Release);
        let mut descriptor = CmuxFrontendResourceUpdate {
            payload_length: 0,
            overflowed: false,
            ended: false,
            end_reason: 0,
        };
        assert!(unsafe {
            copy_resource_update_from_state(&state, &mut descriptor, std::ptr::null_mut(), 0)
        });
        assert!(descriptor.ended);
        assert_eq!(
            descriptor.end_reason,
            u32::from(RESOURCE_STREAM_END_COMPLETED)
        );
        assert!(!descriptor.overflowed);
        let mut payload = vec![0_u8; descriptor.payload_length];
        assert!(unsafe {
            copy_resource_update_from_state(
                &state,
                &mut descriptor,
                payload.as_mut_ptr(),
                payload.len(),
            )
        });
        assert_eq!(serde_json::from_slice::<Value>(&payload).unwrap()["sequence"], 257);
    }

    #[test]
    fn resource_control_accepts_v2_and_preserves_stream_end_reason() {
        let state = FrontendControlState::new(Arc::new(ClientUpdates::default()));
        handle_control_line(
            &state,
            br#"{"protocol":"cmux.protocol/1","type":"stream_end"}"#,
        );
        assert!(!state.resource_stream_ended.load(Ordering::Acquire));

        handle_control_line(
            &state,
            br#"{"protocol":"cmux.protocol/2","type":"stream_end","reason":"gap"}"#,
        );
        assert!(state.resource_stream_ended.load(Ordering::Acquire));
        assert_eq!(
            state.resource_stream_end_reason.load(Ordering::Acquire),
            RESOURCE_STREAM_END_GAP
        );

        state.begin_resource_stream();
        assert!(!state.resource_stream_ended.load(Ordering::Acquire));
        assert_eq!(
            state.resource_stream_end_reason.load(Ordering::Acquire),
            RESOURCE_STREAM_END_NONE
        );

        handle_control_line(
            &state,
            br#"{"protocol":"cmux.protocol/2","type":"stream_end","reason":"error"}"#,
        );
        let mut descriptor = CmuxFrontendResourceUpdate {
            payload_length: 0,
            overflowed: false,
            ended: false,
            end_reason: 0,
        };
        assert!(unsafe {
            copy_resource_update_from_state(&state, &mut descriptor, std::ptr::null_mut(), 0)
        });
        assert!(descriptor.ended);
        assert_eq!(descriptor.end_reason, u32::from(RESOURCE_STREAM_END_ERROR));
    }

    #[test]
    fn native_render_payload_copy_survives_resync() {
        let runtime = Runtime::new().unwrap();
        let state = Arc::new(Mutex::new(
            ClientState::new(
                "test".into(),
                "memory".into(),
                1,
                TerminalPublicId::parse("term_0123456789abcdef0123456789abcdef").unwrap(),
            )
            .unwrap(),
        ));
        {
            let mut state = state.lock().unwrap();
            state.enable_native_render_events();
            assert!(state.push_native_render_event(
                NativeRenderEventKind::Bytes,
                80,
                24,
                b"old".to_vec(),
            ));
        }
        let terminal = CmuxFrontendTerminal {
            runtime: runtime.handle().clone(),
            state: state.clone(),
            updates: Arc::new(ClientUpdates::default()),
            active: Mutex::new(None),
            next_request: AtomicU64::new(1),
        };
        let mut descriptor =
            CmuxFrontendRenderEvent { kind: 0, cols: 0, rows: 0, payload_length: 0 };
        assert!(unsafe {
            cmux_frontend_terminal_copy_next_render_event(
                &terminal,
                &mut descriptor,
                std::ptr::null_mut(),
                0,
            )
        });
        {
            let mut state = state.lock().unwrap();
            state
                .prepare_handshake(
                    TerminalPublicId::parse("term_0123456789abcdef0123456789abcdef").unwrap(),
                )
                .unwrap();
            assert!(state.push_native_render_event(
                NativeRenderEventKind::Reset,
                100,
                30,
                b"authoritative".to_vec(),
            ));
        }
        let mut payload = [0_u8; 3];
        assert!(unsafe {
            cmux_frontend_terminal_copy_next_render_event(
                &terminal,
                &mut descriptor,
                payload.as_mut_ptr(),
                payload.len(),
            )
        });
        assert_eq!(payload, *b"old");
        assert_eq!(descriptor.kind, NativeRenderEventKind::Bytes as u32);
    }

    #[test]
    fn resource_lanes_keep_mutations_ordered_with_terminal_input() {
        assert_eq!(classify_resource_request("pane.split", true), Lane::Interactive);
        assert_eq!(classify_resource_request("session.snapshot", false), Lane::Bulk);
        assert_eq!(classify_resource_request("workspace.list", false), Lane::Control);
    }

    #[test]
    fn response_routing_is_by_public_string_request_id() {
        let updates = Arc::new(ClientUpdates::default());
        let state = FrontendControlState::new(updates);
        let (sender, receiver) = oneshot::channel();
        state.pending.lock().unwrap().insert("native-test-1".into(), sender);
        let response_line = serde_json::to_vec(&json!({
            "protocol": RESOURCE_PROTOCOL,
            "type": "response",
            "id": "native-test-1",
            "ok": true,
            "result": {"value": 1},
        }))
        .unwrap();
        handle_control_line(&state, &response_line);
        let runtime = Runtime::new().unwrap();
        let response = runtime
            .block_on(tokio::time::timeout(Duration::from_secs(1), receiver))
            .expect("resource response timed out")
            .unwrap()
            .unwrap();
        assert_eq!(response["result"]["value"], 1);
    }
}
