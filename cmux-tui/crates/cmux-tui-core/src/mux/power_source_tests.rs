//! The daemon's own power reading against the app's override
//! (p14-energy-137). The clock thread's wait on a fake notify source is
//! covered in cmux-wake (`maintenance::power_tests`).

use super::*;
use crate::server::energy_op::{EnergySource, SaverReason};

/// The control client id the app's override is set as.
const APP: u64 = 7;

fn plugged() -> PowerReading {
    PowerReading { on_battery: false, has_battery: true, battery_percent: Some(15) }
}

fn battery(percent: u8) -> PowerReading {
    PowerReading { on_battery: true, has_battery: true, battery_percent: Some(percent) }
}

#[test]
fn an_ac_to_battery_edge_sets_the_mode_by_the_apps_rule() {
    let energy = DaemonEnergy::default();
    assert!(!apply(&energy, plugged()));
    assert!(!energy.mode().is_saver());
    assert!(!apply(&energy, battery(40)), "auto keeps the saver off above 20%");
    assert!(apply(&energy, battery(15)), "on battery below 20% turns it on");
    let status = energy.status();
    assert!(status.saver && status.reading);
    assert_eq!(status.source, EnergySource::Daemon);
    assert!(apply(&energy, plugged()), "plugging in turns it off");
    assert!(!energy.mode().is_saver());
}

#[test]
fn the_apps_override_wins_until_it_is_cleared() {
    let energy = DaemonEnergy::default();
    energy.set_override(APP, Some(false), None);
    assert!(!apply(&energy, battery(10)), "the app holds the saver off");
    let status = energy.status();
    assert!(!status.saver && status.reading);
    assert_eq!(status.source, EnergySource::App);

    assert!(energy.set_override(APP, None, None), "clearing it follows the reading");
    assert!(energy.mode().is_saver());

    energy.set_override(APP, Some(true), Some(SaverReason::Setting));
    assert!(!apply(&energy, plugged()), "the app holds the saver on while plugged in");
    assert!(energy.mode().is_saver());
    assert!(energy.client_left(APP), "the app quits: the daemon follows AC");
    assert!(!energy.mode().is_saver());
}

#[test]
fn delivery_stops_with_the_mux() {
    let mut deliver = deliver(Weak::new());
    deliver(battery(5));
}

/// The app's `BatteryLevel.percent` rows.
#[test]
fn percent_is_the_rounded_share_of_the_full_capacity() {
    assert_eq!(percent(Some(50), Some(100)), Some(50));
    assert_eq!(percent(Some(1), Some(3)), Some(33));
    assert_eq!(percent(Some(2), Some(3)), Some(67));
    assert_eq!(percent(Some(120), Some(100)), Some(100));
    assert_eq!(percent(Some(-5), Some(100)), Some(0));
    assert_eq!(percent(Some(5), Some(0)), None);
    assert_eq!(percent(None, Some(100)), None);
    assert_eq!(percent(Some(5), None), None);
}
