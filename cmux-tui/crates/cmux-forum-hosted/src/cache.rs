//! The thread list the UI reads, kept current by feed events so only the feed is polled.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::client::StateFilter;
use crate::model::{EventKind, FeedEvent, Thread, ThreadState};

/// One thread's row in a list.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ThreadSummary {
    pub number: u64,
    pub space: String,
    pub title: String,
    pub state: ThreadState,
    /// Counted from events for a thread first seen in the feed, so it can trail the server's.
    pub comments: u64,
    pub created_at: String,
    pub updated_at: String,
    /// The newest comment's one-line excerpt, when the feed carried it.
    pub last_excerpt: Option<String>,
    /// The feed seq this row is current as of; older events are skipped.
    pub seq: u64,
}

/// One team's threads, by number (numbers are unique per team).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ThreadCache {
    threads: BTreeMap<u64, ThreadSummary>,
}

impl ThreadCache {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.threads.len()
    }

    pub fn is_empty(&self) -> bool {
        self.threads.is_empty()
    }

    pub fn get(&self, number: u64) -> Option<&ThreadSummary> {
        self.threads.get(&number)
    }

    /// Loads threads fetched by a list call, current as of feed seq `seq` (the head when fetched).
    /// A row already newer than `seq` is kept.
    pub fn seed(&mut self, threads: &[Thread], seq: u64) {
        for t in threads {
            if self.threads.get(&t.number).is_some_and(|row| row.seq > seq) {
                continue;
            }
            let last_excerpt = self.threads.get(&t.number).and_then(|row| row.last_excerpt.clone());
            self.threads.insert(
                t.number,
                ThreadSummary {
                    number: t.number,
                    space: t.space.clone(),
                    title: t.title.clone(),
                    state: t.state,
                    comments: t.comments,
                    created_at: t.created_at.clone(),
                    updated_at: t.updated_at.clone(),
                    last_excerpt,
                    seq,
                },
            );
        }
    }

    /// Applies one event; returns whether a row changed. Replayed or older events are skipped.
    pub fn apply(&mut self, event: &FeedEvent) -> bool {
        if event.thread == 0
            || self.threads.get(&event.thread).is_some_and(|row| row.seq >= event.seq)
        {
            return false;
        }
        let row = self.threads.entry(event.thread).or_insert_with(|| ThreadSummary {
            number: event.thread,
            created_at: event.at.clone(),
            ..ThreadSummary::default()
        });
        row.seq = event.seq;
        row.space.clone_from(&event.space);
        if !event.title.is_empty() {
            row.title.clone_from(&event.title);
        }
        if event.state != ThreadState::Unknown {
            row.state = event.state;
        }
        if event.at > row.updated_at {
            row.updated_at.clone_from(&event.at);
        }
        if event.kind == EventKind::CommentCreated {
            row.comments += 1;
            if let Some(c) = &event.comment {
                row.last_excerpt = Some(c.excerpt.clone());
            }
        }
        true
    }

    /// Applies events in order; returns how many changed a row.
    pub fn apply_all(&mut self, events: &[FeedEvent]) -> usize {
        events.iter().filter(|e| self.apply(e)).count()
    }

    /// A space's threads (every space for `None`), most recently updated first.
    pub fn list(&self, space: Option<&str>, state: StateFilter) -> Vec<&ThreadSummary> {
        let mut rows: Vec<&ThreadSummary> = self
            .threads
            .values()
            .filter(|r| space.is_none_or(|s| r.space == s))
            .filter(|r| match state {
                StateFilter::All => true,
                StateFilter::Open => r.state == ThreadState::Open,
                StateFilter::Closed => r.state == ThreadState::Closed,
            })
            .collect();
        rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then(b.number.cmp(&a.number)));
        rows
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}
