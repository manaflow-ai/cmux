//! Release trace ring v1 for cmux's Rust processes. The format, the write and decode protocols and
//! the sizes by role are specified in plans/cmux-next/trace.md, "Release trace ring v1" (task 002);
//! the Swift ring (task 003) and the C writer (task 094) write the same bytes, and the golden file
//! they share pins them (`tests/ring.rs`).
//!
//! Every process writes 32-byte records on one clock ([`clock`]) into per-thread chunks of its
//! active ring. A thread owns one chunk at a time and publishes each record with a seqlock; a
//! chunk still owned by another thread is skipped, never shared. The ring overwrites its oldest
//! chunks, so the black box always holds the latest records, and it lives in a reserved
//! `MAP_SHARED` file, so a crash leaves it on disk. This is Chrome's `TraceLog` over Perfetto's
//! shared memory buffer (`base/trace_event/trace_log.h`, `src/tracing/core/shared_memory_abi.h`),
//! cut to what a black box needs.
//!
//! - [`init_blackbox`]: the first call in `main`. The heap ring is active at once; a one-shot
//!   thread (`cmux-trace-open`) maps the file, copies the heap ring into it and swaps. No writer
//!   thread exists, ever.
//! - [`start_recording`] / [`stop`]: the recording ring for `cmux trace`. Its file is mapped once
//!   and never unmapped or cleared; each start moves its cursor a lap past the last recording.
//! - [`write`](fn@write): off, one relaxed load and a branch; on, no lock, allocation or system call.
//! - The trace macros ([`trace_scope!`], [`trace_instant!`], [`trace_async_begin!`] /
//!   [`trace_async_end!`], [`trace_flow_out!`] / [`trace_flow_in!`], [`trace_counter!`]): Chrome's
//!   `TRACE_EVENT*` over [`write`](fn@write), one `static` [`TraceSite`] per call site, names from the shared
//!   catalog ([`names::CATALOG`]); [`scope_stack`] is the calling thread's open scopes.
//!
//! - [`crash_keys`]: the process's crash-key page, a 4 KiB file beside the black box that the
//!   same open thread makes (task 098).
//! - [`export`](fn@export): decoded rings and Chromium's JSON trace to one native Perfetto
//!   protobuf trace (task 022), for `cmux trace record`.
//! - [`metrics`]: field histograms in a crash-safe `metrics-<role>-<pid>.bin` with the app's
//!   CmuxNextMetrics layout (task 131).
//!
//! std and libc only: the holder links it.

pub mod cleanup;
pub mod clock;
mod control;
mod copy;
pub mod crash_keys;
mod decode;
mod export;
mod folder;
mod identity;
mod json;
mod layout;
mod macros;
mod map;
pub mod metrics;
pub mod names;
mod proto;
mod ring;
mod terminal;
mod tracer;

use std::cell::RefCell;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};

pub use control::{ControlOp, apply as apply_control};
pub use decode::{DecodeError, Decoded, DecodedRecord, Header, NameEntry, ThreadEntry, decode};
pub use export::{
    ChromiumInput, ExportError, ExportInput, ExportStats, Machine, RemoteMachine, RingInput, export,
};
pub use folder::{process_dir, process_dir_with};
pub use identity::{ProcessIdentity, ThreadIdentity, build_uuid, build_version};
pub use json::JsonError;
pub use layout::{
    CHUNK_BYTES, CatalogName, FLAG_ESTIMATE, FLAG_ID, HEADER_BYTES, NAME_TEXT_BYTES, NameKind,
    PAGE_BYTES, Phase, RECORDS_PER_CHUNK, RingKind, RingLayout, RingSizes, THREAD_NONE,
};
#[doc(hidden)]
pub use macros::categories as __categories;
pub use macros::{
    SCOPE_SLOTS, SCOPE_STACK_DEPTH, ScopeGuard, ScopeStack, TraceArg, TraceSite, scope_stack,
};
pub use map::{Reserve, reserve_blocks};
pub use ring::Record;
pub use terminal::terminal_hash;
use tracer::RingId;
pub use tracer::{InternedName, StartClocks, Tracer, TracerConfig, Writer};

/// Which process wrote a ring (header `role`, u16 at 20).
#[repr(u16)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    App = 1,
    Daemon = 2,
    Holder = 3,
    TerminalHost = 4,
    Acpmux = 5,
    ChromiumHost = 6,
    Cli = 7,
    /// acpmux's `__agent-host`: one harness per process.
    AgentHost = 8,
    /// `cmux-app-host`: one sandboxed QuickJS VM per app.
    AppHost = 9,
    /// `cmux-browser-host serve`: the agent browser runtime.
    BrowserHost = 10,
}

