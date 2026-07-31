use std::collections::BTreeMap;
use std::ffi::{CStr, c_char};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use base64::Engine;
use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::EnrollmentInvitation;
use cmux_remote::provider::{
    ConnectRequest, IrohProvider, IrohProviderConfig, ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID,
    ROUTING_RELAY_URL, TransportProvider,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer, ServiceStream};
use cmux_remote_protocol::{Lane, LanePolicy, Service, ServiceControl, SessionId};
use cmux_tui_core::apply_terminal_color_overrides;
use cmux_tui_core::terminal_host_protocol::{
    Frame, FrameDecoder, MAX_FRAME_PAYLOAD, MessageKind, encode_frame,
};
use cmux_tui_core::terminal_host_runtime::decode_host_snapshot_payload;
use cmux_tui_core::terminal_host_runtime::decode_terminal_color_overrides;
use ghostty_vt::{Callbacks, CellWidth, RenderState, Terminal};
use serde::Serialize;
use tokio::runtime::Runtime;
use url::Url;
use zeroize::Zeroizing;

pub struct CmuxTerminalClient {
    runtime: Runtime,
    stream: Arc<ServiceStream>,
    connection: Arc<ClientConnection>,
    provider: Arc<IrohProvider>,
    multiplexer: Arc<ServiceMultiplexer>,
    state: Arc<Mutex<ClientState>>,
    command_sender: tokio::sync::mpsc::Sender<Bytes>,
    next_request: AtomicU64,
}

struct ClientState {
    terminal: Option<Terminal>,
    render: RenderState,
    frame_text: String,
    render_dirty: bool,
    status: String,
    transport_provider: String,
    transport_path: String,
    generation: u64,
    surface: u64,
    snapshot_boundary: u64,
    snapshot_bytes: u64,
    bootstrap_frames: u64,
    ready: bool,
    raw_bytes: u64,
    raw_frames: u64,
    local_parser_cursor: u64,
    source_cursor: u64,
    resync_count: u64,
    expected_sequence: Option<u64>,
    cols: u16,
    rows: u16,
}

#[derive(Serialize)]
struct Diagnostics<'a> {
    carrier: &'a str,
    path: &'a str,
    generation: u64,
    surface: u64,
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

impl ClientState {
    fn new(provider: String, path: String, generation: u64, surface: u64) -> Result<Self, String> {
        Ok(Self {
            terminal: None,
            render: RenderState::new().map_err(|error| error.to_string())?,
            frame_text: String::new(),
            render_dirty: false,
            status: "bootstrap".into(),
            transport_provider: provider,
            transport_path: path,
            generation,
            surface,
            snapshot_boundary: 0,
            snapshot_bytes: 0,
            bootstrap_frames: 0,
            ready: false,
            raw_bytes: 0,
            raw_frames: 0,
            local_parser_cursor: 0,
            source_cursor: 0,
            resync_count: 0,
            expected_sequence: None,
            cols: 0,
            rows: 0,
        })
    }

