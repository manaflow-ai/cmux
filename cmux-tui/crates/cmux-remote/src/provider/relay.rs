use std::collections::{HashMap, HashSet, VecDeque};
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
use bytes::Bytes;
use cmux_deadline::Deadline;
use cmux_remote_protocol::{
    CircuitId, LaneToken, MAX_RELAY_BATCH_BYTES, REMOTE_PROTOCOL_VERSION, RelayControl, RelayRole,
    RelayTicketClaims,
};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{Sink, SinkExt, StreamExt};
use http::StatusCode;
use http::header::{AUTHORIZATION, HeaderValue};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc, oneshot, watch};
use tokio::task::{Id, JoinSet};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::error::UrlError;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};
use tokio_tungstenite::{Connector, MaybeTlsStream, WebSocketStream, client_async_tls_with_config};
use url::Url;
use zeroize::{Zeroize, Zeroizing};

use crate::daemon::{InboundLink, NetworkPeer, RemoteDaemon};

#[path = "relay_credential_read.rs"]
mod credential_read;
#[path = "relay_liveness.rs"]
mod liveness;
use credential_read::*;

/// The last [`CREDENTIAL_COMMAND_STDERR_TAIL_BYTES`] a credential command
/// wrote to stderr, read while it runs so a full pipe never stalls it. The
/// reader stops with the source: it is aborted on drop.
struct StderrTail {
    tail: Arc<std::sync::Mutex<VecDeque<u8>>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl StderrTail {
    fn spawn(stderr: Option<tokio::process::ChildStderr>) -> Self {
        let tail = Arc::new(std::sync::Mutex::new(VecDeque::new()));
        let task = stderr.map(|mut stderr| {
            let tail = tail.clone();
            tokio::spawn(async move {
                let mut chunk = [0_u8; 512];
                while let Ok(read) = stderr.read(&mut chunk).await {
                    if read == 0 {
                        break;
                    }
                    let mut tail = tail.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    tail.extend(chunk.get(..read).unwrap_or_default());
                    let excess = tail.len().saturating_sub(CREDENTIAL_COMMAND_STDERR_TAIL_BYTES);
                    tail.drain(..excess);
                }
            })
        });
        Self { tail, task }
    }

    /// `; stderr: …` with [`stderr_summary`] of the tail, or nothing when it
    /// was empty. Waits briefly for the reader to drain what an exited
    /// command wrote.
    async fn describe(&mut self) -> String {
        if let Some(task) = &mut self.task
            && tokio::time::timeout(Duration::from_millis(100), task).await.is_ok()
        {
            // A finished handle must not be polled again.
            self.task = None;
        }
        let bytes: Vec<u8> = {
            let tail = self.tail.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            tail.iter().copied().collect()
        };
        stderr_summary(&bytes)
    }
}

impl Drop for StderrTail {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}
#[path = "relay_registration_state.rs"]
mod registration_state;
use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    SupportedClientAuthModes, TransportProvider, sanitized_route,
};
use liveness::{
    CHECK_INTERVAL, CLOCK_JUMP, Check, ClockWatch, Ended, Liveness, Retry, random_unit,
};
pub use registration_state::RegistrationState;
#[cfg(test)]
pub(crate) use registration_state::test_wall;
use registration_state::wall_now;

type RelaySocket = WebSocketStream<MaybeTlsStream<TcpStream>>;
type RelayCircuitSink = SplitSink<RelaySocket, Message>;
type RelayCircuitStream = SplitStream<RelaySocket>;

const MAX_RELAY_CREDENTIAL_BYTES: usize = 4 * 1024;
const MAX_RELAY_CONTROL_MESSAGE_BYTES: usize = 16 * 1024;
/// How long one relay WebSocket may take to open (TCP, TLS and the
/// upgrade). The relay answers an upgrade in well under a second; a socket
/// that dies silently mid-open (a Cloud machine whose network is settling
/// just after a restore) would otherwise hold the caller forever. A daemon's
/// registration held that way logs nothing and never retries, so every dial
/// parks on the relay until the daemon restarts (65 s in one measured cold
/// start). Past this, the open fails as a retryable transport error.
pub(crate) const RELAY_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_CREDENTIAL_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
/// The bound on one callback credential fetch ([`RelayCredentialSource::callback`]). A
/// callback asks a platform for a ticket (the hub carrier's `POST /v1/mesh/carrier`, itself
/// bounded at 30 s); one that never answers (a mint that stalls) would hold a registration in
/// `Registering` forever. Past this the fetch fails as a credential source failure, which the
/// registration reports as [`RegistrationState::CredentialUnavailable`] and retries.
pub const CREDENTIAL_CALLBACK_TIMEOUT: Duration = Duration::from_secs(35);
/// A daemon's relay ticket command's timeout ([`RelayCredentialSource::daemon_command`]).
/// A Cloud machine's command (`cmux host cloud carrier-ticket`) waits up to
/// 30 s for the Cloud agent's answer and then exits with its own error code;
/// this leaves it 5 s more to start and exit, so a slow answer that still
/// comes is used, not killed at 10 s and asked for again.
pub const DAEMON_TICKET_COMMAND_TIMEOUT: Duration = Duration::from_secs(35);
/// How much of a failed credential command's stderr its error keeps: the
/// last bytes, where the reason usually is.
const CREDENTIAL_COMMAND_STDERR_TAIL_BYTES: usize = 2 * 1024;
/// Every credential source error starts with this.
const CREDENTIAL_SOURCE_ERROR_PREFIX: &str = "relay credential source ";
const RELAY_BATCH_MAGIC: [u8; 4] = *b"CMXB";
const RELAY_BATCH_VERSION: u8 = 1;
const RELAY_BATCH_HEADER_BYTES: usize = 8;
const RELAY_BATCH_ENTRY_HEADER_BYTES: usize = 4;
const MAX_RELAY_BATCH_FRAMES: usize = 32;
const RELAY_BATCH_QUEUE_FRAMES: usize = 128;
// A batched sender lingers to fill a batch only after this many consecutive
// sends each began within RELAY_BURST_LINGER of the previous one finishing.
// A flood builds that streak within microseconds; typed input at human pace,
// its echo and their acknowledgements do not. Interactive frames wait on the
// timer (at most RELAY_BURST_LINGER per hop, as every frame did before) only
// while the sender is saturated or a request-response loop runs faster than
// one round trip per RELAY_BURST_LINGER.
const RELAY_BURST_SENDS: usize = 4;
const RELAY_BURST_LINGER: Duration = Duration::from_millis(1);
const MAX_RELAY_INCOMING_TASKS: usize = 64;

type CredentialFuture = Pin<Box<dyn Future<Output = Result<String, ()>> + Send + 'static>>;
type CredentialCallback = dyn Fn() -> CredentialFuture + Send + Sync + 'static;
type BoundCredentialFuture =
    Pin<Box<dyn Future<Output = Result<BoundCredential, ()>> + Send + 'static>>;
type BoundCredentialCallback = dyn Fn() -> BoundCredentialFuture + Send + Sync + 'static;

/// A relay ticket and the CarrierGrant it was minted beside
/// ([`RelayCredentialSource::bound_callback`]). A Connect presents the grant
/// with the ticket, and the relay admits a ticket that names its grant only
/// with that grant (cmuxterm-hq#19075).
pub struct BoundCredential {
    pub ticket: Zeroizing<String>,
    pub grant: Option<Zeroizing<String>>,
}

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
    BoundCallback(Arc<BoundCredentialCallback>),
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
    /// The credential is read from stdout and never appears in an error. When
    /// the command fails or times out, its error carries the exit status and a
    /// summary of the last [`CREDENTIAL_COMMAND_STDERR_TAIL_BYTES`] of its
    /// stderr: the byte length and the error codes in it
    /// ([`stderr_summary`]), never its free text.
    pub fn command<I, S>(program: impl Into<OsString>, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Self::command_with_timeout(program, args, DEFAULT_CREDENTIAL_COMMAND_TIMEOUT)
    }

    /// [`RelayCredentialSource::command`] for a daemon's own relay
    /// registration, with [`DAEMON_TICKET_COMMAND_TIMEOUT`].
    pub fn daemon_command<I, S>(program: impl Into<OsString>, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Self::command_with_timeout(program, args, DAEMON_TICKET_COMMAND_TIMEOUT)
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

    /// [`RelayCredentialSource::callback`] whose answer also carries the
    /// CarrierGrant the ticket was minted beside: each client Connect presents
    /// it. Every other use of the credential (a control socket's
    /// authentication) takes the ticket alone.
    pub fn bound_callback<F, Fut, E>(callback: F) -> Self
    where
        F: Fn() -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<BoundCredential, E>> + Send + 'static,
        E: Send + 'static,
    {
        let callback = Arc::new(move || {
            let future = callback();
            Box::pin(async move { future.await.map_err(|_| ()) }) as BoundCredentialFuture
        });
        Self { inner: Arc::new(RelayCredentialSourceInner::BoundCallback(callback)) }
    }

    /// True when each fetch may return a new credential: a registration renews
    /// its ticket before it expires only from such a source.
    fn renews(&self) -> bool {
        !matches!(&*self.inner, RelayCredentialSourceInner::Static(_))
    }

    async fn fetch(&self) -> Result<RelayCredential, ProviderError> {
        self.fetch_with_grant().await.map(|(credential, _)| credential)
    }

    /// The credential and, from a [`Self::bound_callback`], the grant it was
    /// minted beside.
    async fn fetch_with_grant(
        &self,
    ) -> Result<(RelayCredential, Option<Zeroizing<String>>), ProviderError> {
        let mut grant = None;
        let value = match &*self.inner {
            RelayCredentialSourceInner::Static(credential) => {
                return Ok((credential.clone(), None));
            }
            RelayCredentialSourceInner::File(path) => read_credential_file(path).await?,
            RelayCredentialSourceInner::Command(command) => {
                read_credential_command(command).await?
            }
            RelayCredentialSourceInner::Callback(callback) => {
                let deadline = Deadline::<Instant>::after(CREDENTIAL_CALLBACK_TIMEOUT);
                let answer = tokio::time::timeout_at(deadline.end(), callback())
                    .await
                    .map_err(|_| credential_source_error("callback timed out"))?;
                Zeroizing::new(answer.map_err(|()| credential_source_error("callback failed"))?)
            }
            RelayCredentialSourceInner::BoundCallback(callback) => {
                let deadline = Deadline::<Instant>::after(CREDENTIAL_CALLBACK_TIMEOUT);
                let answer = tokio::time::timeout_at(deadline.end(), callback())
                    .await
                    .map_err(|_| credential_source_error("callback timed out"))?
                    .map_err(|()| credential_source_error("callback failed"))?;
                grant = answer.grant;
                answer.ticket
            }
        };
        let credential = RelayCredential::parse_secret(value)
            .map_err(|_| credential_source_error("returned invalid data"))?;
        Ok((credential, grant))
    }
}

