//! The daemon's disk tier with the event journal on (R-DURABILITY S2c; lead rule 2026-11-04: a
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

/// With the journal on, the daemon's process keeps the default disk tier; without it, utility as
/// before. A test process's own policy, so each case runs in a child of this test binary.
#[cfg(target_os = "macos")]
#[test]
fn the_daemon_with_the_journal_keeps_the_default_disk_tier() {
    if let Ok(case) = std::env::var("ACPMUX_QOS_JOURNAL_CASE") {
        enter_daemon(case == "journal");
        println!("QOS-CASE io={}", process_io());
        return;
    }
    let exe = std::env::current_exe().unwrap();
    let mut seen = Vec::new();
    for case in ["journal", "nojournal"] {
        let out = std::process::Command::new(&exe)
            .args([
                "--exact",
                "qos::journal_tests::the_daemon_with_the_journal_keeps_the_default_disk_tier",
                "--nocapture",
            ])
            .env("ACPMUX_QOS_JOURNAL_CASE", case)
            .env_remove(ENV)
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let io = text
            .lines()
            .find_map(|line| line.strip_prefix("QOS-CASE io="))
            .and_then(|io| io.trim().parse::<i32>().ok())
            .unwrap_or_else(|| panic!("case {case}: no QOS-CASE line in {text}"));
        seen.push((case, io));
    }
    // 4 is IOPOL_UTILITY; the default reads 0 (or 1, IOPOL_IMPORTANT, the same tier).
    assert!(matches!(seen[0], ("journal", 0 | 1)), "the daemon with the journal: {seen:?}");
    assert_eq!(seen[1], ("nojournal", 4), "the daemon without the journal: {seen:?}");
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
