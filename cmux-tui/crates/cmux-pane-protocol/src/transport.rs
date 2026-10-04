//! One transport interface for every adapter (spec "Transports"): a sender
//! and a receiver of [`Message`]s. Typed calls, subscriptions and streams
//! ([`crate::rpc`]) sit on top and never see the adapter.
//!
//! Adapters here: length-prefixed byte streams ([`framed`], used for unix
//! sockets and socketpairs), WebSocket ([`crate::ws`]), and an in-memory
//! pair for tests ([`memory_pair`]).

use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufWriter};
use tokio::sync::mpsc;

use crate::frame::{self, Message};

/// Messages queued per direction before a sender waits.
pub const QUEUE: usize = 256;

/// A connected transport. Dropping `tx` closes the write side; `rx` yields
/// `None` once the peer closed or the connection failed.
pub struct Transport {
    pub tx: mpsc::Sender<Message>,
    pub rx: mpsc::Receiver<Message>,
}

impl Transport {
    pub async fn send(&self, message: Message) -> bool {
        self.tx.send(message).await.is_ok()
    }

    pub async fn recv(&mut self) -> Option<Message> {
        self.rx.recv().await
    }
}

/// Frame `reader`/`writer` with the 4-byte length prefix. A reader task and
/// a writer task run until either side closes. The writer drains every
/// queued message before one flush, so writes issued in the same tick
/// coalesce into one syscall instead of relying on Nagle.
pub fn framed<R, W>(mut reader: R, writer: W) -> Transport
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (out_tx, mut out_rx) = mpsc::channel::<Message>(QUEUE);
    let (in_tx, in_rx) = mpsc::channel::<Message>(QUEUE);
    tokio::spawn(async move {
        let mut writer = BufWriter::new(writer);
        'outer: while let Some(first) = out_rx.recv().await {
            let mut next = Some(first);
            while let Some(message) = next.take() {
                if matches!(message, Message::Close(..)) {
                    break 'outer;
                }
                if frame::write_message(&mut writer, &message).await.is_err() {
                    return;
                }
                next = out_rx.try_recv().ok();
            }
            if writer.flush().await.is_err() {
                return;
            }
        }
        let _ = writer.flush().await;
        let _ = writer.shutdown().await;
    });
    tokio::spawn(async move {
        while let Ok(Some(message)) = frame::read_message(&mut reader).await {
            if in_tx.send(message).await.is_err() {
                return;
            }
        }
    });
    Transport { tx: out_tx, rx: in_rx }
}

/// A connected in-memory pair.
pub fn memory_pair() -> (Transport, Transport) {
    let (a_tx, b_rx) = mpsc::channel(QUEUE);
    let (b_tx, a_rx) = mpsc::channel(QUEUE);
    (Transport { tx: a_tx, rx: a_rx }, Transport { tx: b_tx, rx: b_rx })
}

/// Frame a unix stream.
#[cfg(unix)]
pub fn unix(stream: tokio::net::UnixStream) -> Transport {
    let (reader, writer) = stream.into_split();
    framed(reader, writer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn framed_duplex_carries_text_and_binary() {
        let (left, right) = tokio::io::duplex(1024);
        let (left_read, left_write) = tokio::io::split(left);
        let (right_read, right_write) = tokio::io::split(right);
        let a = framed(left_read, left_write);
        let mut b = framed(right_read, right_write);
        assert!(a.send(Message::Text("{}".into())).await);
        assert!(a.send(Message::Binary(bytes::Bytes::from_static(b"xyz"))).await);
        assert_eq!(b.recv().await, Some(Message::Text("{}".into())));
        assert_eq!(b.recv().await, Some(Message::Binary(bytes::Bytes::from_static(b"xyz"))));
        drop(a);
        assert_eq!(b.recv().await, None);
    }
}
