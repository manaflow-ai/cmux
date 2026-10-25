//! Release trace ring v1 for cmux's Rust processes (plans/cmux-next/chrome-parity/p09-observability.md,
//! section 3A; the format section of plans/cmux-next/trace.md).
//!
//! Every process writes 32-byte records on one clock ([`clock`]) into a ring of per-thread chunks:
//! a thread claims a 1 KiB chunk with one `fetch_add`, then publishes each record with a seqlock.
//! The ring overwrites its oldest chunk when it wraps, so it is a black box that always holds the
//! latest records, and it lives in a `MAP_SHARED` file, so a crash leaves it on disk. This is
//! Chrome's `TraceLog` over Perfetto's shared memory buffer (`base/trace_event/trace_log.h`,
//! `perfetto/src/tracing/core/shared_memory_abi.h`), cut to what a black box needs.
//!
//! - [`init_blackbox`]: the first call in `main`. The ring starts on the heap at once; a one-shot
//!   thread (`cmux-trace-open`) creates the file, maps it and moves the ring into it. No writer
//!   thread exists, ever.
//! - [`start_recording`] / [`stop`]: a bigger ring for `cmux trace`. Its file is mapped once and
//!   never unmapped; a later start empties and reuses it. Stop clears the recording categories and
//!   moves writes back to the black box.
//! - [`write`]: off, one relaxed load and a branch; on, no lock, allocation or system call.
//!
//! # Ring v1 bytes (little-endian; Swift task 003 and C task 094 write the same)
//!
//! Header, 256 bytes:
//!
//! | Offset | Type | Field |
//! | --- | --- | --- |
//! | 0 | [u8; 8] | magic `CMXTRACE` |
//! | 8 | u32 | version (1) |
//! | 12 | u32 | header bytes (256) |
//! | 16 | u32 | pid |
//! | 20 | u8 | role ([`Role`]) |
//! | 21 | u8 | clock domain ([`clock::ClockDomain`]) |
//! | 22 | u16 | reserved (0) |
//! | 24 | u64 | start ns (process start; for a recording, its start) |
//! | 32 | [u8; 16] | boot session (`kern.bootsessionuuid`, Linux boot_id) |
//! | 48 | [u8; 16] | build id |
//! | 64 | u32 | chunk offset (a multiple of 1024) |
//! | 68 | u32 | chunk count |
//! | 72 | u32 | chunk bytes (1024) |
//! | 76 | u32 | record bytes (32) |
//! | 80 | u32 | thread table offset |
//! | 84 | u32 | thread table capacity (entries) |
//! | 88 | u32 | thread entry bytes (64) |
//! | 92 | u32 | name table offset |
//! | 96 | u32 | name table bytes |
//! | 100 | u32 | reserved (0) |
//! | 104 | u64 | chunks overwritten |
//! | 112 | u32 | threads the table had no room for |
//! | 116 | u32 | names the table had no room for |
//! | 120 | 136 bytes | reserved (0) |
//!
//! Thread entry, 64 bytes: state u32 at 0 (1 once published, stored last), generation u32 at 4
//! (the thread's process-wide serial from 1), tid u64 at 8, QoS u32 at 16 (macOS `qos_class_t`),
//! name length u32 at 20, name bytes at 24 (40 bytes, zero-padded).
//!
//! Name table: entries packed from its start, each a u32 (`len | id << 16`, stored last; id 0xFFFF
//! while the bytes are written; 0 ends the table) and then the name's bytes padded to 4.
//!
//! Chunk, 1024 bytes: slot 0 is the chunk header (thread index u32 at 0, `u32::MAX` when the table
//! was full; thread generation u32 at 4, 0 for a chunk never claimed; lap u64 at 8, `u64::MAX`
//! while a claimer rewrites the header; published count u32 at 16; 12 reserved bytes), slots 1-31
//! are records. A claim takes position `p` from the cursor: chunk `p % count`, lap `p / count`.
//!
//! Record, 32 bytes: t_ns u64 at 0, seq u32 at 8 (`2*lap+1` while written, `2*lap+2` once
//! published, as u32 wrapping), name u16 at 12, phase u8 at 14 ([`Phase`]), flags u8 at 15
//! ([`FLAG_ASYNC_ID`], [`FLAG_ESTIMATED`]), arg0 u64 at 16, arg1 u64 at 24. A decoder keeps a
//! record only when its seq is the published seq of its chunk header's lap.
//!
//! std and libc only: the holder links it.

pub mod clock;
mod map;
pub mod ring;

use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicPtr, AtomicU8, AtomicU32, AtomicU64, Ordering};

