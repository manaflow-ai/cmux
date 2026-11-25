//! The Reports basket (Swift `FeedReport`, `FeedModel.replaceReports`,
//! `AcpmuxMailboxClient` and `AcpmuxMailboxReader.cursor`): durable reports
//! read from the acpmux mailbox alias `reports:<user>`. Reports are a
//! projection apart from the feed: they never enter feed triage or wake a
//! session. Only the newest [`REPORTS_LIMIT`] stay.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

/// The most reports the basket shows (and the daemon keeps): the newest.
pub const REPORTS_LIMIT: usize = 200;

/// One report.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Report {
    pub id: String,
    /// The daemon-qualified acpmux session that sent it (a reply's address).
    pub sender: String,
    pub body: String,
    pub created_at: i64,
}

/// One `_acpmux/mail/wait` answer: its rows and the cursor after them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MailPage {
    pub messages: Vec<(u64, Report)>,
    pub next_cursor: Option<u64>,
}

impl MailPage {
    /// The page of acpmux's answer; rows that do not decode are skipped.
    pub fn from_value(result: &Value) -> Self {
        let messages = result
            .get("messages")
            .and_then(Value::as_array)
            .map(|rows| rows.iter().filter_map(|row| message(row.get("message")?)).collect())
            .unwrap_or_default();
        Self { messages, next_cursor: result.get("nextCursor").and_then(Value::as_u64) }
    }

    /// The cursor after this page: its next cursor, else its last row,
    /// never back.
    pub fn cursor_after(&self, cursor: u64) -> u64 {
        match (self.next_cursor, self.messages.last()) {
            (Some(next), _) => cursor.max(next),
            (None, Some((seq, _))) => cursor.max(*seq),
            (None, None) => cursor,
        }
    }
}

fn message(row: &Value) -> Option<(u64, Report)> {
    let text = |key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    let created = row.get("createdAt")?;
    let created_at =
        created.as_i64().or_else(|| created.as_f64().and_then(super::item::whole_ms))?;
    Some((
        row.get("seq")?.as_u64()?,
        Report { id: text("id")?, sender: text("sender")?, body: text("body")?, created_at },
    ))
}

/// The basket.
#[derive(Default)]
pub struct Reports {
    rows: HashMap<String, Report>,
    revision: u64,
}

impl Reports {
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Adds a page's rows, keeping the newest [`REPORTS_LIMIT`]; true when
    /// anything shown changed.
    pub fn apply(&mut self, page: &MailPage) -> bool {
        let before = self.list();
        for (_, report) in &page.messages {
            self.rows.insert(report.id.clone(), report.clone());
        }
        let kept = self.list();
        self.rows = kept.iter().map(|report| (report.id.clone(), report.clone())).collect();
        let changed = kept != before;
        if changed {
            self.revision = self.revision.saturating_add(1);
        }
        changed
    }

    /// Empties the basket (sign-out, another account); true when it had rows.
    pub fn clear(&mut self) -> bool {
        if self.rows.is_empty() {
            return false;
        }
        self.rows.clear();
        self.revision = self.revision.saturating_add(1);
        true
    }

    /// Newest first (ids break ties, larger first), at most [`REPORTS_LIMIT`].
    pub fn list(&self) -> Vec<Report> {
        let mut rows: Vec<Report> = self.rows.values().cloned().collect();
        rows.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| b.id.cmp(&a.id)));
        rows.truncate(REPORTS_LIMIT);
        rows
    }
}
