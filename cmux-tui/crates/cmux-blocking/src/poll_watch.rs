//! Slow tokio polls, for lab builds only (`RUSTFLAGS="--cfg tokio_unstable"`
//! and the `cmux-stability` feature, `cmux-tui/lab/stability.env`).
//!
//! Chrome times every task on its UI and IO threads between `WillRunTask`
//! and `DidRunTask` and names the task by where it was posted
//! (`content/browser/scheduler/responsiveness/watcher.cc`,
//! `base/task/common/task_annotator.cc`, `PendingTask::posted_from`). Here
//! tokio's poll hooks time each poll of a spawned task: a poll longer than
//! the threshold kept every other task queued behind it on that worker (on a
//! current_thread runtime, every task of the runtime). Time a poll spends in
//! a compensated blocking call ([`crate::scoped_blocking_call`] on a
//! multi_thread worker, inside `block_in_place`) is not counted: another
//! thread runs the worker's queue meanwhile.
//!
//! The first slow poll of each spawn site is written with the site to the
//! sink, the hang JSONL in a daemon. Every slow poll is counted, and the
//! totals go to the sink as one `slow_poll_summary` record when the watch
//! ends ([`PollWatch::finish`], or when the runtime that holds its hooks is
//! dropped), as Chrome's responsiveness watcher reports its janky intervals.
//! With no sink, slow polls are only counted and nothing is written.
//!
//! The futures passed to `block_on` are not tasks and are not timed.

use std::cell::Cell;
use std::panic::Location;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tokio::runtime::{Builder, RuntimeFlavor, TaskMeta};

use crate::RecordSink;

/// The lab's slow-poll threshold.
pub const LAB_THRESHOLD: Duration = Duration::from_millis(2);

/// One slow poll, the first at its spawn site for the watch.
#[derive(Clone, Debug)]
pub struct SlowPoll {
    /// Where the task was spawned.
    pub spawned_at: &'static Location<'static>,
    pub task: tokio::task::Id,
    /// How long the poll ran.
    pub polled: Duration,
    pub thread: Option<String>,
    /// `multi_thread` or `current_thread`: whether the poll held one worker
    /// or the whole runtime.
    pub runtime: &'static str,
}

impl SlowPoll {
    /// The record's JSON fields (the hang JSONL shape).
    pub fn to_fields(&self) -> serde_json::Map<String, serde_json::Value> {
        let spawned_at = format!(
            "{}:{}:{}",
            self.spawned_at.file(),
            self.spawned_at.line(),
            self.spawned_at.column()
        );
        let polled_us = u64::try_from(self.polled.as_micros()).unwrap_or(u64::MAX);
        let mut fields = serde_json::Map::new();
        fields.insert("kind".into(), "slow_poll".into());
        fields.insert("spawned_at".into(), spawned_at.into());
        fields.insert("task_id".into(), self.task.to_string().into());
        fields.insert("polled_us".into(), polled_us.into());
        fields.insert("thread".into(), self.thread.clone().into());
        fields.insert("runtime".into(), self.runtime.into());
        fields
    }
}

/// A watch's totals.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PollCounts {
    /// Polls over the threshold.
    pub slow: u64,
    /// Their total time.
    pub slow_nanos: u64,
    /// Records written (one per spawn site, only while a sink exists).
    pub recorded: u64,
    /// Slow spawn sites past the dedupe table's capacity: counted, not recorded.
    pub sites_dropped: u64,
}

/// A watch's totals when it ended: the `slow_poll_summary` record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PollSummary {
    pub counts: PollCounts,
    pub threshold: Duration,
}

