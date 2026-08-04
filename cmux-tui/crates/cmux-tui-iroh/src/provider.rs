//! Machine-provider v1 provider over stdio.
//!
//! Launched by the TUI as `cmux-tui --machine-provider-command cmux-tui-iroh
//! provider --`, which appends `control` or `stream` per the v1 contract.
//!
//! The control process owns the account discovery view, the pair-grant
//! requests, and the single iroh endpoint. Stream processes cannot share that
//! endpoint across process boundaries, so each transport ticket embeds the
//! path of a private, owner-only rendezvous socket: the stream role forwards
//! the client's `TransportHandshake` there, the control process validates the
//! generation bearer and the one-use ticket, opens a fresh bidirectional
//! stream on the admitted connection, and pumps bytes. `RemoteSession` then
//! speaks protocol v10 JSON-lines end to end.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, bail};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_tui_machine_protocol as proto;
use iroh::endpoint::Connection;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::broker::{BrokerClient, BrokerConfig, DiscoveredBinding, Discovery};
use crate::endpoint::{bind_endpoint, dial_by_endpoint_id, fresh_relay_token, log_id};
use crate::identity::{
    Identity, load_credential, load_or_mint_identity, random_uuid, save_identity, state_root,
};
use crate::timefmt::{rfc3339_after, unix_seconds_now};

const DIAL_TIMEOUT: Duration = Duration::from_secs(45);
const TICKET_LIFETIME: Duration = Duration::from_secs(120);
const DISCOVERY_POLL_INTERVAL: Duration = Duration::from_secs(45);
const HANDSHAKE_MAX_BYTES: usize = 1024 * 1024;

pub struct ProviderArgs {
    pub state: Option<PathBuf>,
    pub broker: Option<String>,
    pub tag: Option<String>,
    pub role: String,
}

pub async fn run(args: ProviderArgs) -> anyhow::Result<()> {
    match args.role.as_str() {
        "control" => run_control(args).await,
        "stream" => run_stream().await,
        other => bail!("unknown provider role {other:?} (expected control or stream)"),
    }
}

// ---------------------------------------------------------------------------
// Control role
// ---------------------------------------------------------------------------

struct MachineConn {
    connection: Connection,
    /// Admission stream halves; dropping the send half signals the listener
    /// that this client is gone, so they live as long as the connection.
    _admission_send: iroh::endpoint::SendStream,
    _admission_recv: iroh::endpoint::RecvStream,
    machine_binding_id: String,
}

struct Ticket {
    connection_id: String,
    expires_at_unix: i64,
}

struct ControlState {
    identity: Identity,
    broker: Arc<BrokerClient>,
    state_root: PathBuf,
    hello_token: Option<String>,
    my_binding_id: Option<String>,
    discovery: Option<Discovery>,
    endpoint: Option<iroh::Endpoint>,
    connections: HashMap<String, MachineConn>,
    tickets: HashMap<String, Ticket>,
    rendezvous_path: PathBuf,
}

#[derive(Debug, Serialize, Deserialize)]
struct TicketPayload {
    /// Rendezvous socket path.
    p: String,
    /// One-use secret.
    s: String,
}

