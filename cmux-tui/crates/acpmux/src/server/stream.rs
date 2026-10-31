//! One daemon socket connection (Unix and Windows): newline-delimited
//! JSON-RPC both ways over a `local_stream::Stream`.

use super::{ConnAuth, Hub, Origin, serve_connection_from};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

/// One daemon socket connection: newline-delimited JSON-RPC both ways.
pub(super) async fn serve_stream(
    hub: Arc<Hub>,
    stream: crate::local_stream::Stream,
    peer: Option<cmux_link::app_caller::PeerToken>,
) {
    let (rd, mut wr) = crate::local_stream::split(stream);
    let (in_tx, in_rx) = mpsc::channel::<String>(256);
    let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
    tokio::spawn(async move {
        let mut lines = BufReader::new(rd).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if in_tx.send(line).await.is_err() {
                break;
            }
        }
    });
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
