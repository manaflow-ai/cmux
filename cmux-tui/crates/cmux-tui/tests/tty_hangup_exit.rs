//! An interactive client exits once its host terminal is gone.
//!
//! Closing a terminal window closes the pty master. The client's descriptor
//! then reports end of input forever, and the client may or may not also get
//! `SIGHUP`, depending on whether it leads the terminal's session. Clients that
//! missed this kept running for days: the input thread re-read the dead
//! terminal at full speed, and once a `SIGHUP` asked the client to stop, the
//! main thread waited forever to join that thread (manaflow-ai/cmux#23088).
//!
//! These tests run the real `cmux-tui` binary as an interactive client on a
//! pty, wait until it owns the terminal and has started its input reader, hang
//! the terminal up, and require the process to exit within a deadline. One
//! scenario sends no `SIGHUP`, as when the emulator exits without one; the
//! other sends `SIGHUP` right after the hangup, as a session leader gets it.
//!
//! The client runs with `--ephemeral`, so it hosts its session in-process. A
//! client attached to a separate session owner shares the same input reader,
//! shutdown and terminal restore, but its owner's teardown is not covered here.

#![cfg(unix)]

use std::fs::File;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Mutex, mpsc};
use std::time::{Duration, Instant};

/// How long the client gets to start and take over the terminal.
const STARTUP_DEADLINE: Duration = Duration::from_secs(30);
/// How long the client gets to exit after its terminal hangs up. A healthy
/// client exits in well under a second; the bound leaves room for a loaded
/// machine. A client that spins on the dead terminal never exits at all.
const EXIT_DEADLINE: Duration = Duration::from_secs(15);

/// Bracketed paste is the last input mode the client enables before it starts
/// its host input reader, so seeing it means the reader is about to poll.
const INPUT_MODES_ENABLED: &[u8] = b"\x1b[?2004h";

/// Held from `openpty` until the client has started. `openpty` returns
/// descriptors without close-on-exec, so a client the other test spawns in that
/// window would inherit this test's master and keep the terminal from hanging up.
static PTY_SPAWN: Mutex<()> = Mutex::new(());

#[test]
fn cmux_next_client_exits_when_its_terminal_closes_without_sighup() {
    assert_exited_cleanly(run_client_then_hang_up(false));
}

#[test]
fn cmux_next_client_exits_on_sighup_after_its_terminal_hangs_up() {
    assert_exited_cleanly(run_client_then_hang_up(true));
}

/// The client must have exited on its own: a crash or a signal on the way out
/// is not a clean end of the session.
fn assert_exited_cleanly(verdict: Result<ExitStatus, String>) {
    let status = verdict.unwrap_or_else(|reason| panic!("{reason}"));
    assert!(status.signal().is_none(), "the client died from a signal: {status}");
}

/// Starts an isolated interactive client on a fresh pty, closes the pty master
/// once the client reads input, optionally sends `SIGHUP`, and reports whether
/// the client exited in time.
fn run_client_then_hang_up(sighup: bool) -> Result<ExitStatus, String> {
    let root = tempfile::tempdir().expect("temporary root");
    let home = root.path().join("home");
    std::fs::create_dir_all(&home).expect("home");
    std::fs::write(root.path().join("config.json"), "{}").expect("config");
    let stderr_path = root.path().join("stderr.txt");

    let spawn_guard = PTY_SPAWN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let (mut master, slave) = open_pty();
    let stdin = slave.try_clone().expect("slave for stdin");
    let stdout = slave.try_clone().expect("slave for stdout");
    let mut client = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--ephemeral")
        .arg("--socket")
        .arg(root.path().join("mux.sock"))
        .current_dir(&home)
        .env_clear()
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("SHELL", "/bin/sh")
        .env("TERM", "xterm-256color")
        .env("XDG_DATA_HOME", root.path().join("data"))
        .env("XDG_STATE_HOME", root.path().join("state"))
        .env("XDG_CONFIG_HOME", root.path().join("config"))
        .env("CMUX_TUI_CONFIG", root.path().join("config.json"))
        .env("TMPDIR", root.path())
        .stdin(Stdio::from(stdin))
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(File::create(&stderr_path).expect("stderr file")))
        .spawn()
        .expect("cmux-tui client must start");
    drop(slave);
    drop(spawn_guard);

    if let Err(reason) = await_output(&mut master, INPUT_MODES_ENABLED) {
        kill(&mut client);
        return Err(format!("{reason}\nclient stderr:\n{}", read_lossy(&stderr_path)));
    }

    // Closing the only master descriptor is what hangs the terminal up.
    drop(master);
    if sighup {
        // SAFETY: sends a signal to the child this test spawned and still owns.
        assert_eq!(unsafe { libc::kill(client.id() as libc::pid_t, libc::SIGHUP) }, 0);
    }

    let pid = client.id();
    let (exited_tx, exited_rx) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let status = client.wait().expect("client status");
        let _ = exited_tx.send(status);
        client
    });
    match exited_rx.recv_timeout(EXIT_DEADLINE) {
        Ok(status) => {
            let _ = waiter.join();
            Ok(status)
        }
        Err(_) => {
            // SAFETY: the waiter still owns this unreaped child, so the pid
            // cannot have been reused.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            let _ = waiter.join();
            Err(format!(
                "the client was still running {EXIT_DEADLINE:?} after its terminal hung up \
                 (sighup: {sighup}); it must treat end of input as the end of the session \
                 and must not wait forever for its input reader\nclient stderr:\n{}",
                read_lossy(&stderr_path)
            ))
        }
    }
}

/// Reads the pty master until `needle` appears or the startup deadline passes.
fn await_output(master: &mut File, needle: &[u8]) -> Result<(), String> {
    let deadline = Instant::now() + STARTUP_DEADLINE;
    let mut seen = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        if seen.windows(needle.len()).any(|window| window == needle) {
            return Ok(());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "the client never enabled its input modes within {STARTUP_DEADLINE:?}; \
                 output so far: {:?}",
                String::from_utf8_lossy(&seen)
            ));
        }
        let mut descriptor =
            libc::pollfd { fd: master.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let timeout = libc::c_int::try_from(remaining.as_millis()).unwrap_or(libc::c_int::MAX);
        // SAFETY: one valid pollfd for a descriptor this test owns.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout) };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("poll on the pty master failed: {error}"));
        }
        if ready == 0 {
            continue;
        }
        match master.read(&mut buffer) {
            Ok(0) => return Err("the client closed its terminal during startup".into()),
            Ok(count) => seen.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => {
                return Err(format!(
                    "the client's terminal ended during startup ({error}); output so far: {:?}",
                    String::from_utf8_lossy(&seen)
                ));
            }
        }
    }
}

fn kill(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn read_lossy(path: &Path) -> String {
    std::fs::read(path)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .unwrap_or_default()
}

/// A pty pair. The client gets the slave as stdin and stdout; the test keeps
/// the master to watch the client start and to hang the terminal up.
///
/// Both descriptors are close-on-exec, so the client and its shells never hold
/// the master open and the hangup reaches them.
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