impl fmt::Debug for RelayCredentialSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = match &*self.inner {
            RelayCredentialSourceInner::Static(_) => "static",
            RelayCredentialSourceInner::File(_) => "file",
            RelayCredentialSourceInner::Command(_) => "command",
            RelayCredentialSourceInner::Callback(_) => "callback",
            RelayCredentialSourceInner::BoundCallback(_) => "bound callback",
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

    /// How long a signed ticket (`v2.<claims>.<signature>`) lives, read from its
    /// claims, which are not secret: the relay checks the signature, this only
    /// schedules the renewal. None for an opaque ticket.
    fn lifetime(&self) -> Option<Duration> {
        use base64::Engine as _;
        let mut parts = self.expose().split('.');
        let (Some("v2"), Some(claims), Some(_), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return None;
        };
        let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(claims).ok()?;
        let claims: RelayTicketClaims = serde_json::from_slice(&claims).ok()?;
        claims
            .has_valid_lifetime()
            .then(|| Duration::from_secs(claims.expires_at_unix - claims.issued_at_unix))
    }
}

impl fmt::Debug for RelayCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RelayCredential([REDACTED])")
    }
}

/// The TLS trust a relay's `wss` and `relay+do` connections use. The default
/// trusts the platform's roots (and `SSL_CERT_FILE`/`SSL_CERT_DIR`), as every
/// relay connection did before; [`RelayTls::with_root_certificates`] trusts
/// only the given roots, so a caller (a test's own CA) needs no process-wide
/// environment.
#[derive(Clone, Default)]
pub struct RelayTls {
    client_config: Option<Arc<rustls::ClientConfig>>,
}

impl RelayTls {
    /// Trust exactly these DER-encoded root certificates.
    pub fn with_root_certificates<I, C>(certificates: I) -> Result<Self, ProviderError>
    where
        I: IntoIterator<Item = C>,
        C: Into<Vec<u8>>,
    {
        let mut roots = rustls::RootCertStore::empty();
        for certificate in certificates {
            roots.add(rustls::pki_types::CertificateDer::from(certificate.into())).map_err(
                |error| ProviderError::Configuration(format!("invalid relay TLS root: {error}")),
            )?;
        }
        let config = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|error| ProviderError::Configuration(format!("relay TLS: {error}")))?
        .with_root_certificates(roots)
        .with_no_client_auth();
        Ok(Self { client_config: Some(Arc::new(config)) })
    }

    fn connector(&self) -> Option<Connector> {
        self.client_config.clone().map(Connector::Rustls)
    }
}

impl fmt::Debug for RelayTls {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayTls")
            .field("custom_roots", &self.client_config.is_some())
            .finish()
    }
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
            .field("slot", &"[REDACTED]")
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
    tls: RelayTls,
    /// When set, a lane's allocation waits until this instant instead of
    /// `control_timeout`: a Connect the relay parks until the daemon
    /// registers then follows its caller's one deadline.
    allocation_deadline: Option<Instant>,
    /// When set, a first connect's lane waits this long, not
    /// `control_timeout`, for the daemon to join its circuit once the relay
    /// allocated it ([`RelayProvider::with_peer_join_wait`]).
    peer_join_wait: Option<Duration>,
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
        Ok(Self {
            config,
            credentials,
            tls: RelayTls::default(),
            allocation_deadline: None,
            peer_join_wait: None,
        })
    }

    /// Wait for each lane's allocation until `deadline` rather than for
    /// `control_timeout`. A relay may park a Connect until the machine's
    /// daemon registers (`RelayControl::Parked`); this lets that wait follow
    /// the caller's remaining deadline. It applies to the first connect
    /// (generation 0) only: a resume's allocation, and every other control
    /// step, keeps `control_timeout`.
    pub fn with_allocation_deadline(mut self, deadline: Instant) -> Self {
        self.allocation_deadline = Some(deadline);
        self
    }

    /// Wait `wait`, not `control_timeout`, for the daemon to join a circuit
    /// the relay allocated, so a lane whose daemon never joins is given up
    /// for a new allocation (a new circuit and a new `Incoming`) instead of
    /// held to `control_timeout`. A daemon that joins does so in about a
    /// second of its `Incoming`. It applies to the first connect (generation
    /// 0) only, as [`Self::with_allocation_deadline`] does; connecting the
    /// circuit's socket keeps its own bound.
    pub fn with_peer_join_wait(mut self, wait: Duration) -> Self {
        self.peer_join_wait = Some(wait);
        self
    }

    /// Connect with this TLS trust instead of the platform's roots.
    pub fn with_tls(mut self, tls: RelayTls) -> Self {
        self.tls = tls;
        self
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

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOnly
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let route = sanitized_route(&request.endpoint);
        let framing = RelayCircuitFraming::for_route(&route);
        let endpoint =
            relay_websocket_url(&request.endpoint, &self.config.slot, RelayRole::Client)?;
        let control = connect_provider_control(&endpoint, &self.credentials, &self.tls).await?;
        Ok(Arc::new(RelayLinkGroup {
            description: route.clone(),
            evidence: CarrierEvidence::Relay {
                provider: endpoint.host_str().unwrap_or("relay").to_string(),
            },
            route,
            endpoint,
            framing,
            config: self.config.clone(),
            credentials: self.credentials.clone(),
            tls: self.tls.clone(),
            allocation_deadline: self.allocation_deadline,
            peer_join_wait: self.peer_join_wait,
            control: Mutex::new(Some(control)),
            closed: AtomicBool::new(false),
        }))
    }
}

struct RelayLinkGroup {
    description: String,
    evidence: CarrierEvidence,
    route: String,
    endpoint: Url,
    framing: RelayCircuitFraming,
    config: RelayClientConfig,
    credentials: RelayCredentialSource,
    tls: RelayTls,
    allocation_deadline: Option<Instant>,
    peer_join_wait: Option<Duration>,
    // An allocation temporarily takes ownership of the control socket. If the
    // allocation future is cancelled, the socket is dropped while this slot
    // remains empty, so a later attempt cannot consume a stale response.
    control: Mutex<Option<RelaySocket>>,
    closed: AtomicBool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RelayCircuitFraming {
    Single,
    Batch,
}

impl RelayCircuitFraming {
    fn for_route(route: &str) -> Self {
        if Url::parse(route).is_ok_and(|url| url.scheme() == "relay+do") {
            Self::Batch
        } else {
            Self::Single
        }
    }

    fn websocket_message_limit(self, logical_frame_limit: usize) -> usize {
        match self {
            Self::Single => logical_frame_limit.max(MAX_RELAY_CONTROL_MESSAGE_BYTES),
            Self::Batch => MAX_RELAY_BATCH_BYTES.max(MAX_RELAY_CONTROL_MESSAGE_BYTES),
        }
    }
}

struct RelayCircuitLink {
    description: String,
    maximum: usize,
    framing: RelayCircuitFraming,
    sender: RelayCircuitSender,
    receiver: Mutex<RelayCircuitReceiver>,
    terminal: watch::Sender<Option<LinkError>>,
    closed: AtomicBool,
}

enum RelayCircuitSender {
    Direct(Mutex<RelayCircuitSink>),
    Batched(mpsc::Sender<RelayCircuitCommand>),
}

struct RelayCircuitReceiver {
    stream: RelayCircuitStream,
    pending: VecDeque<Bytes>,
}

enum RelayCircuitCommand {
    Frame(Bytes),
    Message(Message),
    Close(oneshot::Sender<Result<(), LinkError>>),
}

impl RelayCircuitLink {
    fn new_with_framing(
        description: impl Into<String>,
        maximum: usize,
        framing: RelayCircuitFraming,
        socket: RelaySocket,
    ) -> Self {
        let (sender, receiver) = socket.split();
        let (terminal, _) = watch::channel(None);
        let sender = match framing {
            RelayCircuitFraming::Single => RelayCircuitSender::Direct(Mutex::new(sender)),
            RelayCircuitFraming::Batch => {
                let (commands, receiver) = mpsc::channel(RELAY_BATCH_QUEUE_FRAMES);
                tokio::spawn(run_batched_relay_sender(sender, receiver, terminal.clone()));
                RelayCircuitSender::Batched(commands)
            }
        };
        Self {
            description: description.into(),
            maximum,
            framing,
            sender,
            receiver: Mutex::new(RelayCircuitReceiver {
                stream: receiver,
                pending: VecDeque::new(),
            }),
            terminal,
            closed: AtomicBool::new(false),
        }
    }

