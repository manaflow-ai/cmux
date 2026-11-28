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
use cmux_remote_protocol::{
    CircuitId, LaneToken, MAX_RELAY_BATCH_BYTES, REMOTE_PROTOCOL_VERSION, RelayControl, RelayRole,
};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use http::StatusCode;
use http::header::{AUTHORIZATION, HeaderValue};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc, oneshot, watch};
use tokio::task::{Id, JoinSet};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async_with_config};
use url::Url;
use zeroize::{Zeroize, Zeroizing};

use crate::daemon::{InboundLink, NetworkPeer, RemoteDaemon};
use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    SupportedClientAuthModes, TransportProvider, sanitized_route,
};

type RelaySocket = WebSocketStream<MaybeTlsStream<TcpStream>>;
type RelayCircuitSink = SplitSink<RelaySocket, Message>;
type RelayCircuitStream = SplitStream<RelaySocket>;

const MAX_RELAY_CREDENTIAL_BYTES: usize = 4 * 1024;
const MAX_RELAY_CONTROL_MESSAGE_BYTES: usize = 16 * 1024;
const DEFAULT_CREDENTIAL_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const RELAY_BATCH_MAGIC: [u8; 4] = *b"CMXB";
const RELAY_BATCH_VERSION: u8 = 1;
const RELAY_BATCH_HEADER_BYTES: usize = 8;
const RELAY_BATCH_ENTRY_HEADER_BYTES: usize = 4;
const MAX_RELAY_BATCH_FRAMES: usize = 32;
const RELAY_BATCH_QUEUE_FRAMES: usize = 128;
const RELAY_BATCH_DELAY: Duration = Duration::from_millis(1);
const MAX_RELAY_INCOMING_TASKS: usize = 64;

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
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        crate::secret_file::read_owner_only_string(&path, MAX_RELAY_CREDENTIAL_BYTES)
    })
    .await
    .map_err(|_| credential_source_error("file could not be read"))?
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
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            terminate_child(&mut child).await;
            return Err(credential_source_error("command stdout was unavailable"));
        }
    };
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
            terminate_child(&mut child).await;
            Err(error)
        }
        Err(_) => {
            terminate_child(&mut child).await;
            Err(credential_source_error("command timed out"))
        }
    }
}

