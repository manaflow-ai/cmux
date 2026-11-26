//! The [`Service::Acpmux`](cmux_remote_protocol::Service::Acpmux) bridge:
//! each stream of the service becomes one WebSocket to acpmux's carrier
//! socket, `ACPMUX_HOME/run/carrier.sock` (acpmux `docs/carrier-roles.md`).
//!
//! The bridge itself opens the WebSocket. Its upgrade request carries
//! exactly one [`HEADER`], built by [`header`] from the carrier grant that
//! admitted the session, and nothing from the client:
//!
//! ```text
//! x-acpmux-carrier: {"vmk":"owner"|"team","sub":"…","team":"…","chats":["…"]|null,"name":"…"|null}
//! ```
//!
//! `team` is always the grant's team, a string, for an owner too (a grant
//! always has one); it is never `null`.
//!
//! After the upgrade the bridge relays acpmux's JSON-RPC: each line the
//! client writes is one text frame, and each text frame acpmux sends is one
//! line back. The client never writes an HTTP request through the bridge, so
//! a header it forges reaches acpmux as frame bytes, never as a header.
//!
//! A session no grant admitted, a grant without `vmk`, a teammate's grant
//! without `chats`, or a grant whose `svc` lacks `acpmux` is refused before
//! the socket is dialed. An owner's grant sends `chats: null`.
//!
//! The client side ([`open`], [`pump_lines`]) is what `cmux carrier dial
//! --service acpmux` runs: it opens the service on a dialed session and
//! carries newline JSON-RPC between stdio and the stream, writing only whole
//! lines out. The service rides the session's Tunnel lane, which is bound to
//! one session generation and never replayed: a resume of the session resets
//! the stream ([`StreamFailure::GenerationChanged`](crate::service)), and
//! [`pump_lines`] returns that as an error rather than reopening, because a
//! fresh stream is a fresh acpmux connection (its JSON-RPC state is gone).

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_remote_protocol::Service;

use cmux_link::carrier_grant::CarrierGrant;
use cmux_link::token::VmKind;
use futures_util::{SinkExt as _, StreamExt as _};
use tokio::io::{
    AsyncBufReadExt as _, AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _,
};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;

use crate::bridge::{BridgeError, await_opened};
use crate::service::{ServiceMultiplexer, ServiceStream};

/// The upgrade header acpmux reads the person from.
pub const HEADER: &str = "x-acpmux-carrier";

/// The grant service name that holds the bridge.
pub const SERVICE_NAME: &str = "acpmux";

/// acpmux's longest header value, in bytes.
pub const MAX_HEADER_BYTES: usize = 8 * 1024;

/// The longest line a client may write: one JSON-RPC message.
pub const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;

/// How long the upgrade on the carrier socket may take.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// acpmux's carrier socket in `home` (`ACPMUX_HOME`).
pub fn socket_path(home: &Path) -> PathBuf {
    home.join("run").join("carrier.sock")
}

/// The [`HEADER`] value for the session `grant` admitted, or the stable
/// reason the bridge refuses it. Every field comes from the grant.
pub fn header(grant: Option<&CarrierGrant>) -> Result<String, &'static str> {
    let grant = grant.ok_or("acpmux.no_grant")?;
    if !grant.services.iter().any(|service| service == SERVICE_NAME) {
        return Err("acpmux.not_granted");
    }
    let (vmk, chats) = match grant.vm_kind {
        Some(VmKind::Owner) => ("owner", None),
        Some(VmKind::Team) => match grant.chats.as_deref() {
            Some(chats) if !chats.is_empty() => ("team", Some(chats)),
            _ => return Err("acpmux.team_without_chats"),
        },
        None => return Err("acpmux.no_vm_kind"),
    };
    let value = serde_json::json!({
        "vmk": vmk,
        "sub": grant.subject,
        "team": grant.team,
        "chats": chats,
        "name": grant.name,
    });
    let header = ascii_json(&value.to_string());
    if header.len() > MAX_HEADER_BYTES {
        return Err("acpmux.header_too_long");
    }
    Ok(header)
}

/// `json` with every non-ASCII character written as a `\u` escape, so it is
/// a valid header value and the same JSON. Outside strings JSON is ASCII.
fn ascii_json(json: &str) -> String {
    let mut out = String::with_capacity(json.len());
    for c in json.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut units = [0_u16; 2];
            for unit in c.encode_utf16(&mut units) {
                let _ = write!(out, "\\u{unit:04x}");
            }
        }
    }
    out
}

/// Open the WebSocket to acpmux's carrier socket at `socket`, its upgrade
/// carrying `header` as the only [`HEADER`].
#[cfg(unix)]
pub async fn connect(
    socket: &Path,
    header: &str,
) -> io::Result<WebSocketStream<tokio::net::UnixStream>> {
    let stream = tokio::net::UnixStream::connect(socket).await?;
    let mut request = "ws://acpmux/".into_client_request().map_err(io::Error::other)?;
    let value = HeaderValue::from_str(header)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    request.headers_mut().insert(HEADER, value);
    let (ws, _) =
        tokio::time::timeout(HANDSHAKE_TIMEOUT, tokio_tungstenite::client_async(request, stream))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "acpmux upgrade timed out"))?
            .map_err(io::Error::other)?;
    Ok(ws)
}

