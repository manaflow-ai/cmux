//! Blocking calls on tokio threads: the tokio layer of Chrome's
//! `ScopedBlockingCall` for the cmux daemons.
//!
//! Policy is `cmux_threads::blocking`, the one ThreadRestrictions for the
//! daemon (`base/threading/thread_restrictions.h`): which threads disallow
//! blocking, the `AllowReason` friend list, and the site table that
//! `server.blocking` reports. Every wrapper here checks that policy at its
//! caller's `#[track_caller]` location first, so a request thread that called
//! `cmux_threads::disallow_blocking()` reports a `cmux_blocking::fs::read`
//! like any other blocking call.
//!
//! This crate adds only what is tokio's, from what the thread is doing:
//! - On a thread of a [`runtime::multi_thread`] runtime the call runs inside
//!   `tokio::task::block_in_place`, which hands the worker's queue to another
//!   thread for the length of the call (Chrome's compensation in
//!   `base/task/thread_pool/thread_group.cc`). This happens whatever the
//!   policy says: an allowance never stalls a worker.
//! - On the thread inside [`runtime::block_on`] (either flavor) no thread can
//!   take over: every task of a current_thread runtime, and the block_on
//!   future of a multi_thread one, makes no progress. [`runtime::block_on`]
//!   disallows blocking for the call (`ScopedDisallowBlocking`), so the stall
//!   is a policy violation. In a Debug build the `cmux_threads` check panics
//!   there first, unless `CMUX_DAEMON_BLOCKING=record`. Otherwise (Release,
//!   or record mode) it is counted, the first at each site is written to the
//!   installed [`RecordSink`] and logged once in debug builds, and it panics
//!   only in this crate's own tests or with `CMUX_BLOCKING_STRICT=1` (the
//!   lab). `block_in_place` is never called there: tokio panics on it
//!   inside a `LocalSet` and does nothing useful outside one.
//! - In [`spawn_blocking`] work the call may block and is counted as allowed.
//! - Anywhere else (plain tokio runtimes, `#[tokio::test]`, std threads) the
//!   call is counted as unknown and runs as is. A plain runtime cannot be
//!   compensated safely: its workers cannot be told from a `block_on` driver
//!   running a `LocalSet`, where `block_in_place` panics.

#![forbid(unsafe_code)]

// The wrapper modules are the only callers of the blocking std calls the lab's
// disallowed-methods list (cmux-tui/lab/clippy/clippy.toml) names.
#[allow(
    clippy::disallowed_methods,
    reason = "the wrapper that cmux-tui/lab/clippy/clippy.toml names for this std call"
)]
pub mod fs;
#[cfg(all(tokio_unstable, feature = "cmux-stability"))]
pub mod poll_watch;
#[allow(
    clippy::disallowed_methods,
    reason = "the wrapper that cmux-tui/lab/clippy/clippy.toml names for this std call"
)]
pub mod process;
pub mod runtime;
mod sink;
#[allow(
    clippy::disallowed_methods,
    reason = "the wrapper that cmux-tui/lab/clippy/clippy.toml names for this std call"
)]
pub mod sync;
#[allow(
    clippy::disallowed_methods,
    reason = "the wrapper that cmux-tui/lab/clippy/clippy.toml names for this std call"
)]
pub mod thread;

#[cfg(test)]
mod tests;

pub use cmux_threads::blocking::BlockingKind;
pub use sink::{JsonlSink, RecordSink, SinkAlreadyInstalled, install_sink};

use std::cell::Cell;
use std::marker::PhantomData;
use std::panic::Location;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_threads::blocking::{BlockingCheck, assert_blocking_allowed_at};

/// Chrome's `base::BlockingType`: how likely the call is to wait.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockingType {
    /// May return at once (a file read that hits the page cache).
    MayBlock,
    /// Waits by design (sleep, channel receive, child process).
    WillBlock,
}

impl BlockingType {
    /// File-system calls may hit a cache; every other kind waits by design.
    pub const fn of(kind: BlockingKind) -> Self {
        match kind {
            BlockingKind::Fs => Self::MayBlock,
            _ => Self::WillBlock,
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::MayBlock => "may_block",
            Self::WillBlock => "will_block",
        }
    }
}

