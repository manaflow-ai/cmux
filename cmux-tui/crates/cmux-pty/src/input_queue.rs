//! Writes to a macOS PTY master that never cut an escape sequence right after its ESC (#22265).
//!
//! A macOS PTY holds at most [`CAPACITY`] bytes of input for the program. A write that does not fit
//! is taken byte by byte until the queue is full, and the rest blocks until the program reads. If
//! the queue fills right after an ESC, the program's next read ends in a lone ESC: crossterm (Codex
//! and most Rust TUIs) reads a short read ending in ESC as the Esc key and types the rest of the
//! sequence (`[<65;30;7M`, a wheel report) as text. Under a burst of mouse reports that happens
//! about once per thirteen fills.
//!
//! So a write that does not fit the room left (`FIONREAD` on the master counts the queued input on
//! macOS) writes only what fits, cut before an ESC, and waits for room for a sequence it cannot
//! start whole. Input that fits, the common case, is one plain `write`.

use std::fs::File;
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

/// The input a macOS PTY queues for its program (`TTYHOG` less two).
pub(crate) const CAPACITY: usize = 1022;
/// The longest an escape sequence waits for room before it is written as the kernel takes it.
const ROOM_WAIT: Duration = Duration::from_millis(250);
/// How often a waiting write checks for room. A bounded delay, only while the program reads
/// nothing and the next sequence cannot start whole.
const ROOM_POLL: Duration = Duration::from_millis(1);

const ESC: u8 = 0x1b;

/// One `Write::write` on the master: returns how many bytes of `buffer` went to the queue.
pub(crate) fn write(file: &mut File, buffer: &[u8]) -> io::Result<usize> {
    let Some(pending) = queued(file) else { return file.write(buffer) };
    let mut room = CAPACITY.saturating_sub(pending);
    if buffer.len() <= room {
        return file.write(buffer);
    }
    let deadline = Instant::now() + ROOM_WAIT;
    loop {
        match cut(buffer, room) {
            Cut::Write(length) => return file.write(buffer.get(..length).unwrap_or(buffer)),
            Cut::Wait if Instant::now() >= deadline => return file.write(buffer),
            Cut::Wait => {
                std::thread::sleep(ROOM_POLL);
                let Some(pending) = queued(file) else { return file.write(buffer) };
                room = CAPACITY.saturating_sub(pending);
                if buffer.len() <= room {
                    return file.write(buffer);
                }
            }
        }
    }
}

/// Input the program has not read yet, or `None` when the master cannot say.
fn queued(file: &File) -> Option<usize> {
    let mut count: libc::c_int = 0;
    let status = unsafe { libc::ioctl(file.as_raw_fd(), libc::FIONREAD, &mut count) };
    (status == 0 && count >= 0).then_some(count as usize)
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Cut {
    /// Write this many bytes now: they fit and do not end right after an ESC.
    Write(usize),
    /// Write nothing yet: the next escape sequence does not fit whole.
    Wait,
}

/// How much of `buffer` (longer than `room`) to write into `room` free bytes: up to the last ESC
/// that starts within the room, so whole sequences go in; else, for text with no ESC to cut at
/// (a long paste), all the room, never ending right after an ESC. A buffer that starts with an
/// escape sequence longer than the room waits, unless the sequence cannot fit even an empty queue.
pub(crate) fn cut(buffer: &[u8], room: usize) -> Cut {
    debug_assert!(buffer.len() > room);
    if let Some(start) =
        buffer.get(1..=room).and_then(|window| window.iter().rposition(|&byte| byte == ESC))
    {
        return Cut::Write(start + 1);
    }
    if let Some((&ESC, after)) = buffer.split_first() {
        let sequence =
            after.iter().position(|&byte| byte == ESC).map_or(buffer.len(), |end| end + 1);
        if sequence <= CAPACITY || room == 0 {
            return Cut::Wait;
        }
    }
    match room {
        0 => Cut::Wait,
        _ if buffer.get(room - 1) == Some(&ESC) => {
            if room > 1 {
                Cut::Write(room - 1)
            } else {
                Cut::Wait
            }
        }
        _ => Cut::Write(room),
    }
}

#[cfg(test)]
mod tests {
    use super::{CAPACITY, Cut, cut};

    #[test]
    fn whole_sequences_go_in_up_to_the_last_one_that_starts_in_the_room() {
        let reports = b"\x1b[<65;30;7M\x1b[<65;30;7M\x1b[<65;30;7M";
        // 11 bytes per report: 12 bytes of room take the first report only.
        assert_eq!(cut(reports, 12), Cut::Write(11));
        assert_eq!(cut(reports, 23), Cut::Write(22));
    }

    #[test]
    fn a_sequence_that_does_not_fit_waits_for_room() {
        assert_eq!(cut(b"\x1b[<65;30;7M", 1), Cut::Wait);
        assert_eq!(cut(b"\x1b[<65;30;7M", 5), Cut::Wait);
        assert_eq!(cut(b"\x1b[<65;30;7M", 0), Cut::Wait);
    }

    #[test]
    fn text_fills_the_room_but_never_ends_after_an_escape() {
        assert_eq!(cut(b"abcdef", 4), Cut::Write(4));
        // The room ends right after the ESC that the text holds at its fourth byte.
        assert_eq!(cut(b"abc\x1b[A", 4), Cut::Write(3));
        assert_eq!(cut(b"a\x1b", 1), Cut::Write(1));
    }

    #[test]
    fn a_sequence_longer_than_the_queue_is_cut_where_it_must_be() {
        let mut long = vec![0x1b, b']'];
        long.extend(std::iter::repeat_n(b'x', CAPACITY + 10));
        assert_eq!(cut(&long, 100), Cut::Write(100));
    }
}
