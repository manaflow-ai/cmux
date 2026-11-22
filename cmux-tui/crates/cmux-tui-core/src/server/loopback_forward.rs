//! Loopback forwarding (`loopback-forward-v1`): multiplexed TCP streams from a
//! control client to this machine's own loopback services.
//!
//! The cmux app uses it so a browser tab whose workspace lives on this
//! machine can open `http://localhost:3000` and reach the dev server that runs
//! here, like an SSH `-L` tunnel without a listening socket on either side.
//!
//! Security rules (plans/cmux-next/remote-localhost.md):
//! - Off unless the connection asks: a Unix control client must declare the
//!   capability with `set-client-info`, and the daemon policy must allow it.
//! - Loopback only: the target is `localhost`, `*.localhost`, or a loopback
//!   IP literal. No DNS lookup decides the target, and the connected peer is
//!   checked again after connect.
//! - Bounded: per-connection and daemon-wide stream limits, credit-based flow
//!   control in both directions, bounded frames, and an audit ring.
//! - No new listening socket anywhere.
//!
//! Wire (JSON lines, same framing as every v12 command):
//! - `loopback-open {id, stream, host, port, window?}` answers
//!   `{stream, address, window}` or an error with `error_code`.
//! - `loopback-data {stream, data}` (base64, no reply), `loopback-credit
//!   {stream, bytes}`, `loopback-shutdown {stream}` (half close),
//!   `loopback-close {stream}`, `loopback-status {id}`.
//! - Events: `loopback-data`, `loopback-credit`, `loopback-eof`,
//!   `loopback-closed {stream, error?}`. Data, EOF and close of one stream
//!   travel in one ordered outbound stream.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream};
use std::ops::RangeInclusive;
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{MessageWriter, OutboundStream, Response, send_response};
use crate::mux::Mux;

pub const LOOPBACK_FORWARD_CAPABILITY: &str = "loopback-forward-v1";

/// Largest decoded payload of one `loopback-data` frame, both directions.
pub(crate) const MAX_FRAME_BYTES: usize = 64 * 1024;
/// Bytes the daemon accepts from the client before it returns credit.
pub(crate) const DAEMON_RECEIVE_WINDOW: usize = 256 * 1024;
/// The client's receive window when `loopback-open` names none.
pub(crate) const DEFAULT_CLIENT_WINDOW: usize = 256 * 1024;
const MIN_CLIENT_WINDOW: usize = 16 * 1024;
const MAX_CLIENT_WINDOW: usize = 4 * 1024 * 1024;
pub(crate) const MAX_STREAMS_PER_CLIENT: usize = 128;
pub(crate) const MAX_STREAMS_TOTAL: usize = 512;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const AUDIT_CAPACITY: usize = 256;
const MAX_HOST_BYTES: usize = 253;
const THREAD_STACK_BYTES: usize = 256 * 1024;

// MARK: Policy

/// Daemon-side switch and port rules, from `server.loopback_forward` in
/// cmux-tui.json. The default allows every port; `false` turns it off.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoopbackForwardPolicy {
    enabled: bool,
    allow: Vec<RangeInclusive<u16>>,
    deny: Vec<RangeInclusive<u16>>,
}

impl Default for LoopbackForwardPolicy {
    fn default() -> Self {
        Self { enabled: true, allow: vec![1..=u16::MAX], deny: Vec::new() }
    }
}