impl PollSummary {
    /// The record's JSON fields (the hang JSONL shape).
    pub fn to_fields(&self) -> serde_json::Map<String, serde_json::Value> {
        let threshold_us = u64::try_from(self.threshold.as_micros()).unwrap_or(u64::MAX);
        let counts = &self.counts;
        let mut fields = serde_json::Map::new();
        fields.insert("kind".into(), "slow_poll_summary".into());
        fields.insert("slow".into(), counts.slow.into());
        fields.insert("slow_us".into(), (counts.slow_nanos / 1_000).into());
        fields.insert("recorded".into(), counts.recorded.into());
        fields.insert("sites_dropped".into(), counts.sites_dropped.into());
        fields.insert("threshold_us".into(), threshold_us.into());
        fields
    }
}

enum Target {
    /// The process's sink ([`crate::install_sink`]), read at record time:
    /// runtimes are often built before the composition root installs it.
    Installed(&'static OnceLock<Box<dyn RecordSink>>),
    Sink(Arc<dyn RecordSink>),
}

impl Target {
    fn sink(&self) -> Option<&dyn RecordSink> {
        match self {
            Self::Installed(installed) => installed.get().map(|sink| &**sink),
            Self::Sink(sink) => Some(&**sink),
        }
    }
}

struct Inner {
    threshold: Duration,
    target: Target,
    sites: Box<[AtomicU64]>,
    slow: AtomicU64,
    slow_nanos: AtomicU64,
    recorded: AtomicU64,
    sites_dropped: AtomicU64,
    finished: AtomicBool,
}

impl Inner {
    fn counts(&self) -> PollCounts {
        PollCounts {
            slow: self.slow.load(Ordering::Relaxed),
            slow_nanos: self.slow_nanos.load(Ordering::Relaxed),
            recorded: self.recorded.load(Ordering::Relaxed),
            sites_dropped: self.sites_dropped.load(Ordering::Relaxed),
        }
    }

    /// Write the summary once, if a poll was slow and a sink exists.
    fn finish(&self) {
        if self.finished.swap(true, Ordering::AcqRel) {
            return;
        }
        let counts = self.counts();
        if counts.slow == 0 {
            return;
        }
        if let Some(sink) = self.target.sink() {
            sink.slow_poll_summary(&PollSummary { counts, threshold: self.threshold });
        }
    }
}

impl Drop for Inner {
    /// The runtime that held the hooks was dropped: the watch ended.
    fn drop(&mut self) {
        self.finish();
    }
}

/// Times the task polls of the runtimes it instruments. Clones share one
/// set of counts and spawn sites.
#[derive(Clone)]
pub struct PollWatch(Arc<Inner>);

/// The poll running on a thread.
#[derive(Clone, Copy)]
struct Poll {
    task: tokio::task::Id,
    started: Instant,
    /// Time spent in compensated blocking calls (`block_in_place`).
    compensated: Duration,
}

thread_local! {
    static POLL: Cell<Option<Poll>> = const { Cell::new(None) };
}

/// [`crate::scoped_blocking_call`] ran a call inside `block_in_place` for
/// `spent`: another thread ran the worker's queue meanwhile, so the poll on
/// this thread held no worker for that time.
pub(crate) fn note_compensated(spent: Duration) {
    POLL.with(|poll| {
        if let Some(mut running) = poll.get() {
            running.compensated = running.compensated.saturating_add(spent);
            poll.set(Some(running));
        }
    });
}

impl PollWatch {
    /// The lab's watch: polls over [`LAB_THRESHOLD`] go to the process's
    /// installed sink.
    pub fn lab() -> Self {
        Self::new(LAB_THRESHOLD, Target::Installed(&crate::sink::SINK))
    }

    /// A watch that writes to `sink`.
    pub fn with_sink(threshold: Duration, sink: Arc<dyn RecordSink>) -> Self {
        Self::new(threshold, Target::Sink(sink))
    }

    fn new(threshold: Duration, target: Target) -> Self {
        Self(Arc::new(Inner {
            threshold,
            target,
            sites: (0..SITE_CAPACITY).map(|_| AtomicU64::new(0)).collect(),
            slow: AtomicU64::new(0),
            slow_nanos: AtomicU64::new(0),
            recorded: AtomicU64::new(0),
            sites_dropped: AtomicU64::new(0),
            finished: AtomicBool::new(false),
        }))
    }

