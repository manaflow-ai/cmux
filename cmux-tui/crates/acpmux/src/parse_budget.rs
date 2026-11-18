//! How many whole session lists the daemon turns into `serde_json::Value` at once (rework stage
//! 3; the heap attribution of Leo's daemon, 2026-11-12). Its memory swung between 1.2 and 2.4 GB,
//! 3.1 GB on another pid, and one Mac reached 11 GB: not from anything it kept, but from whole
//! lists parsed at the same time, each about 6 times its text (270 MB for a 42 MB list of 10,848
//! peer rows), one per list reply being built (`list_reply.rs`: masking a list for a peer). About
//! ten in flight was 2.7 GB. A peer link no longer makes a whole list from a delta: it follows
//! from its cursor (`hub/row_log.rs`).
//!
//! Each of those takes one of [`PARSES`] permits for its parse, so at most that many whole-list
//! parses are live, however many connections and links ask at once. The rest wait their turn:
//! a reply is later, never larger. The permit is taken by the async caller before any lock, and
//! never two at once, so it cannot deadlock.

use tokio::sync::{Semaphore, SemaphorePermit};

/// Whole-list parses live at once.
pub const PARSES: usize = 2;

static BUDGET: Semaphore = Semaphore::const_new(PARSES);

/// A turn to parse a whole list; held while the parse and what it made are alive.
pub async fn permit() -> SemaphorePermit<'static> {
    match BUDGET.acquire().await {
        Ok(permit) => permit,
        // Never closed: this cannot happen, and waiting is no worse than parsing.
        Err(_) => std::future::pending().await,
    }
}

/// Parses live now (tests).
#[cfg(test)]
pub fn in_use() -> usize {
    PARSES - BUDGET.available_permits()
}