impl LoopbackForwardPolicy {
    pub fn disabled() -> Self {
        Self { enabled: false, allow: Vec::new(), deny: Vec::new() }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// `true`, `false`, or `{"enabled": bool, "allow_ports": [..],
    /// "deny_ports": [..]}` where each port entry is a number or a
    /// `"low-high"` string. Unknown keys and bad entries are errors, so a
    /// typo never silently widens access.
    pub fn from_config_value(value: &Value) -> anyhow::Result<Self> {
        match value {
            Value::Bool(true) => Ok(Self::default()),
            Value::Bool(false) => Ok(Self::disabled()),
            Value::Object(object) => {
                let mut policy = Self::default();
                for (key, entry) in object {
                    match key.as_str() {
                        "enabled" => {
                            policy.enabled = entry
                                .as_bool()
                                .ok_or_else(|| anyhow::anyhow!("enabled must be a boolean"))?;
                        }
                        "allow_ports" => policy.allow = parse_port_ranges(entry, key)?,
                        "deny_ports" => policy.deny = parse_port_ranges(entry, key)?,
                        other => anyhow::bail!("unknown loopback_forward key {other:?}"),
                    }
                }
                Ok(policy)
            }
            _ => anyhow::bail!("loopback_forward must be a boolean or an object"),
        }
    }

    /// Deny wins over allow; port 0 is never valid.
    pub fn permits_port(&self, port: u16) -> bool {
        port != 0
            && self.allow.iter().any(|range| range.contains(&port))
            && !self.deny.iter().any(|range| range.contains(&port))
    }

    /// Adds a port this daemon itself listens on (its WebSocket control
    /// endpoint), so a forwarded page cannot talk to the daemon.
    pub fn deny_port(&mut self, port: u16) {
        self.deny.push(port..=port);
    }
}

fn parse_port_ranges(value: &Value, key: &str) -> anyhow::Result<Vec<RangeInclusive<u16>>> {
    let entries = value.as_array().ok_or_else(|| anyhow::anyhow!("{key} must be an array"))?;
    anyhow::ensure!(entries.len() <= 256, "{key} has too many entries");
    entries
        .iter()
        .map(|entry| match entry {
            Value::Number(number) => {
                let port = number
                    .as_u64()
                    .and_then(|port| u16::try_from(port).ok())
                    .filter(|port| *port != 0)
                    .ok_or_else(|| anyhow::anyhow!("{key}: {number} is not a port"))?;
                Ok(port..=port)
            }
            Value::String(text) => {
                let (low, high) = text.split_once('-').unwrap_or((text, text));
                let low = low.trim().parse::<u16>().ok().filter(|port| *port != 0);
                let high = high.trim().parse::<u16>().ok().filter(|port| *port != 0);
                match (low, high) {
                    (Some(low), Some(high)) if low <= high => Ok(low..=high),
                    _ => anyhow::bail!("{key}: {text:?} is not a port range"),
                }
            }
            _ => anyhow::bail!("{key}: entries are ports or \"low-high\" strings"),
        })
        .collect()
}

// MARK: Target classification

/// Where a stream may connect. `Localhost` tries 127.0.0.1, then ::1 (a dev
/// server bound to `localhost` may listen on either family).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LoopbackTarget {
    Localhost,
    Address(IpAddr),
}

impl LoopbackTarget {
    fn candidates(self, port: u16) -> Vec<SocketAddr> {
        match self {
            Self::Localhost => vec![
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port),
                SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), port),
            ],
            Self::Address(address) => vec![SocketAddr::new(address, port)],
        }
    }
}

/// Classifies a host string without DNS. Accepts `localhost`, names under
/// `.localhost` (RFC 6761), and loopback IP literals (IPv6 with or without
/// brackets, IPv4-mapped loopback). Everything else is refused.
pub(crate) fn classify_target(host: &str) -> Option<LoopbackTarget> {
    if host.is_empty() || host.len() > MAX_HOST_BYTES + 2 {
        return None;
    }
    let unbracketed = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']'));
    if let Some(inner) = unbracketed {
        return inner.parse::<Ipv6Addr>().ok().and_then(|address| loopback_ip(IpAddr::V6(address)));
    }
    if let Ok(address) = host.parse::<IpAddr>() {
        return loopback_ip(address);
    }
    let name = host.strip_suffix('.').unwrap_or(host).to_ascii_lowercase();
    if name.len() > MAX_HOST_BYTES {
        return None;
    }
    let labels: Vec<&str> = name.split('.').collect();
    if labels.last() != Some(&"localhost") {
        return None;
    }
    let valid = labels.iter().all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    });
    valid.then_some(LoopbackTarget::Localhost)
}

fn loopback_ip(address: IpAddr) -> Option<LoopbackTarget> {
    let canonical = address.to_canonical();
    canonical.is_loopback().then_some(LoopbackTarget::Address(canonical))
}

// MARK: Audit

#[derive(Debug, Clone)]
struct AuditRecord {
    at_ms: u64,
    client: u64,
    stream: u64,
    host: String,
    port: u16,
    outcome: String,
    bytes_to_target: u64,
    bytes_from_target: u64,
    duration_ms: u64,
}

