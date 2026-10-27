//! One ring v1 block: its header, name table, thread table and chunks, and the writer's
//! operations on them (plans/cmux-next/trace.md, "Writing").
//!
//! The model is Perfetto's shared memory buffer (`src/tracing/core/shared_memory_abi.h`): each
//! thread owns one chunk at a time, a chunk that is still owned is skipped and never shared, and a
//! writer drops a record rather than wait when no chunk is free (`BufferExhaustedPolicy::kDrop`,
//! `include/perfetto/tracing/buffer_exhausted_policy.h`). A ring's memory never moves: the heap
//! ring and the file are two rings, and [`crate::Tracer`] swaps which one is active.

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering, fence};

use crate::identity::ThreadIdentity;
use crate::layout::{
    CLAIM_TRIES, CatalogName, ENTRY_PUBLISHED, ENTRY_WRITING, HEADER_BYTES, MAGIC, NAME_TEXT_BYTES,
    NameKind, RECORD_BYTES, RingKind, RingLayout, THREAD_EXITED, THREAD_LIVE, THREAD_NONE, VERSION,
    lap_complete, lap_owned, off, utf8_prefix,
};
use crate::map::{HeapBlock, Mapping};

#[cfg(target_endian = "big")]
compile_error!("ring v1 is little-endian; cmux-trace supports little-endian targets only");

/// One record as a writer passes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record {
    pub t_ns: u64,
    pub name: u16,
    pub phase: crate::Phase,
    pub flags: u8,
    pub arg0: u64,
    pub arg1: u64,
}

/// The header fields a ring's creator writes (the cursors, offsets and counters follow from the
/// layout and start at zero).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HeaderFields {
    pub pid: u32,
    pub role: u16,
    pub kind: RingKind,
    pub clock_domain: u8,
    pub start_uptime_ns: u64,
    pub start_unix_ns: u64,
    pub start_continuous_ns: u64,
    pub process_start_unix_us: u64,
    pub boot_session_uuid: [u8; 16],
    pub build_uuid: [u8; 16],
    pub build_version: [u8; 32],
    pub categories: u64,
}

/// A ring's memory: a zeroed heap block or a shared file mapping. Neither is ever freed while a
/// writer can reach it (the tracer keeps every ring for the process's life).
pub(crate) struct Ring {
    base: *mut u8,
    layout: RingLayout,
    file_backed: bool,
    _heap: Option<HeapBlock>,
}

// SAFETY: the synchronization is the block's atomics. Every shared access to the block is an atomic
// of one fixed width per word (`a32`, `a64`, ordered by the seqlock protocol of trace.md); `bytes`
// reads only a private copy no writer reaches; the block outlives every `&Ring` (the heap block is
// owned and freed in its `Drop`, a mapping is never unmapped). So moving the ring and sharing
// `&Ring` between threads are sound. Test:
// `ring::tests::writers_on_many_threads_share_one_ring_and_it_drops_on_another`
// (Miri lane: `scripts/sanitize.sh --sanitizer miri --crate cmux-trace`).
unsafe impl Send for Ring {}
// SAFETY: as for `Send`; `&Ring` exposes the block only through those atomics. Test: as above.
unsafe impl Sync for Ring {}

impl Ring {
    pub(crate) fn on_heap(layout: RingLayout) -> Ring {
        let heap = HeapBlock::zeroed(layout.total_bytes);
        Ring { base: heap.as_ptr(), layout, file_backed: false, _heap: Some(heap) }
    }

    /// A ring on `mapping`, which holds `layout.total_bytes` zeroed bytes.
    pub(crate) fn on_mapping(layout: RingLayout, mapping: Mapping) -> Ring {
        Ring { base: mapping.as_ptr(), layout, file_backed: true, _heap: None }
    }

    pub(crate) fn layout(&self) -> &RingLayout {
        &self.layout
    }

    pub(crate) fn is_file_backed(&self) -> bool {
        self.file_backed
    }

    /// The block's bytes. Only for a ring no writer can reach (a snapshot's private copy).
    pub(crate) fn bytes(&self) -> &[u8] {
        // SAFETY: `base` holds `total_bytes` initialised bytes for the ring's life, and the caller
        // holds the only reference to a ring that no writer can reach.
        unsafe { std::slice::from_raw_parts(self.base, self.layout.total_bytes) }
    }

