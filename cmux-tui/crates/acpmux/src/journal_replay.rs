//! Read a session journal in bounded pages and prepare a replay plan.
//!
//! The durable event log is the source of truth for a replay. Consumers provide the page
//! operation, so this adapter works with the local store and with the cursor-paged
//! `_acpmux/events` route. Every request is capped at [`PAGE_SIZE`], repeated boundary records are
//! removed by sequence number, and the reducer runs once for each unique record. The resulting
//! [`ReplayPlan`] stores timestamped states, allowing a frame renderer to seek by replay time
//! without reading or reducing the journal again.

use anyhow::Result;
use std::collections::BTreeMap;

use crate::store::EventRecord;

/// The maximum number of records requested from one journal page.
pub const PAGE_SIZE: usize = 400;

/// A page returned by a cursor-based journal reader.
#[derive(Debug, Clone, PartialEq)]
pub struct JournalPage {
    /// Records after the requested cursor, oldest first. A server may repeat the cursor boundary
    /// when a retry races a page cache, so callers must not assume every record is new.
    pub events: Vec<EventRecord>,
    /// Whether another page remains after this one.
    pub has_more: bool,
    /// The server's cursor watermark for this page. It can advance past the last returned event
    /// when a filter omits records.
    pub page_through: u64,
}

/// Counts the source work independently of the encoder's frame rate.
#[derive(Debug, Default, serde::Serialize)]
pub struct Work {
    pub pages: usize,
    pub largest_page: usize,
    pub fetched: usize,
    pub duplicates: usize,
    pub reduced: usize,
    pub first_seq: Option<u64>,
    pub last_seq: Option<u64>,
}

/// Fold one bounded page at a time. Older records may overlap a previous page. An unseen
/// record behind an acknowledged watermark would invalidate states already emitted.
pub fn read<F, V>(mut fetch: F, mut visit: V) -> Result<Work>
where
    F: FnMut(u64, usize) -> Result<JournalPage>,
    V: FnMut(EventRecord),
{
    let mut cursor = 0;
    let mut seen = std::collections::HashSet::new();
    let mut work = Work::default();
    loop {
        let page = fetch(cursor, PAGE_SIZE)?;
        anyhow::ensure!(page.events.len() <= PAGE_SIZE, "oversize journal page");
        work.pages += 1;
        work.fetched += page.events.len();
        work.largest_page = work.largest_page.max(page.events.len());
        let mut next = cursor.max(page.page_through);
        let mut ordered = BTreeMap::new();
        for event in page.events {
            anyhow::ensure!(event.seq > 0, "zero journal sequence");
            next = next.max(event.seq);
            if !seen.insert(event.seq) {
                work.duplicates += 1;
                continue;
            }
            anyhow::ensure!(
                event.seq > cursor,
                "unseen record {} behind cursor {cursor}",
                event.seq
            );
            ordered.insert(event.seq, event);
        }
        for (seq, event) in ordered {
            work.first_seq.get_or_insert(seq);
            work.last_seq = Some(seq);
            work.reduced += 1;
            visit(event);
        }
        if !page.has_more {
            return Ok(work);
        }
        anyhow::ensure!(next > cursor, "journal replay cursor did not advance past {cursor}");
        cursor = next;
    }
}

/// Only text that fits the preview is kept. The event journal still holds each full payload.
#[derive(Clone, Default, PartialEq, serde::Serialize)]
pub struct Screen {
    pub status: String,
    pub prompt: String,
    pub reply: String,
    pub tool: String,
}

fn visible(text: &str) -> String {
    const COLUMNS: usize = 640;
    let tail_reversed: String = text.chars().rev().take(COLUMNS).collect();
    let tail: String = tail_reversed.chars().rev().collect();
    if text.chars().nth(COLUMNS).is_some() { format!("…{tail}") } else { tail }
}

impl Screen {
    fn apply(&mut self, event: &EventRecord) {
        let msg = &event.msg;
        let update = msg.pointer("/params/update");
        match (event.dir.as_str(), event.kind.as_str()) {
            ("mux", "status") => {
                if let Some(status) = msg["status"].as_str() {
                    self.status = visible(status);
                }
            }
            ("mux", "user_message") => {
                if let Some(prompt) = msg["text"].as_str() {
                    self.prompt = visible(prompt);
                    self.reply.clear();
                    self.tool.clear();
                }
            }
            ("mux", "turn_result") => {
                self.status = visible(msg["status"].as_str().unwrap_or("completed"))
            }
            ("in", _) => {
                let Some(update) = update else { return };
                match update["sessionUpdate"].as_str() {
                    Some("agent_message_chunk") => {
                        if let Some(text) = update.pointer("/content/text").and_then(|v| v.as_str())
                        {
                            self.reply = visible(&format!("{}{}", self.reply, visible(text)));
                        }
                    }
                    Some("tool_call" | "tool_call_update") => {
                        if let Some(label) =
                            update["title"].as_str().or(update["toolCallId"].as_str())
                        {
                            self.tool = visible(label);
                            if let Some(status) = update["status"].as_str() {
                                self.tool = visible(&format!("{} ({status})", self.tool));
                            }
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

#[derive(serde::Serialize)]
pub struct Transition {
    pub time: u64,
    pub seq: u64,
    pub state: Screen,
}

#[derive(Default, serde::Serialize)]
pub struct ReplayPlan {
    pub duration: u64,
    pub transitions: Vec<Transition>,
    #[serde(skip)]
    previous_at: Option<u64>,
    #[serde(skip)]
    screen: Screen,
}

impl ReplayPlan {
    /// Apply a record once. Repeated or invisible states need no new frame.
    pub fn apply(&mut self, event: EventRecord) {
        if let Some(previous) = self.previous_at.replace(event.at) {
            self.duration =
                self.duration.saturating_add(event.at.saturating_sub(previous).min(2_000));
        }
        self.screen.apply(&event);
        if self.transitions.last().is_none_or(|s| s.state != self.screen) {
            self.transitions.push(Transition {
                time: self.duration,
                seq: event.seq,
                state: self.screen.clone(),
            });
        }
    }
}

#[cfg(test)]
#[path = "journal_replay_tests.rs"]
mod tests;
