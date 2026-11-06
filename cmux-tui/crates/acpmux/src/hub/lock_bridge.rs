//! The lock bridge: with `sessions.keepAwakeWhenLocked` on, this Mac does not idle to sleep
//! while its screen is locked and an agent turn runs, on battery too (design/lock-bridge.md).
//! Leo, 2026-11-06: "acpmux not dying just cuz mac is locked for whatever reason ... similar to
//! the dont sleep while using feature".
//!
//! It extends `sessions.keepAwake` ("Keep Mac Awake While Agents Work"): that setting's hold
//! (the app's `KeepAwakeService`) is unchanged, and the bridge takes the same idle-sleep
//! assertion (`mac_lock::IdleSleepHold`) only for the case it leaves out, a locked Mac on
//! battery under "While Plugged In". `keepAwake` off turns the bridge off too.
//!
//! The hold is bounded (what [`holds`] decides, each [`TICK`]):
//! - only while the screen is locked ([`Lock::Locked`]; an unknown state holds nothing);
//! - only while a turn runs, or for [`WAIT_GRACE`] after the last one ran while a turn waits on
//!   the person (an answer from their phone can still reach this Mac), never longer;
//! - at most [`CAP`] per locked stretch, so a turn that never ends cannot keep the Mac up;
//! - and not past what macOS forces: a closed lid on battery and low battery still sleep it.
//!
//! The worker sleeps on a wake (a session's status changed) and ticks only while some session
//! runs or waits: with none, it releases the hold and waits for the next wake. It never answers
//! a request, and it reads no credential.

use std::sync::LazyLock;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::sync::Notify;

use super::Hub;
use crate::mac_lock::{IdleSleepHold, Lock};
use crate::store::SessionStatus;

/// How often the worker reads the lock and the setting while a session runs or waits.
pub(crate) const TICK: Duration = Duration::from_secs(15);
/// How long after the last running turn a waiting turn still keeps a locked Mac up.
pub(crate) const WAIT_GRACE: Duration = Duration::from_secs(10 * 60);
/// The longest one locked stretch is held.
pub(crate) const CAP: Duration = Duration::from_secs(2 * 60 * 60);
/// The settings key (schemas/settings/source/sessions.json).
pub(crate) const SETTING: &str = "sessions.keepAwakeWhenLocked";
/// What `pmset -g assertions` names the hold.
const REASON: &str =
    "cmux keeps agents running while this Mac is locked (sessions.keepAwakeWhenLocked)";

/// One tick's view of what the bridge decides on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Inputs {
    /// `sessions.keepAwakeWhenLocked` is on and `sessions.keepAwake` is not off.
    pub on: bool,
    pub lock: Lock,
    /// Sessions running a turn.
    pub running: usize,
    /// Sessions waiting on the person (a permission or a question).
    pub waiting: usize,
    /// Since a turn last ran (zero while one runs).
    pub since_running: Duration,
    /// How long the screen has been locked, as this worker saw it.
    pub locked_for: Duration,
}

/// Whether the bridge holds the Mac awake for these inputs.
pub(crate) fn holds(i: Inputs) -> bool {
    i.on && i.lock == Lock::Locked
        && i.locked_for < CAP
        && (i.running > 0 || (i.waiting > 0 && i.since_running < WAIT_GRACE))
}

/// Whether the settings document turns the bridge on: the toggle is true and `keepAwake` is not
/// "off". Anything else (absent, not a boolean, an unreadable file) is off.
pub(crate) fn setting_on(doc: Option<&Value>) -> bool {
    let Some(doc) = doc else { return false };
    let on = crate::user_settings::value(doc, SETTING) == Some(Value::Bool(true));
    let keep_awake = crate::user_settings::value(doc, "sessions.keepAwake");
    on && keep_awake.as_ref().and_then(Value::as_str) != Some("off")
}

/// What the worker carries from one reading to the next: when a turn last ran, and when this
/// locked stretch began.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Tracker {
    last_running: Instant,
    locked_since: Option<Instant>,
}

impl Tracker {
    pub(crate) fn new(now: Instant) -> Self {
        Self { last_running: now, locked_since: None }
    }

    /// One reading at `now`. `None` when no session runs or waits: the worker goes idle.
    pub(crate) fn step(
        &mut self,
        on: bool,
        lock: Lock,
        running: usize,
        waiting: usize,
        now: Instant,
    ) -> Option<Inputs> {
        if running == 0 && waiting == 0 {
            *self = Self::new(now);
            return None;
        }
        if running > 0 {
            self.last_running = now;
        }
        let locked_for = match (lock, self.locked_since) {
            (Lock::Locked, Some(since)) => now.saturating_duration_since(since),
            (Lock::Locked, None) => {
                self.locked_since = Some(now);
                Duration::ZERO
            }
            _ => {
                self.locked_since = None;
                Duration::ZERO
            }
        };
        Some(Inputs {
            on,
            lock,
            running,
            waiting,
            since_running: now.saturating_duration_since(self.last_running),
            locked_for,
        })
    }
}

fn setting_now() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => setting_on(Some(&doc)),
        _ => false,
    }
}

/// The worker's wake (a status change), and what it last decided, for `status` views.
struct Bridge {
    wake: Notify,
    state: std::sync::Mutex<Value>,
}

