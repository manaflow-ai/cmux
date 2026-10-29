//! The daemon's own power reading against the app's override, the
//! `energy.saver` setting and "Turn Off for Now". The rule
//! table is server/energy_rule_tests.rs; the clock thread's wait on a fake
//! notify source is covered in cmux-wake (`maintenance::power_tests`).

use super::*;
use crate::server::energy_op::{EnergySource, SaverReason};
use crate::server::energy_rule::SaverSetting;
use crate::wake::Thermal;

/// The control client id the app's override is set as.
const APP: u64 = 7;

fn plugged() -> PowerReading {
    PowerReading { has_battery: true, battery_percent: Some(15), ..PowerReading::default() }
}

fn battery(percent: u8) -> PowerReading {
    PowerReading {
        on_battery: true,
        has_battery: true,
        battery_percent: Some(percent),
        ..PowerReading::default()
    }
}

/// A daemon that read `setting` from its settings file.
fn energy(setting: SaverSetting) -> DaemonEnergy {
    let energy = DaemonEnergy::default();
    energy.set_setting(setting);
    energy
}

#[test]
fn an_ac_to_battery_edge_sets_the_mode_by_the_apps_rule() {
    let energy = energy(SaverSetting::Auto);
    let mut follow = FactsFollow::default();
    assert!(!follow.apply(&energy, plugged()));
    assert!(!energy.mode().is_saver());
    assert!(!follow.apply(&energy, battery(40)), "auto keeps the saver off above 20%");
    assert!(follow.apply(&energy, battery(15)), "on battery below 20% turns it on");
    let status = energy.status();
    assert!(status.saver && status.reading);
    assert_eq!(status.source, EnergySource::Daemon);
    assert_eq!(status.reason, Some(SaverReason::Battery));
    assert!(follow.apply(&energy, plugged()), "plugging in turns it off");
    assert!(!energy.mode().is_saver());
}

/// After the app quits, each setting decides as the app's resolver would.
#[test]
fn every_setting_holds_after_the_app_quits() {
    let low = battery(10);
    let high = battery(80);
    let low_power = PowerReading { low_power_mode: true, ..plugged() };
    let cases = [
        (SaverSetting::Off, low, false, "off never turns on, even at 10%"),
        (SaverSetting::Always, plugged(), true, "always stays on plugged in"),
        (SaverSetting::OnBattery, high, true, "onBattery is on above 20%"),
        (SaverSetting::OnBattery, plugged(), false, "onBattery is off plugged in"),
        (SaverSetting::Auto, low_power, true, "auto follows Low Power Mode"),
        (SaverSetting::Auto, high, false, "auto is off on a full battery"),
    ];
    for (setting, reading, saver, label) in cases {
        let energy = energy(setting);
        // The app held the opposite while it ran.
        energy.set_override(APP, Some(!saver), Some(SaverReason::Setting).filter(|_| !saver));
        FactsFollow::default().apply(&energy, reading);
        assert_eq!(energy.mode().is_saver(), !saver, "{label}: the app decides while it runs");
        energy.client_left(APP);
        assert_eq!(energy.mode().is_saver(), saver, "{label}");
        assert_eq!(energy.status().setting, Some(setting));
    }
}

#[test]
fn nothing_turns_on_before_the_setting_is_read() {
    let energy = DaemonEnergy::default();
    assert!(!FactsFollow::default().apply(&energy, battery(5)));
    assert!(!energy.status().reading, "an unread setting might be off");
    assert!(energy.set_setting(SaverSetting::Auto), "the default setting reads auto");
    assert!(energy.mode().is_saver());
}

#[test]
fn the_thermal_hold_lasts_across_readings() {
    let energy = energy(SaverSetting::Auto);
    let mut follow = FactsFollow::default();
    let at = |thermal| PowerReading { thermal, ..battery(80) };
    assert!(follow.apply(&energy, at(Thermal::Serious)));
    assert!(!follow.apply(&energy, at(Thermal::Fair)), "fair keeps the held saver");
    assert_eq!(energy.status().reason, Some(SaverReason::Thermal));
    assert!(follow.apply(&energy, at(Thermal::Nominal)), "cooled to nominal");
    assert!(!follow.apply(&energy, at(Thermal::Fair)), "the hold ended at nominal");
}

#[test]
fn turn_off_for_now_outlives_the_app_until_the_mac_is_plugged_in() {
    let energy = energy(SaverSetting::Always);
    let mut follow = FactsFollow::default();
    follow.apply(&energy, battery(50));
    assert!(energy.mode().is_saver());
    assert!(energy.set_app(APP, Some(false), None, Some(true)), "Turn Off for Now");
    assert!(!energy.client_left(APP), "the app quits: the hold stays");
    let status = energy.status();
    assert!(!status.saver && status.off_for_now && !status.reading);
    assert!(!follow.apply(&energy, battery(10)), "it holds while the battery drains");
    assert!(follow.apply(&energy, plugged()), "the battery -> AC edge ends it");
    assert!(!energy.status().off_for_now);
    assert!(energy.mode().is_saver(), "always is on again");

    // AC -> battery is no edge: a new hold set plugged in survives it.
    energy.set_app(APP, Some(false), None, Some(true));
    energy.client_left(APP);
    assert!(!follow.apply(&energy, battery(50)));
    assert!(energy.status().off_for_now);
    // The app's next word ends it too; a line without offForNow keeps it.
    energy.set_override(APP, None, None);
    assert!(energy.status().off_for_now);
    assert!(energy.set_app(APP, None, None, Some(false)));
    assert!(energy.mode().is_saver());
}

#[test]
fn the_apps_override_wins_until_it_is_cleared() {
    let energy = energy(SaverSetting::Auto);
    let mut follow = FactsFollow::default();
    energy.set_override(APP, Some(false), None);
    assert!(!follow.apply(&energy, battery(10)), "the app holds the saver off");
    let status = energy.status();
    assert!(!status.saver && status.reading);
    assert_eq!(status.source, EnergySource::App);

    assert!(energy.set_override(APP, None, None), "clearing it follows the reading");
    assert!(energy.mode().is_saver());

    energy.set_override(APP, Some(true), Some(SaverReason::Setting));
    assert!(!follow.apply(&energy, plugged()), "the app holds the saver on while plugged in");
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