    async fn send_control(&self, control: &RelayControl) -> Result<(), LinkError> {
        let encoded = serde_json::to_string(control)
            .map_err(|error| LinkError::Protocol(format!("invalid relay control: {error}")))?;
        self.send_message(RelayCircuitCommand::Message(Message::Text(encoded.into()))).await
    }

    async fn send_message(&self, command: RelayCircuitCommand) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::Closed);
        }
        if let Some(error) = self.terminal.borrow().clone() {
            return Err(error);
        }
        let result = match (&self.sender, command) {
            (RelayCircuitSender::Direct(sender), RelayCircuitCommand::Frame(frame)) => {
                sender.lock().await.send(Message::Binary(frame)).await.map_err(relay_link_error)
            }
            (RelayCircuitSender::Direct(sender), RelayCircuitCommand::Message(message)) => {
                sender.lock().await.send(message).await.map_err(relay_link_error)
            }
            (RelayCircuitSender::Direct(_), RelayCircuitCommand::Close(_)) => {
                unreachable!("direct relay close bypasses the command queue")
            }
            (RelayCircuitSender::Batched(sender), command) => sender
                .send(command)
                .await
                .map_err(|_| self.terminal.borrow().clone().unwrap_or(LinkError::Closed)),
        };
        if let Err(error) = &result {
            self.publish_terminal(error.clone());
        }
        result
    }

    fn publish_terminal(&self, error: LinkError) {
        if self.terminal.borrow().is_none() {
            self.terminal.send_replace(Some(error));
        }
    }

    fn terminal_receive_result(&self) -> Result<Option<Bytes>, LinkError> {
        match self.terminal.borrow().clone() {
            Some(LinkError::Closed) => Ok(None),
            Some(error) => Err(error),
            None => {
                Err(LinkError::Protocol("relay terminal notification had no terminal state".into()))
            }
        }
    }
}

fn relay_link_error(error: WebSocketError) -> LinkError {
    LinkError::Transport(error.to_string())
}

fn relay_batch_encoded_len(frames: &[Bytes]) -> Option<usize> {
    frames.iter().try_fold(RELAY_BATCH_HEADER_BYTES, |total, frame| {
        total.checked_add(RELAY_BATCH_ENTRY_HEADER_BYTES)?.checked_add(frame.len())
    })
}

fn encode_relay_batch(frames: &[Bytes]) -> Result<Bytes, LinkError> {
    if frames.is_empty() || frames.len() > MAX_RELAY_BATCH_FRAMES {
        return Err(LinkError::Protocol("relay batch has an invalid frame count".into()));
    }
    let encoded_len = relay_batch_encoded_len(frames)
        .filter(|size| *size <= MAX_RELAY_BATCH_BYTES)
        .ok_or_else(|| LinkError::Protocol("relay batch exceeds its carrier limit".into()))?;
    let mut encoded = Vec::with_capacity(encoded_len);
    encoded.extend_from_slice(&RELAY_BATCH_MAGIC);
    encoded.push(RELAY_BATCH_VERSION);
    encoded.push(frames.len() as u8);
    encoded.extend_from_slice(&[0, 0]);
    for frame in frames {
        let frame_len = u32::try_from(frame.len())
            .map_err(|_| LinkError::Protocol("relay batch frame length overflowed".into()))?;
        encoded.extend_from_slice(&frame_len.to_be_bytes());
        encoded.extend_from_slice(frame);
    }
    Ok(Bytes::from(encoded))
}

fn decode_relay_batch(encoded: Bytes, maximum: usize) -> Result<VecDeque<Bytes>, LinkError> {
    if encoded.len() < RELAY_BATCH_HEADER_BYTES
        || encoded[..4] != RELAY_BATCH_MAGIC
        || encoded[4] != RELAY_BATCH_VERSION
        || encoded[6..8] != [0, 0]
    {
        return Err(LinkError::Protocol("relay batch header is invalid".into()));
    }
    let count = usize::from(encoded[5]);
    if count == 0 || count > MAX_RELAY_BATCH_FRAMES {
        return Err(LinkError::Protocol("relay batch has an invalid frame count".into()));
    }
    let mut frames = VecDeque::with_capacity(count);
    let mut offset = RELAY_BATCH_HEADER_BYTES;
    for _ in 0..count {
        let length_end = offset
            .checked_add(RELAY_BATCH_ENTRY_HEADER_BYTES)
            .filter(|end| *end <= encoded.len())
            .ok_or_else(|| LinkError::Protocol("relay batch is truncated".into()))?;
        let length = u32::from_be_bytes(encoded[offset..length_end].try_into().unwrap()) as usize;
        if length == 0 || length > maximum {
            return Err(LinkError::FrameTooLarge { actual: length, maximum });
        }
        let frame_end = length_end
            .checked_add(length)
            .filter(|end| *end <= encoded.len())
            .ok_or_else(|| LinkError::Protocol("relay batch frame is truncated".into()))?;
        frames.push_back(encoded.slice(length_end..frame_end));
        offset = frame_end;
    }
    if offset != encoded.len() {
        return Err(LinkError::Protocol("relay batch has trailing bytes".into()));
    }
    Ok(frames)
}

async fn run_batched_relay_sender<S>(
    mut socket: S,
    mut commands: mpsc::Receiver<RelayCircuitCommand>,
    terminal: watch::Sender<Option<LinkError>>,
) where
    S: Sink<Message, Error = WebSocketError> + Unpin,
{
    let mut deferred = None;
    let mut last_send_finished: Option<Instant> = None;
    let mut burst_sends = 0_usize;
    loop {
        let command = match deferred.take() {
            Some(command) => command,
            None => match commands.recv().await {
                Some(command) => command,
                None => {
                    let _ = socket.close().await;
                    return;
                }
            },
        };
        let back_to_back =
            last_send_finished.is_some_and(|finished| finished.elapsed() < RELAY_BURST_LINGER);
        burst_sends = if back_to_back { burst_sends.saturating_add(1) } else { 0 };
        let result = match command {
            RelayCircuitCommand::Frame(first) => {
                let mut frames = vec![first];
                // Interactive traffic normally leaves without a timer: one yield lets
                // frames produced in the same scheduler pass join this batch,
                // and frames queued while the previous send was in flight are
                // drained below. Only sustained output waits to fill a batch,
                // which keeps the relay's message count down during floods.
                if burst_sends < RELAY_BURST_SENDS {
                    tokio::task::yield_now().await;
                } else if commands.len() + 1 < MAX_RELAY_BATCH_FRAMES {
                    tokio::time::sleep(RELAY_BURST_LINGER).await;
                }
                while frames.len() < MAX_RELAY_BATCH_FRAMES {
                    let Ok(command) = commands.try_recv() else {
                        break;
                    };
                    match command {
                        RelayCircuitCommand::Frame(frame) => {
                            let fits = relay_batch_encoded_len(&frames)
                                .and_then(|bytes| {
                                    bytes
                                        .checked_add(RELAY_BATCH_ENTRY_HEADER_BYTES)?
                                        .checked_add(frame.len())
                                })
                                .is_some_and(|bytes| bytes <= MAX_RELAY_BATCH_BYTES);
                            if fits {
                                frames.push(frame);
                            } else {
                                deferred = Some(RelayCircuitCommand::Frame(frame));
                                break;
                            }
                        }
                        other => {
                            deferred = Some(other);
                            break;
                        }
                    }
                }
                match encode_relay_batch(&frames) {
                    Ok(batch) => {
                        socket.send(Message::Binary(batch)).await.map_err(relay_link_error)
                    }
                    Err(error) => Err(error),
                }
            }
            RelayCircuitCommand::Message(message) => {
                socket.send(message).await.map_err(relay_link_error)
            }
            RelayCircuitCommand::Close(completion) => {
                let result = socket.close().await.map_err(relay_link_error);
                let _ = completion.send(result.clone());
                if let Err(error) = result {
                    terminal.send_replace(Some(error));
                } else {
                    terminal.send_replace(Some(LinkError::Closed));
                }
                return;
            }
        };
        if let Err(error) = result {
            terminal.send_replace(Some(error));
            return;
        }
        last_send_finished = Some(Instant::now());
    }
}

