//! Blocking calls on tokio threads: Chrome's `MayBlock` and
//! `ScopedBlockingCall` for the cmux daemons.
//!
//! Chrome lets a thread block only when it says so: `base::MayBlock()` on a
//! ThreadPool task (`base/task/task_traits.h`), `ScopedAllowBlocking`
//! (`base/threading/thread_restrictions.h`), and every blocking primitive
//! opens a `ScopedBlockingCall` (`base/threading/scoped_blocking_call.h`)
//! that asserts the thread may block and lets the pool add a worker while it
//! waits (`base/task/thread_pool/thread_group.cc`, compensation).
//!
//! Here each thread has a [`ThreadKind`]. [`runtime::multi_thread`] marks the
//! runtime's threads [`ThreadKind::NoBlock`]; [`runtime::block_on`] marks the
//! thread that drives a runtime for the length of the call;
//! [`spawn_blocking`] and [`ThreadKindScope`] mark work that may block.
//! Threads nobody marked (test runtimes, plain std threads) are
//! [`ThreadKind::Unknown`] and are only counted.
//!
//! The wrappers in [`fs`], [`process`], [`sync`] and [`thread`] go through
//! [`scoped_blocking_call`], which on a `NoBlock` thread:
//! - on a multi_thread runtime runs the call inside
//!   `tokio::task::block_in_place`, which hands the worker's queue to a new
//!   thread for the length of the call (Chrome's compensation), and counts it;
//! - on a current_thread runtime cannot compensate: the whole runtime stalls.
//!   It counts the stall, writes one record per call site (with the caller's
//!   `#[track_caller]` location) to the installed [`RecordSink`], logs the
//!   site once in debug builds, and panics only in this crate's own tests or
//!   when `CMUX_BLOCKING_STRICT=1` (the lab).
//!
//! Tokio has no delayed compensation, so [`BlockingType::MayBlock`] and
//! [`BlockingType::WillBlock`] are compensated the same way; the type is kept
//! in the record so the lab can tell cache-hit-likely calls from waits.

#![forbid(unsafe_code)]

pub mod fs;
#[cfg(all(tokio_unstable, feature = "cmux-stability"))]
pub mod poll_watch;
pub mod process;
pub mod runtime;
mod sink;
mod sites;
pub mod sync;
pub mod thread;

#[cfg(test)]
mod tests;

pub use sink::{JsonlSink, RecordSink, SinkAlreadyInstalled, install_sink};

use std::cell::Cell;
use std::marker::PhantomData;
use std::panic::Location;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Whether the current thread may block.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThreadKind {
    /// Nobody marked this thread (test runtimes, plain std threads). Counted,
    /// never treated as a violation.
    Unknown,
    /// A tokio worker or a thread inside [`runtime::block_on`]: blocking here
    /// stalls other tasks.
    NoBlock,
    /// [`spawn_blocking`] work or a [`ThreadKindScope`] that allows blocking.
    MayBlock,
}

/// Chrome's `base::BlockingType`: how likely the call is to wait.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockingType {
    /// May return at once (a file read that hits the page cache).
    MayBlock,
    /// Waits by design (sleep, channel receive, child process).
    WillBlock,
}

impl BlockingType {
    fn as_str(self) -> &'static str {
        match self {
            Self::MayBlock => "may_block",
            Self::WillBlock => "will_block",
        }
    }
}

/// What [`scoped_blocking_call`] did with one call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The thread may block; the call ran as is.
    Allowed,
    /// A multi_thread worker: the call ran inside `block_in_place`.
    Compensated,
    /// A `NoBlock` thread with no multi_thread runtime to compensate: the
    /// thread's runtime made no progress for the length of the call.
    Stalled,
    /// An unmarked thread: the call ran as is.
    Unknown,
}

impl Outcome {
    fn as_str(self) -> &'static str {
        match self {
            Self::Allowed => "allowed",
            Self::Compensated => "compensated",
            Self::Stalled => "stalled",
            Self::Unknown => "unknown",
        }
    }
}

