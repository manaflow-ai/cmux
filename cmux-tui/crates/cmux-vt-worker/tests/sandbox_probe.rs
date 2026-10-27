//! The worker's Seatbelt profile, applied as the worker applies it, denies
//! what a compromised parser would reach for: `open()`, `fork()`,
//! `socket(AF_INET)` and `bootstrap_look_up("com.apple.pasteboard.1")`.
//! It still allows what the worker needs: mapping a segment it was given
//! read-only and writing to the socket it holds. Every check also runs
//! before the sandbox and must succeed there, so a denial is the profile's;
//! notifyd's lookup is the Mach control where an SSH session cannot reach
//! the pasteboard at all.
//!
//! A sandbox is for the life of the process, so the probe runs in a child:
//! the test re-runs its own binary with only `probe_child` selected and
//! [`PROBE_ENV`] set (Chrome's `MultiProcessTest` pattern in
//! `sandbox/mac/sandbox_mac_seatbelt_exec_unittest.cc`), and reads one
//! result line per check.

#![cfg(target_os = "macos")]

use std::ffi::{CStr, c_char, c_int};
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

/// `bootstrap_look_up(name)` found the service.
fn can_look_up(name: &CStr) -> bool {
    let mut service = 0u32;
    // SAFETY: a NUL-terminated name and a writable out-parameter; reading
    // the process's bootstrap port global.
    let result = unsafe { bootstrap_look_up(bootstrap_port, name.as_ptr(), &mut service) };
    result == 0
}

/// The pasteboard server: only in a GUI (Aqua) bootstrap session, so an
/// SSH session may not reach it even unsandboxed.
const PASTEBOARD: &CStr = c"com.apple.pasteboard.1";
/// notifyd, in the system bootstrap every session inherits: it resolves
/// unsandboxed everywhere, so its denial proves the profile denies
/// `mach-lookup` even where the pasteboard check proves nothing.
const NOTIFYD: &CStr = c"com.apple.system.notification_center";

/// The values of `key=bool` pairs on the line that starts with `prefix`.
fn checks(stdout: &str, prefix: &str) -> std::collections::BTreeMap<String, bool> {
    let line = stdout
        .lines()
        .find(|line| line.starts_with(prefix))
        .unwrap_or_else(|| panic!("no {prefix:?} line in {stdout}"));
    line.split_whitespace()
        .skip(1)
        .filter_map(|pair| pair.split_once('='))
        .map(|(key, value)| (key.to_owned(), value == "true"))
        .collect()
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
    // The same checks before the sandbox: each "after" denial below means
    // something only where the call works without it.
    println!(
        "before open={} fork={} socket={} pasteboard={} notifyd={}",
        can_open(),
        can_fork(),
        can_open_inet_socket(),
        can_look_up(PASTEBOARD),
        can_look_up(NOTIFYD)
    );

    let policy = sandbox::compile_policy().expect("compile");
    assert!(matches!(policy, SandboxPolicy::Seatbelt(_)));
    assert_eq!(sandbox::apply(&policy), Ok(SandboxMechanism::Seatbelt));

    println!(
        "after open={} fork={} socket={} pasteboard={} notifyd={}",
        can_open(),
        can_fork(),
        can_open_inet_socket(),
        can_look_up(PASTEBOARD),
        can_look_up(NOTIFYD)
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
    let before = checks(&stdout, "before ");
    let after = checks(&stdout, "after ");
    // The checks work at all: each call succeeds before the sandbox. The
    // pasteboard may be out of reach of a non-GUI (SSH) session; notifyd
    // never is, so the Mach check always has a positive control.
    for check in ["open", "fork", "socket", "notifyd"] {
        assert_eq!(before.get(check), Some(&true), "{check} before the sandbox: {stdout}");
    }
    for check in ["open", "fork", "socket", "pasteboard", "notifyd"] {
        assert_eq!(after.get(check), Some(&false), "{check} after the sandbox: {stdout}");
    }
    if before.get("pasteboard") != Some(&true) {
        eprintln!(
            "the pasteboard is not in this bootstrap session; notifyd proves the Mach denial"
        );
    }
    assert!(stdout.contains("needs map=true socket_write=true"), "{stdout}");
}
