//! The clock thread's power follow with a fake notify
//! source: its descriptor's readability wakes the loop, which reads the
//! source and passes each changed reading on, with no timed wait.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use super::*;

const DESCRIPTOR: c_int = 42;

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

/// The battery part of the app's `auto` rule; the whole rule is the daemon's
/// (cmux-tui-core `server/energy_rule.rs`).
fn low_battery(reading: PowerReading) -> bool {
    reading.on_battery && reading.battery_percent.is_some_and(|percent| percent < 20)
}

/// A notify source whose reads return `readings` in order (the last one
/// repeats), as the Mac's power source would after each post.
struct FakeSource(VecDeque<PowerReading>);

impl PowerSource for FakeSource {
    fn descriptor(&self) -> c_int {
        DESCRIPTOR
    }

    fn read(&mut self) -> PowerReading {
        if self.0.len() > 1 { self.0.pop_front().unwrap() } else { self.0[0] }
    }
}

#[derive(Default)]
struct Seen {
    /// Every `until` the loop waited for.
    asked: Vec<Option<SystemTime>>,
    /// The descriptors the loop asked to wait on.
    watched: Vec<c_int>,
}

/// A wait that hands out `wakes` in order, then ends the loop.
struct ScriptedWait {
    wakes: VecDeque<Wake>,
    seen: Arc<Mutex<Seen>>,
    refuse: bool,
}

impl Wait for ScriptedWait {
    fn wait(&mut self, until: Option<SystemTime>, _now: SystemTime) -> Wake {
        self.seen.lock().unwrap().asked.push(until);
        self.wakes.pop_front().unwrap_or(Wake::Closed)
    }

    fn watch_power(&mut self, descriptor: c_int) -> io::Result<()> {
        if self.refuse {
            return Err(io::ErrorKind::Unsupported.into());
        }
        self.seen.lock().unwrap().watched.push(descriptor);
        Ok(())
    }
}

/// Runs the loop over `wakes`, the first a follow of `readings` that flips
/// `mode` by the battery rule; returns what the loop asked and the readings
/// passed on.
fn run(
    readings: &[PowerReading],
    wakes: impl IntoIterator<Item = Wake>,
    mode: &Arc<EnergyMode>,
    refuse: bool,
) -> (Seen, Vec<PowerReading>) {
    let heard = Arc::new(Mutex::new(Vec::new()));
    let (sink, flip) = (Arc::clone(&heard), Arc::clone(mode));
    let follow = PowerFollow::new(
        Box::new(FakeSource(readings.iter().copied().collect())),
        Box::new(move |reading: PowerReading| {
            sink.lock().unwrap().push(reading);
            flip.set_saver(low_battery(reading));
        }),
    );
    let seen = Arc::new(Mutex::new(Seen::default()));
    let mut script = VecDeque::from([Wake::Command(Command::FollowPower(follow))]);
    script.extend(wakes);
    let waiter = ScriptedWait { wakes: script, seen: Arc::clone(&seen), refuse };
    drive(Schedule::default(), waiter, &SystemClock, mode);
    let seen = std::mem::take(&mut *seen.lock().unwrap());
    let heard = heard.lock().unwrap().clone();
    (seen, heard)
}

#[test]
fn an_ac_to_battery_edge_reaches_the_receiver() {
    let mode = EnergyMode::new(false);
    let (seen, heard) = run(&[plugged(), battery(15)], [Wake::Power], &mode, false);
    assert_eq!(seen.watched, vec![DESCRIPTOR]);
    assert_eq!(heard, vec![plugged(), battery(15)], "the first reading, then the edge");
    assert!(mode.is_saver(), "the receiver saw the battery below 20%");
}

#[test]
fn battery_above_the_threshold_keeps_the_saver_off_and_a_repeat_is_not_passed_on() {
    let mode = EnergyMode::new(false);
    let readings = [plugged(), battery(60), battery(60), battery(19), plugged()];
    let (_, heard) = run(&readings, std::iter::repeat_with(|| Wake::Power).take(3), &mode, false);
    assert_eq!(heard, vec![plugged(), battery(60), battery(19)]);
    assert!(mode.is_saver());
    let (_, heard) = run(&readings, std::iter::repeat_with(|| Wake::Power).take(4), &mode, false);
    assert_eq!(heard.last(), Some(&plugged()));
    assert!(!mode.is_saver(), "plugging in ends the battery saver");
}

#[test]
fn following_the_power_source_adds_no_timed_wait() {
    let mode = EnergyMode::new(false);
    let (seen, _) =
        run(&[plugged(), battery(15), plugged()], [Wake::Power, Wake::Power], &mode, false);
    assert!(seen.asked.iter().all(Option::is_none), "{:?}", seen.asked);
}

#[test]
fn a_wait_that_cannot_watch_the_descriptor_reads_nothing() {
    let mode = EnergyMode::new(false);
    let (seen, heard) = run(&[battery(5)], [Wake::Power], &mode, true);
    assert!(seen.watched.is_empty());
    assert!(heard.is_empty(), "Linux follows the app");
    assert!(!mode.is_saver());
}

#[test]
fn a_second_source_is_dropped() {
    let mode = EnergyMode::new(false);
    let other = PowerFollow::new(
        Box::new(FakeSource(VecDeque::from([battery(5)]))),
        Box::new(|_| panic!("the second source is never read")),
    );
    let (seen, heard) =
        run(&[plugged()], [Wake::Command(Command::FollowPower(other)), Wake::Power], &mode, false);
    assert_eq!(seen.watched, vec![DESCRIPTOR]);
    assert_eq!(heard, vec![plugged()]);
}
