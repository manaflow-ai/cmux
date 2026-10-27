//! A process's rings and its one write path (plans/cmux-next/trace.md, "One write path"): the heap
//! ring, the black-box file and the recording ring, and one atomic word that names the active
//! ring with an epoch that grows at every change. A writer compares its chunk's epoch with the
//! word on each write; on a change it completes its chunk and claims from the active ring, so no
//! ring's memory ever moves under a writer and no write needs a second pass.

use std::io;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering};

use crate::clock::ClockDomain;
use crate::copy;
use crate::identity::{ProcessIdentity, ThreadIdentity};
use crate::layout::{CatalogName, RECORDS_PER_CHUNK, RingKind, RingLayout, RingSizes, off};
use crate::map::{self, Reserve};
use crate::ring::{HeaderFields, Record, Ring};
use crate::{Role, Status, TraceError};

/// The active word: bits 0-1 the active ring's slot, bit 2 "the black box is the file", bit 3
/// "a recording runs", bits 8-63 the epoch.
const SLOT_MASK: u64 = 0b11;
const BLACKBOX_IS_FILE: u64 = 1 << 2;
const RECORDING_ON: u64 = 1 << 3;
const EPOCH_ONE: u64 = 1 << 8;
const SLOT_HEAP: usize = 0;
const SLOT_FILE: usize = 1;
const SLOT_RECORDING: usize = 2;
const SLOTS: usize = 3;

/// `start_recording` and `stop` exclude each other with this state, never by waiting.
const IDLE: u8 = 0;
const CHANGING: u8 = 1;
const RECORDING: u8 = 2;

/// The clocks a ring's start fields read. Injected so a golden ring has fixed start times.
#[derive(Clone, Copy, Debug)]
pub struct StartClocks {
    pub uptime_ns: fn() -> u64,
    pub unix_ns: fn() -> u64,
    pub continuous_ns: fn() -> u64,
    pub domain: ClockDomain,
}

impl StartClocks {
    pub const SYSTEM: StartClocks = StartClocks {
        uptime_ns: crate::clock::now_ns,
        unix_ns: crate::clock::unix_ns,
        continuous_ns: crate::clock::continuous_ns,
        domain: ClockDomain::CURRENT,
    };
}

/// Everything a [`Tracer`] reads from its environment.
#[derive(Clone, Debug)]
pub struct TracerConfig {
    pub role: Role,
    /// Where the black-box and recording files go.
    pub dir: PathBuf,
    pub blackbox: RingSizes,
    pub recording: RingSizes,
    /// The categories on while no recording runs.
    pub blackbox_categories: u64,
    pub clocks: StartClocks,
    /// The process fields known at once ([`ProcessIdentity::current_fast`]).
    pub identity: ProcessIdentity,
    /// Fills the fields that need a system call; runs once, off the main thread.
    pub read_slow_identity: fn(&mut ProcessIdentity),
    /// Reserves a ring file's blocks before it is mapped ([`map::reserve_blocks`]).
    pub reserve: Reserve,
}

impl TracerConfig {
    /// This process as `role`: the role's sizes, the system clocks and identity.
    pub fn for_process(dir: impl Into<PathBuf>, role: Role) -> TracerConfig {
        TracerConfig {
            role,
            dir: dir.into(),
            blackbox: role.blackbox_sizes(),
            recording: role.recording_sizes(),
            blackbox_categories: crate::category::BLACKBOX,
            clocks: StartClocks::SYSTEM,
            identity: ProcessIdentity::current_fast(),
            read_slow_identity: ProcessIdentity::read_slow,
            reserve: map::reserve_blocks,
        }
    }
}

/// A trace point whose name is interned at run time: one id per ring (bits `16*slot` of `ids`,
/// 0 until interned there). Serves one [`Tracer`] (the process's, for a `static`).
#[derive(Debug)]
pub struct InternedName {
    text: &'static str,
    category: u8,
    ids: AtomicU64,
}

impl InternedName {
    pub const fn new(text: &'static str, category: u8) -> InternedName {
        InternedName { text, category, ids: AtomicU64::new(0) }
    }