pub use ring::{
    DecodeError, Decoded, DecodedRecord, FLAG_ASYNC_ID, FLAG_ESTIMATED, Header, Phase, Record,
    Ring, RingConfig, RingLayout, ThreadEntry, ThreadInfo, Writer, WriterState, decode,
};

/// Which process wrote a ring (header byte 20).
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Unknown = 0,
    App = 1,
    Daemon = 2,
    Holder = 3,
    TerminalHost = 4,
    Acpmux = 5,
    AgentHost = 6,
    AppHost = 7,
    BrowserHost = 8,
    ChromiumHost = 9,
    Cli = 10,
}

impl Role {
    /// The file-name stem of this role's rings.
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Unknown => "unknown",
            Role::App => "app",
            Role::Daemon => "daemon",
            Role::Holder => "holder",
            Role::TerminalHost => "terminal-host",
            Role::Acpmux => "acpmux",
            Role::AgentHost => "agent-host",
            Role::AppHost => "app-host",
            Role::BrowserHost => "browser-host",
            Role::ChromiumHost => "chromium-host",
            Role::Cli => "cli",
        }
    }

    /// Black-box records for this role (section 3A, "Sizes by role").
    pub fn blackbox_records(self) -> usize {
        match self {
            Role::TerminalHost => 512,
            _ => 4096,
        }
    }

    /// The largest recording for this role; [`start_recording`] caps its request here.
    pub fn recording_records(self) -> usize {
        match self {
            Role::App | Role::Daemon => 1 << 20,
            Role::TerminalHost => 16 << 10,
            _ => 256 << 10,
        }
    }
}

/// Trace categories: one bit each in the process-wide set that [`enabled`] reads.
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

    /// What the black box records while no recording runs.
    pub const BLACKBOX: u64 = ACTION | KEY | SWITCH | CREATE | CEF | LAUNCH | DAEMON | HANG | CRASH;
    /// What a recording adds.
    pub const RECORDING: u64 = MOTION | FRAME | STALL | TASK | BURST | INPUT | WEBVIEW | REMOTE;
    pub const ALL: u64 = BLACKBOX | RECORDING;
}

/// The build id in every ring header: the first 16 bytes of `CMUX_BUILD_ID` at compile time (the
/// release scripts set it), else the crate version.
pub fn build_id() -> [u8; 16] {
    let text = option_env!("CMUX_BUILD_ID").unwrap_or(env!("CARGO_PKG_VERSION"));
    let mut out = [0u8; 16];
    let len = text.len().min(16);
    out[..len].copy_from_slice(&text.as_bytes()[..len]);
    out
}

/// Categories on in this process. 0 until [`init_blackbox`].
static CATEGORIES: AtomicU64 = AtomicU64::new(0);
/// The ring trace points write into: the black box, or the recording while one runs.
static ACTIVE: AtomicPtr<Ring> = AtomicPtr::new(std::ptr::null_mut());
/// The process's rings. The one process-wide trace state, like Chrome's `TraceLog`
/// (arch-ratchet's reviewed `TraceRuntime` exception).
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
/// Process-wide thread serials (a thread's generation), from 1.
static THREAD_SERIAL: AtomicU32 = AtomicU32::new(1);

const IDLE: u8 = 0;
const CHANGING: u8 = 1;
const RECORDING: u8 = 2;

struct Runtime {
    dir: PathBuf,
    role: Role,
    blackbox: Ring,
    blackbox_path: OnceLock<PathBuf>,
    recording: OnceLock<Recording>,
    state: AtomicU8,
    map_failures: AtomicU32,
}

struct Recording {
    ring: Ring,
    path: PathBuf,
}

/// A thread's place in up to two rings (the black box and the recording), keyed by ring address,
/// so moving between them never registers the thread again.
#[derive(Clone, Copy)]
struct WriterSlots([(usize, WriterState); 2]);

