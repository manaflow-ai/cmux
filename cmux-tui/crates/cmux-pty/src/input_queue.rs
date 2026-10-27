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
//! start whole. Input that fits, the common case, is one plain `write`. The wait wakes when the
//! program reads ([`ReadWaiter`]), never on a timer.

use std::fs::File;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant};

/// The input a macOS PTY queues for its program (`TTYHOG` less two).
pub(crate) const CAPACITY: usize = 1022;
/// The longest an escape sequence waits for room before it is written as the kernel takes it.
const ROOM_WAIT: Duration = Duration::from_millis(250);

const ESC: u8 = 0x1b;

/// One `Write::write` on the master: returns how many bytes of `buffer` went to the queue.
pub(crate) fn write(file: &mut File, buffer: &[u8]) -> io::Result<usize> {
    write_waiting(file, buffer, ROOM_WAIT).0
}

/// [`write`] with its room wait, and how many times it waited for the program to read.
fn write_waiting(file: &mut File, buffer: &[u8], room_wait: Duration) -> (io::Result<usize>, u32) {
    let mut waits = 0;
    let Some(pending) = queued(file) else { return (file.write(buffer), waits) };
    let mut room = CAPACITY.saturating_sub(pending);
    if buffer.len() <= room {
        return (file.write(buffer), waits);
    }
    let deadline = Instant::now() + room_wait;
    let mut reads: Option<ReadWaiter> = None;
    loop {
        if let Cut::Write(length) = cut(buffer, room) {
            return (file.write(&buffer[..length]), waits);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return (file.write(buffer), waits);
        }
        let waiter = match reads {
            Some(ref waiter) => waiter,
            None => match ReadWaiter::new(file.as_raw_fd()) {
                Ok(waiter) => reads.insert(waiter),
                Err(_) => return (file.write(buffer), waits),
            },
        };
        waits += 1;
        if waiter.wait(remaining).is_err() {
            return (file.write(buffer), waits);
        }
        let Some(pending) = queued(file) else { return (file.write(buffer), waits) };
        room = CAPACITY.saturating_sub(pending);
        if buffer.len() <= room {
            return (file.write(buffer), waits);
        }
    }
}

/// Wakes when the program reads from the master's input queue.
///
/// An edge-triggered (`EV_CLEAR`) `EVFILT_WRITE` on the master fires on each read the program
/// makes: XNU's `ptsread` calls `ptcwakeup(tp, FWRITE)` (bsd/kern/tty_dev.c). A level-triggered
/// `poll(POLLOUT)` would not do: it is ready while the queue has any room, so it would return at
/// once while the room is too small for the next sequence. The first wait may return at once (the
/// filter is active when added with room left); each later one waits for a read or the timeout.
struct ReadWaiter {
    queue: OwnedFd,
}

impl ReadWaiter {
    fn new(master: RawFd) -> io::Result<Self> {
        // SAFETY: kqueue takes no arguments; a non-negative result is a new descriptor we own.
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `queue` is the open descriptor kqueue just returned, owned by nothing else.
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        let change = libc::kevent {
            ident: master as libc::uintptr_t,
            filter: libc::EVFILT_WRITE,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: 0,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        // SAFETY: one valid change record, no event list, no timeout; both descriptors are open.
        let status = unsafe {
            libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        };
        if status < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { queue })
    }

    /// Returns after the program reads, a signal, or `timeout`.
    fn wait(&self, timeout: Duration) -> io::Result<()> {
        let timeout = libc::timespec {
            tv_sec: libc::time_t::try_from(timeout.as_secs()).unwrap_or(libc::time_t::MAX),
            tv_nsec: libc::c_long::from(timeout.subsec_nanos()),
        };
        // SAFETY: an all-zero kevent is a valid value of this plain C struct.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: no change list, room for one event in `event`, a valid timespec.
        let count = unsafe {
            libc::kevent(self.queue.as_raw_fd(), std::ptr::null(), 0, &mut event, 1, &timeout)
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        Ok(())
    }
}

/// Input the program has not read yet, or `None` when the master cannot say.
fn queued(file: &File) -> Option<usize> {
    let mut count: libc::c_int = 0;
    // SAFETY: `file` keeps its descriptor open for the call, and FIONREAD writes one c_int through
    // the pointer to `count`, a live local of that type.
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
mod tests {
    use std::fs::File;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::time::{Duration, Instant};

    use super::{CAPACITY, Cut, cut, write_waiting};

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

    const WHEEL_UP: &[u8] = b"\x1b[<65;30;7M";

    /// A raw-mode PTY pair from `openpty`: (master, slave).
    fn raw_pty() -> (File, File) {
        let (mut master, mut slave) = (-1, -1);
        // SAFETY: two out-pointers to live c_ints; no name, termios or window size.
        let status = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(status, 0, "openpty: {}", std::io::Error::last_os_error());
        // SAFETY: openpty returned two open descriptors that nothing else owns.
        let (master, slave) = unsafe { (File::from_raw_fd(master), File::from_raw_fd(slave)) };
        let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
        // SAFETY: an open tty descriptor and room for one termios.
        assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), termios.as_mut_ptr()) }, 0);
        // SAFETY: tcgetattr filled the termios.
        let mut termios = unsafe { termios.assume_init() };
        // SAFETY: a live termios.
        unsafe { libc::cfmakeraw(&mut termios) };
        // SAFETY: an open tty descriptor and a live termios.
        assert_eq!(unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios) }, 0);
        (master, slave)
    }

    #[test]
    fn a_waiting_write_wakes_when_the_program_reads_not_on_a_timer() {
        let (mut master, mut slave) = raw_pty();
        // The program is busy: the queue holds 1,021 bytes, one short of full.
        master.write_all(&[b'x'; 1021]).unwrap();
        let program = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            let mut got = Vec::new();
            let mut buffer = [0u8; 2048];
            while got.len() < 1021 + WHEEL_UP.len() {
                let read = slave.read(&mut buffer).unwrap();
                got.extend_from_slice(&buffer[..read]);
            }
            got
        });

        let started = Instant::now();
        let (written, waits) = write_waiting(&mut master, WHEEL_UP, Duration::from_secs(2));
        let elapsed = started.elapsed();

        assert_eq!(written.unwrap(), WHEEL_UP.len());
        // No wait: ReadWaiter::new failed and the write blocked in the kernel instead.
        assert!(waits >= 1, "the write never waited for the program to read");
        // The 1 ms poll checked the queue about 100 times while the program was busy.
        assert!(waits <= 3, "the waiting write woke {waits} times before the program read");
        // It returned when the program read at 100 ms, not at its 2 s room wait: a read that
        // fires no EVFILT_WRITE leaves only the timeout to wake it.
        assert!(
            elapsed >= Duration::from_millis(50),
            "returned before the program read: {elapsed:?}"
        );
        assert!(elapsed < Duration::from_secs(1), "woke on the room-wait timeout: {elapsed:?}");
        let got = program.join().unwrap();
        assert_eq!(&got[1021..], WHEEL_UP, "the wheel report arrived changed");
    }
}
