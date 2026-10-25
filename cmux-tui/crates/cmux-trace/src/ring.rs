//! Ring v1: per-thread chunks of 32-byte seqlock records, overwritten oldest-first.
//!
//! The model is Perfetto's shared memory buffer (`src/tracing/core/shared_memory_abi.h`,
//! `trace_writer_impl.cc`): each thread writes into a chunk it owns, so threads never contend on a
//! record. Unlike Perfetto there is no service that returns chunks: the ring is a black box with no
//! consumer, so a claim just takes the next chunk and overwrites it (a Vyukov queue would wait for
//! a consumer). The byte layout is in the crate doc; Swift (task 003) and C (task 094) write the
//! same bytes, which the golden file in `tests/fixtures` pins.

use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU64, Ordering, fence};

use crate::Role;
use crate::clock::ClockDomain;
use crate::map::{self, HeapBlock};

#[cfg(target_endian = "big")]
compile_error!("ring v1 is little-endian; cmux-trace supports little-endian targets only");

/// `CMXTRACE` read as a little-endian u64.
pub const MAGIC: [u8; 8] = *b"CMXTRACE";
/// The ring format version (header offset 8).
pub const VERSION: u32 = 1;
/// Bytes in the fixed header.
pub const HEADER_BYTES: usize = 256;
/// Bytes in one record.
pub const RECORD_BYTES: usize = 32;
/// Bytes in one chunk: a 32-byte chunk header, then [`RECORDS_PER_CHUNK`] records.
pub const CHUNK_BYTES: usize = 1024;
/// Records in one chunk (slots 1..=31; slot 0 is the chunk header).
pub const RECORDS_PER_CHUNK: usize = CHUNK_BYTES / RECORD_BYTES - 1;
/// Bytes in one thread-table entry.
pub const THREAD_ENTRY_BYTES: usize = 64;
/// The longest thread name an entry keeps.
pub const THREAD_NAME_BYTES: usize = 40;
/// A chunk header's lap while its claimer rewrites it.
const LAP_CLAIMING: u64 = u64::MAX;
/// The thread index of a thread that found the thread table full.
pub const THREAD_UNKNOWN: u32 = u32::MAX;
/// The name id a name-table entry carries until its bytes are written.
const NAME_PENDING: u32 = 0xFFFF;
/// The fewest chunks a ring has.
const MIN_CHUNKS: usize = 4;
/// The most chunks a ring has (1 GiB of records, 32x the largest role's recording).
const MAX_CHUNKS: usize = 1 << 20;

/// Header field offsets (all little-endian; see the crate doc).
mod off {
    pub const MAGIC: usize = 0;
    pub const VERSION: usize = 8;
    pub const HEADER_BYTES: usize = 12;
    pub const PID: usize = 16;
    /// role u8 at 20, clock u8 at 21, reserved u16 at 22: one u32 word.
    pub const ROLE_CLOCK: usize = 20;
    pub const START_NS: usize = 24;
    pub const BOOT_SESSION: usize = 32;
    pub const BUILD_ID: usize = 48;
    pub const CHUNK_OFFSET: usize = 64;
    pub const CHUNK_COUNT: usize = 68;
    pub const CHUNK_BYTES: usize = 72;
    pub const RECORD_BYTES: usize = 76;
    pub const THREAD_OFFSET: usize = 80;
    pub const THREAD_CAPACITY: usize = 84;
    pub const THREAD_ENTRY_BYTES: usize = 88;
    pub const NAME_OFFSET: usize = 92;
    pub const NAME_BYTES: usize = 96;
    pub const OVERWRITES: usize = 104;
    pub const THREAD_OVERFLOW: usize = 112;
    pub const NAME_OVERFLOW: usize = 116;

    // Chunk header.
    pub const CH_THREAD: usize = 0;
    pub const CH_GENERATION: usize = 4;
    pub const CH_LAP: usize = 8;
    pub const CH_PUBLISHED: usize = 16;

    // Record.
    pub const R_T: usize = 0;
    pub const R_SEQ: usize = 8;
    /// name u16 at 12, phase u8 at 14, flags u8 at 15: one u32 word.
    pub const R_META: usize = 12;
    pub const R_ARG0: usize = 16;
    pub const R_ARG1: usize = 24;

    // Thread entry.
    pub const T_STATE: usize = 0;
    pub const T_GENERATION: usize = 4;
    pub const T_TID: usize = 8;
    pub const T_QOS: usize = 16;
    pub const T_NAME_LEN: usize = 20;
    pub const T_NAME: usize = 24;
}

/// What a record marks (record byte 14).
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// A slice begins on this thread.
    Begin = 1,
    /// The innermost open slice of this thread ends.
    End = 2,
    /// A point in time.
    Instant = 3,
    /// An async slice begins; arg1 is its id (flag [`FLAG_ASYNC_ID`]).
    AsyncBegin = 4,
    /// The async slice with id arg1 ends.
    AsyncEnd = 5,
    /// A flow leaves this point; arg0 is the flow id.
    FlowOut = 6,
    /// A flow arrives at this point; arg0 is the flow id.
    FlowIn = 7,
    /// A counter sample; arg0 is the value.
    Counter = 8,
}

impl Phase {
    /// The phase stored as `raw`, if it is one.
    pub fn from_raw(raw: u8) -> Option<Phase> {
        Some(match raw {
            1 => Phase::Begin,
            2 => Phase::End,
            3 => Phase::Instant,
            4 => Phase::AsyncBegin,
            5 => Phase::AsyncEnd,
            6 => Phase::FlowOut,
            7 => Phase::FlowIn,
            8 => Phase::Counter,
            _ => return None,
        })
    }
}

/// Record flag bit 0: arg1 is an async or track id.
pub const FLAG_ASYNC_ID: u8 = 1 << 0;
/// Record flag bit 1: `t_ns` is an estimate (a present time, for example).
pub const FLAG_ESTIMATED: u8 = 1 << 1;

/// One record as a writer passes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record {
    pub t_ns: u64,
    pub name: u16,
    pub phase: Phase,
    pub flags: u8,
    pub arg0: u64,
    pub arg1: u64,
}

/// The identity a thread writes into the thread table on its first write to a ring.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ThreadInfo {
    /// The system thread id (`pthread_threadid_np`, `gettid`, `GetCurrentThreadId`).
    pub tid: u64,
    /// This thread's process-wide serial, from 1: chunk headers carry it, so a decoder never
    /// credits one thread's records to another that took its table entry or its tid.
    pub generation: u32,
    /// macOS `qos_class_t`; 0 elsewhere.
    pub qos: u32,
    pub name: [u8; THREAD_NAME_BYTES],
    pub name_len: u8,
}