/// Kill and reap a credential command on every cancellation or failure path.
/// `kill_on_drop` is best effort and does not guarantee prompt zombie cleanup.
async fn terminate_child(child: &mut tokio::process::Child) {
    let _ = child.kill().await;
    let _ = child.wait().await;
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

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOnly
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let route = sanitized_route(&request.endpoint);
        let framing = RelayCircuitFraming::for_route(&route);
        let endpoint =
            relay_websocket_url(&request.endpoint, &self.config.slot, RelayRole::Client)?;
        let control = connect_provider_control(&endpoint, &self.credentials).await?;
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
    #[cfg(test)]
    fn new(description: impl Into<String>, maximum: usize, socket: RelaySocket) -> Self {
        let description = description.into();
        let framing = RelayCircuitFraming::for_route(&description);
        Self::new_with_framing(description, maximum, framing, socket)
    }

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

async fn run_batched_relay_sender(
    mut socket: RelayCircuitSink,
    mut commands: mpsc::Receiver<RelayCircuitCommand>,
    terminal: watch::Sender<Option<LinkError>>,
) {
    let mut deferred = None;
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
        let result = match command {
            RelayCircuitCommand::Frame(first) => {
                let mut frames = vec![first];
                tokio::time::sleep(RELAY_BATCH_DELAY).await;
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
        let allocation = {
            let mut stored_control = self.control.lock().await;
            if self.closed.load(Ordering::Acquire) {
                return Err(ProviderError::Transport("relay connection group is closed".into()));
            }
            let mut control = match stored_control.take() {
                Some(control) => control,
                None => connect_provider_control(&self.endpoint, &self.credentials).await?,
            };
            match request_allocation(
                &mut control,
                &self.config,
                &self.credentials,
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
                        connect_provider_control(&self.endpoint, &self.credentials)
                            .await
                            .map_err(|error| relay_reconnect_error(&control_error, error))?;
                    match request_allocation(
                        &mut replacement,
                        &self.config,
                        &self.credentials,
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
            self.config.control_timeout,
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
            AllocationError::Reconnect(relay_carrier_error("relay allocation timed out"))
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
            RelayControl::Error { code, retryable, .. } => {
                return Err(if relay_authentication_error(&code) {
                    AllocationError::Authentication(relay_rejection())
                } else if retryable {
                    AllocationError::Reconnect(relay_carrier_error(
                        "relay allocation is temporarily unavailable",
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
) -> Result<Box<dyn FrameLink>, ProviderError> {
    let circuit_endpoint = relay_circuit_url(endpoint, &circuit)?;
    // The circuit starts with JSON Join/Ready messages before it becomes a
    // binary frame link. A caller may intentionally choose a data-frame limit
    // smaller than those control messages, so keep the WebSocket handshake
    // ceiling large enough for control and enforce the advertised data limit
    // in RelayCircuitLink after the circuit is ready.
    let websocket_message_limit = framing.websocket_message_limit(maximum_frame_bytes);
    let mut socket =
        connect_relay_socket(&circuit_endpoint, Some(&ticket), websocket_message_limit).await?;
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
    let framing = RelayCircuitFraming::for_route(&sanitized_route(&config.endpoint));
    let endpoint = relay_websocket_url(&config.endpoint, &config.slot, RelayRole::Daemon)?;
    let config = RelayDaemonConfig { endpoint, ..config };
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (ready_tx, ready_rx) = oneshot::channel();
    let task = tokio::spawn(run_registration_loop(
        daemon,
        config,
        framing,
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
    framing: RelayCircuitFraming,
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
            framing,
            &credentials,
            &mut shutdown,
            &mut first_ready,
        )
        .await;
        if let Err(error) = result
            && first_ready.is_some()
            && !error.is_retryable_carrier_failure()
        {
            if let Some(sender) = first_ready.take() {
                let _ = sender.send(Err(error));
            }
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
    framing: RelayCircuitFraming,
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
    let mut incoming_tasks = IncomingCircuitTasks::new(MAX_RELAY_INCOMING_TASKS);
    let result = loop {
        tokio::select! {
            _ = incoming_tasks.join_next(), if !incoming_tasks.is_empty() => {}
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { break Ok(()) }
            }
            _ = interval.tick() => {
                nonce = nonce.wrapping_add(1);
                if let Err(error) =
                    send_control(&mut socket, &RelayControl::Ping { nonce }).await
                {
                    break Err(error);
                }
            }
            message = read_control(&mut socket) => {
                let message = match message {
                    Ok(message) => message,
                    Err(error) => break Err(error),
                };
                match message {
                    RelayControl::Incoming { circuit, lane, generation, join_ticket } => {
                        let daemon = daemon.clone();
                        let endpoint = config.endpoint.clone();
                        let slot = config.slot.clone();
                        let maximum = config.maximum_frame_bytes;
                        let timeout = config.control_timeout;
                        let task_circuit = circuit.clone();
                        incoming_tasks.try_spawn(circuit, async move {
                            if let Ok(link) = join_circuit(
                                &endpoint,
                                &slot,
                                RelayRole::Daemon,
                                framing,
                                task_circuit,
                                lane,
                                generation,
                                join_ticket,
                                maximum,
                                timeout,
                            ).await {
                                let inbound = InboundLink::network(link, NetworkPeer::Relay);
                                let _ = daemon.accept(inbound).await;
                            }
                        });
                    }
                    RelayControl::Ping { nonce } => {
                        send_control(&mut socket, &RelayControl::Pong { nonce }).await?;
                    }
                    RelayControl::Pong { .. } => {}
                    RelayControl::Error { code, retryable, .. } => {
                        break Err(relay_operation_rejection(
                            &code,
                            retryable,
                            "relay registration is temporarily unavailable",
                        ));
                    }
                    _ => {}
                }
            }
        }
    };
    incoming_tasks.shutdown().await;
    result
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

async fn authenticate_daemon_control(
    config: &RelayDaemonConfig,
    credentials: &RelayCredentialSource,
) -> Result<(RelaySocket, u32), ProviderError> {
    let mut retried_authentication = false;
    loop {
        let credential = credentials.fetch().await?;
        let mut socket = match connect_relay_socket_once(
            &config.endpoint,
            Some(&credential),
            MAX_RELAY_CONTROL_MESSAGE_BYTES,
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
            RelayControl::Registered { lease_seconds } => return Ok((socket, lease_seconds)),
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
) -> Result<RelaySocket, ProviderError> {
    let mut retried_authentication = false;
    loop {
        let credential = credentials.fetch().await?;
        match connect_relay_socket_once(
            endpoint,
            Some(&credential),
            MAX_RELAY_CONTROL_MESSAGE_BYTES,
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
) -> Result<RelaySocket, ProviderError> {
    let credential =
        authorization.map(|ticket| RelayCredential::parse(ticket.to_owned())).transpose()?;
    connect_relay_socket_once(endpoint, credential.as_ref(), maximum_message_bytes)
        .await
        .map_err(RelaySocketConnectError::into_provider_error)
}

async fn connect_relay_socket_once(
    endpoint: &Url,
    authorization: Option<&RelayCredential>,
    maximum_message_bytes: usize,
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
    match connect_async_with_config(request, Some(config), true).await {
        Ok((socket, _)) => Ok(socket),
        Err(tokio_tungstenite::tungstenite::Error::Http(response))
            if matches!(response.status(), StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) =>
        {
            Err(RelaySocketConnectError::Authentication)
        }
        Err(error) => Err(RelaySocketConnectError::Provider(relay_connect_error(error))),
    }
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
        relay_carrier_error(retryable_message)
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
            Some(Ok(Message::Close(_))) | None => {
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
mod tests {
    use std::collections::BTreeMap;
    use std::sync::Mutex as StdMutex;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

    use bytes::Bytes;
    use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
    use tokio::io::AsyncWriteExt;
    use tokio::net::TcpListener;
    use tokio::sync::oneshot;
    use tokio_tungstenite::accept_hdr_async;
    use tokio_tungstenite::tungstenite::handshake::server::Request;
    use tokio_tungstenite::tungstenite::protocol::frame::Frame;
    use tokio_tungstenite::tungstenite::protocol::frame::coding::{Data, OpCode};

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
    async fn relay_dial_bounds_fragmented_messages_and_disables_nagle() {
        const MAXIMUM: usize = 8;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket
                .send(Message::Frame(Frame::message(
                    Bytes::from_static(b"12345"),
                    OpCode::Data(Data::Binary),
                    false,
                )))
                .await
                .unwrap();
            socket
                .send(Message::Frame(Frame::message(
                    Bytes::from_static(b"67890"),
                    OpCode::Data(Data::Continue),
                    true,
                )))
                .await
                .unwrap();
        });

        let mut socket = match connect_relay_socket_once(&endpoint, None, MAXIMUM).await {
            Ok(socket) => socket,
            Err(_) => panic!("bounded relay WebSocket dial failed"),
        };
        let MaybeTlsStream::Plain(stream) = socket.get_ref() else {
            panic!("test relay did not use a plain TCP stream");
        };
        assert!(stream.nodelay().unwrap(), "relay dial left Nagle enabled");
        let error = socket
            .next()
            .await
            .expect("relay WebSocket closed before the oversize message")
            .expect_err("relay WebSocket accepted an oversize fragmented message");
        assert!(
            error.to_string().contains("Message too long: 10 > 8"),
            "relay limit was not enforced by the WebSocket codec: {error}"
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn durable_object_circuit_coalesces_concurrent_frames() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            let first =
                socket.next().await.expect("circuit closed before its first batch").unwrap();
            let second = tokio::time::timeout(Duration::from_millis(25), socket.next()).await;
            (first, second)
        });

        let socket = connect_relay_socket(&endpoint, None, 1024 * 1024).await.unwrap();
        let link = Arc::new(RelayCircuitLink::new("relay+do://relay.example", 64, socket));
        futures_util::future::join_all((0_u8..10).map(|marker| {
            let link = link.clone();
            async move {
                link.send(Bytes::from(vec![marker; 8])).await.unwrap();
            }
        }))
        .await;

        let (first, second) = server.await.unwrap();
        let Message::Binary(batch) = first else {
            panic!("Durable Object relay emitted a non-binary carrier message");
        };
        let frames = decode_relay_batch(batch, 64).unwrap();
        assert_eq!(frames.len(), 10);
        let mut markers = frames.iter().map(|frame| frame[0]).collect::<Vec<_>>();
        markers.sort_unstable();
        assert_eq!(markers, (0_u8..10).collect::<Vec<_>>());
        assert!(
            second.is_err(),
            "Durable Object relay emitted one WebSocket message per logical frame"
        );
    }

    #[test]
    fn durable_object_batch_codec_preserves_frames_and_rejects_malformed_input() {
        let frames = Vec::from([
            Bytes::from_static(b"alpha"),
            Bytes::from_static(b"beta"),
            Bytes::from_static(b"gamma"),
        ]);
        let encoded = encode_relay_batch(&frames).unwrap();
        assert_eq!(decode_relay_batch(encoded, 16).unwrap(), VecDeque::from(frames));

        let mut truncated = encode_relay_batch(&[Bytes::from_static(b"alpha")]).unwrap().to_vec();
        truncated.pop();
        assert!(matches!(
            decode_relay_batch(Bytes::from(truncated), 16),
            Err(LinkError::Protocol(_))
        ));

        let oversized = encode_relay_batch(&[Bytes::from_static(b"alpha")]).unwrap();
        assert!(matches!(
            decode_relay_batch(oversized, 4),
            Err(LinkError::FrameTooLarge { actual: 5, maximum: 4 })
        ));
    }

    #[test]
    fn durable_object_batching_is_scoped_to_its_route_scheme() {
        assert_eq!(
            RelayCircuitFraming::for_route("relay+do://relay.example"),
            RelayCircuitFraming::Batch
        );
        for route in [
            "relay+ws://relay.example",
            "relay+wss://relay.example",
            "relay+https://relay.example",
            "wss://relay.example",
        ] {
            assert_eq!(
                RelayCircuitFraming::for_route(route),
                RelayCircuitFraming::Single,
                "{route}"
            );
        }
    }

    #[tokio::test]
    async fn established_relay_circuit_treats_retryable_error_as_carrier_loss() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let circuit = CircuitId("retryable-error-circuit".into());
        let lane = LaneToken("retryable-error-lane".into());
        let server_circuit = circuit.clone();
        let server_lane = lane.clone();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut socket, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer join-ticket");
            assert_eq!(
                receive_test_control(&mut socket).await,
                RelayControl::Join {
                    protocol: REMOTE_PROTOCOL_VERSION,
                    slot: "test-slot".into(),
                    circuit: server_circuit.clone(),
                    lane: server_lane.clone(),
                    generation: 4,
                    ticket: "join-ticket".into(),
                    role: RelayRole::Client,
                }
            );
            send_test_control(
                &mut socket,
                &RelayControl::Ready { circuit: server_circuit, lane: server_lane, generation: 4 },
            )
            .await;
            send_test_control(
                &mut socket,
                &RelayControl::Error {
                    code: "peer-disconnected".into(),
                    message: "peer disconnected".into(),
                    retryable: true,
                },
            )
            .await;
        });

        let link = join_circuit(
            &endpoint,
            "test-slot",
            RelayRole::Client,
            RelayCircuitFraming::Single,
            circuit,
            lane,
            4,
            "join-ticket".into(),
            64,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert!(matches!(link.receive().await, Err(LinkError::Transport(_))));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn relay_circuit_join_timeout_is_retryable_carrier_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let circuit = CircuitId("join-timeout-circuit".into());
        let lane = LaneToken("join-timeout-lane".into());
        let server_circuit = circuit.clone();
        let server_lane = lane.clone();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut socket, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer join-ticket");
            assert_eq!(
                receive_test_control(&mut socket).await,
                RelayControl::Join {
                    protocol: REMOTE_PROTOCOL_VERSION,
                    slot: "test-slot".into(),
                    circuit: server_circuit,
                    lane: server_lane,
                    generation: 5,
                    ticket: "join-ticket".into(),
                    role: RelayRole::Client,
                }
            );
            let _ = socket.next().await;
        });

        let result = join_circuit(
            &endpoint,
            "test-slot",
            RelayRole::Client,
            RelayCircuitFraming::Single,
            circuit,
            lane,
            5,
            "join-ticket".into(),
            64,
            Duration::from_millis(20),
        )
        .await;
        let error = match result {
            Ok(_) => panic!("relay circuit unexpectedly became ready"),
            Err(error) => error,
        };
        assert!(error.is_retryable_carrier_failure(), "{error}");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn retryable_relay_circuit_rejection_is_retryable_carrier_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let circuit = CircuitId("join-rejection-circuit".into());
        let lane = LaneToken("join-rejection-lane".into());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut socket, _) = accept_with_authorization(stream).await;
            assert!(matches!(
                receive_test_control(&mut socket).await,
                RelayControl::Join { generation: 6, .. }
            ));
            send_test_control(
                &mut socket,
                &RelayControl::Error {
                    code: "peer-unavailable".into(),
                    message: "peer is not ready".into(),
                    retryable: true,
                },
            )
            .await;
        });

        let result = join_circuit(
            &endpoint,
            "test-slot",
            RelayRole::Client,
            RelayCircuitFraming::Single,
            circuit,
            lane,
            6,
            "join-ticket".into(),
            64,
            Duration::from_secs(1),
        )
        .await;
        let error = match result {
            Ok(_) => panic!("relay circuit unexpectedly became ready"),
            Err(error) => error,
        };
        assert!(error.is_retryable_carrier_failure(), "{error}");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn retryable_allocation_rejection_is_retryable_carrier_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            send_test_control(
                &mut socket,
                &RelayControl::Error {
                    code: "edge-unavailable".into(),
                    message: "try another edge".into(),
                    retryable: true,
                },
            )
            .await;
        });

        let mut socket =
            connect_relay_socket(&endpoint, None, MAX_RELAY_CONTROL_MESSAGE_BYTES).await.unwrap();
        let lane = LaneToken("allocation-rejection-lane".into());
        let error = match read_until_allocation(&mut socket, &lane, 7).await {
            Ok(_) => panic!("relay allocation unexpectedly succeeded"),
            Err(error) => error.into_provider_error(),
        };
        assert!(error.is_retryable_carrier_failure(), "{error}");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn relay_registration_timeout_is_retryable_carrier_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut socket, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer registration-ticket");
            assert!(matches!(
                receive_test_control(&mut socket).await,
                RelayControl::Register { .. }
            ));
            let _ = socket.next().await;
        });
        let config = RelayDaemonConfig {
            endpoint: Url::parse(&format!("ws://{address}/v1/relay")).unwrap(),
            slot: "test-slot".into(),
            ticket: String::new(),
            maximum_frame_bytes: 64,
            control_timeout: Duration::from_millis(20),
        };
        let credentials = RelayCredentialSource::static_ticket("registration-ticket").unwrap();

        let result = authenticate_daemon_control(&config, &credentials).await;
        let error = match result {
            Ok(_) => panic!("relay registration unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(error.is_retryable_carrier_failure(), "{error}");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn closed_relay_control_socket_is_retryable_carrier_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket.close(None).await.unwrap();
        });

        let mut socket =
            connect_relay_socket(&endpoint, None, MAX_RELAY_CONTROL_MESSAGE_BYTES).await.unwrap();
        let error = read_control(&mut socket).await.unwrap_err();
        assert!(error.is_retryable_carrier_failure(), "{error}");
        server.await.unwrap();
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

    #[tokio::test]
    async fn daemon_registration_retries_transient_initial_carrier_failure() {
        use crate::identity::AuthDatabase;
        use crate::session::SessionLimits;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint =
            Url::parse(&format!("relay+ws://{}", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (mut failed, _) = listener.accept().await.unwrap();
            failed
                .write_all(
                    b"HTTP/1.1 500 Internal Server Error\r\n\
                      Content-Length: 0\r\n\
                      Connection: close\r\n\r\n",
                )
                .await
                .unwrap();
            failed.shutdown().await.unwrap();

            let (stream, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept())
                .await
                .expect("relay daemon did not retry its initial carrier failure")
                .unwrap();
            let (mut socket, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer registration-ticket");
            assert!(matches!(
                receive_test_control(&mut socket).await,
                RelayControl::Register { .. }
            ));
            send_test_control(&mut socket, &RelayControl::Registered { lease_seconds: 30 }).await;
            while socket.next().await.is_some() {}
        });

        let directory = tempfile::tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "relay-startup-retry", true).unwrap();
        let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
        let registration = tokio::time::timeout(
            Duration::from_secs(2),
            register_relay_daemon(
                daemon,
                RelayDaemonConfig {
                    endpoint,
                    slot: "startup-retry-slot".into(),
                    ticket: "registration-ticket".into(),
                    maximum_frame_bytes: 65_535,
                    control_timeout: Duration::from_secs(1),
                },
            ),
        )
        .await
        .expect("relay registration did not become ready")
        .expect("transient initial carrier failure stopped relay registration");

        tokio::time::timeout(Duration::from_secs(1), registration.shutdown())
            .await
            .expect("relay registration shutdown did not complete");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn provider_description_redacts_relay_capabilities_and_slot() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut socket, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer provider-ticket");
            let _ = socket.next().await;
        });
        let endpoint = Url::parse(&format!(
            "relay+ws://{address}/capability-path?ticket=query-secret#fragment"
        ))
        .unwrap();
        let provider = RelayProvider::new(RelayClientConfig {
            slot: "secret-slot".into(),
            ticket: "provider-ticket".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
        })
        .unwrap();

        let group = provider
            .connect(ConnectRequest {
                endpoint: endpoint.clone(),
                session: SessionId::ZERO,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .unwrap();

        assert_eq!(group.description(), sanitized_route(&endpoint));
        group.close().await.unwrap();
        server.await.unwrap();
    }

    #[test]
    fn relay_config_debug_redacts_endpoint_capabilities_slots_and_tickets() {
        let endpoint = Url::parse(
            "relay+wss://endpoint-user-marker:endpoint-password-marker@relay.example/\
             endpoint-path-marker?ticket=endpoint-query-marker#endpoint-fragment-marker",
        )
        .unwrap();
        let client = RelayClientConfig {
            slot: "client-slot-marker".into(),
            ticket: "client-ticket-marker".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
        };
        let daemon = RelayDaemonConfig {
            endpoint,
            slot: "daemon-slot-marker".into(),
            ticket: "daemon-ticket-marker".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
        };

        let diagnostic = format!("client={client:?} daemon={daemon:?}");

        for secret in [
            "endpoint-user-marker",
            "endpoint-password-marker",
            "endpoint-path-marker",
            "endpoint-query-marker",
            "endpoint-fragment-marker",
            "client-slot-marker",
            "client-ticket-marker",
            "daemon-slot-marker",
            "daemon-ticket-marker",
        ] {
            assert!(
                !diagnostic.contains(secret),
                "relay config Debug leaked {secret:?}: {diagnostic}"
            );
        }
        assert!(diagnostic.contains("relay+wss://relay.example"), "{diagnostic}");
        assert!(diagnostic.contains("65535"), "{diagnostic}");
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
    async fn incoming_circuit_tasks_are_bounded_deduplicated_and_drained() {
        let mut tasks = IncomingCircuitTasks::new(1);
        let (started_tx, started_rx) = oneshot::channel();
        let (release_tx, release_rx) = oneshot::channel();
        let first = CircuitId("first".into());
        assert!(tasks.try_spawn(first.clone(), async move {
            let _ = started_tx.send(());
            let _ = release_rx.await;
        }));
        assert!(!tasks.try_spawn(first, async {}));
        assert!(!tasks.try_spawn(CircuitId("overflow".into()), async {}));
        started_rx.await.unwrap();
        release_tx.send(()).unwrap();
        tasks.join_next().await;

        assert!(tasks.try_spawn(CircuitId("replacement".into()), async {}));
        tasks.join_next().await;
        assert!(tasks.is_empty());

        assert!(tasks.try_spawn(CircuitId("panics".into()), async {
            panic!("test circuit task panic");
        }));
        tasks.join_next().await;
        assert!(tasks.active.is_empty());

        assert!(tasks.try_spawn(CircuitId("cancelled".into()), std::future::pending()));
        tasks.shutdown().await;
        assert!(tasks.is_empty());
        assert!(tasks.active.is_empty());
    }

    #[tokio::test]
    async fn file_and_callback_sources_refresh_without_caching() {
        #[cfg(unix)]
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("relay-ticket");
        tokio::fs::write(&path, "file-ticket-one\n").await.unwrap();
        #[cfg(unix)]
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).await.unwrap();
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
    async fn relay_credential_file_requires_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("relay-ticket");
        tokio::fs::write(&path, "ticket\n").await.unwrap();
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).await.unwrap();
        assert_eq!(RelayCredentialSource::file(&path).fetch().await.unwrap().expose(), "ticket");

        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).await.unwrap();
        assert!(RelayCredentialSource::file(&path).fetch().await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn relay_credential_file_rejects_symlinks() {
        use std::os::unix::fs::{PermissionsExt as _, symlink};

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let link = directory.path().join("relay-ticket");
        tokio::fs::write(&target, "ticket\n").await.unwrap();
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).await.unwrap();
        symlink(&target, &link).unwrap();

        assert!(RelayCredentialSource::file(&link).fetch().await.is_err());
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
    async fn cancelled_allocation_discards_the_shared_control_socket() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (first_seen_tx, first_seen_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut abandoned_control, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer client-ticket");
            assert!(matches!(
                receive_test_control(&mut abandoned_control).await,
                RelayControl::Connect { generation: 1, .. }
            ));
            first_seen_tx.send(()).unwrap();

            let (stream, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
                .await
                .expect("retry reused the cancellation-contaminated control socket")
                .unwrap();
            let (mut replacement_control, authorization) = accept_with_authorization(stream).await;
            assert_eq!(authorization, "Bearer client-ticket");
            let RelayControl::Connect { lane, generation, .. } =
                receive_test_control(&mut replacement_control).await
            else {
                panic!("expected retried relay allocation");
            };
            assert_eq!(generation, 2);
            let circuit = CircuitId("after-cancellation".into());
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
        });

        let provider = RelayProvider::new(RelayClientConfig {
            slot: "test-slot".into(),
            ticket: "client-ticket".into(),
            maximum_frame_bytes: 64,
            control_timeout: Duration::from_secs(5),
        })
        .unwrap();
        let group = provider
            .connect(ConnectRequest {
                endpoint: Url::parse(&format!("relay+ws://{address}/v1/relay")).unwrap(),
                session: SessionId::ZERO,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .unwrap();
        let abandoned = tokio::spawn({
            let group = group.clone();
            async move { group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await }
        });
        first_seen_rx.await.unwrap();
        abandoned.abort();
        assert!(matches!(abandoned.await, Err(error) if error.is_cancelled()));

        let link = tokio::time::timeout(
            Duration::from_secs(10),
            group.open(LinkRequest { lane: Lane::Interactive, generation: 2 }),
        )
        .await
        .expect("relay allocation did not recover after cancellation")
        .unwrap();
        assert_eq!(link.maximum_frame_bytes(), 64);
        assert!(matches!(
            link.send(Bytes::from(vec![0_u8; 65])).await,
            Err(LinkError::FrameTooLarge { actual: 65, maximum: 64 })
        ));
        link.send(Bytes::from_static(b"after cancellation")).await.unwrap();
        assert_eq!(link.receive().await.unwrap().unwrap(), b"after cancellation".as_slice());
        link.close().await.unwrap();
        group.close().await.unwrap();
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
                control_timeout: Duration::from_secs(10),
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