    /// The u32 at `offset`.
    #[inline]
    pub(crate) fn a32(&self, offset: usize) -> &AtomicU32 {
        debug_assert!(offset.is_multiple_of(4) && offset + 4 <= self.layout.total_bytes);
        // SAFETY: `base` is this ring's block, `total_bytes` long, page-aligned and alive as long
        // as the ring; `offset` is in bounds and 4-aligned; every access to this word is a u32
        // atomic.
        unsafe { AtomicU32::from_ptr(self.base.add(offset).cast()) }
    }

    /// The u64 at `offset`.
    #[inline]
    pub(crate) fn a64(&self, offset: usize) -> &AtomicU64 {
        debug_assert!(offset.is_multiple_of(8) && offset + 8 <= self.layout.total_bytes);
        // SAFETY: as in `a32`, with an 8-aligned offset and u64 atomics only.
        unsafe { AtomicU64::from_ptr(self.base.add(offset).cast()) }
    }

    fn put_bytes(&self, offset: usize, bytes: &[u8]) {
        for (index, word) in bytes.as_chunks::<8>().0.iter().enumerate() {
            self.a64(offset + 8 * index).store(u64::from_le_bytes(*word), Ordering::Relaxed);
        }
    }

    fn bump32(&self, offset: usize) {
        self.a32(offset).fetch_add(1, Ordering::Relaxed);
    }

    fn bump64(&self, offset: usize) {
        self.a64(offset).fetch_add(1, Ordering::Relaxed);
    }

    /// Writes the header and the catalog while the ring is still private (before any writer can
    /// reach it). `name_cursor` becomes the last catalog id + 1, at least 1.
    pub(crate) fn init(&self, fields: &HeaderFields, catalog: &[CatalogName]) {
        let layout = &self.layout;
        let sizes = layout.sizes;
        let put32 = |at, value: u32| self.a32(at).store(value, Ordering::Relaxed);
        let put64 = |at, value: u64| self.a64(at).store(value, Ordering::Relaxed);
        put64(off::MAGIC, u64::from_le_bytes(MAGIC));
        put32(off::VERSION, VERSION);
        put32(off::HEADER_BYTES, HEADER_BYTES as u32);
        put32(off::PID, fields.pid);
        put32(
            off::ROLE_KIND_CLOCK,
            u32::from(fields.role)
                | u32::from(fields.kind as u8) << 16
                | u32::from(fields.clock_domain) << 24,
        );
        self.put_start_times(
            fields.start_uptime_ns,
            fields.start_unix_ns,
            fields.start_continuous_ns,
        );
        self.put_slow_identity(fields.process_start_unix_us, fields.boot_session_uuid);
        self.put_bytes(off::BUILD_UUID, &fields.build_uuid);
        self.put_bytes(off::BUILD_VERSION, &fields.build_version);
        put32(off::CHUNK_BYTES, crate::layout::CHUNK_BYTES as u32);
        put32(off::CHUNK_COUNT, sizes.chunk_count);
        put64(off::CHUNKS_OFFSET, layout.chunks_offset as u64);
        put64(off::NAME_TABLE_OFFSET, layout.name_table_offset as u64);
        put32(off::NAME_CAPACITY, sizes.name_capacity);
        put64(off::THREAD_TABLE_OFFSET, layout.thread_table_offset as u64);
        put32(off::THREAD_CAPACITY, sizes.thread_capacity);
        put64(off::CATEGORIES, fields.categories);
        let mut cursor = 1u32;
        for name in catalog {
            if u32::from(name.id) == 0 || u32::from(name.id) >= sizes.name_capacity {
                self.bump32(off::NAME_OVERFLOW);
                continue;
            }
            self.write_name(name.id, name.kind, name.category, name.text);
            cursor = cursor.max(u32::from(name.id) + 1);
        }
        put32(off::NAME_CURSOR, cursor);
    }

    pub(crate) fn put_start_times(&self, uptime_ns: u64, unix_ns: u64, continuous_ns: u64) {
        self.a64(off::START_UPTIME_NS).store(uptime_ns, Ordering::Relaxed);
        self.a64(off::START_UNIX_NS).store(unix_ns, Ordering::Relaxed);
        self.a64(off::START_CONTINUOUS_NS).store(continuous_ns, Ordering::Relaxed);
    }