impl ThreadInfo {
    /// An identity with these fields; `name` is cut at [`THREAD_NAME_BYTES`].
    pub fn new(tid: u64, generation: u32, qos: u32, name: &str) -> ThreadInfo {
        let mut info =
            ThreadInfo { tid, generation, qos, name: [0; THREAD_NAME_BYTES], name_len: 0 };
        let bytes = name.as_bytes();
        let len = bytes.len().min(THREAD_NAME_BYTES);
        info.name[..len].copy_from_slice(&bytes[..len]);
        info.name_len = len as u8;
        info
    }

    /// The calling thread's identity, read with no allocation.
    pub fn current(generation: u32) -> ThreadInfo {
        let mut info = ThreadInfo {
            tid: current_tid(),
            generation,
            qos: current_qos(),
            name: [0; THREAD_NAME_BYTES],
            name_len: 0,
        };
        info.name_len = current_name(&mut info.name);
        info
    }
}

#[cfg(target_os = "macos")]
fn current_tid() -> u64 {
    let mut id = 0u64;
    // SAFETY: a null thread names the calling thread; `id` is a valid out pointer.
    unsafe { libc::pthread_threadid_np(0, &mut id) };
    id
}

#[cfg(target_os = "linux")]
fn current_tid() -> u64 {
    // SAFETY: gettid has no preconditions.
    unsafe { libc::gettid() as u64 }
}

#[cfg(windows)]
fn current_tid() -> u64 {
    unsafe extern "system" {
        fn GetCurrentThreadId() -> u32;
    }
    // SAFETY: no preconditions.
    u64::from(unsafe { GetCurrentThreadId() })
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn current_tid() -> u64 {
    0
}

#[cfg(target_os = "macos")]
fn current_qos() -> u32 {
    let mut qos: libc::qos_class_t = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
    let mut relative = 0;
    // SAFETY: the calling thread's handle and two valid out pointers.
    unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut qos, &mut relative) };
    qos as u32
}

#[cfg(not(target_os = "macos"))]
fn current_qos() -> u32 {
    0
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn current_name(out: &mut [u8; THREAD_NAME_BYTES]) -> u8 {
    let mut buffer = [0u8; 64];
    // SAFETY: the calling thread's handle and a buffer of the length passed.
    let status = unsafe {
        libc::pthread_getname_np(libc::pthread_self(), buffer.as_mut_ptr().cast(), buffer.len())
    };
    if status != 0 {
        return 0;
    }
    let len =
        buffer.iter().position(|&byte| byte == 0).unwrap_or(buffer.len()).min(THREAD_NAME_BYTES);
    out[..len].copy_from_slice(&buffer[..len]);
    len as u8
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn current_name(_out: &mut [u8; THREAD_NAME_BYTES]) -> u8 {
    0
}

/// What a ring's header says and how big its tables are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RingConfig {
    /// Records the ring holds (rounded up to whole chunks, at least 4 chunks).
    pub records: usize,
    /// Thread-table entries.
    pub threads: u32,
    /// Name-table bytes (rounded up to a multiple of 4).
    pub name_bytes: u32,
    pub pid: u32,
    pub role: Role,
    pub clock: ClockDomain,
    pub start_ns: u64,
    pub boot_session: [u8; 16],
    pub build_id: [u8; 16],
}

impl RingConfig {
    /// The ring for this process: its pid, the platform clock, now as the start, and tables sized
    /// for `records`.
    pub fn for_process(role: Role, records: usize) -> RingConfig {
        RingConfig {
            records,
            threads: (records / 16).clamp(64, 1024) as u32,
            name_bytes: 16 * 1024,
            pid: std::process::id(),
            role,
            clock: ClockDomain::CURRENT,
            start_ns: crate::clock::now_ns(),
            boot_session: [0; 16],
            build_id: crate::build_id(),
        }
    }
}

/// Where each part of a ring sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RingLayout {
    pub chunk_count: usize,
    pub thread_capacity: usize,
    pub thread_offset: usize,
    pub name_offset: usize,
    pub name_bytes: usize,
    pub chunk_offset: usize,
    pub total_bytes: usize,
}

impl RingLayout {
    pub fn of(config: &RingConfig) -> RingLayout {
        let chunk_count = config.records.div_ceil(RECORDS_PER_CHUNK).clamp(MIN_CHUNKS, MAX_CHUNKS);
        let thread_capacity = config.threads as usize;
        let thread_offset = HEADER_BYTES;
        let name_offset = thread_offset + thread_capacity * THREAD_ENTRY_BYTES;
        let name_bytes = (config.name_bytes as usize).next_multiple_of(4);
        let chunk_offset = (name_offset + name_bytes).next_multiple_of(CHUNK_BYTES);
        RingLayout {
            chunk_count,
            thread_capacity,
            thread_offset,
            name_offset,
            name_bytes,
            chunk_offset,
            total_bytes: chunk_offset + chunk_count * CHUNK_BYTES,
        }
    }
}

/// A writer's place in a ring: the chunk it owns and its next slot. `Copy`, so a thread-local
/// `Cell` holds it with no destructor.
#[derive(Clone, Copy, Debug)]
pub struct WriterState {
    ring_generation: u32,
    thread_index: u32,
    thread_generation: u32,
    chunk: u32,
    next_slot: u32,
    lap: u64,
}

impl WriterState {
    /// A writer that has not written to any ring yet.
    pub const NEW: WriterState = WriterState {
        ring_generation: u32::MAX,
        thread_index: THREAD_UNKNOWN,
        thread_generation: 0,
        chunk: 0,
        next_slot: 0,
        lap: 0,
    };
}

/// One ring: a header, a thread table, a name table and chunks, in one block of memory that starts
/// on the heap and may move once to a shared file mapping ([`Ring::adopt_file`]).
pub struct Ring {
    /// The memory every access goes through. It changes at most once (heap to file) per ring.
    base: AtomicPtr<u8>,
    layout: RingLayout,
    config: RingConfig,
    /// Chunks in use (at most `layout.chunk_count`; a recording uses part of its mapping).
    chunk_count: AtomicU32,
    /// Bumped by [`Ring::reset`]: a writer whose state names another generation starts over.
    generation: AtomicU32,
    /// Chunk claims so far. Kept here, not in the block, so a base swap never forks it.
    cursor: AtomicU64,
    threads_used: AtomicU32,
    names_used: AtomicU32,
    overwrites: AtomicU64,
    thread_overflow: AtomicU32,
    name_overflow: AtomicU32,
    file_backed: AtomicBool,
    /// The first block. Kept for the ring's life: a writer may still hold its address after a swap.
    _heap: Option<HeapBlock>,
}