    fn apply(&mut self, frame: Frame) -> Result<(), String> {
        match frame.kind {
            MessageKind::Snapshot => {
                let snapshot = decode_host_snapshot_payload(&frame.payload)
                    .map_err(|error| error.to_string())?;
                let mut terminal =
                    Terminal::new(snapshot.cols, snapshot.rows, 100_000, Callbacks::default())
                        .map_err(|error| error.to_string())?;
                terminal.vt_write(&snapshot.replay);
                self.cols = snapshot.cols;
                self.rows = snapshot.rows;
                self.snapshot_boundary = frame.sequence;
                self.snapshot_bytes = frame.payload.len() as u64;
                self.bootstrap_frames = 1;
                self.local_parser_cursor = frame.sequence;
                self.source_cursor = frame.sequence;
                self.expected_sequence = frame.sequence.checked_add(1);
                self.terminal = Some(terminal);
                self.status = "snapshot".into();
                self.render_dirty = true;
            }
            MessageKind::Colors if frame.sequence == self.snapshot_boundary => {
                let colors = decode_terminal_color_overrides(&frame.payload)
                    .map_err(|error| error.to_string())?;
                apply_terminal_color_overrides(
                    self.terminal
                        .as_mut()
                        .ok_or_else(|| "Colors arrived before snapshot".to_string())?,
                    &colors,
                );
                self.bootstrap_frames = self.bootstrap_frames.saturating_add(1);
                self.render_dirty = true;
            }
            MessageKind::Ready if frame.sequence == self.snapshot_boundary => {
                self.ready = true;
                self.status = "live".into();
                self.bootstrap_frames = self.bootstrap_frames.saturating_add(1);
            }
            MessageKind::Output => {
                self.require_sequence(frame.sequence)?;
                let terminal = self
                    .terminal
                    .as_mut()
                    .ok_or_else(|| "output arrived before snapshot".to_string())?;
                terminal.vt_write(&frame.payload);
                self.raw_bytes = self.raw_bytes.saturating_add(frame.payload.len() as u64);
                self.raw_frames = self.raw_frames.saturating_add(1);
                self.local_parser_cursor = frame.sequence;
                self.render_dirty = true;
            }
            MessageKind::Resized if frame.payload.len() == 4 => {
                self.require_sequence(frame.sequence)?;
                let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]).max(1);
                let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]).max(1);
                self.terminal
                    .as_mut()
                    .ok_or_else(|| "resize arrived before snapshot".to_string())?
                    .resize(cols, rows, 8, 16)
                    .map_err(|error| error.to_string())?;
                self.cols = cols;
                self.rows = rows;
                self.local_parser_cursor = frame.sequence;
                self.render_dirty = true;
            }
            MessageKind::Exit => {
                self.require_sequence(frame.sequence)?;
                self.local_parser_cursor = frame.sequence;
                self.status = "exited".into();
            }
            MessageKind::ResyncRequired => {
                self.source_cursor = frame.sequence;
                self.resync_count = self.resync_count.saturating_add(1);
                self.status = "resync-required".into();
                return Err("terminal stream requested a fresh snapshot".into());
            }
            // Targeted resize acknowledgements are outside the source
            // sequence and carry no render state.
            MessageKind::ResizeAck if frame.sequence == 0 => {}
            other => return Err(format!("unexpected smart terminal frame {other:?}")),
        }
        Ok(())
    }

    fn require_sequence(&mut self, sequence: u64) -> Result<(), String> {
        let expected = self
            .expected_sequence
            .ok_or_else(|| "live frame arrived before snapshot".to_string())?;
        if sequence != expected {
            return Err(format!("terminal sequence gap: expected {expected}, received {sequence}"));
        }
        self.expected_sequence = sequence.checked_add(1);
        self.source_cursor = sequence;
        Ok(())
    }

    fn materialize_frame(&mut self) -> Result<(), String> {
        if !self.render_dirty {
            return Ok(());
        }
        let terminal =
            self.terminal.as_mut().ok_or_else(|| "terminal is not initialized".to_string())?;
        self.render.update(terminal).map_err(|error| error.to_string())?;
        let frame = self.render.build_frame().map_err(|error| error.to_string())?;
        let mut text = String::new();
        // The UI polls at a bounded cadence. Only the visible viewport is
        // materialized here; raw transport frames never trigger a grid walk,
        // and history remains local in libghostty for a later paged API.
        for row in frame.styled_rows() {
            append_row(&mut text, row);
        }
        self.frame_text = text;
        self.render_dirty = false;
        Ok(())
    }

    fn diagnostics(&self) -> String {
        serde_json::to_string(&Diagnostics {
            carrier: &self.transport_provider,
            path: &self.transport_path,
            generation: self.generation,
            surface: self.surface,
            service: "terminal-bytes-v1",
            status: &self.status,
            snapshot_boundary: self.snapshot_boundary,
            snapshot_bytes: self.snapshot_bytes,
            bootstrap_frames: self.bootstrap_frames,
            ready: self.ready,
            raw_bytes: self.raw_bytes,
            raw_frames: self.raw_frames,
            local_parser_cursor: self.local_parser_cursor,
            source_cursor: self.source_cursor,
            resync_count: self.resync_count,
            server_snapshot_rpc_count: 0,
            cols: self.cols,
            rows: self.rows,
        })
        .unwrap_or_else(|_| "{\"status\":\"diagnostics-error\"}".into())
    }
}

fn append_row(output: &mut String, row: &[ghostty_vt::Cell]) {
    for cell in row {
        match cell.width {
            CellWidth::SpacerTail => {}
            _ if cell.text.is_empty() => output.push(' '),
            _ => output.push_str(&cell.text),
        }
    }
    while output.ends_with(' ') {
        output.pop();
    }
    output.push('\n');
}

