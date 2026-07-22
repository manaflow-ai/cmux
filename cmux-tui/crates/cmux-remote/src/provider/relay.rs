use std::ffi::OsString;
use std::fmt;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use cmux_remote_protocol::{
    CircuitId, LaneToken, REMOTE_PROTOCOL_VERSION, RelayControl, RelayRole,
};
use futures_util::{SinkExt, StreamExt};
use http::StatusCode;
use http::header::{AUTHORIZATION, HeaderValue};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::process::Command;
use tokio::sync::{Mutex, oneshot, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use url::Url;
use zeroize::{Zeroize, Zeroizing};

use crate::daemon::RemoteDaemon;
use crate::link::FrameLink;
use crate::provider::{
    CarrierEvidence, ConnectRequest, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    TransportProvider, TungsteniteWebSocketLink,
};

type RelaySocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

const MAX_RELAY_CREDENTIAL_BYTES: usize = 4 * 1024;
const DEFAULT_CREDENTIAL_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

type CredentialFuture = Pin<Box<dyn Future<Output = Result<String, ()>> + Send + 'static>>;
type CredentialCallback = dyn Fn() -> CredentialFuture + Send + Sync + 'static;

/// A refreshable source for short-lived relay provider credentials.
///
/// The source is queried before each provider-authenticated WebSocket and each
/// register/connect authentication attempt. Clones share callback state but do
/// not cache returned credentials.
#[derive(Clone)]
pub struct RelayCredentialSource {
    inner: Arc<RelayCredentialSourceInner>,
}

enum RelayCredentialSourceInner {
    Static(RelayCredential),
    File(PathBuf),
    Command(CommandCredentialSource),
    Callback(Arc<CredentialCallback>),
}

struct CommandCredentialSource {
    program: OsString,
    args: Vec<OsString>,
    timeout: Duration,
}

#[derive(Clone)]
struct RelayCredential(Zeroizing<String>);

impl RelayCredentialSource {
    /// Keep using one credential. This is the compatibility path used by the
    /// existing `ticket` config fields.
    pub fn static_ticket(ticket: impl Into<String>) -> Result<Self, ProviderError> {
        let credential = RelayCredential::parse(ticket.into())?;
        Ok(Self { inner: Arc::new(RelayCredentialSourceInner::Static(credential)) })
    }

    /// Read the credential afresh from a UTF-8 file on every authentication.
    /// One trailing newline is accepted through surrounding whitespace trim.
    pub fn file(path: impl Into<PathBuf>) -> Self {
        Self { inner: Arc::new(RelayCredentialSourceInner::File(path.into())) }
    }

    /// Execute an argv-based command without a shell on every authentication.
    /// The credential is read from stdout; stderr and command errors are never
    /// included in returned errors.
    pub fn command<I, S>(program: impl Into<OsString>, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Self::command_with_timeout(program, args, DEFAULT_CREDENTIAL_COMMAND_TIMEOUT)
    }

    pub fn command_with_timeout<I, S>(
        program: impl Into<OsString>,
        args: I,
        timeout: Duration,
    ) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Self {
            inner: Arc::new(RelayCredentialSourceInner::Command(CommandCredentialSource {
                program: program.into(),
                args: args.into_iter().map(Into::into).collect(),
                timeout,
            })),
        }
    }

    /// Invoke an async broker callback on every authentication. Callback error
    /// details are intentionally discarded so broker responses cannot leak
    /// secrets through transport error strings.
    pub fn callback<F, Fut, E>(callback: F) -> Self
    where
        F: Fn() -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<String, E>> + Send + 'static,
        E: Send + 'static,
    {
        let callback = Arc::new(move || {
            let future = callback();
            Box::pin(async move { future.await.map_err(|_| ()) }) as CredentialFuture
        });
        Self { inner: Arc::new(RelayCredentialSourceInner::Callback(callback)) }
    }

    async fn fetch(&self) -> Result<RelayCredential, ProviderError> {
        let value = match &*self.inner {
            RelayCredentialSourceInner::Static(credential) => return Ok(credential.clone()),
            RelayCredentialSourceInner::File(path) => read_credential_file(path).await?,
            RelayCredentialSourceInner::Command(command) => {
                read_credential_command(command).await?
            }
            RelayCredentialSourceInner::Callback(callback) => Zeroizing::new(
                callback().await.map_err(|()| credential_source_error("callback failed"))?,
            ),
        };
        RelayCredential::parse_secret(value)
            .map_err(|_| credential_source_error("returned invalid data"))
    }
}

impl fmt::Debug for RelayCredentialSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = match &*self.inner {
            RelayCredentialSourceInner::Static(_) => "static",
            RelayCredentialSourceInner::File(_) => "file",
            RelayCredentialSourceInner::Command(_) => "command",
            RelayCredentialSourceInner::Callback(_) => "callback",
        };
        formatter.debug_struct("RelayCredentialSource").field("kind", &kind).finish()
    }
}

impl RelayCredential {
    fn parse(value: String) -> Result<Self, ProviderError> {
        Self::parse_secret(Zeroizing::new(value))
    }

    fn parse_secret(value: Zeroizing<String>) -> Result<Self, ProviderError> {
        let trimmed = value.trim();
        if value.len() > MAX_RELAY_CREDENTIAL_BYTES
            || trimmed.is_empty()
            || !trimmed.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
        {
            return Err(ProviderError::Configuration(
                "relay credential must be 1-4096 visible ASCII bytes".into(),
            ));
        }
        Ok(Self(Zeroizing::new(trimmed.to_owned())))
    }