// SAFETY: every access to the block goes through atomics (see `a32` and `a64`); the block lives as
// long as the ring (the heap block is owned, a mapping is never unmapped).
unsafe impl Send for Ring {}
// SAFETY: as for Send.
unsafe impl Sync for Ring {}

impl Ring {
    /// A ring on a zeroed heap block.
    pub fn new(config: RingConfig) -> Ring {
        let layout = RingLayout::of(&config);
        let heap = HeapBlock::zeroed(layout.total_bytes);
        let ring = Ring::on(config, layout, heap.as_ptr(), Some(heap));
        ring.write_header(ring.base(), ring.config.boot_session);
        ring
    }

    /// A ring written straight into a file mapping of `path` (a recording). Falls back to the heap
    /// when the file cannot be mapped; [`Ring::is_file_backed`] says which.
    pub fn new_mapped(config: RingConfig, path: &Path) -> Ring {
        let layout = RingLayout::of(&config);
        match map::map_file(path, layout.total_bytes) {
            Ok(mapping) => {
                let ring = Ring::on(config, layout, mapping.as_ptr(), None);
                ring.file_backed.store(true, Ordering::Relaxed);
                ring.write_header(ring.base(), ring.config.boot_session);
                ring
            }
            Err(_) => Ring::new(config),
        }
    }

    fn on(config: RingConfig, layout: RingLayout, base: *mut u8, heap: Option<HeapBlock>) -> Ring {
        Ring {
            base: AtomicPtr::new(base),
            layout,
            config,
            chunk_count: AtomicU32::new(layout.chunk_count as u32),
            generation: AtomicU32::new(0),
            cursor: AtomicU64::new(0),
            threads_used: AtomicU32::new(0),
            names_used: AtomicU32::new(0),
            overwrites: AtomicU64::new(0),
            thread_overflow: AtomicU32::new(0),
            name_overflow: AtomicU32::new(0),
            file_backed: AtomicBool::new(false),
            _heap: heap,
        }
    }

    pub fn layout(&self) -> RingLayout {
        self.layout
    }

    pub fn config(&self) -> &RingConfig {
        &self.config
    }

    /// Records the ring holds now.
    pub fn capacity(&self) -> usize {
        self.chunk_count.load(Ordering::Relaxed) as usize * RECORDS_PER_CHUNK
    }

    /// Whether the ring lives in a file mapping.
    pub fn is_file_backed(&self) -> bool {
        self.file_backed.load(Ordering::Relaxed)
    }

    /// Chunks reclaimed before they were read (the overwrite count).
    pub fn overwrites(&self) -> u64 {
        self.overwrites.load(Ordering::Relaxed)
    }

    #[inline]
    fn base(&self) -> *mut u8 {
        self.base.load(Ordering::Acquire)
    }

    /// The u32 at `offset` of the block at `base`.
    #[inline]
    fn a32(&self, base: *mut u8, offset: usize) -> &AtomicU32 {
        debug_assert!(offset.is_multiple_of(4) && offset + 4 <= self.layout.total_bytes);
        // SAFETY: `base` is this ring's heap block or mapping (both live as long as the ring and
        // are `total_bytes` long and page-aligned), and `offset` is in bounds and 4-aligned. Every
        // access to this word is a u32 atomic.
        unsafe { AtomicU32::from_ptr(base.add(offset).cast()) }
    }

    /// The u64 at `offset` of the block at `base`.
    #[inline]
    fn a64(&self, base: *mut u8, offset: usize) -> &AtomicU64 {
        debug_assert!(offset.is_multiple_of(8) && offset + 8 <= self.layout.total_bytes);
        // SAFETY: as in `a32`, with an 8-aligned offset and u64 atomics only.
        unsafe { AtomicU64::from_ptr(base.add(offset).cast()) }
    }

    fn chunk_at(&self, chunk: usize) -> usize {
        self.layout.chunk_offset + chunk * CHUNK_BYTES
    }

    fn write_header(&self, base: *mut u8, boot_session: [u8; 16]) {
        let config = &self.config;
        let layout = &self.layout;
        let put32 = |offset, value: u32| self.a32(base, offset).store(value, Ordering::Relaxed);
        let put64 = |offset, value: u64| self.a64(base, offset).store(value, Ordering::Relaxed);
        put64(off::MAGIC, u64::from_le_bytes(MAGIC));
        put32(off::VERSION, VERSION);
        put32(off::HEADER_BYTES, HEADER_BYTES as u32);
        put32(off::PID, config.pid);
        put32(off::ROLE_CLOCK, u32::from(config.role as u8) | u32::from(config.clock as u8) << 8);
        put64(off::START_NS, config.start_ns);
        for (index, half) in boot_session.as_chunks::<8>().0.iter().enumerate() {
            put64(off::BOOT_SESSION + 8 * index, u64::from_le_bytes(*half));
        }
        for (index, half) in config.build_id.as_chunks::<8>().0.iter().enumerate() {
            put64(off::BUILD_ID + 8 * index, u64::from_le_bytes(*half));
        }
        put32(off::CHUNK_OFFSET, layout.chunk_offset as u32);
        put32(off::CHUNK_COUNT, self.chunk_count.load(Ordering::Relaxed));
        put32(off::CHUNK_BYTES, CHUNK_BYTES as u32);
        put32(off::RECORD_BYTES, RECORD_BYTES as u32);
        put32(off::THREAD_OFFSET, layout.thread_offset as u32);
        put32(off::THREAD_CAPACITY, layout.thread_capacity as u32);
        put32(off::THREAD_ENTRY_BYTES, THREAD_ENTRY_BYTES as u32);
        put32(off::NAME_OFFSET, layout.name_offset as u32);
        put32(off::NAME_BYTES, layout.name_bytes as u32);
        put64(off::OVERWRITES, self.overwrites.load(Ordering::Relaxed));
        put32(off::THREAD_OVERFLOW, self.thread_overflow.load(Ordering::Relaxed));
        put32(off::NAME_OVERFLOW, self.name_overflow.load(Ordering::Relaxed));
    }

