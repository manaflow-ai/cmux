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
        let mut available = self.available.lock().await;
        *available = available.saturating_add(u64::from(bytes));
        drop(available);
        self.granted.notify_waiters();
        self.granted.notify_one();
    }

    /// Take up to `want` bytes of credit without waiting.
    pub async fn try_take(&self, want: usize) -> usize {
        let mut available = self.available.lock().await;
        let want = u64::try_from(want).unwrap_or(u64::MAX);
        let take = (*available).min(want);
        *available = available.saturating_sub(take);
        // `take` is at most `want`, which came from a usize.
        usize::try_from(take).unwrap_or(usize::MAX)
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
        let Some(outstanding) =
            u64::try_from(bytes).ok().and_then(|bytes| self.outstanding.checked_sub(bytes))
        else {
            return Err(CreditViolation);
        };
        self.outstanding = outstanding;
        Ok(())
    }

    /// The application consumed `bytes`. Returns a grant to send once at
    /// least half the window was consumed, so grants stay infrequent.
    pub fn consumed(&mut self, bytes: usize) -> Option<u32> {
        self.consumed = self.consumed.saturating_add(u64::try_from(bytes).unwrap_or(u64::MAX));
        if self.consumed.saturating_mul(2) < u64::from(self.window) {
            return None;
        }
        let grant = u32::try_from(self.consumed).unwrap_or(u32::MAX);
        self.consumed = self.consumed.saturating_sub(u64::from(grant));
        self.outstanding = self.outstanding.saturating_add(u64::from(grant));
        Some(grant)
    }
}