static BRIDGE: LazyLock<Bridge> = LazyLock::new(|| Bridge {
    wake: Notify::new(),
    state: std::sync::Mutex::new(json!({"lock": "unknown", "on": false, "holding": false})),
});

/// What the lock bridge last saw and decided: `{lock, on, holding, lockedForS}`.
pub(crate) fn state() -> Value {
    BRIDGE.state.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

impl Hub {
    /// A session's status changed: the lock bridge looks again.
    pub(super) fn lock_bridge_wake(&self) {
        BRIDGE.wake.notify_one();
    }

    /// (running, waiting) sessions now.
    fn lock_bridge_counts(&self) -> (usize, usize) {
        self.session_handles().iter().fold((0, 0), |(run, wait), s| match s.status() {
            SessionStatus::Running => (run + 1, wait),
            SessionStatus::Waiting => (run, wait + 1),
            _ => (run, wait),
        })
    }

    /// Starts the daemon's one lock-bridge worker. It holds the hub weakly and ends with it.
    pub(crate) fn lock_bridge_worker(self: &std::sync::Arc<Self>) {
        let hub = std::sync::Arc::downgrade(self);
        BRIDGE.wake.notify_one();
        tokio::spawn(async move {
            let mut tracker = Tracker::new(Instant::now());
            loop {
                BRIDGE.wake.notified().await;
                let mut hold: Option<IdleSleepHold> = None;
                loop {
                    let Some(strong) = hub.upgrade() else { return };
                    let (running, waiting) = strong.lock_bridge_counts();
                    drop(strong);
                    let lock = crate::mac_lock::lock();
                    let on = setting_now();
                    let Some(inputs) = tracker.step(on, lock, running, waiting, Instant::now())
                    else {
                        break; // nothing runs or waits: release, then sleep until a wake
                    };
                    let locked_for = inputs.locked_for;
                    let want = holds(inputs);
                    if want && hold.is_none() {
                        hold = IdleSleepHold::take(REASON);
                        tracing::info!(
                            taken = hold.is_some(),
                            "lock bridge: holding idle sleep off while locked"
                        );
                    } else if !want && hold.take().is_some() {
                        tracing::info!(?inputs, "lock bridge: released");
                    }
                    *BRIDGE.state.lock().unwrap_or_else(|e| e.into_inner()) = json!({
                        "lock": lock.as_str(), "on": on, "holding": hold.is_some(),
                        "lockedForS": locked_for.as_secs(),
                    });
                    // A status change ends the wait early, so a turn that ends releases at once.
                    let _ = tokio::time::timeout(TICK, BRIDGE.wake.notified()).await;
                }
                if hold.take().is_some() {
                    tracing::info!("lock bridge: released (no session runs or waits)");
                }
                let mut state = BRIDGE.state.lock().unwrap_or_else(|e| e.into_inner());
                state["holding"] = json!(false);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Inputs {
        Inputs {
            on: true,
            lock: Lock::Locked,
            running: 1,
            waiting: 0,
            since_running: Duration::ZERO,
            locked_for: Duration::from_secs(60),
        }
    }

    #[test]
    fn holds_only_while_locked_with_a_running_turn_and_the_toggle_on() {
        assert!(holds(base()));
        assert!(!holds(Inputs { on: false, ..base() }), "off by default: the toggle decides");
        for lock in [Lock::Unlocked, Lock::Unknown, Lock::None] {
            assert!(!holds(Inputs { lock, ..base() }), "{lock:?}: only a locked screen holds");
        }
        assert!(!holds(Inputs { running: 0, ..base() }), "no turn: nothing to keep running");
    }

    #[test]
    fn a_waiting_turn_holds_only_for_the_grace_after_the_last_running_one() {
        let waiting = Inputs { running: 0, waiting: 1, ..base() };
        assert!(holds(Inputs { since_running: Duration::from_secs(60), ..waiting }));
        assert!(
            !holds(Inputs { since_running: WAIT_GRACE, ..waiting }),
            "never indefinitely for a person"
        );
    }

    #[test]
    fn one_locked_stretch_is_held_at_most_the_cap() {
        assert!(holds(Inputs { locked_for: CAP - Duration::from_secs(1), ..base() }));
        assert!(
            !holds(Inputs { locked_for: CAP, ..base() }),
            "a turn that never ends cannot keep the Mac up"
        );
    }

    #[test]
    fn the_setting_is_on_only_when_set_true_and_keep_awake_is_not_off() {
        assert!(!setting_on(None), "an unreadable file is off");
        assert!(!setting_on(Some(&json!({}))), "off by default");
        assert!(!setting_on(Some(&json!({"sessions": {"keepAwakeWhenLocked": "yes"}}))));
        assert!(setting_on(Some(&json!({"sessions": {"keepAwakeWhenLocked": true}}))));
        assert!(
            setting_on(Some(&json!({"sessions.keepAwakeWhenLocked": true}))),
            "the flat form too"
        );
        let off = json!({"sessions": {"keepAwakeWhenLocked": true, "keepAwake": "off"}});
        assert!(!setting_on(Some(&off)), "Keep Mac Awake off turns the bridge off too");
        let always = json!({"sessions": {"keepAwakeWhenLocked": true, "keepAwake": "always"}});
        assert!(setting_on(Some(&always)));
    }
}