    fn expose(&self) -> &str {
        self.0.as_str()
    }
}

impl fmt::Debug for RelayCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RelayCredential([REDACTED])")
    }
}

async fn read_credential_file(path: &Path) -> Result<Zeroizing<String>, ProviderError> {
    let file = tokio::fs::File::open(path)
        .await
        .map_err(|_| credential_source_error("file could not be read"))?;
    read_limited_credential(file)
        .await
        .map_err(|_| credential_source_error("file could not be read"))
}

async fn read_credential_command(
    source: &CommandCredentialSource,
) -> Result<Zeroizing<String>, ProviderError> {
    if source.timeout.is_zero() {
        return Err(credential_source_error("command timeout is invalid"));
    }
    let mut command = Command::new(&source.program);
    command
        .args(&source.args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child =
        command.spawn().map_err(|_| credential_source_error("command could not be started"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| credential_source_error("command stdout was unavailable"))?;
    let result = tokio::time::timeout(source.timeout, async {
        let output = read_limited_credential(stdout).await?;
        let status = child
            .wait()
            .await
            .map_err(|_| credential_source_error("command could not be completed"))?;
        if !status.success() {
            return Err(credential_source_error("command was unsuccessful"));
        }
        Ok(output)
    })
    .await;
    match result {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(error)) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            Err(error)
        }
        Err(_) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            Err(credential_source_error("command timed out"))
        }
    }
}

async fn read_limited_credential(
    reader: impl tokio::io::AsyncRead + Unpin,
) -> Result<Zeroizing<String>, ProviderError> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_RELAY_CREDENTIAL_BYTES.min(256)));
    reader
        .take((MAX_RELAY_CREDENTIAL_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| credential_source_error("could not be read"))?;
    if bytes.len() > MAX_RELAY_CREDENTIAL_BYTES {
        return Err(credential_source_error("was too large"));
    }
    let value = Zeroizing::new(
        std::str::from_utf8(&bytes)
            .map_err(|_| credential_source_error("was not UTF-8"))?
            .to_owned(),
    );
    Ok(value)
}

fn credential_source_error(reason: &str) -> ProviderError {
    ProviderError::Transport(format!("relay credential source {reason}"))
}

#[derive(Clone)]
pub struct RelayClientConfig {
    pub slot: String,
    pub ticket: String,
    pub maximum_frame_bytes: usize,
    pub control_timeout: Duration,
}

impl RelayClientConfig {
    pub fn validate(&self) -> Result<(), ProviderError> {
        self.validate_common()?;
        RelayCredential::parse(self.ticket.clone()).map(|_| ())
    }

    fn validate_common(&self) -> Result<(), ProviderError> {
        validate_identifier("relay slot", &self.slot)?;
        if self.maximum_frame_bytes == 0 || self.control_timeout.is_zero() {
            return Err(ProviderError::Configuration(
                "relay frame limit and control timeout must be positive".into(),
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for RelayClientConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayClientConfig")
            .field("slot", &self.slot)
            .field("ticket", &"[REDACTED]")
            .field("maximum_frame_bytes", &self.maximum_frame_bytes)
            .field("control_timeout", &self.control_timeout)
            .finish()
    }
}

#[derive(Clone)]
pub struct RelayProvider {
    config: RelayClientConfig,
    credentials: RelayCredentialSource,
}

impl RelayProvider {
    pub fn new(mut config: RelayClientConfig) -> Result<Self, ProviderError> {
        if let Err(error) = config.validate_common() {
            config.ticket.zeroize();
            return Err(error);
        }
        let credentials = RelayCredentialSource::static_ticket(std::mem::take(&mut config.ticket))?;
        Self::with_credentials(config, credentials)
    }

    pub fn with_credentials(
        mut config: RelayClientConfig,
        credentials: RelayCredentialSource,
    ) -> Result<Self, ProviderError> {
        config.ticket.zeroize();
        config.validate_common()?;
        Ok(Self { config, credentials })
    }
}

impl fmt::Debug for RelayProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayProvider")
            .field("config", &self.config)
            .field("credentials", &self.credentials)
            .finish()
    }
}

#[async_trait]
impl TransportProvider for RelayProvider {
    fn name(&self) -> &'static str {
        "websocket-relay"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["relay+ws", "relay+wss", "relay+https", "relay+do"]
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let endpoint =
            relay_websocket_url(&request.endpoint, &self.config.slot, RelayRole::Client)?;
        let control = connect_provider_control(&endpoint, &self.credentials).await?;
        Ok(Arc::new(RelayLinkGroup {
            description: format!("relay:{}@{}", self.config.slot, endpoint),
            evidence: CarrierEvidence::Relay {
                provider: endpoint.host_str().unwrap_or("relay").to_string(),
            },
            endpoint,
            config: self.config.clone(),
            credentials: self.credentials.clone(),
            control: Mutex::new(control),
            closed: AtomicBool::new(false),
        }))
    }
}

struct RelayLinkGroup {
    description: String,
    evidence: CarrierEvidence,
    endpoint: Url,
    config: RelayClientConfig,
    credentials: RelayCredentialSource,
    control: Mutex<RelaySocket>,
    closed: AtomicBool,
}

#[async_trait]
impl LinkGroup for RelayLinkGroup {
    fn description(&self) -> &str {
        &self.description
    }