/// One stalled call, the first at its call site in this process.
#[derive(Clone, Debug)]
pub struct BlockingRecord {
    /// The wrapper that blocked, for example `fs::read`.
    pub op: &'static str,
    pub blocking_type: BlockingType,
    pub outcome: Outcome,
    /// The caller of the wrapper.
    pub location: &'static Location<'static>,
    pub thread: Option<String>,
    /// How long the runtime made no progress.
    pub blocked: Duration,
}

impl BlockingRecord {
    /// The record's JSON fields (the hang/panic JSONL shape).
    pub fn to_fields(&self) -> serde_json::Map<String, serde_json::Value> {
        let location =
            format!("{}:{}:{}", self.location.file(), self.location.line(), self.location.column());
        let blocked_ms = u64::try_from(self.blocked.as_millis()).unwrap_or(u64::MAX);
        let mut fields = serde_json::Map::new();
        fields.insert("kind".into(), "blocking".into());
        fields.insert("op".into(), self.op.into());
        fields.insert("blocking_type".into(), self.blocking_type.as_str().into());
        fields.insert("outcome".into(), self.outcome.as_str().into());
        fields.insert("location".into(), location.into());
        fields.insert("thread".into(), self.thread.clone().into());
        fields.insert("blocked_ms".into(), blocked_ms.into());
        fields
    }
}

/// Process-wide totals since start.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub allowed: u64,
    pub compensated: u64,
    pub stalled: u64,
    pub unknown: u64,
    /// Total time current_thread runtimes stalled in wrapped calls.
    pub stalled_nanos: u64,
    /// Stalled sites past the dedupe table's capacity: counted, not recorded.
    pub sites_dropped: u64,
}

struct Counters {
    allowed: AtomicU64,
    compensated: AtomicU64,
    stalled: AtomicU64,
    unknown: AtomicU64,
    stalled_nanos: AtomicU64,
    sites_dropped: AtomicU64,
}

// Process-wide, as Chrome's thread restrictions are: a wrapper is called from
// arbitrarily deep code that has no handle to pass a monitor through.
static COUNTERS: Counters = Counters {
    allowed: AtomicU64::new(0),
    compensated: AtomicU64::new(0),
    stalled: AtomicU64::new(0),
    unknown: AtomicU64::new(0),
    stalled_nanos: AtomicU64::new(0),
    sites_dropped: AtomicU64::new(0),
};

/// The totals so far.
pub fn counts() -> Counts {
    Counts {
        allowed: COUNTERS.allowed.load(Ordering::Relaxed),
        compensated: COUNTERS.compensated.load(Ordering::Relaxed),
        stalled: COUNTERS.stalled.load(Ordering::Relaxed),
        unknown: COUNTERS.unknown.load(Ordering::Relaxed),
        stalled_nanos: COUNTERS.stalled_nanos.load(Ordering::Relaxed),
        sites_dropped: COUNTERS.sites_dropped.load(Ordering::Relaxed),
    }
}

thread_local! {
    static KIND: Cell<ThreadKind> = const { Cell::new(ThreadKind::Unknown) };
}

/// The current thread's kind.
pub fn current_thread_kind() -> ThreadKind {
    KIND.with(Cell::get)
}

/// Mark the current thread for the rest of its life. For thread start hooks
/// of threads the caller owns (a runtime's workers); scoped marks use
/// [`ThreadKindScope`].
pub fn mark_thread(kind: ThreadKind) {
    KIND.with(|cell| cell.set(kind));
}

/// Sets the current thread's kind until dropped, then restores the previous
/// one. Chrome's `ScopedAllowBlocking` is `ThreadKindScope::enter(MayBlock)`.
#[must_use = "the kind reverts when the scope is dropped"]
pub struct ThreadKindScope {
    previous: ThreadKind,
    // Restores a thread-local: must drop on the thread that made it.
    _not_send: PhantomData<*const ()>,
}

impl ThreadKindScope {
    pub fn enter(kind: ThreadKind) -> Self {
        let previous = KIND.with(|cell| cell.replace(kind));
        Self { previous, _not_send: PhantomData }
    }
}

