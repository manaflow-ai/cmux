//! Slow tokio polls, for lab builds only (`RUSTFLAGS="--cfg tokio_unstable"`
//! and the `cmux-stability` feature, `cmux-tui/lab/stability.env`).
//!
//! Chrome times every task on its UI and IO threads between `WillRunTask`
//! and `DidRunTask` and names the task by where it was posted
//! (`content/browser/scheduler/responsiveness/watcher.cc`,
//! `base/task/common/task_annotator.cc`, `PendingTask::posted_from`). Here
//! tokio's poll hooks time each poll of a spawned task: a poll longer than
//! the threshold kept every other task queued behind it on that worker (on a
//! current_thread runtime, every task of the runtime). The first slow poll of
//! each spawn site is written with the site to the sink, the hang JSONL in a
//! daemon; later ones are counted.
//!
//! The futures passed to `block_on` are not tasks and are not timed.

use std::cell::Cell;
use std::panic::Location;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tokio::runtime::{Builder, RuntimeFlavor, TaskMeta};

use crate::RecordSink;
use crate::sites::{self, Seen};

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
    /// Records written (one per spawn site).
    pub recorded: u64,
    /// Slow spawn sites past the dedupe table's capacity: counted, not recorded.
    pub sites_dropped: u64,
}

enum Target {
    /// The process's sink ([`crate::install_sink`]), read at record time:
    /// runtimes are often built before the composition root installs it.
    Installed,
    Sink(Arc<dyn RecordSink>),
}

struct Inner {
    threshold: Duration,
    target: Target,
    sites: Box<[AtomicU64]>,
    slow: AtomicU64,
    slow_nanos: AtomicU64,
    recorded: AtomicU64,
    sites_dropped: AtomicU64,
}

/// Times the task polls of the runtimes it instruments. Clones share one
/// set of counts and spawn sites.
#[derive(Clone)]
pub struct PollWatch(Arc<Inner>);

thread_local! {
    /// The poll running on this thread: its task and start.
    static POLL: Cell<Option<(tokio::task::Id, Instant)>> = const { Cell::new(None) };
}

impl PollWatch {
    /// The lab's watch: polls over [`LAB_THRESHOLD`] go to the process's
    /// installed sink.
    pub fn lab() -> Self {
        Self::new(LAB_THRESHOLD, Target::Installed)
    }

    /// A watch that writes to `sink`.
    pub fn with_sink(threshold: Duration, sink: Arc<dyn RecordSink>) -> Self {
        Self::new(threshold, Target::Sink(sink))
    }

    fn new(threshold: Duration, target: Target) -> Self {
        Self(Arc::new(Inner {
            threshold,
            target,
            sites: (0..sites::CAPACITY).map(|_| AtomicU64::new(0)).collect(),
            slow: AtomicU64::new(0),
            slow_nanos: AtomicU64::new(0),
            recorded: AtomicU64::new(0),
            sites_dropped: AtomicU64::new(0),
        }))
    }

    /// Set `builder`'s task poll hooks to this watch. They replace earlier
    /// `on_before_task_poll` / `on_after_task_poll` hooks, and later ones
    /// replace these.
    pub fn instrument(&self, builder: &mut Builder) {
        let watch = self.clone();
        builder
            .on_before_task_poll(|meta| {
                POLL.with(|poll| poll.set(Some((meta.id(), Instant::now()))));
            })
            .on_after_task_poll(move |meta| watch.after_poll(meta));
    }

    /// The totals so far.
    pub fn counts(&self) -> PollCounts {
        let inner = &self.0;
        PollCounts {
            slow: inner.slow.load(Ordering::Relaxed),
            slow_nanos: inner.slow_nanos.load(Ordering::Relaxed),
            recorded: inner.recorded.load(Ordering::Relaxed),
            sites_dropped: inner.sites_dropped.load(Ordering::Relaxed),
        }
    }

    fn after_poll(&self, meta: &TaskMeta<'_>) {
        // A poll that drove another runtime's tasks on this thread
        // (block_in_place + block_on) lost its start to theirs: not timed.
        let Some((task, started)) = POLL.with(Cell::take).filter(|(id, _)| *id == meta.id()) else {
            return;
        };
        let polled = started.elapsed();
        let inner = &self.0;
        if polled <= inner.threshold {
            return;
        }
        inner.slow.fetch_add(1, Ordering::Relaxed);
        inner
            .slow_nanos
            .fetch_add(u64::try_from(polled.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
        let spawned_at = meta.spawned_at();
        match sites::insert(&inner.sites, sites::site_key(spawned_at)) {
            Seen::First => {}
            Seen::Before => return,
            Seen::TableFull => {
                inner.sites_dropped.fetch_add(1, Ordering::Relaxed);
                return;
            }
        }
        let record = SlowPoll {
            spawned_at,
            task,
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
        match &inner.target {
            Target::Installed => crate::sink::emit_slow_poll(&record),
            Target::Sink(sink) => sink.slow_poll(&record),
        }
    }
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
    struct Collector(Mutex<Vec<SlowPoll>>);

    impl RecordSink for Collector {
        fn record(&self, _record: &BlockingRecord) {}

        fn slow_poll(&self, record: &SlowPoll) {
            self.0
                .lock()
                .expect("INVARIANT: the collector never panics while holding its lock")
                .push(record.clone());
        }
    }

    impl Collector {
        fn polls(&self) -> Vec<SlowPoll> {
            self.0
                .lock()
                .expect("INVARIANT: the collector never panics while holding its lock")
                .clone()
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

        let polls = collector.polls();
        assert_eq!(polls.len(), 1, "{polls:?}");
        assert_eq!(polls[0].runtime, "multi_thread");
        let counts = watch.counts();
        assert_eq!((counts.slow, counts.recorded), (3, 1), "{counts:?}");
        assert!(counts.slow_nanos >= 3 * u64::try_from(SLEEP.as_nanos()).unwrap_or(u64::MAX));
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

        let text = std::fs::read_to_string(&path).expect("the slow poll line");
        let _ = std::fs::remove_file(&path);
        let lines: Vec<serde_json::Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).expect("one JSON object per line"))
            .collect();
        assert_eq!(lines.len(), 1, "{text}");
        assert_eq!(lines[0]["kind"], "slow_poll");
        assert_eq!(lines[0]["process"], "poll-watch-test");
        assert_eq!(lines[0]["runtime"], "current_thread");
        assert!(lines[0]["polled_us"].as_u64().is_some_and(|us| us >= 20_000), "{text}");
    }
}
