//! What a dial is waiting on, said while it waits: with `CMUX_CARRIER_PROGRESS=1`
//! in its environment, `cmux carrier dial` writes progress lines on stderr
//! *before* its one reply line, about once a second while the text changes:
//!
//! `{"progress":{"stage":"waking","text":"Waking up the machine, about 25 s left","eta_ms":25000,"deadline_ms":150000}}`
//!
//! - `stage`: the step the dial is in. `access` (the carrier ticket and grant
//!   from cmux-platform), `relay` (the relay's control socket), `machine` (the
//!   relay holds the connect until the machine's daemon registers),
//!   `waking` (the same hold past [`WAKE_AFTER`]: a paused machine resuming,
//!   or one starting its daemon), `securing` (the Noise handshake and the
//!   daemon's mux stream), `desktop` (the desktop stream's open) and
//!   `retrying` (between two attempts).
//! - `text`: one line for a person, the stage's reason and how long is left;
//!   a stage that ran past its usual time says so and when the dial gives up.
//! - `eta_ms`: the expected time to the connected reply; `deadline_ms`: the
//!   time left before the dial gives up.
//!
//! The usual durations are this Mac's own: the medians of the last
//! successful attempts' `carrier.phases` lines in the connect log
//! ([`Expected::from_log`]), else fixed defaults.
//!
//! Without the variable nothing changes: the reply line stays stderr's first
//! line, as every other reader of the dial (the Cloud app server, `serve`)
//! expects. No progress line follows the reply line.

use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::json;
use tokio::time::Instant;

use super::client::{Marks, Progress};

/// The environment variable that turns progress lines on (`1`).
pub(super) const ENV: &str = "CMUX_CARRIER_PROGRESS";
/// A hold on the machine longer than this is the machine waking up.
pub(super) const WAKE_AFTER: Duration = Duration::from_secs(2);
/// How often the line is written again while its text changes.
const TICK: Duration = Duration::from_secs(1);
/// How many recent successful attempts the usual durations come from.
const HISTORY: usize = 20;
/// How much of the connect log's end is read for them.
const HISTORY_BYTES: u64 = 64 * 1024;

/// A step of the dial as a person reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Stage {
    Access,
    Relay,
    Machine,
    Waking,
    Securing,
    Desktop,
    Retrying,
}

impl Stage {
    pub(super) fn id(self) -> &'static str {
        match self {
            Self::Access => "access",
            Self::Relay => "relay",
            Self::Machine => "machine",
            Self::Waking => "waking",
            Self::Securing => "securing",
            Self::Desktop => "desktop",
            Self::Retrying => "retrying",
        }
    }

    /// Why the person waits, in a few words.
    pub(super) fn reason(self) -> &'static str {
        match self {
            Self::Access => "Getting access to the machine",
            Self::Relay => "Reaching the Cloud relay",
            Self::Machine => "Reaching the machine",
            Self::Waking => "Waking up the machine",
            Self::Securing => "Securing the connection",
            Self::Desktop => "Opening the desktop",
            Self::Retrying => "Trying the connection again",
        }
    }
}

/// How long each stage usually takes. `parked` is a hold that did not wake
/// the machine; `waking` the whole hold of one that did (it includes the
/// first [`WAKE_AFTER`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Expected {
    pub access: Duration,
    pub relay: Duration,
    pub parked: Duration,
    pub waking: Duration,
    pub securing: Duration,
    pub desktop: Duration,
    pub retry: Duration,
}

impl Default for Expected {
    fn default() -> Self {
        let ms = Duration::from_millis;
        Self {
            access: ms(1_500),
            relay: ms(1_000),
            parked: ms(500),
            waking: ms(30_000),
            securing: ms(1_500),
            desktop: ms(2_000),
            retry: ms(3_000),
        }
    }
}

/// The value of `key=` among a line's words.
fn field(line: &str, key: &str) -> Option<u64> {
    line.split_whitespace()
        .find_map(|word| word.strip_prefix(key)?.strip_prefix('='))
        .and_then(|value| value.parse().ok())
}

/// The middle value of at least three, in milliseconds.
fn median(mut values: Vec<u64>) -> Option<Duration> {
    if values.len() < 3 {
        return None;
    }
    values.sort_unstable();
    values.get(values.len() / 2).map(|ms| Duration::from_millis(*ms))
}

