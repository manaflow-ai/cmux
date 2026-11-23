//! `host_power.rs`: the parsers read real command output, the override replaces only what it
//! names and expires, and the health JSON carries `power` and `network`.

use super::*;
use std::fs;
use std::time::{Duration, Instant};

/// A MacBook on its charger (`pmset -g batt`, macOS 26).
const PMSET_AC: &str = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=21823587)\t100%; charged; 0:00 remaining present: true\n";
/// The same MacBook unplugged.
const PMSET_BATTERY: &str = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=21823587)\t87%; discharging; 5:12 remaining present: true\n";
/// A Mac mini: no battery.
const PMSET_MINI: &str = "Now drawing from 'AC Power'\n";
/// A Mac mini behind a UPS: the UPS's percent is not a battery of this machine.
const PMSET_UPS: &str = "Now drawing from 'UPS Power'\n -CP1500PFCLCDa (id=1234)\t64%; discharging; 0:21 remaining present: true\n";

/// `ioreg -r -k AppleClamshellState -d 1` on a MacBook, trimmed to a few of its keys.
const IOREG_OPEN: &str = r#"+-o IOPMrootDomain  <class IOPMrootDomain, id 0x100000100, registered, matched, active, busy 0 (0 ms), retain 207>
    {
      "SleepWakeUUID" = "9F0E5E7A-4C1A-4B4B-9B1E-3D2A1C0B9E8F"
      "AppleClamshellState" = No
      "AppleClamshellCausesSleep" = Yes
      "SystemPowerProfileOverrideDict" = {}
    }
"#;

#[test]
fn power_pmset_reads_ac_battery_mini_and_ups() {
    assert_eq!(parse_pmset_batt(PMSET_AC), (Some(100), Some(true)));
    assert_eq!(parse_pmset_batt(PMSET_BATTERY), (Some(87), Some(false)));
    assert_eq!(parse_pmset_batt(PMSET_MINI), (None, Some(true)));
    assert_eq!(parse_pmset_batt(PMSET_UPS), (None, Some(false)), "a UPS is not the battery");
    assert_eq!(parse_pmset_batt(""), (None, None));
}

#[test]
fn power_clamshell_reads_open_closed_and_no_lid() {
    assert_eq!(parse_clamshell(IOREG_OPEN), Some(false));
    let closed =
        IOREG_OPEN.replace("\"AppleClamshellState\" = No", "\"AppleClamshellState\" = Yes");
    assert_eq!(parse_clamshell(&closed), Some(true));
    // AppleClamshellCausesSleep must not be read as the state.
    assert_eq!(parse_clamshell("      \"AppleClamshellCausesSleep\" = Yes\n"), None);
    assert_eq!(parse_clamshell(""), None, "a Mac with no lid prints nothing");
}

#[test]
fn power_linux_lid_state_parses() {
    assert_eq!(parse_lid_state("state:      open\n"), Some(false));
    assert_eq!(parse_lid_state("state:      closed\n"), Some(true));
    assert_eq!(parse_lid_state("garbage"), None);
}

fn supply(root: &Path, name: &str, files: &[(&str, &str)]) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    for (k, v) in files {
        fs::write(dir.join(k), format!("{v}\n")).unwrap();
    }
}

#[test]
fn power_linux_sysfs_laptop_server_and_peripheral() {
    let root = tempfile::tempdir().unwrap();
    let (supplies, lid) = (root.path().join("ps"), root.path().join("lid"));
    fs::create_dir_all(&supplies).unwrap();
    // A server: only a mouse's battery (scope Device) and no lid.
    supply(
        &supplies,
        "hid-mouse-battery",
        &[("type", "Battery"), ("scope", "Device"), ("capacity", "40")],
    );
    assert_eq!(read_linux(&supplies, &lid), None, "no system battery: no power");
    // A laptop on its charger with the lid open.
    supply(
        &supplies,
        "BAT0",
        &[("type", "Battery"), ("present", "1"), ("capacity", "73"), ("status", "Charging")],
    );
    supply(&supplies, "AC", &[("type", "Mains"), ("online", "1")]);
    fs::create_dir_all(lid.join("LID0")).unwrap();
    fs::write(lid.join("LID0/state"), "state:      open\n").unwrap();
    assert_eq!(
        read_linux(&supplies, &lid),
        Some(Power { battery_percent: Some(73), on_ac: Some(true), lid_closed: Some(false) })
    );
    // Unplugged, lid shut.
    fs::write(supplies.join("AC/online"), "0\n").unwrap();
    fs::write(lid.join("LID0/state"), "state:      closed\n").unwrap();
    let p = read_linux(&supplies, &lid).unwrap();
    assert_eq!((p.on_ac, p.lid_closed), (Some(false), Some(true)));
    // No Mains entry: the battery's status says it.
    fs::remove_dir_all(supplies.join("AC")).unwrap();
    fs::write(supplies.join("BAT0/status"), "Discharging\n").unwrap();
    assert_eq!(read_linux(&supplies, &lid).unwrap().on_ac, Some(false));
}

