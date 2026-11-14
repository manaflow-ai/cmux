//! One daemon socket connection (Unix and Windows): newline-delimited
//! JSON-RPC both ways over a `local_stream::Stream`.
//!
//! What a client sends is bounded (manaflow-ai/cmuxterm-hq#2888): unbounded, one line with no
//! newline grew the reader's buffer until the daemon ran out of memory. A line holds at most
//! [`MAX_LINE_BYTES`], and a line past [`SMALL_LINE_BYTES`] goes to the server only when nothing
//! read before it still waits there, so one connection holds at most about two of the largest
//! lines read and not yet parsed: the one being read, and one waiting (or 256 small ones).

use super::{ConnAuth, Hub, Origin, serve_connection_from};
use crate::rpc::{Message, RpcError};
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use tokio_util::codec::{FramedRead, LinesCodec, LinesCodecError};

/// The longest line a socket client may send: what one WebSocket message may carry
/// (`WS_MAX_MESSAGE_BYTES`), so a request either transport takes, the other takes too.
const MAX_LINE_BYTES: usize = super::WS_MAX_MESSAGE_BYTES;
/// A line longer than this waits until the lines before it were taken (see the module docs).
const SMALL_LINE_BYTES: usize = 64 << 10;
/// Lines read and not yet taken by the server.
const INBOUND_LINES: usize = 256;
/// How long the error that ends a connection may take to go out.
const LAST_LINE_WAIT: Duration = Duration::from_secs(2);

/// How much one connection's reader holds.
#[derive(Debug, Clone, Copy)]
struct Limits {
    /// The longest line.
    line: usize,
    /// The longest line that may wait behind others.
    small: usize,
}

/// One daemon socket connection: newline-delimited JSON-RPC both ways.
pub(super) async fn serve_stream(
    hub: Arc<Hub>,
    stream: crate::local_stream::Stream,
    peer: Option<cmux_link::app_caller::PeerToken>,
    provisioner: bool,
    socket_peer: crate::sender_harness::SocketPeer,
    v2: Option<std::sync::Arc<acpmux_core::life::V2>>,
) {
    let daemon_id = hub.run_id();
    let (rd, wr) = crate::local_stream::split(stream);
    let (in_tx, in_rx) = mpsc::channel::<String>(INBOUND_LINES);
    let (out_tx, out_rx) = mpsc::channel::<String>(4096);
    let (last_tx, last_rx) = oneshot::channel();
    let limits = Limits { line: MAX_LINE_BYTES, small: SMALL_LINE_BYTES };
    let reader_v2 = v2.clone();
    let reader =
        tokio::spawn(
            async move { read_lines(rd, in_tx, last_tx, limits, reader_v2.as_deref()).await },
        );
    let may_upgrade = v2.is_some();
    let writer = tokio::spawn(async move {
        let wr = write_lines(wr, out_rx, last_rx).await;
        // With v2 disabled, the task drops its write half just as v1 always did.
        may_upgrade.then_some(wr)
    });
    serve_connection_from(
        hub,
        in_rx,
        out_tx,
        Origin::Local,
        ConnAuth::LocalSocket,
        peer,
        provisioner,
        socket_peer,
        None,
        None,
        None,
        None,
        None,
    )
    .await;
    if let Some(v2) = v2
        && let Ok(Some(upgrade)) = reader.await
        && let Ok(Some(wr)) = writer.await
    {
        let _ = upgrade.serve(wr, &v2, daemon_id).await;
    }
}

struct Upgrade<R> {
    reader: tokio::io::Chain<std::io::Cursor<Vec<u8>>, R>,
    id: Value,
    surfaces: Vec<String>,
}

impl<R: AsyncRead + Unpin> Upgrade<R> {
    async fn serve<W: AsyncWrite + Unpin>(
        self,
        mut writer: W,
        v2: &acpmux_core::life::V2,
        daemon_id: String,
    ) -> Result<(), acpmux_core::conn::ConnError> {
        // The v1 connection has ended, but its upgraded client is still here.
        let _client = crate::daemon::unused_exit::client();
        let reply = Message::ok(
            self.id,
            json!({
                "protocol": 2, "surfaces": self.surfaces, "upgrade": true,
            }),
        );
        writer.write_all(reply.to_line().as_bytes()).await?;
        let source = Arc::new(acpmux_core::conn::HubSource::new(v2.hub()));
        acpmux_core::conn::run(
            self.reader,
            writer,
            source,
            daemon_id,
            &self.surfaces,
            acpmux_core::conn::Role::Local,
        )
        .await
    }
}

fn v2_upgrade(line: &str, v2: &acpmux_core::life::V2) -> Option<(Value, Vec<String>)> {
    let Message::Request { id, method, params: Some(params) } = Message::parse(line).ok()? else {
        return None;
    };
    if method != crate::rpc::method::MUX_V2
        || params.get("protocol").and_then(Value::as_u64) != Some(2)
    {
        return None;
    }
    let requested = params
        .get("surfaces")?
        .as_array()?
        .iter()
        .map(Value::as_str)
        .collect::<Option<Vec<_>>>()?;
    if !requested.iter().all(|surface| matches!(*surface, "list" | "chat"))
        || !v2.allows_surfaces(&requested)
    {
        return None;
    }
    Some((
        id,
        ["list", "chat"]
            .into_iter()
            .filter(|surface| requested.contains(surface))
            .map(str::to_owned)
            .collect(),
    ))
}