async fn run_control(args: ProviderArgs) -> anyhow::Result<()> {
    let root = state_root(args.state.as_deref())?;
    let default_tag = default_client_tag();
    let identity = load_or_mint_identity(&root, Some(args.tag.as_deref().unwrap_or(&default_tag)))?;
    let credential = load_credential(&root)?.context(
        "no device credential; run `cmux-tui-iroh enroll --token <enrollment-token>` first",
    )?;
    let config = BrokerConfig::resolve(args.broker.as_deref());
    let broker = Arc::new(BrokerClient::new(config, credential, root.clone())?);

    // Private rendezvous directory for this control generation.
    let rendezvous_dir = rendezvous_dir()?;
    crate::files::ensure_private_dir(&rendezvous_dir)?;
    let rendezvous_path = rendezvous_dir.join("rv.sock");
    let rendezvous = tokio::net::UnixListener::bind(&rendezvous_path)
        .with_context(|| format!("binding rendezvous socket {}", rendezvous_path.display()))?;

    let state = Arc::new(tokio::sync::Mutex::new(ControlState {
        identity,
        broker,
        state_root: root,
        hello_token: None,
        my_binding_id: None,
        discovery: None,
        endpoint: None,
        connections: HashMap::new(),
        tickets: HashMap::new(),
        rendezvous_path: rendezvous_path.clone(),
    }));

    // Single writer task keeps stdout line-atomic across responses and events.
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::task::spawn_blocking(move || {
        let stdout = std::io::stdout();
        let mut handle = stdout.lock();
        while let Some(line) = out_rx.blocking_recv() {
            if handle.write_all(line.as_bytes()).is_err() || handle.write_all(b"\n").is_err() {
                break;
            }
            if handle.flush().is_err() {
                break;
            }
        }
    });

    // Rendezvous accept loop.
    let rendezvous_state = state.clone();
    tokio::spawn(async move {
        loop {
            match rendezvous.accept().await {
                Ok((socket, _)) => {
                    let state = rendezvous_state.clone();
                    tokio::spawn(async move {
                        if let Err(error) = serve_rendezvous(state, socket).await {
                            eprintln!("cmux-tui-iroh: transport stream failed: {error:#}");
                        }
                    });
                }
                Err(error) => {
                    eprintln!("cmux-tui-iroh: rendezvous accept failed: {error}");
                    break;
                }
            }
        }
    });

    // Discovery change poller -> snapshot_changed events.
    let poll_state = state.clone();
    let poll_tx = out_tx.clone();
    tokio::spawn(async move {
        let mut last_revision: Option<u64> = None;
        loop {
            tokio::time::sleep(DISCOVERY_POLL_INTERVAL).await;
            let (broker, helloed) = {
                let state = poll_state.lock().await;
                (state.broker.clone(), state.hello_token.is_some())
            };
            if !helloed {
                continue;
            }
            let Ok(discovery) = broker.discover().await else { continue };
            let revision = discovery.revision;
            {
                let mut state = poll_state.lock().await;
                state.discovery = Some(discovery);
            }
            if last_revision.is_some() && last_revision != Some(revision) {
                let event = proto::EventEnvelope::new(proto::ProviderEvent::SnapshotChanged(
                    proto::SnapshotChangedEvent { revision },
                ));
                if let Ok(line) = serde_json::to_string(&event) {
                    let _ = poll_tx.send(line);
                }
            }
            last_revision = Some(revision);
        }
    });

    // Control request loop over stdin.
    let stdin = tokio::io::stdin();
    let mut lines = BufReader::new(stdin).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let envelope: proto::RequestEnvelope = match serde_json::from_str(&line) {
            Ok(envelope) => envelope,
            Err(error) => {
                // Reply with a typed error when the id is recoverable.
                if let Some(id) = serde_json::from_str::<serde_json::Value>(&line)
                    .ok()
                    .and_then(|value| value.get("id").and_then(|id| id.as_str().map(String::from)))
                    .and_then(|id| proto::OpaqueId::new(id).ok())
                {
                    send_failure(
                        &out_tx,
                        id,
                        proto::ProviderErrorCode::InvalidInput,
                        format!("unsupported request: {error}"),
                        false,
                    );
                } else {
                    eprintln!("cmux-tui-iroh: undecodable control request: {error}");
                }
                continue;
            }
        };
        let id = envelope.id.clone();
        let response = handle_request(&state, envelope).await;
        match response {
            Ok(line) => {
                let _ = out_tx.send(line);
            }
            Err(failure) => {
                send_failure(&out_tx, id, failure.code, failure.message, failure.retryable);
            }
        }
    }

    // stdin EOF: the client is gone; tear everything down.
    drop(out_tx);
    let _ = writer.await;
    let _ = std::fs::remove_file(&rendezvous_path);
    if let Some(dir) = rendezvous_path.parent() {
        let _ = std::fs::remove_dir(dir);
    }
    Ok(())
}

