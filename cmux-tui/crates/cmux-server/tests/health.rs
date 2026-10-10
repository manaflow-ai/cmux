//! Health probes against fixture trees, the disk re-check deadline, and the
//! reducer driver.

/// Linux with logind only: holds the idle inhibitor, sees it listed, and
/// sees it released when the holder is dropped. Skipped where logind
/// refuses or is absent.
#[cfg(target_os = "linux")]
#[test]
fn idle_inhibitor_is_held_and_released_with_the_pipe() {
    use cmux_server::health::inhibit::{Inhibitor, Kind, probe};
    if !probe(Kind::Idle) {
        eprintln!("skipped: logind does not grant an idle inhibitor here");
        return;
    }
    let listed = || {
        let out = std::process::Command::new("systemd-inhibit")
            .args(["--list", "--no-pager"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .any(|l| l.contains("cmux-server") && l.contains("idle"))
    };
    let mut held = Inhibitor::hold(Kind::Idle).unwrap();
    // systemd-inhibit registers before it starts `cat`; wait for the listing.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !listed() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(50)); // test-only wait
    }
    assert!(held.is_held() && listed(), "idle inhibitor is listed while held");
    drop(held);
    assert!(!listed(), "dropping the holder releases the inhibitor");
}