    /// The identity fields read off the hot path (a sysctl or a file): written when the ring
    /// file is made, not at the process's first instruction.
    pub(crate) fn put_slow_identity(&self, process_start_unix_us: u64, boot_session: [u8; 16]) {
        self.a64(off::PROCESS_START_UNIX_US).store(process_start_unix_us, Ordering::Relaxed);
        self.put_bytes(off::BOOT_SESSION_UUID, &boot_session);
    }

    pub(crate) fn set_categories(&self, categories: u64) {
        self.a64(off::CATEGORIES).store(categories, Ordering::Relaxed);
    }

    fn write_name(&self, id: u16, kind: NameKind, category: u8, text: &str) {
        let at = self.layout.name_entry(usize::from(id));
        let state = self.a32(at + off::N_STATE);
        state.store(ENTRY_WRITING, Ordering::Relaxed);
        self.a32(at + off::N_META).store(name_meta(id, kind, category), Ordering::Relaxed);
        self.put_bytes(at + off::N_TEXT, &packed_name(text));
        state.store(ENTRY_PUBLISHED, Ordering::Release);
    }

    /// The id of a published interned entry of `text` in `category`, if the table holds one.
    fn find_interned(&self, text: &str, category: u8) -> Option<u16> {
        let packed = packed_name(text);
        let words = packed.as_chunks::<8>().0;
        let end = self.a32(off::NAME_CURSOR).load(Ordering::Relaxed);
        (1..end.min(self.layout.sizes.name_capacity)).map(|id| id as u16).find(|&id| {
            let at = self.layout.name_entry(usize::from(id));
            self.a32(at + off::N_STATE).load(Ordering::Acquire) == ENTRY_PUBLISHED
                && self.a32(at + off::N_META).load(Ordering::Relaxed)
                    == name_meta(id, NameKind::Interned, category)
                && words.iter().enumerate().all(|(index, word)| {
                    self.a64(at + off::N_TEXT + 8 * index).load(Ordering::Relaxed)
                        == u64::from_le_bytes(*word)
                })
        })
    }

    /// The id of `text` in `category`: the published entry another trace point of the same text
    /// interned, else a new entry claimed and published; 0 (counted in `name_overflow`) when the
    /// table is full. Two trace points that intern the same text at once may both claim an entry,
    /// as two threads of one trace point may (trace.md, "Name table").
    pub(crate) fn intern(&self, text: &str, category: u8) -> u16 {
        if let Some(id) = self.find_interned(text, category) {
            return id;
        }
        let capacity = self.layout.sizes.name_capacity;
        let cursor = self.a32(off::NAME_CURSOR);
        let id = if cursor.load(Ordering::Relaxed) < capacity {
            cursor.fetch_add(1, Ordering::Relaxed)
        } else {
            capacity
        };
        if id >= capacity {
            self.bump32(off::NAME_OVERFLOW);
            return 0;
        }
        self.write_name(id as u16, NameKind::Interned, category, text);
        id as u16
    }

    /// Registers a thread ("Register a thread in a ring"): a fresh entry in index order, else an
    /// exited one taken again with its generation + 1, else [`THREAD_NONE`] and a counted overflow.
    /// Returns (index, generation).
    pub(crate) fn register_thread(&self, identity: &ThreadIdentity) -> (u32, u32) {
        let capacity = self.layout.sizes.thread_capacity;
        let cursor = self.a32(off::THREAD_CURSOR);
        if cursor.load(Ordering::Relaxed) < capacity {
            let index = cursor.fetch_add(1, Ordering::Relaxed);
            if index < capacity {
                let at = self.layout.thread_entry(index as usize);
                self.a32(at + off::T_STATE).store(ENTRY_WRITING, Ordering::Relaxed);
                self.a32(at + off::T_GENERATION).store(0, Ordering::Relaxed);
                self.fill_thread(at, identity);
                return (index, 0);
            }
        }
        for index in 0..capacity {
            let at = self.layout.thread_entry(index as usize);
            let state = self.a32(at + off::T_STATE);
            if state.load(Ordering::Relaxed) == THREAD_EXITED
                && state
                    .compare_exchange(
                        THREAD_EXITED,
                        ENTRY_WRITING,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    )
                    .is_ok()
            {
                let generation_word = self.a32(at + off::T_GENERATION);
                let generation = generation_word.load(Ordering::Relaxed).wrapping_add(1);
                generation_word.store(generation, Ordering::Relaxed);
                self.fill_thread(at, identity);
                return (index, generation);
            }
        }
        self.bump32(off::THREAD_OVERFLOW);
        (THREAD_NONE, 0)
    }