struct Failure {
    code: proto::ProviderErrorCode,
    message: String,
    retryable: bool,
}

impl Failure {
    fn new(code: proto::ProviderErrorCode, message: impl Into<String>, retryable: bool) -> Self {
        Self { code, message: message.into(), retryable }
    }
}

fn send_failure(
    out_tx: &mpsc::UnboundedSender<String>,
    id: proto::OpaqueId,
    code: proto::ProviderErrorCode,
    message: String,
    retryable: bool,
) {
    let envelope = proto::ResponseEnvelope::<serde_json::Value>::failure(
        id,
        proto::ProviderError { code, message, retryable },
    );
    if let Ok(line) = serde_json::to_string(&envelope) {
        let _ = out_tx.send(line);
    }
}

async fn handle_request(
    state: &Arc<tokio::sync::Mutex<ControlState>>,
    envelope: proto::RequestEnvelope,
) -> Result<String, Failure> {
    let id = envelope.id.clone();
    match envelope.request {
        proto::ProviderRequest::Hello(params) => {
            let mut state = state.lock().await;
            if state.hello_token.is_some() {
                return Err(Failure::new(
                    proto::ProviderErrorCode::InvalidInput,
                    "hello was already negotiated",
                    false,
                ));
            }
            if !params.client.supported_versions.contains(&proto::PROTOCOL_VERSION) {
                return Err(Failure::new(
                    proto::ProviderErrorCode::UnsupportedVersion,
                    "client does not support machine-provider v1",
                    false,
                ));
            }
            state.hello_token = Some(params.token.expose().to_string());
            let result = proto::HelloResult {
                provider_id: opaque("cmux-tui-iroh"),
                provider_name: "cmux iroh devices".to_string(),
                negotiated_version: proto::Version,
            };
            respond(id, result)
        }
        proto::ProviderRequest::NegotiateClientCapabilities(_) => {
            require_hello(state).await?;
            respond(id, proto::NegotiateClientCapabilitiesResult { capabilities: Vec::new() })
        }
        proto::ProviderRequest::Snapshot(_) => {
            require_hello(state).await?;
            let snapshot = build_snapshot(state).await?;
            respond(id, snapshot)
        }
        proto::ProviderRequest::SelectScope(params) => {
            require_hello(state).await?;
            if params.scope_id.as_str() != "personal" {
                return Err(Failure::new(
                    proto::ProviderErrorCode::NotFound,
                    "only the personal scope exists",
                    false,
                ));
            }
            let snapshot = build_snapshot(state).await?;
            respond(id, proto::SelectScopeResult { snapshot })
        }
        proto::ProviderRequest::OpenMachine(params) => {
            require_hello(state).await?;
            if params.workspace_mirror_authority {
                return Err(Failure::new(
                    proto::ProviderErrorCode::InvalidInput,
                    "workspace mirror authority is not supported",
                    false,
                ));
            }
            let result = open_machine(state, params.machine_id.as_str()).await?;
            respond(id, result)
        }
        proto::ProviderRequest::CloseMachine(params) => {
            require_hello(state).await?;
            let mut state = state.lock().await;
            if let Some(machine) = state.connections.remove(params.connection_id.as_str()) {
                machine.connection.close(0u32.into(), b"closed by client");
            }
            let secrets: Vec<String> = state
                .tickets
                .iter()
                .filter(|(_, ticket)| ticket.connection_id == params.connection_id.as_str())
                .map(|(secret, _)| secret.clone())
                .collect();
            for secret in secrets {
                state.tickets.remove(&secret);
            }
            let revision = state.discovery.as_ref().map(|d| d.revision).unwrap_or(0);
            respond(id, proto::CloseMachineResult { revision })
        }
        _ => Err(Failure::new(
            proto::ProviderErrorCode::InvalidInput,
            "this provider does not support that operation",
            false,
        )),
    }
}