impl AuditRecord {
    fn json(&self) -> Value {
        json!({
            "at_ms": self.at_ms,
            "client": self.client,
            "stream": self.stream,
            "host": self.host,
            "port": self.port,
            "outcome": self.outcome,
            "bytes_to_target": self.bytes_to_target,
            "bytes_from_target": self.bytes_from_target,
            "duration_ms": self.duration_ms,
        })
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

// MARK: Forwarder

/// Receives one line per finished or refused forwarded connection.
pub type AuditReporter = Arc<dyn Fn(String) + Send + Sync>;

/// Connection-scoped streams of every client, owned by the client registry.
pub(crate) struct LoopbackForwarder {
    policy: RwLock<LoopbackForwardPolicy>,
    state: Mutex<ForwarderState>,
    audit: Mutex<VecDeque<AuditRecord>>,
    diagnostics: Mutex<Option<AuditReporter>>,
}

#[derive(Default)]
struct ForwarderState {
    /// Open streams by (client, stream id).
    streams: HashMap<(u64, u64), Arc<ForwardStream>>,
    /// Slots reserved by opens in progress, plus open streams, per client.
    slots: HashMap<u64, usize>,
    total: usize,
    opened: u64,
    refused: u64,
}

impl Default for LoopbackForwarder {
    fn default() -> Self {
        Self {
            policy: RwLock::new(LoopbackForwardPolicy::default()),
            state: Mutex::new(ForwarderState::default()),
            audit: Mutex::new(VecDeque::new()),
            diagnostics: Mutex::new(None),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OpenError {
    NotEnabled,
    Disabled,
    DeniedHost,
    DeniedPort,
    Limit,
    Duplicate,
    Refused,
    Timeout,
    BadRequest,
}

impl OpenError {
    fn code(self) -> &'static str {
        match self {
            Self::NotEnabled => "loopback.not-enabled",
            Self::Disabled => "loopback.disabled",
            Self::DeniedHost => "loopback.denied-host",
            Self::DeniedPort => "loopback.denied-port",
            Self::Limit => "loopback.limit",
            Self::Duplicate => "loopback.duplicate-stream",
            Self::Refused => "loopback.refused",
            Self::Timeout => "loopback.timeout",
            Self::BadRequest => "loopback.bad-request",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotEnabled => {
                "loopback forwarding needs a Unix client that declared loopback-forward-v1"
            }
            Self::Disabled => "loopback forwarding is turned off on this machine",
            Self::DeniedHost => "only localhost, *.localhost and loopback addresses are forwarded",
            Self::DeniedPort => "this port is not allowed for loopback forwarding",
            Self::Limit => "too many forwarded connections",
            Self::Duplicate => "stream id is already in use",
            Self::Refused => "nothing is listening on that loopback port",
            Self::Timeout => "the loopback connection timed out",
            Self::BadRequest => "bad loopback-open request",
        }
    }
}

impl LoopbackForwarder {
    pub(crate) fn set_policy(&self, policy: LoopbackForwardPolicy) {
        *self.policy.write().unwrap() = policy;
    }

    pub(crate) fn set_diagnostics(&self, reporter: AuditReporter) {
        *self.diagnostics.lock().unwrap() = Some(reporter);
    }

    fn record(&self, record: AuditRecord) {
        let line = format!(
            "loopback-forward client={} stream={} target={}:{} outcome={} up={} down={} ms={}",
            record.client,
            record.stream,
            record.host,
            record.port,
            record.outcome,
            record.bytes_to_target,
            record.bytes_from_target,
            record.duration_ms
        );
        {
            let mut audit = self.audit.lock().unwrap();
            if audit.len() == AUDIT_CAPACITY {
                audit.pop_front();
            }
            audit.push_back(record);
        }
        let reporter = self.diagnostics.lock().unwrap().clone();
        if let Some(reporter) = reporter {
            reporter(line);
        }
    }

    fn reserve(&self, client: u64, stream: u64) -> Result<(), OpenError> {
        let mut state = self.state.lock().unwrap();
        if state.streams.contains_key(&(client, stream)) {
            return Err(OpenError::Duplicate);
        }
        let used = state.slots.get(&client).copied().unwrap_or_default();
        if used >= MAX_STREAMS_PER_CLIENT || state.total >= MAX_STREAMS_TOTAL {
            return Err(OpenError::Limit);
        }
        *state.slots.entry(client).or_default() += 1;
        state.total += 1;
        Ok(())
    }

    fn release(&self, client: u64) {
        let mut state = self.state.lock().unwrap();
        state.total = state.total.saturating_sub(1);
        if let Some(used) = state.slots.get_mut(&client) {
            *used = used.saturating_sub(1);
            if *used == 0 {
                state.slots.remove(&client);
            }
        }
    }

    fn stream(&self, client: u64, stream: u64) -> Option<Arc<ForwardStream>> {
        self.state.lock().unwrap().streams.get(&(client, stream)).cloned()
    }

    /// Ends every stream of a client whose connection is gone.
    pub(crate) fn disconnect(&self, client: u64) {
        let streams: Vec<Arc<ForwardStream>> = {
            let state = self.state.lock().unwrap();
            state
                .streams
                .iter()
                .filter(|((owner, _), _)| *owner == client)
                .map(|(_, stream)| stream.clone())
                .collect()
        };
        for stream in streams {
            stream.fail(self, "disconnected", false);
        }
    }

    fn remove(&self, stream: &ForwardStream) {
        let removed = {
            let mut state = self.state.lock().unwrap();
            state
                .streams
                .get(&(stream.client, stream.id))
                .is_some_and(|current| std::ptr::eq(Arc::as_ptr(current), stream))
                .then(|| state.streams.remove(&(stream.client, stream.id)))
                .flatten()
        };
        if removed.is_some() {
            self.release(stream.client);
        }
    }

    fn status(&self, client: u64) -> Value {
        let policy = self.policy.read().unwrap().clone();
        let state = self.state.lock().unwrap();
        let audit: Vec<Value> = self.audit.lock().unwrap().iter().map(AuditRecord::json).collect();
        json!({
            "enabled": policy.enabled,
            "open_streams": state.streams.len(),
            "client_streams": state.slots.get(&client).copied().unwrap_or_default(),
            "opened": state.opened,
            "refused": state.refused,
            "limits": {
                "per_client": MAX_STREAMS_PER_CLIENT,
                "total": MAX_STREAMS_TOTAL,
                "frame_bytes": MAX_FRAME_BYTES,
                "daemon_window": DAEMON_RECEIVE_WINDOW,
            },
            "audit": audit,
        })
    }
}

// MARK: Streams

struct ForwardStream {
    client: u64,
    id: u64,
    host: String,
    port: u16,
    started: Instant,
    tcp: TcpStream,
    writer: MessageWriter,
    outbound: OutboundStream,
    inner: Mutex<StreamInner>,
    changed: Condvar,
}

#[derive(Default)]
struct StreamInner {
    /// Bytes the daemon may still send to the client.
    send_credit: usize,
    /// Client bytes waiting for the target socket.
    queue: VecDeque<Vec<u8>>,
    /// Client bytes received and not yet returned as credit.
    unacknowledged: usize,
    /// Written bytes not yet returned as credit.
    to_credit: usize,
    client_shutdown: bool,
    /// Why the stream ended early, for tests and the audit record.
    reason: Option<String>,
    reader_done: bool,
    writer_done: bool,
    closed: bool,
    bytes_to_target: u64,
    bytes_from_target: u64,
}

impl ForwardStream {
    fn event(&self, value: &Value) -> std::io::Result<()> {
        self.writer.send_stream_backpressured(value, &self.outbound)
    }

    /// Accepts one client data frame. A client that exceeds the daemon's
    /// window broke flow control; its stream ends.
    fn accept_data(&self, forwarder: &LoopbackForwarder, bytes: Vec<u8>) {
        let mut inner = self.inner.lock().unwrap();
        if inner.closed || inner.client_shutdown {
            drop(inner);
            self.fail(forwarder, "data-after-shutdown", true);
            return;
        }
        if inner.unacknowledged + bytes.len() > DAEMON_RECEIVE_WINDOW {
            drop(inner);
            self.fail(forwarder, "window-exceeded", true);
            return;
        }
        inner.unacknowledged += bytes.len();
        inner.queue.push_back(bytes);
        drop(inner);
        self.changed.notify_all();
    }

    fn grant(&self, bytes: usize) {
        let mut inner = self.inner.lock().unwrap();
        inner.send_credit = inner.send_credit.saturating_add(bytes).min(MAX_CLIENT_WINDOW);
        drop(inner);
        self.changed.notify_all();
    }

    fn shutdown_from_client(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.client_shutdown = true;
        drop(inner);
        self.changed.notify_all();
    }

    /// Ends the stream once: closes the socket, reports `loopback-closed`
    /// (unless the connection itself is gone) and writes the audit record.
    fn fail(&self, forwarder: &LoopbackForwarder, reason: &str, notify: bool) {
        {
            let mut inner = self.inner.lock().unwrap();
            if inner.closed {
                return;
            }
            inner.closed = true;
            inner.queue.clear();
            inner.reason = Some(reason.to_string());
        }
        self.changed.notify_all();
        let _ = self.tcp.shutdown(Shutdown::Both);
        if notify {
            // The outbound stream may be full; the close notice is the
            // overflow text, so it still reaches the client in order.
            self.outbound.close();
            let _ = self.writer.send_control(
                &json!({"event": "loopback-closed", "stream": self.id, "error": reason}),
            );
        }
        self.finish(forwarder, reason);
    }

    /// Both directions finished normally.
    fn complete_if_done(&self, forwarder: &LoopbackForwarder) {
        {
            let mut inner = self.inner.lock().unwrap();
            if inner.closed || !(inner.reader_done && inner.writer_done) {
                return;
            }
            inner.closed = true;
        }
        let _ = self.tcp.shutdown(Shutdown::Both);
        let _ = self.event(&json!({"event": "loopback-closed", "stream": self.id}));
        self.finish(forwarder, "closed");
    }

    fn finish(&self, forwarder: &LoopbackForwarder, outcome: &str) {
        forwarder.remove(self);
        let (up, down) = {
            let inner = self.inner.lock().unwrap();
            (inner.bytes_to_target, inner.bytes_from_target)
        };
        forwarder.record(AuditRecord {
            at_ms: now_ms(),
            client: self.client,
            stream: self.id,
            host: self.host.clone(),
            port: self.port,
            outcome: outcome.to_string(),
            bytes_to_target: up,
            bytes_from_target: down,
            duration_ms: u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX),
        });
    }
}

/// Target to client. Reads only while the client granted credit, and the
/// outbound stream holds at most two frames, so memory stays bounded.
fn run_reader(stream: Arc<ForwardStream>, forwarder: Arc<Mux>) {
    let forwarder = &forwarder.control_clients.loopback;
    let Ok(mut socket) = stream.tcp.try_clone() else {
        stream.fail(forwarder, "internal", true);
        return;
    };
    let mut buffer = vec![0_u8; MAX_FRAME_BYTES];
    loop {
        let allowed = {
            let mut inner = stream.inner.lock().unwrap();
            while inner.send_credit == 0 && !inner.closed {
                inner = stream.changed.wait(inner).unwrap();
            }
            if inner.closed {
                return;
            }
            inner.send_credit.min(MAX_FRAME_BYTES)
        };
        let read = match socket.read(&mut buffer[..allowed]) {
            Ok(read) => read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                stream.fail(forwarder, "read-failed", true);
                return;
            }
        };
        if read == 0 {
            let closed = stream.inner.lock().unwrap().closed;
            if closed {
                return;
            }
            if stream.event(&json!({"event": "loopback-eof", "stream": stream.id})).is_err() {
                stream.fail(forwarder, "client-gone", false);
                return;
            }
            stream.inner.lock().unwrap().reader_done = true;
            stream.complete_if_done(forwarder);
            return;
        }
        {
            let mut inner = stream.inner.lock().unwrap();
            inner.send_credit = inner.send_credit.saturating_sub(read);
            inner.bytes_from_target += read as u64;
        }
        let data = base64::engine::general_purpose::STANDARD.encode(&buffer[..read]);
        let event = json!({"event": "loopback-data", "stream": stream.id, "data": data});
        if stream.event(&event).is_err() {
            stream.fail(forwarder, "client-gone", false);
            return;
        }
    }
}

/// Client to target. Returns credit after each write, batched to a quarter
/// window or an empty queue.
fn run_writer(stream: Arc<ForwardStream>, forwarder: Arc<Mux>) {
    let forwarder = &forwarder.control_clients.loopback;
    let Ok(mut socket) = stream.tcp.try_clone() else {
        stream.fail(forwarder, "internal", true);
        return;
    };
    loop {
        let chunk = {
            let mut inner = stream.inner.lock().unwrap();
            while inner.queue.is_empty() && !inner.client_shutdown && !inner.closed {
                inner = stream.changed.wait(inner).unwrap();
            }
            if inner.closed {
                return;
            }
            match inner.queue.pop_front() {
                Some(chunk) => chunk,
                None => {
                    // Client half-closed and everything is written.
                    drop(inner);
                    let _ = socket.shutdown(Shutdown::Write);
                    stream.inner.lock().unwrap().writer_done = true;
                    stream.complete_if_done(forwarder);
                    return;
                }
            }
        };
        if socket.write_all(&chunk).is_err() {
            stream.fail(forwarder, "write-failed", true);
            return;
        }
        let credit = {
            let mut inner = stream.inner.lock().unwrap();
            inner.bytes_to_target += chunk.len() as u64;
            inner.to_credit += chunk.len();
            if inner.to_credit >= DAEMON_RECEIVE_WINDOW / 4 || inner.queue.is_empty() {
                let credit = inner.to_credit;
                inner.to_credit = 0;
                inner.unacknowledged = inner.unacknowledged.saturating_sub(credit);
                credit
            } else {
                0
            }
        };
        if credit > 0
            && stream
                .writer
                .send_control(
                    &json!({"event": "loopback-credit", "stream": stream.id, "bytes": credit}),
                )
                .is_err()
        {
            stream.fail(forwarder, "client-gone", false);
            return;
        }
    }
}

// MARK: Requests

#[derive(Deserialize)]
struct LoopbackRequest {
    id: Option<Value>,
    #[serde(flatten)]
    command: LoopbackCommand,
}

#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum LoopbackCommand {
    #[serde(rename = "loopback-open")]
    Open {
        stream: u64,
        host: String,
        port: u16,
        #[serde(default)]
        window: Option<usize>,
    },
    #[serde(rename = "loopback-data")]
    Data { stream: u64, data: String },
    #[serde(rename = "loopback-credit")]
    Credit { stream: u64, bytes: usize },
    #[serde(rename = "loopback-shutdown")]
    Shutdown { stream: u64 },
    #[serde(rename = "loopback-close")]
    Close { stream: u64 },
    #[serde(rename = "loopback-status")]
    Status,
}

/// Handles a `loopback-*` message on the connection's reader thread, apart
/// from the per-connection surface queue, so forwarded bytes never use the
/// daemon's surface-operation budget. Returns `None` for other messages.
///
/// A client must wait for the `set-client-info` reply before its first
/// `loopback-open`, because that command runs on the ordered dispatcher.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"loopback-") {
        return None;
    }
    let request = serde_json::from_str::<LoopbackRequest>(message).ok()?;
    let forwarder = &mux.control_clients.loopback;
    let LoopbackRequest { id, command } = request;
    let allowed = mux.control_clients.is_unix(client)
        && mux.control_clients.supports_capability(client, LOOPBACK_FORWARD_CAPABILITY);
    match command {
        LoopbackCommand::Status => {
            if !allowed {
                return Some(open_error(writer, id, OpenError::NotEnabled));
            }
            Some(ok(writer, id, forwarder.status(client)))
        }
        LoopbackCommand::Open { stream, host, port, window } => {
            Some(open(mux, client, allowed, id, stream, host, port, window, writer))
        }
        LoopbackCommand::Data { stream, data } => {
            let Some(target) = allowed.then(|| forwarder.stream(client, stream)).flatten() else {
                return Some(unknown_stream(writer, id, stream));
            };
            match base64::engine::general_purpose::STANDARD.decode(data.as_bytes()) {
                Ok(bytes) if bytes.len() <= MAX_FRAME_BYTES => {
                    if !bytes.is_empty() {
                        target.accept_data(forwarder, bytes);
                    }
                }
                _ => target.fail(forwarder, "bad-frame", true),
            }
            Some(id.is_none() || ok(writer, id, json!({})))
        }
        LoopbackCommand::Credit { stream, bytes } => {
            if let Some(target) = allowed.then(|| forwarder.stream(client, stream)).flatten() {
                target.grant(bytes);
            }
            Some(id.is_none() || ok(writer, id, json!({})))
        }
        LoopbackCommand::Shutdown { stream } => {
            if let Some(target) = allowed.then(|| forwarder.stream(client, stream)).flatten() {
                target.shutdown_from_client();
            }
            Some(id.is_none() || ok(writer, id, json!({})))
        }
        LoopbackCommand::Close { stream } => {
            if let Some(target) = allowed.then(|| forwarder.stream(client, stream)).flatten() {
                target.fail(forwarder, "closed-by-client", true);
            }
            Some(id.is_none() || ok(writer, id, json!({})))
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn open(
    mux: &Arc<Mux>,
    client: u64,
    allowed: bool,
    id: Option<Value>,
    stream: u64,
    host: String,
    port: u16,
    window: Option<usize>,
    writer: &MessageWriter,
) -> bool {
    let forwarder = &mux.control_clients.loopback;
    let policy = forwarder.policy.read().unwrap().clone();
    let refusal = if !allowed {
        Some(OpenError::NotEnabled)
    } else if !policy.enabled {
        Some(OpenError::Disabled)
    } else if window.is_some_and(|window| window < MIN_CLIENT_WINDOW) {
        Some(OpenError::BadRequest)
    } else {
        None
    };
    let target = classify_target(&host);
    let refusal = refusal
        .or_else(|| target.is_none().then_some(OpenError::DeniedHost))
        .or_else(|| (!policy.permits_port(port)).then_some(OpenError::DeniedPort));
    let refusal = refusal.or_else(|| forwarder.reserve(client, stream).err());
    let audit_host: String = host.chars().take(MAX_HOST_BYTES).collect();
    if let Some(refusal) = refusal {
        forwarder.state.lock().unwrap().refused += 1;
        // Requests from clients that never opted in stay out of the log.
        if allowed {
            forwarder.record(AuditRecord {
                at_ms: now_ms(),
                client,
                stream,
                host: audit_host,
                port,
                outcome: refusal.code().to_string(),
                bytes_to_target: 0,
                bytes_from_target: 0,
                duration_ms: 0,
            });
        }
        return open_error(writer, id, refusal);
    }
    let target = target.expect("refusal covers a missing target");
    let window = window.unwrap_or(DEFAULT_CLIENT_WINDOW).min(MAX_CLIENT_WINDOW);
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-loopback-open".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            connect_and_start(
                worker_mux,
                client,
                worker_id,
                stream,
                audit_host,
                port,
                target,
                window,
                worker_writer,
            );
        });
    if spawned.is_err() {
        forwarder.release(client);
        return open_error(writer, id, OpenError::Limit);
    }
    true
}

