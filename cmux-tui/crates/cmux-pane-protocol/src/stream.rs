//! Credit-based flow control for byte streams.
//!
//! A sender may only send as many payload bytes on a stream as the receiver
//! granted. The receiver grants credit with a `credit` envelope or in the
//! credit field of any data frame it sends on the same stream. A stream with
//! no credit stops; calls and other streams keep flowing, so one large
//! stream cannot starve them.
//!
//! [`SendCredit`] is the sender's window. [`RecvWindow`] is the receiver's:
//! it decides when to grant more as the application consumes bytes.

use std::sync::Arc;

use tokio::sync::{Mutex, Notify};

/// The default receive window.
pub const DEFAULT_WINDOW: u32 = 256 * 1024;

/// The sender's credit on one stream.
#[derive(Debug, Default)]
pub struct SendCredit {
    available: Mutex<u64>,
    granted: Notify,
}

impl SendCredit {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Add `bytes` of credit (from a `credit` envelope or a data frame).
    pub async fn grant(&self, bytes: u32) {
        if bytes == 0 {
            return;
        }
        *self.available.lock().await += u64::from(bytes);
        self.granted.notify_waiters();
        self.granted.notify_one();
    }

    /// Take up to `want` bytes of credit without waiting.
    pub async fn try_take(&self, want: usize) -> usize {
        let mut available = self.available.lock().await;
        let take = (*available).min(want as u64);
        *available -= take;
        take as usize
    }

    /// Wait until some credit exists, then take up to `want` bytes of it.
    /// Returns a nonzero count unless `want` is 0.
    pub async fn take(&self, want: usize) -> usize {
        if want == 0 {
            return 0;
        }
        loop {
            let notified = self.granted.notified();
            let taken = self.try_take(want).await;
            if taken > 0 {
                return taken;
            }
            notified.await;
        }
    }

    pub async fn available(&self) -> u64 {
        *self.available.lock().await
    }
}

/// The receiver's window on one stream.
#[derive(Debug, Clone)]
pub struct RecvWindow {
    window: u32,
    /// Bytes granted and not yet received.
    outstanding: u64,
    /// Bytes received and consumed since the last grant.
    consumed: u64,
}

/// The peer sent more than it was granted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CreditViolation;

impl RecvWindow {
    pub fn new(window: u32) -> Self {
        Self { window, outstanding: 0, consumed: 0 }
    }

    /// The first grant, sent right after `open`.
    pub fn initial_grant(&mut self) -> u32 {
        self.outstanding = u64::from(self.window);
        self.window
    }

    /// Account for `bytes` received; an error when the peer exceeded credit.
    pub fn received(&mut self, bytes: usize) -> Result<(), CreditViolation> {
        let bytes = bytes as u64;
        if bytes > self.outstanding {
            return Err(CreditViolation);
        }
        self.outstanding -= bytes;
        Ok(())
    }

    /// The application consumed `bytes`. Returns a grant to send once at
    /// least half the window was consumed, so grants stay infrequent.
    pub fn consumed(&mut self, bytes: usize) -> Option<u32> {
        self.consumed += bytes as u64;
        if self.consumed * 2 < u64::from(self.window) {
            return None;
        }
        let grant = self.consumed.min(u64::from(u32::MAX)) as u32;
        self.consumed -= u64::from(grant);
        self.outstanding += u64::from(grant);
        Some(grant)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn sender_waits_for_credit() {
        let credit = SendCredit::new();
        assert_eq!(credit.try_take(10).await, 0);
        let waiter = {
            let credit = credit.clone();
            tokio::spawn(async move { credit.take(100).await })
        };
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!waiter.is_finished());
        credit.grant(40).await;
        assert_eq!(waiter.await.unwrap(), 40);
        assert_eq!(credit.available().await, 0);
    }

    #[test]
    fn receiver_refuses_overrun_and_regrants_at_half_window() {
        let mut window = RecvWindow::new(100);
        assert_eq!(window.initial_grant(), 100);
        window.received(60).unwrap();
        assert_eq!(window.consumed(30), None);
        assert_eq!(window.consumed(20), Some(50));
        window.received(90).unwrap();
        assert_eq!(window.received(1), Err(CreditViolation));
    }
}
