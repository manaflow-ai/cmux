//! Clipboard text sync (cap `clipboard.text`): the `clipboard` control message's parts,
//! the sender that splits a text into them and paces them, and the receiver that joins
//! them, for the host and the viewer alike. No I/O; every time is the caller's clock.
//!
//! One control record must fit one sealed packet of the secure link (a Noise message is at
//! most 65535 bytes) and every record waits in the link's window of 128 unacknowledged
//! records, whose overflow ends the session. So a text travels in parts whose JSON-escaped
//! text is at most [`MAX_PART_ENCODED`] bytes, at most one part per [`PART_INTERVAL_US`],
//! and a newer text drops the unsent parts of an older one. A text over
//! [`MAX_CLIPBOARD_TEXT`] bytes is refused whole and counted, never truncated.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// Largest clipboard text, in UTF-8 bytes (1 MiB, the stream carrier's frame limit).
pub const MAX_CLIPBOARD_TEXT: usize = 1 << 20;
/// Largest JSON-escaped text in one part: with the rest of the message the record stays
/// near the size of a `cursor_shape` record, far under one link packet.
pub const MAX_PART_ENCODED: usize = 16 * 1024;
/// Least time between two parts of one sender (at most 1.6 MB/s of escaped text; at a
/// 300 ms round trip about 30 parts wait for their acknowledgement, a quarter of the window).
pub const PART_INTERVAL_US: u64 = 10_000;

/// One `clipboard` control message (`control::Control::Clipboard`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardPart {
    pub seq: u64,
    pub text: String,
    /// UTF-8 byte offset of `text` in the whole; `None` for a whole text in one part.
    pub offset: Option<u64>,
    /// UTF-8 length of the whole text; `None` for a whole text in one part.
    pub total: Option<u64>,
}

/// What [`ClipboardSync::offer`] did with a local text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Offer {
    /// Queued as `seq`; its parts come out of [`ClipboardSync::next_part`].
    Queued(u64),
    /// The same text both sides already have (the peer's own text coming back): not sent.
    Unchanged,
    /// Over [`MAX_CLIPBOARD_TEXT`]: refused and counted in [`ClipboardSync::dropped`].
    TooLarge,
}

/// Why a received part was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PartError {
    /// The whole text would pass [`MAX_CLIPBOARD_TEXT`].
    TooLarge,
    /// A part that does not continue the text being joined, or an older `seq`.
    OutOfOrder,
    /// `offset` and `total` not both set, or the parts pass `total`.
    Invalid,
}

/// Counters of refused texts and parts (both directions).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Dropped {
    /// Local texts refused for size.
    pub local_too_large: u64,
    /// Received texts refused for size.
    pub remote_too_large: u64,
    /// Received parts out of order or malformed.
    pub remote_invalid: u64,
}

struct Outgoing {
    seq: u64,
    text: String,
    /// Bytes of `text` already sent.
    sent: usize,
}

struct Joining {
    seq: u64,
    total: usize,
    text: String,
}

/// One side's clipboard sync: what it sends and what it receives, and the text both sides
/// last agreed on, so a text set from the peer is not sent back (no echo).
#[derive(Default)]
pub struct ClipboardSync {
    next_seq: u64,
    outgoing: Option<Outgoing>,
    next_part_us: u64,
    joining: Option<Joining>,
    /// The highest `seq` received (whole or begun).
    last_remote_seq: u64,
    /// Fingerprint of the text both sides have now (last sent or last received).
    shared: Option<(usize, u64)>,
    dropped: Dropped,
}

fn fingerprint(text: &str) -> (usize, u64) {
    let mut h = DefaultHasher::new();
    text.hash(&mut h);
    (text.len(), h.finish())
}

/// Bytes `c` takes inside a JSON string as serde_json writes it.
fn escaped_len(c: char) -> usize {
    match c {
        '"' | '\\' | '\u{8}' | '\u{c}' | '\n' | '\r' | '\t' => 2,
        c if (c as u32) < 0x20 => 6,
        c => c.len_utf8(),
    }
}

/// The byte length of the longest prefix of `text` whose escaped length fits `budget`
/// (at least one character, so a part always makes progress).
fn part_len(text: &str, budget: usize) -> usize {
    let mut used = 0;
    for (i, c) in text.char_indices() {
        let n = escaped_len(c);
        if used + n > budget && i > 0 {
            return i;
        }
        used += n;
    }
    text.len()
}

impl ClipboardSync {
    pub fn new() -> Self {
        Self::default()
    }

    /// The local clipboard now holds `text`: queue it for the peer, unless it is what both
    /// sides already have. A newer text replaces an older one still being sent.
    pub fn offer(&mut self, text: &str) -> Offer {
        if text.len() > MAX_CLIPBOARD_TEXT {
            self.dropped.local_too_large += 1;
            return Offer::TooLarge;
        }
        let print = fingerprint(text);
        if self.shared == Some(print) {
            return Offer::Unchanged;
        }
        self.shared = Some(print);
        self.next_seq += 1;
        self.outgoing = Some(Outgoing { seq: self.next_seq, text: text.to_owned(), sent: 0 });
        Offer::Queued(self.next_seq)
    }

