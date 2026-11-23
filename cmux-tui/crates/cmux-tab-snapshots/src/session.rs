//! The Mac side of one connected phone. Frames from the phone go in through
//! [`Session::on_frame`]; the host pulls frames to write with
//! [`Session::next_frame`] whenever the link can take one, so nothing is
//! buffered beyond a queue of hashes (the bytes stay in the store).
//!
//! Rules:
//! - The session opens on the phone's first frame other than `have`. On
//!   link-up the phone sends `have` (if it holds blobs), then `resume` (if
//!   it holds a rev), then `viewport`. A resumed phone's opening frame is a
//!   delta from its rev; a phone without one, or one whose `resume` names
//!   another epoch than the producer's (or none), gets the manifest. The
//!   host may also open the session itself ([`Session::open`]) if the phone
//!   stays silent.
//! - A producer change since the last manifest or delta goes out as one
//!   delta before any blob; changes made between two pulls coalesce.
//! - Push (the default): after each manifest or delta the session queues
//!   the card blobs in row order, per row the favicon, then the thumbnail
//!   or screen, without waiting for `want`. A pushed hash is skipped when
//!   the phone listed it in `have` or this session already sent it. Full
//!   frames (`frameHash`) are never pushed, only sent on `want`.
//! - `want` moves its hashes to the front of the queue, in its order, and
//!   replaces the hashes of the previous `want` still queued. A hash named
//!   in `want` is sent even when the phone listed it in `have` or this
//!   session sent it before (the phone may have evicted it), but once per
//!   `want`. So with push on, a phone sends `want` only to reorder what is
//!   still coming or to fetch again what it dropped, not to list every
//!   blob it lacks: those are already on their way.
//! - A queued hash the store no longer holds is skipped.
//! - [`Session::without_push`] turns push off: blobs move only on `want`.
//! - A row filter ([`Session::set_row_filter`]) hides tabs from this phone:
//!   its manifest and deltas carry only the tabs the filter passes, and a
//!   blob goes out (pushed or wanted) only when a passed row names it. A new
//!   filter is answered with a fresh manifest. While the filter hides a
//!   current row, a `resume` is answered with a manifest too, since the
//!   phone's rows may come from a connection with another filter. A delta's
//!   `removed` is not filtered, so a tab hidden after the phone saw it still
//!   leaves the phone when it closes.

use crate::hash::BlobHash;
use crate::producer::Producer;
use crate::wire::{Message, Viewport, WireError, encode_blob};
use std::collections::{HashSet, VecDeque};
use std::fmt;
use std::sync::Arc;

/// A predicate on `tabId`: true when this phone may see the tab.
#[derive(Clone)]
pub struct RowFilter(Arc<dyn Fn(&str) -> bool + Send + Sync>);

impl RowFilter {
    pub fn new(pass: impl Fn(&str) -> bool + Send + Sync + 'static) -> Self {
        Self(Arc::new(pass))
    }

    pub fn passes(&self, tab_id: &str) -> bool {
        (self.0)(tab_id)
    }
}

impl fmt::Debug for RowFilter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RowFilter")
    }
}

/// Why a phone frame was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionError {
    Wire(WireError),
    /// A Mac-to-phone kind arrived from the phone.
    WrongDirection(u8),
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Wire(err) => err.fmt(f),
            Self::WrongDirection(kind) => write!(f, "frame kind 0x{kind:02x} is Mac to phone"),
        }
    }
}

impl std::error::Error for SessionError {}

/// Counters for reports and the bench.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SessionStats {
    pub manifests: u64,
    pub deltas: u64,
    pub blobs: u64,
    pub blob_bytes: u64,
    /// Pushed hashes skipped because the phone has them or they were sent.
    pub skipped_held: u64,
    /// Queued hashes skipped because the store no longer holds them.
    pub skipped_gone: u64,
    /// Blobs sent again because a `want` named a hash sent before.
    pub resent: u64,
    /// Queued hashes skipped because no row the filter passes names them.
    pub skipped_hidden: u64,
}