    /// Its id in the ring in `slot`, interned there at its first record. When two threads intern
    /// it at once, both entries are published and the record uses the id that won.
    fn id_in(&self, ring: &Ring, slot: usize) -> u16 {
        let shift = 16 * slot as u32;
        let id = (self.ids.load(Ordering::Relaxed) >> shift) as u16;
        if id != 0 {
            return id;
        }
        let id = ring.intern(self.text, self.category);
        if id == 0 {
            return 0;
        }
        let set = self.ids.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |ids| {
            ((ids >> shift) as u16 == 0).then_some(ids | u64::from(id) << shift)
        });
        set.map_or_else(|ids| (ids >> shift) as u16, |_| id)
    }
}

/// The ring a record went into: the black box (the heap ring and the file it is copied into are
/// one), or one recording, named by the epoch its start set. A scope's end goes only into the ring
/// its begin went into.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RingId(u64);

impl RingId {
    const BLACKBOX: RingId = RingId(0);

    fn of(word: u64) -> RingId {
        if (word & SLOT_MASK) as usize == SLOT_RECORDING {
            RingId(word & !(EPOCH_ONE - 1) | SLOT_RECORDING as u64)
        } else {
            RingId::BLACKBOX
        }
    }
}

/// The chunk a writer owns.
#[derive(Clone, Copy, Debug)]
struct Owned {
    slot: usize,
    epoch: u64,
    chunk: u32,
    lap: u64,
    next_slot: u32,
}

/// One thread's place in a tracer's rings: its identity (read once), its entry in each ring and
/// the chunk it owns.
#[derive(Clone, Copy, Debug)]
pub(crate) struct WriterState {
    identity: Option<ThreadIdentity>,
    entries: [Option<(u32, u32)>; SLOTS],
    chunk: Option<Owned>,
}

impl WriterState {
    pub(crate) const NEW: WriterState =
        WriterState { identity: None, entries: [None; SLOTS], chunk: None };

    /// (index, generation) of this thread in `ring`, registering it there at its first record.
    fn entry(&mut self, ring: &Ring, slot: usize) -> (u32, u32) {
        if let Some(entry) = self.entries[slot] {
            return entry;
        }
        let identity = *self.identity.get_or_insert_with(ThreadIdentity::current);
        let entry = ring.register_thread(&identity);
        self.entries[slot] = Some(entry);
        entry
    }
}

/// A process's rings and trace state. The process has one, behind [`crate::init_blackbox`]; tests
/// and tools make their own.
pub struct Tracer {
    config: TracerConfig,
    /// The fixed names every ring of the tracer starts with.
    catalog: &'static [CatalogName],
    heap: Ring,
    file: OnceLock<Ring>,
    recording: OnceLock<Ring>,
    identity: OnceLock<ProcessIdentity>,
    active: AtomicU64,
    categories: AtomicU64,
    /// The process-wide category word [`crate::enabled`] reads, for the process's tracer.
    mirror: Option<&'static AtomicU64>,
    control: AtomicU8,
    adopting: AtomicBool,
    map_failures: AtomicU32,
    blackbox_path: OnceLock<PathBuf>,
    recording_path: OnceLock<PathBuf>,
}

impl Tracer {
    /// A tracer whose heap ring is active at once, its rings naming the shared catalog
    /// ([`crate::names::CATALOG`]) the trace macros resolve their ids from. Makes no system call
    /// but the heap allocation.
    pub fn new(config: TracerConfig) -> Tracer {
        Tracer::with_catalog(config, crate::names::CATALOG)
    }

    /// [`Tracer::new`] whose rings start with `catalog` instead: for a tracer the trace macros
    /// never write to (the process's tracer always names the shared catalog).
    pub fn with_catalog(config: TracerConfig, catalog: &'static [CatalogName]) -> Tracer {
        Tracer::with_mirror(config, catalog, None)
    }

    pub(crate) fn with_mirror(
        config: TracerConfig,
        catalog: &'static [CatalogName],
        mirror: Option<&'static AtomicU64>,
    ) -> Tracer {
        let heap = Ring::on_heap(RingLayout::of(config.blackbox));
        let tracer = Tracer {
            heap,
            file: OnceLock::new(),
            recording: OnceLock::new(),
            identity: OnceLock::new(),
            active: AtomicU64::new(SLOT_HEAP as u64 | EPOCH_ONE),
            categories: AtomicU64::new(config.blackbox_categories),
            mirror,
            control: AtomicU8::new(IDLE),
            adopting: AtomicBool::new(false),
            map_failures: AtomicU32::new(0),
            blackbox_path: OnceLock::new(),
            recording_path: OnceLock::new(),
            config,
            catalog,
        };
        let fields = tracer.header_fields(RingKind::BlackBox, &tracer.config.identity);
        tracer.heap.init(&fields, tracer.catalog);
        if let Some(mirror) = mirror {
            mirror.store(tracer.config.blackbox_categories, Ordering::Release);
        }
        tracer
    }