impl fmt::Debug for RelayCircuitLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayCircuitLink")
            .field("description", &self.description)
            .field("maximum", &self.maximum)
            .field("framing", &self.framing)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl FrameLink for RelayCircuitLink {
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        ensure_relay_frame_size(frame.len(), self.maximum)?;
        self.send_message(RelayCircuitCommand::Frame(frame)).await
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let mut receiver = self.receiver.lock().await;
        if let Some(frame) = receiver.pending.pop_front() {
            return Ok(Some(frame));
        }
        let mut terminal = self.terminal.subscribe();
        loop {
            if terminal.borrow().is_some() {
                return self.terminal_receive_result();
            }
            let next = tokio::select! {
                biased;
                changed = terminal.changed() => {
                    if changed.is_ok() {
                        return self.terminal_receive_result();
                    }
                    return Err(LinkError::Closed);
                }
                next = receiver.stream.next() => next,
            };
            match next {
                Some(Ok(Message::Binary(frame))) => match self.framing {
                    RelayCircuitFraming::Single => {
                        ensure_relay_frame_size(frame.len(), self.maximum)?;
                        return Ok(Some(frame));
                    }
                    RelayCircuitFraming::Batch => {
                        receiver.pending = decode_relay_batch(frame, self.maximum)?;
                        return Ok(receiver.pending.pop_front());
                    }
                },
                Some(Ok(Message::Text(text))) => {
                    if text.len() > MAX_RELAY_CONTROL_MESSAGE_BYTES {
                        return Err(LinkError::Protocol(
                            "relay circuit control message exceeded its limit".into(),
                        ));
                    }
                    match serde_json::from_str(&text) {
                        Ok(RelayControl::Error { retryable: true, .. }) => {
                            return Err(LinkError::Transport(
                                "relay circuit became unavailable".into(),
                            ));
                        }
                        Ok(RelayControl::Error { retryable: false, .. }) => {
                            return Err(LinkError::Protocol(
                                "relay circuit was rejected after establishment".into(),
                            ));
                        }
                        Ok(RelayControl::Ping { nonce }) => {
                            self.send_control(&RelayControl::Pong { nonce }).await?;
                        }
                        Ok(RelayControl::Pong { .. }) => {}
                        Ok(_) => {
                            return Err(LinkError::Protocol(
                                "relay sent unexpected circuit control".into(),
                            ));
                        }
                        Err(_) => {
                            return Err(LinkError::Protocol(
                                "relay sent invalid circuit control".into(),
                            ));
                        }
                    }
                }
                Some(Ok(Message::Ping(payload))) => {
                    self.send_message(RelayCircuitCommand::Message(Message::Pong(payload))).await?;
                }
                Some(Ok(Message::Pong(_))) => {}
                Some(Ok(Message::Close(_))) | None => {
                    self.publish_terminal(LinkError::Closed);
                    return Ok(None);
                }
                Some(Ok(_)) => {
                    return Err(LinkError::Protocol(
                        "relay circuit accepts binary data and relay control only".into(),
                    ));
                }
                Some(Err(error)) => {
                    let error = relay_link_error(error);
                    self.publish_terminal(error.clone());
                    return Err(error);
                }
            }
        }
    }

    async fn close(&self) -> Result<(), LinkError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let result = match &self.sender {
            RelayCircuitSender::Direct(sender) => {
                sender.lock().await.close().await.map_err(relay_link_error)
            }
            RelayCircuitSender::Batched(sender) => {
                let (completion, finished) = oneshot::channel();
                sender
                    .send(RelayCircuitCommand::Close(completion))
                    .await
                    .map_err(|_| self.terminal.borrow().clone().unwrap_or(LinkError::Closed))?;
                finished
                    .await
                    .map_err(|_| self.terminal.borrow().clone().unwrap_or(LinkError::Closed))?
            }
        };
        match &result {
            Ok(()) => self.publish_terminal(LinkError::Closed),
            Err(error) => self.publish_terminal(error.clone()),
        }
        result
    }
}

fn ensure_relay_frame_size(actual: usize, maximum: usize) -> Result<(), LinkError> {
    if actual > maximum { Err(LinkError::FrameTooLarge { actual, maximum }) } else { Ok(()) }
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

    async fn transport_snapshot(&self) -> TransportSnapshot {
        TransportSnapshot {
            provider: "websocket-relay".into(),
            route: self.route.clone(),
            selected_path: Some(TransportPathSnapshot {
                kind: TransportPathKind::Relay,
                remote: self.endpoint.host_str().map(str::to_owned),
                rtt_micros: None,
            }),
        }
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("relay connection group is closed".into()));
        }
        let lane = LaneToken(random_capability()?);
        // The allocation deadline is the first connect's; a resume (a later
        // generation) waits `control_timeout` as any reconnect does.
        let wait_until = self.allocation_deadline.filter(|_| request.generation == 0);
        let join_wait = self
            .peer_join_wait
            .filter(|_| request.generation == 0)
            .unwrap_or(self.config.control_timeout);
        let allocation = {
            let mut stored_control = self.control.lock().await;
            if self.closed.load(Ordering::Acquire) {
                return Err(ProviderError::Transport("relay connection group is closed".into()));
            }
            let mut control = match stored_control.take() {
                Some(control) => control,
                None => {
                    connect_provider_control(&self.endpoint, &self.credentials, &self.tls).await?
                }
            };
            match request_allocation(
                &mut control,
                &self.config,
                &self.credentials,
                allocation_wait(wait_until, self.config.control_timeout),
                &lane,
                request.generation,
            )
            .await
            {
                Ok(allocation) => {
                    *stored_control = Some(control);
                    allocation
                }
                Err(AllocationError::Terminal(error)) => {
                    *stored_control = Some(control);
                    return Err(error);
                }
                Err(
                    error @ (AllocationError::Reconnect(_) | AllocationError::Authentication(_)),
                ) => {
                    let control_error = error.into_provider_error();
                    drop(control);
                    if self.closed.load(Ordering::Acquire) {
                        return Err(ProviderError::Transport(
                            "relay connection group is closed".into(),
                        ));
                    }
                    let mut replacement =
                        connect_provider_control(&self.endpoint, &self.credentials, &self.tls)
                            .await
                            .map_err(|error| relay_reconnect_error(&control_error, error))?;
                    match request_allocation(
                        &mut replacement,
                        &self.config,
                        &self.credentials,
                        allocation_wait(wait_until, self.config.control_timeout),
                        &lane,
                        request.generation,
                    )
                    .await
                    {
                        Ok(allocation) => {
                            *stored_control = Some(replacement);
                            allocation
                        }
                        Err(AllocationError::Terminal(error)) => {
                            *stored_control = Some(replacement);
                            return Err(error);
                        }
                        Err(error) => return Err(error.into_provider_error()),
                    }
                }
            }
        };
        join_circuit(
            &self.endpoint,
            &self.config.slot,
            RelayRole::Client,
            self.framing,
            allocation.0,
            lane,
            request.generation,
            allocation.1,
            self.config.maximum_frame_bytes,
            join_wait,
            &self.tls,
        )
        .await
    }

    async fn close(&self) -> Result<(), ProviderError> {
        if !self.closed.swap(true, Ordering::AcqRel)
            && let Some(mut control) = self.control.lock().await.take()
        {
            control
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

/// How long one lane's allocation may wait: until the provider's
/// allocation deadline when it has one, else `control_timeout`.
fn allocation_wait(deadline: Option<Instant>, control_timeout: Duration) -> Duration {
    match deadline {
        Some(deadline) => deadline.saturating_duration_since(Instant::now()),
        None => control_timeout,
    }
}

async fn request_allocation(
    socket: &mut RelaySocket,
    config: &RelayClientConfig,
    credentials: &RelayCredentialSource,
    wait: Duration,
    lane: &LaneToken,
    generation: u64,
) -> Result<(CircuitId, String), AllocationError> {
    let (credential, grant) =
        credentials.fetch_with_grant().await.map_err(AllocationError::Authentication)?;
    send_control(
        socket,
        &RelayControl::Connect {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: config.slot.clone(),
            ticket: credential.expose().to_owned(),
            lane: lane.clone(),
            generation,
            // `read_until_allocation` reads past `Parked` to the answer.
            accepts_parked: true,
            grant: grant.as_deref().map(ToOwned::to_owned),
        },
    )
    .await
    .map_err(AllocationError::Reconnect)?;
    tokio::time::timeout(wait, read_until_allocation(socket, lane, generation)).await.map_err(
        |_| AllocationError::Reconnect(relay_carrier_error("relay allocation timed out")),
    )?
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
            RelayControl::Error { code, retryable, .. } => {
                return Err(if relay_authentication_error(&code) {
                    AllocationError::Authentication(relay_rejection())
                } else if retryable {
                    AllocationError::Reconnect(relay_unavailable(
                        "relay allocation is temporarily unavailable",
                        &code,
                    ))
                } else {
                    AllocationError::Terminal(relay_rejection())
                });
            }
            RelayControl::Ping { nonce } => {
                send_control(socket, &RelayControl::Pong { nonce })
                    .await
                    .map_err(AllocationError::Reconnect)?;
            }
            // The relay holds the request until its daemon registers; keep
            // reading for `Allocated` inside this call's timeout.
            RelayControl::Parked { .. } => {}
            _ => {}
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn join_circuit(
    endpoint: &Url,
    slot: &str,
    role: RelayRole,
    framing: RelayCircuitFraming,
    circuit: CircuitId,
    lane: LaneToken,
    generation: u64,
    ticket: String,
    maximum_frame_bytes: usize,
    timeout: Duration,
    tls: &RelayTls,
) -> Result<Box<dyn FrameLink>, ProviderError> {
    let circuit_endpoint = relay_circuit_url(endpoint, &circuit)?;
    // The circuit starts with JSON Join/Ready messages before it becomes a
    // binary frame link. A caller may intentionally choose a data-frame limit
    // smaller than those control messages, so keep the WebSocket handshake
    // ceiling large enough for control and enforce the advertised data limit
    // in RelayCircuitLink after the circuit is ready.
    let websocket_message_limit = framing.websocket_message_limit(maximum_frame_bytes);
    let mut socket =
        connect_relay_socket(&circuit_endpoint, Some(&ticket), websocket_message_limit, tls)
            .await?;
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
                RelayControl::Error { code, retryable, .. } => {
                    return Err(relay_operation_rejection(
                        &code,
                        retryable,
                        "relay circuit is temporarily unavailable",
                    ));
                }
                _ => {}
            }
        }
    })
    .await
    .map_err(|_| relay_carrier_error("relay circuit join timed out"))??;
    Ok(Box::new(RelayCircuitLink::new_with_framing(
        sanitized_route(endpoint),
        maximum_frame_bytes,
        framing,
        socket,
    )))
}

