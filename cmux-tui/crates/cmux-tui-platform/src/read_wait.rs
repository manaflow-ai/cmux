//! A read timeout for a test's socket whose peer can have closed first.
//!
//! macOS refuses `SO_RCVTIMEO` with `EINVAL` (os error 22) on a socket that
//! can send no more and receive no more: its peer closed, or each side ended
//! its writes. Linux accepts the call. So a test that sets a read timeout
//! after its peer can have closed passes on Linux and fails on macOS, by the
//! order of two processes.

use std::io;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use crate::platform::transport::Stream;

/// What [`read_timeout_or_ended`] left on the socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadWait {
    /// The timeout is set: a read waits at most that long.
    Timed,
    /// The system refused the timeout and the socket can receive no more:
    /// each read returns at once, with what is left and then the end (or
    /// the error of the socket).
    Ended,
}

/// Sets the read timeout of a test's socket whose peer can have closed
/// first. Use it in the place of `set_read_timeout(..).unwrap()` when the
/// peer can close, or each side can end its writes, before the call.
///
/// A refusal is [`ReadWait::Ended`] only when a poll that does not block
/// says that the socket can receive no more. No read can wait then, so the
/// test needs no timeout. A refusal on a socket that can still receive is an
/// error: a read there could wait with no limit, and the fault is the test's
/// (a zero timeout, for example).
///
/// The call changes nothing but the timeout. It sets no nonblocking flag:
/// that flag is on the file description that every clone of the socket
/// shares, so it would reach a reader thread or a writer thread that holds
/// a clone. The timeout is a property of the socket: a clone gets it too, as
/// with `set_read_timeout`.
///
/// Test support only: the module is in this crate's own tests and behind
/// the `test-support` feature, which a dependent enables only from
/// `[dev-dependencies]`, so no production build contains this function.
pub fn read_timeout_or_ended(stream: &UnixStream, timeout: Duration) -> io::Result<ReadWait> {
    settle(stream, stream.set_read_timeout(Some(timeout)))
}

fn settle(stream: &UnixStream, set: io::Result<()>) -> io::Result<ReadWait> {
    let Err(refused) = set else {
        return Ok(ReadWait::Timed);
    };
    if ended(stream) {
        return Ok(ReadWait::Ended);
    }
    Err(io::Error::new(
        refused.kind(),
        format!("a read timeout was refused on a socket that is open: {refused}"),
    ))
}

/// Whether a poll that never blocks says that `stream` can receive no more:
/// a hang-up or an error of the socket ([`Stream::peer_closed`], the poll
/// that the daemon uses). On Linux a peer that only ended its writes gives
/// no hang-up, so this is `false` there; Linux does not refuse the timeout
/// on such a socket, so no real refusal reaches this poll with that state.
fn ended(stream: &UnixStream) -> bool {
    Stream::peer_closed(stream)
}

#[cfg(test)]
mod tests;
