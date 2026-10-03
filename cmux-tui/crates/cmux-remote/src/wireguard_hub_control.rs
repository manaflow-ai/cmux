//! The hub's control socket (transport.md 12a): path events and the
//! datagram service for local processes of the same user.
//!
//! The control socket is an owner-only (`0600`) Unix stream socket that
//! speaks newline-delimited JSON. Each request is
//! `{"id":N,"method":M,"params":{...}}`; each reply is
//! `{"id":N,"result":{...}}` or `{"id":N,"error":{"code":C,"message":S}}`.
//! Methods:
//!
//! - `path.get`: the current path as a `path.changed` body.
//! - `path.subscribe`: the same, then one line per path event,
//!   `{"event":"path.changed","path":P,"kind":K,"rtt_ms":..,"jitter_ms":..,
//!   "loss_pct":..,"max_datagram":..}`, on every switch and every 5 s while
//!   the tunnel carries traffic.
//! - `datagram.bind {"port":P,"class":"interactive"|"media"|"bulk"}`: bind
//!   overlay UDP port `P` and serve it on a Unix datagram socket next to the
//!   control socket (`<control>.dgram-<P>`, `0600`). The binding lives as
//!   long as the control connection that made it.
//! - `datagram.stats`: datagrams the tunnel dropped, by reason.
//!
//! Every datagram on a datagram socket carries the SOCKS5 UDP request header
//! (RFC 1928 section 7: two zero bytes, fragment 0, address type 1 or 4, the
//! address, the port) before its payload. A client sends to the overlay
//! address in the header; the hub delivers received datagrams with the
//! sender's overlay address in the header, to the socket address that most
//! recently sent on that port (the client must bind its own socket to a
//! path to receive). The hub drops what does not fit: a payload above
//! `max_datagram`, a malformed header, a reader that is not keeping up.

use std::collections::HashSet;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_wg::{MultipathControl, PathEvent, PathKind, Priority, WgDatagramSocket, WgError, WgNet};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixDatagram, UnixStream};
use tokio::sync::{Semaphore, broadcast, mpsc, oneshot};
use tokio::task::JoinSet;

use crate::admin::verify_unix_peer_owner;
use crate::provider::socks::{ADDRESS_IPV4, ADDRESS_IPV6};
use crate::unix_socket::{OwnedUnixListener, UnixAcceptBackoff, UnixSocketCleanup};
use crate::wireguard_hub::HubError;

/// Control connections served at once.
const MAX_CONTROL_CONNECTIONS: usize = 32;
/// Datagram ports one control connection may bind.
const MAX_BINDINGS_PER_CONNECTION: usize = 16;
/// Longest request line; requests are tiny.
const MAX_REQUEST_BYTES: usize = 4096;
/// Lines queued for a control client before events are skipped (a stalled
/// subscriber must not hold the hub's memory).
const OUTBOUND_LINES: usize = 128;
/// Ports the overlay reserves for itself (transport.md 12a: link, outer
/// WireGuard, probes).
const RESERVED_PORTS: [u16; 3] = [4100, 4101, 4102];
/// The SOCKS5 UDP header before the address: reserved (2), fragment (1),
/// address type (1).
const HEADER_PREFIX: usize = 4;
/// Room for the largest header (IPv6) plus any payload a Unix datagram can
/// carry here; oversized payloads are refused after the read.
const DATAGRAM_BUFFER: usize = 65_536;

/// A running control socket. Dropping it unlinks the socket, ends every
/// control connection and unbinds their datagram ports.
pub struct HubControl {
    path: PathBuf,
    socket_cleanup: Arc<UnixSocketCleanup>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<(), HubError>>>,
}

impl std::fmt::Debug for HubControl {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("HubControl").field("path", &self.path).finish_non_exhaustive()
    }
}

impl HubControl {
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Stop serving, end every control connection (their datagram sockets
    /// are unlinked), and unlink the control socket.
    pub async fn shutdown(mut self) -> Result<(), HubError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        let result = match self.task.take() {
            Some(task) => task
                .await
                .map_err(|error| HubError::Socket(format!("hub control task failed: {error}")))?,
            None => Ok(()),
        };
        let _ = self.socket_cleanup.unlink();
        result
    }
}