impl Role {
    pub fn from_raw(raw: u16) -> Option<Role> {
        Some(match raw {
            1 => Role::App,
            2 => Role::Daemon,
            3 => Role::Holder,
            4 => Role::TerminalHost,
            5 => Role::Acpmux,
            6 => Role::ChromiumHost,
            7 => Role::Cli,
            8 => Role::AgentHost,
            9 => Role::AppHost,
            10 => Role::BrowserHost,
            _ => return None,
        })
    }

    /// The file-name stem of this role's rings.
    pub fn as_str(self) -> &'static str {
        match self {
            Role::App => "app",
            Role::Daemon => "daemon",
            Role::Holder => "holder",
            Role::TerminalHost => "terminal-host",
            Role::Acpmux => "acpmux",
            Role::ChromiumHost => "chromium-host",
            Role::Cli => "cli",
            Role::AgentHost => "agent-host",
            Role::AppHost => "app-host",
            Role::BrowserHost => "browser-host",
        }
    }

    /// (name capacity, thread capacity, black-box chunks, recording chunks) from "Sizes by role".
    /// The CLI has no row there; it takes the holder's (a short-lived process with few threads).
    fn size_row(self) -> (u32, u32, u32, u32) {
        match self {
            Role::App | Role::Daemon => (4096, 2048, 512, 32768),
            Role::ChromiumHost => (4096, 2048, 512, 8192),
            Role::Holder | Role::Acpmux | Role::Cli | Role::AgentHost | Role::BrowserHost => {
                (2048, 512, 256, 8192)
            }
            Role::TerminalHost | Role::AppHost => (1024, 256, 64, 512),
        }
    }

    pub fn blackbox_sizes(self) -> RingSizes {
        let (name_capacity, thread_capacity, chunk_count, _) = self.size_row();
        RingSizes { name_capacity, thread_capacity, chunk_count }
    }

    pub fn recording_sizes(self) -> RingSizes {
        let (name_capacity, thread_capacity, _, chunk_count) = self.size_row();
        RingSizes { name_capacity, thread_capacity, chunk_count }
    }
}

/// Trace categories: one bit each in the process's category set ([`enabled`]). The bits are the
/// table in plans/cmux-next/trace.md ("Release trace ring: category bits"), shared with Swift's
/// `SignpostCategory.traceBit` and the C writer; `tests/shared_values.rs` pins every one.
pub mod category {
    pub const ACTION: u64 = 1 << 0;
    pub const KEY: u64 = 1 << 1;
    pub const SWITCH: u64 = 1 << 2;
    pub const CREATE: u64 = 1 << 3;
    pub const CEF: u64 = 1 << 4;
    pub const LAUNCH: u64 = 1 << 5;
    pub const DAEMON: u64 = 1 << 6;
    pub const HANG: u64 = 1 << 7;
    pub const CRASH: u64 = 1 << 8;
    pub const MOTION: u64 = 1 << 9;
    pub const FRAME: u64 = 1 << 10;
    pub const STALL: u64 = 1 << 11;
    pub const TASK: u64 = 1 << 12;
    pub const BURST: u64 = 1 << 13;
    pub const INPUT: u64 = 1 << 14;
    pub const WEBVIEW: u64 = 1 << 15;
    pub const REMOTE: u64 = 1 << 16;
    pub const CONTROL: u64 = 1 << 17;
    pub const GHOSTTY: u64 = 1 << 18;
    pub const RESIZE: u64 = 1 << 19;
    pub const WEBUI: u64 = 1 << 20;
    pub const LOG: u64 = 1 << 21;

    /// What the black box records while no recording runs.
    pub const BLACKBOX: u64 = ACTION | KEY | SWITCH | CREATE | CEF | LAUNCH | DAEMON | HANG | CRASH;
    /// What a recording adds.
    pub const RECORDING: u64 = MOTION
        | FRAME
        | STALL
        | TASK
        | BURST
        | INPUT
        | WEBVIEW
        | REMOTE
        | CONTROL
        | GHOSTTY
        | RESIZE
        | WEBUI
        | LOG;
    pub const ALL: u64 = BLACKBOX | RECORDING;

    /// Each category's name, indexed by its bit: the text before the first dot of its trace names.
    pub use crate::macros::CATEGORY_NAMES as NAMES;
}