/// Hands each line `rd` reads to `in_tx`, holding at most `limits.line` bytes of one (and the
/// `\r` of a `\r\n`, which is not part of it); a line past `limits.small` only once `in_tx` is
/// empty. A longer line ends the connection, as a WebSocket message over its limit does: its
/// request id is in the part not kept, so no reply could name it, and a client waiting on it sees
/// the connection end instead. Why goes to [`write_lines`] on `last`, as the connection's last
/// line.
async fn read_lines<R: AsyncRead + Unpin>(
    rd: R,
    in_tx: mpsc::Sender<String>,
    last: oneshot::Sender<String>,
    limits: Limits,
    v2: Option<&acpmux_core::life::V2>,
) -> Option<Upgrade<R>> {
    let max = limits.line;
    // The codec counts a line's `\r` with it and strips it after, so it holds one byte more.
    let mut lines = FramedRead::new(rd, LinesCodec::new_with_max_length(max.saturating_add(1)));
    let mut first = true;
    while let Some(line) = lines.next().await {
        // An HTTP request (a WebSocket upgrade, perhaps with the Cloud carrier's header) is for
        // the carrier socket, never this one (`carrier.rs`): no header here names anyone.
        let is_first = std::mem::take(&mut first);
        if is_first
            && let Ok(line) = &line
            && http_request_line(line)
        {
            tracing::warn!("closing a socket connection that sent an HTTP request");
            let error = RpcError::new(
                -32600,
                "this is acpmux's JSON-RPC socket; HTTP and WebSocket upgrades are refused here",
            )
            .with_data(json!({"reason": super::carrier::WRONG_SOCKET}));
            let _ = last.send(Message::err(Value::Null, error).to_line());
            break;
        }
        let line = match line {
            Ok(line) if line.len() <= max => line,
            Ok(_) | Err(LinesCodecError::MaxLineLengthExceeded) => {
                tracing::warn!(
                    limit = max,
                    "closing a socket connection that sent a line over the limit"
                );
                let error = RpcError::new(
                    -32600,
                    format!("message too large: a line over {max} bytes; closing the connection"),
                )
                .with_data(json!({"reason": "message.too_large", "limit": max}));
                let _ = last.send(Message::err(Value::Null, error).to_line());
                break;
            }
            // Not UTF-8, or the socket failed.
            Err(LinesCodecError::Io(_)) => break,
        };
        // Only the first request of a fresh local socket can upgrade. Trigger
        // admission is itself a v1 request, so an admitted trigger cannot reach
        // this branch; later upgrades use the normal v1 method-not-found path.
        if is_first && let Some((id, surfaces)) = v2.and_then(|v2| v2_upgrade(&line, v2)) {
            let parts = lines.into_parts();
            return Some(Upgrade {
                reader: std::io::Cursor::new(parts.read_buf.to_vec()).chain(parts.io),
                id,
                surfaces,
            });
        }
        let sent = if line.len() > limits.small {
            // All the queue's room: every line before it was taken.
            match in_tx.reserve_many(in_tx.max_capacity()).await {
                Ok(mut room) => room.next().map(|permit| permit.send(line)).is_some(),
                Err(_) => false,
            }
        } else {
            in_tx.send(line).await.is_ok()
        };
        if !sent {
            break;
        }
    }
    None
}

/// Whether `line` is an HTTP request line (`GET /path HTTP/1.1`), which no JSON-RPC line is.
fn http_request_line(line: &str) -> bool {
    let line = line.trim_end_matches('\r');
    let mut parts = line.split(' ');
    matches!(
        (parts.next(), parts.next(), parts.next(), parts.next()),
        (Some(m), Some(_), Some(v), None)
            if m.bytes().all(|b| b.is_ascii_uppercase()) && !m.is_empty() && v.starts_with("HTTP/")
    )
}

/// Writes each line `out_rx` gives to `wr` until the queue closes, or until a `last` line comes:
/// it goes out after the line being written and in place of the rest (within [`LAST_LINE_WAIT`],
/// so a client that reads nothing cannot hold it), and `wr` is dropped, which closes the write half. The client then
/// reads the end of the connection even while request handlers still hold the queue's sender. A
/// reader that ends without one (the client closed its side) leaves the replies still owed to go
/// out.
async fn write_lines<W: AsyncWrite + Unpin>(
    mut wr: W,
    mut out_rx: mpsc::Receiver<String>,
    last: oneshot::Receiver<String>,
) -> W {
    let last = async move {
        match last.await {
            Ok(line) => line,
            Err(_) => std::future::pending().await,
        }
    };
    tokio::pin!(last);
    'lines: while let Some(next) = tokio::select! {
        biased;
        line = &mut last => {
            let _ = tokio::time::timeout(LAST_LINE_WAIT, wr.write_all(line.as_bytes())).await;
            None
        }
        next = out_rx.recv() => next,
    } {
        // `write` takes nothing when it is cancelled, so a line half written is finished before
        // the last one goes.
        let mut rest = next.as_bytes();
        while !rest.is_empty() {
            tokio::select! {
                biased;
                line = &mut last => {
                    let _ = tokio::time::timeout(LAST_LINE_WAIT, async {
                        wr.write_all(rest).await?;
                        wr.write_all(line.as_bytes()).await
                    })
                    .await;
                    break 'lines;
                }
                wrote = wr.write(rest) => match wrote {
                    Ok(0) | Err(_) => break 'lines,
                    Ok(n) => rest = &rest[n..],
                },
            }
        }
    }
    wr
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
