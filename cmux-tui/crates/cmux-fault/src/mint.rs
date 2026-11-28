//! `ticket-expire` and `mint-down`: a ticket mint whose tickets live a short TTL, and which can
//! refuse (answers 503) or hang.
//!
//! The mint signs nothing itself: the scenario hands it the issuer (for the native relay,
//! `TicketAuthority::issue`), and the mint picks each ticket's times from its [`WallClock`].
//! A ticket's times are whole unix seconds, so a 1 s TTL minted at floor(now) could expire in a
//! millisecond; the mint issues at the next whole second instead (ceil), so every ticket is
//! valid for at least its TTL and at most a second more. At the platform's 300 s that second does
//! not matter; at 1 s it is the difference between testing renewal and testing rounding.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::sync::watch;

use crate::clock::WallClock;
use crate::trace::Trace;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MintMode {
    Up,
    /// Every request is refused at once, as a mint answering 503 is.
    Down,
    /// Every request waits until the mint is up or down again.
    Hang,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MintDown;

impl std::fmt::Display for MintDown {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the ticket mint answered 503")
    }
}

type Issue = dyn Fn(u64, u64) -> String + Send + Sync;

#[derive(Clone)]
pub struct Mint {
    ttl: Duration,
    clock: WallClock,
    issue: Arc<Issue>,
    mode: Arc<watch::Sender<MintMode>>,
    minted: Arc<AtomicU64>,
    refused: Arc<AtomicU64>,
    trace: Trace,
}

impl Mint {
    /// `issue(issued_at_unix, expires_at_unix)` signs one ticket.
    pub fn new(
        ttl: Duration,
        clock: WallClock,
        trace: &Trace,
        issue: impl Fn(u64, u64) -> String + Send + Sync + 'static,
    ) -> Self {
        assert!(ttl >= Duration::from_secs(1), "a ticket's TTL is whole seconds");
        Self {
            ttl,
            clock,
            issue: Arc::new(issue),
            mode: Arc::new(watch::channel(MintMode::Up).0),
            minted: Arc::default(),
            refused: Arc::default(),
            trace: trace.clone(),
        }
    }

    pub fn set(&self, mode: MintMode) {
        self.trace.note(match mode {
            MintMode::Up => "heal mint".to_owned(),
            MintMode::Down => "fault mint-down (503)".to_owned(),
            MintMode::Hang => "fault mint-down (hangs)".to_owned(),
        });
        self.mode.send_replace(mode);
    }

    pub fn mode(&self) -> MintMode {
        *self.mode.borrow()
    }

    /// Tickets minted so far.
    pub fn minted(&self) -> u64 {
        self.minted.load(Ordering::SeqCst)
    }

    /// Requests refused so far (a hang that ended in a refusal counts once).
    pub fn refused(&self) -> u64 {
        self.refused.load(Ordering::SeqCst)
    }

    pub async fn fetch(&self) -> Result<String, MintDown> {
        let mut mode = self.mode.subscribe();
        let now = *mode.wait_for(|mode| *mode != MintMode::Hang).await.map_err(|_| MintDown)?;
        if now == MintMode::Down {
            self.refused.fetch_add(1, Ordering::SeqCst);
            return Err(MintDown);
        }
        let issued = self.clock.unix_seconds_ceil();
        self.minted.fetch_add(1, Ordering::SeqCst);
        Ok((self.issue)(issued, issued + self.ttl.as_secs()))
    }
}

#[cfg(test)]
#[path = "mint_tests.rs"]
mod tests;
