//! A reference model of one TCP connection's two byte streams, for checking
//! any TCP implementation driven over a lossy link.
//!
//! TCP promises each direction of a connection one thing: the bytes one end
//! wrote arrive at the other end in order, exactly once, and a half-close
//! (FIN) arrives as end of stream only after all of them. Loss, reordering,
//! duplication and delay underneath may change when bytes arrive, never which
//! bytes or in what order. The oracle holds that promise and nothing else, so
//! it is the same for every stack: smoltcp, a kernel, or a model.
//!
//! The harness reports every event of the connection as it happens:
//!
//! - [`StreamOracle::wrote`]: an end's write call accepted these bytes.
//! - [`StreamOracle::shutdown`]: an end half-closed (its write side).
//! - [`StreamOracle::read`]: an end's read call returned these bytes.
//! - [`StreamOracle::eof`]: an end's read call returned end of stream.
//! - [`StreamOracle::error`]: an end's read or write failed (a reset).
//!
//! Each event is checked at once against the invariants below, and the first
//! violation comes back as a [`Violation`] naming the end, the offset and what
//! was expected, so the harness can stop and print its seed. When the run is
//! over, [`StreamOracle::finish`] checks completeness: every end whose peer
//! half-closed got every byte and then EOF.
//!
//! Per-event invariants:
//!
//! 1. Bytes read by an end are the next bytes its peer wrote: what an end has
//!    read is always a prefix of what its peer has written (in order, no
//!    duplicate, no invented byte, nothing from before the peer wrote it).
//! 2. Nothing is written after that end's shutdown.
//! 3. EOF only after the peer shut down and only once every byte the peer
//!    wrote was read; no bytes after EOF.
//! 4. With `resets_allowed` false (no end aborted and no timeout is
//!    expected), no read or write fails.
//!
//! The oracle has no clock: a harness bounds the run itself and reports a
//! hang (no completion within its bound) as its own failure.

use std::fmt;

/// One end of the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum End {
    /// The end that connected.
    Client,
    /// The end that accepted.
    Server,
}

impl End {
    /// The other end.
    pub fn peer(self) -> Self {
        match self {
            Self::Client => Self::Server,
            Self::Server => Self::Client,
        }
    }
}

/// The first broken promise, with enough to locate it in a trace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Violation {
    /// The end whose event broke the invariant.
    pub end: End,
    /// What went wrong, with offsets into the stream.
    pub what: String,
}

impl fmt::Display for Violation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.end, self.what)
    }
}

impl std::error::Error for Violation {}

#[derive(Debug, Default, Clone)]
struct Direction {
    /// Every byte the writing end's write calls accepted.
    written: Vec<u8>,
    /// The writing end half-closed.
    shut: bool,
    /// Bytes the reading end has read so far (an offset into `written`).
    read: usize,
    /// The reading end saw end of stream.
    eof: bool,
}

/// The two byte streams of one connection. See the module docs.
#[derive(Debug, Clone)]
pub struct StreamOracle {
    client_to_server: Direction,
    server_to_client: Direction,
    /// An end saw a read or write fail.
    errored: bool,
    resets_allowed: bool,
}

impl StreamOracle {
    /// A fresh connection. `resets_allowed` false makes any failed read or
    /// write a violation: no end aborts and nothing times out in the run.
    pub fn new(resets_allowed: bool) -> Self {
        Self {
            client_to_server: Direction::default(),
            server_to_client: Direction::default(),
            errored: false,
            resets_allowed,
        }
    }

    /// The direction `writer` writes into.
    fn written_by(&self, writer: End) -> &Direction {
        match writer {
            End::Client => &self.client_to_server,
            End::Server => &self.server_to_client,
        }
    }

    fn written_by_mut(&mut self, writer: End) -> &mut Direction {
        match writer {
            End::Client => &mut self.client_to_server,
            End::Server => &mut self.server_to_client,
        }
    }

    fn violation(end: End, what: String) -> Result<(), Violation> {
        Err(Violation { end, what })
    }

    /// `end`'s write call accepted `bytes`.
    pub fn wrote(&mut self, end: End, bytes: &[u8]) -> Result<(), Violation> {
        let direction = self.written_by_mut(end);
        if direction.shut && !bytes.is_empty() {
            return Self::violation(
                end,
                format!("a write accepted {} bytes after shutdown", bytes.len()),
            );
        }
        direction.written.extend_from_slice(bytes);
        Ok(())
    }

    /// `end` half-closed its write side.
    pub fn shutdown(&mut self, end: End) {
        self.written_by_mut(end).shut = true;
    }