    fn fill_thread(&self, at: usize, identity: &ThreadIdentity) {
        self.a64(at + off::T_TID).store(identity.tid, Ordering::Relaxed);
        self.put_bytes(at + off::T_INFO, &identity.packed());
        self.a32(at + off::T_STATE).store(THREAD_LIVE, Ordering::Release);
    }

    /// Marks entry `index` exited (the thread's TLS destructor), so a later thread may take it.
    pub(crate) fn exit_thread(&self, index: u32) {
        if index < self.layout.sizes.thread_capacity {
            let at = self.layout.thread_entry(index as usize);
            self.a32(at + off::T_STATE).store(THREAD_EXITED, Ordering::Release);
        }
    }

    /// "Claim a chunk": at most [`CLAIM_TRIES`] tries; a chunk that is owned (odd `lap_seq`) or
    /// claimed by a newer lap is skipped, so two writers never share a chunk. Returns (chunk, lap),
    /// or None after counting the dropped record.
    pub(crate) fn claim(&self, thread_index: u32, thread_generation: u32) -> Option<(u32, u64)> {
        let count = u64::from(self.layout.sizes.chunk_count);
        let start_lap = self.a64(off::RECORDING_START_CURSOR).load(Ordering::Acquire) / count;
        let cursor = self.a64(off::CHUNK_CURSOR);
        for _ in 0..CLAIM_TRIES {
            let claim = cursor.fetch_add(1, Ordering::Relaxed);
            let (chunk, lap) = ((claim & (count - 1)) as u32, claim / count);
            let at = self.layout.chunk(chunk as usize);
            let lap_seq = self.a64(at + off::C_LAP_SEQ);
            let seen = lap_seq.load(Ordering::Relaxed);
            if seen & 1 == 1 || seen >= lap_complete(lap) {
                self.bump64(off::CHUNKS_SKIPPED);
                continue;
            }
            if lap_seq
                .compare_exchange(seen, lap_owned(lap), Ordering::AcqRel, Ordering::Relaxed)
                .is_err()
            {
                self.bump64(off::CHUNKS_SKIPPED);
                continue;
            }
            fence(Ordering::Release);
            if seen >= lap_complete(start_lap) {
                self.bump64(off::CHUNKS_OVERWRITTEN);
            }
            self.a32(at + off::C_THREAD).store(thread_index, Ordering::Relaxed);
            self.a32(at + off::C_GENERATION).store(thread_generation, Ordering::Relaxed);
            self.a32(at + off::C_PUBLISHED).store(0, Ordering::Relaxed);
            return Some((chunk, lap));
        }
        self.bump64(off::RECORDS_DROPPED);
        None
    }

    /// "Publish a record" in slot `slot` (1-31) of the owned chunk `chunk` of `lap`.
    #[inline]
    pub(crate) fn publish(&self, chunk: u32, lap: u64, slot: u32, record: &Record) {
        let chunk_at = self.layout.chunk(chunk as usize);
        let at = chunk_at + slot as usize * RECORD_BYTES;
        let writing = lap_owned(lap) as u32;
        let seq = self.a32(at + off::R_SEQ);
        seq.store(writing, Ordering::Relaxed);
        fence(Ordering::Release);
        self.a64(at + off::R_T_NS).store(record.t_ns, Ordering::Relaxed);
        self.a32(at + off::R_META).store(
            u32::from(record.name)
                | u32::from(record.phase as u8) << 16
                | u32::from(record.flags) << 24,
            Ordering::Relaxed,
        );
        self.a64(at + off::R_ARG0).store(record.arg0, Ordering::Relaxed);
        self.a64(at + off::R_ARG1).store(record.arg1, Ordering::Relaxed);
        seq.store(writing.wrapping_add(1), Ordering::Release);
        self.a32(chunk_at + off::C_PUBLISHED).store(slot, Ordering::Release);
    }

    /// "Complete the chunk": only its owner stores to an odd `lap_seq`, so this never overwrites
    /// another owner's claim.
    pub(crate) fn complete(&self, chunk: u32, lap: u64) {
        self.a64(self.layout.chunk(chunk as usize) + off::C_LAP_SEQ)
            .store(lap_complete(lap), Ordering::Release);
    }