fn resolve_iroh_route(route: &str) -> Result<(Url, BTreeMap<String, String>), String> {
    let mut endpoint = Url::parse(route).map_err(|error| format!("Iroh route: {error}"))?;
    if endpoint.scheme() != "iroh" {
        return Err("route is not an Iroh URL".into());
    }
    let node_id =
        endpoint.host_str().ok_or_else(|| "Iroh route has no node id".to_string())?.to_string();
    let query = endpoint.query_pairs().into_owned().collect::<Vec<_>>();
    endpoint.set_query(None);
    let mut routing = BTreeMap::from([(ROUTING_NODE_ID.into(), node_id)]);
    for (key, value) in query {
        let key = match key.as_str() {
            "node_id" => ROUTING_NODE_ID,
            "relay" | "relay_url" => ROUTING_RELAY_URL,
            "direct" | "direct_addrs" => ROUTING_DIRECT_ADDRS,
            _ => return Err("Iroh route contains an unsupported parameter".into()),
        };
        routing.entry(key.into()).or_insert(value);
    }
    Ok((endpoint, routing))
}

async fn connect_client(
    invitation_uri: &str,
    surface: u64,
) -> Result<
    (
        Arc<ServiceStream>,
        Arc<ClientConnection>,
        Arc<IrohProvider>,
        Arc<ServiceMultiplexer>,
        Arc<Mutex<ClientState>>,
    ),
    String,
> {
    let invitation = EnrollmentInvitation::from_uri(invitation_uri)
        .map_err(|error| format!("invitation: {error}"))?;
    let route = invitation
        .route_hints
        .iter()
        .find(|route| route.starts_with("iroh://"))
        .ok_or_else(|| "invitation has no Iroh route".to_string())?;
    let (endpoint, routing) = resolve_iroh_route(route)?;
    let mut session_bytes = [0u8; 16];
    getrandom::fill(&mut session_bytes).map_err(|error| error.to_string())?;
    let session = SessionId(session_bytes);
    let provider = Arc::new(
        IrohProvider::new(IrohProviderConfig {
            discovery_n0: true,
            ..IrohProviderConfig::default()
        })
        .map_err(|error| error.to_string())?,
    );
    let group = provider
        .connect(ConnectRequest { endpoint, session, lane_policy: LanePolicy::Isolated, routing })
        .await
        .map_err(|error| format!("Iroh connect: {error}"))?;
    let daemon_key = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&invitation.daemon_public_key)
        .map_err(|error| format!("daemon key: {error}"))?
        .try_into()
        .map_err(|bytes: Vec<u8>| format!("daemon key is {} bytes", bytes.len()))?;
    let invitation_secret = invitation.secret_bytes().map_err(|error| error.to_string())?;
    let connection = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().map_err(|error| error.to_string())?,
            expected_daemon: Some(daemon_key),
            auth: ClientAuthMode::Invitation {
                id: invitation.id,
                secret: Zeroizing::new(invitation_secret),
            },
            device_name: "TerminalBytes Demo".into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: Default::default(),
            reconnect: ReconnectPolicy::default(),
        },
    )
    .await
    .map_err(|error| format!("Noise enrollment: {error}"))?;
    let snapshot = connection.snapshot().await;
    let path = snapshot
        .transport
        .selected_path
        .as_ref()
        .map(|path| format!("{:?}", path.kind).to_lowercase())
        .unwrap_or_else(|| snapshot.transport.route.clone());
    let state = Arc::new(Mutex::new(
        ClientState::new(snapshot.transport.provider, path, snapshot.generation, surface)
            .map_err(|error| format!("libghostty: {error}"))?,
    ));
    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    let stream = Arc::new(
        multiplexer
            .open(Service::TerminalBytes, BTreeMap::from([("surface".into(), surface.to_string())]))
            .await
            .map_err(|error| format!("open terminal-bytes-v1: {error}"))?,
    );
    let opened = stream
        .receive()
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "terminal service closed before Opened".to_string())?;
    let control: ServiceControl =
        serde_json::from_slice(&opened.payload).map_err(|error| error.to_string())?;
    if opened.lane != Lane::Interactive
        || control != (ServiceControl::Opened { service: Service::TerminalBytes })
    {
        return Err("terminal service returned an invalid Opened acknowledgement".into());
    }
    Ok((stream, connection, provider, multiplexer, state))
}