    /// `end`'s read call returned `bytes` (non-empty).
    pub fn read(&mut self, end: End, bytes: &[u8]) -> Result<(), Violation> {
        let direction = self.written_by_mut(end.peer());
        if direction.eof {
            return Self::violation(end, format!("read {} bytes after EOF", bytes.len()));
        }
        let start = direction.read;
        let unread = direction.written.get(start..).unwrap_or_default();
        if bytes.len() > unread.len() {
            return Self::violation(
                end,
                format!(
                    "read {} bytes at offset {start}, but the peer had written only {} more",
                    bytes.len(),
                    unread.len()
                ),
            );
        }
        let mismatch = unread.iter().zip(bytes).enumerate().find(|(_, (want, got))| want != got);
        if let Some((at, (want, got))) = mismatch {
            return Self::violation(
                end,
                format!(
                    "byte at offset {} is {got:#04x}, the peer wrote {want:#04x}",
                    start.saturating_add(at)
                ),
            );
        }
        direction.read = start.saturating_add(bytes.len());
        Ok(())
    }

    /// `end`'s read call returned end of stream.
    pub fn eof(&mut self, end: End) -> Result<(), Violation> {
        let direction = self.written_by_mut(end.peer());
        if !direction.shut {
            return Self::violation(end, "EOF before the peer shut down".into());
        }
        if direction.read != direction.written.len() {
            return Self::violation(
                end,
                format!(
                    "EOF at offset {} of the {} bytes the peer wrote",
                    direction.read,
                    direction.written.len()
                ),
            );
        }
        direction.eof = true;
        Ok(())
    }

    /// `end`'s read or write failed (a reset or timeout).
    pub fn error(&mut self, end: End, what: &str) -> Result<(), Violation> {
        self.errored = true;
        if self.resets_allowed {
            return Ok(());
        }
        Self::violation(end, format!("unexpected error: {what}"))
    }

    /// Bytes `end` has read so far, and bytes its peer has written.
    pub fn progress(&self, end: End) -> (usize, usize) {
        let direction = self.written_by(end.peer());
        (direction.read, direction.written.len())
    }

    /// Whether `end` has seen EOF.
    pub fn saw_eof(&self, end: End) -> bool {
        self.written_by(end.peer()).eof
    }

    /// The run is over: every end that kept reading, whose peer shut down
    /// and neither saw an error, got every byte and EOF. `reading` says which
    /// ends kept reading to the end (an end that dropped its reader owes
    /// nothing).
    pub fn finish(&self, reading: [bool; 2]) -> Result<(), Violation> {
        let [client_reading, server_reading] = reading;
        for (end, kept_reading) in [(End::Client, client_reading), (End::Server, server_reading)] {
            let direction = self.written_by(end.peer());
            if !kept_reading || !direction.shut || self.errored {
                continue;
            }
            if !direction.eof {
                return Self::violation(
                    end,
                    format!(
                        "no EOF: read {} of the {} bytes the peer wrote and shut down",
                        direction.read,
                        direction.written.len()
                    ),
                );
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_faithful_stream_passes() {
        let mut oracle = StreamOracle::new(false);
        oracle.wrote(End::Client, b"hello ").unwrap();
        oracle.wrote(End::Client, b"world").unwrap();
        oracle.shutdown(End::Client);
        oracle.read(End::Server, b"hel").unwrap();
        oracle.read(End::Server, b"lo world").unwrap();
        oracle.eof(End::Server).unwrap();
        oracle.finish([false, true]).unwrap();
    }

    #[test]
    fn each_broken_promise_is_caught() {
        let mut oracle = StreamOracle::new(false);
        oracle.wrote(End::Client, b"abc").unwrap();
        assert!(oracle.clone().read(End::Server, b"abd").is_err(), "corruption");
        assert!(oracle.clone().read(End::Server, b"abcd").is_err(), "invented byte");
        assert!(oracle.clone().eof(End::Server).is_err(), "EOF before FIN");
        oracle.read(End::Server, b"ab").unwrap();
        assert!(oracle.clone().read(End::Server, b"b").is_err(), "duplicate");
        oracle.shutdown(End::Client);
        assert!(oracle.clone().wrote(End::Client, b"x").is_err(), "write after shutdown");
        assert!(oracle.clone().eof(End::Server).is_err(), "EOF before the last byte");
        assert!(oracle.finish([false, true]).is_err(), "no EOF at the end");
        assert!(oracle.error(End::Client, "reset").is_err(), "unexpected reset");
    }
}