/// What a relay registration hands each joined circuit to: a cmux-remote
/// daemon, or another endpoint that runs its own handshake over the link
/// (acpmux's hub carrier, which bridges it to its WebSocket listener).
#[async_trait]
pub trait RelayIncoming: Send + Sync + 'static {
    /// Serve one joined circuit until it ends.
    async fn incoming(self: Arc<Self>, link: Box<dyn FrameLink>);
}

#[async_trait]
impl RelayIncoming for RemoteDaemon {
    async fn incoming(self: Arc<Self>, link: Box<dyn FrameLink>) {
        let _ = self.accept(InboundLink::network(link, NetworkPeer::Relay)).await;
    }
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
            .field("endpoint", &sanitized_route(&self.endpoint))
            .field("slot", &"[REDACTED]")
            .field("ticket", &"[REDACTED]")
            .field("maximum_frame_bytes", &self.maximum_frame_bytes)
            .field("control_timeout", &self.control_timeout)
            .finish()
    }
}

pub struct RelayDaemonRegistration {
    shutdown: watch::Sender<bool>,
    task: Option<tokio::task::JoinHandle<()>>,
    state: watch::Receiver<RegistrationState>,
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
    daemon: Arc<dyn RelayIncoming>,
    mut config: RelayDaemonConfig,
) -> Result<RelayDaemonRegistration, ProviderError> {
    if let Err(error) = config.validate_common() {
        config.ticket.zeroize();
        return Err(error);
    }
    let credentials = RelayCredentialSource::static_ticket(std::mem::take(&mut config.ticket))?;
    register_relay_daemon_with_credentials(daemon, config, credentials).await
}

/// [`register_relay_daemon`] with this TLS trust instead of the platform's roots.
pub async fn register_relay_daemon_with_tls(
    daemon: Arc<dyn RelayIncoming>,
    mut config: RelayDaemonConfig,
    tls: RelayTls,
) -> Result<RelayDaemonRegistration, ProviderError> {
    if let Err(error) = config.validate_common() {
        config.ticket.zeroize();
        return Err(error);
    }
    let credentials = RelayCredentialSource::static_ticket(std::mem::take(&mut config.ticket))?;
    register_with_credentials_and_tls(daemon, config, credentials, tls).await
}

pub async fn register_relay_daemon_with_credentials(
    daemon: Arc<dyn RelayIncoming>,
    config: RelayDaemonConfig,
    credentials: RelayCredentialSource,
) -> Result<RelayDaemonRegistration, ProviderError> {
    register_with_credentials_and_tls(daemon, config, credentials, RelayTls::default()).await
}

async fn register_with_credentials_and_tls(
    daemon: Arc<dyn RelayIncoming>,
    mut config: RelayDaemonConfig,
    credentials: RelayCredentialSource,
    tls: RelayTls,
) -> Result<RelayDaemonRegistration, ProviderError> {
    config.ticket.zeroize();
    config.validate_common()?;
    let framing = RelayCircuitFraming::for_route(&sanitized_route(&config.endpoint));
    let endpoint = relay_websocket_url(&config.endpoint, &config.slot, RelayRole::Daemon)?;
    let config = RelayDaemonConfig { endpoint, ..config };
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (state_tx, state) = watch::channel(RegistrationState::Registering);
    let (ready_tx, ready_rx) = oneshot::channel();
    let task = tokio::spawn(run_registration_loop(
        daemon,
        config,
        framing,
        credentials,
        tls,
        shutdown_rx,
        Some(ready_tx),
        None,
        state_tx,
    ));
    ready_rx.await.map_err(|_| {
        ProviderError::Transport("relay registration stopped before ready".into())
    })??;
    Ok(RelayDaemonRegistration { shutdown: shutdown_tx, task: Some(task), state })
}

/// Register on a relay in the background and return at once.
///
/// Unlike [`register_relay_daemon_with_credentials`], no failure is fatal:
/// a credential source that fails (a ticket command that exits non-zero or
/// hangs past its timeout) or a relay that refuses is retried until
/// [`RelayDaemonRegistration::shutdown`] or drop. Each failed attempt is
/// written to stderr once, prefixed by `log_label`, with its reason, and
/// the registration's [`RelayDaemonRegistration::state`] says what the last
/// attempt met (`CredentialUnavailable` for a ticket mint that is down). The
/// wait between attempts is jittered and capped: 5 s after a relay failure,
/// 60 s after a credential source failure. A resume (`relay_liveness.rs`)
/// ends a registration from before the pause or a wait at once and
/// registers again with no wait. A ticket that expires is renewed before it
/// does, on a second control socket that replaces the first, and joined
/// circuits outlive their control socket. Only an invalid configuration is
/// an error here. A daemon uses this so that its local services start and
/// stay up while the relay route is unavailable.
pub fn spawn_relay_daemon_registration(
    daemon: Arc<dyn RelayIncoming>,
    mut config: RelayDaemonConfig,
    credentials: RelayCredentialSource,
    log_label: &str,
) -> Result<RelayDaemonRegistration, ProviderError> {
    config.ticket.zeroize();
    config.validate_common()?;
    let framing = RelayCircuitFraming::for_route(&sanitized_route(&config.endpoint));
    let route = sanitized_route(&config.endpoint);
    let endpoint = relay_websocket_url(&config.endpoint, &config.slot, RelayRole::Daemon)?;
    let config = RelayDaemonConfig { endpoint, ..config };
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (state_tx, state) = watch::channel(RegistrationState::Registering);
    let task = tokio::spawn(run_registration_loop(
        daemon,
        config,
        framing,
        credentials,
        RelayTls::default(),
        shutdown_rx,
        None,
        Some(format!("{log_label}: relay registration on {route}")),
        state_tx,
    ));
    Ok(RelayDaemonRegistration { shutdown: shutdown_tx, task: Some(task), state })
}

/// The registration's joined circuits belong to the registration, not to one
/// control socket: each is its own relay socket, which the relay keeps open
/// when the control socket closes, so a live session outlives a dropped or
/// renewed registration. They end at shutdown, or after a pause the
/// registration did not survive (their sockets died with it).
#[allow(clippy::too_many_arguments)]
async fn run_registration_loop(
    daemon: Arc<dyn RelayIncoming>,
    config: RelayDaemonConfig,
    framing: RelayCircuitFraming,
    credentials: RelayCredentialSource,
    tls: RelayTls,
    shutdown: watch::Receiver<bool>,
    first_ready: Option<oneshot::Sender<Result<(), ProviderError>>>,
    log: Option<String>,
    state: watch::Sender<RegistrationState>,
) {
    let mut circuits = IncomingCircuitTasks::new(MAX_RELAY_INCOMING_TASKS);
    run_registration_attempts(
        daemon,
        config,
        framing,
        credentials,
        tls,
        shutdown,
        first_ready,
        log,
        &mut circuits,
        &state,
    )
    .await;
    circuits.shutdown().await;
}

#[allow(clippy::too_many_arguments)]
async fn run_registration_attempts(
    daemon: Arc<dyn RelayIncoming>,
    config: RelayDaemonConfig,
    framing: RelayCircuitFraming,
    credentials: RelayCredentialSource,
    tls: RelayTls,
    mut shutdown: watch::Receiver<bool>,
    mut first_ready: Option<oneshot::Sender<Result<(), ProviderError>>>,
    log: Option<String>,
    circuits: &mut IncomingCircuitTasks,
    state: &watch::Sender<RegistrationState>,
) {
    let mut retry = Retry::new();
    let mut log = RegisterLog::new(log, Instant::now());
    loop {
        if *shutdown.borrow() {
            return;
        }
        if shutdown.has_changed().is_err() {
            return;
        }
        let mut attempt = Attempt::default();
        let result = run_registration_once(
            daemon.clone(),
            &config,
            framing,
            &credentials,
            &tls,
            &mut shutdown,
            &mut first_ready,
            circuits,
            &mut attempt,
            &log,
            state,
        )
        .await;
        // A registration that got ready and later died (a pause, a relay
        // restart, an expired ticket) registers again from the first wait.
        if attempt.registered {
            retry.ready();
            log.dropped(Instant::now());
        }
        // What the attempt met, while the next one waits. A credential source
        // that fails (the ticket mint is down, or did not answer in its
        // bound) is a named state, not only a stderr line.
        state.send_replace(match &result {
            Ok(()) => RegistrationState::Registering,
            Err(error) if is_credential_source_error(error) => {
                RegistrationState::CredentialUnavailable { error: error.to_string() }
            }
            Err(error) => RegistrationState::RelayUnavailable { error: error.to_string() },
        });
        // A pause the registration did not survive outlived its circuits too.
        if attempt.resumed {
            circuits.shutdown().await;
        }
        let credential_failure = result.as_ref().is_err_and(is_credential_source_error);
        if first_ready.is_some()
            && result.as_ref().is_err_and(|error| !error.is_retryable_carrier_failure())
        {
            if let Some(sender) = first_ready.take() {
                let _ = sender.send(result);
            }
            return;
        }
        if *shutdown.borrow() {
            return;
        }
        let ended = if attempt.resumed {
            Ended::Resumed
        } else if credential_failure {
            Ended::Credential
        } else {
            Ended::Relay
        };
        let wait = retry.wait(ended, random_unit());
        if let (Some(label), Err(error)) = (&log.label, &result) {
            log.failures += 1;
            eprintln!(
                "{label}: attempt {} failed, retrying in {} ms: {error}",
                log.failures,
                wait.as_millis()
            );
        }
        match back_off(&mut retry, wait, &mut shutdown, wall_now).await {
            Waited::Elapsed => {}
            Waited::Resumed => {
                if let Some(label) = &log.label {
                    eprintln!("{label}: resumed during the wait; registering now");
                }
            }
            Waited::Shutdown => return,
        }
    }
}