/// Relay until one side ends: each line from `reader` (a client's JSON-RPC)
/// is one text frame to `ws`, and each text frame from `ws` is one line to
/// `writer`. The client's end sends acpmux a close; acpmux's close ends
/// `writer`.
pub async fn relay<S, R, W>(ws: WebSocketStream<S>, reader: R, mut writer: W) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let (mut sink, mut frames) = ws.split();
    let upload = async {
        let mut reader = tokio::io::BufReader::new(reader);
        let mut line = Vec::new();
        loop {
            line.clear();
            let read =
                (&mut reader).take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line).await?;
            if read == 0 {
                break;
            }
            if line.last() == Some(&b'\n') {
                line.pop();
            } else if line.len() > MAX_LINE_BYTES {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "acpmux line too long"));
            }
            if line.is_empty() {
                continue;
            }
            let text = String::from_utf8(std::mem::take(&mut line))
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            sink.send(Message::text(text)).await.map_err(io::Error::other)?;
        }
        let _ = sink.close().await;
        Ok(())
    };
    let download = async {
        while let Some(frame) = frames.next().await {
            match frame.map_err(io::Error::other)? {
                Message::Text(text) => {
                    writer.write_all(text.as_bytes()).await?;
                    writer.write_all(b"\n").await?;
                }
                Message::Close(_) => break,
                Message::Binary(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "acpmux sent a binary frame",
                    ));
                }
                // tungstenite answers a Ping as it reads: the Pong goes out
                // before the next frame is read, so an idle bridge keeps
                // acpmux's keepalive. A Pong needs nothing.
                _ => {}
            }
        }
        writer.shutdown().await
    };
    tokio::select! {
        result = upload => result,
        result = download => result,
    }
}

/// Opens [`Service::Acpmux`] on a dialed session and waits for the daemon's
/// answer: the opened stream, or [`BridgeError::Rejected`] with the daemon's
/// reason (`acpmux.no_grant`, `acpmux.not_granted`, no acpmux on the host).
pub async fn open(
    multiplexer: &Arc<ServiceMultiplexer>,
) -> Result<Arc<ServiceStream>, BridgeError> {
    let stream = multiplexer.open(Service::Acpmux, BTreeMap::new()).await?;
    if let Err(error) = await_opened(&stream).await {
        let _ = stream.close().await;
        return Err(error);
    }
    Ok(Arc::new(stream))
}

/// Carries newline JSON-RPC between an opened acpmux stream (from [`open`])
/// and `reader` / `writer` until either side ends. Each line from `reader`
/// goes out whole in one send; `writer` gets whole lines only, each flushed,
/// so a reader of it never sees half a message. EOF on `reader` closes the
/// stream's sending side and the call returns when acpmux's side ends. A
/// line longer than [`MAX_LINE_BYTES`] either way, a reset, or the session
/// moving to a new generation under the stream (a resume) is an error.
pub async fn pump_lines<R, W>(
    stream: Arc<ServiceStream>,
    reader: R,
    mut writer: W,
) -> Result<(), BridgeError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let too_long =
        || BridgeError::Io(io::Error::new(io::ErrorKind::InvalidData, "acpmux line too long"));
    let upload = {
        let stream = stream.clone();
        async move {
            let mut reader = tokio::io::BufReader::new(reader);
            loop {
                let mut line = Vec::new();
                let read = (&mut reader)
                    .take(MAX_LINE_BYTES as u64 + 1)
                    .read_until(b'\n', &mut line)
                    .await?;
                if read == 0 {
                    stream.close().await?;
                    return Ok::<_, BridgeError>(());
                }
                if line.last() != Some(&b'\n') && line.len() > MAX_LINE_BYTES {
                    return Err(too_long());
                }
                stream.send(Bytes::from(line)).await?;
            }
        }
    };
    let download = {
        let stream = stream.clone();
        async move {
            let mut pending: Vec<u8> = Vec::new();
            while let Some(chunk) = stream.receive().await? {
                pending.extend_from_slice(&chunk.payload);
                if let Some(end) = pending.iter().rposition(|b| *b == b'\n') {
                    let rest = pending.split_off(end + 1);
                    writer.write_all(&pending).await?;
                    writer.flush().await?;
                    pending = rest;
                }
                if pending.len() > MAX_LINE_BYTES + 1 {
                    return Err(too_long());
                }
                if chunk.reset {
                    return Err(BridgeError::Rejected("the acpmux stream was reset".into()));
                }
                if chunk.finished {
                    break;
                }
            }
            if !pending.is_empty() {
                writer.write_all(&pending).await?;
            }
            writer.shutdown().await?;
            Ok::<_, BridgeError>(())
        }
    };
    let transfer = async {
        tokio::try_join!(upload, download)?;
        Ok::<_, BridgeError>(())
    };
    tokio::pin!(transfer);
    let failure = stream.wait_for_failure();
    tokio::pin!(failure);
    tokio::select! {
        biased;
        error = &mut failure => Err(error.into()),
        result = &mut transfer => result,
    }
}

#[cfg(test)]
#[path = "acpmux_bridge_tests.rs"]
pub(crate) mod tests;