    fn capabilities(&self) -> ProviderCapabilities {
        relay_capabilities(&self.endpoint)
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("relay connection group is closed".into()));
        }
        let lane = LaneToken(random_capability()?);
        let allocation = {
            let mut control = self.control.lock().await;
            if self.closed.load(Ordering::Acquire) {
                return Err(ProviderError::Transport("relay connection group is closed".into()));
            }
            match request_allocation(
                &mut control,
                &self.config,
                &self.credentials,
                &lane,
                request.generation,
            )
            .await
            {
                Ok(allocation) => allocation,
                Err(AllocationError::Terminal(error)) => return Err(error),
                Err(
                    error @ (AllocationError::Reconnect(_) | AllocationError::Authentication(_)),
                ) => {
                    let control_error = error.into_provider_error();
                    if self.closed.load(Ordering::Acquire) {
                        return Err(ProviderError::Transport(
                            "relay connection group is closed".into(),
                        ));
                    }
                    *control = connect_provider_control(&self.endpoint, &self.credentials)
                        .await
                        .map_err(|error| {
                            ProviderError::Transport(format!(
                                "relay control failed ({control_error}); reconnect failed: {error}"
                            ))
                        })?;
                    request_allocation(
                        &mut control,
                        &self.config,
                        &self.credentials,
                        &lane,
                        request.generation,
                    )
                    .await
                    .map_err(AllocationError::into_provider_error)?
                }
            }
        };
        join_circuit(
            &self.endpoint,
            &self.config.slot,
            RelayRole::Client,
            allocation.0,
            lane,
            request.generation,
            allocation.1,
            self.config.maximum_frame_bytes,
            self.config.control_timeout,
        )
        .await
    }

    async fn close(&self) -> Result<(), ProviderError> {
        if !self.closed.swap(true, Ordering::AcqRel) {
            self.control
                .lock()
                .await
                .close(None)
                .await
                .map_err(|_| ProviderError::Transport("relay WebSocket close failed".into()))?;
        }
        Ok(())
    }
}

enum AllocationError {
    Reconnect(ProviderError),
    Authentication(ProviderError),
    Terminal(ProviderError),
}

impl AllocationError {
    fn into_provider_error(self) -> ProviderError {
        match self {
            Self::Reconnect(error) | Self::Authentication(error) | Self::Terminal(error) => error,
        }
    }
}

async fn request_allocation(
    socket: &mut RelaySocket,
    config: &RelayClientConfig,
    credentials: &RelayCredentialSource,
    lane: &LaneToken,
    generation: u64,
) -> Result<(CircuitId, String), AllocationError> {
    let credential = credentials.fetch().await.map_err(AllocationError::Authentication)?;
    send_control(
        socket,
        &RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: config.slot.clone(),
            ticket: credential.expose().to_owned(),
            lane: lane.clone(),
            generation,
        },
    )
    .await
    .map_err(AllocationError::Reconnect)?;
    tokio::time::timeout(config.control_timeout, read_until_allocation(socket, lane, generation))
        .await
        .map_err(|_| {
            AllocationError::Reconnect(ProviderError::Transport(
                "relay allocation timed out".into(),
            ))
        })?
}

async fn read_until_allocation(
    socket: &mut RelaySocket,
    expected_lane: &LaneToken,
    expected_generation: u64,
) -> Result<(CircuitId, String), AllocationError> {
    loop {
        match read_control(socket).await.map_err(AllocationError::Reconnect)? {
            RelayControl::Allocated { circuit, lane, generation, join_ticket }
                if lane == *expected_lane && generation == expected_generation =>
            {
                return Ok((circuit, join_ticket));
            }
            RelayControl::Error { code, .. } => {
                let error = relay_rejection();
                return Err(if relay_authentication_error(&code) {
                    AllocationError::Authentication(error)
                } else {
                    AllocationError::Terminal(error)
                });
            }
            RelayControl::Ping { nonce } => {
                send_control(socket, &RelayControl::Pong { nonce })
                    .await
                    .map_err(AllocationError::Reconnect)?;
            }
            _ => {}
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn join_circuit(
    endpoint: &Url,
    slot: &str,
    role: RelayRole,
    circuit: CircuitId,
    lane: LaneToken,
    generation: u64,
    ticket: String,
    maximum_frame_bytes: usize,
    timeout: Duration,
) -> Result<Box<dyn FrameLink>, ProviderError> {
    let circuit_endpoint = relay_circuit_url(endpoint, &circuit)?;
    let mut socket = connect_relay_socket(&circuit_endpoint, Some(&ticket)).await?;
    send_control(
        &mut socket,
        &RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: slot.to_string(),
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            ticket,
            role,
        },
    )
    .await?;
    tokio::time::timeout(timeout, async {
        loop {
            match read_control(&mut socket).await? {
                RelayControl::Ready {
                    circuit: ready_circuit,
                    lane: ready_lane,
                    generation: ready_generation,
                } if ready_circuit == circuit
                    && ready_lane == lane
                    && ready_generation == generation =>
                {
                    return Ok(());
                }
                RelayControl::Error { .. } => {
                    return Err(relay_rejection());
                }
                _ => {}
            }
        }
    })
    .await
    .map_err(|_| ProviderError::Transport("relay circuit join timed out".into()))??;
    Ok(Box::new(TungsteniteWebSocketLink::new(
        format!("relay-circuit:{}", circuit.0),
        maximum_frame_bytes,
        socket,
    )))
}

#[derive(Clone)]
pub struct RelayDaemonConfig {
    pub endpoint: Url,
    pub slot: String,
    pub ticket: String,
    pub maximum_frame_bytes: usize,
    pub control_timeout: Duration,
}

impl RelayDaemonConfig {
    fn validate_common(&self) -> Result<(), ProviderError> {
        validate_identifier("relay slot", &self.slot)?;
        if self.maximum_frame_bytes == 0 || self.control_timeout.is_zero() {
            return Err(ProviderError::Configuration(
                "relay frame limit and control timeout must be positive".into(),
            ));
        }
        Ok(())
    }
}

impl fmt::Debug for RelayDaemonConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayDaemonConfig")
            .field("endpoint", &self.endpoint)
            .field("slot", &self.slot)
            .field("ticket", &"[REDACTED]")
            .field("maximum_frame_bytes", &self.maximum_frame_bytes)
            .field("control_timeout", &self.control_timeout)
            .finish()
    }
}

