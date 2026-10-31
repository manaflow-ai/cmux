//! One daemon socket connection (Unix and Windows): newline-delimited
//! JSON-RPC both ways over a `local_stream::Stream`.

use super::{ConnAuth, Hub, Origin, serve_connection_from};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

/// The longest line a socket client may send.
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

/// Hands each line `rd` reads to `in_tx`.
async fn read_lines<R: AsyncRead + Unpin>(
    rd: R,
    in_tx: mpsc::Sender<String>,
    _out_tx: mpsc::WeakSender<String>,
    _max: usize,
) {
    let mut lines = BufReader::new(rd).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if in_tx.send(line).await.is_err() {
            break;
        }
    }
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