/// The black-box ring file of `role` in process `pid`.
pub fn blackbox_file_name(role: Role, pid: u32) -> String {
    format!("{}-{pid}.blackbox.cmxtrace", role.as_str())
}

/// The recording ring file of `role` in process `pid`.
pub fn recording_file_name(role: Role, pid: u32) -> String {
    format!("{}-{pid}.recording.cmxtrace", role.as_str())
}

/// Why a control call did nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TraceError {
    /// [`init_blackbox`] has not run in this process.
    NotInitialized,
    /// A recording runs (or another start or stop is changing state).
    AlreadyRecording,
    /// No recording runs.
    NotRecording,
}

impl std::fmt::Display for TraceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            TraceError::NotInitialized => "tracing is not initialised in this process",
            TraceError::AlreadyRecording => "a trace recording is already running",
            TraceError::NotRecording => "no trace recording is running",
        })
    }
}

impl std::error::Error for TraceError {}

/// What `trace.status` reports for one process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub role: Role,
    pub categories: u64,
    pub recording: bool,
    pub blackbox_path: Option<PathBuf>,
    pub recording_path: Option<PathBuf>,
    /// Bytes of the recording ring (0 before the first start).
    pub recording_bytes: u64,
    pub recording_file_backed: bool,
    /// The active ring's `chunks_overwritten`, `chunks_skipped` and `records_dropped`.
    pub chunks_overwritten: u64,
    pub chunks_skipped: u64,
    pub records_dropped: u64,
    /// The black-box file's `heap_chunks_lost`.
    pub heap_chunks_lost: u64,
    /// Ring files that could not be reserved or mapped (that ring stayed on the heap).
    pub map_failures: u32,
}

/// The process-wide category set: what [`enabled`] reads in one relaxed load.
static CATEGORIES: AtomicU64 = AtomicU64::new(0);
/// The process's tracer: the one process-wide trace state, like Chrome's `TraceLog`
/// (arch-ratchet's reviewed `TraceRuntime` exception). Everything it does is on [`Tracer`].
static PROCESS: OnceLock<Tracer> = OnceLock::new();

/// A thread's writer state, with the TLS destructor of "Register a thread": at exit it completes
/// the thread's chunk and frees its thread entries.
struct ThreadWriter(RefCell<tracer::WriterState>);

impl Drop for ThreadWriter {
    fn drop(&mut self) {
        if let Some(tracer) = PROCESS.get() {
            tracer.exit(self.0.get_mut());
        }
    }
}

thread_local! {
    static WRITER: ThreadWriter =
        const { ThreadWriter(RefCell::new(tracer::WriterState::NEW)) };
}

/// The ring-open thread of [`init_blackbox`].
pub struct BlackboxOpen(Option<std::thread::JoinHandle<io::Result<PathBuf>>>);

impl BlackboxOpen {
    /// Waits for the ring file (tests and tools; a `main` drops this and never waits). The path of
    /// the file, or why the black box stays on the heap.
    pub fn wait(self) -> io::Result<PathBuf> {
        match self.0 {
            Some(handle) => {
                handle.join().unwrap_or_else(|_| Err(io::Error::other("ring-open thread panicked")))
            }
            None => Err(io::Error::other("ring-open thread did not start")),
        }
    }
}

/// Starts this process's black box as `role`, with the shared catalog ([`names::CATALOG`]) in every
/// ring's name table: the heap ring takes records from now on, and the one-shot `cmux-trace-open`
/// thread moves it into `<dir>/<role>-<pid>.blackbox.cmxtrace` and makes the crash-key page
/// ([`crash_keys`]) beside it. Call it first in `main`; it opens
/// no file itself. None when the black box was already started.
pub fn init_blackbox(dir: impl AsRef<Path>, role: Role) -> Option<BlackboxOpen> {
    init_process(TracerConfig::for_process(dir.as_ref(), role))
}

/// [`init_blackbox`] with every other input given. The process's rings name the shared catalog
/// ([`names::CATALOG`]): the trace macros write the ids they resolved from it at compile time.
pub fn init_process(config: TracerConfig) -> Option<BlackboxOpen> {
    let mut fresh = false;
    let tracer = PROCESS.get_or_init(|| {
        fresh = true;
        Tracer::with_mirror(config, names::CATALOG, Some(&CATEGORIES))
    });
    if !fresh {
        return None;
    }
    // supervise-allow: a one-shot ring-file open whose handle is BlackboxOpen; a panic keeps the black box on the heap, and BlackboxOpen::wait reports it.
    let handle = std::thread::Builder::new().name("cmux-trace-open".into()).spawn(|| {
        let ring = tracer.adopt_file();
        let config = tracer.config();
        // A page that cannot be mapped keeps its keys in process memory, as the ring does.
        let _ =
            crash_keys::open_page(&config.dir, config.role, tracer.full_identity(), config.reserve);
        ring
    });
    Some(BlackboxOpen(handle.ok()))
}

