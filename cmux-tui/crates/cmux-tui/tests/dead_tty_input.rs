//! A client must notice that its terminal is gone instead of spinning on it.
//!
//! When a terminal emulator exits without delivering `SIGHUP`, the pty master is
//! closed while the client keeps the slave open. The poll then reports the
//! descriptor ready forever and every read reports end of input, so a reader that
//! treats "no bytes this time" as "ask again" re-reads at once and pins a core
//! for as long as the process lives. Nothing else in the client can exit while
//! that thread never returns, so the process then also survives `SIGTERM` and
//! needs `SIGKILL`.
//!
//! The reader is crossterm's, reached through the same `poll`/`read` pair the
//! interactive client uses, so these tests drive it directly against a real pty.
//! Both scenarios let the reader build itself over a live terminal first and only
//! then hang the terminal up, which is the order a real client sees: crossterm
//! opens the tty at startup, and the terminal dies later.
//!
//! `a_live_tty_still_delivers_events` is the control. A fix that turned every poll
//! into an error would satisfy the hangup test and nothing else.
//!
//! See manaflow-ai/cmux#17287.

#![cfg(unix)]

use std::fs::File;
use std::io::Write;
use std::os::fd::{FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Directory the re-executed child reports through. Its presence is also what
/// marks a process as the child, so neither test forks twice.
const CHILD_DIR_ENV: &str = "CMUX_TEST_DEAD_TTY_DIR";

/// Name of the test the child runs. Selecting one test keeps the child from
/// re-entering the scenario tests, which would each fork a child of their own.
const CHILD_TEST: &str = "reader_child_entry_point";

/// How long the reader gets to report what its terminal did. A reader looping on
/// end of input burns a core for this whole window, so the bound leaves room for a
/// loaded machine while keeping the suite quick.
const READER_DEADLINE: Duration = Duration::from_secs(10);

/// Verdicts the child can report.
const READER_REPORTED_ERROR: &str = "reported-error";
const READER_DELIVERED_EVENT: &str = "delivered-event";
/// The reader never returned. The pty was hung up, so this is the bug.
const READER_SPUN: &str = "spun";
/// The reader never returned and the pty was not hung up at all, so this run
/// proves nothing about the reader.
const READER_NEVER_HUNG_UP: &str = "never-hung-up";

#[test]
fn a_hung_up_tty_is_reported_instead_of_read_again() {
    if is_child() {
        return;
    }
    let verdict = run_reader(true, |_| {});
    assert_eq!(
        verdict,
        READER_REPORTED_ERROR,
        "{}",
        explain(&verdict, "a hung-up terminal must be reported as an error")
    );
}

#[test]
fn a_live_tty_still_delivers_events() {
    if is_child() {
        return;
    }
    let verdict = run_reader(false, |master| {
        // Deliver one line. The line discipline only reports a canonical-mode
        // reader once a line is complete, so the trailing newline is what makes the
        // byte visible to the reader.
        master.write_all(b"x\n").expect("write to pty master");
    });
    assert_eq!(
        verdict,
        READER_DELIVERED_EVENT,
        "{}",
        explain(&verdict, "a live terminal must still deliver input")
    );
}

/// Turns a verdict into the reason it is the wrong one, or an empty string when
/// it is the one the scenario asked for.
fn explain(verdict: &str, wanted: &str) -> String {
    match verdict {
        READER_REPORTED_ERROR | READER_DELIVERED_EVENT => format!(
            "the reader reported {verdict:?}, but {wanted}; the tests disagree about what a \
             correct reader does, so neither result means anything"
        ),
        READER_SPUN => format!(
            "the reader never returned within {READER_DEADLINE:?} even though its terminal hung \
             up: it re-read the terminal instead of reporting the end of input"
        ),
        READER_NEVER_HUNG_UP => format!(
            "the reader never returned, but a raw read of the same terminal still showed it \
            open, so this run never exercised {wanted}"
        ),
        other => format!("the reader reported an unknown verdict {other:?}"),
    }
}

fn is_child() -> bool {
    std::env::var_os(CHILD_DIR_ENV).is_some()
}

/// Re-executes this test binary as the reader child, gives it a pty, and returns the
/// verdict the child reached.
///
/// `hang_up` closes the pty master once the child reports that its reader is built over
/// a live terminal. `setup` feeds the terminal before that, and only runs while the
/// terminal is still live.
fn run_reader(hang_up: bool, setup: impl FnOnce(&mut File)) -> String {
    // One directory per scenario: cargo runs tests in parallel and both
    // scenarios share this process, so a name derived from the process id would
    // let them read each other's `ready` and `verdict` files. A fresh temporary
    // directory also means no `ready` file survives an aborted run to make the
    // parent hang the terminal up before the reader exists. Holding it for the
    // whole function is what keeps the directory alive for the child, and its
    // drop is what removes it.
    let child_directory = tempfile::tempdir().expect("child directory");
    let directory = child_directory.path();

    let (mut master, slave) = open_pty();
    let mut child = Command::new(std::env::current_exe().expect("test binary path"))
        .arg(CHILD_TEST)
        .arg("--exact")
        .arg("--nocapture")
        .env(CHILD_DIR_ENV, directory)
        // crossterm reads the terminal through `tty_fd`, which uses stdin whenever stdin is
        // a terminal, so the slave has to be stdin.
        .stdin(Stdio::from(slave))
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("reader child must start");

    setup(&mut master);
    // Hanging up before the reader is built would fail crossterm's `tty_fd` instead of
    // exercising the reader, so wait for the handshake first.
    await_file(&directory.join("ready"), &mut child);

    // Dropping the master is what hangs the terminal up. In the live case it stays open
    // until the child exits, because a closed master ends input.
    let master = if hang_up {
        drop(master);
        None
    } else {
        Some(master)
    };

    let status = await_exit(&mut child);
    drop(master);
    assert!(status.success(), "reader child exited with {status}");

    let verdict = std::fs::read_to_string(directory.join("verdict"))
        .unwrap_or_else(|error| panic!("read verdict: {error}"));
    verdict.trim().to_string()
}

/// Waits for the child to create `path`, failing the test if it never does.
fn await_file(path: &Path, child: &mut Child) {
    let deadline = Instant::now() + READER_DEADLINE;
    while !path.exists() {
        assert!(
            Instant::now() < deadline,
            "reader child never reported a ready reader at {}",
            path.display()
        );
        assert!(child.try_wait().expect("child status").is_none(), "reader child exited early");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Waits for the child to exit, killing it if it outlives the reader deadline.
fn await_exit(child: &mut Child) -> std::process::ExitStatus {
    let deadline = Instant::now() + 2 * READER_DEADLINE;
    loop {
        match child.try_wait().expect("child status") {
            Some(status) => return status,
            None if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            None => {
                let _ = child.kill();
                panic!("reader child reported nothing within {READER_DEADLINE:?}");
            }
        }
    }
}

/// The reader half: read the terminal the way the interactive client does, and record
/// whether the poll reported an error, delivered an event, or never returned at all.
fn reader_child() -> ! {
    let directory = PathBuf::from(std::env::var_os(CHILD_DIR_ENV).expect("child directory"));
    let ready_path = directory.join("ready");
    let verdict_path = directory.join("verdict");

    let (sender, receiver) = mpsc::channel();
    // A reader looping on end of input spins on this thread and cannot be joined, so the
    // verdict is written from the main thread and reported with `process::exit`, which
    // does not wait for it.
    std::thread::spawn(move || {
        let deadline = Instant::now() + READER_DEADLINE;
        let mut announced = false;
        let mut verdict = READER_SPUN;
        while Instant::now() < deadline {
            match crossterm::event::poll(Duration::from_millis(100)) {
                Err(_) => {
                    verdict = READER_REPORTED_ERROR;
                    break;
                }
                Ok(ready) => {
                    // Any poll that got as far as answering means crossterm has built its
                    // reader over this pty, which is what the parent waits for before
                    // hanging the terminal up.
                    if !announced {
                        std::fs::write(&ready_path, b"ready").expect("write ready");
                        announced = true;
                    }
                    if ready {
                        verdict = match crossterm::event::read() {
                            Err(_) => READER_REPORTED_ERROR,
                            Ok(_) => READER_DELIVERED_EVENT,
                        };
                        break;
                    }
                }
            }
        }
        let _ = sender.send(verdict);
    });

    let verdict = match receiver.recv_timeout(2 * READER_DEADLINE) {
        Ok(verdict) => verdict,
        // The reader is still stuck in crossterm. Ask the terminal directly whether it
        // really did hang up, so a run that never closed it cannot be mistaken for the bug.
        Err(_) => {
            if terminal_ended() {
                READER_SPUN
            } else {
                READER_NEVER_HUNG_UP
            }
        }
    };
    std::fs::write(&verdict_path, verdict).expect("write verdict");
    std::process::exit(0)
}

/// Whether a raw read of the reader's own terminal reports end of input. A terminal that
/// is still open has bytes to give or refuses the read outright.
fn terminal_ended() -> bool {
    let mut byte = [0u8; 1];
    // SAFETY: reading one byte into a one-byte buffer from the reader's own stdin.
    let read = unsafe { libc::read(0, byte.as_mut_ptr().cast(), byte.len()) };
    read == 0 || (read < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EIO))
}

/// One test entry point has to run in the child, and it has to be the only test the child
/// runs, so the reader lives behind this name rather than behind the scenario tests.
#[test]
fn reader_child_entry_point() {
    if is_child() {
        reader_child();
    }
}

/// A pty pair. The caller hands the slave to the reader as its stdin and keeps the master
/// to inject input or to hang up.
///
/// Both descriptors are close-on-exec. The child must not keep the master open, or
/// closing it here leaves the pair alive and the terminal never hangs up.
fn open_pty() -> (File, OwnedFd) {
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    // SAFETY: `openpty` writes two descriptors into the out params on success.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(opened, 0, "openpty: {}", std::io::Error::last_os_error());
    for descriptor in [master, slave] {
        // SAFETY: both descriptors are open and owned here.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
        assert!(flags >= 0, "F_GETFD: {}", std::io::Error::last_os_error());
        // SAFETY: as above, with the flags read a moment ago.
        assert_eq!(
            unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) },
            0,
            "F_SETFD: {}",
            std::io::Error::last_os_error()
        );
    }
    // SAFETY: both descriptors are fresh, owned, and valid.
    unsafe { (File::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) }
}
