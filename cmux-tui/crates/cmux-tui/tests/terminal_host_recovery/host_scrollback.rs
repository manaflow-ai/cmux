//! The daemon's terminal holds the scrollback every client reads (attach
//! history, `terminal-history`, `read-scrollback`, copy); a terminal host only
//! ever sends a bounded replay of its own (on daemon adopt or reconnect). A
//! readiness soak measured each busy terminal's host keeping a second full
//! 50 MB scrollback anyway: 10 terminals' hosts grew from 216 to 526 MB.
//! (The default is 10 MB since #20257, under the replay budget, so at the
//! default this bounds the host's growth but no longer tells the two apart.)

use super::*;

/// Resident memory of `pid` in KiB (`ps -o rss=`).
fn resident_kib(pid: u32) -> u64 {
    let out = Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().expect("the host is gone")
}

#[test]
fn flooded_terminal_host_keeps_only_a_replay_window_of_scrollback() {
    let harness = RecoveryHarness::start("host-scrollback");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "sleep 2; seq 1 200000; echo flood-done; exec sleep 60"],
            "new_workspace": true,
            "name": "host-scrollback",
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let host = wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid;
    let before = resident_kib(host);

    let deadline = Instant::now() + test_timeout(Duration::from_secs(90));
    while !wait_for_screen(&harness.socket, surface, "flood-done").contains("flood-done") {
        assert!(Instant::now() < deadline, "the flood never finished");
    }
    let grown_mib = resident_kib(host).saturating_sub(before) / 1024;
    // 200k rows at 80 columns is far past either limit: a 50 MB host
    // scrollback would grow ~50 MiB; the 10 MB default or a replay window
    // (~16 MB) stays well under 32.
    assert!(grown_mib < 32, "the host grew {grown_mib} MiB of scrollback");
}

#[path = "sized_attach.rs"]
mod sized_attach;