/// Whether trace points of `category` record now: one relaxed load and a branch.
#[inline(always)]
pub fn enabled(category: u64) -> bool {
    CATEGORIES.load(Ordering::Relaxed) & category != 0
}

/// Records catalog name `name` with `phase` now, if `category` is on.
#[inline]
pub fn write(category: u64, name: u16, phase: Phase, flags: u8, arg0: u64, arg1: u64) {
    if enabled(category) {
        let record = Record { t_ns: clock::now_ns(), name, phase, flags, arg0, arg1 };
        write_process(record, None, None);
    }
}

/// [`write`](fn@write) with a time the caller measured on the trace clock (an event's own timestamp).
#[inline]
pub fn write_at(
    category: u64,
    t_ns: u64,
    name: u16,
    phase: Phase,
    flags: u8,
    arg0: u64,
    arg1: u64,
) {
    if enabled(category) {
        write_process(Record { t_ns, name, phase, flags, arg0, arg1 }, None, None);
    }
}

/// [`write`](fn@write) under a name interned at run time (one id per ring, interned at its first record
/// there).
#[inline]
pub fn write_interned(
    category: u64,
    name: &'static InternedName,
    phase: Phase,
    flags: u8,
    arg0: u64,
    arg1: u64,
) {
    if enabled(category) {
        let record = Record { t_ns: clock::now_ns(), name: 0, phase, flags, arg0, arg1 };
        write_process(record, Some(name), None);
    }
}

/// Writes `record` as this thread into the process's active ring ([`Tracer::write`]): with
/// `only_in`, only while that ring is active. The ring it went into, if it was written.
#[inline(never)]
pub(crate) fn write_process(
    record: Record,
    interned: Option<&InternedName>,
    only_in: Option<RingId>,
) -> Option<RingId> {
    let tracer = PROCESS.get()?;
    WRITER
        .try_with(|writer| {
            let mut state = writer.0.try_borrow_mut().ok()?;
            tracer.write(&mut state, record, interned, only_in)
        })
        .ok()
        .flatten()
}

/// `trace.start` in this process ([`Tracer::start_recording`]).
pub fn start_recording(categories: u64) -> Result<Status, TraceError> {
    PROCESS.get().ok_or(TraceError::NotInitialized)?.start_recording(categories)
}

/// Maps this process's recording ring ahead of its first `trace.start`
/// ([`Tracer::prepare_recording`]): the ring's bytes. Blocking: call it off the main thread.
pub fn prepare_recording() -> Result<u64, TraceError> {
    Ok(PROCESS.get().ok_or(TraceError::NotInitialized)?.prepare_recording())
}

/// `trace.stop` in this process ([`Tracer::stop`]).
pub fn stop() -> Result<Status, TraceError> {
    PROCESS.get().ok_or(TraceError::NotInitialized)?.stop()
}

/// Whether a recording runs in this process now ([`Tracer::recording`]): two loads, no
/// allocation. False before [`init_blackbox`].
#[inline]
pub fn recording() -> bool {
    PROCESS.get().is_some_and(Tracer::recording)
}

/// This process's trace state; None before [`init_blackbox`].
pub fn status() -> Option<Status> {
    PROCESS.get().map(Tracer::status)
}

/// The role this process traces as; None before [`init_blackbox`]. The panic lines name it.
pub fn process_role() -> Option<Role> {
    PROCESS.get().map(|tracer| tracer.config().role)
}

/// How long ago [`init_blackbox`] ran (the first call in `main`), on the trace clock; None before
/// it. The panic lines carry it as their uptime, as Chrome's crash reports carry `ptime` from the
/// time the crash reporter started (`components/crash/core/app/breakpad_linux.cc`,
/// `g_process_start_time`). No allocation or lock: a panic hook calls it.
pub fn process_uptime_ns() -> Option<u64> {
    PROCESS.get().map(Tracer::uptime_ns)
}

/// A consistent copy of the active ring: the crash and hang reports read the black-box tail from
/// it. None before [`init_blackbox`].
pub fn snapshot_active() -> Option<Vec<u8>> {
    PROCESS.get().map(Tracer::snapshot_active)
}