    pub fn config(&self) -> &TracerConfig {
        &self.config
    }

    /// Whether trace points of `category` record now.
    pub fn enabled(&self, category: u64) -> bool {
        self.categories.load(Ordering::Relaxed) & category != 0
    }

    fn header_fields(&self, kind: RingKind, identity: &ProcessIdentity) -> HeaderFields {
        let clocks = self.config.clocks;
        HeaderFields {
            pid: identity.pid,
            role: self.config.role as u16,
            kind,
            clock_domain: clocks.domain as u8,
            start_uptime_ns: (clocks.uptime_ns)(),
            start_unix_ns: (clocks.unix_ns)(),
            start_continuous_ns: (clocks.continuous_ns)(),
            process_start_unix_us: identity.process_start_unix_us,
            boot_session_uuid: identity.boot_session_uuid,
            build_uuid: identity.build_uuid,
            build_version: identity.build_version,
            categories: self.categories.load(Ordering::Relaxed),
        }
    }

    fn full_identity(&self) -> &ProcessIdentity {
        self.identity.get_or_init(|| {
            let mut identity = self.config.identity;
            (self.config.read_slow_identity)(&mut identity);
            identity
        })
    }

    fn ring(&self, slot: usize) -> Option<&Ring> {
        match slot {
            SLOT_HEAP => Some(&self.heap),
            SLOT_FILE => self.file.get(),
            SLOT_RECORDING => self.recording.get(),
            _ => None,
        }
    }

    fn active_ring(&self) -> &Ring {
        let slot = (self.active.load(Ordering::Acquire) & SLOT_MASK) as usize;
        self.ring(slot).unwrap_or(&self.heap)
    }

    fn set_categories(&self, categories: u64) {
        self.categories.store(categories, Ordering::Release);
        if let Some(mirror) = self.mirror {
            mirror.store(categories, Ordering::Release);
        }
        for slot in 0..SLOTS {
            if let Some(ring) = self.ring(slot) {
                ring.set_categories(categories);
            }
        }
    }

    /// Writes `record` as the thread whose place is `state`, into the active ring; with
    /// `interned`, under that name's id in the ring; with `only_in`, only while that ring is the
    /// active one. The ring it went into, if it was written. No lock or allocation; the
    /// read-modify-writes are the chunk claim's, once per 31 records.
    #[inline]
    pub(crate) fn write(
        &self,
        state: &mut WriterState,
        mut record: Record,
        interned: Option<&InternedName>,
        only_in: Option<RingId>,
    ) -> Option<RingId> {
        let word = self.active.load(Ordering::Acquire);
        let ring_id = RingId::of(word);
        if only_in.is_some_and(|only_in| only_in != ring_id) {
            return None;
        }
        let (slot, epoch) = ((word & SLOT_MASK) as usize, word >> 8);
        let ring = self.ring(slot)?;
        if let Some(owned) = state.chunk.filter(|owned| owned.epoch != epoch) {
            if let Some(old) = self.ring(owned.slot) {
                old.complete(owned.chunk, owned.lap);
            }
            state.chunk = None;
        }
        let (index, generation) = state.entry(ring, slot);
        if let Some(name) = interned {
            record.name = name.id_in(ring, slot);
        }
        let mut owned = match state.chunk {
            Some(owned) => owned,
            None => {
                let (chunk, lap) = ring.claim(index, generation)?;
                Owned { slot, epoch, chunk, lap, next_slot: 1 }
            }
        };
        ring.publish(owned.chunk, owned.lap, owned.next_slot, &record);
        if owned.next_slot == RECORDS_PER_CHUNK {
            ring.complete(owned.chunk, owned.lap);
            state.chunk = None;
        } else {
            owned.next_slot += 1;
            state.chunk = Some(owned);
        }
        Some(ring_id)
    }

