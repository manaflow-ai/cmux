//! Whether the program on a PTY sits in a line editor with nothing in flight between it and the
//! daemon: the kernel's word, for the daemon's `extra.shell_idle` (cmux-tui-core
//! `terminal_activity`).
//!
//! A shell's line editor (readline, zle, fish's reader) reads its keys raw: canonical mode
//! (`ICANON`) is off while it waits at the prompt, and the shell turns it back on before it runs a
//! command it read. [`LineState::quiet`] holds when, at one moment, the program reads raw, no
//! input waits to be read by it, and none of its output waits for the daemon's side. Linux asks
//! with a zero-timeout `poll`, which first hands the kernel's in-flight bytes (the flip buffer a
//! master write fills) to the line discipline, so a byte written a moment ago is never missed;
//! macOS writes to a PTY synchronously, so its counts are exact. A few PTY queries of one terminal
//! the caller holds the master of; never a process scan.

#[cfg(unix)]
use std::os::fd::RawFd;

/// What the kernel says about one PTY at one moment ([`state`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineState {
    /// The program reads raw (`ICANON` off): a line editor at its prompt.
    pub reads_raw: bool,
    /// Input waits for the program to read it.
    pub input_waiting: bool,
    /// Output of the program waits for the master's reader.
    pub output_waiting: bool,
}

impl LineState {
    /// A line editor that read everything written to it, with nothing of
    /// its own in flight.
    pub fn quiet(self) -> bool {
        self.reads_raw && !self.input_waiting && !self.output_waiting
    }
}

/// The [`LineState`] of the PTY of `master`, or `None` when the PTY cannot say. The caller keeps
/// `master` open.
#[cfg(unix)]
pub fn state(master: RawFd) -> Option<LineState> {
    #[cfg(target_os = "linux")]
    {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        let flags = libc::O_RDONLY | libc::O_NOCTTY | libc::O_CLOEXEC | libc::O_NONBLOCK;
        // SAFETY: TIOCGPTPEER on the master the caller keeps open returns a new descriptor of its
        // slave (or -1); it takes the open flags as its int argument.
        let slave = unsafe { libc::ioctl(master, libc::TIOCGPTPEER, flags) };
        if slave < 0 {
            return None;
        }
        // SAFETY: `slave` is a descriptor this call just opened and nothing else owns.
        let slave = unsafe { OwnedFd::from_raw_fd(slave) };
        Some(LineState {
            reads_raw: reads_raw(slave.as_raw_fd())?,
            // The slave's input is the program's; the master's input is its output.
            input_waiting: readable(slave.as_raw_fd())?,
            output_waiting: readable(master)?,
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        // The master shares the slave's termios and queues: FIONREAD counts the program's unread
        // input, TIOCOUTQ its output the master's reader has not taken.
        Some(LineState {
            reads_raw: reads_raw(master)?,
            input_waiting: count(master, libc::FIONREAD)? > 0,
            output_waiting: count(master, TIOCOUTQ)? > 0,
        })
    }
}

#[cfg(unix)]
fn reads_raw(fd: RawFd) -> Option<bool> {
    let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
    // SAFETY: tcgetattr writes one termios through the pointer, which points to `termios`, a live
    // MaybeUninit<termios>; the caller keeps `fd` open for the call.
    if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: tcgetattr returned 0, so it filled the termios; it was zeroed before, and every field
    // is an integer or an integer array, so any bit pattern is valid.
    let termios = unsafe { termios.assume_init() };
    Some(termios.c_lflag & libc::ICANON == 0)
}

/// Whether a read of `fd` would return data now. The tty's poll hands the kernel's in-flight
/// input to the line discipline before it answers. An error or hang-up is unknown.
#[cfg(target_os = "linux")]
fn readable(fd: RawFd) -> Option<bool> {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    // SAFETY: one pollfd that lives for the call; a zero timeout never waits.
    let ready = unsafe { libc::poll(&mut poll, 1, 0) };
    if ready < 0 || poll.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
        return None;
    }
    Some(poll.revents & libc::POLLIN != 0)
}

/// `TIOCOUTQ` from Darwin's `<sys/ttycom.h>` (`_IOR('t', 115, int)`): the bytes in the tty's
/// output queue. libc does not export it for Apple targets.
#[cfg(all(unix, not(target_os = "linux")))]
const TIOCOUTQ: libc::c_ulong = 0x4004_7473;

#[cfg(all(unix, not(target_os = "linux")))]
fn count(fd: RawFd, request: libc::c_ulong) -> Option<usize> {
    let mut queued: libc::c_int = 0;
    // SAFETY: the caller keeps `fd` open for the call, and FIONREAD and TIOCOUTQ write one c_int
    // through the pointer to `queued`, a live local of that type.
    if unsafe { libc::ioctl(fd, request, &mut queued) } != 0 || queued < 0 {
        return None;
    }
    usize::try_from(queued).ok()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;

    /// A PTY pair whose slave this test sets up: cooked, raw, input queued, output queued.
    #[test]
    fn shell_idle_a_raw_reader_with_nothing_queued_is_told_apart() {
        let mut master: libc::c_int = 0;
        let mut slave: libc::c_int = 0;
        // SAFETY: openpty writes two descriptors through the pointers to these live locals; the
        // name, termios and winsize pointers may be null.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0);
        // SAFETY: openpty just opened both and nothing else owns them.
        let (master, slave) = unsafe {
            use std::os::fd::FromRawFd;
            (std::fs::File::from_raw_fd(master), std::fs::File::from_raw_fd(slave))
        };
        assert_eq!(state(master.as_raw_fd()).map(LineState::quiet), Some(false), "cooked");
        let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
        // SAFETY: as in `reads_raw`; the test owns `slave`.
        assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), termios.as_mut_ptr()) }, 0);
        // SAFETY: tcgetattr filled it.
        let mut termios = unsafe { termios.assume_init() };
        termios.c_lflag &= !(libc::ICANON | libc::ECHO);
        // SAFETY: tcsetattr reads the termios the pointer points to; the test owns `slave`.
        assert_eq!(unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios) }, 0);
        assert_eq!(state(master.as_raw_fd()).map(LineState::quiet), Some(true), "raw, empty");
        use std::io::{Read, Write};
        // A master write is seen at once: on Linux the poll hands the kernel's in-flight
        // bytes to the line discipline first (no timing), on macOS the write is synchronous.
        (&master).write_all(b"x").unwrap();
        assert_eq!(
            state(master.as_raw_fd()).map(LineState::quiet),
            Some(false),
            "input waits for the program"
        );
        let mut byte = [0u8; 1];
        (&slave).read_exact(&mut byte).unwrap();
        assert_eq!(
            state(master.as_raw_fd()).map(LineState::quiet),
            Some(true),
            "the program read it"
        );
        // The program's output the master's reader has not taken (an echo).
        (&slave).write_all(b"y").unwrap();
        assert_eq!(
            state(master.as_raw_fd()).map(LineState::quiet),
            Some(false),
            "output waits for the reader"
        );
        (&master).read_exact(&mut byte).unwrap();
        assert_eq!(
            state(master.as_raw_fd()).map(LineState::quiet),
            Some(true),
            "the reader took it"
        );
    }
}

