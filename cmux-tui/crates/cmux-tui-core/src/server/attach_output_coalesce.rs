//! `attach-output-coalesce-v1`: a byte attach whose connection declared the
//! capability gets its `output` events at most once per frame interval, as
//! a browser coalesces a page's work to one frame per display refresh.
//!
//! Today's byte attach sends one `output` event per PTY read: a build log at
//! 200 lines a second is about 200 events a second and `yes` tens of
//! thousands, each one a wakeup on the viewer (a phone). The coalescer holds
//! the bytes that arrive within one interval of the last event and sends them
//! as one event at the interval's end, in order.
//!
//! - Leading edge: the first bytes after an idle gap of at least one interval
//!   go out at once, so a keypress echo is not delayed.
//! - A byte cap per event (`OUTPUT_COALESCE_MAX_BYTES`): the held bytes go
//!   out at once when they reach it, so a flood never builds a buffer past
//!   it. A viewer that cannot read that fast backs up its socket and gets the
//!   existing `overflow` (reattach), as today.
//! - Any other attach event (`resized`, `colors-changed`, an `output` that
//!   carries `colors`) first sends the held bytes, so stream order holds.
//!
//! The interval only applies to `output` events of the plain byte attach
//! (`mode:"bytes"` without `snapshot`). Render mode and snapshot viewers are
//! unchanged. A connection that does not declare the capability gets today's
//! stream, one event per read.

use std::time::{Duration, Instant};

use crate::surface::AttachFrame;

/// Advertised in `identify`; a client declares it in `set-client-info` before
/// `attach-surface` to opt in.
pub const ATTACH_OUTPUT_COALESCE_CAPABILITY: &str = "attach-output-coalesce-v1";

/// One frame at 60 Hz: the default interval.
pub(super) const OUTPUT_COALESCE_DEFAULT: Duration = Duration::from_micros(16_667);

/// The largest `output_coalesce_ms` an attach may ask for.
pub(super) const OUTPUT_COALESCE_MAX_MS: u32 = 1_000;

/// Held bytes past this go out at once (one event carries at most about this
/// many bytes plus the last read).
pub(super) const OUTPUT_COALESCE_MAX_BYTES: usize = 1 << 20;

/// The interval of one attach: `None` keeps today's stream (no capability, or
/// `output_coalesce_ms: 0`).
pub(super) fn attach_interval(
    declared: bool,
    requested_ms: Option<u32>,
) -> anyhow::Result<Option<Duration>> {
    if !declared {
        // A client that did not opt in keeps today's stream byte for byte;
        // the field alone changes nothing.
        return Ok(None);
    }
    match requested_ms {
        None => Ok(Some(OUTPUT_COALESCE_DEFAULT)),
        Some(0) => Ok(None),
        Some(ms) if ms <= OUTPUT_COALESCE_MAX_MS => Ok(Some(Duration::from_millis(u64::from(ms)))),
        Some(ms) => {
            anyhow::bail!("invalid: output_coalesce_ms {ms} is over {OUTPUT_COALESCE_MAX_MS}")
        }
    }
}

/// The per-attach state: the bytes held for the next event and when the last
/// event went out.
pub(super) struct OutputCoalescer {
    interval: Duration,
    max_bytes: usize,
    pending: Vec<u8>,
    last_sent: Option<Instant>,
}

impl OutputCoalescer {
    pub(super) fn new(interval: Duration) -> Self {
        Self::with_max_bytes(interval, OUTPUT_COALESCE_MAX_BYTES)
    }

    pub(super) fn with_max_bytes(interval: Duration, max_bytes: usize) -> Self {
        Self { interval, max_bytes, pending: Vec::new(), last_sent: None }
    }

    /// When the held bytes are due; `None` when nothing is held.
    pub(super) fn due(&self) -> Option<Instant> {
        if self.pending.is_empty() {
            return None;
        }
        Some(self.last_sent.map_or_else(Instant::now, |sent| sent + self.interval))
    }

    /// Takes `frame` at `now` and pushes what goes out now onto `out`, in
    /// order.
    pub(super) fn push(&mut self, frame: AttachFrame, now: Instant, out: &mut Vec<AttachFrame>) {
        match frame {
            AttachFrame::Output(bytes) => {
                if bytes.is_empty() {
                    return;
                }
                let idle = self.last_sent.is_none_or(|sent| now >= sent + self.interval);
                if self.pending.is_empty() && idle {
                    // Leading edge: the first bytes after an idle interval.
                    self.last_sent = Some(now);
                    out.push(AttachFrame::Output(bytes));
                    return;
                }
                if self.pending.is_empty() {
                    self.pending = bytes;
                } else {
                    self.pending.extend_from_slice(&bytes);
                }
                if self.pending.len() >= self.max_bytes {
                    self.take_pending(now, out);
                }
            }
            other => {
                self.take_pending(now, out);
                if matches!(other, AttachFrame::OutputWithColors { .. }) {
                    self.last_sent = Some(now);
                }
                out.push(other);
            }
        }
    }

