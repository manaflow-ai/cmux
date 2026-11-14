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
            Cut::Write(length) => return file.write(&buffer[..length]),
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
    if let Some(start) = buffer[1..=room].iter().rposition(|&byte| byte == ESC) {
        return Cut::Write(start + 1);
    }
    if buffer[0] == ESC {
        let sequence =
            buffer[1..].iter().position(|&byte| byte == ESC).map_or(buffer.len(), |end| end + 1);
        if sequence <= CAPACITY || room == 0 {
            return Cut::Wait;
        }
    }
    match room {
        0 => Cut::Wait,
        _ if buffer[room - 1] == ESC => {
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
mod tests;