/// Review 5 of cp/daemon-foreground-state, item 1: a byte the daemon wrote to the master a
/// moment ago is input that waits for the program, every time. On Linux a master write lands in
/// the kernel's flip buffer and reaches the line discipline from a work queue, so a FIONREAD
/// right after the write can count 0 while the byte is in flight: a typed-ahead line would read
/// as consumed and pay the prompts it is owed.
#[cfg(all(test, target_os = "linux"))]
mod in_flight_tests {
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd};

    #[test]
    fn shell_idle_a_byte_just_written_to_the_master_is_never_read_as_consumed() {
        let (mut master, mut slave) = (0, 0);
        // SAFETY: openpty writes two descriptors through the pointers to these live locals; the
        // name, termios and winsize pointers may be null.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0);
        // SAFETY: openpty just opened both and nothing else owns them.
        let (master, slave) =
            unsafe { (std::fs::File::from_raw_fd(master), std::fs::File::from_raw_fd(slave)) };
        let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
        // SAFETY: tcgetattr writes one termios into `termios`; the test owns `slave`.
        assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), termios.as_mut_ptr()) }, 0);
        // SAFETY: tcgetattr filled it.
        let mut termios = unsafe { termios.assume_init() };
        // SAFETY: cfmakeraw edits the termios the pointer points to.
        unsafe { libc::cfmakeraw(&mut termios) };
        // SAFETY: tcsetattr reads the termios the pointer points to; the test owns `slave`.
        assert_eq!(unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios) }, 0);
        let mut missed = 0;
        for _ in 0..500 {
            (&master).write_all(b"x").unwrap();
            if super::state(master.as_raw_fd()).map(|state| state.input_waiting) != Some(true) {
                missed += 1;
            }
            let mut byte = [0u8; 1];
            (&slave).read_exact(&mut byte).unwrap();
        }
        assert_eq!(missed, 0, "a byte in flight read as consumed {missed} of 500 times");
    }
}