    /// Writes `record` as the writer whose place is `state`. `who` names the calling thread; it
    /// runs only on the thread's first write to this ring generation. No lock, allocation or
    /// system call (registration reads the thread name once: `pthread_getname_np`).
    #[inline]
    pub fn write(&self, state: &mut WriterState, who: impl FnOnce() -> ThreadInfo, record: Record) {
        let generation = self.generation.load(Ordering::Relaxed);
        if state.ring_generation != generation {
            let info = who();
            state.ring_generation = generation;
            state.thread_generation = info.generation;
            state.thread_index = self.register_thread(&info);
            self.claim(state);
        } else if state.next_slot as usize > RECORDS_PER_CHUNK || !self.still_owns(state) {
            self.claim(state);
        }
        let base = self.base();
        let chunk = self.chunk_at(state.chunk as usize);
        let slot = chunk + state.next_slot as usize * RECORD_BYTES;
        let published = seq_published(state.lap);
        let sequence = self.a32(base, slot + off::R_SEQ);
        sequence.store(published.wrapping_sub(1), Ordering::Relaxed);
        fence(Ordering::Release);
        self.a64(base, slot + off::R_T).store(record.t_ns, Ordering::Relaxed);
        self.a32(base, slot + off::R_META).store(meta_word(&record), Ordering::Relaxed);
        self.a64(base, slot + off::R_ARG0).store(record.arg0, Ordering::Relaxed);
        self.a64(base, slot + off::R_ARG1).store(record.arg1, Ordering::Relaxed);
        sequence.store(published, Ordering::Release);
        self.a32(base, chunk + off::CH_PUBLISHED).store(state.next_slot, Ordering::Relaxed);
        state.next_slot += 1;
    }

    /// Whether the writer's chunk is still its own: a wrap may have handed it to another thread
    /// while this one slept between two writes. A check, not a lock: a wrap during the write
    /// itself can still interleave two writers, which needs the whole ring to cycle inside one
    /// 32-byte store sequence.
    #[inline]
    fn still_owns(&self, state: &WriterState) -> bool {
        self.a64(self.base(), self.chunk_at(state.chunk as usize) + off::CH_LAP)
            .load(Ordering::Relaxed)
            == state.lap
    }

    /// Takes the next chunk (one `fetch_add`) and writes its header for this thread.
    fn claim(&self, state: &mut WriterState) {
        let thread_generation = state.thread_generation;
        let count = u64::from(self.chunk_count.load(Ordering::Relaxed));
        let position = self.cursor.fetch_add(1, Ordering::Relaxed);
        let (chunk, lap) = ((position % count) as u32, position / count);
        if lap > 0 {
            let overwrites = self.overwrites.fetch_add(1, Ordering::Relaxed) + 1;
            self.a64(self.base(), off::OVERWRITES).store(overwrites, Ordering::Relaxed);
        }
        self.on_live_base(|base| {
            self.publish_chunk_header(
                base,
                chunk as usize,
                lap,
                state.thread_index,
                thread_generation,
            );
        });
        *state = WriterState { chunk, lap, next_slot: 1, ..*state };
    }

    fn publish_chunk_header(
        &self,
        base: *mut u8,
        chunk: usize,
        lap: u64,
        thread: u32,
        generation: u32,
    ) {
        let at = self.chunk_at(chunk);
        let lap_word = self.a64(base, at + off::CH_LAP);
        lap_word.store(LAP_CLAIMING, Ordering::Relaxed);
        fence(Ordering::Release);
        self.a32(base, at + off::CH_THREAD).store(thread, Ordering::Relaxed);
        self.a32(base, at + off::CH_GENERATION).store(generation, Ordering::Relaxed);
        self.a32(base, at + off::CH_PUBLISHED).store(0, Ordering::Relaxed);
        lap_word.store(lap, Ordering::Release);
    }

    /// Adds `info` to the thread table; [`THREAD_UNKNOWN`] (and a counted overflow) when it is full.
    fn register_thread(&self, info: &ThreadInfo) -> u32 {
        let index = self.threads_used.fetch_add(1, Ordering::Relaxed);
        if index as usize >= self.layout.thread_capacity {
            let overflow = self.thread_overflow.fetch_add(1, Ordering::Relaxed) + 1;
            self.a32(self.base(), off::THREAD_OVERFLOW).store(overflow, Ordering::Relaxed);
            return THREAD_UNKNOWN;
        }
        self.on_live_base(|base| self.write_thread_entry(base, index as usize, info));
        index
    }

    /// Runs `write` on the live block, and once more on the new block if the one heap-to-file swap
    /// happened meanwhile (the swap's second copy may already have passed this part).
    fn on_live_base(&self, write: impl Fn(*mut u8)) {
        let base = self.base();
        write(base);
        fence(Ordering::SeqCst);
        let now = self.base.load(Ordering::SeqCst);
        if now != base {
            write(now);
        }
    }

    fn write_thread_entry(&self, base: *mut u8, index: usize, info: &ThreadInfo) {
        let at = self.layout.thread_offset + index * THREAD_ENTRY_BYTES;
        self.a32(base, at + off::T_GENERATION).store(info.generation, Ordering::Relaxed);
        self.a64(base, at + off::T_TID).store(info.tid, Ordering::Relaxed);
        self.a32(base, at + off::T_QOS).store(info.qos, Ordering::Relaxed);
        self.a32(base, at + off::T_NAME_LEN).store(u32::from(info.name_len), Ordering::Relaxed);
        for (word, bytes) in info.name.as_chunks::<8>().0.iter().enumerate() {
            let value = u64::from_le_bytes(*bytes);
            self.a64(base, at + off::T_NAME + 8 * word).store(value, Ordering::Relaxed);
        }
        self.a32(base, at + off::T_STATE).store(1, Ordering::Release);
    }

    /// Adds name `id` (1..0xFFFE) to the header's name table, so a decoder of any build reads it.
    /// False when the table is full (counted) or the id or name cannot be stored. Not a hot path:
    /// each name registers once per process.
    pub fn register_name(&self, id: u16, name: &str) -> bool {
        let bytes = name.as_bytes();
        if id == 0 || u32::from(id) >= NAME_PENDING || bytes.len() > 0xFFFF {
            return false;
        }
        let entry_bytes = 4 + bytes.len().next_multiple_of(4);
        let start = self.names_used.fetch_add(entry_bytes as u32, Ordering::Relaxed) as usize;
        if start + entry_bytes > self.layout.name_bytes {
            // Leave the cursor past the end: later, shorter names must not fill in behind a gap
            // that no header describes.
            let overflow = self.name_overflow.fetch_add(1, Ordering::Relaxed) + 1;
            self.a32(self.base(), off::NAME_OVERFLOW).store(overflow, Ordering::Relaxed);
            return false;
        }
        self.on_live_base(|base| self.write_name_entry(base, start, id, bytes));
        true
    }