/// What one registration attempt got to.
#[derive(Debug, Default)]
struct Attempt {
    /// It got ready (and may have ended since).
    registered: bool,
    /// It ended because the machine resumed from a pause it did not survive.
    resumed: bool,
}

/// How [`wait_unless_resumed`] ended.
#[derive(Debug, PartialEq, Eq)]
enum Waited {
    Elapsed,
    /// The machine resumed: the wall clock jumped past the monotonic one, or
    /// the monotonic clock moved past the relay's retirement between two looks.
    Resumed,
    Shutdown,
}

/// Waits out a failed attempt's `wait`. A resume during it (the pause
/// outlived the reason for the wait) starts both backoffs over, so the next
/// failure waits the first backoff again, not the one from before the pause.
async fn back_off(
    retry: &mut Retry,
    wait: Duration,
    shutdown: &mut watch::Receiver<bool>,
    wall: fn() -> std::time::SystemTime,
) -> Waited {
    let waited = wait_unless_resumed(wait, shutdown, wall).await;
    if waited == Waited::Resumed {
        retry.ready();
    }
    waited
}

/// Waits `wait` (monotonic, so a pause does not count), looking at the
/// clocks every [`CHECK_INTERVAL`]: a resume ends the wait at once. Ends at
/// the latest when `wait` elapses or at shutdown. `wall` is the wall clock.
async fn wait_unless_resumed(
    wait: Duration,
    shutdown: &mut watch::Receiver<bool>,
    wall: fn() -> std::time::SystemTime,
) -> Waited {
    if wait.is_zero() {
        return Waited::Elapsed;
    }
    let sleep = tokio::time::sleep(wait);
    tokio::pin!(sleep);
    let mut clocks = ClockWatch::new(Instant::now(), wall());
    let mut interval = tokio::time::interval(CHECK_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        // After a pause longer than `wait`, the sleep and the tick are both
        // ready and `select!` picks either: every wakeup looks at the clocks.
        let elapsed = tokio::select! {
            _ = &mut sleep => true,
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Waited::Shutdown;
                }
                false
            }
            _ = interval.tick() => false,
        };
        // A wall-clock step past the monotonic one, or a monotonic gap past
        // the relay's retirement between two looks a second apart (a pause
        // where every guest clock kept running).
        let look = clocks.look(Instant::now(), wall());
        if look.wall_ahead > CLOCK_JUMP || look.outlived_relay() {
            return Waited::Resumed;
        }
        if elapsed {
            return Waited::Elapsed;
        }
    }
}

/// What a background registration writes to stderr when the relay answers
/// its Register: the first one, and each one after a drop, never a
/// heartbeat. A journey timeline reads the Register time from it.
struct RegisterLog {
    /// The registration's stderr prefix; nothing is written without one.
    label: Option<String>,
    /// When the registration started.
    started: Instant,
    /// Failed attempts since the last Register (or the start).
    failures: u64,
    /// When the last registration ended, once one has.
    dropped_at: Option<Instant>,
}

impl RegisterLog {
    fn new(label: Option<String>, started: Instant) -> Self {
        Self { label, started, failures: 0, dropped_at: None }
    }

    /// A registration that got ready has ended at `now`.
    fn dropped(&mut self, now: Instant) {
        self.failures = 0;
        self.dropped_at = Some(now);
    }

    /// The line for a Register answered at `now` on `slot`.
    fn registered_line(&self, slot: &str, now: Instant) -> Option<String> {
        let label = self.label.as_ref()?;
        let elapsed = now.saturating_duration_since(self.started).as_millis();
        let again = match self.dropped_at {
            Some(dropped) => {
                format!(
                    " again, {} ms after the drop,",
                    now.saturating_duration_since(dropped).as_millis()
                )
            }
            None => String::new(),
        };
        let retried = match self.failures {
            0 => String::new(),
            1 => " and 1 failed attempt".to_owned(),
            failures => format!(" and {failures} failed attempts"),
        };
        Some(format!("{label}: registered{again} on slot {slot} after {elapsed} ms{retried}"))
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_registration_once(
    daemon: Arc<dyn RelayIncoming>,
    config: &RelayDaemonConfig,
    framing: RelayCircuitFraming,
    credentials: &RelayCredentialSource,
    tls: &RelayTls,
    shutdown: &mut watch::Receiver<bool>,
    first_ready: &mut Option<oneshot::Sender<Result<(), ProviderError>>>,
    circuits: &mut IncomingCircuitTasks,
    attempt: &mut Attempt,
    log: &RegisterLog,
    state: &watch::Sender<RegistrationState>,
) -> Result<(), ProviderError> {
    let authentication = authenticate_daemon_control(config, credentials, tls);
    tokio::pin!(authentication);
    let control = tokio::select! {
        result = &mut authentication => result?,
        changed = shutdown.changed() => {
            if changed.is_err() || *shutdown.borrow() {
                return Ok(());
            }
            authentication.await?
        }
    };
    attempt.registered = true;
    state.send_replace(RegistrationState::Registered);
    if let Some(line) = log.registered_line(&config.slot, Instant::now()) {
        eprintln!("{line}");
    }
    if let Some(sender) = first_ready.take() {
        let _ = sender.send(Ok(()));
    }
    let mut socket = control.socket;
    // Checked every second (relay_liveness.rs): a ping unanswered for 3 s,
    // or a resume (a wall-clock jump, or a monotonic gap past the relay's
    // 45 s between two checks), finds a dead registration in seconds.
    let mut liveness = registration_liveness(control.lease_seconds);
    let mut renew_at = control.renew_at;
    // Make-before-break: before the ticket expires a second control socket
    // registers with a fresh one. Every relay takes a Register on the slot as
    // the current registration and retires the one it replaced, so dials go to
    // the new socket from that moment; Incomings already sent on the old one
    // are still read until the relay closes it (`retiring`).
    let mut renewal: Option<Renewal<'_>> = None;
    let mut retiring: Option<RelaySocket> = None;
    let mut retire_until = Instant::now();
    let mut interval = tokio::time::interval(CHECK_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut nonce = 0_u64;
    let far = || Instant::now() + Duration::from_secs(86_400);
    loop {
        let message = tokio::select! {
            _ = circuits.join_next(), if !circuits.is_empty() => continue,
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { return Ok(()) }
                continue;
            }
            _ = tokio::time::sleep_until(renew_at.unwrap_or_else(far)),
                if renew_at.is_some() && renewal.is_none() =>
            {
                renew_at = None;
                renewal = Some(Box::pin(authenticate_daemon_control(config, credentials, tls)));
                continue;
            }
            renewed = poll_some(renewal.as_mut()) => {
                renewal = None;
                match renewed {
                    Ok(control) => {
                        let old = std::mem::replace(&mut socket, control.socket);
                        retiring = Some(old);
                        retire_until = Instant::now() + config.control_timeout;
                        liveness = registration_liveness(control.lease_seconds);
                        renew_at = control.renew_at;
                    }
                    Err(error) => {
                        if let Some(label) = &log.label {
                            eprintln!(
                                "{label}: renewing the registration failed, retrying in {} ms: \
                                 {error}",
                                RENEWAL_RETRY.as_millis()
                            );
                        }
                        renew_at = Some(Instant::now() + RENEWAL_RETRY);
                    }
                }
                continue;
            }
            message = read_some(retiring.as_mut()) => {
                match message {
                    Ok(RelayControl::Incoming { circuit, lane, generation, join_ticket }) => {
                        spawn_incoming(
                            circuits, &daemon, config, framing, tls, circuit, lane, generation,
                            join_ticket, log,
                        );
                    }
                    Ok(_) => {}
                    // Replaced: the relay closed it (after an Error), or it failed.
                    Err(_) => retiring = None,
                }
                continue;
            }
            _ = tokio::time::sleep_until(retire_until), if retiring.is_some() =>
            {
                retiring = None;
                continue;
            }
            _ = interval.tick() => {
                match liveness.check(Instant::now(), wall_now()) {
                    Check::Idle => continue,
                    Check::Ping => {
                        nonce = nonce.wrapping_add(1);
                        match send_control(&mut socket, &RelayControl::Ping { nonce }).await {
                            Ok(()) => continue,
                            Err(error) => Err(error),
                        }
                    }
                    Check::Dead => {
                        Err(ProviderError::Transport(
                            "relay registration stopped answering".into(),
                        ))
                    }
                    Check::Resumed => {
                        attempt.resumed = true;
                        return Err(ProviderError::Transport(
                            "relay registration did not survive a pause".into(),
                        ));
                    }
                }
            }
            message = read_control(&mut socket) => message,
        };
        let failure = match message {
            Ok(message) => {
                liveness.on_inbound();
                match message {
                    RelayControl::Incoming { circuit, lane, generation, join_ticket } => {
                        spawn_incoming(
                            circuits,
                            &daemon,
                            config,
                            framing,
                            tls,
                            circuit,
                            lane,
                            generation,
                            join_ticket,
                            log,
                        );
                        continue;
                    }
                    RelayControl::Ping { nonce } => {
                        send_control(&mut socket, &RelayControl::Pong { nonce }).await?;
                        continue;
                    }
                    RelayControl::Error { code, retryable, .. } => relay_operation_rejection(
                        &code,
                        retryable,
                        "relay registration is temporarily unavailable",
                    ),
                    _ => continue,
                }
            }
            Err(error) => error,
        };
        // The current socket ended (the relay saw the renewal's Register before
        // this socket's last read, or its ticket ran out) while a renewal is in
        // flight: the renewal decides, and the registration continues on it.
        let Some(pending) = renewal.take() else {
            return Err(failure);
        };
        let renewed = tokio::select! {
            renewed = pending => renewed,
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Ok(());
                }
                return Err(failure);
            }
        };
        let Ok(control) = renewed else {
            return Err(failure);
        };
        socket = control.socket;
        liveness = registration_liveness(control.lease_seconds);
        renew_at = control.renew_at;
    }
}

