//! The output of one terminal: bytes with running offsets, then at most one
//! end event (exit or lost).
//!
//! Bounds (README, "Resume"):
//! - at most [`MAX_UNREAD`] bytes wait for the session host. The session
//!   asks the host channel for no more than the free room, so the rest of a
//!   flood stays in the host (the host's own bounded buffer and SSH flow
//!   control stop the far end). Bytes are never dropped while the terminal
//!   is open.
//! - at most [`RETAINED`] already delivered bytes stay for `resume`. Older
//!   bytes are gone; a resume from before them gives `lost`.

use crate::iface::ByteEvent;
use std::collections::VecDeque;

pub const MAX_UNREAD: usize = 64 * 1024;
pub const RETAINED: usize = 64 * 1024;

pub struct Output {
    bytes: VecDeque<u8>,
    /// Offset of `bytes[0]`.
    start: u64,
    /// Next offset the attached terminal gets.
    delivered: u64,
    end: Option<ByteEvent>,
    end_delivered: bool,
    attached: bool,
    /// Closed by the session host: bytes are discarded, nobody reads.
    closed: bool,
}

impl Default for Output {
    fn default() -> Self {
        Self {
            bytes: VecDeque::new(),
            start: 0,
            delivered: 0,
            end: None,
            end_delivered: false,
            attached: true,
            closed: false,
        }
    }
}

impl Output {
    fn end_offset(&self) -> u64 {
        self.start + self.bytes.len() as u64
    }

    fn unread(&self) -> usize {
        (self.end_offset() - self.delivered) as usize
    }

    fn trim(&mut self) {
        let kept = (self.delivered - self.start) as usize;
        if kept > RETAINED {
            let drop = kept - RETAINED;
            self.bytes.drain(..drop);
            self.start += drop as u64;
        }
    }

    /// How many more far-end bytes may wait now. Zero after the end or a close.
    pub fn room(&self) -> usize {
        if self.closed || self.end.is_some() {
            0
        } else {
            MAX_UNREAD - self.unread().min(MAX_UNREAD)
        }
    }

    /// Appends far-end bytes. The caller asked for at most [`Self::room`].
    pub fn push(&mut self, data: &[u8]) {
        if !self.closed {
            self.bytes.extend(data);
        }
    }

    /// Records the end event once. Later calls do nothing.
    pub fn finish(&mut self, event: ByteEvent) {
        if self.end.is_none() {
            self.end = Some(event);
        }
    }

    pub fn has_ended(&self) -> bool {
        self.end.is_some()
    }

    /// Ended, and no attached terminal still waits for the end event.
    pub fn is_finished(&self) -> bool {
        self.end.is_some() && (self.end_delivered || !self.attached)
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// Everything new for the attached terminal, in order. One output event
    /// carries the offset after its bytes.
    pub fn take(&mut self) -> Vec<ByteEvent> {
        let mut events = Vec::new();
        if !self.attached {
            return events;
        }
        if self.unread() > 0 {
            let from = (self.delivered - self.start) as usize;
            let bytes = self.bytes.range(from..).copied().collect();
            self.delivered = self.end_offset();
            events.push(ByteEvent::Output { offset: self.delivered, bytes });
            self.trim();
        }
        if !self.end_delivered
            && let Some(end) = self.end.clone()
        {
            events.push(end);
            self.end_delivered = true;
        }
        events
    }

    /// The next offset the attached terminal gets (for the resume token).
    pub fn delivered(&self) -> u64 {
        self.delivered
    }

    pub fn detach(&mut self) {
        self.attached = false;
    }

    /// The terminal is closed: drop kept bytes; nobody reads again.
    pub fn close(&mut self) {
        self.closed = true;
        self.attached = false;
        self.bytes.clear();
        self.start = self.delivered;
    }

    /// Attaches again from `offset`. False when `offset` is outside the kept
    /// bytes or a terminal is still attached.
    pub fn attach_at(&mut self, offset: u64) -> bool {
        if self.attached || self.closed || offset < self.start || offset > self.end_offset() {
            return false;
        }
        self.delivered = offset;
        self.end_delivered = false;
        self.attached = true;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::iface::ExitStatus;

    #[test]
    fn room_shrinks_with_unread_bytes_and_comes_back_after_take() {
        let mut out = Output::default();
        assert_eq!(out.room(), MAX_UNREAD);
        out.push(&vec![b'a'; MAX_UNREAD]);
        assert_eq!(out.room(), 0, "the session asks the host for nothing more");
        let events = out.take();
        assert!(matches!(events.as_slice(), [ByteEvent::Output { offset, bytes }]
            if *offset == MAX_UNREAD as u64 && bytes.len() == MAX_UNREAD));
        assert_eq!(out.room(), MAX_UNREAD);
    }

    #[test]
    fn offsets_run_on_over_chunks() {
        let mut out = Output::default();
        out.push(b"abc");
        out.take();
        out.push(b"de");
        assert_eq!(out.take(), vec![ByteEvent::Output { offset: 5, bytes: b"de".to_vec() }]);
    }

    #[test]
    fn resume_replays_only_the_retained_window() {
        let mut out = Output::default();
        for _ in 0..3 {
            out.push(&vec![b'x'; MAX_UNREAD]);
            out.take();
        }
        let end = out.delivered();
        out.detach();
        assert!(!out.attach_at(0), "bytes older than RETAINED are gone");
        assert!(out.attach_at(end - RETAINED as u64));
        assert!(!out.attach_at(end), "one terminal attached at a time");
    }

    #[test]
    fn the_end_event_comes_once_after_all_bytes() {
        let mut out = Output::default();
        out.push(b"bye");
        out.finish(ByteEvent::Exit(ExitStatus { code: Some(0), ..Default::default() }));
        out.finish(ByteEvent::Lost { reason: "late".into(), retryable: true });
        assert_eq!(out.room(), 0, "nothing is read after the end");
        let events = out.take();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0], ByteEvent::Output { offset: 3, bytes: b"bye".to_vec() });
        assert!(matches!(events[1], ByteEvent::Exit(_)));
        assert!(out.take().is_empty());
    }

    #[test]
    fn close_discards_bytes_and_refuses_resume() {
        let mut out = Output::default();
        out.push(b"abc");
        out.close();
        out.push(b"d");
        assert!(out.take().is_empty());
        assert!(!out.attach_at(0), "a closed terminal cannot be resumed");
    }
}
