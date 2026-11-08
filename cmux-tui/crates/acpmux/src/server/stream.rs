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
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
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
) {
    let (rd, wr) = crate::local_stream::split(stream);
    let (in_tx, in_rx) = mpsc::channel::<String>(INBOUND_LINES);
    let (out_tx, out_rx) = mpsc::channel::<String>(4096);
    let (last_tx, last_rx) = oneshot::channel();
    let limits = Limits { line: MAX_LINE_BYTES, small: SMALL_LINE_BYTES };
    tokio::spawn(read_lines(rd, in_tx, last_tx, limits));
    tokio::spawn(write_lines(wr, out_rx, last_rx));
    serve_connection_from(
        hub,
        in_rx,
        out_tx,
        Origin::Local,
        ConnAuth::LocalSocket,
        peer,
        None,
        None,
    )
    .await;
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
) {
    let max = limits.line;
    // The codec counts a line's `\r` with it and strips it after, so it holds one byte more.
    let mut lines = FramedRead::new(rd, LinesCodec::new_with_max_length(max.saturating_add(1)));
    while let Some(line) = lines.next().await {
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
) {
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
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