#[test]
fn power_assume_replaces_only_what_it_names_and_expires() {
    let now = 1_000_000;
    assert_eq!(parse_assume("not json", now), None);
    assert_eq!(parse_assume("{}", now), None, "names nothing");
    assert_eq!(parse_assume(r#"{"lidClosed": true, "until": 999999}"#, now), None, "expired");
    let a = parse_assume(r#"{"lidClosed": true, "until": 2000000}"#, now).unwrap();
    assert_eq!(a.lid_closed, Some(true));
    let real = Power { battery_percent: Some(80), on_ac: Some(true), lid_closed: Some(false) };
    let v = power_json(Some(real), Some(&a)).unwrap();
    assert_eq!(v, json!({"batteryPercent": 80, "onAc": true, "lidClosed": true, "assumed": true}));
    // A machine with no battery shows power when one is assumed, and none otherwise.
    assert_eq!(power_json(None, None), None);
    let low = parse_assume(r#"{"batteryPercent": 12.4, "onAc": false}"#, now).unwrap();
    assert_eq!(
        power_json(None, Some(&low)).unwrap(),
        json!({"batteryPercent": 12, "onAc": false, "lidClosed": null, "assumed": true})
    );
    // A network-only override leaves power unassumed.
    let net = parse_assume(r#"{"networkUp": false}"#, now).unwrap();
    assert_eq!(power_json(Some(real), Some(&net)).unwrap().get("assumed"), None);
    assert_eq!(network_json(true, Some(&net)), json!({"up": false, "assumed": true}));
    assert_eq!(network_json(true, None), json!({"up": true}));
}

#[test]
fn power_bounded_command_returns_output_and_kills_a_slow_one() {
    assert_eq!(
        run_bounded("/bin/sh", &["-c", "echo ok"], Duration::from_secs(5)).as_deref(),
        Some("ok\n")
    );
    assert_eq!(run_bounded("/bin/sh", &["-c", "exit 3"], Duration::from_secs(5)), None);
    let started = Instant::now();
    assert_eq!(run_bounded("/bin/sh", &["-c", "sleep 30"], Duration::from_millis(200)), None);
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "killed at its limit: {:?}",
        started.elapsed()
    );
    assert_eq!(run_bounded("/nonexistent/pmset", &[], Duration::from_secs(1)), None);
}

/// The health every peer shares carries `network` always and `power` per machine; one reading's
/// cost is printed (`--nocapture`) for the PR: the first (cold) and the median of cached ones,
/// beside the whole `host_health`.
#[tokio::test]
async fn power_and_network_in_host_health_and_their_cost() {
    use crate::server::Origin;
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let v = crate::server::peer_status::host_health_with(&hub, Origin::Peer, None).await;
    assert!(v.pointer("/network/up").is_some_and(Value::is_boolean), "{v}");
    if let Some(p) = v.get("power") {
        for key in ["batteryPercent", "onAc", "lidClosed"] {
            assert!(p.get(key).is_some(), "power names {key}: {p}");
        }
    }

    let median = |mut xs: Vec<Duration>| {
        xs.sort();
        xs[xs.len() / 2]
    };
    *CACHE.lock().await = None;
    let t = Instant::now();
    let _ = power().await;
    let cold = t.elapsed();
    let mut cached = Vec::new();
    let mut net = Vec::new();
    let mut whole = Vec::new();
    for _ in 0..200 {
        let t = Instant::now();
        let _ = power().await;
        cached.push(t.elapsed());
        let t = Instant::now();
        let _ = (network_up(), assumed(0));
        net.push(t.elapsed());
        let t = Instant::now();
        let _ = crate::server::peer_status::host_health_with(&hub, Origin::Peer, None).await;
        whole.push(t.elapsed());
    }
    let mut cold_reads = Vec::new();
    for _ in 0..20 {
        let t = Instant::now();
        let _ = tokio::task::spawn_blocking(read_now).await;
        cold_reads.push(t.elapsed());
    }
    println!(
        "host_power cost ({}): first power read {:?}; uncached read p50 {:?}; cached power p50 {:?}; network_up+override p50 {:?}; whole host_health p50 {:?}",
        std::env::consts::OS,
        cold,
        median(cold_reads),
        median(cached),
        median(net),
        median(whole),
    );
}