pub struct RelayDaemonRegistration {
    shutdown: watch::Sender<bool>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl fmt::Debug for RelayDaemonRegistration {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("RelayDaemonRegistration").finish_non_exhaustive()
    }
}

impl RelayDaemonRegistration {
    pub async fn shutdown(mut self) {
        let _ = self.shutdown.send(true);
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}

impl Drop for RelayDaemonRegistration {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
    }
}

pub async fn register_relay_daemon(
    daemon: Arc<RemoteDaemon>,
    mut config: RelayDaemonConfig,
) -> Result<RelayDaemonRegistration, ProviderError> {
    if let Err(error) = config.validate_common() {
        config.ticket.zeroize();
        return Err(error);
    }
    let credentials = RelayCredentialSource::static_ticket(std::mem::take(&mut config.ticket))?;
    register_relay_daemon_with_credentials(daemon, config, credentials).await
}

pub async fn register_relay_daemon_with_credentials(
    daemon: Arc<RemoteDaemon>,
    mut config: RelayDaemonConfig,
    credentials: RelayCredentialSource,
) -> Result<RelayDaemonRegistration, ProviderError> {
    config.ticket.zeroize();
    config.validate_common()?;
    let endpoint = relay_websocket_url(&config.endpoint, &config.slot, RelayRole::Daemon)?;
    let config = RelayDaemonConfig { endpoint, ..config };
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (ready_tx, ready_rx) = oneshot::channel();
    let task = tokio::spawn(run_registration_loop(
        daemon,
        config,
        credentials,
        shutdown_rx,
        Some(ready_tx),
    ));
    ready_rx.await.map_err(|_| {
        ProviderError::Transport("relay registration stopped before ready".into())
    })??;
    Ok(RelayDaemonRegistration { shutdown: shutdown_tx, task: Some(task) })
}

async fn run_registration_loop(
    daemon: Arc<RemoteDaemon>,
    config: RelayDaemonConfig,
    credentials: RelayCredentialSource,
    mut shutdown: watch::Receiver<bool>,
    mut first_ready: Option<oneshot::Sender<Result<(), ProviderError>>>,
) {
    let mut backoff = Duration::from_millis(100);
    loop {
        if *shutdown.borrow() {
            return;
        }
        if shutdown.has_changed().is_err() {
            return;
        }
        let result = run_registration_once(
            daemon.clone(),
            &config,
            &credentials,
            &mut shutdown,
            &mut first_ready,
        )
        .await;
        if result.is_err()
            && let Some(sender) = first_ready.take()
        {
            let _ = sender.send(Err(ProviderError::Transport(result.unwrap_err().to_string())));
            return;
        }
        if *shutdown.borrow() {
            return;
        }
        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return;
                }
                continue;
            },
        }
        backoff = (backoff * 2).min(Duration::from_secs(5));
    }
}

async fn run_registration_once(
    daemon: Arc<RemoteDaemon>,
    config: &RelayDaemonConfig,
    credentials: &RelayCredentialSource,
    shutdown: &mut watch::Receiver<bool>,
    first_ready: &mut Option<oneshot::Sender<Result<(), ProviderError>>>,
) -> Result<(), ProviderError> {
    let authentication = authenticate_daemon_control(config, credentials);
    tokio::pin!(authentication);
    let (mut socket, lease_seconds) = tokio::select! {
        result = &mut authentication => result?,
        changed = shutdown.changed() => {
            if changed.is_err() || *shutdown.borrow() {
                return Ok(());
            }
            authentication.await?
        }
    };
    let heartbeat = Duration::from_secs(u64::from(lease_seconds).max(3) / 3);
    if let Some(sender) = first_ready.take() {
        let _ = sender.send(Ok(()));
    }
    let mut interval = tokio::time::interval(heartbeat);
    let mut nonce = 0_u64;
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { return Ok(()) }
            }
            _ = interval.tick() => {
                nonce = nonce.wrapping_add(1);
                send_control(&mut socket, &RelayControl::Ping { nonce }).await?;
            }
            message = read_control(&mut socket) => {
                match message? {
                    RelayControl::Incoming { circuit, lane, generation, join_ticket } => {
                        let daemon = daemon.clone();
                        let endpoint = config.endpoint.clone();
                        let slot = config.slot.clone();
                        let maximum = config.maximum_frame_bytes;
                        let timeout = config.control_timeout;
                        tokio::spawn(async move {
                            if let Ok(link) = join_circuit(
                                &endpoint,
                                &slot,
                                RelayRole::Daemon,
                                circuit,
                                lane,
                                generation,
                                join_ticket,
                                maximum,
                                timeout,
                            ).await {
                                let _ = daemon.accept(link).await;
                            }
                        });
                    }
                    RelayControl::Ping { nonce } => {
                        send_control(&mut socket, &RelayControl::Pong { nonce }).await?;
                    }
                    RelayControl::Pong { .. } => {}
                    RelayControl::Error { .. } => {
                        return Err(relay_rejection());
                    }
                    _ => {}
                }
            }
        }
    }
}