#[allow(clippy::too_many_arguments)]
fn connect_and_start(
    mux: Arc<Mux>,
    client: u64,
    id: Option<Value>,
    stream_id: u64,
    host: String,
    port: u16,
    target: LoopbackTarget,
    window: usize,
    writer: MessageWriter,
) {
    let forwarder = &mux.control_clients.loopback;
    let started = Instant::now();
    let mut failure = OpenError::Refused;
    let mut connected = None;
    for address in target.candidates(port) {
        match TcpStream::connect_timeout(&address, CONNECT_TIMEOUT) {
            Ok(socket) => {
                // Defense in depth: the peer must be a loopback address.
                if socket.peer_addr().is_ok_and(|peer| peer.ip().to_canonical().is_loopback()) {
                    connected = Some((socket, address));
                    break;
                }
                let _ = socket.shutdown(Shutdown::Both);
                failure = OpenError::DeniedHost;
            }
            Err(error) if error.kind() == std::io::ErrorKind::TimedOut => {
                failure = OpenError::Timeout;
            }
            Err(_) => {}
        }
    }
    let Some((socket, address)) = connected else {
        forwarder.release(client);
        forwarder.state.lock().unwrap().refused += 1;
        forwarder.record(AuditRecord {
            at_ms: now_ms(),
            client,
            stream: stream_id,
            host,
            port,
            outcome: failure.code().to_string(),
            bytes_to_target: 0,
            bytes_from_target: 0,
            duration_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        });
        open_error(&writer, id, failure);
        return;
    };
    let _ = socket.set_nodelay(true);
    let overflow = json!({"event": "loopback-closed", "stream": stream_id, "error": "overflow"});
    let Ok(outbound) = writer.start_stream(&overflow) else {
        forwarder.release(client);
        let _ = socket.shutdown(Shutdown::Both);
        open_error(&writer, id, OpenError::Limit);
        return;
    };
    let stream = Arc::new(ForwardStream {
        client,
        id: stream_id,
        host,
        port,
        started,
        tcp: socket,
        writer: writer.clone(),
        outbound,
        inner: Mutex::new(StreamInner { send_credit: window, ..StreamInner::default() }),
        changed: Condvar::new(),
    });
    {
        let mut state = forwarder.state.lock().unwrap();
        // The connection ended while connecting: the slot is still ours.
        if !writer.is_open() {
            drop(state);
            forwarder.release(client);
            let _ = stream.tcp.shutdown(Shutdown::Both);
            return;
        }
        state.streams.insert((client, stream_id), stream.clone());
        state.opened += 1;
    }
    // The reply is queued before the reader starts, and control messages
    // leave before stream messages, so no data can overtake it.
    let replied = ok(
        &writer,
        id,
        json!({"stream": stream_id, "address": address.to_string(), "window": DAEMON_RECEIVE_WINDOW}),
    );
    if !replied {
        stream.fail(forwarder, "client-gone", false);
        return;
    }
    for (name, run) in [
        ("mux-loopback-rd", run_reader as fn(Arc<ForwardStream>, Arc<Mux>)),
        ("mux-loopback-wr", run_writer as fn(Arc<ForwardStream>, Arc<Mux>)),
    ] {
        let worker = stream.clone();
        let worker_mux = mux.clone();
        let spawned = std::thread::Builder::new()
            .name(name.into())
            .stack_size(THREAD_STACK_BYTES)
            .spawn(move || run(worker, worker_mux));
        if spawned.is_err() {
            stream.fail(forwarder, "internal", true);
            return;
        }
    }
}