impl Expected {
    /// The defaults, each replaced by the median of the last [`HISTORY`]
    /// successful attempts' `carrier.phases` lines in `log` that have three
    /// or more samples of it. The mux stream's open stands for the desktop's
    /// (both are one stream open on the session).
    pub(super) fn from_log(log: &str) -> Self {
        let lines: Vec<&str> = log
            .lines()
            .filter(|line| line.starts_with("carrier.phases ") && line.contains(" outcome=ok "))
            .collect();
        let recent = lines.iter().rev().take(HISTORY);
        let column =
            |key: &str| -> Vec<u64> { recent.clone().filter_map(|l| field(l, key)).collect() };
        let parked = column("parked_ms");
        let wake = WAKE_AFTER.as_millis() as u64;
        let (woke, held): (Vec<u64>, Vec<u64>) = parked.into_iter().partition(|ms| *ms >= wake);
        let securing: Vec<u64> = recent
            .clone()
            .filter_map(|l| Some(field(l, "handshake_ms")?.saturating_add(field(l, "mux_ms")?)))
            .collect();
        let defaults = Self::default();
        Self {
            access: median(column("ticket_ms")).unwrap_or(defaults.access),
            relay: median(column("relay_ms")).unwrap_or(defaults.relay),
            parked: median(held).unwrap_or(defaults.parked),
            waking: median(woke).unwrap_or(defaults.waking),
            securing: median(securing).unwrap_or(defaults.securing),
            desktop: median(column("mux_ms")).unwrap_or(defaults.desktop),
            retry: defaults.retry,
        }
    }

    /// [`Self::from_log`] over the end of the connect log at `path`; the
    /// defaults when there is none.
    pub(super) fn read(path: Option<&Path>) -> Self {
        let Some(path) = path else { return Self::default() };
        let Ok(mut file) = std::fs::File::open(path) else { return Self::default() };
        let start = file.metadata().map_or(0, |m| m.len().saturating_sub(HISTORY_BYTES));
        let mut bytes = Vec::new();
        if file.seek(SeekFrom::Start(start)).is_err()
            || file.take(HISTORY_BYTES).read_to_end(&mut bytes).is_err()
        {
            return Self::default();
        }
        Self::from_log(&String::from_utf8_lossy(&bytes))
    }

    fn of(&self, stage: Stage) -> Duration {
        match stage {
            Stage::Access => self.access,
            Stage::Relay => self.relay,
            Stage::Machine => self.parked,
            Stage::Waking => self.waking,
            Stage::Securing => self.securing,
            Stage::Desktop => self.desktop,
            Stage::Retrying => self.retry,
        }
    }

    /// The usual time from the start of `stage` to the connected reply: the
    /// stage and every one after it. A hold that has not woken the machine
    /// counts as a short one; a retry is followed by a whole attempt.
    fn through(&self, stage: Stage, desktop: bool) -> Duration {
        let tail = if desktop { self.desktop } else { Duration::ZERO };
        let attempt_from = |stage: Stage| -> Duration {
            let order = [Stage::Access, Stage::Relay, Stage::Machine, Stage::Securing];
            let at = match stage {
                Stage::Waking => Stage::Machine,
                other => other,
            };
            let rest: Duration =
                order.iter().skip_while(|s| **s != at).skip(1).map(|s| self.of(*s)).sum();
            self.of(stage) + rest + tail
        };
        match stage {
            Stage::Desktop => self.desktop,
            Stage::Retrying => self.retry + attempt_from(Stage::Access),
            other => attempt_from(other),
        }
    }
}

/// The stage an attempt is in by its marks at `now`, and how long it has
/// been in it. A hold on the machine is `waking` once it passed
/// [`WAKE_AFTER`], counted from the hold's start.
pub(super) fn stage_of(marks: &Marks, now: Instant) -> (Stage, Duration) {
    let since = |mark: Instant| now.saturating_duration_since(mark);
    if let Some(at) = marks.first_allocated {
        return (Stage::Securing, since(at));
    }
    if let Some(at) = marks.first_open {
        let held = since(at);
        return (if held >= WAKE_AFTER { Stage::Waking } else { Stage::Machine }, held);
    }
    if let Some(at) = marks.answered {
        return (Stage::Relay, since(at));
    }
    (Stage::Access, marks.started.map_or(Duration::ZERO, since))
}

/// `12 s`, `1 min`, `2 min 40 s`: whole seconds, at least 1.
pub(super) fn spoken(duration: Duration) -> String {
    let secs = duration.as_secs().saturating_add(u64::from(duration.subsec_nanos() > 0)).max(1);
    match (secs / 60, secs % 60) {
        (0, s) => format!("{s} s"),
        (m, 0) => format!("{m} min"),
        (m, s) => format!("{m} min {s} s"),
    }
}

