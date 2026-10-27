//! A terminal's input FIFO, and the bounded writes shared by image paste and
//! the clear-history keyboard fallback.
//!
//! Every input to one terminal takes a turn from its [`PtyInputFifo`], in
//! arrival order across connections and threads, and writes all of its
//! bytes before the next turn starts: a `send` (its text, its bytes and its
//! submit Return), an INPUT frame of an attach stream, a key the TUI types,
//! an image paste's path, a clear-history fallback key, a terminal response
//! the reader writes back. So a key typed on a stream while a 1 MiB paste
//! goes in lands before the paste or after its Return, never inside it, and
//! a bounded write that waits for the child to read keeps every later input
//! behind it. This is Chrome's one ordered input queue per widget: every
//! input event to a renderer widget leaves through that widget's
//! `InputRouterImpl`, in order (components/input/input_router_impl.cc),
//! as Ghostty writes every byte to the PTY from one writer mailbox
//! (src/termio/Exec.zig, `queueWrite`).
//!
//! A turn is a lock rank of its own ([`LockRank::PtyInput`], documented in
//! crate::lock_rank): after `Mux::state`, before the terminal and runtime
//! locks the write takes.

use std::io;
use std::os::fd::RawFd;
use std::sync::PoisonError;
use std::time::{Duration, Instant};

use cmux_threads::sync::{Condvar, Mutex};

use crate::lock_rank::{HeldRank, LockRank};

/// The rank name of a held input turn (lock-order reports).
const PTY_INPUT_LOCK_NAME: &str = "pty.input";

/// One terminal's input FIFO: turns are served in the order they were
/// taken. Shared by every view of the terminal (projected surfaces share
/// the terminal runtime that owns it).
#[derive(Default)]
pub(crate) struct PtyInputFifo {
    tickets: Mutex<Tickets>,
    /// Signalled when a turn ends and a later one waits.
    turn_ended: Condvar,
}

#[derive(Default)]
struct Tickets {
    /// The ticket the next [`PtyInputFifo::enter`] takes.
    next: u64,
    /// The ticket whose turn runs now (or runs next when none does).
    serving: u64,
    /// Turns taken but not started yet.
    waiting: usize,
}

/// A held turn of a terminal's input FIFO: the bytes written while it is
/// held reach the terminal with no other input among them. Dropping it
/// starts the next turn.
#[must_use = "the input turn ends when it is dropped"]
pub(crate) struct InputTurn<'a> {
    fifo: &'a PtyInputFifo,
    _rank: HeldRank,
}

impl PtyInputFifo {
    /// Takes the next turn and waits until every turn taken before it
    /// ended. The wait is the input's place in line, not a lock convoy: it
    /// lasts as long as the earlier inputs take to reach the terminal.
    #[track_caller]
    pub(crate) fn enter(&self) -> InputTurn<'_> {
        // Checked and raised before the wait, as a ranked mutex is.
        let wait = HeldRank::acquire(LockRank::PtyInput, PTY_INPUT_LOCK_NAME);
        let mut tickets = self.tickets.lock().unwrap_or_else(PoisonError::into_inner);
        let ticket = tickets.next;
        tickets.next = tickets.next.wrapping_add(1);
        if tickets.serving != ticket {
            tickets.waiting += 1;
            while tickets.serving != ticket {
                tickets = self.turn_ended.wait(tickets).unwrap_or_else(PoisonError::into_inner);
            }
            tickets.waiting -= 1;
        }
        drop(tickets);
        InputTurn { fifo: self, _rank: wait.held() }
    }

    /// Turns taken that have not started yet.
    #[cfg(test)]
    pub(crate) fn waiting(&self) -> usize {
        self.tickets.lock().unwrap_or_else(PoisonError::into_inner).waiting
    }
}

impl InputTurn<'_> {
    /// Whether this is a turn of `fifo`.
    pub(crate) fn is_of(&self, fifo: &PtyInputFifo) -> bool {
        std::ptr::eq(self.fifo, fifo)
    }
}

impl Drop for InputTurn<'_> {
    fn drop(&mut self) {
        let mut tickets = self.fifo.tickets.lock().unwrap_or_else(PoisonError::into_inner);
        tickets.serving = tickets.serving.wrapping_add(1);
        let waiting = tickets.waiting > 0;
        drop(tickets);
        // Every waiter checks its own ticket; no wake when none waits.
        if waiting {
            self.fifo.turn_ended.notify_all();
        }
    }
}

#[derive(Debug)]
pub(crate) struct BoundedWriteFailure {
    pub error: io::Error,
    pub delivered: usize,
}

/// Writes directly to a PTY descriptor and restores its original status flags.
/// The caller must keep the descriptor alive and hold the terminal's
/// [`InputTurn`], so no other input enters while this write waits.
/// No buffered writer flush is needed: every byte is written through the descriptor.
pub(crate) fn write_bounded(
    fd: RawFd,
    bytes: &[u8],
    timeout: Duration,
    timeout_message: &'static str,
) -> Result<(), BoundedWriteFailure> {
    let mut delivered = 0;
    let result = (|| {
        let mut nonblocking = NonblockingFdGuard::install(fd)?;
        // A timeout too large to represent never expires.
        let deadline = Instant::now().checked_add(timeout);
        while delivered < bytes.len() {
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let Some(remaining) = bytes.get(delivered..) else { break };
            let written = unsafe { libc::write(fd, remaining.as_ptr().cast(), remaining.len()) };
            if written > 0 {
                delivered += written as usize;
                continue;
            }
            if written == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "PTY write returned zero"));
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
            let wait = deadline
                .map_or(timeout, |deadline| deadline.saturating_duration_since(Instant::now()));
            if wait.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let millis = wait.as_nanos().saturating_add(999_999) / 1_000_000;
            let mut poll_fd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            let ready =
                unsafe { libc::poll(&mut poll_fd, 1, millis.clamp(1, i32::MAX as u128) as i32) };
            if ready == 0 {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            } else if poll_fd.revents & libc::POLLNVAL != 0 {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "PTY fd is invalid"));
            }
        }
        nonblocking.restore()
    })();
    result.map_err(|error| BoundedWriteFailure { error, delivered })
}

struct NonblockingFdGuard {
    fd: RawFd,
    original_flags: libc::c_int,
    restored: bool,
}

impl NonblockingFdGuard {
    fn install(fd: RawFd) -> io::Result<Self> {
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { fd, original_flags, restored: false })
    }

    fn restore(&mut self) -> io::Result<()> {
        if !self.restored {
            if unsafe { libc::fcntl(self.fd, libc::F_SETFL, self.original_flags) } < 0 {
                return Err(io::Error::last_os_error());
            }
            self.restored = true;
        }
        Ok(())
    }
}

impl Drop for NonblockingFdGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

#[cfg(test)]
#[path = "pty_write_tests.rs"]
mod tests;