    /// The held bytes as one event when they are due at `now`.
    pub(super) fn flush_due(&mut self, now: Instant, out: &mut Vec<AttachFrame>) {
        if self.due().is_some_and(|due| now >= due) {
            self.take_pending(now, out);
        }
    }

    /// The held bytes as one event now (the terminal ended).
    pub(super) fn flush(&mut self, now: Instant, out: &mut Vec<AttachFrame>) {
        self.take_pending(now, out);
    }

    fn take_pending(&mut self, now: Instant, out: &mut Vec<AttachFrame>) {
        if self.pending.is_empty() {
            return;
        }
        self.last_sent = Some(now);
        out.push(AttachFrame::Output(std::mem::take(&mut self.pending)));
    }
}

/// The most bytes one drain (`drain_merged`) merges into one `output` event: the phone's batch
/// size, so a backlog goes out as phone-sized events and the writer sends between them.
pub(super) const DRAIN_MAX_BYTES: usize = 256 * 1024;

/// The plain byte attach (no timer) once its writer frees, for the reads already pending:
/// `first` and then `next()` merge into one `output` event of at most `max_bytes` (a single
/// read over it goes alone, unsplit). The drain stops at the first frame that does not merge
/// (another kind of event, or a read past the cap): that frame goes out as its own event and
/// whatever is still queued waits for the next drain. So one drain pushes at most two frames
/// and holds at most `max_bytes` plus one read. Same bytes, same order.
pub(super) fn drain_merged(
    first: AttachFrame,
    mut next: impl FnMut() -> Option<AttachFrame>,
    max_bytes: usize,
    out: &mut Vec<AttachFrame>,
) {
    let AttachFrame::Output(mut merged) = first else {
        out.push(first);
        return;
    };
    while merged.len() < max_bytes {
        let Some(frame) = next() else { break };
        match frame {
            AttachFrame::Output(bytes) if merged.len() + bytes.len() <= max_bytes => {
                merged.extend_from_slice(&bytes);
            }
            other => {
                out.push(AttachFrame::Output(merged));
                out.push(other);
                return;
            }
        }
    }
    out.push(AttachFrame::Output(merged));
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: Duration = Duration::from_millis(16);

    fn bytes(frames: &[AttachFrame]) -> Vec<Vec<u8>> {
        frames
            .iter()
            .map(|frame| match frame {
                AttachFrame::Output(bytes) => bytes.clone(),
                _ => b"<other>".to_vec(),
            })
            .collect()
    }

    #[test]
    fn the_first_bytes_after_idle_go_out_at_once() {
        let mut coalescer = OutputCoalescer::new(FRAME);
        let start = Instant::now();
        let mut out = Vec::new();
        coalescer.push(AttachFrame::Output(b"a".to_vec()), start, &mut out);
        assert_eq!(bytes(&out), vec![b"a".to_vec()]);
        assert_eq!(coalescer.due(), None);
        // A whole interval later: the leading edge again.
        out.clear();
        coalescer.push(AttachFrame::Output(b"b".to_vec()), start + FRAME, &mut out);
        assert_eq!(bytes(&out), vec![b"b".to_vec()]);
    }

    #[test]
    fn bytes_within_an_interval_go_out_as_one_event_at_its_end() {
        let mut coalescer = OutputCoalescer::new(FRAME);
        let start = Instant::now();
        let mut out = Vec::new();
        coalescer.push(AttachFrame::Output(b"1".to_vec()), start, &mut out);
        out.clear();
        for (ms, chunk) in [(2u64, b"2"), (5, b"3"), (9, b"4")] {
            coalescer.push(
                AttachFrame::Output(chunk.to_vec()),
                start + Duration::from_millis(ms),
                &mut out,
            );
        }
        assert!(out.is_empty(), "held until the interval ends");
        assert_eq!(coalescer.due(), Some(start + FRAME));
        coalescer.flush_due(start + Duration::from_millis(15), &mut out);
        assert!(out.is_empty(), "not due yet");
        coalescer.flush_due(start + FRAME, &mut out);
        assert_eq!(bytes(&out), vec![b"234".to_vec()]);
        // The next bytes within an interval of that event wait for the next end.
        out.clear();
        coalescer.push(
            AttachFrame::Output(b"5".to_vec()),
            start + FRAME + Duration::from_millis(1),
            &mut out,
        );
        assert!(out.is_empty());
        assert_eq!(coalescer.due(), Some(start + FRAME + FRAME));
    }

    #[test]
    fn another_event_sends_the_held_bytes_first() {
        let mut coalescer = OutputCoalescer::new(FRAME);
        let start = Instant::now();
        let mut out = Vec::new();
        coalescer.push(AttachFrame::Output(b"a".to_vec()), start, &mut out);
        coalescer.push(
            AttachFrame::Output(b"b".to_vec()),
            start + Duration::from_millis(1),
            &mut out,
        );
        let colors =
            AttachFrame::ColorsChanged(std::sync::Arc::new(crate::TerminalColors::default()));
        coalescer.push(colors, start + Duration::from_millis(2), &mut out);
        assert_eq!(bytes(&out), vec![b"a".to_vec(), b"b".to_vec(), b"<other>".to_vec()]);
        assert_eq!(coalescer.due(), None);
    }

    #[test]
    fn held_bytes_go_out_at_the_cap() {
        let mut coalescer = OutputCoalescer::with_max_bytes(FRAME, 8);
        let start = Instant::now();
        let mut out = Vec::new();
        coalescer.push(AttachFrame::Output(b"x".to_vec()), start, &mut out);
        out.clear();
        coalescer.push(AttachFrame::Output(b"12345".to_vec()), start, &mut out);
        assert!(out.is_empty());
        coalescer.push(AttachFrame::Output(b"6789".to_vec()), start, &mut out);
        assert_eq!(bytes(&out), vec![b"123456789".to_vec()]);
        assert_eq!(coalescer.due(), None);
    }

    #[test]
    fn a_drain_past_the_cap_splits_into_events_under_it_in_order() {
        const CAP: usize = 1000;
        // 50 reads of 97 bytes each (4850 bytes, almost five caps), every byte numbered.
        let burst: Vec<u8> = (0..50 * 97).map(|i| (i % 251) as u8).collect();
        let mut queue: std::collections::VecDeque<AttachFrame> =
            burst.chunks(97).map(|read| AttachFrame::Output(read.to_vec())).collect();
        let mut sent = Vec::new();
        while let Some(first) = queue.pop_front() {
            let mut ready = Vec::new();
            drain_merged(first, || queue.pop_front(), CAP, &mut ready);
            assert!(ready.len() <= 2, "one drain pushes at most two frames");
            sent.extend(ready);
        }
        let events = bytes(&sent);
        assert!(events.len() > 1, "the burst split");
        assert!(events.iter().all(|event| event.len() <= CAP), "each event is under the cap");
        assert_eq!(events.concat(), burst, "every byte, in order");
        assert_eq!(events.len(), 5, "10 reads per event");

        // The real cap: a 1 MiB burst of 16 KiB reads goes out as four 256 KiB events.
        let burst: Vec<u8> = (0..1 << 20).map(|i| (i % 253) as u8).collect();
        let mut queue: std::collections::VecDeque<AttachFrame> =
            burst.chunks(16 * 1024).map(|read| AttachFrame::Output(read.to_vec())).collect();
        let mut sent = Vec::new();
        while let Some(first) = queue.pop_front() {
            drain_merged(first, || queue.pop_front(), DRAIN_MAX_BYTES, &mut sent);
        }
        let events = bytes(&sent);
        assert_eq!(events.len(), 4);
        assert!(events.iter().all(|event| event.len() <= DRAIN_MAX_BYTES));
        assert_eq!(events.concat(), burst);
    }

    #[test]
    fn a_drain_stops_at_another_event_and_a_big_read_goes_alone() {
        let colors =
            AttachFrame::ColorsChanged(std::sync::Arc::new(crate::TerminalColors::default()));
        let mut queue: std::collections::VecDeque<AttachFrame> = [
            AttachFrame::Output(b"b".to_vec()),
            colors,
            AttachFrame::Output(b"c".to_vec()),
            AttachFrame::Output(vec![b'x'; 20]),
        ]
        .into();
        let mut out = Vec::new();
        drain_merged(AttachFrame::Output(b"a".to_vec()), || queue.pop_front(), 10, &mut out);
        assert_eq!(bytes(&out), [b"ab".to_vec(), b"<other>".to_vec()]);
        assert_eq!(queue.len(), 2, "the rest waits for the next drain");
        out.clear();
        let first = queue.pop_front().unwrap();
        drain_merged(first, || queue.pop_front(), 10, &mut out);
        assert_eq!(bytes(&out), [b"c".to_vec(), vec![b'x'; 20]]);
    }

    #[test]
    fn the_interval_needs_the_capability() {
        assert_eq!(attach_interval(false, None).unwrap(), None);
        assert_eq!(attach_interval(false, Some(30)).unwrap(), None);
        assert_eq!(attach_interval(true, None).unwrap(), Some(OUTPUT_COALESCE_DEFAULT));
        assert_eq!(attach_interval(true, Some(0)).unwrap(), None);
        assert_eq!(attach_interval(true, Some(8)).unwrap(), Some(Duration::from_millis(8)));
        assert!(attach_interval(true, Some(OUTPUT_COALESCE_MAX_MS + 1)).is_err());
    }
}
