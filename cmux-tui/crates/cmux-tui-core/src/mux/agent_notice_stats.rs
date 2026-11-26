//! Whether people act on agent notices (`list-notifications` with `stats: true`).
//!
//! The daemon posts a notice when an agent's turn finishes, fails or waits for
//! the person (`agent_chat_notices.rs`, and the terminal agent hooks). A view
//! of the chat, an answer, a click or a tab ack reads it. This counts, per
//! kind, how many notices were read within 60 s, within 10 min, later or never,
//! and the time to read at p50 and p95: how often a notice is acted on, not how
//! fast a banner showed (pursuit research:notifications:2026-11-24, after
//! alarm-management practice that reviews act rates per alarm type).
//!
//! Nothing new is stored. A notice's post time is its ledger row's
//! `created_at_ms`, and its read time is the first durable read the store
//! already records: the console ack (`notification_acks.acked_at_ms`) or a
//! client's read (`resource_notification_reads.read_at_ms`). So the numbers
//! survive a daemon restart, and their window is the retained ledger (the
//! newest [`LEDGER_WINDOW`] notifications of any source): constant cost, no
//! counter that grows. A cleared or evicted notice leaves the window.

use std::collections::HashMap;
use std::sync::PoisonError;

use serde_json::{Value, json};

use super::{Mux, NotificationLevel, NotificationSource, ResourceNotification, now_ms};

/// The ledger keeps at most this many notifications (`notifications.rs`).
const LEDGER_WINDOW: usize = 256;
/// Read within this long: acted on at once.
const SOON_MS: u64 = 60_000;
/// Read within this long: acted on. Unread past it: never acted on.
const LATE_MS: u64 = 600_000;

/// What an agent notice was about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum NoticeKind {
    Finished,
    Failed,
    NeedsInput,
    Other,
}

impl NoticeKind {
    const ALL: [NoticeKind; 4] = [Self::Finished, Self::Failed, Self::NeedsInput, Self::Other];

    fn as_str(self) -> &'static str {
        match self {
            Self::Finished => "finished",
            Self::Failed => "failed",
            Self::NeedsInput => "needs_input",
            Self::Other => "other",
        }
    }

    /// An agent notice's kind from what it shows; `None` for any other source.
    /// The titles are `agent_chat_notices.rs`'s: "<chat> finished", "<chat>
    /// needs input", and level error for a failed turn, a folded failure ("3
    /// chats hit the usage limit") and "<chat> stopped responding".
    pub(super) fn of(row: &ResourceNotification) -> Option<Self> {
        if row.source != NotificationSource::Agent {
            return None;
        }
        Some(if row.level == NotificationLevel::Error {
            Self::Failed
        } else if row.title.ends_with(" needs input") {
            Self::NeedsInput
        } else if row.title.ends_with(" finished") {
            Self::Finished
        } else {
            Self::Other
        })
    }
}

/// One agent notice: its kind, when it was posted, and when it was first read.
#[derive(Clone, Copy, Debug)]
pub(super) struct NoticeRead {
    pub kind: NoticeKind,
    pub posted_ms: u64,
    pub read_ms: Option<u64>,
}

/// The stats of `notices` at `now_ms`, as `list-notifications` returns them.
pub(super) fn notice_stats(notices: &[NoticeRead], now_ms: u64) -> Value {
    let mut kinds = serde_json::Map::new();
    let mut total = Bucket::default();
    for kind in NoticeKind::ALL {
        let mut bucket = Bucket::default();
        for notice in notices.iter().filter(|notice| notice.kind == kind) {
            bucket.add(notice, now_ms);
            total.add(notice, now_ms);
        }
        kinds.insert(kind.as_str().to_owned(), bucket.json());
    }
    json!({
        "now_ms": now_ms,
        "window": {
            "notifications": LEDGER_WINDOW,
            "since_ms": notices.iter().map(|notice| notice.posted_ms).min(),
        },
        "within_ms": {"soon": SOON_MS, "late": LATE_MS},
        "kinds": kinds,
        "all": total.json(),
    })
}

#[derive(Default)]
struct Bucket {
    posted: u64,
    read_within_60s: u64,
    read_within_10m: u64,
    read_later: u64,
    /// Unread, posted less than 10 min ago: it may still be read in time.
    unread_recent: u64,
    /// Unread, posted 10 min ago or more.
    never_read: u64,
    /// Time to read of each read notice (at most the ledger's size).
    read_after_ms: Vec<u64>,
}

impl Bucket {
    fn add(&mut self, notice: &NoticeRead, now_ms: u64) {
        self.posted += 1;
        match notice.read_ms {
            Some(read_ms) => {
                let after = read_ms.saturating_sub(notice.posted_ms);
                self.read_after_ms.push(after);
                if after <= SOON_MS {
                    self.read_within_60s += 1;
                } else if after <= LATE_MS {
                    self.read_within_10m += 1;
                } else {
                    self.read_later += 1;
                }
            }
            None if now_ms.saturating_sub(notice.posted_ms) < LATE_MS => self.unread_recent += 1,
            None => self.never_read += 1,
        }
    }

    fn json(mut self) -> Value {
        self.read_after_ms.sort_unstable();
        // Acted on: read within 10 min, of the notices old enough to say (not unread_recent).
        let settled = self.posted - self.unread_recent;
        let acted = self.read_within_60s + self.read_within_10m;
        json!({
            "posted": self.posted,
            "read_within_60s": self.read_within_60s,
            "read_within_10m": self.read_within_10m,
            "read_later": self.read_later,
            "never_read": self.never_read,
            "unread_recent": self.unread_recent,
            "acted_rate": (settled > 0).then(|| acted as f64 / settled as f64),
            "read_ms_p50": percentile(&self.read_after_ms, 50),
            "read_ms_p95": percentile(&self.read_after_ms, 95),
        })
    }
}

/// The nearest-rank `pct`th percentile of `sorted`; `None` when empty.
fn percentile(sorted: &[u64], pct: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (pct * sorted.len()).div_ceil(100).max(1);
    sorted.get(rank - 1).copied()
}

impl Mux {
    /// [`notice_stats`] of the retained agent notices, read from the ledger
    /// and the durable read marks.
    pub(crate) fn agent_notice_stats(&self) -> anyhow::Result<Value> {
        let reads: HashMap<String, u64> = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .notification_first_reads()?;
        let notices = self
            .notification_ledger
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter_map(|row| {
                Some(NoticeRead {
                    kind: NoticeKind::of(row)?,
                    posted_ms: row.created_at_ms,
                    read_ms: reads.get(row.id.as_str()).copied(),
                })
            })
            .collect::<Vec<_>>();
        Ok(notice_stats(&notices, now_ms()))
    }
}

#[cfg(test)]
#[path = "agent_notice_stats_tests.rs"]
mod tests;