async fn authenticate_daemon_control(
    config: &RelayDaemonConfig,
    credentials: &RelayCredentialSource,
) -> Result<(RelaySocket, u32), ProviderError> {
    let mut retried_authentication = false;
    loop {
        let credential = credentials.fetch().await?;
        let mut socket = match connect_relay_socket_once(&config.endpoint, Some(&credential)).await
        {
            Ok(socket) => socket,
            Err(RelaySocketConnectError::Authentication) if !retried_authentication => {
                retried_authentication = true;
                continue;
            }
            Err(error) => return Err(error.into_provider_error()),
        };
        send_control(
            &mut socket,
            &RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: config.slot.clone(),
                ticket: credential.expose().to_owned(),
            },
        )
        .await?;
        let reply = tokio::time::timeout(config.control_timeout, read_control(&mut socket))
            .await
            .map_err(|_| ProviderError::Transport("relay registration timed out".into()))??;
        match reply {
            RelayControl::Registered { lease_seconds } => return Ok((socket, lease_seconds)),
            RelayControl::Error { code, .. }
                if relay_authentication_error(&code) && !retried_authentication =>
            {
                retried_authentication = true;
            }
            RelayControl::Error { .. } => {
                return Err(relay_rejection());
            }
            _ => {
                return Err(ProviderError::Transport(
                    "relay sent an invalid registration reply".into(),
                ));
            }
        }
    }
}

async fn connect_provider_control(
    endpoint: &Url,
    credentials: &RelayCredentialSource,
) -> Result<RelaySocket, ProviderError> {
    let mut retried_authentication = false;
    loop {
        let credential = credentials.fetch().await?;
        match connect_relay_socket_once(endpoint, Some(&credential)).await {
            Ok(socket) => return Ok(socket),
            Err(RelaySocketConnectError::Authentication) if !retried_authentication => {
                retried_authentication = true;
            }
            Err(error) => return Err(error.into_provider_error()),
        }
    }
}

enum RelaySocketConnectError {
    Authentication,
    Provider(ProviderError),
}

impl RelaySocketConnectError {
    fn into_provider_error(self) -> ProviderError {
        match self {
            Self::Authentication => {
                ProviderError::Transport("relay WebSocket authentication was rejected".into())
            }
            Self::Provider(error) => error,
        }
    }
}

async fn connect_relay_socket(
    endpoint: &Url,
    authorization: Option<&str>,
) -> Result<RelaySocket, ProviderError> {
    let credential =
        authorization.map(|ticket| RelayCredential::parse(ticket.to_owned())).transpose()?;
    connect_relay_socket_once(endpoint, credential.as_ref())
        .await
        .map_err(RelaySocketConnectError::into_provider_error)
}

async fn connect_relay_socket_once(
    endpoint: &Url,
    authorization: Option<&RelayCredential>,
) -> Result<RelaySocket, RelaySocketConnectError> {
    let mut request = endpoint.as_str().into_client_request().map_err(|_| {
        RelaySocketConnectError::Provider(ProviderError::Transport(
            "relay WebSocket request could not be built".into(),
        ))
    })?;
    if let Some(credential) = authorization {
        let value = bearer_header(credential).map_err(RelaySocketConnectError::Provider)?;
        request.headers_mut().insert(AUTHORIZATION, value);
    }
    match connect_async(request).await {
        Ok((socket, _)) => Ok(socket),
        Err(tokio_tungstenite::tungstenite::Error::Http(response))
            if matches!(response.status(), StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) =>
        {
            Err(RelaySocketConnectError::Authentication)
        }
        Err(_) => Err(RelaySocketConnectError::Provider(ProviderError::Transport(
            "relay WebSocket connection failed".into(),
        ))),
    }
}

fn bearer_header(credential: &RelayCredential) -> Result<HeaderValue, ProviderError> {
    let mut value = Zeroizing::new(Vec::with_capacity(7 + credential.expose().len()));
    value.extend_from_slice(b"Bearer ");
    value.extend_from_slice(credential.expose().as_bytes());
    let mut header = HeaderValue::from_bytes(&value)
        .map_err(|_| ProviderError::Configuration("relay credential is not header-safe".into()))?;
    header.set_sensitive(true);
    Ok(header)
}

fn relay_authentication_error(code: &str) -> bool {
    matches!(code, "unauthorized" | "invalid-ticket" | "ticket-expired" | "registration-expired")
}

fn relay_rejection() -> ProviderError {
    ProviderError::Transport("relay rejected the authenticated operation".into())
}

async fn send_control(
    socket: &mut RelaySocket,
    control: &RelayControl,
) -> Result<(), ProviderError> {
    let encoded = serde_json::to_string(control)
        .map_err(|error| ProviderError::Transport(error.to_string()))?;
    socket
        .send(Message::Text(encoded.into()))
        .await
        .map_err(|_| ProviderError::Transport("relay WebSocket write failed".into()))
}

async fn read_control(socket: &mut RelaySocket) -> Result<RelayControl, ProviderError> {
    loop {
        match socket.next().await {
            Some(Ok(Message::Text(text))) => {
                return serde_json::from_str(&text).map_err(|error| {
                    ProviderError::Transport(format!("invalid relay control: {error}"))
                });
            }
            Some(Ok(Message::Ping(bytes))) => {
                socket
                    .send(Message::Pong(bytes))
                    .await
                    .map_err(|_| ProviderError::Transport("relay WebSocket write failed".into()))?;
            }
            Some(Ok(Message::Pong(_))) => {}
            Some(Ok(Message::Close(_))) | None => {
                return Err(ProviderError::Transport("relay WebSocket closed".into()));
            }
            Some(Ok(Message::Binary(_))) => {
                return Err(ProviderError::Transport(
                    "relay sent binary data on a control socket".into(),
                ));
            }
            Some(Ok(_)) => {}
            Some(Err(_)) => {
                return Err(ProviderError::Transport("relay WebSocket read failed".into()));
            }
        }
    }
}