impl Drop for HubControl {
    fn drop(&mut self) {
        let _ = self.socket_cleanup.unlink();
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

/// The path of the datagram socket for overlay `port`, next to `control`.
pub fn datagram_socket_path(control: &Path, port: u16) -> PathBuf {
    let mut name = control.file_name().unwrap_or_default().to_os_string();
    name.push(format!(".dgram-{port}"));
    control.with_file_name(name)
}

/// Serve the control socket at `path` for `net`. `paths` is the tunnel's
/// path control (from [`WgNet::start_single_path`] or a multipath setup);
/// without it, `path.get` and `path.subscribe` answer `unavailable`.
///
/// The parent directory gets the same checks as the SOCKS socket's: created
/// `0700` if missing, owned by this user, not writable by others.
pub async fn serve_hub_control(
    net: Arc<WgNet>,
    paths: Option<MultipathControl>,
    path: impl Into<PathBuf>,
) -> Result<HubControl, HubError> {
    let path = path.into();
    let listener = OwnedUnixListener::bind(path.clone()).await?;
    let socket_cleanup = listener.cleanup();
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let permits = Arc::new(Semaphore::new(MAX_CONTROL_CONNECTIONS));
    let hub = Arc::new(Hub { net, paths, control: path.clone() });
    let task = tokio::spawn(async move {
        let mut accept_backoff = UnixAcceptBackoff::new();
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    connections.shutdown().await;
                    return Ok(());
                }
                Some(_) = connections.join_next(), if !connections.is_empty() => {}
                accepted = listener.listener().accept() => {
                    let stream = match accepted {
                        Ok((stream, _)) => {
                            accept_backoff.reset();
                            stream
                        }
                        Err(error) => {
                            let Some(delay) = accept_backoff.retry_delay(&error) else {
                                return Err(HubError::Io(io::Error::new(
                                    error.kind(),
                                    format!("hub control accept failed: {error}"),
                                )));
                            };
                            tokio::select! {
                                _ = &mut shutdown_rx => {
                                    connections.shutdown().await;
                                    return Ok(());
                                }
                                _ = tokio::time::sleep(delay) => {}
                            }
                            continue;
                        }
                    };
                    if verify_unix_peer_owner(&stream).is_err() {
                        continue;
                    }
                    let Ok(permit) = permits.clone().try_acquire_owned() else { continue };
                    let hub = Arc::clone(&hub);
                    connections.spawn(async move {
                        let _permit = permit;
                        hub.serve(stream).await;
                    });
                }
            }
        }
    });
    Ok(HubControl { path, socket_cleanup, shutdown: Some(shutdown_tx), task: Some(task) })
}

struct Hub {
    net: Arc<WgNet>,
    paths: Option<MultipathControl>,
    control: PathBuf,
}

