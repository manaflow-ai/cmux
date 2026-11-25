//! The UI-loop hang watchdog of the interactive client (Leo, 2026-11-24: "dead hang loops ...
//! endless freezes, these soft locks ... these recovery processes needs to be able to happen just
//! automatically"; "in terminals and guis alike").
//!
//! The same design as the Mac app's `MainThreadWatchdog` (CmuxNextControl/Diagnostics):
//!
//! - **Heartbeat.** The event loop marks each turn: [`LoopWatchdog::turn_begin`] when its wait
//!   for events returns, [`LoopWatchdog::turn_end`] before it waits again. Time between the two is
//!   UI-thread work.
//! - **A parked watchdog thread.** `turn_begin` arms a one-shot kernel timer (timerfd on Linux,
//!   a kqueue timer on macOS) and `turn_end` disarms it, so a short turn wakes no other thread and
//!   an idle loop costs the watchdog nothing: it is parked in the kernel with no timeout
//!   ([`alarm`]). Only a turn that outlasts the threshold wakes it; it then checks once per
//!   threshold until the turn ends.
//! - **A stack sample** of the UI thread, taken once per stalled turn ([`sampler`]), raw
//!   addresses named off the hot path.
//! - **A hang** (a turn past [`Config::hang`], 2 s) is written while it runs, since a hang that
//!   never ends is never recorded otherwise: a hang file under `<state root>/hangs/`, a JSON line
//!   in `<state root>/client-hangs.jsonl` that `crash_forward` sends to the app's Sentry project
//!   with the owner's panics, and a client-log warning.
//!
//! Recovery, automatic and in that order:
//!
//! 1. **Known waits are cancelled** ([`waits`]). A UI-thread wait (a daemon request, for one)
//!    registers itself with a bound and a cancel handle; past its bound the watchdog thread runs
//!    the handle and the wait returns its own timeout error, so the loop goes on.
//! 2. **A hang past the restart bound** (30 s, `CMUX_TUI_HANG_RESTART_SECS`, 0 turns it off)
//!    that no cancel ended restarts the client in place ([`restart`]): the outer terminal is
//!    restored, a restore marker is written, and the process `exec`s itself with the same
//!    arguments. The daemon holds every terminal, its scrollback and the layout, so the new client
//!    attaches to the same session with nothing lost; it reports the prior hang once. At most
//!    three restarts in ten minutes, so a hang at startup never loops.
//!
//! The watchdog never traps or aborts: it observes, cancels what declared itself cancellable, and
//! hands the session to a fresh client (the Mac app's rule, cmux#50992).

pub(crate) mod alarm;
mod record;
pub(crate) mod restart;
#[cfg(unix)]
pub(crate) mod sampler;
pub(crate) mod waits;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

pub(crate) use record::HangReport;
pub(crate) use waits::{UiWaitGuard, ui_wait};

/// Thresholds and where hangs go.
#[derive(Clone, Debug)]
pub(crate) struct Config {
    /// A turn longer than this is a stall: it is sampled once.
    pub(crate) threshold: Duration,
    /// A turn longer than this is a hang: it is written while it runs.
    pub(crate) hang: Duration,
    /// A hang this long that no cancel ended restarts the client; `None` never does.
    pub(crate) restart: Option<Duration>,
    /// `<state root>`: `hangs/` and `client-hangs.jsonl` go here; `None` writes nothing.
    pub(crate) dir: Option<PathBuf>,
    /// The session's name, in each record.
    pub(crate) session: String,
}

impl Config {
    /// The interactive client's defaults: 250 ms stall, 2 s hang, 30 s restart (or
    /// `CMUX_TUI_HANG_RESTART_SECS`), records in the cmux-tui state root.
    pub(crate) fn for_client(session: &str) -> Self {
        let restart = std::env::var("CMUX_TUI_HANG_RESTART_SECS")
            .ok()
            .and_then(|value| value.trim().parse::<u64>().ok())
            .map_or(Some(Duration::from_secs(30)), |seconds| {
                (seconds > 0).then(|| Duration::from_secs(seconds.max(5)))
            });
        Config {
            threshold: Duration::from_millis(250),
            hang: Duration::from_secs(2),
            restart,
            dir: record::state_root(),
            session: session.to_string(),
        }
    }
}