    fn write_name_entry(&self, base: *mut u8, start: usize, id: u16, bytes: &[u8]) {
        let at = self.layout.name_offset + start;
        let header = self.a32(base, at);
        let len = bytes.len() as u32;
        header.store(len | NAME_PENDING << 16, Ordering::Relaxed);
        for (word, part) in bytes.chunks(4).enumerate() {
            let mut padded = [0u8; 4];
            padded[..part.len()].copy_from_slice(part);
            self.a32(base, at + 4 + 4 * word).store(u32::from_le_bytes(padded), Ordering::Relaxed);
        }
        header.store(len | u32::from(id) << 16, Ordering::Release);
    }

    /// Moves the ring into a shared mapping of `path`: maps it, copies the block (header with the
    /// boot session, tables, every published record), swaps the base, then copies again what
    /// writers finished in the old block during the first copy. A record still being written into
    /// the old block when the second copy reaches it is lost (at most one per thread). Call it
    /// once, off the main thread (the black box does it on its ring-open thread).
    pub fn adopt_file(&self, path: &Path) -> io::Result<()> {
        let mapping = map::map_file(path, self.layout.total_bytes)?;
        let old = self.base();
        let new = mapping.as_ptr();
        self.copy_block(old, new, false);
        self.write_header(new, crate::clock::boot_session());
        self.base.store(new, Ordering::SeqCst);
        self.file_backed.store(true, Ordering::Relaxed);
        std::thread::yield_now();
        self.copy_block(old, new, true);
        Ok(())
    }

    /// A consistent copy of the ring's bytes, as a file of it would read: every record is either
    /// whole or absent. Allocates; never call it on a hot path.
    pub fn snapshot(&self) -> Vec<u8> {
        let words = HeapBlock::zeroed(self.layout.total_bytes);
        let base = self.base();
        for at in (0..HEADER_BYTES).step_by(8) {
            let value = self.a64(base, at).load(Ordering::Relaxed);
            self.a64(words.as_ptr(), at).store(value, Ordering::Relaxed);
        }
        self.copy_block(base, words.as_ptr(), false);
        // SAFETY: the block holds `total_bytes` initialised bytes and no one else writes it.
        unsafe { std::slice::from_raw_parts(words.as_ptr(), self.layout.total_bytes) }.to_vec()
    }

    fn read_boot_session(&self, base: *mut u8) -> [u8; 16] {
        let mut out = [0u8; 16];
        for half in 0..2 {
            let value = self.a64(base, off::BOOT_SESSION + 8 * half).load(Ordering::Relaxed);
            out[8 * half..8 * half + 8].copy_from_slice(&value.to_le_bytes());
        }
        out
    }

    /// Copies the tables and every whole record from `src` to `dst` (header excluded). With
    /// `merge`, only what `dst` lacks or holds from an older lap, with a seqlock write, because
    /// `dst` is live by then.
    fn copy_block(&self, src: *mut u8, dst: *mut u8, merge: bool) {
        self.copy_threads(src, dst, merge);
        self.copy_names(src, dst, merge);
        for chunk in 0..self.chunk_count.load(Ordering::Relaxed) as usize {
            self.copy_chunk(src, dst, chunk, merge);
        }
    }

    fn copy_threads(&self, src: *mut u8, dst: *mut u8, merge: bool) {
        for index in 0..self.layout.thread_capacity {
            let at = self.layout.thread_offset + index * THREAD_ENTRY_BYTES;
            if self.a32(src, at + off::T_STATE).load(Ordering::Acquire) != 1 {
                continue;
            }
            if merge && self.a32(dst, at + off::T_STATE).load(Ordering::Acquire) == 1 {
                continue;
            }
            let mut info = ThreadInfo {
                tid: self.a64(src, at + off::T_TID).load(Ordering::Relaxed),
                generation: self.a32(src, at + off::T_GENERATION).load(Ordering::Relaxed),
                qos: self.a32(src, at + off::T_QOS).load(Ordering::Relaxed),
                name: [0; THREAD_NAME_BYTES],
                name_len: self
                    .a32(src, at + off::T_NAME_LEN)
                    .load(Ordering::Relaxed)
                    .min(THREAD_NAME_BYTES as u32) as u8,
            };
            for word in 0..THREAD_NAME_BYTES / 8 {
                let value = self.a64(src, at + off::T_NAME + 8 * word).load(Ordering::Relaxed);
                info.name[8 * word..8 * word + 8].copy_from_slice(&value.to_le_bytes());
            }
            self.write_thread_entry(dst, index, &info);
        }
    }

    fn copy_names(&self, src: *mut u8, dst: *mut u8, merge: bool) {
        let used = (self.names_used.load(Ordering::Relaxed) as usize).min(self.layout.name_bytes);
        let mut start = 0;
        while start + 4 <= used {
            let at = self.layout.name_offset + start;
            let header = self.a32(src, at).load(Ordering::Acquire);
            if header == 0 {
                break;
            }
            let len = (header & 0xFFFF) as usize;
            let entry_bytes = 4 + len.next_multiple_of(4);
            if start + entry_bytes > self.layout.name_bytes {
                break;
            }
            let target = self.a32(dst, at);
            let copied = target.load(Ordering::Acquire);
            let done = merge && copied != 0 && copied >> 16 != NAME_PENDING;
            if !done {
                for word in 0..len.div_ceil(4) {
                    let value = self.a32(src, at + 4 + 4 * word).load(Ordering::Relaxed);
                    self.a32(dst, at + 4 + 4 * word).store(value, Ordering::Relaxed);
                }
                target.store(header, Ordering::Release);
            }
            start += entry_bytes;
        }
    }

