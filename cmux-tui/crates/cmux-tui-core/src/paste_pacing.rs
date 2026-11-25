//! Input that follows a paste reaches the program in its own read, after the program read the paste.
//!
//! Leo, 2026-11-21: "it also just didnt send my s*** when i put it at the bottoma" (the phone's bottom
//! composer). The composer sends its draft as one bracketed paste and Return as its own key, but both left the
//! PTY writer back to back. macOS gives a PTY child an input queue of 1022 bytes, so a multi-KB paste is read in
//! about 1 KB pieces while the writer blocks, and a Return written as soon as that write returns lands in the queue
//! right behind the paste's last piece and its end marker (`ESC [201~`). An agent TUI that joins the reads of a
//! paste arriving close together (Claude Code, Codex) took the Return as part of the paste: the prompt stayed a
//! draft. A Return in the very same write as the paste (a phone batch that held both) went the same way.
//!
//! So every PTY writer (a terminal host, and the daemon's own PTY) writes through a [`PastePacer`]:
//!
//! - A write is cut after each paste end marker it holds: the bytes after it are a write of their own.
//! - Bytes that follow a paste (a paste frame, or bytes ending in the end marker) wait until the program read the
//!   whole paste (the child's input queue is empty, `FIONREAD` on macOS; at most [`DRAIN_LIMIT`]), then
//!   [`SETTLE`] more, and are written then. Without a queue count (off macOS) they wait [`SETTLE`] after the
//!   paste's write.
//! - Nothing else waits: a key long after a paste, or with no paste before it, is written at once.
//!
//! The submit of every sender is paced the same way: the phone's composer, a Feed or notification reply (the
//! daemon's `send` with `submit`), `cmux terminal send` and a paste typed into the Mac's own terminal.

use std::time::{Duration, Instant};

/// The bracketed paste end marker.
pub(crate) const PASTE_END: &[u8] = b"\x1b[201~";
/// How long input waits after the program read a paste: past the window in which an agent TUI joins reads that
/// arrive close together into one paste (about 100 ms), with room for a loaded Mac.
pub(crate) const SETTLE: Duration = Duration::from_millis(200);
/// The longest input waits for a program to read a paste: one that stopped reading gets its input anyway.
pub(crate) const DRAIN_LIMIT: Duration = Duration::from_secs(2);
/// How often the child's input queue is checked while a paste is still being read.
const POLL: Duration = Duration::from_millis(5);

/// What the pacer waits with (tests drive a fake one).
pub(crate) trait PaceClock {
    fn now(&self) -> Instant;
    fn sleep(&mut self, duration: Duration);
}

/// The real clock: the writer's thread sleeps.
pub(crate) struct SystemClock;

impl PaceClock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn sleep(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// One PTY's pacing state: when its last paste was written, until the next input waited for it.
#[derive(Default, Debug)]
pub(crate) struct PastePacer {
    paste_written_at: Option<Instant>,
}

impl PastePacer {
    /// A paste was written just now (a paste frame, whose markers the writer added).
    pub(crate) fn paste_written(&mut self, clock: &impl PaceClock) {
        self.paste_written_at = Some(clock.now());
    }

    /// Before input: waits until the program read the paste written before it, then [`SETTLE`] more. `unread` is
    /// the bytes the child has not read yet, or `None` when the PTY cannot say. Returns what it waited.
    pub(crate) fn settle(
        &mut self,
        unread: &mut dyn FnMut() -> Option<usize>,
        clock: &mut impl PaceClock,
    ) -> Duration {
        let Some(written) = self.paste_written_at.take() else {
            return Duration::ZERO;
        };
        let start = clock.now();
        let deadline = written + DRAIN_LIMIT;
        let mut drained_late = false;
        while unread().is_some_and(|pending| pending > 0) {
            let now = clock.now();
            if now >= deadline {
                break;
            }
            clock.sleep(POLL.min(deadline - now));
            drained_late = true;
        }
        // Read by the time the input came: the settle counts from the paste's write.
        let ready = if drained_late { clock.now() } else { written } + SETTLE;
        let now = clock.now();
        if ready > now {
            clock.sleep(ready - now);
        }
        clock.now().saturating_duration_since(start)
    }

    /// Writes `payload` with `write`, cut after each paste end marker in it, each piece after [`Self::settle`].
    pub(crate) fn write<E>(
        &mut self,
        payload: &[u8],
        unread: &mut dyn FnMut() -> Option<usize>,
        clock: &mut impl PaceClock,
        write: &mut dyn FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), E> {
        for piece in pieces(payload) {
            self.settle(unread, clock);
            write(piece)?;
            if piece.ends_with(PASTE_END) {
                self.paste_written(clock);
            }
        }
        Ok(())
    }
}

/// `payload` cut after each paste end marker: every piece but the last ends with one.
pub(crate) fn pieces(payload: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut rest = payload;
    std::iter::from_fn(move || {
        if rest.is_empty() {
            return None;
        }
        let cut = rest
            .windows(PASTE_END.len())
            .position(|window| window == PASTE_END)
            .map_or(rest.len(), |at| at + PASTE_END.len());
        let (piece, tail) = rest.split_at(cut);
        rest = tail;
        Some(piece)
    })
}

#[cfg(test)]
#[path = "paste_pacing_tests.rs"]
mod tests;
