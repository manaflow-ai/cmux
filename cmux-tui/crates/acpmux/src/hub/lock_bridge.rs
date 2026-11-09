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
//! - at most [`CAP`] per locked stretch, however many turns run in it, so neither a turn that
//!   never ends nor turn after turn can keep the Mac up (only an unlock starts a new stretch);
//! - and not past what macOS forces: a closed lid on battery and low battery still sleep it.
//!
//! The worker sleeps on a wake (a session's status changed) and ticks only while some session
//! runs or waits: with none, it releases the hold and waits for the next wake. It never answers
//! a request, and it reads no credential.

use std::sync::LazyLock;
use std::time::{Duration, Instant};

use cmux_config::managed::ManagedPreferences;
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

/// How long the worker waits before it reads again: a [`TICK`], or less when the hold is due to
/// end sooner (the [`CAP`], or the [`WAIT_GRACE`] of a waiting turn), so it never outlives
/// either. A status change ends the wait early.
pub(crate) fn next_wait(i: Inputs) -> Duration {
    if !holds(i) {
        return TICK;
    }
    let mut wait = TICK.min(CAP.saturating_sub(i.locked_for));
    if i.running == 0 {
        wait = wait.min(WAIT_GRACE.saturating_sub(i.since_running));
    }
    wait
}

/// The settings that decide the bridge: the toggle, and Keep Mac Awake that it extends.
const KEEP_AWAKE: &str = "sessions.keepAwake";
const KEYS: [&str; 2] = [SETTING, KEEP_AWAKE];

/// One key's value as cmux applies it: an administrator's forced value, else the settings file's,
/// else an administrator's recommended value (which only replaces the default).
fn effective(doc: Option<&Value>, managed: &ManagedPreferences, key: &str) -> Option<Value> {
    managed
        .forced
        .get(key)
        .cloned()
        .or_else(|| doc.and_then(|doc| crate::user_settings::value(doc, key)))
        .or_else(|| managed.recommended.get(key).cloned())
}

/// Whether the settings turn the bridge on: the toggle is true and `keepAwake` is not "off", each
/// as [`effective`] reads it under the managed values. Anything else (absent, not a boolean, an
/// unreadable file with nothing forced) is off.
pub(crate) fn setting_on(doc: Option<&Value>, managed: &ManagedPreferences) -> bool {
    let on = effective(doc, managed, SETTING) == Some(Value::Bool(true));
    let keep_awake = effective(doc, managed, KEEP_AWAKE);
    on && keep_awake.as_ref().and_then(Value::as_str) != Some("off")
}

/// The managed preferences of the two [`KEYS`] (MDM profiles, `com.manaflow.cmux`), read the way
/// cmux-config reads every other managed setting. Off a Mac the bridge holds nothing.
fn managed_now() -> ManagedPreferences {
    #[cfg(target_os = "macos")]
    {
        use cmux_config::managed::{CfManagedReader, DOMAIN, ManagedReader};
        let keys = KEYS.iter().map(|key| (*key).to_owned()).collect();
        CfManagedReader { domain: DOMAIN.to_owned(), keys }.read()
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = KEYS;
        ManagedPreferences::default()
    }
}

/// What the worker carries from one reading to the next, for the daemon's life: when it last saw
/// a turn run, when it last read the screen unlocked, and when this locked stretch began. Going
/// idle between turns keeps all three, so turns one after another in one locked stretch share its
/// [`CAP`] and the [`WAIT_GRACE`] after the last running turn. Only a read that says unlocked ends
/// a stretch: an unknown read keeps it. The worker does not read while idle, so a stretch it did
/// not see begin (the Mac locked while nothing ran) counts from its last unlocked read: the hold
/// can only end sooner, never later. A worker that has read no unlock (a daemon that starts while
/// the screen is locked or its state is unknown) cannot know when the stretch began, so it holds
/// nothing until a read says unlocked; and a waiting turn it has not seen run gets no grace.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Tracker {
    last_running: Option<Instant>,
    last_unlocked: Option<Instant>,
    locked_since: Option<Instant>,
}

impl Tracker {
    /// A tracker whose worker read `first` at `now`, when it started.
    pub(crate) fn new(now: Instant, first: Lock) -> Self {
        let last_unlocked = matches!(first, Lock::Unlocked | Lock::None).then_some(now);
        Self { last_running: None, last_unlocked, locked_since: None }
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
        // The lock is recorded on every read, the one that goes idle too.
        let locked_for = match lock {
            Lock::Locked => match self.locked_since.or(self.last_unlocked) {
                Some(since) => {
                    self.locked_since = Some(since);
                    now.saturating_duration_since(since)
                }
                None => CAP,
            },
            Lock::Unknown => Duration::ZERO,
            Lock::Unlocked | Lock::None => {
                self.locked_since = None;
                self.last_unlocked = Some(now);
                Duration::ZERO
            }
        };
        if running == 0 && waiting == 0 {
            return None;
        }
        if running > 0 {
            self.last_running = Some(now);
        }
        Some(Inputs {
            on,
            lock,
            running,
            waiting,
            since_running: self
                .last_running
                .map_or(Duration::MAX, |ran| now.saturating_duration_since(ran)),
            locked_for,
        })
    }
}