/// What the watchdog thread does with a hang and a restart; tests replace both.
pub(crate) trait Sink: Send + Sync + 'static {
    /// A turn passed the hang threshold (once per turn).
    fn hang(&self, report: &HangReport);
    /// A hang passed the restart bound; returns only when the restart did not happen.
    fn restart(&self, report: &HangReport);
}

/// The production sink: hang file, JSON line, client log, Sentry; `exec` restart.
pub(crate) struct ClientSink {
    pub(crate) config: Config,
    /// Puts the outer terminal back as the client found it (cooked mode, main screen); `None`
    /// when this client must not restart (it holds the session's terminals itself).
    pub(crate) restore_terminal: Option<Box<dyn Fn() + Send + Sync>>,
    pub(crate) forwarder: Option<crate::owner_start::HangForwarder>,
}

impl Sink for ClientSink {
    fn hang(&self, report: &HangReport) {
        if let Some(log) = record::write(&self.config, report)
            && let Some(forwarder) = &self.forwarder
        {
            forwarder.send_soon(log);
        }
    }

    fn restart(&self, report: &HangReport) {
        if let Some(restore_terminal) = &self.restore_terminal {
            restart::restart_after_hang(&self.config, report, restore_terminal.as_ref());
        }
    }
}

/// State shared by the UI thread (which writes it) and the watchdog thread (which reads it).
pub(crate) struct Shared {
    config: Config,
    epoch: Instant,
    /// Turn number; moves at each `turn_begin`.
    turn: AtomicU64,
    /// Nanoseconds since `epoch` when the current turn began.
    turn_start: AtomicU64,
    in_turn: AtomicBool,
    running: AtomicBool,
    alarm: alarm::Alarm,
    pub(crate) waits: waits::WaitRegistry,
    /// Finished stalls: count and longest, for `debug`-style reads and tests.
    stalls: AtomicU64,
    longest_stall_ns: AtomicU64,
    /// Watchdog thread wakes (tests count an idle loop's).
    wakes: AtomicU64,
    #[cfg(unix)]
    sampler: Option<sampler::Sampler>,
    sink: Box<dyn Sink>,
}