#[derive(Deserialize)]
struct Request {
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BindParams {
    port: u16,
    class: Class,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Class {
    Interactive,
    Media,
    Bulk,
}

impl Class {
    fn priority(self) -> Priority {
        match self {
            Class::Interactive => Priority::Interactive,
            Class::Media => Priority::Media,
            Class::Bulk => Priority::Bulk,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Class::Interactive => "interactive",
            Class::Media => "media",
            Class::Bulk => "bulk",
        }
    }
}

/// An error reply: a stable code and a message for people.
struct Failure(&'static str, String);

/// One bound port: its relay task ends (and the socket file goes) when the
/// binding is dropped with its control connection.
struct Binding {
    path: PathBuf,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Binding {
    fn drop(&mut self) {
        self.task.abort();
        let _ = remove_socket_file(&self.path);
    }
}

impl Hub {
    async fn serve(&self, stream: UnixStream) {
        let (read, mut write) = stream.into_split();
        let (lines_tx, mut lines_rx) = mpsc::channel::<String>(OUTBOUND_LINES);
        let writer = tokio::spawn(async move {
            while let Some(mut line) = lines_rx.recv().await {
                line.push('\n');
                if write.write_all(line.as_bytes()).await.is_err() {
                    return;
                }
            }
        });
        let mut reader = BufReader::new(read).take(u64::MAX);
        let mut bindings: Vec<Binding> = Vec::new();
        let mut bound_ports = HashSet::new();
        let mut subscription: Option<tokio::task::JoinHandle<()>> = None;
        let mut line = Vec::new();
        loop {
            line.clear();
            reader.set_limit(MAX_REQUEST_BYTES as u64 + 1);
            match reader.read_until(b'\n', &mut line).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            if line.len() > MAX_REQUEST_BYTES || line.last() != Some(&b'\n') {
                let _ = lines_tx
                    .send(error_line(&Value::Null, "too_large", "request line too long"))
                    .await;
                break;
            }
            let request = match serde_json::from_slice::<Request>(&line) {
                Ok(request) => request,
                Err(error) => {
                    let reply = error_line(&Value::Null, "invalid_request", &error.to_string());
                    if lines_tx.send(reply).await.is_err() {
                        break;
                    }
                    continue;
                }
            };
            let id = request.id.clone();
            let outcome = match request.method.as_str() {
                "path.get" => self.path_now().map(|event| path_json(&event)),
                "path.subscribe" => self.path_now().map(|event| {
                    if subscription.is_none()
                        && let Some(paths) = &self.paths
                    {
                        let events = paths.path_events();
                        subscription = Some(tokio::spawn(forward_events(events, lines_tx.clone())));
                    }
                    path_json(&event)
                }),
                "datagram.bind" => self.bind(request.params, &mut bindings, &mut bound_ports).await,
                "datagram.stats" => Ok(self.stats()),
                other => Err(Failure("unknown_method", format!("unknown method {other}"))),
            };
            let reply = match outcome {
                Ok(result) => json!({ "id": id, "result": result }).to_string(),
                Err(Failure(code, message)) => error_line(&id, code, &message),
            };
            if lines_tx.send(reply).await.is_err() {
                break;
            }
        }
        if let Some(subscription) = subscription {
            subscription.abort();
        }
        drop(bindings);
        drop(lines_tx);
        let _ = writer.await;
    }

    fn path_now(&self) -> Result<PathEvent, Failure> {
        self.paths.as_ref().map(MultipathControl::snapshot).ok_or_else(|| {
            Failure("unavailable", "this hub was started without path control".into())
        })
    }

    fn stats(&self) -> Value {
        let drops = self.net.datagram_drops();
        json!({
            "media_stale": drops.media_stale,
            "media_full": drops.media_full,
            "interactive_full": drops.interactive_full,
            "bulk_full": drops.bulk_full,
            "inbox_full": drops.inbox_full,
        })
    }

    async fn bind(
        &self,
        params: Value,
        bindings: &mut Vec<Binding>,
        bound_ports: &mut HashSet<u16>,
    ) -> Result<Value, Failure> {
        let params: BindParams = serde_json::from_value(params)
            .map_err(|error| Failure("invalid_params", error.to_string()))?;
        if params.port == 0 || RESERVED_PORTS.contains(&params.port) {
            return Err(Failure("reserved_port", format!("port {} is reserved", params.port)));
        }
        if bindings.len() >= MAX_BINDINGS_PER_CONNECTION {
            return Err(Failure("too_many_bindings", "too many datagram ports bound".into()));
        }
        let socket = self
            .net
            .bind_datagram(params.port)
            .await
            .map_err(|error| Failure("port_busy", error.to_string()))?;
        let path = datagram_socket_path(&self.control, params.port);
        let local = bind_datagram_socket(&path)
            .map_err(|error| Failure("socket_failed", format!("{}: {error}", path.display())))?;
        let max_datagram = socket.max_datagram();
        let task = tokio::spawn(relay(socket, local, params.class.priority()));
        bound_ports.insert(params.port);
        bindings.push(Binding { path: path.clone(), task });
        Ok(json!({
            "socket": path.display().to_string(),
            "port": params.port,
            "class": params.class.name(),
            "max_datagram": max_datagram,
        }))
    }
}

/// Bind a Unix datagram socket at `path` with mode `0600`. The directory is
/// the control socket's, already checked; a leftover socket file from an
/// earlier hub that held this control path is replaced, any other file is
/// refused.
fn bind_datagram_socket(path: &Path) -> io::Result<UnixDatagram> {
    remove_socket_file(path)?;
    let socket = UnixDatagram::bind(path)?;
    if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        let _ = std::fs::remove_file(path);
        return Err(error);
    }
    Ok(socket)
}

/// Remove `path` if it is a socket; a missing path is fine, any other file
/// is an error.
fn remove_socket_file(path: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => std::fs::remove_file(path),
        Ok(_) => Err(io::Error::new(io::ErrorKind::AlreadyExists, "not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Move datagrams between one overlay port and its Unix datagram socket.
async fn relay(mut overlay: WgDatagramSocket, local: UnixDatagram, priority: Priority) {
    let mut client: Option<PathBuf> = None;
    let mut buffer = vec![0u8; DATAGRAM_BUFFER];
    loop {
        tokio::select! {
            received = local.recv_from(&mut buffer) => {
                let Ok((len, from)) = received else { return };
                if let Some(path) = from.as_pathname() {
                    client = Some(path.to_path_buf());
                }
                let Some((peer, payload)) = decode_header(&buffer[..len]) else { continue };
                // Too large, or a destination outside the tunnel: dropped.
                if let Err(WgError::Shutdown) = overlay.send_to(payload, peer, priority).await {
                    return;
                }
            }
            received = overlay.recv_from() => {
                let Some((payload, peer)) = received else { return };
                let Some(client) = &client else { continue };
                let mut datagram = encode_header(peer);
                datagram.extend_from_slice(&payload);
                // A reader that is not keeping up loses datagrams.
                let _ = local.try_send_to(&datagram, client);
            }
        }
    }
}

/// The SOCKS5 UDP request header for `peer`.
pub fn encode_header(peer: SocketAddr) -> Vec<u8> {
    let mut header = vec![0, 0, 0];
    match peer.ip() {
        IpAddr::V4(address) => {
            header.push(ADDRESS_IPV4);
            header.extend_from_slice(&address.octets());
        }
        IpAddr::V6(address) => {
            header.push(ADDRESS_IPV6);
            header.extend_from_slice(&address.octets());
        }
    }
    header.extend_from_slice(&peer.port().to_be_bytes());
    header
}

/// The peer and payload of a datagram with a SOCKS5 UDP request header, or
/// `None` for a malformed header, a fragment, or a domain name.
pub fn decode_header(datagram: &[u8]) -> Option<(SocketAddr, &[u8])> {
    let prefix = datagram.get(..HEADER_PREFIX)?;
    if prefix[..3] != [0, 0, 0] {
        return None;
    }
    let (address, rest): (IpAddr, &[u8]) = match prefix[3] {
        ADDRESS_IPV4 => {
            let octets: [u8; 4] =
                datagram.get(HEADER_PREFIX..HEADER_PREFIX + 4)?.try_into().ok()?;
            (Ipv4Addr::from(octets).into(), &datagram[HEADER_PREFIX + 4..])
        }
        ADDRESS_IPV6 => {
            let octets: [u8; 16] =
                datagram.get(HEADER_PREFIX..HEADER_PREFIX + 16)?.try_into().ok()?;
            (Ipv6Addr::from(octets).into(), &datagram[HEADER_PREFIX + 16..])
        }
        _ => return None,
    };
    let port = u16::from_be_bytes(rest.get(..2)?.try_into().ok()?);
    Some((SocketAddr::new(address, port), &rest[2..]))
}

async fn forward_events(mut events: broadcast::Receiver<PathEvent>, lines: mpsc::Sender<String>) {
    loop {
        match events.recv().await {
            Ok(event) => {
                let mut body = path_json(&event);
                body["event"] = json!("path.changed");
                // A full queue skips this event; the next one carries the
                // same fields.
                match lines.try_send(body.to_string()) {
                    Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                    Err(mpsc::error::TrySendError::Closed(_)) => return,
                }
            }
            Err(broadcast::error::RecvError::Lagged(_)) => {}
            Err(broadcast::error::RecvError::Closed) => return,
        }
    }
}

fn path_json(event: &PathEvent) -> Value {
    json!({
        "path": event.path.map(|path| path.0),
        "kind": event.kind.map(kind_name),
        "rtt_ms": event.rtt_ms,
        "jitter_ms": event.jitter_ms,
        "loss_pct": event.loss_pct,
        "max_datagram": event.max_datagram,
    })
}

/// The wire name of a path kind.
pub fn kind_name(kind: PathKind) -> &'static str {
    match kind {
        PathKind::DirectLan => "direct-lan",
        PathKind::DirectWan => "direct-wan",
        PathKind::ViaCloudRegion => "via-cloud-region",
        PathKind::DoRelay => "do-relay",
    }
}

fn error_line(id: &Value, code: &str, message: &str) -> String {
    json!({ "id": id, "error": { "code": code, "message": message } }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_round_trips_and_refuses_what_it_cannot_carry() {
        for peer in ["10.0.0.7:4103", "[fd00::7]:4103"] {
            let peer: SocketAddr = peer.parse().unwrap();
            let mut datagram = encode_header(peer);
            datagram.extend_from_slice(b"frame");
            assert_eq!(decode_header(&datagram), Some((peer, &b"frame"[..])));
        }
        assert_eq!(decode_header(&[0, 0, 1, 1, 10, 0, 0, 7, 0x10, 0x07]), None, "fragment");
        assert_eq!(decode_header(&[0, 0, 0, 3, 1, b'a', 0x10, 0x07]), None, "domain");
        assert_eq!(decode_header(&[0, 0, 0, 1, 10, 0, 0]), None, "short");
    }

    #[test]
    fn datagram_sockets_sit_next_to_the_control_socket() {
        let path = datagram_socket_path(Path::new("/run/u/hub/control.sock"), 4103);
        assert_eq!(path, Path::new("/run/u/hub/control.sock.dgram-4103"));
    }
}