fn setting_now() -> bool {
    let managed = managed_now();
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => setting_on(Some(&doc), &managed),
        crate::user_settings::Settings::Missing => setting_on(None, &managed),
        // A broken file may hold the person's off: only a forced value decides then.
        crate::user_settings::Settings::Unreadable(_) => setting_on(
            None,
            &ManagedPreferences { forced: managed.forced, ..ManagedPreferences::default() },
        ),
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
            let mut tracker = Tracker::new(Instant::now(), crate::mac_lock::lock());
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
                    let _ = tokio::time::timeout(next_wait(inputs), BRIDGE.wake.notified()).await;
                }
                if hold.take().is_some() {
                    tracing::info!("lock bridge: released (no session runs or waits)");
                }
                let mut state = BRIDGE.state.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(state) = state.as_object_mut() {
                    state.insert("holding".to_owned(), json!(false));
                }
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

    /// One locked stretch, however many turns run in it (review of cmux#37239): a turn that ends
    /// and another that starts while the screen stays locked do not open a new window, nor does
    /// a lock read that fails. Only an unlock ends the stretch.
    #[test]
    fn turns_one_after_another_share_one_locked_stretch() {
        let t0 = Instant::now();
        let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
        let mut tracker = Tracker::new(t0, Lock::Unlocked);
        assert!(holds(tracker.step(true, Lock::Locked, 1, 0, t0).unwrap()));
        assert_eq!(tracker.step(true, Lock::Locked, 0, 0, at(30)), None, "the turn ended: idle");
        let next = tracker.step(true, Lock::Locked, 1, 0, at(31)).unwrap();
        assert_eq!(next.locked_for, Duration::from_secs(31 * 60), "the same stretch: {next:?}");
        assert!(tracker.step(true, Lock::Unknown, 1, 0, at(60)).is_some());
        let late = tracker.step(true, Lock::Locked, 1, 0, at(120)).unwrap();
        assert!(!holds(late), "turn after turn cannot keep a locked Mac up past the cap: {late:?}");
        assert!(tracker.step(true, Lock::Unlocked, 1, 0, at(121)).is_some());
        let relocked = tracker.step(true, Lock::Locked, 1, 0, at(122)).unwrap();
        assert!(holds(relocked), "an unlock ends the stretch: {relocked:?}");
    }

    /// A daemon that restarts during a locked stretch (review of cmux#37239) does not open a
    /// fresh window: it cannot know when the stretch began, so it holds nothing until it reads
    /// an unlock. Restart after restart cannot keep a locked Mac up past the cap.
    #[test]
    fn a_daemon_that_starts_while_locked_holds_nothing_until_an_unlock() {
        let t0 = Instant::now();
        let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
        for first in [Lock::Locked, Lock::Unknown] {
            let mut tracker = Tracker::new(t0, first);
            let locked = tracker.step(true, Lock::Locked, 1, 0, t0).unwrap();
            assert!(!holds(locked), "started {first:?}: no fresh window: {locked:?}");
            assert!(tracker.step(true, Lock::Unknown, 1, 0, at(1)).is_some());
            let still = tracker.step(true, Lock::Locked, 1, 0, at(2)).unwrap();
            assert!(!holds(still), "an unknown read is not an unlock: {still:?}");
            assert!(tracker.step(true, Lock::Unlocked, 1, 0, at(3)).is_some());
            let relocked = tracker.step(true, Lock::Locked, 1, 0, at(4)).unwrap();
            assert!(holds(relocked), "an unlock starts a stretch: {relocked:?}");
            assert_eq!(relocked.locked_for, Duration::from_secs(60), "from the unlocked read");
        }
        let mut unlocked_start = Tracker::new(t0, Lock::Unlocked);
        assert!(holds(unlocked_start.step(true, Lock::Locked, 1, 0, t0).unwrap()));
    }

    /// A Mac that locks while nothing runs (review of cmux#37239 at 1a1ebad0, F2): the worker
    /// does not read while idle, so the stretch counts from its last unlocked read, and a turn
    /// that starts hours into the stretch opens no fresh window.
    #[test]
    fn a_lock_that_began_while_idle_counts_from_the_last_unlocked_read() {
        let t0 = Instant::now();
        let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
        let mut tracker = Tracker::new(t0, Lock::Unlocked);
        assert!(tracker.step(true, Lock::Unlocked, 1, 0, t0).is_some());
        assert_eq!(tracker.step(true, Lock::Unlocked, 0, 0, at(1)), None, "idle");
        let late = tracker.step(true, Lock::Locked, 1, 0, at(180)).unwrap();
        assert!(late.locked_for >= CAP, "the stretch began by the last unlocked read: {late:?}");
        assert!(!holds(late), "no fresh window after an idle lock: {late:?}");
        let soon = Tracker::new(t0, Lock::Unlocked).step(true, Lock::Locked, 1, 0, at(5)).unwrap();
        assert!(holds(soon), "a turn soon after the last unlocked read still holds: {soon:?}");
    }

    /// A daemon that starts with a waiting session restored (review of cmux#37239 at 1a1ebad0,
    /// F3) has not seen a turn run, so the waiting turn gets no fresh [`WAIT_GRACE`].
    #[test]
    fn a_waiting_session_the_daemon_never_saw_run_gets_no_grace() {
        let t0 = Instant::now();
        let mut tracker = Tracker::new(t0, Lock::Unlocked);
        let restored = tracker.step(true, Lock::Locked, 0, 1, t0).unwrap();
        assert!(!holds(restored), "no running turn seen: no grace: {restored:?}");
        assert!(holds(tracker.step(true, Lock::Locked, 1, 0, t0).unwrap()));
        let after = tracker.step(true, Lock::Locked, 0, 1, t0 + Duration::from_secs(60)).unwrap();
        assert!(holds(after), "the grace runs from a turn it saw: {after:?}");
    }

    #[test]
    fn the_setting_is_on_only_when_set_true_and_keep_awake_is_not_off() {
        let none = ManagedPreferences::default();
        let on = |doc: &Value| setting_on(Some(doc), &none);
        assert!(!setting_on(None, &none), "an unreadable file is off");
        assert!(!on(&json!({})), "off by default");
        assert!(!on(&json!({"sessions": {"keepAwakeWhenLocked": "yes"}})));
        assert!(on(&json!({"sessions": {"keepAwakeWhenLocked": true}})));
        assert!(on(&json!({"sessions.keepAwakeWhenLocked": true})), "the flat form too");
        let off = json!({"sessions": {"keepAwakeWhenLocked": true, "keepAwake": "off"}});
        assert!(!on(&off), "Keep Mac Awake off turns the bridge off too");
        let always = json!({"sessions": {"keepAwakeWhenLocked": true, "keepAwake": "always"}});
        assert!(on(&always));
    }

    /// An administrator's value (review of cmux#37239): a forced one wins over the settings
    /// file, as it does for every other setting, and a recommended one only replaces the default.
    #[test]
    fn a_managed_value_wins_over_the_file_and_a_recommended_one_only_over_the_default() {
        let managed = |forced: Value, recommended: Value| ManagedPreferences {
            forced: serde_json::from_value(forced).unwrap(),
            recommended: serde_json::from_value(recommended).unwrap(),
        };
        let file_on = json!({"sessions": {"keepAwakeWhenLocked": true}});
        let forced_off = managed(json!({SETTING: false}), json!({}));
        assert!(!setting_on(Some(&file_on), &forced_off), "a forced off wins over the file");
        let forced_on = managed(json!({SETTING: true}), json!({}));
        assert!(setting_on(Some(&json!({})), &forced_on), "a forced on needs no file value");
        assert!(setting_on(None, &forced_on), "nor a readable file");
        let file_off = json!({"sessions": {"keepAwakeWhenLocked": false}});
        assert!(setting_on(Some(&file_off), &forced_on), "a forced on wins over the file");
        let keep_awake_off = managed(json!({"sessions.keepAwake": "off"}), json!({}));
        assert!(!setting_on(Some(&file_on), &keep_awake_off), "a forced Keep Mac Awake off");
        let recommended_on = managed(json!({}), json!({SETTING: true}));
        assert!(setting_on(Some(&json!({})), &recommended_on), "recommended replaces the default");
        assert!(!setting_on(Some(&file_off), &recommended_on), "the person's own off wins");
    }

    /// The worker reads again when the hold is due to end (review of cmux#37239), not up to a
    /// [`TICK`] later: a hold never outlives its [`CAP`] or its [`WAIT_GRACE`].
    #[test]
    fn the_next_read_comes_no_later_than_the_hold_is_due_to_end() {
        assert_eq!(next_wait(base()), TICK, "far from both bounds: one tick");
        let near_cap = Inputs { locked_for: CAP - Duration::from_secs(3), ..base() };
        assert_eq!(next_wait(near_cap), Duration::from_secs(3));
        let waiting = Inputs {
            running: 0,
            waiting: 1,
            since_running: WAIT_GRACE - Duration::from_secs(2),
            ..base()
        };
        assert_eq!(next_wait(waiting), Duration::from_secs(2));
        let running = Inputs { since_running: WAIT_GRACE - Duration::from_secs(2), ..base() };
        assert_eq!(next_wait(running), TICK, "a running turn has no grace to end");
        assert_eq!(next_wait(Inputs { on: false, ..near_cap }), TICK, "no hold: one tick");
    }
}