/// A running watchdog; dropping it stops the thread.
pub(crate) struct LoopWatchdog {
    shared: Arc<Shared>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl LoopWatchdog {
    /// Starts watching the calling thread, which must be the loop's.
    pub(crate) fn start(config: Config, sink: Box<dyn Sink>) -> std::io::Result<Self> {
        let alarm = alarm::Alarm::new()?;
        #[cfg(unix)]
        let sampler = sampler::Sampler::for_current_thread();
        let shared = Arc::new(Shared {
            config,
            epoch: Instant::now(),
            turn: AtomicU64::new(0),
            turn_start: AtomicU64::new(0),
            in_turn: AtomicBool::new(false),
            running: AtomicBool::new(true),
            alarm,
            waits: waits::WaitRegistry::default(),
            stalls: AtomicU64::new(0),
            longest_stall_ns: AtomicU64::new(0),
            wakes: AtomicU64::new(0),
            #[cfg(unix)]
            sampler,
            sink,
        });
        let watched = shared.clone();
        let thread = std::thread::Builder::new()
            .name("cmux-ui-watchdog".into())
            .spawn(move || watch(&watched))?;
        Ok(LoopWatchdog { shared, thread: Some(thread) })
    }

    pub(crate) fn shared(&self) -> &Arc<Shared> {
        &self.shared
    }
}

impl Drop for LoopWatchdog {
    fn drop(&mut self) {
        self.shared.running.store(false, Ordering::Release);
        self.shared.alarm.wake();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Shared {
    fn now_ns(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_nanos()).unwrap_or(u64::MAX)
    }

    /// The loop's wait for events returned: a turn begins. UI thread.
    pub(crate) fn turn_begin(&self) {
        if self.in_turn.load(Ordering::Relaxed) {
            return;
        }
        self.turn_start.store(self.now_ns(), Ordering::Release);
        self.turn.fetch_add(1, Ordering::AcqRel);
        self.in_turn.store(true, Ordering::Release);
        // The watchdog thread wakes only if this turn is still running at the threshold.
        self.alarm.arm(self.config.threshold);
    }

    /// The loop is about to wait for events: the turn ends. UI thread.
    pub(crate) fn turn_end(&self) {
        if !self.in_turn.load(Ordering::Relaxed) {
            return;
        }
        self.in_turn.store(false, Ordering::Release);
        self.alarm.disarm();
        let length = self.now_ns().saturating_sub(self.turn_start.load(Ordering::Acquire));
        if length >= duration_ns(self.config.threshold) {
            self.stalls.fetch_add(1, Ordering::Relaxed);
            self.longest_stall_ns.fetch_max(length, Ordering::Relaxed);
        }
    }

    /// Finished stalls since start, and the longest.
    pub(crate) fn stall_stats(&self) -> (u64, Duration) {
        (
            self.stalls.load(Ordering::Relaxed),
            Duration::from_nanos(self.longest_stall_ns.load(Ordering::Relaxed)),
        )
    }

    /// Times the watchdog thread returned from a wait.
    #[cfg(test)]
    pub(crate) fn watchdog_wakes(&self) -> u64 {
        self.wakes.load(Ordering::Relaxed)
    }
}

fn duration_ns(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

/// A gap between two of the watchdog's own checks at least this long (and four intervals) is
/// time the process did not run, not time the loop hung.
const UNOBSERVED_GAP_NS: u64 = 1_000_000_000;

/// The watchdog thread's loop.
fn watch(shared: &Shared) {
    let threshold = duration_ns(shared.config.threshold);
    let hang = duration_ns(shared.config.hang);
    let restart = shared.config.restart.map(duration_ns);
    let mut sampled_turn = u64::MAX;
    let mut reported_turn = u64::MAX;
    let mut restarted_turn = u64::MAX;
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut stack: Vec<usize> = Vec::new();
    let mut cancelled: Vec<String> = Vec::new();
    // The watchdog's own last check of the current stalled turn: a gap far longer than its
    // interval means this process did not run (stopped with ^Z, a debugger, a suspended host),
    // and that time is not a hang the client caused.
    let mut last_check: Option<(u64, u64)> = None;
    let mut unobserved_ns: u64 = 0;
    while shared.running.load(Ordering::Acquire) {
        if !shared.in_turn.load(Ordering::Acquire) {
            // Parked until a turn outlasts the threshold (its alarm) or stop.
            shared.alarm.wait(None);
            shared.wakes.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        let turn = shared.turn.load(Ordering::Acquire);
        let started = shared.turn_start.load(Ordering::Acquire);
        let now = shared.now_ns();
        let elapsed = now.saturating_sub(started);
        if elapsed < threshold {
            shared.alarm.wait(Some(Duration::from_nanos(threshold - elapsed)));
            shared.wakes.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        // Still the same turn, still running: a stall.
        if turn != shared.turn.load(Ordering::Acquire) || !shared.in_turn.load(Ordering::Acquire) {
            continue;
        }
        match last_check {
            Some((checked_turn, at)) if checked_turn == turn => {
                let gap = now.saturating_sub(at);
                if gap > threshold.saturating_mul(4).max(UNOBSERVED_GAP_NS) {
                    unobserved_ns = unobserved_ns.saturating_add(gap - threshold);
                }
            }
            _ => unobserved_ns = 0,
        }
        last_check = Some((turn, now));
        if sampled_turn != turn {
            sampled_turn = turn;
            cancelled.clear();
            #[cfg(unix)]
            {
                stack = shared.sampler.as_ref().map(sampler::Sampler::sample).unwrap_or_default();
            }
        }
        // Recovery 1: a known wait past its bound is cancelled.
        cancelled.extend(shared.waits.cancel_overdue(Instant::now()));
        let observed = elapsed.saturating_sub(unobserved_ns);
        let report = || HangReport {
            session: shared.config.session.clone(),
            duration: Duration::from_nanos(observed),
            stack: stack.clone(),
            waits: shared.waits.describe(Instant::now()),
            cancelled: cancelled.clone(),
        };
        if observed >= hang && reported_turn != turn {
            reported_turn = turn;
            shared.sink.hang(&report());
        }
        // Recovery 2: a hang past the restart bound hands the session to a fresh client.
        if let Some(restart) = restart
            && observed >= restart
            && restarted_turn != turn
        {
            restarted_turn = turn;
            shared.sink.restart(&report());
        }
        shared.alarm.wait(Some(Duration::from_nanos(threshold)));
        shared.wakes.fetch_add(1, Ordering::Relaxed);
    }
}

/// The interactive client's watchdog, once started (`run.rs`); the event loop marks turns on it.
static CLIENT: OnceLock<Mutex<Option<Arc<Shared>>>> = OnceLock::new();

fn client_slot() -> &'static Mutex<Option<Arc<Shared>>> {
    CLIENT.get_or_init(|| Mutex::new(None))
}

/// Starts the client's watchdog on the calling (UI) thread; the returned guard stops it.
/// `restore_terminal` is `Some` when the client may restart itself after a hang (the daemon holds
/// its session). Reports a prior hang restart once, and sends the hangs not sent yet.
pub(crate) fn start_client(
    session: &str,
    restore_terminal: Option<Box<dyn Fn() + Send + Sync>>,
) -> Option<LoopWatchdog> {
    let config = Config::for_client(session);
    restart::take_restore_marker(&config);
    let forwarder = config
        .dir
        .as_ref()
        .and_then(|dir| crate::owner_start::forward_client_hangs(record::hang_log(dir)));
    let sink = ClientSink { config: config.clone(), restore_terminal, forwarder };
    let watchdog = match LoopWatchdog::start(config, Box::new(sink)) {
        Ok(watchdog) => watchdog,
        Err(error) => {
            crate::client_log::warn("hangs", &format!("no UI watchdog: {error}"));
            return None;
        }
    };
    waits::set_ui_thread(std::thread::current().id());
    *client_slot().lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some(watchdog.shared().clone());
    Some(watchdog)
}

/// Stops marking turns on the client's watchdog (the loop ended).
pub(crate) fn stop_client() {
    let shared = client_slot().lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    if let Some(shared) = shared {
        let (stalls, longest) = shared.stall_stats();
        if stalls > 0 {
            crate::client_log::info(
                "hangs",
                &format!("ui loop: {stalls} stalled turns, longest {:.2}s", longest.as_secs_f64()),
            );
        }
    }
}

fn with_client(action: impl FnOnce(&Shared)) {
    if let Some(shared) = client_shared() {
        action(&shared);
    }
}

/// The event loop's wait returned (no-op without a client watchdog).
pub(crate) fn client_turn_begin() {
    with_client(Shared::turn_begin);
}

/// The event loop is about to wait (no-op without a client watchdog).
pub(crate) fn client_turn_end() {
    with_client(Shared::turn_end);
}

/// The client's watchdog state, when one runs.
fn client_shared() -> Option<Arc<Shared>> {
    CLIENT.get()?.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

#[cfg(test)]
#[path = "ui_watchdog_tests.rs"]
mod tests;