impl Drop for ThreadKindScope {
    fn drop(&mut self) {
        KIND.with(|cell| cell.set(self.previous));
    }
}

/// `tokio::task::spawn_blocking` whose closure may block.
#[track_caller]
pub fn spawn_blocking<F, R>(f: F) -> tokio::task::JoinHandle<R>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    tokio::task::spawn_blocking(move || {
        let _may_block = ThreadKindScope::enter(ThreadKind::MayBlock);
        f()
    })
}

/// Chrome's `ScopedBlockingCall`: run `f`, which blocks, on the current
/// thread under the policy in the crate docs. `op` names the call in
/// records.
#[track_caller]
pub fn scoped_blocking_call<R>(
    op: &'static str,
    blocking_type: BlockingType,
    f: impl FnOnce() -> R,
) -> R {
    match current_thread_kind() {
        ThreadKind::MayBlock => {
            COUNTERS.allowed.fetch_add(1, Ordering::Relaxed);
            f()
        }
        ThreadKind::Unknown => {
            COUNTERS.unknown.fetch_add(1, Ordering::Relaxed);
            f()
        }
        ThreadKind::NoBlock if on_multi_thread_runtime() => {
            COUNTERS.compensated.fetch_add(1, Ordering::Relaxed);
            #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
            let started = Instant::now();
            let value = tokio::task::block_in_place(|| {
                // The worker's queue moved to another thread; nested wrapper
                // calls in `f` block only this one.
                let _may_block = ThreadKindScope::enter(ThreadKind::MayBlock);
                f()
            });
            // The poll watch does not count this time as the poll's.
            #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
            poll_watch::note_compensated(started.elapsed());
            value
        }
        ThreadKind::NoBlock => stalled_call(op, blocking_type, Location::caller(), f),
    }
}

fn on_multi_thread_runtime() -> bool {
    tokio::runtime::Handle::try_current()
        .is_ok_and(|handle| handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread)
}

#[track_caller]
fn stalled_call<R>(
    op: &'static str,
    blocking_type: BlockingType,
    location: &'static Location<'static>,
    f: impl FnOnce() -> R,
) -> R {
    COUNTERS.stalled.fetch_add(1, Ordering::Relaxed);
    if strict() {
        // crash-allow: only with CMUX_BLOCKING_STRICT=1 (the lab) or in this crate's tests; shipped builds count and record
        panic!(
            "cmux-blocking: {op} on a thread that must not block (current_thread runtime) at {location}; \
             move it into cmux_blocking::spawn_blocking or use the tokio equivalent"
        );
    }
    let started = Instant::now();
    let value = f();
    let blocked = started.elapsed();
    COUNTERS
        .stalled_nanos
        .fetch_add(u64::try_from(blocked.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
    match sites::first_at(location) {
        sites::Seen::First => {
            if cfg!(debug_assertions) {
                eprintln!(
                    "cmux-blocking: {op} stalled a current_thread runtime for {blocked:?} at {location} (logged once per site)"
                );
            }
            sink::emit(&BlockingRecord {
                op,
                blocking_type,
                outcome: Outcome::Stalled,
                location,
                thread: std::thread::current().name().map(str::to_owned),
                blocked,
            });
        }
        sites::Seen::Before => {}
        sites::Seen::TableFull => {
            COUNTERS.sites_dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
    value
}

/// `CMUX_BLOCKING_STRICT=1` turns a stall into a panic (the lab).
fn strict_from_env_value(value: Option<&std::ffi::OsStr>) -> bool {
    value.is_some_and(|value| value == "1")
}

#[cfg(not(test))]
fn strict() -> bool {
    static STRICT: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *STRICT
        .get_or_init(|| strict_from_env_value(std::env::var_os("CMUX_BLOCKING_STRICT").as_deref()))
}

/// This crate's own tests are strict unless a test opts out on its thread.
#[cfg(test)]
fn strict() -> bool {
    tests::STRICT_OVERRIDE.with(Cell::get).unwrap_or(true)
}