/// One stall of a runtime's driving thread, the first violation at its site
/// in this process.
#[derive(Clone, Debug)]
pub struct BlockingRecord {
    /// The wrapper that blocked, for example `fs::read`.
    pub op: &'static str,
    pub kind: BlockingKind,
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
        fields.insert("blocking_kind".into(), self.kind.as_str().into());
        fields.insert("blocking_type".into(), BlockingType::of(self.kind).as_str().into());
        fields.insert("outcome".into(), "stalled".into());
        fields.insert("location".into(), location.into());
        fields.insert("thread".into(), self.thread.clone().into());
        fields.insert("blocked_ms".into(), blocked_ms.into());
        fields
    }
}

/// Process-wide totals since start.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    /// In [`spawn_blocking`] work, or allowed on a driving thread by a
    /// `cmux_threads` allowance.
    pub allowed: u64,
    /// On a worker of a [`runtime::multi_thread`] runtime: ran in
    /// `block_in_place`.
    pub compensated: u64,
    /// On a [`runtime::multi_thread`] thread not seen working as a scheduler
    /// worker since its last compensated call: a raw
    /// `tokio::task::spawn_blocking` closure (where `block_in_place` does
    /// nothing) or a worker that has not parked since it took a core. Ran in
    /// `block_in_place` too.
    pub unconfirmed: u64,
    /// On the thread inside [`runtime::block_on`]: the runtime stalled.
    pub stalled: u64,
    /// Anywhere else; ran as is.
    pub unknown: u64,
    /// Total time runtimes stalled in wrapped calls.
    pub stalled_nanos: u64,
}

struct Counters {
    allowed: AtomicU64,
    compensated: AtomicU64,
    unconfirmed: AtomicU64,
    stalled: AtomicU64,
    unknown: AtomicU64,
    stalled_nanos: AtomicU64,
}

// Process-wide, as Chrome's thread restrictions are: a wrapper is called from
// arbitrarily deep code that has no handle to pass a monitor through.
static COUNTERS: Counters = Counters {
    allowed: AtomicU64::new(0),
    compensated: AtomicU64::new(0),
    unconfirmed: AtomicU64::new(0),
    stalled: AtomicU64::new(0),
    unknown: AtomicU64::new(0),
    stalled_nanos: AtomicU64::new(0),
};

/// The totals so far.
pub fn counts() -> Counts {
    Counts {
        allowed: COUNTERS.allowed.load(Ordering::Relaxed),
        compensated: COUNTERS.compensated.load(Ordering::Relaxed),
        unconfirmed: COUNTERS.unconfirmed.load(Ordering::Relaxed),
        stalled: COUNTERS.stalled.load(Ordering::Relaxed),
        unknown: COUNTERS.unknown.load(Ordering::Relaxed),
        stalled_nanos: COUNTERS.stalled_nanos.load(Ordering::Relaxed),
    }
}

/// What the current thread is doing for tokio. Set only by this crate:
/// runtime hooks, [`runtime::block_on`], [`spawn_blocking`] and compensated
/// calls. It is not a permission; `cmux_threads` owns those.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Role {
    /// Not a thread this crate set up.
    Unknown,
    /// A thread of a [`runtime::multi_thread`] runtime (tokio starts workers
    /// and blocking-pool threads alike through its pool), not seen working as
    /// a scheduler worker since its last compensated call.
    RuntimeThread,
    /// A scheduler worker of a [`runtime::multi_thread`] runtime: it unparked
    /// as one and has made no compensated call since.
    Worker,
    /// The thread inside [`runtime::block_on`].
    Driver,
    /// Work that may block: a [`spawn_blocking`] closure, or the body of a
    /// compensated call.
    MayBlock,
}

thread_local! {
    static ROLE: Cell<Role> = const { Cell::new(Role::Unknown) };
}

pub(crate) fn current_role() -> Role {
    ROLE.with(Cell::get)
}

pub(crate) fn set_role(role: Role) {
    ROLE.with(|cell| cell.set(role));
}

/// Sets the current thread's role until dropped, then sets `after`.
struct RoleScope {
    after: Role,
    // Restores a thread-local: must drop on the thread that made it.
    _not_send: PhantomData<*const ()>,
}

impl RoleScope {
    /// `role` until dropped, then the role before it.
    fn enter(role: Role) -> Self {
        let after = ROLE.with(|cell| cell.replace(role));
        Self { after, _not_send: PhantomData }
    }

    /// `role` until dropped, then `after`.
    fn enter_then(role: Role, after: Role) -> Self {
        set_role(role);
        Self { after, _not_send: PhantomData }
    }
}