fn registration_liveness(lease_seconds: u32) -> Liveness {
    let heartbeat = Duration::from_secs(u64::from(lease_seconds).max(3) / 3);
    Liveness::new(heartbeat, Instant::now(), wall_now())
}

/// Polls `future` when there is one, else never completes (a `select!`
/// branch's future is built even while its branch is off).
async fn poll_some<F: Future + Unpin>(future: Option<&mut F>) -> F::Output {
    match future {
        Some(future) => future.await,
        None => std::future::pending().await,
    }
}

/// Reads `socket`'s next control message when there is a socket, else never.
async fn read_some(socket: Option<&mut RelaySocket>) -> Result<RelayControl, ProviderError> {
    match socket {
        Some(socket) => read_control(socket).await,
        None => std::future::pending().await,
    }
}

/// How long one daemon-side Join of an `Incoming` circuit has alone before a
/// second one starts beside it (on a new WebSocket, with the same join ticket).
/// A fresh Cloud machine's daemon, paired with a parked Connect the moment it
/// registered, sometimes never joined that first circuit: production
/// `cloud-chat-replies-production`, cold starts 2026-11-22 18:00Z to 11-23
/// 06:10Z, the first dial of 3 of 9 created machines waited out the client's
/// whole 4 s peer-join wait (`outcome=relay`, link 7.2 to 11.7 s) though the
/// daemon had registered in 340 ms, and the client's redial was joined in 0.6 to
/// 1 s every time. The one Join was given up silently, and its WebSocket connect
/// (resolve, TCP, TLS, upgrade) is bounded only by the relay's 10 s connect.
/// A healthy Join is Ready in well under a second (both ends join on the same
/// Allocated/Incoming pair), so a second attempt at 1 s lands inside the client's
/// wait. An extra Join on a circuit the first already joined is refused by the
/// relay (`duplicate-role`) and closes; the first keeps waiting.
const DAEMON_JOIN_STAGGER: Duration = Duration::from_secs(1);
/// Daemon-side Joins of one `Incoming` in all: one every [`DAEMON_JOIN_STAGGER`]
/// while none is Ready, all kept in flight until the registration's control
/// timeout.
const DAEMON_JOIN_ATTEMPTS: usize = 4;

/// The first of `attempt`'s results that is Ok, starting one attempt at once
/// and another every `stagger` while none has been (at most `most` in all,
/// every one kept in flight), within `budget`. The error is the last failed
/// attempt's, or a join timeout when the budget ran out first.
async fn hedged_join<T, F, Fut>(
    mut attempt: F,
    stagger: Duration,
    most: usize,
    budget: Duration,
) -> Result<T, ProviderError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, ProviderError>>,
{
    use futures_util::stream::FuturesUnordered;
    let deadline = Instant::now() + budget;
    let mut running = FuturesUnordered::new();
    running.push(attempt());
    let mut launched = 1_usize;
    let mut next_launch = Instant::now() + stagger;
    let mut last_error = None;
    loop {
        let more = launched < most.max(1);
        tokio::select! {
            Some(result) = running.next(), if !running.is_empty() => match result {
                Ok(joined) => return Ok(joined),
                Err(error) => {
                    last_error = Some(error);
                    if running.is_empty() && !more {
                        break;
                    }
                }
            },
            _ = tokio::time::sleep_until(next_launch), if more => {
                running.push(attempt());
                launched += 1;
                next_launch = Instant::now() + stagger;
            }
            _ = tokio::time::sleep_until(deadline) => break,
        }
    }
    Err(last_error.unwrap_or_else(|| relay_carrier_error("relay circuit join timed out")))
}

/// Joins the circuit an `Incoming` names and hands it to `daemon`, unless the
/// circuit is already joined or the registration holds its most circuits. The
/// Join is hedged ([`DAEMON_JOIN_STAGGER`]); one that never became Ready is
/// written to the registration's log, with how long it was tried.
#[allow(clippy::too_many_arguments)]
fn spawn_incoming(
    circuits: &mut IncomingCircuitTasks,
    daemon: &Arc<dyn RelayIncoming>,
    config: &RelayDaemonConfig,
    framing: RelayCircuitFraming,
    tls: &RelayTls,
    circuit: CircuitId,
    lane: LaneToken,
    generation: u64,
    join_ticket: String,
    log: &RegisterLog,
) {
    let daemon = daemon.clone();
    let endpoint = config.endpoint.clone();
    let slot = config.slot.clone();
    let maximum = config.maximum_frame_bytes;
    let timeout = config.control_timeout;
    let tls = tls.clone();
    let label = log.label.clone();
    let task_circuit = circuit.clone();
    circuits.try_spawn(circuit, async move {
        let started = Instant::now();
        let joined = hedged_join(
            || {
                join_circuit(
                    &endpoint,
                    &slot,
                    RelayRole::Daemon,
                    framing,
                    task_circuit.clone(),
                    lane.clone(),
                    generation,
                    join_ticket.clone(),
                    maximum,
                    timeout,
                    &tls,
                )
            },
            DAEMON_JOIN_STAGGER,
            DAEMON_JOIN_ATTEMPTS,
            timeout,
        )
        .await;
        match joined {
            Ok(link) => daemon.incoming(link).await,
            Err(error) => {
                if let Some(label) = &label {
                    eprintln!(
                        "{label}: an incoming circuit was not joined after {} ms: {error}",
                        started.elapsed().as_millis()
                    );
                }
            }
        }
    });
}

struct IncomingCircuitTasks {
    maximum: usize,
    active: HashSet<CircuitId>,
    task_circuits: HashMap<Id, CircuitId>,
    tasks: JoinSet<()>,
}

impl IncomingCircuitTasks {
    fn new(maximum: usize) -> Self {
        Self {
            maximum,
            active: HashSet::new(),
            task_circuits: HashMap::new(),
            tasks: JoinSet::new(),
        }
    }

    fn is_empty(&self) -> bool {
        self.tasks.is_empty()
    }

    fn try_spawn(
        &mut self,
        circuit: CircuitId,
        task: impl Future<Output = ()> + Send + 'static,
    ) -> bool {
        if self.tasks.len() >= self.maximum || !self.active.insert(circuit.clone()) {
            return false;
        }
        let handle = self.tasks.spawn(task);
        self.task_circuits.insert(handle.id(), circuit);
        true
    }

    async fn join_next(&mut self) {
        let task_id = match self.tasks.join_next_with_id().await {
            Some(Ok((task_id, ()))) => Some(task_id),
            Some(Err(error)) => Some(error.id()),
            None => None,
        };
        if let Some(circuit) = task_id.and_then(|task_id| self.task_circuits.remove(&task_id)) {
            self.active.remove(&circuit);
        }
    }

    async fn shutdown(&mut self) {
        self.tasks.shutdown().await;
        self.active.clear();
        self.task_circuits.clear();
    }
}

/// A second control socket's authentication, in flight while the first serves.
type Renewal<'a> = Pin<Box<dyn Future<Output = Result<DaemonControl, ProviderError>> + Send + 'a>>;

/// A daemon control socket the relay answered `Registered` on.
struct DaemonControl {
    socket: RelaySocket,
    lease_seconds: u32,
    /// When to register again with a fresh ticket, before this one expires:
    /// [`RENEW_AT_LIFETIME_FRACTION`] of the ticket's lifetime after it was
    /// fetched (on this machine's monotonic clock, so a skewed wall clock does
    /// not move it). None when the source cannot give a new ticket or the
    /// ticket's lifetime is not readable: such a registration lasts as before.
    renew_at: Option<Instant>,
}

/// A registration renews when this share of its ticket's lifetime has passed
/// (200 s of a platform ticket's 300 s), which leaves a third of it for a
/// renewal that fails to be retried before the relay ends the registration.
const RENEW_AT_LIFETIME_FRACTION: (u32, u32) = (2, 3);
/// The wait before trying a failed renewal again.
const RENEWAL_RETRY: Duration = Duration::from_secs(5);

fn renewal_time(
    credentials: &RelayCredentialSource,
    credential: &RelayCredential,
    fetched_at: Instant,
) -> Option<Instant> {
    if !credentials.renews() {
        return None;
    }
    let (numerator, denominator) = RENEW_AT_LIFETIME_FRACTION;
    let lifetime = credential.lifetime()?;
    Some(fetched_at + lifetime * numerator / denominator)
}

