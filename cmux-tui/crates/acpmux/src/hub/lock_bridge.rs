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

/// The worker's wake (a status change), what it last decided, and whether it reads now (a session
/// runs or waits), for `status` views.
struct Bridge {
    wake: Notify,
    state: std::sync::Mutex<Value>,
    reading: std::sync::atomic::AtomicBool,
}

static BRIDGE: LazyLock<Bridge> = LazyLock::new(|| Bridge {
    wake: Notify::new(),
    state: std::sync::Mutex::new(json!({"lock": "unknown", "on": false, "holding": false})),
    reading: std::sync::atomic::AtomicBool::new(false),
});

/// What the lock bridge sees and decides: `{lock, on, holding, lockedForS}`. While the worker
/// reads, its last reading (at most [`TICK`] old, and a status change reads at once). While it is
/// idle it reads nothing, so its last reading would go stale: the lock and the setting are read
/// now, nothing is held, and `lockedForS` is left out (the worker counts a stretch only while a
/// session runs or waits).
pub(crate) fn state() -> Value {
    if BRIDGE.reading.load(std::sync::atomic::Ordering::Acquire) {
        return BRIDGE.state.lock().unwrap_or_else(|e| e.into_inner()).clone();
    }
    idle_state(crate::mac_lock::lock(), setting_now())
}

/// The status of an idle worker: `lock` and `on` as read now, nothing held.
fn idle_state(lock: Lock, on: bool) -> Value {
    json!({"lock": lock.as_str(), "on": on, "holding": false})
}

impl Hub {
    /// A session's status changed: the lock bridge looks again.
    pub(super) fn lock_bridge_wake(&self) {
        BRIDGE.wake.notify_one();
    }

    /// (running, waiting) sessions now.
    fn lock_bridge_counts(&self) -> (usize, usize) {
        self.live_session_handles().iter().fold((0, 0), |(run, wait), s| match s.status() {
            SessionStatus::Running => (run + 1, wait),
            SessionStatus::Waiting => (run, wait + 1),
            _ => (run, wait),
        })
    }

    /// Starts the daemon's one lock-bridge worker, owned by the hub's scope. It holds the hub
    /// weakly and ends with it.
    pub(crate) fn lock_bridge_worker(self: &std::sync::Arc<Self>) {
        let hub = std::sync::Arc::downgrade(self);
        BRIDGE.wake.notify_one();
        self.scope.spawn_until_cancelled("lock-bridge", async move {
            let mut tracker = Tracker::new(Instant::now(), crate::mac_lock::lock());
            loop {
                BRIDGE.wake.notified().await;
                BRIDGE.reading.store(true, std::sync::atomic::Ordering::Release);
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
                // `state` reads the lock and the setting itself while the worker is idle.
                BRIDGE.reading.store(false, std::sync::atomic::Ordering::Release);
            }
        });
    }
}

#[cfg(test)]
#[path = "lock_bridge_tests.rs"]
mod tests;
