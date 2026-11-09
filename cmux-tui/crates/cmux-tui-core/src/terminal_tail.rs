//! Terminal tail pins (`terminal-tail-pin-v1`): the last non-empty line a
//! pinned terminal printed, for the one-line ticker under its workspace in
//! the sidebar (`mux/terminal_tail_pins.rs` publishes it).
//!
//! The tracker reads raw output as the reader gets it. A line ends at `\n`
//! or `\r`, so a progress bar that redraws its line after `\r` shows its
//! newest frame. Escapes are stripped, tabs become spaces, other control
//! characters are dropped and runs of spaces fold to one. A line that is
//! blank after that never replaces the tail. A line keeps at most its first
//! `MAX_LINE_BYTES`; the shown tail is cut to `MAX_TAIL_CHARS` and
//! `MAX_TAIL_BYTES`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Raw bytes one line keeps before its end; the rest of the line is dropped.
pub(crate) const MAX_LINE_BYTES: usize = 1024;
/// The tail is cut to this many chars (a status entry takes 512 bytes; the
/// sidebar row shows far fewer).
pub(crate) const MAX_TAIL_CHARS: usize = 160;
/// And to this many bytes, under the status store's 512-byte text limit
/// (`MAX_STATUS_TEXT_BYTES`), so a wide line is cut, never refused.
pub(crate) const MAX_TAIL_BYTES: usize = 480;
const _: () = assert!(MAX_TAIL_BYTES <= crate::state::workspace_status_store::MAX_STATUS_TEXT_BYTES);
/// A pinned terminal publishes its tail at most this often.
pub(crate) const PUBLISH_INTERVAL: Duration = Duration::from_millis(500);

/// A terminal runtime's pin. Unpinned, the output reader pays one relaxed
/// load per chunk and nothing else.
#[derive(Debug, Default)]
pub(crate) struct TailPinSlot {
    pinned: AtomicBool,
    /// A publication of this terminal is queued and has not taken the tail
    /// yet: further output only updates the line.
    queued: AtomicBool,
    line: Mutex<TailLine>,
}

impl TailPinSlot {
    /// Feeds output of a pinned terminal. True when the reader should queue
    /// a publication (the tail changed and none is queued).
    pub(crate) fn feed(&self, bytes: &[u8]) -> bool {
        if !self.pinned.load(Ordering::Relaxed) || bytes.is_empty() {
            return false;
        }
        let changed = self.line.lock().unwrap_or_else(PoisonError::into_inner).feed(bytes);
        changed && !self.queued.swap(true, Ordering::AcqRel)
    }

    /// Pins with `seed` (the screen's last line) as the first tail, or
    /// unpins and forgets the line. Returns whether the pin changed.
    pub(crate) fn set_pinned(&self, pinned: bool, seed: Option<&str>) -> bool {
        let mut line = self.line.lock().unwrap_or_else(PoisonError::into_inner);
        let was = self.pinned.swap(pinned, Ordering::AcqRel);
        if was == pinned {
            return false;
        }
        *line = TailLine::default();
        if let Some(seed) = seed.filter(|_| pinned) {
            line.feed(seed.as_bytes());
            line.feed(b"\n");
        }
        self.queued.store(false, Ordering::Release);
        true
    }

    /// Publish the current tail again on the next take (its row moved).
    pub(crate) fn mark_changed(&self) {
        let mut line = self.line.lock().unwrap_or_else(PoisonError::into_inner);
        line.changed = line.tail.is_some();
    }

    pub(crate) fn is_pinned(&self) -> bool {
        self.pinned.load(Ordering::Relaxed)
    }

    /// The publisher's take: the changed tail, if any. Output after this
    /// queues the next publication.
    pub(crate) fn take_change(&self) -> Option<String> {
        let mut line = self.line.lock().unwrap_or_else(PoisonError::into_inner);
        self.queued.store(false, Ordering::Release);
        if !self.pinned.load(Ordering::Relaxed) {
            return None;
        }
        line.take_change()
    }
}

/// One pinned terminal's last line.
#[derive(Debug, Default)]
pub(crate) struct TailLine {
    /// The raw bytes of the line being printed, up to `MAX_LINE_BYTES`.
    pending: Vec<u8>,
    tail: Option<String>,
    /// The tail changed since the last `take_change`.
    changed: bool,
}

impl TailLine {
    /// Feeds raw output. Returns whether the tail has a change to take.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> bool {
        let mut segments = bytes.split(|byte| matches!(byte, b'\n' | b'\r')).peekable();
        while let Some(segment) = segments.next() {
            let room = MAX_LINE_BYTES.saturating_sub(self.pending.len());
            self.pending.extend_from_slice(&segment[..segment.len().min(room)]);
            if segments.peek().is_some() {
                self.end_line();
            }
        }
        self.changed
    }

    fn end_line(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let line = clean_line(&String::from_utf8_lossy(&self.pending));
        self.pending.clear();
        if line.is_empty() || self.tail.as_deref() == Some(line.as_str()) {
            return;
        }
        self.tail = Some(line);
        self.changed = true;
    }

    /// The tail, if it changed since the last call.
    pub(crate) fn take_change(&mut self) -> Option<String> {
        if !std::mem::take(&mut self.changed) {
            return None;
        }
        self.tail.clone()
    }

    #[cfg(test)]
    pub(crate) fn tail(&self) -> Option<&str> {
        self.tail.as_deref()
    }
}

/// One output line as the ticker shows it: no escapes or control
/// characters, one space between words, at most `MAX_TAIL_CHARS`.
pub(crate) fn clean_line(raw: &str) -> String {
    let stripped = cmux_local_url::strip_ansi(raw);
    let mut out = String::with_capacity(stripped.len().min(MAX_TAIL_CHARS * 4));
    let mut chars = 0;
    for ch in stripped.chars() {
        let ch = if ch == '\t' { ' ' } else { ch };
        if ch.is_control() || (ch == ' ' && (out.is_empty() || out.ends_with(' '))) {
            continue;
        }
        if chars == MAX_TAIL_CHARS || out.len() + ch.len_utf8() > MAX_TAIL_BYTES {
            break;
        }
        out.push(ch);
        chars += 1;
    }
    out.truncate(out.trim_end().len());
    out
}

/// When a pinned terminal may publish next: at once after a quiet
/// `PUBLISH_INTERVAL`, else when the interval since the last one ends.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct Throttle {
    last: Option<Instant>,
}

impl Throttle {
    pub(crate) fn next_at(&self, now: Instant) -> Instant {
        match self.last {
            Some(last) => (last + PUBLISH_INTERVAL).max(now),
            None => now,
        }
    }

    pub(crate) fn ran(&mut self, at: Instant) {
        self.last = Some(at);
    }
}

#[cfg(test)]
#[path = "terminal_tail_tests.rs"]
mod tests;
