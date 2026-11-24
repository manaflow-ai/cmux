//! A reference phone side, used by tests and the bench. The phone app owns
//! its real cache and fetch policy elsewhere; this one shows the rules a
//! phone has to keep:
//! - A delta applies only on top of the rev it names (`baseRev`) in the
//!   epoch the mirror holds. Any other delta is a gap: the caller sends
//!   `resume {epoch, rev}`. A manifest replaces everything, epoch included.
//! - A blob is kept only when its bytes hash to the hash in its frame.
//! - What to ask for: favicons first in row order, then each row's
//!   thumbnail or screen in row order. Full frames are fetched on demand,
//!   not by this list. Against a pushing Mac (the default) a phone does not
//!   send this list: the blobs are already on their way, and a `want`
//!   names hashes to send again. It wants only what it must have first or
//!   what it evicted.
//!
//! The mirror keeps hashes, not bytes. The held set can be exported and
//! imported to model a cache persisted across launches.

use crate::hash::BlobHash;
use crate::row::{Row, reorder};
use crate::wire::{Delta, Manifest, Message, Resume, WireError};
use std::collections::HashSet;
use std::fmt;

/// What applying one frame did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Applied {
    Manifest {
        rev: u64,
    },
    Delta {
        rev: u64,
    },
    /// The delta starts at `base_rev` but the mirror is at `mirror_rev`, or
    /// the delta is from another epoch than the mirror holds.
    /// Nothing changed; send [`Mirror::resume_frame`].
    Gap {
        mirror_rev: Option<u64>,
        base_rev: u64,
    },
    /// `fresh` is false when the mirror already held it.
    Blob {
        hash: BlobHash,
        len: usize,
        fresh: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorError {
    Wire(WireError),
    /// The blob's bytes do not hash to the hash in its frame.
    HashMismatch {
        claimed: BlobHash,
        actual: BlobHash,
    },
    /// A phone-to-Mac kind arrived from the Mac.
    WrongDirection(u8),
}

impl fmt::Display for MirrorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Wire(err) => err.fmt(f),
            Self::HashMismatch { claimed, actual } => {
                write!(f, "blob claims {claimed} but hashes to {actual}")
            }
            Self::WrongDirection(kind) => write!(f, "frame kind 0x{kind:02x} is phone to Mac"),
        }
    }
}

impl std::error::Error for MirrorError {}

#[derive(Debug, Default)]
pub struct Mirror {
    epoch: String,
    rev: Option<u64>,
    rows: Vec<Row>,
    held: HashSet<BlobHash>,
}

impl Mirror {
    pub fn new() -> Self {
        Self::default()
    }

    /// The epoch of the last manifest applied (empty before any).
    pub fn epoch(&self) -> &str {
        &self.epoch
    }