    fn copy_chunk(&self, src: *mut u8, dst: *mut u8, chunk: usize, merge: bool) {
        let at = self.chunk_at(chunk);
        let Some((lap, thread, generation, published)) = self.read_chunk_header(src, at) else {
            return;
        };
        if generation == 0 {
            return;
        }
        let dst_generation = self.a32(dst, at + off::CH_GENERATION).load(Ordering::Relaxed);
        let dst_lap = self.a64(dst, at + off::CH_LAP).load(Ordering::Acquire);
        if !merge || dst_generation == 0 || (dst_lap != LAP_CLAIMING && dst_lap < lap) {
            self.publish_chunk_header(dst, chunk, lap, thread, generation);
            self.a32(dst, at + off::CH_PUBLISHED).store(published, Ordering::Relaxed);
        }
        let expected = seq_published(lap);
        for slot in 1..=RECORDS_PER_CHUNK {
            let record_at = at + slot * RECORD_BYTES;
            let Some(words) = self.read_record(src, record_at, expected) else { continue };
            let target = self.a32(dst, record_at + off::R_SEQ);
            if merge {
                let current = target.load(Ordering::Acquire);
                if current >= expected
                    || target
                        .compare_exchange(
                            current,
                            expected.wrapping_sub(1),
                            Ordering::Relaxed,
                            Ordering::Relaxed,
                        )
                        .is_err()
                {
                    continue;
                }
            } else {
                target.store(expected.wrapping_sub(1), Ordering::Relaxed);
            }
            fence(Ordering::Release);
            self.a64(dst, record_at + off::R_T).store(words.0, Ordering::Relaxed);
            self.a32(dst, record_at + off::R_META).store(words.1, Ordering::Relaxed);
            self.a64(dst, record_at + off::R_ARG0).store(words.2, Ordering::Relaxed);
            self.a64(dst, record_at + off::R_ARG1).store(words.3, Ordering::Relaxed);
            target.store(expected, Ordering::Release);
        }
    }

    /// The chunk header at `at`, read consistently: (lap, thread, generation, published), or None
    /// while a claimer rewrites it.
    fn read_chunk_header(&self, base: *mut u8, at: usize) -> Option<(u64, u32, u32, u32)> {
        let lap_word = self.a64(base, at + off::CH_LAP);
        let lap = lap_word.load(Ordering::Acquire);
        let thread = self.a32(base, at + off::CH_THREAD).load(Ordering::Relaxed);
        let generation = self.a32(base, at + off::CH_GENERATION).load(Ordering::Relaxed);
        let published = self.a32(base, at + off::CH_PUBLISHED).load(Ordering::Relaxed);
        fence(Ordering::Acquire);
        (lap != LAP_CLAIMING && lap_word.load(Ordering::Relaxed) == lap)
            .then_some((lap, thread, generation, published))
    }

    /// The record at `at` when it is whole and of the lap whose published sequence is `expected`.
    fn read_record(&self, base: *mut u8, at: usize, expected: u32) -> Option<(u64, u32, u64, u64)> {
        let sequence = self.a32(base, at + off::R_SEQ);
        if sequence.load(Ordering::Acquire) != expected {
            return None;
        }
        let words = (
            self.a64(base, at + off::R_T).load(Ordering::Relaxed),
            self.a32(base, at + off::R_META).load(Ordering::Relaxed),
            self.a64(base, at + off::R_ARG0).load(Ordering::Relaxed),
            self.a64(base, at + off::R_ARG1).load(Ordering::Relaxed),
        );
        fence(Ordering::Acquire);
        (sequence.load(Ordering::Relaxed) == expected).then_some(words)
    }

    /// Empties the ring for a new recording of `records` (capped at its size): clears every chunk
    /// and thread entry used before and bumps the generation, so each writer re-registers and
    /// claims afresh. The name table stays (names are append-only). Call it only while the ring is
    /// not the active one.
    pub(crate) fn reset(&self, records: usize) {
        let base = self.base();
        self.generation.fetch_add(1, Ordering::AcqRel);
        let used_chunks = self
            .cursor
            .load(Ordering::Relaxed)
            .min(u64::from(self.chunk_count.load(Ordering::Relaxed)));
        for chunk in 0..used_chunks as usize {
            let at = self.chunk_at(chunk);
            for slot in 1..=RECORDS_PER_CHUNK {
                self.a32(base, at + slot * RECORD_BYTES + off::R_SEQ).store(0, Ordering::Relaxed);
            }
            self.a32(base, at + off::CH_GENERATION).store(0, Ordering::Relaxed);
            self.a32(base, at + off::CH_THREAD).store(0, Ordering::Relaxed);
            self.a32(base, at + off::CH_PUBLISHED).store(0, Ordering::Relaxed);
            self.a64(base, at + off::CH_LAP).store(0, Ordering::Relaxed);
        }
        let threads = (self.threads_used.swap(0, Ordering::Relaxed) as usize)
            .min(self.layout.thread_capacity);
        for index in 0..threads {
            self.a32(base, self.layout.thread_offset + index * THREAD_ENTRY_BYTES + off::T_STATE)
                .store(0, Ordering::Relaxed);
        }
        let chunks = records.div_ceil(RECORDS_PER_CHUNK).clamp(MIN_CHUNKS, self.layout.chunk_count);
        self.chunk_count.store(chunks as u32, Ordering::Relaxed);
        self.cursor.store(0, Ordering::Relaxed);
        self.overwrites.store(0, Ordering::Relaxed);
        self.thread_overflow.store(0, Ordering::Relaxed);
        self.write_header(base, self.read_boot_session(base));
        self.a64(base, off::START_NS).store(crate::clock::now_ns(), Ordering::Relaxed);
        fence(Ordering::Release);
    }
}

/// The sequence of a published record of chunk lap `lap` (`2*lap+2`; the writer stores one less,
/// an odd value, while it writes).
#[inline]
fn seq_published(lap: u64) -> u32 {
    (lap as u32).wrapping_mul(2).wrapping_add(2)
}

#[inline]
fn meta_word(record: &Record) -> u32 {
    u32::from(record.name) | u32::from(record.phase as u8) << 16 | u32::from(record.flags) << 24
}

/// A writer for one thread on one ring (tests, benches and single-ring tools). The process-wide
/// trace points use [`crate::write`], which keeps the same state in a thread-local.
pub struct Writer<'a> {
    ring: &'a Ring,
    state: WriterState,
    info: ThreadInfo,
}