fn respond<T: Serialize>(id: proto::OpaqueId, result: T) -> Result<String, Failure> {
    let envelope = proto::ResponseEnvelope::success(id, result);
    serde_json::to_string(&envelope).map_err(|error| {
        Failure::new(
            proto::ProviderErrorCode::Internal,
            format!("encoding response: {error}"),
            false,
        )
    })
}

fn opaque(value: &str) -> proto::OpaqueId {
    proto::OpaqueId::new(value).expect("static opaque id")
}

async fn require_hello(state: &Arc<tokio::sync::Mutex<ControlState>>) -> Result<(), Failure> {
    if state.lock().await.hello_token.is_none() {
        return Err(Failure::new(
            proto::ProviderErrorCode::PermissionDenied,
            "hello must be the first request",
            false,
        ));
    }
    Ok(())
}

async fn ensure_discovery(
    state: &Arc<tokio::sync::Mutex<ControlState>>,
) -> Result<Discovery, Failure> {
    {
        let state = state.lock().await;
        if let Some(discovery) = &state.discovery {
            return Ok(discovery.clone());
        }
    }
    let broker = state.lock().await.broker.clone();
    let discovery = broker.discover().await.map_err(|error| {
        Failure::new(proto::ProviderErrorCode::Unavailable, format!("{error:#}"), true)
    })?;
    let mut state = state.lock().await;
    state.discovery = Some(discovery.clone());
    Ok(discovery)
}

async fn build_snapshot(
    state: &Arc<tokio::sync::Mutex<ControlState>>,
) -> Result<proto::SnapshotResult, Failure> {
    let discovery = ensure_discovery(state).await?;
    let my_device_id = state.lock().await.identity.device_id.clone();
    let machines: Vec<proto::MachineDescriptor> = discovery
        .bindings
        .iter()
        .filter(|binding| {
            binding.platform == "linux"
                && binding.pairing_enabled
                && binding.device_id != my_device_id
        })
        .filter_map(machine_descriptor)
        .collect();
    Ok(proto::SnapshotResult {
        revision: discovery.revision,
        scopes: vec![proto::ScopeDescriptor {
            id: opaque("personal"),
            display_name: "Personal".to_string(),
            kind: proto::ScopeKind::Personal,
            can_admin: false,
        }],
        selected_scope_id: opaque("personal"),
        machines,
        selected_machine_id: None,
        capabilities: proto::ProviderCapabilities::default(),
        actions: Vec::new(),
        notice: None,
    })
}

fn machine_descriptor(binding: &DiscoveredBinding) -> Option<proto::MachineDescriptor> {
    Some(proto::MachineDescriptor {
        id: proto::OpaqueId::new(binding.binding_id.clone()).ok()?,
        display_name: binding
            .display_name
            .clone()
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| binding.tag.clone()),
        subtitle: format!("iroh · {}…", log_id(&binding.endpoint_id)),
        status: proto::MachineStatus::Running,
        connectable: true,
        workspace_create: proto::WorkspaceCreatePolicy::Session,
    })
}