    /// A thread's exit (its TLS destructor): completes its chunk and marks each of its entries
    /// exited, so a later thread may take them.
    pub(crate) fn exit(&self, state: &mut WriterState) {
        if let Some(owned) = state.chunk.take()
            && let Some(ring) = self.ring(owned.slot)
        {
            ring.complete(owned.chunk, owned.lap);
        }
        for (slot, entry) in state.entries.iter().enumerate() {
            if let (Some((index, _)), Some(ring)) = (entry, self.ring(slot)) {
                ring.exit_thread(*index);
            }
        }
        *state = WriterState::NEW;
    }

    /// "Heap, then file": maps `<dir>/<role>-<pid>.blackbox.cmxtrace`, copies the heap ring into it
    /// (copy first, swap last, so no writer claims in the file before the copy is done), then
    /// makes it the black box. Blocking: call it once, off the main thread. On an error the heap
    /// ring stays the black box.
    pub fn adopt_file(&self) -> io::Result<PathBuf> {
        if self.adopting.swap(true, Ordering::AcqRel) {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, "the black box has a file"));
        }
        let identity = *self.full_identity();
        let path = self.config.dir.join(crate::blackbox_file_name(self.config.role, identity.pid));
        let layout = *self.heap.layout();
        let mapped = map::create_private_dir(&self.config.dir)
            .and_then(|()| map::map_file(&path, layout.total_bytes, self.config.reserve));
        let mapping = mapped.inspect_err(|_| {
            self.map_failures.fetch_add(1, Ordering::Relaxed);
        })?;
        let file = Ring::on_mapping(layout, mapping);
        let copied = copy::copy_ring(&self.heap, &file);
        file.put_slow_identity(identity.process_start_unix_us, identity.boot_session_uuid);
        file.a64(off::HEAP_CURSOR).store(copied.chunk_cursor, Ordering::Relaxed);
        let count = u64::from(layout.sizes.chunk_count);
        file.a64(off::CHUNK_CURSOR).store(copied.chunk_cursor + count, Ordering::Relaxed);
        file.set_categories(self.categories.load(Ordering::Relaxed));
        let file = self.file.get_or_init(|| file);
        let _ = self.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |word| {
            Some(if word & RECORDING_ON != 0 {
                word | BLACKBOX_IS_FILE
            } else {
                ((word & !SLOT_MASK) | SLOT_FILE as u64 | BLACKBOX_IS_FILE) + EPOCH_ONE
            })
        });
        let lost = self.heap.a64(off::CHUNK_CURSOR).load(Ordering::Relaxed) - copied.chunk_cursor;
        file.a32(off::HEAP_CHUNKS_LOST)
            .store(u32::try_from(lost).unwrap_or(u32::MAX), Ordering::Relaxed);
        let _ = self.blackbox_path.set(path.clone());
        Ok(path)
    }

    /// The recording ring, made at the first `trace.start` and never unmapped or cleared.
    fn recording_ring(&self) -> &Ring {
        self.recording.get_or_init(|| {
            let identity = *self.full_identity();
            let layout = RingLayout::of(self.config.recording);
            let path =
                self.config.dir.join(crate::recording_file_name(self.config.role, identity.pid));
            let mapped = map::create_private_dir(&self.config.dir)
                .and_then(|()| map::map_file(&path, layout.total_bytes, self.config.reserve));
            let ring = match mapped {
                Ok(mapping) => {
                    let _ = self.recording_path.set(path);
                    Ring::on_mapping(layout, mapping)
                }
                Err(_) => {
                    self.map_failures.fetch_add(1, Ordering::Relaxed);
                    Ring::on_heap(layout)
                }
            };
            ring.init(&self.header_fields(RingKind::Recording, &identity), self.catalog);
            ring
        })
    }

    /// Maps the recording ring now, so a later [`Tracer::start_recording`] does no disk I/O: its
    /// size in bytes. Blocking: call it off any loop that serves input. Idempotent.
    pub fn prepare_recording(&self) -> u64 {
        self.recording_ring().layout().total_bytes as u64
    }

    /// `trace.start`: the black-box categories plus `categories`, written into the recording
    /// ring. The first start maps the recording file (blocking: call it off the main thread).
    pub fn start_recording(&self, categories: u64) -> Result<Status, TraceError> {
        self.control
            .compare_exchange(IDLE, CHANGING, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| TraceError::AlreadyRecording)?;
        let ring = self.recording_ring();
        let clocks = self.config.clocks;
        ring.begin_recording((clocks.uptime_ns)(), (clocks.unix_ns)(), (clocks.continuous_ns)());
        let _ = self.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |word| {
            Some(((word & !SLOT_MASK) | SLOT_RECORDING as u64 | RECORDING_ON) + EPOCH_ONE)
        });
        self.set_categories(self.config.blackbox_categories | categories);
        self.control.store(RECORDING, Ordering::Release);
        Ok(self.status())
    }

    /// `trace.stop`: back to the black-box categories and the black box. The recording ring keeps
    /// what it holds until the next start.
    pub fn stop(&self) -> Result<Status, TraceError> {
        self.control
            .compare_exchange(RECORDING, CHANGING, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| TraceError::NotRecording)?;
        self.set_categories(self.config.blackbox_categories);
        let _ = self.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |word| {
            let blackbox = if word & BLACKBOX_IS_FILE != 0 { SLOT_FILE } else { SLOT_HEAP };
            Some(((word & !(SLOT_MASK | RECORDING_ON)) | blackbox as u64) + EPOCH_ONE)
        });
        self.control.store(IDLE, Ordering::Release);
        Ok(self.status())
    }

    /// Whether a recording runs now (between a `start_recording` and its `stop`): one load.
    pub fn recording(&self) -> bool {
        self.control.load(Ordering::Relaxed) == RECORDING
    }

    pub fn status(&self) -> Status {
        let active = self.active_ring();
        let recording = self.recording.get();
        Status {
            role: self.config.role,
            categories: self.categories.load(Ordering::Relaxed),
            recording: self.control.load(Ordering::Acquire) == RECORDING,
            blackbox_path: self.blackbox_path.get().cloned(),
            recording_path: self.recording_path.get().cloned(),
            recording_bytes: recording.map_or(0, |ring| ring.layout().total_bytes as u64),
            recording_file_backed: recording.is_some_and(Ring::is_file_backed),
            chunks_overwritten: active.counter(off::CHUNKS_OVERWRITTEN),
            chunks_skipped: active.counter(off::CHUNKS_SKIPPED),
            records_dropped: active.counter(off::RECORDS_DROPPED),
            heap_chunks_lost: self.file.get().map_or(0, |file| file.counter(off::HEAP_CHUNKS_LOST)),
            map_failures: self.map_failures.load(Ordering::Relaxed),
        }
    }

    /// How long the tracer has run, on its start clock: now less the heap ring's
    /// `start_uptime_ns` (written once, when the tracer was made). No allocation or lock.
    pub fn uptime_ns(&self) -> u64 {
        let started = self.heap.a64(off::START_UPTIME_NS).load(Ordering::Relaxed);
        (self.config.clocks.uptime_ns)().saturating_sub(started)
    }

    /// A consistent copy of the active ring, as its file would read. Allocates.
    pub fn snapshot_active(&self) -> Vec<u8> {
        copy::snapshot(self.active_ring())
    }
}

/// One thread writing to a [`Tracer`] it was handed (tests, benches and single-tracer tools; the
/// process-wide trace points keep the same state in a thread-local). Dropping it is the thread's
/// exit: its chunk completes and its entries become free.
pub struct Writer<'a> {
    tracer: &'a Tracer,
    state: WriterState,
}

impl<'a> Writer<'a> {
    pub fn new(tracer: &'a Tracer, identity: ThreadIdentity) -> Writer<'a> {
        Writer { tracer, state: WriterState { identity: Some(identity), ..WriterState::NEW } }
    }

    #[inline]
    pub fn write(&mut self, record: Record) {
        self.tracer.write(&mut self.state, record, None, None);
    }

    /// `record` under `name`'s id in the active ring (`record.name` is ignored).
    #[inline]
    pub fn write_interned(&mut self, name: &InternedName, record: Record) {
        self.tracer.write(&mut self.state, record, Some(name), None);
    }
}

impl Drop for Writer<'_> {
    fn drop(&mut self) {
        self.tracer.exit(&mut self.state);
    }
}