fn ok(writer: &MessageWriter, id: Option<Value>, data: Value) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

fn open_error(writer: &MessageWriter, id: Option<Value>, error: OpenError) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(error.message().to_string()),
            error_code: Some(error.code().to_string()),
            error_delivery: None,
        },
    )
}

fn unknown_stream(writer: &MessageWriter, id: Option<Value>, stream: u64) -> bool {
    match id {
        Some(id) => send_response(
            writer,
            Response {
                id: Some(id),
                ok: false,
                data: None,
                error: Some("unknown loopback stream".into()),
                error_code: Some("loopback.unknown-stream".into()),
                error_delivery: None,
            },
        ),
        None => writer
            .send_control(
                &json!({"event": "loopback-closed", "stream": stream, "error": "unknown-stream"}),
            )
            .is_ok(),
    }
}

impl Mux {
    /// Applies `server.loopback_forward` from the daemon configuration.
    pub fn set_loopback_forward_policy(&self, policy: LoopbackForwardPolicy) {
        self.control_clients.loopback.set_policy(policy);
    }

    /// Sends one line per finished or refused forwarded connection to the
    /// daemon log (the audit trail beside `loopback-status`).
    pub fn set_loopback_forward_audit_reporter(&self, reporter: AuditReporter) {
        self.control_clients.loopback.set_diagnostics(reporter);
    }
}

