//! The rule the daemon's own Energy Saver reading follows:
//! the app's `EnergyPolicyResolver.reason(setting:inputs:)` (CmuxNextEnergy),
//! so after the app quits, or before it connects, the daemon decides as the
//! app would.
//!
//! - The setting is `energy.saver` as the daemon's settings owner reads it
//!   (mux/settings.rs), the same file and managed policy the app reads.
//! - "Turn Off for Now" is the `offForNow` of the app's last `energy.set`; it
//!   outlives the app's connection and ends on the Mac's battery -> AC edge,
//!   as `SetTemporaryBatterySaverDisabledForSession` does in Chrome.
//! - The power facts come from the Mac's power source, Low Power Mode and
//!   thermal state (mux/power_source.rs).
//!
//! Chrome's rule is chrome/browser/performance_manager/user_tuning/
//! battery_saver_mode_manager.cc; cmux's Low Power Mode and thermal triggers
//! in `auto` are the app's (plans/cmux-next/chrome-parity/p14-energy.md, D).

use serde::Serialize;
use serde_json::Value;

use super::energy_op::SaverReason;
use crate::wake::{PowerReading, Thermal};

/// On battery below this charge (strictly), `auto` turns the saver on: the
/// app's `EnergyPolicyResolver.lowBatteryThresholdPercent`, Chrome's
/// `kLowBatteryThresholdPercent`.
pub(crate) const LOW_BATTERY_THRESHOLD_PERCENT: u8 = 20;

/// The settings key the daemon reads (the app's `EnergySaverSetting.path`).
pub(crate) const SETTING_KEY: &str = "energy.saver";

/// The `energy.saver` setting: the app's `EnergySaverMode`, spelled the same.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SaverSetting {
    /// On in Low Power Mode, on battery below 20%, or on battery while hot.
    Auto,
    /// On whenever the Mac runs on battery.
    OnBattery,
    /// On all the time.
    Always,
    /// Never on.
    Off,
}

impl SaverSetting {
    pub(crate) const ALL: [Self; 4] = [Self::Auto, Self::OnBattery, Self::Always, Self::Off];

    /// The setting `value` names; a missing or unknown value is `auto`, as
    /// the app's `EnergySaverSetting.value(in:)` reads it.
    pub fn from_value(value: Option<&Value>) -> Self {
        match value.and_then(Value::as_str) {
            Some("onBattery") => Self::OnBattery,
            Some("always") => Self::Always,
            Some("off") => Self::Off,
            _ => Self::Auto,
        }
    }

    pub(crate) fn code(self) -> u8 {
        match self {
            Self::Auto => 1,
            Self::OnBattery => 2,
            Self::Always => 3,
            Self::Off => 4,
        }
    }

    pub(crate) fn from_code(code: u8) -> Option<Self> {
        Self::ALL.into_iter().find(|setting| setting.code() == code)
    }
}

/// Whether `keys` (a settings change's dotted keys) may have changed
/// [`SETTING_KEY`]: the key itself, a parent or a child of it.
pub(crate) fn touches_setting(keys: &[String]) -> bool {
    keys.iter().any(|key| {
        key == SETTING_KEY
            || SETTING_KEY.strip_prefix(key.as_str()).is_some_and(|rest| rest.starts_with('.'))
            || key.strip_prefix(SETTING_KEY).is_some_and(|rest| rest.starts_with('.'))
    })
}

/// The power inputs as the rule reads them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PowerFacts {
    /// The battery provides power.
    pub on_battery: bool,
    /// On battery with an internal battery strictly below
    /// [`LOW_BATTERY_THRESHOLD_PERCENT`].
    pub low_battery: bool,
    /// macOS Low Power Mode is on.
    pub low_power_mode: bool,
    /// On battery and serious or critical, or above nominal while the hold
    /// from an earlier serious state lasts (the app's thermal hold).
    pub hot: bool,
}

impl PowerFacts {
    /// The facts of `reading`; `held` is [`Self::hot`] of the reading before
    /// it, so the thermal reason holds until the Mac cools to nominal or is
    /// plugged in (`EnergyPolicyResolver.isHot`).
    pub fn read(reading: PowerReading, held: bool) -> Self {
        let on_battery = reading.on_battery;
        Self {
            on_battery,
            low_battery: on_battery
                && reading.has_battery
                && reading
                    .battery_percent
                    .is_some_and(|percent| percent < LOW_BATTERY_THRESHOLD_PERCENT),
            low_power_mode: reading.low_power_mode,
            hot: on_battery
                && (reading.thermal >= Thermal::Serious
                    || (held && reading.thermal > Thermal::Nominal)),
        }
    }
}

/// Why the saver is on for `setting` and `facts`, or `None` while it is off;
/// `off_for_now` ("Turn Off for Now") holds it off whatever the rest says.
pub fn reason(setting: SaverSetting, off_for_now: bool, facts: PowerFacts) -> Option<SaverReason> {
    if off_for_now {
        return None;
    }
    match setting {
        SaverSetting::Off => None,
        SaverSetting::Always => Some(SaverReason::Setting),
        SaverSetting::OnBattery => facts.on_battery.then_some(SaverReason::Setting),
        SaverSetting::Auto if facts.low_power_mode => Some(SaverReason::LowPowerMode),
        SaverSetting::Auto if !facts.on_battery => None,
        SaverSetting::Auto if facts.low_battery => Some(SaverReason::Battery),
        SaverSetting::Auto => facts.hot.then_some(SaverReason::Thermal),
    }
}

#[cfg(test)]
#[path = "energy_rule_tests.rs"]
mod tests;