    /// The rev of the last manifest or delta applied.
    pub fn rev(&self) -> Option<u64> {
        self.rev
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    pub fn holds(&self, hash: &BlobHash) -> bool {
        self.held.contains(hash)
    }

    /// The held hashes, sorted, for persisting.
    pub fn export_held(&self) -> Vec<BlobHash> {
        let mut out: Vec<_> = self.held.iter().copied().collect();
        out.sort_unstable();
        out
    }

    /// Adds hashes from a persisted cache.
    pub fn import_held(&mut self, hashes: impl IntoIterator<Item = BlobHash>) {
        self.held.extend(hashes);
    }

    /// Forgets the rows and rev but keeps the held blobs: a relaunch with a
    /// persisted blob cache and no persisted manifest.
    pub fn relaunch(&mut self) {
        self.epoch.clear();
        self.rev = None;
        self.rows.clear();
    }

    pub fn apply_frame(&mut self, frame: &[u8]) -> Result<Applied, MirrorError> {
        let msg = Message::decode(frame).map_err(MirrorError::Wire)?;
        self.apply(msg)
    }

    pub fn apply(&mut self, msg: Message) -> Result<Applied, MirrorError> {
        match msg {
            Message::Manifest(m) => Ok(self.apply_manifest(m)),
            Message::Delta(d) => Ok(self.apply_delta(d)),
            Message::Blob(blob) => {
                let actual = BlobHash::of(&blob.bytes);
                if actual != blob.hash {
                    return Err(MirrorError::HashMismatch { claimed: blob.hash, actual });
                }
                let fresh = self.held.insert(blob.hash);
                Ok(Applied::Blob { hash: blob.hash, len: blob.bytes.len(), fresh })
            }
            other @ (Message::Viewport(_)
            | Message::Want(_)
            | Message::Have(_)
            | Message::Resume(_)) => Err(MirrorError::WrongDirection(other.kind())),
        }
    }

    fn apply_manifest(&mut self, m: Manifest) -> Applied {
        self.epoch = m.epoch;
        self.rev = Some(m.rev);
        self.rows = m.rows;
        Applied::Manifest { rev: m.rev }
    }

    fn apply_delta(&mut self, d: Delta) -> Applied {
        if self.rev != Some(d.base_rev) || self.epoch != d.epoch {
            return Applied::Gap { mirror_rev: self.rev, base_rev: d.base_rev };
        }
        let removed: HashSet<&str> = d.removed.iter().map(String::as_str).collect();
        self.rows.retain(|r| !removed.contains(r.tab_id.as_str()));
        for patch in &d.changed {
            match self.rows.iter_mut().find(|r| r.tab_id == patch.tab_id) {
                Some(row) => patch.apply(row),
                None => {
                    let mut row = Row { tab_id: patch.tab_id.clone(), ..Row::default() };
                    patch.apply(&mut row);
                    self.rows.push(row);
                }
            }
        }
        if let Some(order) = &d.order {
            reorder(&mut self.rows, order);
        }
        self.rev = Some(d.rev);
        Applied::Delta { rev: d.rev }
    }

    /// The hashes a card needs to be drawn: favicon, then thumbnail or
    /// screen.
    fn card_hashes(row: &Row) -> impl Iterator<Item = BlobHash> {
        [row.favicon_hash, row.thumb_hash, row.screen_hash].into_iter().flatten()
    }

    /// True when the card at `index` has every blob it shows.
    pub fn card_filled(&self, index: usize) -> bool {
        self.rows
            .get(index)
            .is_some_and(|row| Self::card_hashes(row).all(|h| self.held.contains(&h)))
    }

    /// Hashes still missing: favicons in row order, then thumbnails or
    /// screens in row order. Each hash appears once.
    pub fn missing(&self) -> Vec<BlobHash> {
        let mut seen = HashSet::new();
        let favicons = self.rows.iter().filter_map(|r| r.favicon_hash);
        let bodies = self.rows.iter().flat_map(|r| [r.thumb_hash, r.screen_hash]).flatten();
        favicons.chain(bodies).filter(|h| !self.held.contains(h) && seen.insert(*h)).collect()
    }

    /// A `want` for [`Mirror::missing`], or `None` when nothing is missing.
    pub fn want_frame(&self) -> Option<Vec<u8>> {
        let missing = self.missing();
        (!missing.is_empty()).then(|| Message::Want(missing).encode())
    }

    /// `resume {epoch, rev}`, or `None` before any manifest.
    pub fn resume_frame(&self) -> Option<Vec<u8>> {
        self.rev.map(|rev| Message::Resume(Resume { epoch: self.epoch.clone(), rev }).encode())
    }

    /// `have` for the held set, or `None` when it is empty.
    pub fn have_frame(&self) -> Option<Vec<u8>> {
        (!self.held.is_empty()).then(|| Message::Have(self.export_held()).encode())
    }

    /// What the phone writes on link-up, in order: `have` (which does not
    /// open the Mac's session), then `resume`, so the Mac's opening frame
    /// knows both the phone's cache and its rev. The caller appends
    /// `viewport`, which opens the session when neither is sent.
    pub fn link_up_frames(&self) -> Vec<Vec<u8>> {
        self.have_frame().into_iter().chain(self.resume_frame()).collect()
    }
}

#[cfg(test)]
#[path = "mirror_tests.rs"]
mod tests;
