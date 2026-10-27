//! The worker's Seatbelt profile, applied as the worker applies it, denies
//! what a compromised parser would reach for: `open()`, `fork()`,
//! `socket(AF_INET)` and `bootstrap_look_up("com.apple.pasteboard.1")`.
//! It still allows what the worker needs: mapping a segment it was given
//! read-only and writing to the socket it holds.
//!
//! A sandbox is for the life of the process, so the probe runs in a child:
//! the test re-runs its own binary with only `probe_child` selected and
//! [`PROBE_ENV`] set (Chrome's `MultiProcessTest` pattern in
//! `sandbox/mac/sandbox_mac_seatbelt_exec_unittest.cc`), and reads one
//! result line per check.

#![cfg(target_os = "macos")]

use std::ffi::{c_char, c_int};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

use cmux_process::{Command, Stdio};
use cmux_vt_worker::ring_view::RingView;
use cmux_vt_worker::sandbox::{self, SandboxMechanism, SandboxPolicy};

const PROBE_ENV: &str = "CMUX_VT_WORKER_SANDBOX_PROBE";

unsafe extern "C" {
    static bootstrap_port: u32;
    fn bootstrap_look_up(port: u32, name: *const c_char, service: *mut u32) -> c_int;
}

/// `open("/etc/hosts")` succeeded.
fn can_open() -> bool {
    // SAFETY: open with a NUL-terminated path; the descriptor is closed.
    let fd = unsafe { libc::open(c"/etc/hosts".as_ptr(), libc::O_RDONLY) };
    if fd >= 0 {
        // SAFETY: closes the descriptor just opened.
        unsafe { libc::close(fd) };
    }
    fd >= 0
}

/// `socket(AF_INET, SOCK_STREAM)` succeeded.
fn can_open_inet_socket() -> bool {
    // SAFETY: socket takes no pointers; the descriptor is closed.
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
    if fd >= 0 {
        // SAFETY: closes the descriptor just made.
        unsafe { libc::close(fd) };
    }
    fd >= 0
}

/// `fork()` succeeded (the child exits at once).
fn can_fork() -> bool {
    // SAFETY: the child calls only `_exit`, which is async-signal-safe.
    let pid = unsafe { libc::fork() };
    if pid == 0 {
        // SAFETY: ends the forked child without running any handler.
        unsafe { libc::_exit(0) };
    }
    if pid > 0 {
        let mut status = 0;
        // SAFETY: reaps the child just forked.
        unsafe { libc::waitpid(pid, &mut status, 0) };
    }
    pid > 0
}

/// `bootstrap_look_up("com.apple.pasteboard.1")` found the service.
fn can_look_up_pasteboard() -> bool {
    let mut service = 0u32;
    // SAFETY: a NUL-terminated name and a writable out-parameter; reading
    // the process's bootstrap port global.
    let result = unsafe {
        bootstrap_look_up(bootstrap_port, c"com.apple.pasteboard.1".as_ptr(), &mut service)
    };
    result == 0
}

#[test]
fn probe_child() {
    if std::env::var_os(PROBE_ENV).is_none() {
        return;
    }
    // What the worker gets before its sandbox: a ring and its socket.
    let ring = cmux_holder::ring::Ring::new(0, 4096);
    let segment = ring.segment().expect("shared ring").try_clone().expect("dup ring");
    let (socket, peer) = UnixStream::pair().expect("socketpair");
    println!("before open={} socket={}", can_open(), can_open_inet_socket());

    let policy = sandbox::compile_policy().expect("compile");
    assert!(matches!(policy, SandboxPolicy::Seatbelt(_)));
    assert_eq!(sandbox::apply(&policy), Ok(SandboxMechanism::Seatbelt));

    println!(
        "after open={} fork={} socket={} pasteboard={}",
        can_open(),
        can_fork(),
        can_open_inet_socket(),
        can_look_up_pasteboard()
    );
    let mapped = RingView::open(segment, 4096).is_ok();
    // SAFETY: writes one byte from a live local to a live socket.
    let sent = unsafe { libc::write(socket.as_raw_fd(), b"x".as_ptr().cast(), 1) } == 1;
    drop(peer);
    println!("needs map={mapped} socket_write={sent}");
}

#[test]
fn the_worker_profile_denies_files_processes_network_and_mach_services() {
    let output = Command::new(std::env::current_exe().expect("test binary"))
        .args(["--exact", "probe_child", "--nocapture", "--test-threads=1"])
        .env(PROBE_ENV, "1")
        .stdin(Stdio::null())
        .output()
        .expect("run the probe");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "probe failed: {stdout}\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    // The checks work at all: the same calls succeed before the sandbox.
    assert!(stdout.contains("before open=true socket=true"), "{stdout}");
    assert!(
        stdout.contains("after open=false fork=false socket=false pasteboard=false"),
        "{stdout}"
    );
    assert!(stdout.contains("needs map=true socket_write=true"), "{stdout}");
}