    /// "Recording ring", steps 1 and 2 of a `trace.start`: zero the chunk counters, store the new
    /// start times, and move `chunk_cursor` a lap past every claim of an earlier recording.
    pub(crate) fn begin_recording(&self, uptime_ns: u64, unix_ns: u64, continuous_ns: u64) {
        for counter in [off::CHUNKS_SKIPPED, off::RECORDS_DROPPED, off::CHUNKS_OVERWRITTEN] {
            self.a64(counter).store(0, Ordering::Relaxed);
        }
        self.put_start_times(uptime_ns, unix_ns, continuous_ns);
        let count = u64::from(self.layout.sizes.chunk_count);
        let claim = self.a64(off::CHUNK_CURSOR).fetch_add(count, Ordering::Relaxed);
        self.a64(off::RECORDING_START_CURSOR).store(claim + count, Ordering::Release);
    }

    pub(crate) fn counter(&self, offset: usize) -> u64 {
        if matches!(offset, off::NAME_OVERFLOW | off::THREAD_OVERFLOW | off::HEAP_CHUNKS_LOST) {
            u64::from(self.a32(offset).load(Ordering::Relaxed))
        } else {
            self.a64(offset).load(Ordering::Relaxed)
        }
    }
}

/// A name entry's `id`, `kind` and `category` word.
fn name_meta(id: u16, kind: NameKind, category: u8) -> u32 {
    u32::from(id) | u32::from(kind as u8) << 16 | u32::from(category) << 24
}

