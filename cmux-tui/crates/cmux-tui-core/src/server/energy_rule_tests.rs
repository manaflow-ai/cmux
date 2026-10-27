//! The daemon's rule against the app's `EnergyPolicyResolverTests` table,
//! one row each (CmuxNextEnergyTests): every setting, the thermal hold and
//! "Turn Off for Now".

use serde_json::json;

use super::*;
use crate::server::energy_op::SaverReason::{Battery, LowPowerMode, Setting};
use crate::wake::Thermal::{Critical, Fair, Nominal, Serious};

/// A laptop on battery at `percent`.
fn battery(percent: u8, thermal: Thermal, low_power_mode: bool) -> PowerReading {
    PowerReading {
        on_battery: true,
        has_battery: true,
        battery_percent: Some(percent),
        low_power_mode,
        thermal,
    }
}

/// A laptop on the adapter.
fn plugged(thermal: Thermal, low_power_mode: bool) -> PowerReading {
    PowerReading { has_battery: true, low_power_mode, thermal, ..PowerReading::default() }
}

/// A desktop Mac: no battery, never on battery.
fn desktop(thermal: Thermal, low_power_mode: bool) -> PowerReading {
    PowerReading { low_power_mode, thermal, ..PowerReading::default() }
}

fn decide(setting: SaverSetting, reading: PowerReading) -> Option<SaverReason> {
    reason(setting, false, PowerFacts::read(reading, false))
}

#[test]
fn each_setting_decides_as_the_apps_resolver() {
    use SaverSetting::{Always, Auto, Off, OnBattery};
    let unknown_charge = PowerReading { battery_percent: None, ..battery(0, Nominal, false) };
    let rows: [(SaverSetting, PowerReading, Option<SaverReason>, &str); 27] = [
        // always: on everywhere, whatever the inputs.
        (Always, plugged(Nominal, false), Some(Setting), "plugged in"),
        (Always, battery(90, Nominal, false), Some(Setting), "battery 90%"),
        (Always, desktop(Nominal, false), Some(Setting), "desktop"),
        (Always, battery(5, Critical, true), Some(Setting), "battery 5%, critical, Low Power Mode"),
        // onBattery: on battery at any charge; Low Power Mode and heat do not matter.
        (OnBattery, battery(90, Nominal, false), Some(Setting), "battery 90%"),
        (OnBattery, battery(5, Nominal, false), Some(Setting), "battery 5%"),
        (OnBattery, plugged(Nominal, false), None, "plugged in"),
        (OnBattery, plugged(Nominal, true), None, "plugged in, Low Power Mode"),
        (OnBattery, desktop(Critical, false), None, "desktop, critical"),
        // off: never, even in Low Power Mode on a hot, empty battery.
        (Off, battery(1, Critical, true), None, "battery 1%, critical, Low Power Mode"),
        (Off, plugged(Nominal, true), None, "plugged in, Low Power Mode"),
        // auto, battery: strictly below 20%.
        (Auto, battery(19, Nominal, false), Some(Battery), "battery 19%"),
        (Auto, battery(20, Nominal, false), None, "battery 20%"),
        (Auto, battery(0, Nominal, false), Some(Battery), "battery 0%"),
        (Auto, battery(80, Nominal, false), None, "battery 80%"),
        (Auto, plugged(Nominal, false), None, "plugged in"),
        // auto, Low Power Mode: on plugged in too, and the reason over battery and heat.
        (Auto, plugged(Nominal, true), Some(LowPowerMode), "plugged in, Low Power Mode"),
        (Auto, desktop(Nominal, true), Some(LowPowerMode), "desktop, Low Power Mode"),
        (Auto, battery(10, Critical, true), Some(LowPowerMode), "battery 10%, critical, LPM"),
        // auto, thermal: serious or critical on battery only.
        (Auto, battery(80, Serious, false), Some(SaverReason::Thermal), "battery 80%, serious"),
        (Auto, battery(80, Critical, false), Some(SaverReason::Thermal), "battery 80%, critical"),
        (Auto, battery(80, Fair, false), None, "battery 80%, fair"),
        (Auto, plugged(Critical, false), None, "plugged in, critical"),
        (Auto, plugged(Serious, false), None, "plugged in, serious"),
        (Auto, desktop(Critical, false), None, "desktop, critical"),
        // A low battery is the reason over heat.
        (Auto, battery(10, Serious, false), Some(Battery), "battery 10%, serious"),
        // An unknown charge never counts as low.
        (Auto, unknown_charge, None, "battery, unknown charge"),
    ];
    for setting in SaverSetting::ALL {
        assert!(rows.iter().any(|row| row.0 == setting), "{setting:?} has no row");
    }
    for (setting, reading, expected, label) in rows {
        assert_eq!(decide(setting, reading), expected, "{setting:?}, {label}");
    }
}

