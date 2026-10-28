//! The power inputs a [`super::MaintenanceClock`] follows,
//! so the daemon reads AC or battery, the charge, Low Power Mode and the
//! thermal state itself and keeps following them after the app quits. The
//! daemon turns a reading into its own Energy Saver by the app's rule
//! (cmux-tui-core `server/energy_rule.rs`); the app's `energy.set` stays an
//! override of it (`server/energy_op.rs`).
//!
//! A [`PowerSource`] is a descriptor that turns readable when an input
//! changes; on macOS one notify(3) descriptor for Low Power Mode,
//! `com.apple.system.powersources.source`, and (while on battery) the charge
//! and the thermal pressure. The clock thread waits on it on the same kqueue
//! as its timer and its user event: no extra thread, no poll and no timed
//! wait. Chrome follows the same IOKit service with no timer on Mac
//! (components/power_monitor/battery_state_sampler_mac.cc,
//! `IOPMPowerSourceSamplingEventSource`).

use std::os::raw::c_int;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// The Mac's thermal state: `ProcessInfo.ThermalState`, in its order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum Thermal {
    #[default]
    Nominal,
    Fair,
    Serious,
    Critical,
}

/// One reading of the power inputs: the app's `EnergyInputs` as the Mac
/// reports them (no `debug.energy.simulate` layer).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PowerReading {
    /// The battery provides power (false on adapter power, a UPS counted as
    /// AC, and a Mac with no battery).
    pub on_battery: bool,
    /// The Mac has an internal battery.
    pub has_battery: bool,
    /// The internal battery's charge in percent of its full capacity; `None`
    /// without a battery or a capacity.
    pub battery_percent: Option<u8>,
    /// macOS Low Power Mode is on.
    pub low_power_mode: bool,
    /// The Mac's thermal state.
    pub thermal: Thermal,
}

/// A power source the clock thread waits on.
pub trait PowerSource: Send {
    /// The descriptor that turns readable when the power source changes. It
    /// stays open while the source lives.
    fn descriptor(&self) -> c_int;

    /// Drains the descriptor and reads the power source now.
    fn read(&mut self) -> PowerReading;
}

/// A source and who to tell about its readings, on the clock thread.
pub(crate) struct PowerFollow {
    source: Box<dyn PowerSource>,
    deliver: Box<dyn FnMut(PowerReading) + Send>,
    last: Option<PowerReading>,
}

impl PowerFollow {
    pub(crate) fn new(
        source: Box<dyn PowerSource>,
        deliver: Box<dyn FnMut(PowerReading) + Send>,
    ) -> Self {
        Self { source, deliver, last: None }
    }

    pub(crate) fn descriptor(&self) -> c_int {
        self.source.descriptor()
    }

    /// Reads the source and passes the reading on when it differs from the
    /// last one passed on (the first reading always goes). Returns whether it
    /// was passed on.
    pub(crate) fn changed(&mut self) -> bool {
        let reading = self.source.read();
        if self.last == Some(reading) {
            return false;
        }
        self.last = Some(reading);
        let _ = catch_unwind(AssertUnwindSafe(|| (self.deliver)(reading)));
        true
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    fn battery(percent: u8) -> PowerReading {
        PowerReading {
            on_battery: true,
            has_battery: true,
            battery_percent: Some(percent),
            ..PowerReading::default()
        }
    }

    fn plugged() -> PowerReading {
        PowerReading { has_battery: true, battery_percent: Some(15), ..PowerReading::default() }
    }

    #[test]
    fn thermal_states_are_ordered_as_the_apps() {
        assert!(Thermal::Nominal < Thermal::Fair);
        assert!(Thermal::Fair < Thermal::Serious);
        assert!(Thermal::Serious < Thermal::Critical);
        assert_eq!(PowerReading::default().thermal, Thermal::Nominal);
    }

    struct Scripted(Arc<Mutex<Vec<PowerReading>>>);

    impl PowerSource for Scripted {
        fn descriptor(&self) -> c_int {
            7
        }

        fn read(&mut self) -> PowerReading {
            let mut readings = self.0.lock().unwrap();
            if readings.len() > 1 { readings.remove(0) } else { readings[0] }
        }
    }

    #[test]
    fn follow_passes_on_the_first_reading_and_each_change_only() {
        let readings = Arc::new(Mutex::new(vec![plugged(), plugged(), battery(15), battery(15)]));
        let heard = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&heard);
        let mut follow = PowerFollow::new(
            Box::new(Scripted(readings)),
            Box::new(move |reading| sink.lock().unwrap().push(reading)),
        );
        assert_eq!(follow.descriptor(), 7);
        assert!(follow.changed());
        assert!(!follow.changed());
        assert!(follow.changed());
        assert!(!follow.changed());
        assert_eq!(*heard.lock().unwrap(), vec![plugged(), battery(15)]);
    }

    #[test]
    fn a_low_power_mode_or_thermal_change_alone_is_passed_on() {
        let low_power = PowerReading { low_power_mode: true, ..plugged() };
        let hot = PowerReading { thermal: Thermal::Serious, ..battery(60) };
        let readings = Arc::new(Mutex::new(vec![plugged(), low_power, battery(60), hot]));
        let heard = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&heard);
        let mut follow = PowerFollow::new(
            Box::new(Scripted(readings)),
            Box::new(move |reading| sink.lock().unwrap().push(reading)),
        );
        assert!((0..4).all(|_| follow.changed()));
        assert_eq!(*heard.lock().unwrap(), vec![plugged(), low_power, battery(60), hot]);
    }

    #[test]
    fn a_panicking_receiver_does_not_stop_the_follow() {
        let readings = Arc::new(Mutex::new(vec![plugged(), battery(15)]));
        let mut follow =
            PowerFollow::new(Box::new(Scripted(readings)), Box::new(|_| panic!("receiver")));
        assert!(follow.changed());
        assert!(follow.changed());
    }
}