async fn open_machine(
    state: &Arc<tokio::sync::Mutex<ControlState>>,
    machine_id: &str,
) -> Result<proto::OpenMachineResult, Failure> {
    let discovery = ensure_discovery(state).await?;
    let binding = discovery
        .bindings
        .iter()
        .find(|binding| binding.binding_id == machine_id)
        .ok_or_else(|| Failure::new(proto::ProviderErrorCode::NotFound, "unknown machine", false))?
        .clone();

    ensure_connection(state, &binding).await.map_err(|error| {
        Failure::new(proto::ProviderErrorCode::Unavailable, format!("{error:#}"), true)
    })?;

    let mut state_guard = state.lock().await;
    let connection_id = state_guard
        .connections
        .iter()
        .find(|(_, conn)| conn.machine_binding_id == binding.binding_id)
        .map(|(id, _)| id.clone())
        .expect("connection ensured above");
    let secret = new_secret().map_err(|error| {
        Failure::new(proto::ProviderErrorCode::Internal, format!("{error:#}"), false)
    })?;
    let payload = TicketPayload {
        p: state_guard.rendezvous_path.to_string_lossy().to_string(),
        s: secret.clone(),
    };
    let ticket_text = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).map_err(|error| {
        Failure::new(proto::ProviderErrorCode::Internal, format!("{error:#}"), false)
    })?);
    state_guard.tickets.insert(
        secret,
        Ticket {
            connection_id: connection_id.clone(),
            expires_at_unix: unix_seconds_now() + TICKET_LIFETIME.as_secs() as i64,
        },
    );
    let ticket = proto::BearerToken::new(ticket_text).map_err(|_| {
        Failure::new(proto::ProviderErrorCode::Internal, "ticket encoding failed", false)
    })?;
    Ok(proto::OpenMachineResult {
        connection_id: proto::OpaqueId::new(connection_id).map_err(|_| {
            Failure::new(proto::ProviderErrorCode::Internal, "connection id invalid", false)
        })?,
        transport: proto::TransportDescriptor::ProviderStream {
            ticket,
            expires_at: rfc3339_after(TICKET_LIFETIME),
        },
        workspace_mirror_authority: None,
    })
}

/// Ensures an admitted connection to the binding's endpoint, registering our
/// own binding and minting a pair grant on the way.
async fn ensure_connection(
    state: &Arc<tokio::sync::Mutex<ControlState>>,
    binding: &DiscoveredBinding,
) -> anyhow::Result<()> {
    // Drop a dead cached connection for this machine.
    {
        let mut state = state.lock().await;
        let dead: Vec<String> = state
            .connections
            .iter()
            .filter(|(_, conn)| {
                conn.machine_binding_id == binding.binding_id
                    && conn.connection.close_reason().is_some()
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in &dead {
            state.connections.remove(id);
        }
        let alive =
            state.connections.values().any(|conn| conn.machine_binding_id == binding.binding_id);
        if alive {
            return Ok(());
        }
    }

    let (identity, broker, root) = {
        let state = state.lock().await;
        (state.identity.clone(), state.broker.clone(), state.state_root.clone())
    };

    // Resolve or create our own binding (initiator side).
    let my_binding_id = {
        let cached = state.lock().await.my_binding_id.clone();
        match cached {
            Some(id) => id,
            None => {
                let endpoint_id = identity.endpoint_id_hex()?;
                let discovery = ensure_discovery(state)
                    .await
                    .map_err(|failure| anyhow::anyhow!("{}", failure.message))?;
                let existing = discovery
                    .bindings
                    .iter()
                    .find(|candidate| candidate.endpoint_id == endpoint_id)
                    .map(|candidate| candidate.binding_id.clone());
                let id = match existing {
                    Some(id) => id,
                    None => {
                        let registration = broker.register(&identity, false).await?;
                        registration.binding_id
                    }
                };
                let mut state = state.lock().await;
                state.my_binding_id = Some(id.clone());
                if state.identity.binding_id.as_deref() != Some(id.as_str()) {
                    state.identity.binding_id = Some(id.clone());
                    let _ = save_identity(&root, &state.identity);
                }
                id
            }
        }
    };

    let grant = broker.pair_grant(&my_binding_id, &binding.binding_id).await?;

    // Bind the endpoint lazily on first use.
    let endpoint = {
        let existing = state.lock().await.endpoint.clone();
        match existing {
            Some(endpoint) => endpoint,
            None => {
                let relay_token = fresh_relay_token(&broker, &identity, &root).await?;
                let endpoint = bind_endpoint(&identity, &relay_token, false).await?;
                state.lock().await.endpoint = Some(endpoint.clone());
                endpoint
            }
        }
    };

    let connection = dial_by_endpoint_id(&endpoint, &binding.endpoint_id, DIAL_TIMEOUT).await?;
    let (mut admission_send, admission_recv) =
        connection.open_bi().await.context("opening admission stream")?;
    let frame = serde_json::json!({ "v": 1, "grant": grant });
    admission_send
        .write_all(format!("{frame}\n").as_bytes())
        .await
        .context("sending admission frame")?;
    let mut reader = BufReader::new(admission_recv).take(HANDSHAKE_MAX_BYTES as u64);
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(10), reader.read_line(&mut line))
        .await
        .context("admission ack timed out")?
        .context("reading admission ack")?;
    let ack: serde_json::Value =
        serde_json::from_str(line.trim()).context("admission ack is not JSON")?;
    if ack.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
        bail!("admission denied by {}…", log_id(&binding.endpoint_id));
    }

    let connection_id = random_uuid()?;
    let mut state = state.lock().await;
    state.connections.insert(
        connection_id,
        MachineConn {
            connection,
            _admission_send: admission_send,
            _admission_recv: reader.into_inner().into_inner(),
            machine_binding_id: binding.binding_id.clone(),
        },
    );
    Ok(())
}