impl<'a> Writer<'a> {
    pub fn new(ring: &'a Ring, info: ThreadInfo) -> Writer<'a> {
        Writer { ring, state: WriterState::NEW, info }
    }

    #[inline]
    pub fn write(&mut self, record: Record) {
        let info = self.info;
        self.ring.write(&mut self.state, || info, record);
    }
}

/// Why bytes are not a ring v1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// Shorter than its header says.
    Truncated,
    /// Not `CMXTRACE`.
    BadMagic,
    /// A version this decoder does not know.
    UnsupportedVersion(u32),
    /// A size or offset in the header that cannot be right.
    BadLayout(&'static str),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::Truncated => f.write_str("trace ring is truncated"),
            DecodeError::BadMagic => f.write_str("not a cmux trace ring (bad magic)"),
            DecodeError::UnsupportedVersion(version) => {
                write!(f, "trace ring version {version} is not supported")
            }
            DecodeError::BadLayout(what) => write!(f, "trace ring layout is invalid: {what}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// A decoded header.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub version: u32,
    pub pid: u32,
    pub role: u8,
    pub clock: u8,
    pub start_ns: u64,
    pub boot_session: [u8; 16],
    pub build_id: [u8; 16],
    pub chunk_count: u32,
    pub thread_capacity: u32,
    pub overwrites: u64,
    pub thread_overflow: u32,
    pub name_overflow: u32,
}

/// A decoded thread-table entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadEntry {
    pub index: u32,
    pub generation: u32,
    pub tid: u64,
    pub qos: u32,
    pub name: String,
}

/// A decoded record with the thread its chunk names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DecodedRecord {
    /// The chunk claim it was written in (`lap * chunk_count + chunk`): a thread's records sorted
    /// by (position, slot) are in the order it wrote them.
    pub position: u64,
    pub slot: u8,
    pub thread_index: u32,
    pub thread_generation: u32,
    pub t_ns: u64,
    pub name: u16,
    pub phase: u8,
    pub flags: u8,
    pub arg0: u64,
    pub arg1: u64,
}

/// A decoded ring: records merged by `t_ns`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decoded {
    pub header: Header,
    pub threads: Vec<ThreadEntry>,
    pub names: Vec<(u16, String)>,
    pub records: Vec<DecodedRecord>,
}

fn read_u32(bytes: &[u8], at: usize) -> Result<u32, DecodeError> {
    let word = bytes.get(at..).and_then(<[u8]>::first_chunk).ok_or(DecodeError::Truncated)?;
    Ok(u32::from_le_bytes(*word))
}

fn read_u64(bytes: &[u8], at: usize) -> Result<u64, DecodeError> {
    let word = bytes.get(at..).and_then(<[u8]>::first_chunk).ok_or(DecodeError::Truncated)?;
    Ok(u64::from_le_bytes(*word))
}

fn read_16(bytes: &[u8], at: usize) -> Result<[u8; 16], DecodeError> {
    bytes.get(at..).and_then(<[u8]>::first_chunk).copied().ok_or(DecodeError::Truncated)
}