async fn receive_frames(stream: Arc<ServiceStream>, state: Arc<Mutex<ClientState>>) {
    let mut decoder = FrameDecoder::new(MAX_FRAME_PAYLOAD);
    loop {
        match stream.receive().await {
            Ok(Some(chunk)) => {
                if chunk.lane != Lane::Interactive {
                    state.lock().unwrap().status = "wrong-lane".into();
                    break;
                }
                match decoder.push(&chunk.payload) {
                    Ok(frames) => {
                        for frame in frames {
                            if let Err(error) = state.lock().unwrap().apply(frame) {
                                state.lock().unwrap().status = error;
                                return;
                            }
                        }
                    }
                    Err(error) => {
                        state.lock().unwrap().status = format!("codec: {error}");
                        break;
                    }
                }
                if chunk.finished || chunk.reset {
                    break;
                }
            }
            Ok(None) => break,
            Err(error) => {
                state.lock().unwrap().status = format!("stream: {error}");
                break;
            }
        }
    }
}

fn copy_utf8(value: &str, buffer: *mut c_char, capacity: usize) -> usize {
    if !buffer.is_null() && capacity > 0 {
        let count = value.len().min(capacity - 1);
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
    let Ok(encoded) = encode_frame(&frame) else { return false };
    client.command_sender.try_send(Bytes::from(encoded)).is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_connect(
    invitation_uri: *const c_char,
    surface: u64,
    error_buffer: *mut c_char,
    error_capacity: usize,
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
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            copy_utf8(&error.to_string(), error_buffer, error_capacity);
            return std::ptr::null_mut();
        }
    };
    match runtime.block_on(connect_client(invitation, surface)) {
        Ok((stream, connection, provider, multiplexer, state)) => {
            runtime.spawn(receive_frames(stream.clone(), state.clone()));
            let diagnostics_connection = connection.clone();
            let diagnostics_state = state.clone();
            let mut generation = connection.subscribe_generation();
            runtime.spawn(async move {
                while generation.changed().await.is_ok() {
                    let snapshot = diagnostics_connection.snapshot().await;
                    let path = snapshot
                        .transport
                        .selected_path
                        .as_ref()
                        .map(|path| format!("{:?}", path.kind).to_lowercase())
                        .unwrap_or_else(|| snapshot.transport.route.clone());
                    let mut state = diagnostics_state.lock().unwrap();
                    state.transport_provider = snapshot.transport.provider;
                    state.transport_path = path;
                    state.generation = snapshot.generation;
                }
            });
            let (command_sender, mut commands) = tokio::sync::mpsc::channel::<Bytes>(256);
            let command_stream = stream.clone();
            let command_state = state.clone();
            runtime.spawn(async move {
                while let Some(command) = commands.recv().await {
                    if let Err(error) = command_stream.send(command).await {
                        command_state.lock().unwrap().status = format!("write: {error}");
                        break;
                    }
                }
            });
            Box::into_raw(Box::new(CmuxTerminalClient {
                runtime,
                stream,
                connection,
                provider,
                multiplexer,
                state,
                command_sender,
                next_request: AtomicU64::new(1),
            }))
        }
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_disconnect(client: *mut CmuxTerminalClient) {
    if client.is_null() {
        return;
    }
    // SAFETY: ownership of a pointer returned by connect transfers exactly once.
    let client = unsafe { Box::from_raw(client) };
    // Connection teardown may wait on the carrier. Transfer ownership to a
    // background thread so the C call is nonblocking for AppKit.
    let _ = std::thread::Builder::new().name("cmux-terminal-disconnect".into()).spawn(move || {
        let _ = client.runtime.block_on(client.stream.close());
        client.runtime.block_on(client.multiplexer.shutdown());
        let _ = client.runtime.block_on(client.connection.close());
        client.runtime.block_on(client.provider.close());
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_resize(
    client: *mut CmuxTerminalClient,
    cols: u16,
    rows: u16,
) -> bool {
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
    let mut payload = Vec::with_capacity(4);
    payload.extend_from_slice(&cols.max(1).to_le_bytes());
    payload.extend_from_slice(&rows.max(1).to_le_bytes());
    let mut frame = Frame::new(MessageKind::ViewerSize, payload);
    frame.request_id = client.next_request.fetch_add(1, Ordering::Relaxed);
    enqueue_command(client, frame)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_copy_frame(
    client: *const CmuxTerminalClient,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
    let mut state = client.state.lock().unwrap();
    if let Err(error) = state.materialize_frame() {
        state.status = format!("render: {error}");
    }
    copy_utf8(&state.frame_text, buffer, capacity)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_client_copy_diagnostics(
    client: *const CmuxTerminalClient,
    buffer: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
    copy_utf8(&client.state.lock().unwrap().diagnostics(), buffer, capacity)
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicU64;

    use async_trait::async_trait;
    use cmux_remote::service::{ServiceError, SessionEndpoint};
    use cmux_remote::session::ReceivedFrame;
    use cmux_remote_protocol::FrameFlags;
    use tokio::sync::{Mutex as AsyncMutex, mpsc, watch};

    use super::*;

    struct TestEndpoint {
        outgoing: mpsc::Sender<ReceivedFrame>,
        incoming: AsyncMutex<mpsc::Receiver<ReceivedFrame>>,
        sequence: AtomicU64,
        generation: watch::Sender<u64>,
    }

    #[async_trait]
    impl SessionEndpoint for TestEndpoint {
        async fn send_frame(
            &self,
            _generation: Option<u64>,
            lane: Lane,
            stream: u64,
            payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
            self.outgoing
                .send(ReceivedFrame { generation: 0, lane, stream, sequence, flags, payload })
                .await
                .map_err(|_| ServiceError::Closed)?;
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
        let (left_tx, left_rx) = mpsc::channel(16);
        let (right_tx, right_rx) = mpsc::channel(16);
        let (left_generation, _) = watch::channel(0);
        let (right_generation, _) = watch::channel(0);
        (
            Arc::new(TestEndpoint {
                outgoing: left_tx,
                incoming: AsyncMutex::new(right_rx),
                sequence: AtomicU64::new(0),
                generation: left_generation,
            }),
            Arc::new(TestEndpoint {
                outgoing: right_tx,
                incoming: AsyncMutex::new(left_rx),
                sequence: AtomicU64::new(0),
                generation: right_generation,
            }),
        )
    }

    #[test]
    fn bounded_command_queue_preserves_order_and_reports_backpressure() {
        let runtime = Runtime::new().unwrap();
        let (sender, mut receiver) = mpsc::channel::<Bytes>(2);
        let encode = |kind, payload: &'static [u8]| {
            Bytes::from(encode_frame(&Frame::new(kind, payload.to_vec())).unwrap())
        };
        let first = encode(MessageKind::Input, b"one");
        let second = encode(MessageKind::Paste, b"two");
        assert!(sender.try_send(first.clone()).is_ok());
        assert!(sender.try_send(second.clone()).is_ok());
        assert!(
            sender.try_send(encode(MessageKind::Input, b"overflow")).is_err(),
            "a full writer queue must return backpressure instead of blocking"
        );
        runtime.block_on(async {
            assert_eq!(receiver.recv().await.unwrap(), first);
            assert_eq!(receiver.recv().await.unwrap(), second);
        });
    }

    #[test]
    fn invitation_iroh_query_becomes_carrier_routing_hints() {
        let (endpoint, routing) = resolve_iroh_route(
            "iroh://node-id?relay_url=https%3A%2F%2Frelay.example&direct_addrs=127.0.0.1%3A9000",
        )
        .unwrap();
        assert_eq!(endpoint.as_str(), "iroh://node-id");
        assert_eq!(routing.get(ROUTING_NODE_ID).map(String::as_str), Some("node-id"));
        assert_eq!(
            routing.get(ROUTING_RELAY_URL).map(String::as_str),
            Some("https://relay.example")
        );
        assert_eq!(routing.get(ROUTING_DIRECT_ADDRS).map(String::as_str), Some("127.0.0.1:9000"));
    }

    #[test]
    fn owning_multiplexer_keeps_frames_flowing_after_open_helper_returns() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            async fn open_owned(
                multiplexer: Arc<ServiceMultiplexer>,
            ) -> (Arc<ServiceMultiplexer>, ServiceStream) {
                let stream = multiplexer
                    .open(Service::TerminalBytes, BTreeMap::from([("surface".into(), "7".into())]))
                    .await
                    .unwrap();
                (multiplexer, stream)
            }

            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let (owned_multiplexer, stream) = open_owned(client).await;
            let incoming = daemon.accept().await.unwrap().unwrap();
            incoming.stream.send(Bytes::from_static(b"after-return")).await.unwrap();
            let received =
                tokio::time::timeout(std::time::Duration::from_secs(1), stream.receive())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
            assert_eq!(received.payload, Bytes::from_static(b"after-return"));
            owned_multiplexer.shutdown().await;
            daemon.shutdown().await;
        });
    }
}
