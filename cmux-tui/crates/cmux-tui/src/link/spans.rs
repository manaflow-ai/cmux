//! Where a link command's folder sync spends its time, below the phases its JSON already
//! reports: each machine request (`rpc <op>`), each git this side runs (`git <subcommand>`),
//! each fixed wait (`sleep <why>`) and the steps a pass marks itself ([`Laps`]), summed per
//! name with how many times each ran. A machine job's own timings (`git.seed.*` status
//! `timings`) come along under `remote`. Always on: a lap is two clock reads and a short lock.
//! `cmux link agent move` reports them as `frozen_sync_phases`, `cmux link seed push` as
//! `sync_phases`; [`take`] reads and clears them.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

static SPANS: Mutex<BTreeMap<String, (Duration, u32)>> = Mutex::new(BTreeMap::new());
static REMOTE: Mutex<Vec<Value>> = Mutex::new(Vec::new());

/// Counts `took` once under `name`.
pub(crate) fn add(name: &str, took: Duration) {
    let mut spans = SPANS.lock().unwrap_or_else(PoisonError::into_inner);
    let entry = spans.entry(name.to_owned()).or_default();
    entry.0 += took;
    entry.1 += 1;
}

/// Runs `run`, its time counted under `name`.
pub(crate) fn time<T>(name: &str, run: impl FnOnce() -> T) -> T {
    let started = Instant::now();
    let answer = run();
    add(name, started.elapsed());
    answer
}

/// Sleeps `pause`, counted under `sleep <why>`.
pub(crate) fn sleep(why: &str, pause: Duration) {
    time(&format!("sleep {why}"), || std::thread::sleep(pause));
}

/// The wait between two polls of a job: short first, doubling up to `ceiling`.
///
/// A fixed wait costs every short job the whole wait (a seed job of 150 ms cost 500 ms);
/// this one costs a short job at most as long again as it ran, and a long job the same
/// requests per second as the fixed wait once it reaches `ceiling`.
pub(crate) struct PollWait {
    next: Duration,
    ceiling: Duration,
}

impl PollWait {
    /// The first wait of every job.
    const FIRST: Duration = Duration::from_millis(10);

    pub(crate) fn up_to(ceiling: Duration) -> Self {
        Self { next: Self::FIRST.min(ceiling), ceiling }
    }

    /// The wait to sleep now; the one after it is twice as long, up to the ceiling.
    pub(crate) fn step(&mut self) -> Duration {
        let now = self.next;
        self.next = (now * 2).min(self.ceiling);
        now
    }

    /// Sleeps this step, counted under `sleep <why>`.
    pub(crate) fn sleep(&mut self, why: &str) {
        sleep(why, self.step());
    }
}

/// The name a git run with `args` is counted under: `git <subcommand>`.
pub(crate) fn git_name<'a>(args: impl IntoIterator<Item = &'a OsStr>) -> String {
    format!("git {}", subcommand(args))
}

/// A machine job's `timings` (its status answer's) for `op`.
pub(crate) fn remote(op: &str, status: &Value) {
    if let Some(timings) = status.get("timings") {
        REMOTE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(json!({ "op": op, "timings": timings }));
    }
}

/// Every count since the last take, as `{"spans": {name: {"ms", "n"}}, "remote": [...]}`.
pub(crate) fn take() -> Value {
    let spans = std::mem::take(&mut *SPANS.lock().unwrap_or_else(PoisonError::into_inner));
    let remote = std::mem::take(&mut *REMOTE.lock().unwrap_or_else(PoisonError::into_inner));
    let spans: Map<String, Value> = spans
        .into_iter()
        .map(|(name, (took, runs))| (name, json!({ "ms": took.as_millis(), "n": runs })))
        .collect();
    json!({ "spans": spans, "remote": remote })
}

/// The steps of one pass, each counted under `<pass>.<step>` from the last mark.
pub(crate) struct Laps {
    pass: &'static str,
    last: Instant,
}

impl Laps {
    pub(crate) fn new(pass: &'static str) -> Self {
        Self { pass, last: Instant::now() }
    }

    pub(crate) fn mark(&mut self, step: &str) {
        let now = Instant::now();
        add(&format!("{}.{step}", self.pass), now.duration_since(self.last));
        self.last = now;
    }
}

/// git's subcommand in `args`: the first that is no option or option value.
fn subcommand<'a>(args: impl IntoIterator<Item = &'a OsStr>) -> String {
    let mut args = args.into_iter().map(|arg| arg.to_string_lossy());
    while let Some(arg) = args.next() {
        match arg.as_ref() {
            "-c" | "-C" | "--git-dir" | "--work-tree" | "--namespace" => {
                args.next();
            }
            option if option.starts_with('-') => {}
            name => return name.to_owned(),
        }
    }
    "?".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subcommand_skips_options_and_their_values() {
        let args = ["-c", "core.fsmonitor=false", "-C", "/tmp", "--no-pager", "bundle", "x"];
        assert_eq!(git_name(args.map(OsStr::new)), "git bundle");
        let bare = ["--git-dir", "/q", "cat-file", "-e"];
        assert_eq!(git_name(bare.map(OsStr::new)), "git cat-file");
    }

    #[test]
    fn a_poll_wait_starts_short_and_stops_at_its_ceiling() {
        let mut wait = PollWait::up_to(Duration::from_millis(500));
        let steps: Vec<u64> = (0..8).map(|_| wait.step().as_millis() as u64).collect();
        assert_eq!(steps, [10, 20, 40, 80, 160, 320, 500, 500]);
        // A job that ends in 150 ms is seen after 150 ms of waits, not 500.
        assert_eq!(steps[..4].iter().sum::<u64>(), 150);
        // A ceiling under the first step is the whole wait.
        assert_eq!(PollWait::up_to(Duration::from_millis(4)).step(), Duration::from_millis(4));
    }
}