/// Decodes a ring file (or a [`Ring::snapshot`]). Keeps only records whose sequence is the
/// published sequence of their chunk's lap, so a torn or overwritten record never appears.
pub fn decode(bytes: &[u8]) -> Result<Decoded, DecodeError> {
    if bytes.get(..8).ok_or(DecodeError::Truncated)? != MAGIC {
        return Err(DecodeError::BadMagic);
    }
    let version = read_u32(bytes, off::VERSION)?;
    if version != VERSION {
        return Err(DecodeError::UnsupportedVersion(version));
    }
    if read_u32(bytes, off::CHUNK_BYTES)? as usize != CHUNK_BYTES
        || read_u32(bytes, off::RECORD_BYTES)? as usize != RECORD_BYTES
        || read_u32(bytes, off::THREAD_ENTRY_BYTES)? as usize != THREAD_ENTRY_BYTES
    {
        return Err(DecodeError::BadLayout("record, chunk or thread entry size"));
    }
    let role_clock = read_u32(bytes, off::ROLE_CLOCK)?;
    let header = Header {
        version,
        pid: read_u32(bytes, off::PID)?,
        role: role_clock as u8,
        clock: (role_clock >> 8) as u8,
        start_ns: read_u64(bytes, off::START_NS)?,
        boot_session: read_16(bytes, off::BOOT_SESSION)?,
        build_id: read_16(bytes, off::BUILD_ID)?,
        chunk_count: read_u32(bytes, off::CHUNK_COUNT)?,
        thread_capacity: read_u32(bytes, off::THREAD_CAPACITY)?,
        overwrites: read_u64(bytes, off::OVERWRITES)?,
        thread_overflow: read_u32(bytes, off::THREAD_OVERFLOW)?,
        name_overflow: read_u32(bytes, off::NAME_OVERFLOW)?,
    };
    let chunk_offset = read_u32(bytes, off::CHUNK_OFFSET)? as usize;
    let thread_offset = read_u32(bytes, off::THREAD_OFFSET)? as usize;
    let name_offset = read_u32(bytes, off::NAME_OFFSET)? as usize;
    let name_bytes = read_u32(bytes, off::NAME_BYTES)? as usize;
    let threads_end = thread_offset
        .checked_add(header.thread_capacity as usize * THREAD_ENTRY_BYTES)
        .ok_or(DecodeError::BadLayout("thread table"))?;
    let chunks_end = (header.chunk_count as usize)
        .checked_mul(CHUNK_BYTES)
        .and_then(|bytes| bytes.checked_add(chunk_offset))
        .ok_or(DecodeError::BadLayout("chunks"))?;
    if thread_offset < HEADER_BYTES
        || threads_end > bytes.len()
        || name_offset + name_bytes > bytes.len()
    {
        return Err(DecodeError::Truncated);
    }
    if chunks_end > bytes.len() {
        return Err(DecodeError::Truncated);
    }

    let mut threads = Vec::new();
    for index in 0..header.thread_capacity as usize {
        let at = thread_offset + index * THREAD_ENTRY_BYTES;
        if read_u32(bytes, at + off::T_STATE)? != 1 {
            continue;
        }
        let len = (read_u32(bytes, at + off::T_NAME_LEN)? as usize).min(THREAD_NAME_BYTES);
        threads.push(ThreadEntry {
            index: index as u32,
            generation: read_u32(bytes, at + off::T_GENERATION)?,
            tid: read_u64(bytes, at + off::T_TID)?,
            qos: read_u32(bytes, at + off::T_QOS)?,
            name: String::from_utf8_lossy(&bytes[at + off::T_NAME..at + off::T_NAME + len])
                .into_owned(),
        });
    }

    let mut names = Vec::new();
    let mut start = 0;
    while start + 4 <= name_bytes {
        let at = name_offset + start;
        let header_word = read_u32(bytes, at)?;
        if header_word == 0 {
            break;
        }
        let len = (header_word & 0xFFFF) as usize;
        let id = header_word >> 16;
        let entry_bytes = 4 + len.next_multiple_of(4);
        if start + entry_bytes > name_bytes {
            break;
        }
        if id != NAME_PENDING {
            names.push((
                id as u16,
                String::from_utf8_lossy(&bytes[at + 4..at + 4 + len]).into_owned(),
            ));
        }
        start += entry_bytes;
    }

    let mut records = Vec::new();
    for chunk in 0..header.chunk_count as usize {
        let at = chunk_offset + chunk * CHUNK_BYTES;
        let lap = read_u64(bytes, at + off::CH_LAP)?;
        let generation = read_u32(bytes, at + off::CH_GENERATION)?;
        if lap == LAP_CLAIMING || generation == 0 {
            continue;
        }
        let thread_index = read_u32(bytes, at + off::CH_THREAD)?;
        let expected = seq_published(lap);
        for slot in 1..=RECORDS_PER_CHUNK {
            let record_at = at + slot * RECORD_BYTES;
            if read_u32(bytes, record_at + off::R_SEQ)? != expected {
                continue;
            }
            let meta = read_u32(bytes, record_at + off::R_META)?;
            records.push(DecodedRecord {
                position: lap * u64::from(header.chunk_count) + chunk as u64,
                slot: slot as u8,
                thread_index,
                thread_generation: generation,
                t_ns: read_u64(bytes, record_at + off::R_T)?,
                name: meta as u16,
                phase: (meta >> 16) as u8,
                flags: (meta >> 24) as u8,
                arg0: read_u64(bytes, record_at + off::R_ARG0)?,
                arg1: read_u64(bytes, record_at + off::R_ARG1)?,
            });
        }
    }
    records.sort_by_key(|record| (record.t_ns, record.position, record.slot));
    Ok(Decoded { header, threads, names, records })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(records: usize) -> RingConfig {
        RingConfig { threads: 8, name_bytes: 256, ..RingConfig::for_process(Role::Daemon, records) }
    }

    fn record(t_ns: u64, arg0: u64) -> Record {
        Record { t_ns, name: 3, phase: Phase::Instant, flags: 0, arg0, arg1: !arg0 }
    }

    #[test]
    fn the_layout_aligns_chunks_and_keeps_tables_apart() {
        let layout = RingLayout::of(&config(4096));
        assert_eq!(layout.chunk_count, 4096usize.div_ceil(31));
        assert_eq!(layout.thread_offset, HEADER_BYTES);
        assert_eq!(layout.name_offset, HEADER_BYTES + 8 * THREAD_ENTRY_BYTES);
        assert_eq!(layout.chunk_offset % CHUNK_BYTES, 0);
        assert!(layout.chunk_offset >= layout.name_offset + layout.name_bytes);
        assert_eq!(RingLayout::of(&config(1)).chunk_count, MIN_CHUNKS);
    }

    #[test]
    fn a_full_chunk_moves_the_writer_to_the_next_claim() {
        let ring = Ring::new(config(31 * 8));
        let mut writer = Writer::new(&ring, ThreadInfo::new(1, 1, 0, "t"));
        for index in 0..40 {
            writer.write(record(index, index));
        }
        let decoded = decode(&ring.snapshot()).expect("decodes");
        assert_eq!(decoded.records.len(), 40);
        assert_eq!(decoded.records[30].position, 0);
        assert_eq!(decoded.records[31].position, 1);
        assert_eq!(decoded.records[31].slot, 1);
    }

    #[test]
    fn a_reset_empties_the_ring_and_writers_start_over() {
        let ring = Ring::new(config(31 * 8));
        let mut writer = Writer::new(&ring, ThreadInfo::new(1, 1, 0, "t"));
        for index in 0..100 {
            writer.write(record(index, index));
        }
        ring.reset(31 * 4);
        assert_eq!(ring.capacity(), 31 * 4);
        let decoded = decode(&ring.snapshot()).expect("decodes");
        assert!(decoded.records.is_empty() && decoded.threads.is_empty());
        writer.write(record(500, 500));
        let decoded = decode(&ring.snapshot()).expect("decodes");
        assert_eq!(decoded.records.len(), 1);
        assert_eq!(decoded.records[0].position, 0);
        assert_eq!(decoded.threads.len(), 1);
    }

    #[test]
    fn a_name_table_that_fills_counts_and_refuses() {
        let ring = Ring::new(RingConfig { name_bytes: 16, ..config(64) });
        assert!(ring.register_name(1, "abcdefgh"));
        assert!(!ring.register_name(2, "longer than the rest"));
        assert!(!ring.register_name(3, "x"), "a name filled in behind a gap");
        assert!(!ring.register_name(0, "zero"));
        let decoded = decode(&ring.snapshot()).expect("decodes");
        assert_eq!(decoded.names, vec![(1, "abcdefgh".to_owned())]);
        assert_eq!(decoded.header.name_overflow, 2);
    }

    #[test]
    fn a_full_thread_table_writes_records_as_unknown() {
        let ring = Ring::new(RingConfig { threads: 1, ..config(64) });
        let mut first = Writer::new(&ring, ThreadInfo::new(1, 1, 0, "a"));
        let mut second = Writer::new(&ring, ThreadInfo::new(2, 2, 0, "b"));
        first.write(record(1, 1));
        second.write(record(2, 2));
        let decoded = decode(&ring.snapshot()).expect("decodes");
        assert_eq!(decoded.threads.len(), 1);
        assert_eq!(decoded.header.thread_overflow, 1);
        assert_eq!(decoded.records[1].thread_index, THREAD_UNKNOWN);
        assert_eq!(decoded.records[1].thread_generation, 2);
    }

    #[test]
    fn bad_bytes_decode_to_errors_not_panics() {
        assert_eq!(decode(b"short"), Err(DecodeError::Truncated));
        assert_eq!(decode(&[0u8; 300]), Err(DecodeError::BadMagic));
        let mut bytes = Ring::new(config(64)).snapshot();
        bytes.truncate(bytes.len() - 1);
        assert_eq!(decode(&bytes), Err(DecodeError::Truncated));
        let mut bytes = Ring::new(config(64)).snapshot();
        bytes[off::VERSION] = 9;
        assert_eq!(decode(&bytes), Err(DecodeError::UnsupportedVersion(9)));
        let mut bytes = Ring::new(config(64)).snapshot();
        bytes[off::CHUNK_COUNT..off::CHUNK_COUNT + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(decode(&bytes).is_err());
    }
}