thread_local! {
    static WRITER: std::cell::Cell<WriterSlots> =
        const { std::cell::Cell::new(WriterSlots([(0, WriterState::NEW); 2])) };
    /// This thread's serial; 0 until its first write.
    static SERIAL: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

/// The black-box ring file of `role` in process `pid`.
pub fn blackbox_file_name(role: Role, pid: u32) -> String {
    format!("{}-{pid}.blackbox.cmxtrace", role.as_str())
}

/// The recording ring file of `role` in process `pid`.
pub fn recording_file_name(role: Role, pid: u32) -> String {
    format!("{}-{pid}.recording.cmxtrace", role.as_str())
}

/// The ring-open thread of [`init_blackbox`].
pub struct BlackboxOpen(Option<std::thread::JoinHandle<io::Result<PathBuf>>>);

impl BlackboxOpen {
    /// Waits for the ring file (tests and tools; a `main` drops this and never waits). The path of
    /// the file, or why the ring stays on the heap.
    pub fn wait(self) -> io::Result<PathBuf> {
        match self.0 {
            Some(handle) => {
                handle.join().unwrap_or_else(|_| Err(io::Error::other("ring-open thread panicked")))
            }
            None => Err(io::Error::other("ring-open thread did not start")),
        }
    }
}

/// Starts the black box: a heap ring of `records` records that trace points write into from now
/// on, and the one-shot `cmux-trace-open` thread that moves it into `<dir>/<role>-<pid>.blackbox.cmxtrace`.
/// Call it first in `main`; it opens no file itself. None when the black box was already started.
pub fn init_blackbox(dir: impl AsRef<Path>, role: Role, records: usize) -> Option<BlackboxOpen> {
    let dir = dir.as_ref().to_path_buf();
    let mut fresh = false;
    let runtime = RUNTIME.get_or_init(|| {
        fresh = true;
        Runtime {
            dir,
            role,
            blackbox: Ring::new(RingConfig::for_process(role, records)),
            blackbox_path: OnceLock::new(),
            recording: OnceLock::new(),
            state: AtomicU8::new(IDLE),
            map_failures: AtomicU32::new(0),
        }
    });
    if !fresh {
        return None;
    }
    ACTIVE.store(std::ptr::from_ref(&runtime.blackbox).cast_mut(), Ordering::Release);
    CATEGORIES.store(category::BLACKBOX, Ordering::Release);
    let handle = std::thread::Builder::new()
        .name("cmux-trace-open".into())
        .spawn(move || {
            let path = runtime.dir.join(blackbox_file_name(runtime.role, std::process::id()));
            let adopted = std::fs::create_dir_all(&runtime.dir)
                .and_then(|()| runtime.blackbox.adopt_file(&path));
            if let Err(error) = adopted {
                runtime.map_failures.fetch_add(1, Ordering::Relaxed);
                return Err(error);
            }
            let _ = runtime.blackbox_path.set(path.clone());
            Ok(path)
        })
        .ok();
    Some(BlackboxOpen(handle))
}

/// Whether trace points of `category` record now: one relaxed load and a branch.
#[inline(always)]
pub fn enabled(category: u64) -> bool {
    CATEGORIES.load(Ordering::Relaxed) & category != 0
}

/// Records `name` with `phase` now, if `category` is on. No lock, allocation or system call.
#[inline]
pub fn write(category: u64, name: u16, phase: Phase, flags: u8, arg0: u64, arg1: u64) {
    if enabled(category) {
        write_enabled(Record { t_ns: clock::now_ns(), name, phase, flags, arg0, arg1 });
    }
}

/// [`write`] with a time the caller measured on the trace clock (an event's own timestamp).
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
        write_enabled(Record { t_ns, name, phase, flags, arg0, arg1 });
    }
}

#[inline(never)]
fn write_enabled(record: Record) {
    let active = ACTIVE.load(Ordering::Acquire);
    if active.is_null() {
        return;
    }
    // SAFETY: ACTIVE only ever holds a ring inside RUNTIME, which lives for the whole process.
    let ring = unsafe { &*active };
    let _ = WRITER.try_with(|cell| {
        let mut slots = cell.get();
        let key = active as usize;
        let index = match slots.0.iter().position(|(owner, _)| *owner == key) {
            Some(index) => index,
            None => {
                // Take the free slot; there are only two rings, so both are free or one is.
                let index = usize::from(slots.0[0].0 != 0);
                slots.0[index] = (key, WriterState::NEW);
                index
            }
        };
        ring.write(&mut slots.0[index].1, || ThreadInfo::current(thread_serial()), record);
        cell.set(slots);
    });
}

fn thread_serial() -> u32 {
    SERIAL
        .try_with(|cell| {
            if cell.get() == 0 {
                cell.set(THREAD_SERIAL.fetch_add(1, Ordering::Relaxed));
            }
            cell.get()
        })
        .unwrap_or(0)
}