async fn authenticate_daemon_control(
    config: &RelayDaemonConfig,
    credentials: &RelayCredentialSource,
    tls: &RelayTls,
) -> Result<DaemonControl, ProviderError> {
    let mut retried_authentication = false;
    loop {
        let fetched_at = Instant::now();
        let credential = credentials.fetch().await?;
        let renew_at = renewal_time(credentials, &credential, fetched_at);
        let mut socket = match connect_relay_socket_once(
            &config.endpoint,
            Some(&credential),
            MAX_RELAY_CONTROL_MESSAGE_BYTES,
            tls,
        )
        .await
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
            .map_err(|_| relay_carrier_error("relay registration timed out"))??;
        match reply {
            RelayControl::Registered { lease_seconds } => {
                return Ok(DaemonControl { socket, lease_seconds, renew_at });
            }
            RelayControl::Error { code, .. }
                if relay_authentication_error(&code) && !retried_authentication =>
            {
                retried_authentication = true;
            }
            RelayControl::Error { code, retryable, .. } => {
                return Err(relay_operation_rejection(
                    &code,
                    retryable,
                    "relay registration is temporarily unavailable",
                ));
            }
            _ => {
                return Err(ProviderError::Link(LinkError::Protocol(
                    "relay sent an invalid registration reply".into(),
                )));
            }
        }
    }
}

async fn connect_provider_control(
    endpoint: &Url,
    credentials: &RelayCredentialSource,
    tls: &RelayTls,
) -> Result<RelaySocket, ProviderError> {
    let mut retried_authentication = false;
    loop {
        let credential = credentials.fetch().await?;
        match connect_relay_socket_once(
            endpoint,
            Some(&credential),
            MAX_RELAY_CONTROL_MESSAGE_BYTES,
            tls,
        )
        .await
        {
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
    maximum_message_bytes: usize,
    tls: &RelayTls,
) -> Result<RelaySocket, ProviderError> {
    let credential =
        authorization.map(|ticket| RelayCredential::parse(ticket.to_owned())).transpose()?;
    connect_relay_socket_once(endpoint, credential.as_ref(), maximum_message_bytes, tls)
        .await
        .map_err(RelaySocketConnectError::into_provider_error)
}

async fn connect_relay_socket_once(
    endpoint: &Url,
    authorization: Option<&RelayCredential>,
    maximum_message_bytes: usize,
    tls: &RelayTls,
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
    let config = WebSocketConfig::default()
        .max_message_size(Some(maximum_message_bytes))
        .max_frame_size(Some(maximum_message_bytes));
    let opened = tokio::time::timeout(RELAY_CONNECT_TIMEOUT, async {
        // The TCP connect is hedged (`hedge`): a relay host's black-holed SYN gets a new socket
        // in 400 ms instead of this whole budget. TLS and the upgrade run on the winner.
        let socket = connect_relay_tcp(endpoint).await?;
        client_async_tls_with_config(request, socket, Some(config), tls.connector()).await
    })
    .await
    .map_err(|_| {
        RelaySocketConnectError::Provider(ProviderError::Link(LinkError::Transport(format!(
            "relay WebSocket connection failed: no answer within {} ms",
            RELAY_CONNECT_TIMEOUT.as_millis()
        ))))
    })?;
    match opened {
        Ok((socket, _)) => Ok(socket),
        Err(tokio_tungstenite::tungstenite::Error::Http(response))
            if matches!(response.status(), StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) =>
        {
            Err(RelaySocketConnectError::Authentication)
        }
        Err(error) => Err(RelaySocketConnectError::Provider(relay_connect_error(error))),
    }
}

/// The relay endpoint's TCP stream, hedged over its addresses ([`super::hedge`]), Nagle off.
async fn connect_relay_tcp(endpoint: &Url) -> Result<TcpStream, WebSocketError> {
    let host = endpoint.host_str().ok_or(WebSocketError::Url(UrlError::NoHostName))?;
    let port = endpoint
        .port_or_known_default()
        .ok_or(WebSocketError::Url(UrlError::UnsupportedUrlScheme))?;
    let addresses = super::dial::resolve_dial_target(host, port)
        .await
        .map_err(|error| WebSocketError::Io(std::io::Error::other(error.to_string())))?;
    let socket =
        super::hedge::connect(&addresses, super::hedge::HedgePolicy::INTERNET, TcpStream::connect)
            .await
            .map_err(WebSocketError::Io)?;
    let _ = socket.set_nodelay(true);
    Ok(socket)
}

fn relay_connect_error(error: WebSocketError) -> ProviderError {
    let detail = match error {
        WebSocketError::ConnectionClosed => "connection closed".into(),
        WebSocketError::AlreadyClosed => "connection was already closed".into(),
        WebSocketError::Io(error) => format!("I/O error: {error}"),
        WebSocketError::Tls(error) => format!("TLS error: {error}"),
        WebSocketError::Capacity(error) => format!("capacity error: {error}"),
        WebSocketError::Protocol(error) => format!("protocol error: {error}"),
        WebSocketError::WriteBufferFull(_) => "write buffer was full".into(),
        WebSocketError::Utf8(_) => "invalid UTF-8".into(),
        WebSocketError::AttackAttempt => "attack attempt detected".into(),
        WebSocketError::Url(error) => format!("URL error: {error}"),
        WebSocketError::Http(response) => format!("HTTP status {}", response.status()),
        WebSocketError::HttpFormat(_) => "invalid HTTP handshake".into(),
    };
    ProviderError::Link(LinkError::Transport(format!(
        "relay WebSocket connection failed: {detail}"
    )))
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

fn relay_carrier_error(message: impl Into<String>) -> ProviderError {
    ProviderError::Link(LinkError::Transport(message.into()))
}

fn relay_operation_rejection(
    code: &str,
    retryable: bool,
    retryable_message: &'static str,
) -> ProviderError {
    if retryable && !relay_authentication_error(code) {
        relay_unavailable(retryable_message, code)
    } else {
        relay_rejection()
    }
}

fn relay_reconnect_error(
    control_error: &ProviderError,
    reconnect_error: ProviderError,
) -> ProviderError {
    let message =
        format!("relay control failed ({control_error}); reconnect failed: {reconnect_error}");
    if reconnect_error.is_retryable_carrier_failure() {
        relay_carrier_error(message)
    } else {
        ProviderError::Transport(message)
    }
}

/// The relay's code for a slot whose daemon's ticket ran out with no renewal: the machine's
/// relay credential is unavailable (its mint is down or stalled).
const RELAY_CREDENTIAL_UNAVAILABLE: &str = "credential-unavailable";

/// A retryable refusal, naming the relay's error code: a short word the
/// relay sets (`slot-busy`), kept only when it looks like one. A lapsed
/// registration (`credential-unavailable`) leads with that reason, the words a
/// link's offline reason is read from (acpmux `peer_carrier::reason`), so the
/// dial says why the machine is offline instead of reading as still connecting.
fn relay_unavailable(message: &str, code: &str) -> ProviderError {
    if code == RELAY_CREDENTIAL_UNAVAILABLE {
        return relay_carrier_error(format!(
            "{RELAY_CREDENTIAL_UNAVAILABLE}: the machine's relay ticket expired and was not \
             renewed (relay code {RELAY_CREDENTIAL_UNAVAILABLE})"
        ));
    }
    let word = code.len() <= 32
        && !code.is_empty()
        && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    relay_carrier_error(format!("{message} (relay code {})", if word { code } else { "other" }))
}

fn relay_rejection() -> ProviderError {
    ProviderError::Transport("relay rejected the authenticated operation".into())
}

async fn send_control(
    socket: &mut RelaySocket,
    control: &RelayControl,
) -> Result<(), ProviderError> {
    let encoded = serde_json::to_string(control)
        .map_err(|error| ProviderError::Link(LinkError::Protocol(error.to_string())))?;
    socket
        .send(Message::Text(encoded.into()))
        .await
        .map_err(|_| relay_carrier_error("relay WebSocket write failed"))
}

async fn read_control(socket: &mut RelaySocket) -> Result<RelayControl, ProviderError> {
    loop {
        match socket.next().await {
            Some(Ok(Message::Text(text))) => {
                return serde_json::from_str(&text).map_err(|error| {
                    ProviderError::Link(LinkError::Protocol(format!(
                        "invalid relay control: {error}"
                    )))
                });
            }
            Some(Ok(Message::Ping(bytes))) => {
                socket
                    .send(Message::Pong(bytes))
                    .await
                    .map_err(|_| relay_carrier_error("relay WebSocket write failed"))?;
            }
            Some(Ok(Message::Pong(_))) => {}
            Some(Ok(Message::Close(Some(frame)))) => {
                return Err(relay_carrier_error(format!(
                    "relay WebSocket closed (close {})",
                    u16::from(frame.code)
                )));
            }
            Some(Ok(Message::Close(None))) | None => {
                return Err(relay_carrier_error("relay WebSocket closed"));
            }
            Some(Ok(Message::Binary(_))) => {
                return Err(ProviderError::Link(LinkError::Protocol(
                    "relay sent binary data on a control socket".into(),
                )));
            }
            Some(Ok(_)) => {}
            Some(Err(_)) => {
                return Err(relay_carrier_error("relay WebSocket read failed"));
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
#[path = "relay_registration_state_tests.rs"]
mod registration_state_tests;
#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;
