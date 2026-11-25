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
