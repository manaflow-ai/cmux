//! Whether the program on a PTY sits in a line editor that has read all of its input: the kernel's
//! word, at one moment, for the daemon's `extra.shell_idle` (cmux-tui-core `terminal_activity`).
//!
//! A shell's line editor (readline, zle, fish's reader) reads its keys raw: canonical mode
//! (`ICANON`) is off while it waits at the prompt, and the shell turns it back on before it runs a
//! command it read. So with `ICANON` off and nothing queued for the program, every byte written to
//! the PTY was read, and the line editor read the last of it. Two PTY queries of one terminal the
//! caller holds the master of; never a process scan.

#[cfg(unix)]
use std::os::fd::RawFd;

/// `Some(true)` when the program on the PTY of `master` reads raw (`ICANON` off) and nothing waits
/// in its input queue; `Some(false)` when it reads cooked lines or input waits; `None` when the PTY
/// cannot say. Linux reads the slave's state through a new slave descriptor (`TIOCGPTPEER`, closed
/// before the return): its master has a termios and a queue of its own. macOS reads both on the
/// master, which shares the slave's. The caller keeps `master` open.
#[cfg(unix)]
pub fn reads_raw_with_nothing_queued(master: RawFd) -> Option<bool> {
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
        state(slave.as_raw_fd())
    }
    #[cfg(not(target_os = "linux"))]
    {
        state(master)
    }
}

#[cfg(unix)]
fn state(fd: RawFd) -> Option<bool> {
    let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
    // SAFETY: tcgetattr writes one termios through the pointer, which points to `termios`, a live
    // MaybeUninit<termios>; the caller keeps `fd` open for the call.
    if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: tcgetattr returned 0, so it filled the termios; it was zeroed before, and every field
    // is an integer or an integer array, so any bit pattern is valid.
    let termios = unsafe { termios.assume_init() };
    if termios.c_lflag & libc::ICANON != 0 {
        return Some(false);
    }
    let mut queued: libc::c_int = 0;
    // SAFETY: the caller keeps `fd` open for the call, and FIONREAD writes one c_int through the
    // pointer to `queued`, a live local of that type.
    if unsafe { libc::ioctl(fd, libc::FIONREAD, &mut queued) } != 0 || queued < 0 {
        return None;
    }
    Some(queued == 0)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;

    /// A PTY pair whose slave this test sets up: cooked, then raw, then raw with input queued.
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
        assert_eq!(reads_raw_with_nothing_queued(master.as_raw_fd()), Some(false), "cooked");
        let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
        // SAFETY: as in `state`; the test owns `slave`.
        assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), termios.as_mut_ptr()) }, 0);
        // SAFETY: tcgetattr filled it.
        let mut termios = unsafe { termios.assume_init() };
        termios.c_lflag &= !(libc::ICANON | libc::ECHO);
        // SAFETY: tcsetattr reads the termios the pointer points to; the test owns `slave`.
        assert_eq!(unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios) }, 0);
        assert_eq!(reads_raw_with_nothing_queued(master.as_raw_fd()), Some(true), "raw, empty");
        use std::io::Write;
        (&master).write_all(b"x").unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while reads_raw_with_nothing_queued(master.as_raw_fd()) != Some(false) {
            assert!(std::time::Instant::now() < deadline, "the queued byte never counted");
            std::thread::yield_now();
        }
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
            if super::reads_raw_with_nothing_queued(master.as_raw_fd()) != Some(false) {
                missed += 1;
            }
            let mut byte = [0u8; 1];
            (&slave).read_exact(&mut byte).unwrap();
        }
        assert_eq!(missed, 0, "a byte in flight read as consumed {missed} of 500 times");
    }
}