/// One rendezvous connection: validate the forwarded handshake, open a fresh
/// session stream on the machine connection, ack, then pump bytes.
async fn serve_rendezvous(
    state: Arc<tokio::sync::Mutex<ControlState>>,
    socket: tokio::net::UnixStream,
) -> anyhow::Result<()> {
    let (read_half, mut write_half) = socket.into_split();
    let mut reader = BufReader::new(read_half).take(HANDSHAKE_MAX_BYTES as u64);
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(10), reader.read_line(&mut line))
        .await
        .context("handshake read timed out")?
        .context("reading handshake")?;
    let handshake: proto::TransportHandshake =
        serde_json::from_str(line.trim()).context("parsing transport handshake")?;

    let (send, recv) = {
        let mut state = state.lock().await;
        let expected_token = state.hello_token.clone().context("no hello generation")?;
        if handshake.token.expose() != expected_token {
            deny(&mut write_half).await;
            bail!("transport handshake presented a wrong generation bearer");
        }
        let payload: TicketPayload = serde_json::from_slice(
            &URL_SAFE_NO_PAD.decode(handshake.ticket.expose()).context("ticket base64")?,
        )
        .context("ticket payload")?;
        let Some(ticket) = state.tickets.remove(&payload.s) else {
            deny(&mut write_half).await;
            bail!("unknown or reused transport ticket");
        };
        if ticket.expires_at_unix <= unix_seconds_now() {
            deny(&mut write_half).await;
            bail!("expired transport ticket");
        }
        let Some(machine) = state.connections.get(&ticket.connection_id) else {
            deny(&mut write_half).await;
            bail!("transport ticket references a closed connection");
        };
        machine.connection.open_bi().await.context("opening session stream")?
    };

    let result = serde_json::to_string(&proto::TransportHandshakeResult { accepted: true })?;
    write_half.write_all(format!("{result}\n").as_bytes()).await?;

    let mut socket_read = reader.into_inner().into_inner();
    let (mut stream_send, mut stream_recv) = (send, recv);
    let to_stream = async {
        tokio::io::copy(&mut socket_read, &mut stream_send).await?;
        stream_send.finish().ok();
        Ok::<(), std::io::Error>(())
    };
    let from_stream = async {
        tokio::io::copy(&mut stream_recv, &mut write_half).await?;
        write_half.shutdown().await?;
        Ok::<(), std::io::Error>(())
    };
    let (to_result, from_result) = tokio::join!(to_stream, from_stream);
    to_result.context("client-to-machine copy")?;
    from_result.context("machine-to-client copy")?;
    Ok(())
}

async fn deny(write_half: &mut tokio::net::unix::OwnedWriteHalf) {
    if let Ok(result) = serde_json::to_string(&proto::TransportHandshakeResult { accepted: false })
    {
        let _ = write_half.write_all(format!("{result}\n").as_bytes()).await;
    }
}