/// Adds name `id` to the header name table of the black box and of the recording (task 010
/// registers each catalog name once). False before [`init_blackbox`] or when a table is full.
pub fn register_name(id: u16, name: &str) -> bool {
    let Some(runtime) = RUNTIME.get() else { return false };
    let mut stored = runtime.blackbox.register_name(id, name);
    if let Some(recording) = runtime.recording.get() {
        stored &= recording.ring.register_name(id, name);
    }
    stored
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

/// What `trace.status` reports for this process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub role: Role,
    pub categories: u64,
    pub recording: bool,
    pub blackbox_path: Option<PathBuf>,
    pub recording_path: Option<PathBuf>,
    /// Records the recording holds (its size this time, capped by the role).
    pub recording_records: usize,
    /// Bytes of the recording file.
    pub recording_bytes: u64,
    pub recording_file_backed: bool,
    /// Chunks the active ring overwrote.
    pub overwrites: u64,
    /// Ring files that could not be mapped (the ring stayed on the heap).
    pub map_failures: u32,
}

/// Starts a recording of up to `records` records (0: the role's size; capped by it) with
/// `categories` on top of the black-box set. The first start creates and maps
/// `<dir>/<role>-<pid>.recording.cmxtrace`, sized for the role; a later start empties the same
/// mapping. Runs on the caller's thread (a control-socket thread, never main): the first start
/// opens a file, every start clears the previous recording's chunks.
pub fn start_recording(records: usize, categories: u64) -> Result<Status, TraceError> {
    let runtime = RUNTIME.get().ok_or(TraceError::NotInitialized)?;
    runtime
        .state
        .compare_exchange(IDLE, CHANGING, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| TraceError::AlreadyRecording)?;
    let recording = runtime.recording.get_or_init(|| {
        let path = runtime.dir.join(recording_file_name(runtime.role, std::process::id()));
        let _ = std::fs::create_dir_all(&runtime.dir);
        let config = RingConfig {
            boot_session: clock::boot_session(),
            ..RingConfig::for_process(runtime.role, runtime.role.recording_records())
        };
        let ring = Ring::new_mapped(config, &path);
        if !ring.is_file_backed() {
            runtime.map_failures.fetch_add(1, Ordering::Relaxed);
        }
        Recording { ring, path }
    });
    let wanted = if records == 0 { runtime.role.recording_records() } else { records };
    recording.ring.reset(wanted);
    ACTIVE.store(std::ptr::from_ref(&recording.ring).cast_mut(), Ordering::Release);
    CATEGORIES.store(category::BLACKBOX | categories, Ordering::Release);
    runtime.state.store(RECORDING, Ordering::Release);
    Ok(status_of(runtime))
}

/// Stops the recording: clears the recording categories and moves writes back to the black box.
/// The recording file keeps what it holds (and stays mapped) until the next start.
pub fn stop() -> Result<Status, TraceError> {
    let runtime = RUNTIME.get().ok_or(TraceError::NotInitialized)?;
    runtime
        .state
        .compare_exchange(RECORDING, CHANGING, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| TraceError::NotRecording)?;
    CATEGORIES.store(category::BLACKBOX, Ordering::Release);
    ACTIVE.store(std::ptr::from_ref(&runtime.blackbox).cast_mut(), Ordering::Release);
    runtime.state.store(IDLE, Ordering::Release);
    Ok(status_of(runtime))
}

/// This process's trace state; None before [`init_blackbox`].
pub fn status() -> Option<Status> {
    RUNTIME.get().map(status_of)
}

fn status_of(runtime: &Runtime) -> Status {
    let recording = runtime.recording.get();
    let active = ACTIVE.load(Ordering::Acquire);
    // SAFETY: ACTIVE holds a ring inside RUNTIME (non-null once RUNTIME exists).
    let overwrites = if active.is_null() { 0 } else { unsafe { &*active }.overwrites() };
    Status {
        role: runtime.role,
        categories: CATEGORIES.load(Ordering::Relaxed),
        recording: runtime.state.load(Ordering::Acquire) == RECORDING,
        blackbox_path: runtime.blackbox_path.get().cloned(),
        recording_path: recording
            .filter(|recording| recording.ring.is_file_backed())
            .map(|r| r.path.clone()),
        recording_records: recording.map_or(0, |recording| recording.ring.capacity()),
        recording_bytes: recording
            .map_or(0, |recording| recording.ring.layout().total_bytes as u64),
        recording_file_backed: recording.is_some_and(|recording| recording.ring.is_file_backed()),
        overwrites,
        map_failures: runtime.map_failures.load(Ordering::Relaxed),
    }
}

/// A consistent copy of the active ring (the black box, or the recording while one runs): the
/// crash and hang reports read the black-box tail from it. None before [`init_blackbox`].
pub fn snapshot_active() -> Option<Vec<u8>> {
    let active = ACTIVE.load(Ordering::Acquire);
    // SAFETY: ACTIVE holds a ring inside RUNTIME, which lives for the whole process.
    (!active.is_null()).then(|| unsafe { &*active }.snapshot())
}
