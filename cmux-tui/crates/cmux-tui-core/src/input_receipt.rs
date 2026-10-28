//! What a sender of terminal input hears about bytes that did not reach the
//! PTY at once (p05-ipc-157): the local input sink (`pty_write`) tells it
//! when queued bytes are written or will never be, and a hosted terminal's
//! host reports the same over its connection (`InputFailed`).

use crate::terminal_host_protocol::{INPUT_FAILED_OVERFLOW, INPUT_FAILED_WRITE};

/// Why input never reached the PTY (`input-failed.reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InputFailure {
    /// The backlog was full: nothing of the payload was written.
    Overflow,
    /// The PTY failed or its terminal closed.
    WriteFailed,
}

impl InputFailure {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            InputFailure::Overflow => "overflow",
            InputFailure::WriteFailed => "write_failed",
        }
    }

    /// Its code in a host's `InputFailed` frame.
    pub(crate) fn wire_code(self) -> u8 {
        match self {
            InputFailure::Overflow => INPUT_FAILED_OVERFLOW,
            InputFailure::WriteFailed => INPUT_FAILED_WRITE,
        }
    }

    /// The failure of an `InputFailed` code; `None` for a code no host sends.
    pub(crate) fn from_wire_code(code: u8) -> Option<Self> {
        match code {
            INPUT_FAILED_OVERFLOW => Some(InputFailure::Overflow),
            INPUT_FAILED_WRITE => Some(InputFailure::WriteFailed),
            _ => None,
        }
    }
}

/// Told what became of input a sender queued. A sender's queued chunks are
/// reported together: a PTY that fails with 10k queued keys of one stream
/// tells that stream once.
pub(crate) trait InputReceipt: Send + Sync {
    /// `bytes` of this sender's input will never reach the PTY.
    fn failed(&self, reason: InputFailure, bytes: usize);

    /// The last byte of one of this sender's queued chunks reached the PTY.
    fn written(&self) {}
}
