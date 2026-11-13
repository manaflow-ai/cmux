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
/// Test support only: every dependent enables `test-support` from
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

/// Whether a poll that never blocks says that `stream` can receive no more.
fn ended(stream: &UnixStream) -> bool {
    let mut poll = libc::pollfd {
        fd: std::os::fd::AsRawFd::as_raw_fd(stream),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one pollfd for a descriptor this stream owns; a zero timeout
    // never blocks.
    let ready = unsafe { libc::poll(&mut poll, 1, 0) };
    ready > 0 && poll.revents & (libc::POLLHUP | libc::POLLERR) != 0
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    use super::{ReadWait, read_timeout_or_ended, settle};

    /// Longer than a loaded host needs for a read that does not wait.
    const WAIT: Duration = Duration::from_secs(30);

    fn refusal() -> std::io::Result<()> {
        Err(std::io::Error::from_raw_os_error(libc::EINVAL))
    }

    #[test]
    fn read_wait_a_peer_that_closed_first_gives_the_end() {
        let (mut near, far) = UnixStream::pair().unwrap();
        drop(far);

        read_timeout_or_ended(&near, WAIT).unwrap();

        assert_eq!(near.read(&mut [0; 8]).unwrap(), 0);
    }

    #[test]
    fn read_wait_a_peer_that_closed_first_leaves_its_lines_and_then_the_end() {
        let (near, mut far) = UnixStream::pair().unwrap();
        far.write_all(b"one\ntwo\n").unwrap();
        drop(far);

        read_timeout_or_ended(&near, WAIT).unwrap();

        let mut reader = BufReader::new(&near);
        let mut lines = Vec::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 {
                break;
            }
            lines.push(line);
        }
        assert_eq!(lines, ["one\n", "two\n"]);
    }

    /// The wider case: no descriptor is closed. Each side ended its writes,
    /// so this side can send no more and receive no more.
    #[test]
    fn read_wait_a_socket_where_each_side_ended_its_writes_gives_the_end() {
        let (mut near, far) = UnixStream::pair().unwrap();
        near.shutdown(Shutdown::Write).unwrap();
        far.shutdown(Shutdown::Write).unwrap();

        read_timeout_or_ended(&near, WAIT).unwrap();

        assert_eq!(near.read(&mut [0; 8]).unwrap(), 0);
        drop(far);
    }

    /// A refusal is the end only when the poll says so. This arm runs on
    /// Linux too, where the system does not refuse.
    #[test]
    fn read_wait_a_refusal_on_a_socket_that_ended_is_the_end() {
        let (near, far) = UnixStream::pair().unwrap();
        drop(far);

        assert_eq!(settle(&near, refusal()).unwrap(), ReadWait::Ended);
    }

    /// A refusal on a socket that can still receive is not read as the end:
    /// a read there could wait with no limit.
    #[test]
    fn read_wait_a_refusal_on_an_open_socket_is_an_error_that_says_so() {
        let (near, _far) = UnixStream::pair().unwrap();

        let error = settle(&near, refusal()).unwrap_err();

        assert!(
            error.to_string().contains("a read timeout was refused on a socket that is open"),
            "{error}"
        );
    }

    #[test]
    fn read_wait_an_open_socket_gets_its_timeout() {
        let (mut near, mut far) = UnixStream::pair().unwrap();

        let set = read_timeout_or_ended(&near, Duration::from_millis(50)).unwrap();

        assert_eq!(set, ReadWait::Timed);
        let started = Instant::now();
        let error = near.read(&mut [0; 8]).unwrap_err();
        assert!(
            matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut),
            "{error}"
        );
        assert!(started.elapsed() < WAIT, "{:?}", started.elapsed());
        far.write_all(b"x").unwrap();
        assert_eq!(near.read(&mut [0; 8]).unwrap(), 1);
    }
}