fn relay_websocket_url(endpoint: &Url, slot: &str, role: RelayRole) -> Result<Url, ProviderError> {
    let durable_object = endpoint.scheme() == "relay+do";
    if durable_object {
        validate_durable_slot(slot)?;
    }
    let scheme = match endpoint.scheme() {
        "relay+ws" | "ws" => "ws",
        "relay+wss" | "relay+https" | "wss" | "https" => "wss",
        "relay+do" => "wss",
        other => return Err(ProviderError::UnsupportedScheme(other.into())),
    };
    let (_, remainder) = endpoint
        .as_str()
        .split_once("://")
        .ok_or_else(|| ProviderError::Configuration("relay URL has no authority".into()))?;
    let mut endpoint = Url::parse(&format!("{scheme}://{remainder}"))
        .map_err(|error| ProviderError::Configuration(format!("invalid relay URL: {error}")))?;
    if durable_object {
        endpoint.set_path("");
        endpoint
            .path_segments_mut()
            .map_err(|_| ProviderError::Configuration("relay URL cannot be a base URL".into()))?
            .extend([
                "v1",
                "slots",
                slot,
                match role {
                    RelayRole::Daemon => "control",
                    RelayRole::Client => "connect",
                },
            ]);
    } else if endpoint.path().is_empty() || endpoint.path() == "/" {
        endpoint.set_path("/v1/relay");
    }
    endpoint.set_query(None);
    endpoint.set_fragment(None);
    Ok(endpoint)
}

fn relay_capabilities(endpoint: &Url) -> ProviderCapabilities {
    ProviderCapabilities {
        carrier_encryption: endpoint.scheme() == "wss",
        ..ProviderCapabilities::MULTI_STREAM
    }
}

fn relay_circuit_url(endpoint: &Url, circuit: &CircuitId) -> Result<Url, ProviderError> {
    if !endpoint.path().starts_with("/v1/slots/") {
        return Ok(endpoint.clone());
    }
    let mut circuit_endpoint = endpoint.clone();
    circuit_endpoint.set_path("");
    circuit_endpoint
        .path_segments_mut()
        .map_err(|_| ProviderError::Configuration("relay URL cannot be a base URL".into()))?
        .extend(["v1", "circuits", circuit.0.as_str()]);
    Ok(circuit_endpoint)
}

fn validate_identifier(label: &str, value: &str) -> Result<(), ProviderError> {
    if value.is_empty() || value.len() > 256 || value.contains(char::is_whitespace) {
        return Err(ProviderError::Configuration(format!("{label} is invalid")));
    }
    Ok(())
}

fn validate_durable_slot(value: &str) -> Result<(), ProviderError> {
    if value.is_empty()
        || value.len() > 128
        || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(ProviderError::Configuration(
            "Durable Object relay slots must be 1-128 base64url characters".into(),
        ));
    }
    Ok(())
}