    /// The next part to send at `now_us`, at most one per [`PART_INTERVAL_US`].
    pub fn next_part(&mut self, now_us: u64) -> Option<ClipboardPart> {
        if now_us < self.next_part_us {
            return None;
        }
        let out = self.outgoing.as_mut()?;
        let rest = out.text.get(out.sent..).unwrap_or_default();
        let len = part_len(rest, MAX_PART_ENCODED);
        let whole = out.sent == 0 && len == out.text.len();
        let part = ClipboardPart {
            seq: out.seq,
            text: rest.get(..len).unwrap_or_default().to_owned(),
            offset: (!whole).then_some(out.sent as u64),
            total: (!whole).then_some(out.text.len() as u64),
        };
        out.sent += len;
        if out.sent >= out.text.len() {
            self.outgoing = None;
        }
        self.next_part_us = now_us.saturating_add(PART_INTERVAL_US);
        Some(part)
    }

    /// When [`Self::next_part`] gives a part next; `None` when nothing waits.
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.outgoing.as_ref().map(|_| self.next_part_us)
    }

    /// Drops the unsent parts of the text being sent (the session lost control). The peer
    /// drops the begun text when the next one starts.
    pub fn cancel_outgoing(&mut self) {
        self.outgoing = None;
    }

    /// Whether a text is still being sent.
    pub fn sending(&self) -> bool {
        self.outgoing.is_some()
    }

    /// Takes one received part. `Ok(Some((seq, text)))` when it completes a text: set the
    /// local clipboard to it. A completed text ends a local text still being sent (the
    /// peer's is newer), so both sides end with the same text.
    pub fn receive(&mut self, part: ClipboardPart) -> Result<Option<(u64, String)>, PartError> {
        let result = self.join(part);
        match &result {
            Err(PartError::TooLarge) => self.dropped.remote_too_large += 1,
            Err(_) => self.dropped.remote_invalid += 1,
            Ok(Some((_, text))) => {
                self.shared = Some(fingerprint(text));
                self.outgoing = None;
            }
            Ok(None) => {}
        }
        result
    }

    fn join(&mut self, part: ClipboardPart) -> Result<Option<(u64, String)>, PartError> {
        let ClipboardPart { seq, text, offset, total } = part;
        match (offset, total) {
            (None, None) => {
                if seq <= self.last_remote_seq {
                    return Err(PartError::OutOfOrder);
                }
                self.last_remote_seq = seq;
                self.joining = None;
                if text.len() > MAX_CLIPBOARD_TEXT {
                    return Err(PartError::TooLarge);
                }
                Ok(Some((seq, text)))
            }
            (Some(0), Some(total)) => {
                if seq <= self.last_remote_seq {
                    return Err(PartError::OutOfOrder);
                }
                self.last_remote_seq = seq;
                self.joining = None;
                let total = usize::try_from(total).unwrap_or(usize::MAX);
                if total > MAX_CLIPBOARD_TEXT {
                    return Err(PartError::TooLarge);
                }
                self.joining = Some(Joining { seq, total, text: String::new() });
                self.append(seq, 0, text)
            }
            (Some(offset), Some(_)) => self.append(seq, offset, text),
            _ => Err(PartError::Invalid),
        }
    }

    fn append(
        &mut self,
        seq: u64,
        offset: u64,
        text: String,
    ) -> Result<Option<(u64, String)>, PartError> {
        let Some(joining) = self.joining.as_mut() else { return Err(PartError::OutOfOrder) };
        if joining.seq != seq || joining.text.len() as u64 != offset {
            self.joining = None;
            return Err(PartError::OutOfOrder);
        }
        if joining.text.len() + text.len() > joining.total {
            self.joining = None;
            return Err(PartError::Invalid);
        }
        joining.text.push_str(&text);
        if joining.text.len() < joining.total {
            return Ok(None);
        }
        let done = self.joining.take().map(|j| (j.seq, j.text));
        Ok(done)
    }

    /// Counts a local text the caller refused for size before offering it.
    pub fn note_local_too_large(&mut self) {
        self.dropped.local_too_large += 1;
    }

    /// Counts a received `clipboard` message the caller could not parse.
    pub fn note_remote_invalid(&mut self) {
        self.dropped.remote_invalid += 1;
    }

    /// Refused texts and parts so far.
    pub fn dropped(&self) -> Dropped {
        self.dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drain(s: &mut ClipboardSync) -> Vec<ClipboardPart> {
        let mut now = 0;
        let mut parts = Vec::new();
        while let Some(due) = s.next_deadline_us() {
            now = now.max(due);
            parts.extend(s.next_part(now));
        }
        parts
    }

    #[test]
    fn a_short_text_is_one_whole_part() {
        let mut a = ClipboardSync::new();
        assert_eq!(a.offer("hello"), Offer::Queued(1));
        let parts = drain(&mut a);
        assert_eq!(
            parts,
            vec![ClipboardPart { seq: 1, text: "hello".into(), offset: None, total: None }]
        );
        let mut b = ClipboardSync::new();
        assert_eq!(b.receive(parts[0].clone()), Ok(Some((1, "hello".into()))));
    }

    #[test]
    fn a_long_text_travels_in_paced_parts_and_joins_whole() {
        let text: String = (0..100_000).map(|i| ['a', 'é', '"', '\u{1}', '😀'][i % 5]).collect();
        let mut a = ClipboardSync::new();
        assert_eq!(a.offer(&text), Offer::Queued(1));
        // Pacing: a second part is not due within the interval.
        assert!(a.next_part(0).is_some());
        assert!(a.next_part(PART_INTERVAL_US - 1).is_none());
        let mut a = ClipboardSync::new();
        a.offer(&text);
        let parts = drain(&mut a);
        assert!(parts.len() > 1);
        let mut b = ClipboardSync::new();
        let mut out = None;
        for part in parts {
            let json_len = part.text.chars().map(escaped_len).sum::<usize>();
            assert!(json_len <= MAX_PART_ENCODED, "{json_len}");
            assert_eq!(part.total, Some(text.len() as u64));
            if let Some(done) = b.receive(part).expect("part") {
                out = Some(done);
            }
        }
        assert_eq!(out, Some((1, text)));
    }

    #[test]
    fn a_text_over_the_bound_is_refused_and_counted_never_truncated() {
        let mut a = ClipboardSync::new();
        let big = "x".repeat(MAX_CLIPBOARD_TEXT + 1);
        assert_eq!(a.offer(&big), Offer::TooLarge);
        assert!(a.next_part(0).is_none());
        assert_eq!(a.dropped().local_too_large, 1);
        assert_eq!(a.offer(&"x".repeat(MAX_CLIPBOARD_TEXT)), Offer::Queued(1));
        let mut b = ClipboardSync::new();
        let part = ClipboardPart {
            seq: 1,
            text: "x".into(),
            offset: Some(0),
            total: Some(MAX_CLIPBOARD_TEXT as u64 + 1),
        };
        assert_eq!(b.receive(part), Err(PartError::TooLarge));
        let whole = ClipboardPart { seq: 2, text: big, offset: None, total: None };
        assert_eq!(b.receive(whole), Err(PartError::TooLarge));
        assert_eq!(b.dropped().remote_too_large, 2);
    }

    #[test]
    fn the_peers_text_is_not_sent_back() {
        let mut host = ClipboardSync::new();
        let mut viewer = ClipboardSync::new();
        viewer.offer("from viewer");
        for part in drain(&mut viewer) {
            host.receive(part).expect("part");
        }
        // The host's pasteboard now changes to the viewer's text: no echo.
        assert_eq!(host.offer("from viewer"), Offer::Unchanged);
        // The viewer reads its own clipboard again: still the same.
        assert_eq!(viewer.offer("from viewer"), Offer::Unchanged);
        // A real change goes out.
        assert_eq!(host.offer("from host"), Offer::Queued(1));
    }

    #[test]
    fn a_newer_text_replaces_the_unsent_parts_of_an_older_one() {
        let mut a = ClipboardSync::new();
        a.offer(&"o".repeat(MAX_PART_ENCODED * 3));
        let first = a.next_part(0).expect("first part");
        assert_eq!(a.offer("new"), Offer::Queued(2));
        let rest = drain(&mut a);
        assert_eq!(
            rest,
            vec![ClipboardPart { seq: 2, text: "new".into(), offset: None, total: None }]
        );
        let mut b = ClipboardSync::new();
        assert_eq!(b.receive(first), Ok(None));
        assert_eq!(b.receive(rest[0].clone()), Ok(Some((2, "new".into()))));
    }

    #[test]
    fn parts_out_of_order_or_malformed_are_dropped() {
        let mut b = ClipboardSync::new();
        let p = |seq, text: &str, offset, total| ClipboardPart {
            seq,
            text: text.into(),
            offset,
            total,
        };
        assert_eq!(b.receive(p(1, "ab", Some(2), Some(4))), Err(PartError::OutOfOrder));
        assert_eq!(b.receive(p(1, "ab", Some(0), None)), Err(PartError::Invalid));
        assert_eq!(b.receive(p(2, "ab", Some(0), Some(4))), Ok(None));
        assert_eq!(b.receive(p(2, "abc", Some(2), Some(4))), Err(PartError::Invalid));
        assert_eq!(b.receive(p(3, "x", None, None)), Ok(Some((3, "x".into()))));
        assert_eq!(b.receive(p(3, "y", None, None)), Err(PartError::OutOfOrder));
        assert_eq!(b.dropped().remote_invalid, 4);
    }

    #[test]
    fn a_completed_peer_text_ends_a_local_text_being_sent() {
        let mut a = ClipboardSync::new();
        a.offer(&"o".repeat(MAX_PART_ENCODED * 3));
        a.next_part(0);
        assert!(a.sending());
        let peer = ClipboardPart { seq: 1, text: "peer".into(), offset: None, total: None };
        assert_eq!(a.receive(peer), Ok(Some((1, "peer".into()))));
        assert!(!a.sending());
        assert_eq!(a.offer("peer"), Offer::Unchanged);
    }
}