#[cfg(test)]
pub(super) struct WindowProbe {
    forwarder: LoopbackForwarder,
    stream: Arc<ForwardStream>,
    _peer: TcpStream,
}

#[cfg(test)]
impl WindowProbe {
    /// Offers `bytes` from the client; false once the stream has ended.
    pub(super) fn push(&self, bytes: usize) -> bool {
        self.stream.accept_data(&self.forwarder, vec![0_u8; bytes]);
        !self.stream.inner.lock().unwrap().closed
    }

    pub(super) fn closed_reason(&self) -> Option<String> {
        self.stream.inner.lock().unwrap().reason.clone()
    }
}

/// A stream whose writer never drains, so client bytes stay unacknowledged.
#[cfg(test)]
pub(super) fn window_probe() -> WindowProbe {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (peer, _) = listener.accept().unwrap();
    let (writer, _) = super::tests::captured_writer();
    let outbound = writer.start_stream(&json!({})).unwrap();
    let stream = Arc::new(ForwardStream {
        client: 1,
        id: 1,
        host: "127.0.0.1".into(),
        port: 1,
        started: Instant::now(),
        tcp: socket,
        writer,
        outbound,
        inner: Mutex::new(StreamInner::default()),
        changed: Condvar::new(),
    });
    WindowProbe { forwarder: LoopbackForwarder::default(), stream, _peer: peer }
}

#[cfg(test)]
impl LoopbackForwarder {
    pub(super) fn reserve_for_test(&self, client: u64, stream: u64) -> bool {
        self.reserve(client, stream).is_ok()
    }

    pub(super) fn release_for_test(&self, client: u64) {
        self.release(client);
    }
}