/// One queued hash. `wanted` is true for a hash the phone named in `want`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Queued {
    hash: BlobHash,
    wanted: bool,
}

#[derive(Debug)]
pub struct Session {
    opened: bool,
    /// The rev the phone holds (or will once the frames already pulled
    /// arrive). `None` until a manifest went out or the phone resumed.
    phone_rev: Option<u64>,
    /// The phone resumed and has not been answered yet.
    answer_resume: bool,
    /// The epoch the phone's `resume` named. A resume from another epoch is
    /// answered with a manifest.
    resume_epoch: String,
    phone_has: HashSet<BlobHash>,
    sent: HashSet<BlobHash>,
    queue: VecDeque<Queued>,
    viewport: Option<Viewport>,
    push: bool,
    filter: Option<RowFilter>,
    stats: SessionStats,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            opened: false,
            phone_rev: None,
            answer_resume: false,
            resume_epoch: String::new(),
            phone_has: HashSet::new(),
            sent: HashSet::new(),
            queue: VecDeque::new(),
            viewport: None,
            push: true,
            filter: None,
            stats: SessionStats::default(),
        }
    }
}

impl Session {
    /// A session that pushes card blobs (see the module rules).
    pub fn new() -> Self {
        Self::default()
    }

    /// A session that sends blobs only on `want`.
    pub fn without_push() -> Self {
        Self { push: false, ..Self::default() }
    }

    /// True when this session pushes card blobs without `want`.
    pub fn pushes(&self) -> bool {
        self.push
    }

    /// Sets (or with `None` clears) the row filter. The phone's next frame
    /// is a manifest of the rows the new filter passes, and queued hashes no
    /// passed row names are dropped when pulled.
    pub fn set_row_filter(&mut self, filter: Option<RowFilter>) {
        self.filter = filter;
        self.phone_rev = None;
        self.answer_resume = false;
    }

    fn visible(&self, tab_id: &str) -> bool {
        self.filter.as_ref().is_none_or(|f| f.passes(tab_id))
    }

    fn hides_any(&self, producer: &Producer) -> bool {
        self.filter.is_some() && producer.rows().iter().any(|r| !self.visible(&r.tab_id))
    }

    /// True when a row this phone may see names `hash`.
    fn visible_hash(&self, producer: &Producer, hash: &BlobHash) -> bool {
        if self.filter.is_none() {
            return true;
        }
        producer.rows().iter().any(|r| self.visible(&r.tab_id) && r.hashes().any(|h| h == *hash))
    }

    /// Opens the session without waiting for the phone's first frame.
    pub fn open(&mut self) {
        self.opened = true;
    }

    pub fn viewport(&self) -> Option<&Viewport> {
        self.viewport.as_ref()
    }

    pub fn stats(&self) -> SessionStats {
        self.stats
    }

    /// Hashes still queued (some may be skipped when pulled).
    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    pub fn on_frame(&mut self, frame: &[u8]) -> Result<(), SessionError> {
        let msg = Message::decode(frame).map_err(SessionError::Wire)?;
        self.on_message(msg)
    }

    pub fn on_message(&mut self, msg: Message) -> Result<(), SessionError> {
        match msg {
            Message::Viewport(v) => self.viewport = Some(v),
            Message::Want(hashes) => {
                let mut seen = HashSet::new();
                let wanted: Vec<BlobHash> =
                    hashes.into_iter().filter(|h| seen.insert(*h)).collect();
                self.queue.retain(|q| !q.wanted && !seen.contains(&q.hash));
                for &hash in wanted.iter().rev() {
                    self.queue.push_front(Queued { hash, wanted: true });
                }
            }
            Message::Have(hashes) => {
                self.phone_has.extend(hashes);
                let has = &self.phone_has;
                self.queue.retain(|q| q.wanted || !has.contains(&q.hash));
                // `have` comes first on link-up and does not open the
                // session: the frame after it (`resume` or `viewport`) does,
                // so the opening already knows the phone's cache and rev.
                return Ok(());
            }
            Message::Resume(r) => {
                self.phone_rev = Some(r.rev);
                self.resume_epoch = r.epoch;
                self.answer_resume = true;
            }
            other @ (Message::Manifest(_) | Message::Delta(_) | Message::Blob(_)) => {
                return Err(SessionError::WrongDirection(other.kind()));
            }
        }
        self.opened = true;
        Ok(())
    }

