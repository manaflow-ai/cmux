//! The data plane (`dataPlane` in the JSON): per channel, in order,
//! `data {channel, offset, bytes}`, `credit {channel, direction, bytes}` and
//! exactly one `end {channel, exit? | lost?}` after the last data.

use crate::error::BackendError;

/// The first window of each direction when an answer names none.
pub const DEFAULT_WINDOW_BYTES: u32 = 256 * 1024;
/// Smallest `window_bytes` an open, resume or connect answer may give.
pub const MIN_WINDOW_BYTES: u32 = 64 * 1024;
/// Largest `window_bytes` an open, resume or connect answer may give.
pub const MAX_WINDOW_BYTES: u32 = 1024 * 1024;

/// `window_bytes` is within 64 KiB to 1 MiB.
pub fn check_window(window_bytes: u32) -> Result<u32, BackendError> {
    if (MIN_WINDOW_BYTES..=MAX_WINDOW_BYTES).contains(&window_bytes) {
        Ok(window_bytes)
    } else {
        Err(BackendError::invalid(format!(
            "window_bytes {window_bytes} is outside 64 KiB to 1 MiB"
        )))
    }
}

/// The direction a credit grant is for, seen from the implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Host to implementation: terminal input, connector viewer messages.
    In,
    /// Implementation to host: terminal output, connector viewer frames.
    Out,
}

impl Direction {
    /// The wire name (`in`, `out`).
    pub fn name(self) -> &'static str {
        match self {
            Self::In => "in",
            Self::Out => "out",
        }
    }
}

/// `lost {reason, retryable}`: the channel ended without an exit status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lost {
    pub reason: String,
    /// A new open, resume or connect may work (false: access ended, or a
    /// protocol violation such as `credit`, `gap` or `overlap`).
    pub retryable: bool,
}

impl Lost {
    pub fn new(reason: impl Into<String>, retryable: bool) -> Self {
        Self { reason: reason.into(), retryable }
    }
}

/// `exit {code?, signal?, core_dumped, message?}`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExitStatus {
    /// The exit code, when the far end sent one.
    pub code: Option<i32>,
    /// The signal name without `SIG` (SSH exit-signal or POSIX).
    pub signal: Option<String>,
    pub core_dumped: bool,
    /// Far-end text, at most [`crate::MAX_EXIT_MESSAGE`] bytes; shown, never parsed.
    pub message: Option<String>,
}

/// How a channel ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum End {
    Exit(ExitStatus),
    Lost(Lost),
}

/// One frame of one channel, without the channel id. A [`crate::ByteTerminal`],
/// a [`crate::HostLink`] or a host channel is one channel, so its frames are
/// bodies; the stream bridge adds the host-assigned id ([`Frame`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameBody {
    /// `offset` is the running byte total of this direction after this
    /// frame; a resumed terminal continues it.
    Data { offset: u64, bytes: Vec<u8> },
    /// The receiver grants `bytes` more of `direction`.
    Credit { direction: Direction, bytes: u32 },
    /// Exactly once per channel, after its last data.
    End(End),
}

/// A frame on the app host's stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// The host-assigned channel id.
    pub channel: String,
    pub body: FrameBody,
}