fn rendezvous_dir() -> anyhow::Result<PathBuf> {
    let mut random = [0u8; 8];
    getrandom::fill(&mut random).map_err(|error| anyhow::anyhow!("getrandom failed: {error}"))?;
    let suffix: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let uid = unsafe { libc::getuid() };
    Ok(std::env::temp_dir().join(format!("cmux-tui-iroh-{uid}-{suffix}")))
}

fn new_secret() -> anyhow::Result<String> {
    let mut random = [0u8; 24];
    getrandom::fill(&mut random).map_err(|error| anyhow::anyhow!("getrandom failed: {error}"))?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn default_client_tag() -> String {
    let host = std::env::var("HOSTNAME")
        .ok()
        .or_else(|| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .and_then(|output| String::from_utf8(output.stdout).ok())
        })
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "client".to_string());
    let sanitized: String = host
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
        .take(48)
        .collect();
    format!("tui-{}", if sanitized.is_empty() { "client".to_string() } else { sanitized })
}

// ---------------------------------------------------------------------------
// Stream role: a dumb pipe between the client's stdio and the control
// process's rendezvous socket. Runs synchronously; two threads pump bytes.
// ---------------------------------------------------------------------------

async fn run_stream() -> anyhow::Result<()> {
    tokio::task::spawn_blocking(run_stream_blocking).await?
}

fn run_stream_blocking() -> anyhow::Result<()> {
    let stdin = std::io::stdin();
    let mut stdin_lock = stdin.lock();
    let mut line = String::new();
    loop {
        let mut byte = [0u8; 1];
        stdin_lock.read_exact(&mut byte).context("reading transport handshake")?;
        if byte[0] == b'\n' {
            break;
        }
        anyhow::ensure!(line.len() < HANDSHAKE_MAX_BYTES, "transport handshake too large");
        line.push(byte[0] as char);
    }
    let handshake: proto::TransportHandshake =
        serde_json::from_str(line.trim()).context("parsing transport handshake")?;
    let payload: TicketPayload = serde_json::from_slice(
        &URL_SAFE_NO_PAD.decode(handshake.ticket.expose()).context("decoding transport ticket")?,
    )
    .context("parsing transport ticket")?;

    let mut socket = std::os::unix::net::UnixStream::connect(&payload.p)
        .with_context(|| format!("connecting to provider control at {}", payload.p))?;
    socket.write_all(line.as_bytes())?;
    socket.write_all(b"\n")?;
    socket.flush()?;

    // Forward the accept/deny result line, then switch to raw pumping.
    let mut result_line = Vec::new();
    {
        let mut byte = [0u8; 1];
        loop {
            let read = socket.read(&mut byte).context("reading handshake result")?;
            anyhow::ensure!(read == 1, "control closed during handshake");
            result_line.push(byte[0]);
            if byte[0] == b'\n' {
                break;
            }
            anyhow::ensure!(result_line.len() < 4096, "handshake result too large");
        }
    }
    let stdout = std::io::stdout();
    {
        let mut handle = stdout.lock();
        handle.write_all(&result_line)?;
        handle.flush()?;
    }
    let accepted: proto::TransportHandshakeResult =
        serde_json::from_slice(result_line.as_slice()).context("parsing handshake result")?;
    if !accepted.accepted {
        return Ok(());
    }

    let socket_out = socket.try_clone().context("cloning rendezvous socket")?;
    let pump_in = std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut stdin_lock = stdin.lock();
        let mut socket = socket_out;
        let _ = std::io::copy(&mut stdin_lock, &mut socket);
        let _ = socket.shutdown(std::net::Shutdown::Write);
    });
    {
        let mut handle = stdout.lock();
        let _ = std::io::copy(&mut socket, &mut handle);
        let _ = handle.flush();
    }
    let _ = pump_in.join();
    Ok(())
}
