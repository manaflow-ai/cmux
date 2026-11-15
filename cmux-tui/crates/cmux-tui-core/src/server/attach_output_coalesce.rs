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
    fn the_interval_needs_the_capability() {
        assert_eq!(attach_interval(false, None).unwrap(), None);
        assert_eq!(attach_interval(false, Some(30)).unwrap(), None);
        assert_eq!(attach_interval(true, None).unwrap(), Some(OUTPUT_COALESCE_DEFAULT));
        assert_eq!(attach_interval(true, Some(0)).unwrap(), None);
        assert_eq!(attach_interval(true, Some(8)).unwrap(), Some(Duration::from_millis(8)));
        assert!(attach_interval(true, Some(OUTPUT_COALESCE_MAX_MS + 1)).is_err());
    }
}