/// A name entry's `name_len` and text, NUL padded: the seven words at `N_TEXT`.
fn packed_name(text: &str) -> [u8; 1 + NAME_TEXT_BYTES] {
    let text = utf8_prefix(text, NAME_TEXT_BYTES);
    let mut packed = [0u8; 1 + NAME_TEXT_BYTES];
    packed[0] = text.len() as u8;
    packed[1..=text.len()].copy_from_slice(text);
    packed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{RingSizes, lap_of, seq_published};

    fn ring(chunks: u32) -> Ring {
        let ring = Ring::on_heap(RingLayout::of(RingSizes {
            name_capacity: 16,
            thread_capacity: 256,
            chunk_count: chunks,
        }));
        ring.init(
            &HeaderFields {
                pid: 1,
                role: 2,
                kind: RingKind::BlackBox,
                clock_domain: 1,
                start_uptime_ns: 0,
                start_unix_ns: 0,
                start_continuous_ns: 0,
                process_start_unix_us: 0,
                boot_session_uuid: [0; 16],
                build_uuid: [0; 16],
                build_version: [0; 32],
                categories: 0,
            },
            &[],
        );
        ring
    }

    fn lap_seq(ring: &Ring, chunk: u32) -> u64 {
        ring.a64(ring.layout.chunk(chunk as usize) + off::C_LAP_SEQ).load(Ordering::Relaxed)
    }

    /// A writer stopped between its odd and even `seq` stores keeps its chunk while other writers
    /// cycle the ring many times: no claim takes it, so its record is whole when it resumes.
    #[test]
    fn a_writer_stopped_inside_a_record_keeps_its_chunk_through_many_laps() {
        let ring = ring(4);
        let (held, lap) = ring.claim(0, 0).expect("claims");
        let slot_at = ring.layout.chunk(held as usize) + RECORD_BYTES;
        ring.a32(slot_at + off::R_SEQ).store(lap_owned(lap) as u32, Ordering::Relaxed);
        for _ in 0..1000 {
            match ring.claim(1, 0) {
                Some((chunk, other_lap)) => {
                    assert_ne!(chunk, held, "a claim took a chunk another writer owns");
                    ring.complete(chunk, other_lap);
                }
                None => panic!("three free chunks and one claimer: a claim failed"),
            }
        }
        assert_eq!(lap_of(lap_seq(&ring, held)), lap);
        assert!(ring.counter(off::CHUNKS_SKIPPED) >= 250);
        let record =
            Record { t_ns: 5, name: 1, phase: crate::Phase::Instant, flags: 0, arg0: 6, arg1: 7 };
        ring.publish(held, lap, 1, &record);
        assert_eq!(ring.a32(slot_at + off::R_SEQ).load(Ordering::Relaxed), seq_published(lap));
    }

    #[test]
    fn a_claim_drops_the_record_after_four_owned_chunks() {
        let ring = ring(4);
        for thread in 0..4 {
            ring.claim(thread, 0).expect("a free chunk");
        }
        assert_eq!(ring.claim(9, 0), None);
        assert_eq!(ring.counter(off::RECORDS_DROPPED), 1);
        assert_eq!(ring.counter(off::CHUNKS_SKIPPED), 4);
        assert_eq!(ring.counter(off::CHUNKS_OVERWRITTEN), 0);
    }

    #[test]
    fn an_exited_entry_is_taken_again_with_the_next_generation() {
        let ring = ring(4);
        let identity = ThreadIdentity::new(7, 0, "a");
        let mut last = (0, 0);
        for _ in 0..256 {
            last = ring.register_thread(&identity);
        }
        assert_eq!(last, (255, 0));
        assert_eq!(ring.register_thread(&identity), (THREAD_NONE, 0));
        ring.exit_thread(17);
        assert_eq!(ring.register_thread(&identity), (17, 1));
        ring.exit_thread(17);
        assert_eq!(ring.register_thread(&identity), (17, 2));
        assert_eq!(ring.counter(off::THREAD_OVERFLOW), 1);
    }

    /// Two trace points of one text share its entry: an async begin and its end, at two call
    /// sites, pair by name id.
    #[test]
    fn interning_a_text_again_returns_its_entry() {
        let ring = ring(4);
        let first = ring.intern("daemon.url_open", 6);
        assert_ne!(first, 0);
        assert_eq!(ring.intern("daemon.url_open", 6), first, "one text, one id");
        let other = ring.intern("daemon.url_open.slow", 6);
        assert_ne!(other, first);
        assert_ne!(ring.intern("daemon.url_open", 7), first, "the category is part of the name");
        assert_eq!(ring.intern("daemon.url_open.slow", 6), other);
        assert_eq!(ring.a32(off::NAME_CURSOR).load(Ordering::Relaxed), u32::from(other) + 2);
    }

    /// The `Send`/`Sync` argument of [`Ring`] under test: writers on several threads share one
    /// `&Ring` (intern, register, claim, publish, complete, exit) and the ring then drops on
    /// another thread. Under Miri (`scripts/sanitize.sh --sanitizer miri --crate cmux-trace`) a
    /// non-atomic or mixed-width access to the block is a reported data race.
    #[test]
    fn writers_on_many_threads_share_one_ring_and_it_drops_on_another() {
        const WRITERS: u32 = 4;
        const ROUNDS: u64 = 2;
        let ring = ring(16);
        let claims = std::thread::scope(|scope| {
            let workers: Vec<_> = (0..WRITERS)
                .map(|writer| {
                    let ring = &ring;
                    scope.spawn(move || {
                        let identity = ThreadIdentity::new(u64::from(writer), 0, "w");
                        let (index, generation) = ring.register_thread(&identity);
                        let name = ring.intern("shared.name", 1);
                        assert_ne!(name, 0, "the name table has room");
                        let mut claims = Vec::new();
                        for round in 0..ROUNDS {
                            let (chunk, lap) = ring.claim(index, generation).expect("a free chunk");
                            let record = Record {
                                t_ns: round,
                                name,
                                phase: crate::Phase::Instant,
                                flags: 0,
                                arg0: u64::from(writer),
                                arg1: round,
                            };
                            ring.publish(chunk, lap, 1, &record);
                            ring.complete(chunk, lap);
                            claims.push((writer, round, chunk, lap));
                        }
                        ring.exit_thread(index);
                        claims
                    })
                })
                .collect();
            workers
                .into_iter()
                .flat_map(|worker| worker.join().expect("writer thread"))
                .collect::<Vec<_>>()
        });
        assert_eq!(claims.len() as u64, u64::from(WRITERS) * ROUNDS);
        assert_eq!(ring.counter(off::RECORDS_DROPPED), 0);
        for (writer, round, chunk, lap) in claims {
            let slot = ring.layout.chunk(chunk as usize) + RECORD_BYTES;
            assert_eq!(ring.a32(slot + off::R_SEQ).load(Ordering::Acquire), seq_published(lap));
            assert_eq!(ring.a64(slot + off::R_ARG0).load(Ordering::Relaxed), u64::from(writer));
            assert_eq!(ring.a64(slot + off::R_ARG1).load(Ordering::Relaxed), round);
        }
        std::thread::spawn(move || drop(ring)).join().expect("drop thread");
    }
}
