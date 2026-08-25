use std::collections::BTreeMap;
use std::ffi::{CStr, c_char, c_void};
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration as StdDuration, Instant};

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
use cmux_tui_core::resource::TerminalPublicId;
use cmux_tui_core::terminal_host_protocol::{
    Frame, FrameDecoder, MAX_FRAME_PAYLOAD, MessageKind, RESIZE_ACK_CANONICAL_CHANGED, encode_frame,
};
use cmux_tui_core::terminal_host_runtime::{
    decode_host_snapshot_payload, decode_terminal_color_overrides,
};
use ghostty_vt::{
    Callbacks, CellWidth, KeyAction, KeyEncoder, RenderState, Terminal, key_input_from_chord,
};
use serde::Serialize;
use tokio::runtime::Runtime;
use url::Url;
use zeroize::Zeroizing;

const CONNECTION_TIMEOUT_ERROR: &str = "terminal connection timed out";
const TERMINAL_RECONNECT_MAX_ATTEMPTS: u32 = 8;
const TERMINAL_RECONNECT_INITIAL_DELAY: StdDuration = StdDuration::from_millis(250);
const TERMINAL_RECONNECT_MAX_DELAY: StdDuration = StdDuration::from_secs(4);

pub struct CmuxTerminalClient {
    runtime: Runtime,
    connection: Arc<ClientConnection>,
    provider: Arc<IrohProvider>,
    multiplexer: Arc<ServiceMultiplexer>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
    terminal: Mutex<Option<ActiveTerminal>>,
    next_request: AtomicU64,
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

impl ClientState {
    fn new(
        provider: String,
        path: String,
        generation: u64,
        terminal_id: TerminalPublicId,
    ) -> Result<Self, String> {
        Ok(Self {
            terminal: None,
            key_encoder: KeyEncoder::new().map_err(|error| error.to_string())?,
            render: RenderState::new().map_err(|error| error.to_string())?,
            frame_text: String::new(),
            frame_rows: Vec::new(),
            frame_dirty_rows: Vec::new(),
            render_dirty: false,
            status: "bootstrap".into(),
            transport_provider: provider,
            transport_path: path,
            generation,
            terminal_id,
            snapshot_boundary: 0,
            snapshot_applied: false,
            snapshot_bytes: 0,
            bootstrap_frames: 0,
            bootstrap_committed: false,
            ready: false,
            exited: false,
            raw_bytes: 0,
            raw_frames: 0,
            local_parser_cursor: 0,
            source_cursor: 0,
            resync_count: 0,
            expected_sequence: None,
            cols: 0,
            rows: 0,
            cell_pixels: (8, 16),
            resize_delivery: None,
            resize_acknowledgement: None,
        })
    }

    fn prepare_handshake(&mut self, terminal_id: TerminalPublicId) -> Result<(), String> {
        self.terminal = None;
        self.render = RenderState::new().map_err(|error| error.to_string())?;
        self.render_dirty = false;
        self.status = "resyncing".into();
        self.terminal_id = terminal_id;
        self.snapshot_boundary = 0;
        self.snapshot_applied = false;
        self.snapshot_bytes = 0;
        self.bootstrap_frames = 0;
        self.bootstrap_committed = false;
        self.ready = false;
        self.exited = false;
        self.expected_sequence = None;
        self.cols = 0;
        self.rows = 0;
        self.cell_pixels = (8, 16);
        self.resize_acknowledgement = None;
        Ok(())
    }

    fn encode_key(&mut self, chord: &str, repeat: bool) -> Result<Vec<u8>, String> {
        let mut input = key_input_from_chord(chord)
            .ok_or_else(|| format!("unsupported terminal key chord: {chord}"))?;
        if repeat {
            input.action = Some(KeyAction::Repeat);
        }
        let terminal = self
            .terminal
            .as_ref()
            .ok_or_else(|| "terminal keyboard state is not ready".to_string())?;
        self.key_encoder.sync_from_terminal(terminal);
        let mut encoded = Vec::new();
        self.key_encoder.encode(&input, &mut encoded).map_err(|error| error.to_string())?;
        Ok(encoded)
    }

