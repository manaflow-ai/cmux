//! Bulk byte channels with a credit window (transport.md 12a and 12c
//! item 3).
//!
//! A sender may have at most `window` bytes that the receiver has not
//! acknowledged. A full window makes `send` wait, so a 4 GB copy never
//! queues more than one window in memory and never drops. `close` from
//! either end stops the channel at once: queued chunks are discarded and
//! the next `send` or `recv` reports the close. This is the in-process shape
//! of the link's bulk channel and its `channel.close`; the overlay carries
//! the same credits between machines.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use bytes::Bytes;
use tokio::sync::{Notify, Semaphore, mpsc};

/// Default credit window for file transfers (transport.md 12c item 3).
pub const DEFAULT_WINDOW_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Closed;

impl std::fmt::Display for Closed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("bulk channel is closed")
    }
}

impl std::error::Error for Closed {}

struct Shared {
    credit: Semaphore,
    window: usize,
    closed: AtomicBool,
    close_notify: Notify,
}

impl Shared {
    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.credit.close();
        self.close_notify.notify_waiters();
    }
}

/// Opens a channel with a credit window of `window` bytes.
#[must_use]
pub fn channel(window: usize) -> (BulkSender, BulkReceiver) {
    let window = window.clamp(1, Semaphore::MAX_PERMITS);
    let shared = Arc::new(Shared {
        credit: Semaphore::new(window),
        window,
        closed: AtomicBool::new(false),
        close_notify: Notify::new(),
    });
    let (sender, receiver) = mpsc::unbounded_channel();
    (
        BulkSender { shared: Arc::clone(&shared), chunks: sender },
        BulkReceiver { shared, chunks: receiver },
    )
}

pub struct BulkSender {
    shared: Arc<Shared>,
    chunks: mpsc::UnboundedSender<Bytes>,
}

impl BulkSender {
    /// Queues `chunk` once the window has room for it. A chunk larger than
    /// the window waits for the whole window.
    pub async fn send(&self, chunk: Bytes) -> Result<(), Closed> {
        if chunk.is_empty() {
            return Ok(());
        }
        let cost = u32::try_from(chunk.len().min(self.shared.window)).unwrap_or(u32::MAX);
        let permit = self.shared.credit.acquire_many(cost).await.map_err(|_| Closed)?;
        if self.shared.closed.load(Ordering::SeqCst) {
            return Err(Closed);
        }
        // The receiver returns the credit when it acknowledges the chunk.
        permit.forget();
        self.chunks.send(chunk).map_err(|_| Closed)
    }

    /// Stops the channel now; queued chunks are discarded.
    pub fn close(&self) {
        self.shared.close();
    }

    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.shared.closed.load(Ordering::SeqCst)
    }
}

pub struct BulkReceiver {
    shared: Arc<Shared>,
    chunks: mpsc::UnboundedReceiver<Bytes>,
}

impl BulkReceiver {
    /// The next chunk, or `None` when the sender finished. A closed channel
    /// returns `Err` even when chunks were still queued.
    pub async fn recv(&mut self) -> Result<Option<Bytes>, Closed> {
        // Register for the close wakeup before checking the flag, so a close
        // between the check and the wait is never missed.
        let notified = self.shared.close_notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if self.shared.closed.load(Ordering::SeqCst) {
            return Err(Closed);
        }
        tokio::select! {
            biased;
            () = notified => Err(Closed),
            chunk = self.chunks.recv() => {
                if self.shared.closed.load(Ordering::SeqCst) {
                    return Err(Closed);
                }
                Ok(chunk)
            }
        }
    }

    /// Returns credit for a chunk the receiver has written out.
    pub fn ack(&self, chunk_len: usize) {
        if !self.shared.closed.load(Ordering::SeqCst) {
            self.shared.credit.add_permits(chunk_len.min(self.shared.window));
        }
    }

    /// Stops the channel now; queued chunks are discarded.
    pub fn close(&mut self) {
        self.shared.close();
        self.chunks.close();
        while self.chunks.try_recv().is_ok() {}
    }
}

impl Drop for BulkReceiver {
    fn drop(&mut self) {
        self.shared.close();
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[tokio::test]
    async fn a_full_window_waits_for_acknowledgement() {
        let (sender, mut receiver) = channel(8);
        sender.send(Bytes::from_static(b"12345678")).await.unwrap();
        let blocked =
            tokio::time::timeout(Duration::from_millis(50), sender.send(Bytes::from_static(b"9")))
                .await;
        assert!(blocked.is_err(), "the ninth byte waits for credit");
        let chunk = receiver.recv().await.unwrap().unwrap();
        receiver.ack(chunk.len());
        sender.send(Bytes::from_static(b"9")).await.unwrap();
        assert_eq!(receiver.recv().await.unwrap().unwrap(), Bytes::from_static(b"9"));
        drop(sender);
        assert_eq!(receiver.recv().await.unwrap(), None);
    }

    #[tokio::test]
    async fn close_stops_both_ends_and_discards_queued_chunks() {
        let (sender, mut receiver) = channel(1024);
        sender.send(Bytes::from_static(b"queued")).await.unwrap();
        sender.close();
        assert_eq!(receiver.recv().await, Err(Closed), "queued bytes are discarded");
        assert_eq!(sender.send(Bytes::from_static(b"x")).await, Err(Closed));

        let (sender, mut receiver) = channel(4);
        sender.send(Bytes::from_static(b"full")).await.unwrap();
        let waiting = tokio::spawn(async move { sender.send(Bytes::from_static(b"more")).await });
        tokio::task::yield_now().await;
        receiver.close();
        assert_eq!(waiting.await.unwrap(), Err(Closed), "a waiting sender wakes up closed");
    }
}