impl Drop for RoleScope {
    fn drop(&mut self) {
        set_role(self.after);
    }
}

/// `tokio::task::spawn_blocking` whose closure may block. Chrome's
/// `MayBlock()` trait on a ThreadPool task.
#[track_caller]
pub fn spawn_blocking<F, R>(f: F) -> tokio::task::JoinHandle<R>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    tokio::task::spawn_blocking(move || {
        let _may_block = RoleScope::enter(Role::MayBlock);
        f()
    })
}

/// How [`scoped_blocking_call`] runs one call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    Allowed,
    Compensated,
    Unconfirmed,
    Stalled { first_at_site: bool },
    Unknown,
}

/// The route for a call on a thread in `role`, whose current tokio runtime is
/// multi_thread or not, after the policy check said `check`.
pub(crate) fn route(role: Role, on_multi_thread: bool, check: BlockingCheck) -> Route {
    match (role, check) {
        (Role::Worker, _) if on_multi_thread => Route::Compensated,
        (Role::RuntimeThread, _) if on_multi_thread => Route::Unconfirmed,
        (Role::Driver, BlockingCheck::Violation { first_at_site }) => {
            Route::Stalled { first_at_site }
        }
        (Role::Driver, BlockingCheck::Allowed) | (Role::MayBlock, _) => Route::Allowed,
        (Role::Worker | Role::RuntimeThread | Role::Unknown, _) => Route::Unknown,
    }
}

/// Chrome's `ScopedBlockingCall`: check the `cmux_threads` policy for `kind`
/// at the caller, then run `f`, which blocks, as the crate docs say. `op`
/// names the call in records.
#[track_caller]
pub fn scoped_blocking_call<R>(op: &'static str, kind: BlockingKind, f: impl FnOnce() -> R) -> R {
    let location = Location::caller();
    let check = assert_blocking_allowed_at(kind, location);
    match route(current_role(), on_multi_thread_runtime(), check) {
        Route::Compensated => {
            COUNTERS.compensated.fetch_add(1, Ordering::Relaxed);
            compensated(f)
        }
        Route::Unconfirmed => {
            COUNTERS.unconfirmed.fetch_add(1, Ordering::Relaxed);
            compensated(f)
        }
        Route::Stalled { first_at_site } => stalled_call(op, kind, location, first_at_site, f),
        Route::Allowed => {
            COUNTERS.allowed.fetch_add(1, Ordering::Relaxed);
            f()
        }
        Route::Unknown => {
            COUNTERS.unknown.fetch_add(1, Ordering::Relaxed);
            f()
        }
    }
}

fn compensated<R>(f: impl FnOnce() -> R) -> R {
    // Nested wrappers in `f` block only this thread. Afterwards the worker's
    // core may be on another thread, so this one is a worker again only once
    // it unparks as one.
    let _may_block = RoleScope::enter_then(Role::MayBlock, Role::RuntimeThread);
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    let started = Instant::now();
    let value = tokio::task::block_in_place(f);
    // The poll watch does not count this time as the poll's.
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    poll_watch::note_compensated(started.elapsed());
    value
}

fn on_multi_thread_runtime() -> bool {
    tokio::runtime::Handle::try_current()
        .is_ok_and(|handle| handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread)
}

fn stalled_call<R>(
    op: &'static str,
    kind: BlockingKind,
    location: &'static Location<'static>,
    first_at_site: bool,
    f: impl FnOnce() -> R,
) -> R {
    COUNTERS.stalled.fetch_add(1, Ordering::Relaxed);
    if strict() {
        // crash-allow: only with CMUX_BLOCKING_STRICT=1 (the lab) or in this crate's tests; shipped builds count and record
        panic!(
            "cmux-blocking: {op} on a thread that drives a tokio runtime at {location}; \
             move it into cmux_blocking::spawn_blocking or use the tokio equivalent"
        );
    }
    let started = Instant::now();
    let value = f();
    let blocked = started.elapsed();
    COUNTERS
        .stalled_nanos
        .fetch_add(u64::try_from(blocked.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
    if first_at_site {
        if cfg!(debug_assertions) {
            eprintln!(
                "cmux-blocking: {op} stalled a tokio runtime for {blocked:?} at {location} (logged once per site)"
            );
        }
        sink::emit(&BlockingRecord {
            op,
            kind,
            location,
            thread: std::thread::current().name().map(str::to_owned),
            blocked,
        });
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
