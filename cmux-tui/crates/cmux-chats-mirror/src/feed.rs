//! The `_acpmux/chats_watch` state machine: one page, then numbered changes.
//!
//! acpmux numbers every index change (`seq`); its page names the last one it holds. A change
//! at or below the mirror's seq is already in it; a jump means one was lost, so the host lists
//! again. Changes that arrive while a page is in flight (acpmux may send a change numbered past
//! the page before the page's line: it serializes megabytes after reading the index) are kept
//! and replayed on top of the page.

use crate::chat::{Chat, Flag, Number, Text, WireChat, non_empty};
use crate::index::{Change, Index};
use serde::Deserialize;

/// One decoded line of the watch. Parse it off the main thread; apply it on the owner's.
#[derive(Debug)]
pub enum Line {
    /// A page response (`_acpmux/chats_watch` or `_acpmux/chats`): the whole index.
    Page { index: Index, ready: bool, enabled: bool, seq: Option<u64> },
    /// One index change and its seq (nil for activity, which is not an index change).
    Change { change: Change, seq: Option<u64> },
    /// acpmux dropped changes for this watcher: list again.
    Lagged,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct WireMessage {
    id: Number,
    method: Text,
    result: Option<WirePage>,
    params: Option<WireParams>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct WirePage {
    chats: Option<Vec<WireChat>>,
    ready: Flag,
    enabled: Flag,
    seq: Number,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct WireParams {
    kind: Text,
    key: Text,
    seq: Number,
    attention: Text,
    preview: Text,
    parent: Text,
    chat: Option<WireChat>,
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn whole(number: Number) -> Option<u64> {
    number.0.filter(|value| *value >= 0.0).map(|value| value as u64)
}

impl Line {
    /// Decodes one line, or None when it is not a page, change or lag of the watch (the
    /// `initialize` answer, a malformed change, another method).
    pub fn parse(bytes: &[u8]) -> Option<Line> {
        let message: WireMessage = serde_json::from_slice(bytes).ok()?;
        if let (Some(id), Some(page)) = (message.id.0, message.result) {
            // The watch is request 2; every later list is 3 or more.
            #[allow(clippy::cast_possible_truncation)]
            let id = id as i64;
            if id == 2 || id >= 3 {
                let chats = page.chats.unwrap_or_default().into_iter().filter_map(Chat::from_wire);
                return Some(Line::Page {
                    index: Index::from_chats(chats),
                    ready: page.ready.0.unwrap_or(false),
                    enabled: page.enabled.0.unwrap_or(true),
                    seq: whole(page.seq),
                });
            }
            return None;
        }
        match message.method.0.as_deref() {
            Some("_acpmux/chat_changed") => {
                let params = message.params?;
                let key: Box<str> = params.key.0.filter(|key| !key.is_empty())?.into();
                let seq = whole(params.seq);
                let change = match params.kind.0.as_deref() {
                    Some("removed") => Change::Removed { key },
                    Some("activity") => Change::Activity {
                        key,
                        attention: params.attention.0.map(Into::into),
                        preview: params.preview.0.map(Into::into),
                        parent: non_empty(params.parent.0),
                    },
                    _ => Change::Upserted { chat: Chat::from_wire(params.chat?)? },
                };
                Some(Line::Change { change, seq })
            }
            Some("_acpmux/chats_lagged") => Some(Line::Lagged),
            _ => None,
        }
    }
}

/// What applying a batch of lines did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    /// The mirror changed: publish once.
    pub changed: bool,
    /// A change was lost (or acpmux said so): list again.
    pub lagged: bool,
    /// A page landed (the connection is healthy: reset its reconnect backoff).
    pub page: bool,
    /// The index's membership, order or listed set changed (not just activity).
    pub index_changed: bool,
}

/// Changes held while a page is in flight before the host lists again instead.
pub const EARLY_LIMIT: usize = 4096;

/// The app's one mirror of the chat index, with the watch's bookkeeping.
#[derive(Debug)]
pub struct Feed {
    index: Index,
    seq: Option<u64>,
    page_in_flight: bool,
    list_again: bool,
    early: Vec<(Change, Option<u64>)>,
    ready: bool,
    enabled: bool,
    generation: u64,
}

impl Default for Feed {
    fn default() -> Self {
        Feed {
            index: Index::default(),
            seq: None,
            page_in_flight: false,
            list_again: false,
            early: Vec::new(),
            ready: false,
            enabled: true,
            generation: 0,
        }
    }
}

impl Feed {
    pub fn new() -> Self {
        Feed::default()
    }

    /// The index.
    pub fn index(&self) -> &Index {
        &self.index
    }

    /// acpmux finished its first scan.
    pub fn is_ready(&self) -> bool {
        self.ready
    }

    /// The chat index is turned on.
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Bumped by every change of the index's membership, order or listed set: a reader that
    /// needs only those (the project list) skips activity.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// A new connection sent the watch request: its page is in flight, and a restarted daemon
    /// numbers from 0 again.
    pub fn connection_started(&mut self) {
        self.seq = None;
        self.page_in_flight = true;
        self.list_again = false;
        self.early.clear();
    }

    /// Replaces the index with a page outside any watch (tests and one-shot lists).
    pub fn load(&mut self, index: Index) {
        self.index = index;
        self.generation = self.generation.wrapping_add(1);
    }

    /// Applies a batch of lines in order.
    pub fn apply(&mut self, lines: impl IntoIterator<Item = Line>) -> Outcome {
        let mut outcome = Outcome::default();
        for line in lines {
            match line {
                Line::Page { index, ready, enabled, seq } => {
                    self.index = index;
                    self.seq = seq;
                    self.ready = ready;
                    self.enabled = enabled;
                    self.page_in_flight = false;
                    outcome.page = true;
                    outcome.lagged = self.list_again;
                    self.list_again = false;
                    outcome.index_changed = true;
                    for (change, seq) in std::mem::take(&mut self.early) {
                        if !self.apply_change(change, seq, &mut outcome) {
                            outcome.lagged = true;
                        }
                    }
                    outcome.changed = true;
                }
                Line::Change { change, seq } => {
                    if self.page_in_flight {
                        if self.early.len() < EARLY_LIMIT {
                            self.early.push((change, seq));
                        } else {
                            self.list_again = true;
                        }
                        continue;
                    }
                    if !self.apply_change(change, seq, &mut outcome) {
                        outcome.lagged = true;
                    }
                    outcome.changed = true;
                }
                Line::Lagged => outcome.lagged = true,
            }
        }
        if outcome.index_changed {
            self.generation = self.generation.wrapping_add(1);
        }
        outcome
    }

    /// The host wants a fresh page: true when it must send the list now (the page is then in
    /// flight); false when one is already in flight (another is sent when it lands).
    pub fn want_list(&mut self) -> bool {
        if self.page_in_flight {
            self.list_again = true;
            return false;
        }
        self.page_in_flight = true;
        true
    }

    /// Applies one change unless the mirror already holds it (its seq is at or below the
    /// mirror's). False on a jump in seq: a change was lost.
    fn apply_change(&mut self, change: Change, seq: Option<u64>, outcome: &mut Outcome) -> bool {
        let mut contiguous = true;
        if let Some(seq) = seq {
            if let Some(last) = self.seq {
                if seq <= last {
                    return true;
                }
                contiguous = last.checked_add(1) == Some(seq);
            }
            self.seq = Some(seq);
        }
        if self.index.apply(change) {
            outcome.index_changed = true;
        }
        contiguous
    }
}