    fn held(&self, hash: &BlobHash) -> bool {
        self.phone_has.contains(hash) || self.sent.contains(hash)
    }

    /// The next frame to write, or `None` when there is nothing to send now.
    pub fn next_frame(&mut self, producer: &Producer) -> Option<Vec<u8>> {
        if !self.opened {
            return None;
        }
        if let Some(frame) = self.rows_frame(producer) {
            return Some(frame);
        }
        while let Some(Queued { hash, wanted }) = self.queue.pop_front() {
            if !wanted && self.held(&hash) {
                self.stats.skipped_held = self.stats.skipped_held.saturating_add(1);
                continue;
            }
            if !self.visible_hash(producer, &hash) {
                self.stats.skipped_hidden = self.stats.skipped_hidden.saturating_add(1);
                continue;
            }
            let Some(blob) = producer.store().get(&hash) else {
                self.stats.skipped_gone = self.stats.skipped_gone.saturating_add(1);
                continue;
            };
            if !self.sent.insert(hash) {
                self.stats.resent = self.stats.resent.saturating_add(1);
            }
            let len = u64::try_from(blob.bytes.len()).unwrap_or(u64::MAX);
            self.stats.blobs = self.stats.blobs.saturating_add(1);
            self.stats.blob_bytes = self.stats.blob_bytes.saturating_add(len);
            return Some(encode_blob(hash, blob.mime, &blob.bytes));
        }
        None
    }

    /// Replaces the pushed part of the queue with the card blobs the phone
    /// lacks, in row order: per row the favicon, then the thumbnail or
    /// screen. Wanted hashes stay in front.
    fn queue_push(&mut self, producer: &Producer) {
        let mut seen: HashSet<BlobHash> =
            self.queue.iter().filter(|q| q.wanted).map(|q| q.hash).collect();
        self.queue.retain(|q| q.wanted);
        let card = producer
            .rows()
            .iter()
            .filter(|r| self.visible(&r.tab_id))
            .flat_map(|r| [r.favicon_hash, r.thumb_hash, r.screen_hash])
            .flatten()
            .collect::<Vec<_>>();
        for hash in card {
            if !self.held(&hash) && seen.insert(hash) {
                self.queue.push_back(Queued { hash, wanted: false });
            }
        }
    }

    /// A manifest or delta when the phone's rev is not the producer's.
    fn rows_frame(&mut self, producer: &Producer) -> Option<Vec<u8>> {
        let rev = producer.rev();
        let same_epoch = !self.answer_resume
            || (self.resume_epoch == producer.epoch() && !self.hides_any(producer));
        let delta = match self.phone_rev {
            Some(have) if have == rev && !self.answer_resume => return None,
            Some(have) if same_epoch => producer.delta_since(have),
            _ => None,
        };
        self.answer_resume = false;
        self.phone_rev = Some(rev);
        if self.push {
            self.queue_push(producer);
        }
        Some(match delta {
            Some(mut delta) => {
                self.stats.deltas = self.stats.deltas.saturating_add(1);
                if self.filter.is_some() {
                    delta.changed.retain(|p| self.visible(&p.tab_id));
                    if let Some(order) = delta.order.as_mut() {
                        order.retain(|id| self.visible(id));
                    }
                }
                Message::Delta(delta).encode()
            }
            None => {
                self.stats.manifests = self.stats.manifests.saturating_add(1);
                let mut manifest = producer.manifest();
                if self.filter.is_some() {
                    manifest.rows.retain(|r| self.visible(&r.tab_id));
                }
                Message::Manifest(manifest).encode()
            }
        })
    }
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