fn random_capability() -> Result<String, ProviderError> {
    use base64::Engine as _;
    let mut bytes = [0_u8; 24];
    getrandom::fill(&mut bytes)
        .map_err(|error| ProviderError::Transport(format!("randomness failed: {error}")))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::sync::Mutex as StdMutex;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

    use bytes::Bytes;
    use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
    use tokio::net::TcpListener;
    use tokio::sync::oneshot;
    use tokio_tungstenite::accept_hdr_async;
    use tokio_tungstenite::tungstenite::handshake::server::Request;

    use super::*;

    async fn receive_test_control(socket: &mut WebSocketStream<TcpStream>) -> RelayControl {
        let message = socket.next().await.unwrap().unwrap();
        let Message::Text(text) = message else {
            panic!("expected relay control text, got {message:?}");
        };
        serde_json::from_str(&text).unwrap()
    }

    async fn send_test_control(socket: &mut WebSocketStream<TcpStream>, control: &RelayControl) {
        socket.send(Message::Text(serde_json::to_string(control).unwrap().into())).await.unwrap();
    }

    #[allow(clippy::result_large_err)] // Required by tungstenite's handshake callback signature.
    async fn accept_with_authorization(stream: TcpStream) -> (WebSocketStream<TcpStream>, String) {
        let authorization = Arc::new(StdMutex::new(None));
        let observed = authorization.clone();
        let socket = accept_hdr_async(stream, move |request: &Request, response| {
            let value = request
                .headers()
                .get(AUTHORIZATION)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            *observed.lock().unwrap() = value;
            Ok(response)
        })
        .await
        .unwrap();
        let authorization = authorization.lock().unwrap().take().unwrap();
        (socket, authorization)
    }

    #[tokio::test]
    async fn cancelling_registration_startup_closes_its_spawned_control_loop() {
        use crate::identity::AuthDatabase;
        use crate::session::SessionLimits;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint =
            Url::parse(&format!("relay+ws://{}", listener.local_addr().unwrap())).unwrap();
        let (registered_tx, registered_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut socket, _) = accept_with_authorization(stream).await;
            assert!(matches!(
                receive_test_control(&mut socket).await,
                RelayControl::Register { .. }
            ));
            let _ = registered_tx.send(());
            let closed = tokio::time::timeout(Duration::from_secs(1), socket.next())
                .await
                .expect("cancelled registration left its control socket open");
            matches!(closed, None | Some(Err(_)))
        });

        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "relay-cancel", true).unwrap();
        let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
        let registration = tokio::spawn(register_relay_daemon(
            daemon,
            RelayDaemonConfig {
                endpoint,
                slot: "cancelled-slot".into(),
                ticket: "registration-ticket".into(),
                maximum_frame_bytes: 65_535,
                control_timeout: Duration::from_secs(5),
            },
        ));
        registered_rx.await.unwrap();
        registration.abort();
        assert!(registration.await.unwrap_err().is_cancelled());
        assert!(server.await.unwrap());
    }

    #[test]
    fn durable_object_urls_route_before_websocket_upgrade() {
        let base = Url::parse("relay+do://relay.example/").unwrap();
        let client = relay_websocket_url(&base, "slot_value-1", RelayRole::Client).unwrap();
        let daemon = relay_websocket_url(&base, "slot_value-1", RelayRole::Daemon).unwrap();
        assert_eq!(client.as_str(), "wss://relay.example/v1/slots/slot_value-1/connect");
        assert_eq!(daemon.as_str(), "wss://relay.example/v1/slots/slot_value-1/control");
        let circuit = relay_circuit_url(&client, &CircuitId("abc_123".into())).unwrap();
        assert_eq!(circuit.as_str(), "wss://relay.example/v1/circuits/abc_123");
        assert!(relay_websocket_url(&base, "slot/value", RelayRole::Client).is_err());
    }

    #[test]
    fn relay_capabilities_report_resolved_carrier_encryption() {
        for (route, resolved_scheme, encrypted) in [
            ("relay+ws://relay.example", "ws", false),
            ("relay+wss://relay.example", "wss", true),
            ("relay+https://relay.example", "wss", true),
            ("relay+do://relay.example", "wss", true),
        ] {
            let base = Url::parse(route).unwrap();
            let endpoint = relay_websocket_url(&base, "slot_value-1", RelayRole::Client).unwrap();
            let capabilities = relay_capabilities(&endpoint);
            assert_eq!(endpoint.scheme(), resolved_scheme, "route {route}");
            assert_eq!(capabilities.carrier_encryption, encrypted, "route {route}");
            assert!(capabilities.parallel_links, "route {route}");
        }
    }

    #[test]
    fn unified_relay_keeps_one_websocket_endpoint() {
        let base = Url::parse("relay+wss://relay.example/").unwrap();
        let control = relay_websocket_url(&base, "slot", RelayRole::Client).unwrap();
        assert_eq!(control.as_str(), "wss://relay.example/v1/relay");
        assert_eq!(relay_circuit_url(&control, &CircuitId("ignored".into())).unwrap(), control);
    }

    #[tokio::test]
    async fn file_and_callback_sources_refresh_without_caching() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("relay-ticket");
        tokio::fs::write(&path, "file-ticket-one\n").await.unwrap();
        let file = RelayCredentialSource::file(&path);
        assert_eq!(file.fetch().await.unwrap().expose(), "file-ticket-one");
        tokio::fs::write(&path, "file-ticket-two\n").await.unwrap();
        assert_eq!(file.fetch().await.unwrap().expose(), "file-ticket-two");

        let calls = Arc::new(AtomicUsize::new(0));
        let callback = RelayCredentialSource::callback({
            let calls = calls.clone();
            move || {
                let value = calls.fetch_add(1, AtomicOrdering::SeqCst) + 1;
                async move { Ok::<_, ()>(format!("callback-ticket-{value}")) }
            }
        });
        assert_eq!(callback.fetch().await.unwrap().expose(), "callback-ticket-1");
        assert_eq!(callback.fetch().await.unwrap().expose(), "callback-ticket-2");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn command_source_uses_argv_stdout_and_redacts_its_arguments() {
        let secret = "command-ticket-secret-marker";
        let source =
            RelayCredentialSource::command("sh", ["-c".to_owned(), format!("printf {secret}")]);
        assert!(!format!("{source:?}").contains(secret));
        assert_eq!(source.fetch().await.unwrap().expose(), secret);

        let failing = RelayCredentialSource::command(
            "sh",
            ["-c".to_owned(), format!("printf {secret}; exit 1")],
        );
        assert!(!failing.fetch().await.unwrap_err().to_string().contains(secret));
    }

    #[tokio::test]
    async fn credential_debug_and_errors_are_redacted() {
        let secret = "relay-secret-debug-marker";
        let source = RelayCredentialSource::static_ticket(secret).unwrap();
        assert!(!format!("{source:?}").contains(secret));
        let credential = source.fetch().await.unwrap();
        assert!(!format!("{credential:?}").contains(secret));
        assert!(!format!("{:?}", bearer_header(&credential).unwrap()).contains(secret));

        let client = RelayClientConfig {
            slot: "slot".into(),
            ticket: secret.into(),
            maximum_frame_bytes: 64,
            control_timeout: Duration::from_secs(1),
        };
        assert!(!format!("{client:?}").contains(secret));
        assert!(!format!("{:?}", RelayProvider::new(client).unwrap()).contains(secret));

        let daemon = RelayDaemonConfig {
            endpoint: Url::parse("relay+wss://relay.example").unwrap(),
            slot: "slot".into(),
            ticket: secret.into(),
            maximum_frame_bytes: 64,
            control_timeout: Duration::from_secs(1),
        };
        assert!(!format!("{daemon:?}").contains(secret));

        let callback = RelayCredentialSource::callback({
            let secret = secret.to_owned();
            move || {
                let secret = secret.clone();
                async move { Err::<String, _>(secret) }
            }
        });
        let error = callback.fetch().await.unwrap_err().to_string();
        assert!(!error.contains(secret));
    }

    #[tokio::test]
    async fn daemon_registration_refreshes_after_authentication_rejection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut first, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer register-ticket-1");
            assert!(matches!(
                receive_test_control(&mut first).await,
                RelayControl::Register { ticket, .. } if ticket == "register-ticket-1"
            ));
            send_test_control(
                &mut first,
                &RelayControl::Error {
                    code: "invalid-ticket".into(),
                    message: "rejected".into(),
                    retryable: false,
                },
            )
            .await;

            let (stream, _) = listener.accept().await.unwrap();
            let (mut second, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer register-ticket-2");
            assert!(matches!(
                receive_test_control(&mut second).await,
                RelayControl::Register { ticket, .. } if ticket == "register-ticket-2"
            ));
            send_test_control(&mut second, &RelayControl::Registered { lease_seconds: 30 }).await;
        });
        let calls = Arc::new(AtomicUsize::new(0));
        let credentials = RelayCredentialSource::callback({
            let calls = calls.clone();
            move || {
                let value = calls.fetch_add(1, AtomicOrdering::SeqCst) + 1;
                async move { Ok::<_, ()>(format!("register-ticket-{value}")) }
            }
        });
        let config = RelayDaemonConfig {
            endpoint: Url::parse(&format!("ws://{address}/v1/relay")).unwrap(),
            slot: "test-slot".into(),
            ticket: String::new(),
            maximum_frame_bytes: 64,
            control_timeout: Duration::from_secs(2),
        };
        let (mut socket, lease) = authenticate_daemon_control(&config, &credentials).await.unwrap();
        assert_eq!(lease, 30);
        assert_eq!(calls.load(AtomicOrdering::SeqCst), 2);
        let _ = socket.close(None).await;
        server.await.unwrap();
    }

    #[tokio::test]
    async fn rotating_credentials_refresh_on_connect_authentication_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut failed_control, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer client-ticket-1");
            assert!(matches!(
                receive_test_control(&mut failed_control).await,
                RelayControl::Connect { generation: 7, ticket, .. }
                    if ticket == "client-ticket-2"
            ));
            send_test_control(
                &mut failed_control,
                &RelayControl::Error {
                    code: "unauthorized".into(),
                    message: "expired".into(),
                    retryable: false,
                },
            )
            .await;

            let (stream, _) = listener.accept().await.unwrap();
            let (mut replacement_control, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer client-ticket-3");
            let RelayControl::Connect { lane, generation, ticket, .. } =
                receive_test_control(&mut replacement_control).await
            else {
                panic!("expected client connect on replacement control socket");
            };
            assert_eq!(ticket, "client-ticket-4");
            let circuit = CircuitId("reconnected-circuit".into());
            send_test_control(
                &mut replacement_control,
                &RelayControl::Allocated {
                    circuit: circuit.clone(),
                    lane: lane.clone(),
                    generation,
                    join_ticket: "replacement-join-ticket".into(),
                },
            )
            .await;

            let (stream, _) = listener.accept().await.unwrap();
            let (mut circuit_socket, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer replacement-join-ticket");
            assert_eq!(
                receive_test_control(&mut circuit_socket).await,
                RelayControl::Join {
                    protocol: REMOTE_PROTOCOL_VERSION,
                    slot: "test-slot".into(),
                    circuit: circuit.clone(),
                    lane: lane.clone(),
                    generation,
                    ticket: "replacement-join-ticket".into(),
                    role: RelayRole::Client,
                }
            );
            send_test_control(
                &mut circuit_socket,
                &RelayControl::Ready { circuit, lane, generation },
            )
            .await;
            let message = circuit_socket.next().await.unwrap().unwrap();
            let Message::Binary(payload) = message else {
                panic!("expected circuit payload, got {message:?}");
            };
            circuit_socket.send(Message::Binary(payload)).await.unwrap();
            let _ = circuit_socket.next().await;
            let _ = replacement_control.next().await;
        });

        let calls = Arc::new(AtomicUsize::new(0));
        let credentials = RelayCredentialSource::callback({
            let calls = calls.clone();
            move || {
                let value = calls.fetch_add(1, AtomicOrdering::SeqCst) + 1;
                async move { Ok::<_, ()>(format!("client-ticket-{value}")) }
            }
        });
        let provider = RelayProvider::with_credentials(
            RelayClientConfig {
                slot: "test-slot".into(),
                ticket: "legacy-ticket-must-not-be-used".into(),
                maximum_frame_bytes: 64,
                control_timeout: Duration::from_secs(2),
            },
            credentials,
        )
        .unwrap();
        let group = provider
            .connect(ConnectRequest {
                endpoint: Url::parse(&format!("relay+ws://{address}/v1/relay")).unwrap(),
                session: SessionId::ZERO,
                lane_policy: LanePolicy::Isolated,
                routing: BTreeMap::new(),
            })
            .await
            .unwrap();
        let link = tokio::time::timeout(
            Duration::from_secs(10),
            group.open(LinkRequest { lane: Lane::Interactive, generation: 7 }),
        )
        .await
        .unwrap()
        .unwrap();
        link.send(Bytes::from_static(b"after-reconnect")).await.unwrap();
        assert_eq!(link.receive().await.unwrap().unwrap(), &b"after-reconnect"[..]);
        assert_eq!(calls.load(AtomicOrdering::SeqCst), 4);
        link.close().await.unwrap();
        group.close().await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), server).await.unwrap().unwrap();
    }
}
