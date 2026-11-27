use std::sync::Mutex;
use std::time::Duration;

use super::*;

/// A scripted idle clock: the person's last deliberate input is at
/// `last_person` (ms on the fake clock), time moves only in `pause`.
struct Script {
    state: Mutex<State>,
}

struct State {
    now: u64,
    /// The person's inputs, ms on the clock; the idle time is since the latest
    /// one at or before now.
    person: Vec<u64>,
    injection: u64,
    readable: bool,
    pauses: u32,
}

impl Script {
    fn new(now: u64, person: &[u64], injection: u64) -> Self {
        Self {
            state: Mutex::new(State {
                now,
                person: person.to_vec(),
                injection,
                readable: true,
                pauses: 0,
            }),
        }
    }
    fn pauses(&self) -> u32 {
        self.state.lock().unwrap().pauses
    }
}

impl IdleClock for Script {
    fn idle_ms(&self) -> Option<u64> {
        let s = self.state.lock().unwrap();
        if !s.readable {
            return None;
        }
        let last = s.person.iter().copied().filter(|&t| t <= s.now).max()?;
        Some(s.now - last)
    }
    fn now_ms(&self) -> u64 {
        self.state.lock().unwrap().now
    }
    fn last_injection_ms(&self) -> u64 {
        self.state.lock().unwrap().injection
    }
    fn pause(&self, duration: Duration) {
        let mut s = self.state.lock().unwrap();
        s.now += duration.as_millis() as u64;
        s.pauses += 1;
    }
}

#[test]
fn a_quiet_person_lets_the_agent_act_at_once() {
    let poll = IdlePoll(Script::new(100_000, &[90_000], 0));
    assert!(poll.wait_idle(Duration::ZERO));
    assert!(poll.wait_idle(Duration::from_secs(15)));
    assert_eq!(poll.0.pauses(), 0);
}

#[test]
fn a_person_typing_now_pauses_the_agent_until_they_stop() {
    // Last key 200 ms ago: the zero-limit probe (the engine's "Paused" check) says not idle,
    // and the real wait returns once IDLE_AFTER has passed since that key.
    let poll = IdlePoll(Script::new(100_000, &[99_800], 0));
    assert!(!poll.wait_idle(Duration::ZERO));
    assert!(poll.wait_idle(Duration::from_secs(15)));
    let waited = poll.0.now_ms() - 100_000;
    assert!(waited >= 1300 && waited <= 1300 + POLL.as_millis() as u64, "waited {waited} ms");
}

#[test]
fn a_person_who_keeps_going_past_the_limit_keeps_control() {
    // A key every 500 ms for 20 s: the 15 s wait runs out and the call is refused.
    let keys: Vec<u64> = (0..40).map(|i| 100_000 + i * 500).collect();
    let poll = IdlePoll(Script::new(100_000, &keys, 0));
    assert!(!poll.wait_idle(Duration::from_secs(15)));
    assert!(poll.0.now_ms() >= 115_000);
}

#[test]
fn our_own_injection_is_not_the_person() {
    // The HID clock saw input 100 ms ago, 20 ms after our own post: ours.
    let poll = IdlePoll(Script::new(100_000, &[99_900], 99_880));
    assert!(poll.wait_idle(Duration::ZERO));
    // Input 900 ms after our post is past the grace: the person's.
    let poll = IdlePoll(Script::new(100_000, &[99_900], 99_000));
    assert!(!poll.wait_idle(Duration::ZERO));
    // Input well before our post is not excused by it.
    let poll = IdlePoll(Script::new(100_000, &[99_700], 99_900));
    assert!(!poll.wait_idle(Duration::ZERO));
}

#[test]
fn no_reading_counts_as_idle() {
    let script = Script::new(100_000, &[99_990], 0);
    script.state.lock().unwrap().readable = false;
    assert!(IdlePoll(script).wait_idle(Duration::ZERO));
}

#[test]
fn the_rule_matches_linux() {
    assert!(person_idle(IDLE_AFTER.as_millis() as u64, 10_000, 0));
    assert!(!person_idle(10, 10_000, 0));
    assert!(person_idle(10, 10_000, 9_980));
    assert!(!person_idle(10, 10_000, 9_000));
}
