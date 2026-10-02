//! Health probes against fixture trees, the disk re-check deadline, and the
//! reducer driver.

use std::fs;
use std::path::Path;

use cmux_server::health::probe::{disk, has_default_route, power};
use cmux_server::health::{HealthRole, MemorySink, disk_recheck_ms, disk_warning_line};
use cmux_server_core::health::{
    CheckId, DiskFacts, Facts, HealthSettings, HostId, Post, PowerFacts, PowerSource,
};
use cmux_server_core::{InstallMode, Platform};

const GIB: u64 = 1 << 30;

fn supply(root: &Path, name: &str, files: &[(&str, &str)]) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    for (file, value) in files {
        fs::write(dir.join(file), format!("{value}\n")).unwrap();
    }
}

#[test]
fn power_supply_probe() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    // No entries: a VM or a server on AC without a battery.
    assert_eq!(power(root), Some(PowerFacts { source: PowerSource::Ac, battery_percent: None }));
    assert_eq!(power(&root.join("missing")), None);
    supply(root, "AC", &[("type", "Mains"), ("online", "0")]);
    supply(root, "BAT0", &[("type", "Battery"), ("status", "Discharging"), ("capacity", "37")]);
    supply(root, "hid-mouse", &[("type", "Battery"), ("scope", "Device"), ("capacity", "5")]);
    assert_eq!(
        power(root),
        Some(PowerFacts { source: PowerSource::Battery, battery_percent: Some(37) })
    );
    supply(root, "AC", &[("type", "Mains"), ("online", "1")]);
    assert_eq!(power(root).unwrap().source, PowerSource::Ac);
}

#[test]
fn default_route_probe() {
    let tmp = tempfile::tempdir().unwrap();
    let net = tmp.path().join("net");
    fs::create_dir_all(&net).unwrap();
    assert_eq!(has_default_route(tmp.path().join("nope").as_path()), None);
    let header = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n";
    fs::write(
        net.join("route"),
        format!("{header}eth0\t0000A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\n"),
    )
    .unwrap();
    assert_eq!(has_default_route(tmp.path()), Some(false));
    fs::write(
        net.join("route"),
        format!("{header}eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\n"),
    )
    .unwrap();
    assert_eq!(has_default_route(tmp.path()), Some(true));
    fs::write(net.join("route"), header).unwrap();
    let v6 = "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003 eth0\n";
    fs::write(net.join("ipv6_route"), v6).unwrap();
    assert_eq!(has_default_route(tmp.path()), Some(true));
}

#[test]
fn disk_probe_reads_the_nearest_existing_ancestor() {
    let tmp = tempfile::tempdir().unwrap();
    let facts = disk(&tmp.path().join("not/yet/created")).unwrap();
    assert!(facts.total_bytes > 0 && facts.free_bytes <= facts.total_bytes);
}

#[test]
fn disk_recheck_is_sized_to_headroom_and_clamped() {
    let s = HealthSettings::default();
    let total = 1000 * GIB;
    assert_eq!(disk_warning_line(&s, total), 10 * GIB, "the byte threshold binds on 1 TB");
    assert_eq!(disk_warning_line(&s, 50 * GIB), 5 * GIB, "the percent binds on 50 GB");
    let at = |free: u64| DiskFacts { free_bytes: free, total_bytes: total };
    // No previous sample, or not shrinking: 30 minutes.
    assert_eq!(disk_recheck_ms(&s, None, 0, at(500 * GIB)), 30 * 60_000);
    assert_eq!(disk_recheck_ms(&s, Some((0, at(400 * GIB))), 60_000, at(500 * GIB)), 30 * 60_000);
    // 1 GiB per minute with 20 GiB headroom: 20 minutes.
    let d = disk_recheck_ms(&s, Some((0, at(31 * GIB))), 60_000, at(30 * GIB));
    assert_eq!(d, 20 * 60_000);
    // Fast fill: never under one minute.
    let d = disk_recheck_ms(&s, Some((0, at(100 * GIB))), 1_000, at(11 * GIB));
    assert_eq!(d, 60_000);
}

#[test]
fn role_posts_raises_and_gives_one_shot_deadlines() {
    let host = HostId::parse("inst_abc").unwrap();
    let mut facts = Facts::healthy(host, Platform::Linux, InstallMode::User);
    facts.power = Some(PowerFacts { source: PowerSource::Battery, battery_percent: Some(50) });
    facts.disk = Some(DiskFacts { free_bytes: GIB, total_bytes: 1000 * GIB });
    let sink = MemorySink::default();
    let mut role = HealthRole::new();
    let posts = role.observe(&facts, 1_000, &sink);
    // disk.low raises now; power.onBattery waits 60 s.
    assert!(matches!(&posts[..], [Post::Notify { check: CheckId::DiskLow, .. }]), "{posts:?}");
    assert_eq!(role.wake_at_ms(), Some(61_000));
    let posts = role.observe(&facts, 61_000, &sink);
    assert!(
        matches!(&posts[..], [Post::Notify { check: CheckId::PowerOnBattery, .. }]),
        "{posts:?}"
    );
    // Nothing pending: the next deadline is the disk re-check.
    assert_eq!(role.wake_at_ms(), Some(61_000 + 30 * 60_000));
    assert_eq!(sink.posts.lock().unwrap().len(), 2);
}

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