    fn apply(&mut self, frame: Frame) -> Result<FrameEffect, String> {
        let effect = match frame.kind {
            MessageKind::Snapshot => {
                let snapshot = decode_host_snapshot_payload(&frame.payload)
                    .map_err(|error| error.to_string())?;
                let mut terminal =
                    Terminal::new(snapshot.cols, snapshot.rows, 100_000, Callbacks::default())
                        .map_err(|error| error.to_string())?;
                terminal
                    .resize(
                        snapshot.cols,
                        snapshot.rows,
                        u32::from(snapshot.cell_pixels.0),
                        u32::from(snapshot.cell_pixels.1),
                    )
                    .map_err(|error| error.to_string())?;
                terminal
                    .apply_vt_replay_parts(
                        &snapshot.replay,
                        &snapshot.kitty_image_aliases,
                        snapshot.kitty_state,
                    )
                    .map_err(|error| error.to_string())?;
                self.cols = snapshot.cols;
                self.rows = snapshot.rows;
                self.cell_pixels = snapshot.cell_pixels;
                self.snapshot_boundary = frame.sequence;
                self.snapshot_bytes = frame.payload.len() as u64;
                self.bootstrap_frames = 1;
                self.local_parser_cursor = frame.sequence;
                self.source_cursor = frame.sequence;
                self.expected_sequence = frame.sequence.checked_add(1);
                self.terminal = Some(terminal);
                self.snapshot_applied = true;
                self.status = "snapshot".into();
                self.render_dirty = true;
                FrameEffect::Continue
            }
            MessageKind::Colors
                if self.snapshot_applied && frame.sequence == self.snapshot_boundary =>
            {
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
                FrameEffect::Continue
            }
            MessageKind::Ready
                if self.snapshot_applied && frame.sequence == self.snapshot_boundary =>
            {
                self.ready = true;
                self.bootstrap_committed = true;
                self.status = "live".into();
                self.bootstrap_frames = self.bootstrap_frames.saturating_add(1);
                FrameEffect::Continue
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
                FrameEffect::Continue
            }
            MessageKind::Resized if matches!(frame.payload.len(), 4 | 8) => {
                self.require_sequence(frame.sequence)?;
                let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]).max(1);
                let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]).max(1);
                let cell_pixels = if frame.payload.len() == 8 {
                    (
                        u16::from_le_bytes([frame.payload[4], frame.payload[5]]).max(1),
                        u16::from_le_bytes([frame.payload[6], frame.payload[7]]).max(1),
                    )
                } else {
                    self.cell_pixels
                };
                self.terminal
                    .as_mut()
                    .ok_or_else(|| "resize arrived before snapshot".to_string())?
                    .resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))
                    .map_err(|error| error.to_string())?;
                self.cols = cols;
                self.rows = rows;
                self.cell_pixels = cell_pixels;
                self.local_parser_cursor = frame.sequence;
                self.render_dirty = true;
                FrameEffect::Continue
            }
            MessageKind::Exit => {
                self.require_sequence(frame.sequence)?;
                self.local_parser_cursor = frame.sequence;
                self.ready = false;
                self.exited = true;
                self.status = "exited".into();
                FrameEffect::Stop
            }
            MessageKind::ResyncRequired => {
                self.source_cursor = frame.sequence;
                self.resync_count = self.resync_count.saturating_add(1);
                self.status = "resync-required".into();
                FrameEffect::Restart
            }
            // Targeted resize acknowledgements are outside the source
            // sequence and carry no render state.
            MessageKind::ResizeAck if frame.sequence == 0 => {
                if frame.request_id == 0 {
                    return Err("ResizeAck request ID is zero".into());
                }
                if frame.payload.len() != 8 {
                    return Err("ResizeAck payload must be 8 bytes".into());
                }
                let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]).max(1);
                let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]).max(1);
                let flags = u32::from_le_bytes([
                    frame.payload[4],
                    frame.payload[5],
                    frame.payload[6],
                    frame.payload[7],
                ]);
                if flags & !RESIZE_ACK_CANONICAL_CHANGED != 0 {
                    return Err(format!("ResizeAck has unknown flags 0x{flags:08x}"));
                }
                let acknowledgement = ResizeAcknowledgement {
                    request_id: frame.request_id,
                    cols,
                    rows,
                    canonical_changed: flags & RESIZE_ACK_CANONICAL_CHANGED != 0,
                };
                self.resize_acknowledgement = Some(acknowledgement);
                if let Some(delivery) = &self.resize_delivery {
                    delivery.acknowledge(frame.request_id);
                }
                FrameEffect::Continue
            }
            other => return Err(format!("unexpected smart terminal frame {other:?}")),
        };
        Ok(effect)
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
        // Snapshot and Colors are one bootstrap transaction. Do not expose
        // their renderable result until the host commits the same boundary
        // with Ready.
        if !self.bootstrap_committed || !self.render_dirty {
            return Ok(());
        }
        let terminal =
            self.terminal.as_mut().ok_or_else(|| "terminal is not initialized".to_string())?;
        self.render.update(terminal).map_err(|error| error.to_string())?;
        let frame = self.render.build_frame().map_err(|error| error.to_string())?;
        let mut text = String::new();
        let mut rows = Vec::with_capacity(frame.styled_rows().len());
        // The UI polls at a bounded cadence. Only the visible viewport is
        // materialized here; raw transport frames never trigger a grid walk,
        // and history remains local in libghostty for a later paged API.
        for row in frame.styled_rows() {
            let mut rendered = String::new();
            append_row(&mut rendered, row);
            text.push_str(&rendered);
            rows.push(rendered);
        }
        self.frame_text = text;
        self.frame_rows = rows;
        self.frame_dirty_rows = frame.dirty_rows;
        self.render_dirty = false;
        Ok(())
    }

    fn diagnostics(&self) -> String {
        serde_json::to_string(&Diagnostics {
            carrier: &self.transport_provider,
            path: &self.transport_path,
            generation: self.generation,
            terminal: self.terminal_id.as_str(),
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

async fn open_terminal_stream(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
) -> Result<Arc<ServiceStream>, String> {
    open_terminal_stream_with_timeout(multiplexer, terminal_id, None).await
}

async fn open_terminal_stream_with_timeout(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
    timeout: Option<StdDuration>,
) -> Result<Arc<ServiceStream>, String> {
    let started = Instant::now();
    let open = async {
        multiplexer
            .open(
                Service::TerminalBytes,
                BTreeMap::from([("terminal".into(), terminal_id.to_string())]),
            )
            .await
            .map_err(|error| format!("open terminal-bytes-v1: {error}"))
    };
    let stream = Arc::new(match timeout {
        Some(timeout) => connect_with_timeout(open, timeout).await?,
        None => open.await?,
    });
    let handshake = async {
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
        Ok::<(), String>(())
    };
    let handshake = match timeout {
        Some(timeout) => {
            connect_with_timeout(handshake, timeout.saturating_sub(started.elapsed())).await
        }
        None => handshake.await,
    };
    if let Err(error) = handshake {
        let _ = stream.close().await;
        return Err(error);
    }
    Ok(stream)
}

async fn connect_client(
    invitation_uri: &str,
    terminal_id: TerminalPublicId,
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
        ClientState::new(
            snapshot.transport.provider,
            path,
            snapshot.generation,
            terminal_id.clone(),
        )
        .map_err(|error| format!("libghostty: {error}"))?,
    ));
    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    let stream = open_terminal_stream(&multiplexer, &terminal_id).await?;
    Ok((stream, connection, provider, multiplexer, state))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamOutcome {
    Restart,
    Stop,
}

fn set_client_status(state: &Arc<Mutex<ClientState>>, updates: &ClientUpdates, status: String) {
    state.lock().unwrap().status = status;
    updates.notify();
}

fn finish_decoder(
    decoder: &FrameDecoder,
    state: &Arc<Mutex<ClientState>>,
    updates: &ClientUpdates,
) -> bool {
    match decoder.finish() {
        Ok(()) => true,
        Err(error) => {
            set_client_status(state, updates, format!("codec: {error}"));
            false
        }
    }
}

async fn receive_frames(
    stream: Arc<ServiceStream>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
) -> StreamOutcome {
    let mut decoder = FrameDecoder::new(MAX_FRAME_PAYLOAD);
    loop {
        match stream.receive().await {
            Ok(Some(chunk)) => {
                if chunk.lane != Lane::Interactive {
                    set_client_status(&state, &updates, "wrong-lane".into());
                    let _ = finish_decoder(&decoder, &state, &updates);
                    return StreamOutcome::Restart;
                }
                match decoder.push(&chunk.payload) {
                    Ok(frames) => {
                        let mut outcome = None;
                        for frame in frames {
                            let applied = state.lock().unwrap().apply(frame);
                            updates.notify();
                            match applied {
                                Ok(FrameEffect::Continue) => {}
                                Ok(FrameEffect::Restart) => {
                                    outcome = Some(StreamOutcome::Restart);
                                    break;
                                }
                                Ok(FrameEffect::Stop) => {
                                    outcome = Some(StreamOutcome::Stop);
                                    break;
                                }
                                Err(error) => {
                                    set_client_status(&state, &updates, error);
                                    let _ = finish_decoder(&decoder, &state, &updates);
                                    return StreamOutcome::Restart;
                                }
                            }
                        }
                        if let Some(outcome) = outcome {
                            let _ = finish_decoder(&decoder, &state, &updates);
                            return outcome;
                        }
                    }
                    Err(error) => {
                        set_client_status(&state, &updates, format!("codec: {error}"));
                        let _ = finish_decoder(&decoder, &state, &updates);
                        return StreamOutcome::Restart;
                    }
                }
                if chunk.finished || chunk.reset {
                    if finish_decoder(&decoder, &state, &updates) {
                        set_client_status(
                            &state,
                            &updates,
                            if chunk.reset { "stream-reset" } else { "stream-closed" }.into(),
                        );
                    }
                    return StreamOutcome::Restart;
                }
            }
            Ok(None) => {
                if finish_decoder(&decoder, &state, &updates) {
                    set_client_status(&state, &updates, "stream-closed".into());
                }
                return StreamOutcome::Restart;
            }
            Err(error) => {
                if finish_decoder(&decoder, &state, &updates) {
                    set_client_status(&state, &updates, format!("stream: {error}"));
                }
                return StreamOutcome::Restart;
            }
        }
    }
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
}

impl TerminalStreamSupervisor {
    async fn run(self) {
        let Self {
            multiplexer,
            terminal_id,
            initial_stream,
            streams,
            closed,
            close_notify,
            state,
            updates,
        } = self;
        let mut stream = initial_stream;
        loop {
            let outcome = receive_frames(stream.clone(), state.clone(), updates.clone()).await;
            let current = streams.send_replace(None);
            if let Some(current) = current {
                let _ = current.close().await;
            }
            if outcome == StreamOutcome::Stop {
                closed.store(true, Ordering::Release);
                close_notify.notify_waiters();
                return;
            }
            if closed.load(Ordering::Acquire) {
                return;
            }
            if let Err(error) = state.lock().unwrap().prepare_handshake(terminal_id.clone()) {
                set_client_status(&state, &updates, format!("resync: {error}"));
                return;
            }
            updates.notify();
            let mut attempt: u32 = 0;
            loop {
                if closed.load(Ordering::Acquire) {
                    return;
                }
                match open_terminal_stream(&multiplexer, &terminal_id).await {
                    Ok(next) => {
                        stream = next;
                        streams.send_replace(Some(stream.clone()));
                        break;
                    }
                    Err(error) => {
                        attempt = attempt.saturating_add(1);
                        if attempt >= TERMINAL_RECONNECT_MAX_ATTEMPTS {
                            set_client_status(
                                &state,
                                &updates,
                                format!("reconnect-failed: {error}"),
                            );
                            closed.store(true, Ordering::Release);
                            close_notify.notify_waiters();
                            return;
                        }
                        set_client_status(
                            &state,
                            &updates,
                            format!(
                                "reconnect {attempt}/{TERMINAL_RECONNECT_MAX_ATTEMPTS}: {error}"
                            ),
                        );
                        tokio::select! {
                            _ = tokio::time::sleep(terminal_reconnect_delay(&terminal_id, attempt)) => {}
                            _ = close_notify.notified() => return,
                        }
                    }
                }
            }
        }
    }
}

fn terminal_reconnect_delay(terminal_id: &TerminalPublicId, attempt: u32) -> StdDuration {
    let multiplier = 1_u32.checked_shl(attempt.saturating_sub(1).min(16)).unwrap_or(u32::MAX);
    let base = TERMINAL_RECONNECT_INITIAL_DELAY
        .saturating_mul(multiplier)
        .min(TERMINAL_RECONNECT_MAX_DELAY);
    let identity_jitter =
        terminal_id.as_str().bytes().fold(u64::from(attempt), |hash, byte| {
            hash.wrapping_mul(33).wrapping_add(u64::from(byte))
        }) % 101;
    base.saturating_add(StdDuration::from_millis(identity_jitter))
}

async fn supervise_resizes(
    mut streams: tokio::sync::watch::Receiver<Option<Arc<ServiceStream>>>,
    closed: Arc<AtomicBool>,
    delivery: Arc<ResizeDelivery>,
    send_lock: Arc<tokio::sync::Mutex<()>>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
) {
    loop {
        if closed.load(Ordering::Acquire) {
            return;
        }
        let Some(request) = delivery.desired() else {
            let changed = delivery.changed.notified();
            if delivery.desired().is_some() {
                continue;
            }
            tokio::select! {
                _ = changed => {}
                result = streams.changed() => {
                    if result.is_err() {
                        return;
                    }
                }
            }
            continue;
        };
        let Some(stream) = streams.borrow().clone() else {
            if streams.changed().await.is_err() {
                return;
            }
            continue;
        };

        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&request.cols.to_le_bytes());
        payload.extend_from_slice(&request.rows.to_le_bytes());
        let mut frame = Frame::new(MessageKind::ViewerSize, payload);
        frame.request_id = request.request_id;
        let encoded = match encode_frame(&frame) {
            Ok(encoded) => Bytes::from(encoded),
            Err(error) => {
                set_client_status(&state, &updates, format!("resize: {error}"));
                delivery.complete_if_current(request.request_id);
                continue;
            }
        };

        let send_result = {
            let _guard = send_lock.lock().await;
            stream.send(encoded).await
        };
        if let Err(error) = send_result {
            set_client_status(&state, &updates, format!("resize-write: {error}"));
            let failed = stream.id();
            loop {
                if closed.load(Ordering::Acquire) {
                    return;
                }
                let replaced = streams.borrow().as_ref().is_none_or(|stream| stream.id() != failed);
                if replaced {
                    break;
                }
                if streams.changed().await.is_err() {
                    return;
                }
            }
            continue;
        }

        loop {
            let acknowledged = delivery.changed.notified();
            if delivery.is_acknowledged(request.request_id) {
                delivery.complete_if_current(request.request_id);
                break;
            }
            let stream_changed = streams.changed();
            tokio::pin!(stream_changed);
            tokio::select! {
                _ = acknowledged => {}
                result = &mut stream_changed => {
                    if result.is_err() {
                        return;
                    }
                    break;
                }
            }
            if closed.load(Ordering::Acquire) {
                return;
            }
        }
    }
}

fn start_terminal_tasks(
    runtime: &Runtime,
    stream: Arc<ServiceStream>,
    multiplexer: Arc<ServiceMultiplexer>,
    terminal_id: TerminalPublicId,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
) -> ActiveTerminal {
    let closed = Arc::new(AtomicBool::new(false));
    let close_notify = Arc::new(tokio::sync::Notify::new());
    let (streams, mut command_streams) = tokio::sync::watch::channel(Some(stream.clone()));
    let resize_streams = streams.subscribe();
    let resize_delivery = Arc::new(ResizeDelivery::default());
    {
        let mut state = state.lock().unwrap();
        state.resize_delivery = Some(resize_delivery.clone());
        state.resize_acknowledgement = None;
    }
    let receiver_task = runtime.spawn(
        TerminalStreamSupervisor {
            multiplexer,
            terminal_id: terminal_id.clone(),
            initial_stream: stream,
            streams: streams.clone(),
            closed: closed.clone(),
            close_notify: close_notify.clone(),
            state: state.clone(),
            updates: updates.clone(),
        }
        .run(),
    );
    let (command_sender, mut commands) = tokio::sync::mpsc::channel::<Bytes>(256);
    let command_state = state.clone();
    let command_updates = updates.clone();
    let command_closed = closed.clone();
    let send_lock = Arc::new(tokio::sync::Mutex::new(()));
    let command_send_lock = send_lock.clone();
    let command_task = runtime.spawn(async move {
        while let Some(command) = commands.recv().await {
            loop {
                if command_closed.load(Ordering::Acquire) {
                    return;
                }
                let current = command_streams.borrow().clone();
                let Some(current) = current else {
                    if command_streams.changed().await.is_err() {
                        return;
                    }
                    continue;
                };
                let send_result = {
                    let _guard = command_send_lock.lock().await;
                    current.send(command.clone()).await
                };
                match send_result {
                    Ok(()) => break,
                    Err(error) => {
                        set_client_status(
                            &command_state,
                            &command_updates,
                            format!("write: {error}"),
                        );
                        let failed = current.id();
                        loop {
                            if command_closed.load(Ordering::Acquire) {
                                return;
                            }
                            let replaced = command_streams
                                .borrow()
                                .as_ref()
                                .is_none_or(|stream| stream.id() != failed);
                            if replaced {
                                break;
                            }
                            if command_streams.changed().await.is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        }
    });
    let resize_task = runtime.spawn(supervise_resizes(
        resize_streams,
        closed.clone(),
        resize_delivery.clone(),
        send_lock,
        state,
        updates,
    ));
    ActiveTerminal {
        terminal_id,
        streams,
        closed,
        close_notify,
        command_sender,
        resize_delivery,
        receiver_task,
        command_task,
        resize_task,
    }
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
        let stream = self.runtime.block_on(open_terminal_stream_with_timeout(
            &self.multiplexer,
            &terminal_id,
            timeout,
        ))?;
        let snapshot = self.runtime.block_on(self.connection.snapshot());
        let path = snapshot
            .transport
            .selected_path
            .as_ref()
            .map(|path| format!("{:?}", path.kind).to_lowercase())
            .unwrap_or_else(|| snapshot.transport.route.clone());
        let next_state = match ClientState::new(
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
        *self.state.lock().unwrap() = next_state;
        self.updates.notify();
        *terminal = Some(start_terminal_tasks(
            &self.runtime,
            stream,
            self.multiplexer.clone(),
            terminal_id,
            self.state.clone(),
            self.updates.clone(),
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
    let Some((attached, closed)) = attached else { return Ok(false) };
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
    let Ok(encoded) = encode_frame(&frame) else { return false };
    let terminal = client.terminal.lock().unwrap();
    let Some(terminal) = terminal.as_ref() else { return false };
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
    tokio::time::timeout(timeout, future).await.map_err(|_| CONNECTION_TIMEOUT_ERROR.to_string())?
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
    let connection = match timeout {
        Some(timeout) => runtime.block_on(connect_with_timeout(
            connect_client(invitation, terminal_id.clone()),
            timeout,
        )),
        None => runtime.block_on(connect_client(invitation, terminal_id.clone())),
    };
    match connection {
        Ok((stream, connection, provider, multiplexer, state)) => {
            let updates = Arc::new(ClientUpdates::default());
            let diagnostics_connection = connection.clone();
            let diagnostics_state = state.clone();
            let diagnostics_updates = updates.clone();
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
                    drop(state);
                    diagnostics_updates.notify();
                }
            });
            let terminal = start_terminal_tasks(
                &runtime,
                stream,
                multiplexer.clone(),
                terminal_id,
                state.clone(),
                updates.clone(),
            );
            Box::into_raw(Box::new(CmuxTerminalClient {
                runtime,
                connection,
                provider,
                multiplexer,
                state,
                updates,
                terminal: Mutex::new(Some(terminal)),
                next_request: AtomicU64::new(1),
            }))
        }
        Err(error) => {
            copy_utf8(&error, error_buffer, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// Connects a terminal client and returns an owning handle, or null on failure.
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
    let Some(client) = (unsafe { client.as_ref() }) else { return };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return };
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
    // Connection teardown may wait on the carrier. Transfer ownership to a
    // background thread so the C call is nonblocking for AppKit.
    let _ = std::thread::Builder::new().name("cmux-terminal-disconnect".into()).spawn(move || {
        let terminal = client.terminal.lock().unwrap().take();
        client.runtime.block_on(async {
            if let Some(terminal) = terminal {
                terminal.close().await;
            }
            client.multiplexer.shutdown().await;
            let _ = client.connection.close().await;
            client.provider.close().await;
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
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
    if request_id.is_null() {
        return false;
    }
    let Some(queued_request_id) = queue_resize(client, cols, rows) else { return false };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
    if request_id.is_null() || cols.is_null() || rows.is_null() || canonical_changed.is_null() {
        return false;
    }
    let state = client.state.lock().unwrap();
    let Some(acknowledgement) = state.resize_acknowledgement else { return false };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return 0 };
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
    let Some(client) = (unsafe { client.as_ref() }) else { return false };
    client.state.lock().unwrap().exited
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, c_void};
    use std::sync::atomic::AtomicU64;

    use async_trait::async_trait;
    use cmux_remote::service::{ServiceError, SessionEndpoint};
    use cmux_remote::session::ReceivedFrame;
    use cmux_remote_protocol::FrameFlags;
    use tokio::sync::{Mutex as AsyncMutex, mpsc, watch};

    use super::*;

    fn test_terminal_id() -> TerminalPublicId {
        TerminalPublicId::parse("term_0123456789abcdef0123456789abcdef").unwrap()
    }

    unsafe extern "C" fn count_update(context: *mut c_void) {
        // SAFETY: the test registers a live AtomicU64 for the callback lifetime.
        let count = unsafe { &*(context.cast::<AtomicU64>()) };
        count.fetch_add(1, Ordering::Relaxed);
    }

    #[test]
    fn terminal_connect_timeout_drops_the_stalled_operation() {
        struct DropSignal(Arc<AtomicBool>);

        impl Drop for DropSignal {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }

        let runtime = Runtime::new().unwrap();
        let dropped = Arc::new(AtomicBool::new(false));
        let result: Result<(), String> = runtime.block_on(connect_with_timeout(
            {
                let dropped = dropped.clone();
                async move {
                    let _signal = DropSignal(dropped);
                    std::future::pending::<Result<(), String>>().await
                }
            },
            StdDuration::from_millis(1),
        ));

        assert_eq!(result.unwrap_err(), CONNECTION_TIMEOUT_ERROR);
        assert!(dropped.load(Ordering::Acquire), "timed-out enrollment future remained live");
    }

    #[test]
    fn update_callback_registration_is_signal_driven_and_synchronously_cleared() {
        let updates = ClientUpdates::default();
        let count = AtomicU64::new(0);
        let context = (&count as *const AtomicU64).cast_mut().cast::<c_void>();

        updates.set_callback(Some(count_update), context);
        assert_eq!(count.load(Ordering::Relaxed), 1, "registration omitted initial state");

        updates.notify();
        assert_eq!(count.load(Ordering::Relaxed), 2, "state change omitted its callback");

        updates.set_callback(None, std::ptr::null_mut());
        updates.notify();
        assert_eq!(
            count.load(Ordering::Relaxed),
            2,
            "callback fired after synchronous unregistration"
        );
    }

    #[test]
    fn resize_delivery_coalesces_to_the_latest_request_until_it_is_acknowledged() {
        let delivery = ResizeDelivery::default();
        let first = ResizeRequest { request_id: 1, cols: 80, rows: 24 };
        let latest = ResizeRequest { request_id: 2, cols: 120, rows: 40 };

        delivery.request(first);
        delivery.request(latest);
        assert_eq!(delivery.desired(), Some(latest));

        delivery.acknowledge(first.request_id);
        delivery.complete_if_current(first.request_id);
        assert_eq!(delivery.desired(), Some(latest));

        delivery.acknowledge(latest.request_id);
        delivery.complete_if_current(latest.request_id);
        assert_eq!(delivery.desired(), None);
    }

    #[test]
    fn resize_acknowledgement_is_validated_and_releases_its_delivery_waiter() {
        let delivery = Arc::new(ResizeDelivery::default());
        let request = ResizeRequest { request_id: 17, cols: 101, rows: 33 };
        delivery.request(request);
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        state.resize_delivery = Some(delivery.clone());

        let mut payload = Vec::new();
        payload.extend_from_slice(&request.cols.to_le_bytes());
        payload.extend_from_slice(&request.rows.to_le_bytes());
        payload.extend_from_slice(&RESIZE_ACK_CANONICAL_CHANGED.to_le_bytes());
        let mut acknowledgement = Frame::new(MessageKind::ResizeAck, payload);
        acknowledgement.request_id = request.request_id;
        assert_eq!(state.apply(acknowledgement).unwrap(), FrameEffect::Continue);
        assert!(delivery.is_acknowledged(request.request_id));
        assert_eq!(
            state.resize_acknowledgement,
            Some(ResizeAcknowledgement {
                request_id: request.request_id,
                cols: request.cols,
                rows: request.rows,
                canonical_changed: true,
            })
        );

        let mut malformed = Frame::new(MessageKind::ResizeAck, vec![0; 8]);
        malformed.request_id = 18;
        malformed.payload[4..8].copy_from_slice(&2_u32.to_le_bytes());
        assert!(state.apply(malformed).unwrap_err().contains("unknown flags"));
    }

    #[test]
    fn final_output_is_materialized_after_terminal_exit() {
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        let boundary = 7;
        let mut snapshot = Frame::new(MessageKind::Snapshot, test_snapshot_payload(b"prompt> "));
        snapshot.sequence = boundary;
        state.apply(snapshot).unwrap();
        let mut ready = Frame::new(MessageKind::Ready, Vec::new());
        ready.sequence = boundary;
        state.apply(ready).unwrap();
        state.materialize_frame().unwrap();

        let mut output = Frame::new(MessageKind::Output, b"final output\r\n".to_vec());
        output.sequence = boundary + 1;
        state.apply(output).unwrap();
        let mut exit = Frame::new(MessageKind::Exit, Vec::new());
        exit.sequence = boundary + 2;
        assert_eq!(state.apply(exit).unwrap(), FrameEffect::Stop);
        state.materialize_frame().unwrap();

        assert!(state.frame_text.contains("final output"), "{}", state.frame_text);
        assert!(!state.ready);
        assert!(state.bootstrap_committed);
    }

    #[test]
    fn a_different_terminal_requires_detach_before_attach() {
        let attached = test_terminal_id();
        let requested = TerminalPublicId::parse("term_fedcba9876543210fedcba9876543210").unwrap();

        assert!(attach_target_already_satisfied(None, &requested).is_ok_and(|value| !value));
        assert!(attach_target_already_satisfied(Some((&attached, false)), &attached).unwrap());
        let error =
            attach_target_already_satisfied(Some((&attached, false)), &requested).unwrap_err();
        assert!(error.contains(attached.as_str()));
        assert!(error.contains(requested.as_str()));
    }

    #[test]
    fn retry_exhaustion_does_not_satisfy_same_terminal_attach() {
        let attached = test_terminal_id();

        assert!(
            !attach_target_already_satisfied(Some((&attached, true)), &attached).unwrap(),
            "a closed terminal owner must be replaced instead of satisfying attach"
        );
    }

    #[test]
    fn utf8_copy_truncates_only_at_character_boundaries() {
        let value = "aé";
        let mut buffer = [0_i8; 3];

        assert_eq!(copy_utf8(value, buffer.as_mut_ptr(), buffer.len()), value.len());
        // SAFETY: copy_utf8 always terminates a nonempty destination.
        let copied = unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_str().unwrap();
        assert_eq!(copied, "a");
    }

    #[test]
    fn terminal_reconnect_backoff_grows_and_is_bounded() {
        let terminal = test_terminal_id();
        let first = terminal_reconnect_delay(&terminal, 1);
        let second = terminal_reconnect_delay(&terminal, 2);
        let saturated = terminal_reconnect_delay(&terminal, u32::MAX);

        assert!(second > first);
        assert!(saturated >= TERMINAL_RECONNECT_MAX_DELAY);
        assert!(
            saturated <= TERMINAL_RECONNECT_MAX_DELAY + StdDuration::from_millis(100),
            "unexpected saturated delay {saturated:?}"
        );
    }

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

    fn test_snapshot_payload(replay: &[u8]) -> Vec<u8> {
        cmux_tui_core::terminal_host_runtime::encode_host_snapshot_payload(
            &cmux_tui_core::terminal_host_runtime::HostSnapshot {
                cols: 80,
                rows: 24,
                cell_pixels: (8, 16),
                replay: replay.to_vec(),
                kitty_image_aliases: Vec::new(),
                kitty_state: ghostty_vt::KittyReplayState::disabled(),
                sequence_boundary: 0,
                colors: ghostty_vt::TerminalColorOverrides::default(),
                pid: None,
                command: Vec::new(),
                cwd: None,
            },
        )
        .unwrap()
    }

    async fn send_test_terminal_frame(stream: &ServiceStream, frame: Frame) {
        stream
            .send_on(Lane::Interactive, Bytes::from(encode_frame(&frame).unwrap()))
            .await
            .unwrap();
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
    fn named_key_encoding_uses_the_local_terminal_keyboard_modes() {
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        state.terminal = Some(Terminal::new(80, 24, 0, Callbacks::default()).unwrap());

        assert_eq!(state.encode_key("up", false).unwrap(), b"\x1b[A");
        state.terminal.as_mut().unwrap().vt_write(b"\x1b[?1h");
        assert_eq!(state.encode_key("up", false).unwrap(), b"\x1bOA");
        assert_eq!(state.encode_key("ctrl+c", false).unwrap(), vec![0x03]);
    }

    #[test]
    fn smart_resize_updates_authoritative_cell_metrics() {
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        let mut snapshot = Frame::new(MessageKind::Snapshot, test_snapshot_payload(b"ready"));
        snapshot.sequence = 7;
        state.apply(snapshot).unwrap();

        let mut resized = Frame::new(MessageKind::Resized, vec![100, 0, 30, 0, 9, 0, 18, 0]);
        resized.sequence = 8;
        state.apply(resized).unwrap();

        assert_eq!((state.cols, state.rows), (100, 30));
        assert_eq!(state.cell_pixels, (9, 18));
        assert_eq!(state.local_parser_cursor, 8);
    }

    #[test]
    fn ready_at_boundary_zero_is_rejected_before_snapshot() {
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        let ready = Frame::new(MessageKind::Ready, Vec::new());

        assert_eq!(state.apply(ready).unwrap_err(), "unexpected smart terminal frame Ready");
        assert!(!state.ready);
        assert!(!state.snapshot_applied);
    }

    #[test]
    fn snapshot_render_is_published_only_after_same_boundary_ready() {
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        let boundary = 7;
        let mut snapshot = Frame::new(MessageKind::Snapshot, test_snapshot_payload(b"prompt> "));
        snapshot.sequence = boundary;
        state.apply(snapshot).unwrap();

        state.materialize_frame().unwrap();
        assert!(state.frame_text.is_empty());
        assert!(state.render_dirty);

        let mut ready = Frame::new(MessageKind::Ready, Vec::new());
        ready.sequence = boundary;
        state.apply(ready).unwrap();
        state.materialize_frame().unwrap();
        assert!(state.frame_text.contains("prompt>"));
        assert!(!state.render_dirty);
    }

    #[test]
    fn terminal_exit_survives_later_diagnostic_status_updates() {
        let mut state =
            ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap();
        let boundary = 3;
        let mut snapshot = Frame::new(MessageKind::Snapshot, test_snapshot_payload(b"done"));
        snapshot.sequence = boundary;
        state.apply(snapshot).unwrap();
        let mut ready = Frame::new(MessageKind::Ready, Vec::new());
        ready.sequence = boundary;
        state.apply(ready).unwrap();
        let mut exit = Frame::new(MessageKind::Exit, Vec::new());
        exit.sequence = boundary + 1;
        assert_eq!(state.apply(exit).unwrap(), FrameEffect::Stop);

        state.status = "stream-closed".into();
        assert!(state.exited);
    }

    #[test]
    fn owning_multiplexer_keeps_frames_flowing_after_open_helper_returns() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            async fn open_owned(
                multiplexer: Arc<ServiceMultiplexer>,
            ) -> (Arc<ServiceMultiplexer>, ServiceStream) {
                let stream = multiplexer
                    .open(
                        Service::TerminalBytes,
                        BTreeMap::from([("terminal".into(), test_terminal_id().to_string())]),
                    )
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

    #[test]
    fn terminal_service_reopens_without_a_second_enrollment() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let daemon_task = tokio::spawn({
                let daemon = daemon.clone();
                async move {
                    for _ in 0..2 {
                        let incoming = daemon.accept().await.unwrap().unwrap();
                        let opened = serde_json::to_vec(&ServiceControl::Opened {
                            service: Service::TerminalBytes,
                        })
                        .unwrap();
                        incoming
                            .stream
                            .send_on(Lane::Interactive, Bytes::from(opened))
                            .await
                            .unwrap();
                        assert!(incoming.stream.receive().await.unwrap().unwrap().finished);
                    }
                }
            });

            let first = open_terminal_stream(&client, &test_terminal_id()).await.unwrap();
            first.close().await.unwrap();
            let second = open_terminal_stream(&client, &test_terminal_id()).await.unwrap();
            assert_ne!(first.id(), second.id());
            second.close().await.unwrap();

            daemon_task.await.unwrap();
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }

    #[test]
    fn failed_terminal_handshake_closes_its_service_stream() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let daemon_task = tokio::spawn({
                let daemon = daemon.clone();
                async move {
                    let incoming = daemon.accept().await.unwrap().unwrap();
                    let invalid = serde_json::to_vec(&ServiceControl::Opened {
                        service: Service::MuxControl,
                    })
                    .unwrap();
                    incoming.stream.send_on(Lane::Interactive, Bytes::from(invalid)).await.unwrap();
                    let closed = tokio::time::timeout(
                        std::time::Duration::from_secs(1),
                        incoming.stream.receive(),
                    )
                    .await
                    .expect("failed handshake left the service registered")
                    .unwrap()
                    .unwrap();
                    assert!(closed.finished, "failed handshake reset instead of closing cleanly");
                    assert!(!closed.reset);
                }
            });

            assert!(open_terminal_stream(&client, &test_terminal_id()).await.is_err());
            daemon_task.await.unwrap();
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }

    #[test]
    fn timed_out_terminal_handshake_closes_its_service_stream() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let daemon_task = tokio::spawn({
                let daemon = daemon.clone();
                async move {
                    let incoming = daemon.accept().await.unwrap().unwrap();
                    tokio::time::timeout(StdDuration::from_secs(1), incoming.stream.receive())
                        .await
                        .expect("timed-out handshake left the service registered")
                        .unwrap()
                        .unwrap()
                }
            });

            let error = open_terminal_stream_with_timeout(
                &client,
                &test_terminal_id(),
                Some(StdDuration::from_millis(25)),
            )
            .await
            .unwrap_err();
            assert_eq!(error, CONNECTION_TIMEOUT_ERROR);
            let closed = daemon_task.await.unwrap();
            assert!(closed.finished, "timed-out handshake reset instead of closing cleanly");
            assert!(!closed.reset);
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }

    #[test]
    fn truncated_terminal_frame_is_reported_when_the_service_finishes() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let stream = Arc::new(
                client
                    .open(
                        Service::TerminalBytes,
                        BTreeMap::from([("terminal".into(), test_terminal_id().to_string())]),
                    )
                    .await
                    .unwrap(),
            );
            let incoming = daemon.accept().await.unwrap().unwrap();
            let state = Arc::new(Mutex::new(
                ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap(),
            ));
            let receiver = tokio::spawn(receive_frames(
                stream,
                state.clone(),
                Arc::new(ClientUpdates::default()),
            ));

            let encoded =
                encode_frame(&Frame::new(MessageKind::Output, b"partial".to_vec())).unwrap();
            incoming
                .stream
                .send_on(Lane::Interactive, Bytes::copy_from_slice(&encoded[..12]))
                .await
                .unwrap();
            incoming.stream.close().await.unwrap();
            receiver.await.unwrap();

            assert!(
                state.lock().unwrap().status.contains("truncated"),
                "stream termination discarded the decoder's buffered prefix"
            );
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }

    #[test]
    fn resync_stops_applying_later_frames_from_the_same_chunk() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let stream = Arc::new(
                client
                    .open(
                        Service::TerminalBytes,
                        BTreeMap::from([("terminal".into(), test_terminal_id().to_string())]),
                    )
                    .await
                    .unwrap(),
            );
            let incoming = daemon.accept().await.unwrap().unwrap();
            let state = Arc::new(Mutex::new(
                ClientState::new("test".into(), "memory".into(), 1, test_terminal_id()).unwrap(),
            ));
            let receiver = tokio::spawn(receive_frames(
                stream,
                state.clone(),
                Arc::new(ClientUpdates::default()),
            ));

            let boundary = 10;
            let frames = [
                Frame {
                    sequence: boundary,
                    ..Frame::new(MessageKind::Snapshot, test_snapshot_payload(b"snapshot"))
                },
                Frame { sequence: boundary, ..Frame::new(MessageKind::Ready, Vec::new()) },
                Frame {
                    sequence: boundary + 1,
                    ..Frame::new(MessageKind::ResyncRequired, Vec::new())
                },
                Frame {
                    sequence: boundary + 2,
                    ..Frame::new(MessageKind::Output, b"must-not-apply".to_vec())
                },
            ];
            let mut chunk = Vec::new();
            for frame in frames {
                chunk.extend_from_slice(&encode_frame(&frame).unwrap());
            }
            incoming.stream.send_on(Lane::Interactive, Bytes::from(chunk)).await.unwrap();

            assert_eq!(receiver.await.unwrap(), StreamOutcome::Restart);
            {
                let mut state = state.lock().unwrap();
                state.materialize_frame().unwrap();
                assert_eq!(state.status, "resync-required");
                assert!(!state.frame_text.contains("must-not-apply"));
            }
            let _ = incoming.stream.close().await;
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }

    #[test]
    fn resync_required_reopens_the_terminal_service_and_applies_a_new_snapshot() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let daemon_task = tokio::spawn({
                let daemon = daemon.clone();
                async move {
                    for round in 0..2 {
                        let incoming = daemon.accept().await.unwrap().unwrap();
                        let opened = serde_json::to_vec(&ServiceControl::Opened {
                            service: Service::TerminalBytes,
                        })
                        .unwrap();
                        incoming
                            .stream
                            .send_on(Lane::Interactive, Bytes::from(opened))
                            .await
                            .unwrap();

                        let boundary = if round == 0 { 10 } else { 20 };
                        let mut snapshot = Frame::new(
                            MessageKind::Snapshot,
                            test_snapshot_payload(if round == 0 { b"first" } else { b"second" }),
                        );
                        snapshot.sequence = boundary;
                        send_test_terminal_frame(&incoming.stream, snapshot).await;

                        let colors = Frame {
                            sequence: boundary,
                            ..Frame::new(
                                MessageKind::Colors,
                                cmux_tui_core::terminal_host_runtime::encode_terminal_color_overrides(
                                    &ghostty_vt::TerminalColorOverrides {
                                        cursor_visual: Some((ghostty_vt::CursorShape::Block, false)),
                                        ..Default::default()
                                    },
                                ),
                            )
                        };
                        send_test_terminal_frame(&incoming.stream, colors).await;
                        let mut ready = Frame::new(MessageKind::Ready, Vec::new());
                        ready.sequence = boundary;
                        send_test_terminal_frame(&incoming.stream, ready).await;

                        if round == 0 {
                            let mut resync =
                                Frame::new(MessageKind::ResyncRequired, Vec::new());
                            resync.sequence = boundary + 1;
                            send_test_terminal_frame(&incoming.stream, resync).await;
                        } else {
                            let mut output =
                                Frame::new(MessageKind::Output, b" recovered".to_vec());
                            output.sequence = boundary + 1;
                            send_test_terminal_frame(&incoming.stream, output).await;
                        }

                        let closed = incoming.stream.receive().await.unwrap().unwrap();
                        assert!(closed.finished || closed.reset);
                    }
                }
            });

            let terminal_id = test_terminal_id();
            let stream = open_terminal_stream(&client, &terminal_id).await.unwrap();
            let state = Arc::new(Mutex::new(
                ClientState::new("test".into(), "memory".into(), 1, terminal_id.clone()).unwrap(),
            ));
            let active = start_terminal_tasks(
                &runtime,
                stream,
                client.clone(),
                terminal_id,
                state.clone(),
                Arc::new(ClientUpdates::default()),
            );

            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                loop {
                    let recovered = {
                        let mut state = state.lock().unwrap();
                        state.materialize_frame().unwrap();
                        state.ready
                            && state.resync_count == 1
                            && state.frame_text.contains("second recovered")
                    };
                    if recovered {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("renderer did not recover from ResyncRequired");

            active.close().await;
            daemon_task.await.unwrap();
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }

    #[test]
    fn terminal_exit_marks_the_smart_client_closed_and_not_ready() {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            let (client_endpoint, daemon_endpoint) = endpoint_pair();
            let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
            let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
            let daemon_task = tokio::spawn({
                let daemon = daemon.clone();
                async move {
                    let incoming = daemon.accept().await.unwrap().unwrap();
                    let opened = serde_json::to_vec(&ServiceControl::Opened {
                        service: Service::TerminalBytes,
                    })
                    .unwrap();
                    incoming.stream.send_on(Lane::Interactive, Bytes::from(opened)).await.unwrap();

                    let boundary = 10;
                    let mut snapshot =
                        Frame::new(MessageKind::Snapshot, test_snapshot_payload(b"prompt> "));
                    snapshot.sequence = boundary;
                    send_test_terminal_frame(&incoming.stream, snapshot).await;
                    let mut ready = Frame::new(MessageKind::Ready, Vec::new());
                    ready.sequence = boundary;
                    send_test_terminal_frame(&incoming.stream, ready).await;
                    let mut exit = Frame::new(MessageKind::Exit, Vec::new());
                    exit.sequence = boundary + 1;
                    send_test_terminal_frame(&incoming.stream, exit).await;

                    let closed = incoming.stream.receive().await.unwrap().unwrap();
                    assert!(closed.finished || closed.reset);
                }
            });

            let terminal_id = test_terminal_id();
            let stream = open_terminal_stream(&client, &terminal_id).await.unwrap();
            let state = Arc::new(Mutex::new(
                ClientState::new("test".into(), "memory".into(), 1, terminal_id.clone()).unwrap(),
            ));
            let active = start_terminal_tasks(
                &runtime,
                stream,
                client.clone(),
                terminal_id,
                state.clone(),
                Arc::new(ClientUpdates::default()),
            );

            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                while !active.closed.load(Ordering::Acquire) {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("terminal exit did not close the smart client input path");
            {
                let state = state.lock().unwrap();
                assert_eq!(state.status, "exited");
                assert!(!state.ready, "an exited terminal must not remain input-ready");
            }

            active.close().await;
            daemon_task.await.unwrap();
            client.shutdown().await;
            daemon.shutdown().await;
        });
    }
}