#[test]
fn turn_off_for_now_holds_every_setting_off() {
    let facts = PowerFacts::read(battery(5, Critical, true), false);
    for setting in SaverSetting::ALL {
        assert_eq!(reason(setting, true, facts), None, "{setting:?}");
    }
}

/// `EnergyPolicyResolverTests.theThermalReasonHoldsUntilNominal`.
#[test]
fn the_thermal_reason_holds_until_nominal_or_plugged_in() {
    let mut held = false;
    let mut step = |reading: PowerReading| {
        let facts = PowerFacts::read(reading, held);
        held = facts.hot;
        reason(SaverSetting::Auto, false, facts)
    };
    assert_eq!(step(battery(80, Fair, false)), None, "fair alone is no reason");
    assert_eq!(step(battery(80, Serious, false)), Some(SaverReason::Thermal));
    for thermal in [Fair, Serious, Fair, Critical, Fair] {
        assert_eq!(step(battery(80, thermal, false)), Some(SaverReason::Thermal), "{thermal:?}");
    }
    assert_eq!(step(battery(80, Nominal, false)), None, "cooled to nominal");
    assert_eq!(step(battery(80, Fair, false)), None, "the hold outlived nominal");
    assert_eq!(step(battery(80, Serious, false)), Some(SaverReason::Thermal));
    assert_eq!(step(plugged(Fair, false)), None);
    assert_eq!(step(battery(80, Fair, false)), None, "the hold outlived the plug-in");
}

#[test]
fn the_setting_reads_as_the_app_reads_it() {
    assert_eq!(SaverSetting::from_value(Some(&json!("auto"))), SaverSetting::Auto);
    assert_eq!(SaverSetting::from_value(Some(&json!("onBattery"))), SaverSetting::OnBattery);
    assert_eq!(SaverSetting::from_value(Some(&json!("always"))), SaverSetting::Always);
    assert_eq!(SaverSetting::from_value(Some(&json!("off"))), SaverSetting::Off);
    assert_eq!(SaverSetting::from_value(None), SaverSetting::Auto, "missing is the default");
    assert_eq!(SaverSetting::from_value(Some(&json!("sometimes"))), SaverSetting::Auto);
    assert_eq!(SaverSetting::from_value(Some(&json!(false))), SaverSetting::Auto);
    for setting in SaverSetting::ALL {
        assert_eq!(SaverSetting::from_code(setting.code()), Some(setting));
        let name = serde_json::to_value(setting).unwrap();
        assert_eq!(SaverSetting::from_value(Some(&name)), setting, "{name}");
    }
    assert_eq!(SaverSetting::from_code(0), None);
}

#[test]
fn a_change_touches_the_setting_through_itself_a_parent_or_a_child() {
    let touches = |key: &str| touches_setting(&[key.to_owned()]);
    assert!(touches("energy.saver"));
    assert!(touches("energy"));
    assert!(touches("energy.saver.extra"));
    assert!(!touches("energy.saverish"));
    assert!(!touches("energ"));
    assert!(!touches("mobile.terminalSizing"));
    assert!(!touches_setting(&[]));
}
