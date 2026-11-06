//! The daemon's disk tier with the event journal (R-DURABILITY S2c; lead rule 2026-11-04: a
//! reply the person waits for never waits on a throttled disk sync). Fleet A/B (STATUS 11554):
//! at `IOPOL_UTILITY` an acknowledged append waited about 16 ms p50 under another process's disk
//! stress, against 0.7 to 1.1 ms at the default tier.

use super::*;

/// The process's disk I/O policy (macOS `getiopolicy_np`, process scope).
#[cfg(target_os = "macos")]
fn process_io() -> libc::c_int {
    unsafe extern "C" {
        fn getiopolicy_np(iotype: libc::c_int, scope: libc::c_int) -> libc::c_int;
    }
    // SAFETY: a plain syscall with constant arguments.
    unsafe { getiopolicy_np(0, 0) }
}

/// The calling thread's own disk I/O policy (0: it follows the process's).
#[cfg(target_os = "macos")]
fn thread_io() -> libc::c_int {
    unsafe extern "C" {
        fn getiopolicy_np(iotype: libc::c_int, scope: libc::c_int) -> libc::c_int;
    }
    // SAFETY: as above, thread scope.
    unsafe { getiopolicy_np(0, 1) }
}

/// The daemon's process keeps the default disk tier: its acknowledged replies wait on the event
/// journal's sync. A test process's own policy, so the daemon's entry runs in a child of this test
/// binary.
#[cfg(target_os = "macos")]
#[test]
fn the_daemon_keeps_the_default_disk_tier() {
    if std::env::var_os("ACPMUX_QOS_JOURNAL_CASE").is_some() {
        enter_daemon();
        println!("QOS-CASE io={}", process_io());
        return;
    }
    let exe = std::env::current_exe().unwrap();
    let out = std::process::Command::new(&exe)
        .args([
            "--exact",
            "qos::journal_tests::the_daemon_keeps_the_default_disk_tier",
            "--nocapture",
        ])
        .env("ACPMUX_QOS_JOURNAL_CASE", "daemon")
        .env_remove(ENV)
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let io = text
        .lines()
        .find_map(|line| line.strip_prefix("QOS-CASE io="))
        .and_then(|io| io.trim().parse::<i32>().ok())
        .unwrap_or_else(|| panic!("no QOS-CASE line in {text}"));
    // 4 is IOPOL_UTILITY; the default reads 0 (or 1, IOPOL_IMPORTANT, the same tier).
    assert!(matches!(io, 0 | 1), "the daemon's disk tier: {io}");
}

/// A dedicated background thread (the checkpointer) does its disk work at the utility tier, and
/// a thread beside it keeps the process's.
#[cfg(target_os = "macos")]
#[test]
fn a_background_thread_yields_its_disk_work() {
    let (own, other) = std::thread::scope(|scope| {
        let own = scope.spawn(|| {
            background_thread();
            thread_io()
        });
        let other = scope.spawn(thread_io);
        (own.join().unwrap(), other.join().unwrap())
    });
    assert_eq!(own, 4, "the background thread's disk tier");
    assert_eq!(other, 0, "a thread beside it");
}