/// One progress line for `stage`, `in_stage` into it, with `left` before
/// the deadline.
pub(super) fn line(
    stage: Stage,
    in_stage: Duration,
    left: Duration,
    expected: &Expected,
    desktop: bool,
) -> String {
    let usual = expected.of(stage);
    let eta = expected.through(stage, desktop).saturating_sub(in_stage.min(usual));
    // Past its usual time (with a second's slack, so a usual time near zero
    // does not flip at once) the stage says so, and when the dial stops.
    // A short hold is not late: past [`WAKE_AFTER`] it is `waking`.
    let late = stage != Stage::Machine && in_stage > usual + Duration::from_secs(1);
    let text = if late {
        format!("{}: taking longer than usual, stops trying in {}", stage.reason(), spoken(left))
    } else {
        format!("{}, about {} left", stage.reason(), spoken(eta.min(left)))
    };
    let eta_ms = if late { left } else { eta.min(left) }.as_millis() as u64;
    cmux_link::dial::line(&json!({
        "progress": {
            "stage": stage.id(),
            "text": text,
            "eta_ms": eta_ms,
            "deadline_ms": left.as_millis() as u64,
        }
    }))
}

/// Where the dial is, as its attempts and the desktop's open say.
#[derive(Default)]
struct State {
    attempt: Option<Arc<Progress>>,
    /// When the last failed attempt ended, while no other runs.
    between: Option<Instant>,
    desktop: Option<Instant>,
    /// The last line written.
    last: String,
    stopped: bool,
}

/// The progress lines of one dial: [`Reporter::tick`] writes the current
/// line when its text changed; [`Reporter::stop`] ends them before the
/// reply line.
pub(super) struct Reporter {
    state: Mutex<State>,
    started: Instant,
    deadline: Instant,
    expected: Expected,
    desktop: bool,
    write: Box<dyn Fn(&str) + Send + Sync>,
}

impl Reporter {
    pub(super) fn new(
        expected: Expected,
        deadline: Instant,
        desktop: bool,
        write: impl Fn(&str) + Send + Sync + 'static,
    ) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::default(),
            started: Instant::now(),
            deadline,
            expected,
            desktop,
            write: Box::new(write),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// An attempt started; its marks say its stage from now on.
    pub(super) fn attempt(&self, progress: Arc<Progress>) {
        let mut state = self.lock();
        state.attempt = Some(progress);
        state.between = None;
        state.desktop = None;
    }

    /// The attempt failed and another may follow.
    pub(super) fn retrying(&self) {
        let mut state = self.lock();
        state.attempt = None;
        state.between = Some(Instant::now());
    }

    /// The session is up and the desktop stream opens.
    pub(super) fn desktop(&self) {
        self.lock().desktop = Some(Instant::now());
    }

    /// The stage at `now` and how long the dial has been in it.
    fn current(&self, state: &State, now: Instant) -> (Stage, Duration) {
        let since = |at: Instant| now.saturating_duration_since(at);
        if let Some(at) = state.desktop {
            return (Stage::Desktop, since(at));
        }
        if let Some(at) = state.between {
            return (Stage::Retrying, since(at));
        }
        match &state.attempt {
            Some(attempt) => stage_of(&attempt.marks(), now),
            None => (Stage::Access, since(self.started)),
        }
    }

    /// Writes the current line if its text changed. The write happens under
    /// the state's lock, so none can follow [`Self::stop`].
    pub(super) fn tick(&self) {
        let now = Instant::now();
        let mut state = self.lock();
        if state.stopped {
            return;
        }
        let (stage, in_stage) = self.current(&state, now);
        let left = self.deadline.saturating_duration_since(now);
        let line = line(stage, in_stage, left, &self.expected, self.desktop);
        if line != state.last {
            (self.write)(&line);
            state.last = line;
        }
    }

    /// No line after this returns.
    pub(super) fn stop(&self) {
        self.lock().stopped = true;
    }

    /// Ticks every [`TICK`] (the first at once) until stopped.
    pub(super) fn spawn(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let reporter = self.clone();
        tokio::spawn(async move {
            let mut ticks = tokio::time::interval(TICK);
            ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                ticks.tick().await;
                if reporter.lock().stopped {
                    return;
                }
                reporter.tick();
            }
        })
    }
}

#[cfg(test)]
#[path = "progress_tests.rs"]
mod tests;