    /// Set `builder`'s task poll hooks to this watch. They replace earlier
    /// `on_before_task_poll` / `on_after_task_poll` hooks, and later ones
    /// replace these.
    pub fn instrument(&self, builder: &mut Builder) {
        let watch = self.clone();
        builder
            .on_before_task_poll(|meta| {
                let started = Instant::now();
                POLL.with(|poll| {
                    poll.set(Some(Poll { task: meta.id(), started, compensated: Duration::ZERO }));
                });
            })
            .on_after_task_poll(move |meta| watch.after_poll(meta));
    }

    /// The totals so far.
    pub fn counts(&self) -> PollCounts {
        self.0.counts()
    }

    /// Write the totals to the sink now, as one `slow_poll_summary` record
    /// (nothing when no poll was slow or no sink exists), for a process that
    /// exits without dropping its runtime. The watch writes no summary after
    /// this one.
    pub fn finish(&self) {
        self.0.finish();
    }

    fn after_poll(&self, meta: &TaskMeta<'_>) {
        // A poll that drove another runtime's tasks on this thread
        // (block_in_place + block_on) lost its start to theirs: not timed.
        let Some(poll) = POLL.with(Cell::take).filter(|poll| poll.task == meta.id()) else {
            return;
        };
        let polled = poll.started.elapsed().saturating_sub(poll.compensated);
        let inner = &self.0;
        if polled <= inner.threshold {
            return;
        }
        inner.slow.fetch_add(1, Ordering::Relaxed);
        inner
            .slow_nanos
            .fetch_add(u64::try_from(polled.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
        // Before the site is marked seen: a slow poll before the composition
        // root installs the sink keeps its site's record for later.
        let Some(sink) = inner.target.sink() else {
            return;
        };
        let spawned_at = meta.spawned_at();
        match first_at_site(&inner.sites, spawned_at) {
            Seen::First => {}
            Seen::Before => return,
            Seen::TableFull => {
                inner.sites_dropped.fetch_add(1, Ordering::Relaxed);
                return;
            }
        }
        let record = SlowPoll {
            spawned_at,
            task: poll.task,
            polled,
            thread: std::thread::current().name().map(str::to_owned),
            runtime: runtime_name(),
        };
        if cfg!(debug_assertions) {
            eprintln!(
                "cmux-blocking: a task spawned at {spawned_at} was polled for {polled:?} (logged once per site)"
            );
        }
        inner.recorded.fetch_add(1, Ordering::Relaxed);
        sink.slow_poll(&record);
    }
}

/// Distinct slow spawn sites one watch records; later ones are counted in
/// [`PollCounts::sites_dropped`].
const SITE_CAPACITY: usize = 1024;

#[derive(Debug, PartialEq, Eq)]
enum Seen {
    First,
    Before,
    TableFull,
}

/// Whether `location` had a slow poll before: a fixed, lock-free
/// open-addressing set of site hashes (0 marks an empty slot), so the poll
/// hook takes no lock and allocates nothing.
fn first_at_site(table: &[AtomicU64], location: &Location<'_>) -> Seen {
    let key = site_key(location);
    let len = table.len();
    let start = usize::try_from(key % len as u64).unwrap_or(0);
    for probe in 0..len {
        let slot = &table[(start + probe) % len];
        match slot.compare_exchange(0, key, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => return Seen::First,
            Err(existing) if existing == key => return Seen::Before,
            Err(_) => {}
        }
    }
    Seen::TableFull
}

/// FNV-1a over `file:line:col`, never 0. Keyed by value, not by the
/// `Location` address, which the compiler may duplicate across codegen units.
fn site_key(location: &Location<'_>) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let bytes = location
        .file()
        .bytes()
        .chain(location.line().to_le_bytes())
        .chain(location.column().to_le_bytes());
    for byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash.max(1)
}

/// The hooks run inside the runtime's context.
fn runtime_name() -> &'static str {
    match tokio::runtime::Handle::try_current().map(|handle| handle.runtime_flavor()) {
        Ok(RuntimeFlavor::CurrentThread) => "current_thread",
        Ok(RuntimeFlavor::MultiThread) => "multi_thread",
        Ok(_) | Err(_) => "other",
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::BlockingRecord;

    #[derive(Default)]
    struct Collector {
        polls: Mutex<Vec<SlowPoll>>,
        summaries: Mutex<Vec<PollSummary>>,
    }

    impl RecordSink for Collector {
        fn record(&self, _record: &BlockingRecord) {}

        fn slow_poll(&self, record: &SlowPoll) {
            self.polls
                .lock()
                .expect("INVARIANT: the collector never panics while holding its lock")
                .push(record.clone());
        }

        fn slow_poll_summary(&self, summary: &PollSummary) {
            self.summaries
                .lock()
                .expect("INVARIANT: the collector never panics while holding its lock")
                .push(*summary);
        }
    }

    impl Collector {
        fn polls(&self) -> Vec<SlowPoll> {
            self.polls
                .lock()
                .expect("INVARIANT: the collector never panics while holding its lock")
                .clone()
        }

        fn summaries(&self) -> Vec<PollSummary> {
            self.summaries
                .lock()
                .expect("INVARIANT: the collector never panics while holding its lock")
                .clone()
        }
    }

    /// An installed sink is boxed; this one forwards to a shared collector.
    struct Forward(Arc<Collector>);

    impl RecordSink for Forward {
        fn record(&self, _record: &BlockingRecord) {}

        fn slow_poll(&self, record: &SlowPoll) {
            self.0.slow_poll(record);
        }

        fn slow_poll_summary(&self, summary: &PollSummary) {
            self.0.slow_poll_summary(summary);
        }
    }

    const SLEEP: Duration = Duration::from_millis(20);

    fn current_thread(watch: &PollWatch) -> tokio::runtime::Runtime {
        let mut builder = Builder::new_current_thread();
        builder.enable_all();
        watch.instrument(&mut builder);
        builder.build().expect("build a current_thread runtime")
    }

    #[test]
    fn a_sleeping_task_records_one_slow_poll_with_its_spawn_site() {
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::with_sink(LAB_THRESHOLD, collector.clone());
        let runtime = current_thread(&watch);
        let line = line!() + 1;
        let task = runtime.spawn(async { std::thread::sleep(SLEEP) });
        runtime.block_on(task).expect("the sleeping task ends");

        let polls = collector.polls();
        assert_eq!(polls.len(), 1, "{polls:?}");
        let poll = &polls[0];
        assert_eq!(poll.spawned_at.file(), file!());
        assert_eq!(poll.spawned_at.line(), line);
        assert!(poll.polled >= SLEEP, "{poll:?}");
        assert_eq!(poll.runtime, "current_thread");
        let fields = poll.to_fields();
        assert_eq!(fields["kind"], "slow_poll");
        assert!(
            fields["spawned_at"].as_str().is_some_and(|at| at.contains(&format!(":{line}:"))),
            "{fields:?}"
        );
        let counts = watch.counts();
        assert_eq!((counts.slow, counts.recorded, counts.sites_dropped), (1, 1, 0), "{counts:?}");
    }

    #[test]
    fn fast_polls_record_nothing() {
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::with_sink(LAB_THRESHOLD, collector.clone());
        let runtime = current_thread(&watch);
        let task = runtime.spawn(async {
            for _ in 0..100 {
                tokio::task::yield_now().await;
            }
        });
        runtime.block_on(task).expect("the yielding task ends");

        assert!(collector.polls().is_empty());
        assert_eq!(watch.counts(), PollCounts::default());
    }

    #[test]
    fn a_site_is_recorded_once_and_counted_each_time_on_multi_thread() {
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::with_sink(LAB_THRESHOLD, collector.clone());
        let mut builder = Builder::new_multi_thread();
        builder.enable_all().worker_threads(2);
        watch.instrument(&mut builder);
        let runtime = builder.build().expect("build a multi_thread runtime");
        let spawn = || runtime.spawn(async { std::thread::sleep(SLEEP) });
        for _ in 0..3 {
            runtime.block_on(spawn()).expect("the sleeping task ends");
        }
        // A join can return before the worker runs its after-poll hook;
        // dropping the runtime joins the workers.
        drop(runtime);

        let polls = collector.polls();
        assert_eq!(polls.len(), 1, "{polls:?}");
        assert_eq!(polls[0].runtime, "multi_thread");
        let counts = watch.counts();
        assert_eq!((counts.slow, counts.recorded), (3, 1), "{counts:?}");
        assert!(counts.slow_nanos >= 3 * u64::try_from(SLEEP.as_nanos()).unwrap_or(u64::MAX));
    }

    /// cmux-blocking's runtime: a wrapper call in one of its tasks runs
    /// inside `block_in_place`.
    fn compensating_multi_thread(watch: &PollWatch) -> tokio::runtime::Runtime {
        let mut builder = crate::runtime::multi_thread();
        builder.worker_threads(2);
        watch.instrument(&mut builder);
        builder.build().expect("build a multi_thread runtime")
    }

    /// Calls that ran in `block_in_place` (a worker not yet seen unparking
    /// counts as unconfirmed; both are compensated).
    fn compensated_calls() -> u64 {
        let counts = crate::counts();
        counts.compensated + counts.unconfirmed
    }

    #[test]
    fn a_compensated_blocking_call_is_not_a_slow_poll() {
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::with_sink(LAB_THRESHOLD, collector.clone());
        // A join can return before the worker runs its after-poll hook;
        // dropping the runtime joins the workers.
        let runtime = compensating_multi_thread(&watch);
        let compensated_before = compensated_calls();
        runtime
            .block_on(runtime.spawn(async { crate::thread::sleep(SLEEP) }))
            .expect("the compensated task ends");
        drop(runtime);
        assert!(compensated_calls() > compensated_before);
        assert!(collector.polls().is_empty(), "{:?}", collector.polls());
        assert_eq!(watch.counts().slow, 0);

        let runtime = compensating_multi_thread(&watch);
        let line = line!() + 1;
        let task = runtime.spawn(async { std::thread::sleep(SLEEP) });
        runtime.block_on(task).expect("the sleeping task ends");
        drop(runtime);
        let polls = collector.polls();
        assert_eq!(polls.len(), 1, "{polls:?}");
        assert_eq!(polls[0].spawned_at.line(), line);
        assert_eq!(watch.counts().slow, 1);
    }

    #[test]
    fn a_slow_poll_before_the_sink_is_installed_keeps_its_site_for_later() {
        static INSTALLED: OnceLock<Box<dyn RecordSink>> = OnceLock::new();
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::new(LAB_THRESHOLD, Target::Installed(&INSTALLED));
        let runtime = current_thread(&watch);
        let spawn = || runtime.spawn(async { std::thread::sleep(SLEEP) });

        runtime.block_on(spawn()).expect("the sleeping task ends");
        let counts = watch.counts();
        assert_eq!((counts.slow, counts.recorded), (1, 0), "{counts:?}");

        assert!(INSTALLED.set(Box::new(Forward(collector.clone()))).is_ok());
        runtime.block_on(spawn()).expect("the sleeping task ends");
        runtime.block_on(spawn()).expect("the sleeping task ends");
        assert_eq!(collector.polls().len(), 1, "{:?}", collector.polls());
        let counts = watch.counts();
        assert_eq!((counts.slow, counts.recorded), (3, 1), "{counts:?}");
    }

    #[test]
    fn the_watch_writes_its_totals_once_when_it_ends() {
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::with_sink(LAB_THRESHOLD, collector.clone());
        let runtime = current_thread(&watch);
        let spawn = || runtime.spawn(async { std::thread::sleep(SLEEP) });
        for _ in 0..2 {
            runtime.block_on(spawn()).expect("the sleeping task ends");
        }
        assert!(collector.summaries().is_empty());

        watch.finish();
        let summaries = collector.summaries();
        assert_eq!(summaries.len(), 1, "{summaries:?}");
        assert_eq!(summaries[0].counts, watch.counts());
        assert_eq!(summaries[0].counts.slow, 2);
        assert_eq!(summaries[0].threshold, LAB_THRESHOLD);
        // Dropping the runtime after finish writes no second summary.
        drop(runtime);
        drop(watch);
        assert_eq!(collector.summaries().len(), 1);
    }

    #[test]
    fn the_site_set_dedupes_by_value_and_reports_full() {
        let table: Vec<AtomicU64> = (0..2).map(|_| AtomicU64::new(0)).collect();
        let (first, second, third) = (Location::caller(), Location::caller(), Location::caller());
        assert_eq!(first_at_site(&table, first), Seen::First);
        assert_eq!(first_at_site(&table, first), Seen::Before);
        assert_eq!(first_at_site(&table, second), Seen::First);
        assert_eq!(first_at_site(&table, third), Seen::TableFull);
        assert_ne!(site_key(first), site_key(second));
    }

    #[test]
    fn a_watch_with_no_slow_poll_writes_no_summary() {
        let collector = Arc::new(Collector::default());
        let watch = PollWatch::with_sink(LAB_THRESHOLD, collector.clone());
        let runtime = current_thread(&watch);
        runtime.block_on(runtime.spawn(async {})).expect("the task ends");
        drop(runtime);
        drop(watch);
        assert!(collector.summaries().is_empty());
    }

    #[test]
    fn the_jsonl_sink_writes_the_slow_poll_line() {
        let path = std::env::temp_dir().join(format!(
            "cmux-blocking-{}-slow-poll-{:?}.jsonl",
            std::process::id(),
            std::time::SystemTime::now()
        ));
        let mut fields = cmux_panic_log::Fields::new();
        fields.insert("process".into(), "poll-watch-test".into());
        let sink = Arc::new(crate::JsonlSink::new(path.clone(), fields));
        let watch = PollWatch::with_sink(LAB_THRESHOLD, sink);
        let runtime = current_thread(&watch);
        runtime
            .block_on(runtime.spawn(async { std::thread::sleep(SLEEP) }))
            .expect("the sleeping task ends");
        // The watch ends with the runtime that holds its hooks.
        drop(runtime);
        drop(watch);

        let text = std::fs::read_to_string(&path).expect("the slow poll lines");
        let _ = std::fs::remove_file(&path);
        let lines: Vec<serde_json::Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).expect("one JSON object per line"))
            .collect();
        assert_eq!(lines.len(), 2, "{text}");
        assert_eq!(lines[0]["kind"], "slow_poll");
        assert_eq!(lines[0]["process"], "poll-watch-test");
        assert_eq!(lines[0]["runtime"], "current_thread");
        assert!(lines[0]["polled_us"].as_u64().is_some_and(|us| us >= 20_000), "{text}");
        assert_eq!(lines[1]["kind"], "slow_poll_summary");
        assert_eq!(lines[1]["process"], "poll-watch-test");
        assert_eq!(lines[1]["slow"], 1, "{text}");
        assert_eq!(lines[1]["recorded"], 1, "{text}");
        assert_eq!(lines[1]["threshold_us"], 2_000, "{text}");
        assert!(lines[1]["slow_us"].as_u64().is_some_and(|us| us >= 20_000), "{text}");
    }
}
