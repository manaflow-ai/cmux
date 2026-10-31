//! One daemon socket connection (Unix and Windows): newline-delimited
//! JSON-RPC both ways over a `local_stream::Stream`.

use super::{ConnAuth, Hub, Origin, serve_connection_from};
use crate::rpc::{Message, RpcError};
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio_util::codec::{FramedRead, LinesCodec, LinesCodecError};

/// The longest line a socket client may send: what one WebSocket message may carry
/// (`WS_MAX_MESSAGE_BYTES`), so a request either transport takes, the other takes too.
/// Unbounded, one line with no newline grew the reader's buffer until the daemon ran out of
/// memory (manaflow-ai/cmuxterm-hq#2888).
const MAX_LINE_BYTES: usize = super::WS_MAX_MESSAGE_BYTES;

/// One daemon socket connection: newline-delimited JSON-RPC both ways.
pub(super) async fn serve_stream(
    hub: Arc<Hub>,
    stream: crate::local_stream::Stream,
    peer: Option<cmux_link::app_caller::PeerToken>,
) {
    let (rd, mut wr) = crate::local_stream::split(stream);
    let (in_tx, in_rx) = mpsc::channel::<String>(256);
    let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
    tokio::spawn(read_lines(rd, in_tx, out_tx.downgrade(), MAX_LINE_BYTES));
    tokio::spawn(async move {
        while let Some(line) = out_rx.recv().await {
            if wr.write_all(line.as_bytes()).await.is_err() {
                break;
            }
        }
    });
    serve_connection_from(hub, in_rx, out_tx, Origin::Local, ConnAuth::LocalSocket, peer, None)
        .await;
}

/// Hands each line `rd` reads to `in_tx`, holding at most `max` bytes of one (and the `\r` of a
/// `\r\n`, which is not part of it). A longer line ends the connection, as a WebSocket message
/// over its limit does: its request id is in the part not kept, so no reply could name it, and a
/// client waiting on it sees the connection end instead. The client is told why on `out_tx` when
/// there is room; a client too far behind to take it only sees the end. `out_tx` is weak, so the
/// reader never keeps the writer open after the connection's server is done with it.
async fn read_lines<R: AsyncRead + Unpin>(
    rd: R,
    in_tx: mpsc::Sender<String>,
    out_tx: mpsc::WeakSender<String>,
    max: usize,
) {
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
                // Never waits: a full queue must not keep the connection open.
                if let Some(out) = out_tx.upgrade() {
                    let _ = out.try_send(Message::err(Value::Null, error).to_line());
                }
                break;
            }
            // Not UTF-8, or the socket failed.
            Err(LinesCodecError::Io(_)) => break,
        };
        if in_tx.send(line).await.is_err() {
            break;
        }
    }
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
