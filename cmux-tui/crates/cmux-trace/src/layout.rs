//! Ring v1 constants, byte offsets and region placement. The tables are in plans/cmux-next/trace.md,
//! "Release trace ring v1"; every number here is one of them.

/// ASCII `CMXTRACE` (header offset 0).
pub const MAGIC: [u8; 8] = *b"CMXTRACE";
/// The ring format version (header offset 8).
pub const VERSION: u32 = 1;
/// Bytes in the header.
pub const HEADER_BYTES: usize = 256;
/// Region alignment: the chunks start on this boundary, and so (in this writer) does every table.
pub const PAGE_BYTES: usize = 16384;
/// Bytes in one name-table entry.
pub const NAME_ENTRY_BYTES: usize = 64;
/// The longest name text an entry keeps.
pub const NAME_TEXT_BYTES: usize = 55;
/// Bytes in one thread-table entry.
pub const THREAD_ENTRY_BYTES: usize = 64;
/// The longest thread name an entry keeps.
pub const THREAD_NAME_BYTES: usize = 46;
/// Bytes in one chunk: a 32-byte chunk header in slot 0, then 31 records.
pub const CHUNK_BYTES: usize = 1024;
/// Bytes in one record.
pub const RECORD_BYTES: usize = 32;
/// Records in one chunk (slots 1-31).
pub const RECORDS_PER_CHUNK: u32 = 31;
/// Claim tries before a record is dropped ("Claim a chunk").
pub const CLAIM_TRIES: u32 = 4;
/// The thread index of a chunk whose owner found the thread table full.
pub const THREAD_NONE: u32 = 0xFFFF_FFFF;
/// The most name entries a ring has (a name id is a u16).
pub const MAX_NAME_CAPACITY: u32 = 65536;
/// Thread entries come in whole 16 KiB pages.
pub const THREAD_CAPACITY_STEP: u32 = (PAGE_BYTES / THREAD_ENTRY_BYTES) as u32;
/// The most chunks a ring has (1 GiB of chunks, 32x the largest role's recording).
pub const MAX_CHUNKS: u32 = 1 << 20;
/// The most thread entries a ring has.
pub const MAX_THREAD_CAPACITY: u32 = 1 << 16;

/// Byte offsets inside the header and the entries.
pub(crate) mod off {
    pub const MAGIC: usize = 0;
    pub const VERSION: usize = 8;
    pub const HEADER_BYTES: usize = 12;
    pub const PID: usize = 16;
    /// `role` u16 at 20, `ring_kind` u8 at 22, `clock_domain` u8 at 23: one u32 word.
    pub const ROLE_KIND_CLOCK: usize = 20;
    pub const START_UPTIME_NS: usize = 24;
    pub const START_UNIX_NS: usize = 32;
    pub const PROCESS_START_UNIX_US: usize = 40;
    pub const BOOT_SESSION_UUID: usize = 48;
    pub const BUILD_UUID: usize = 64;
    pub const BUILD_VERSION: usize = 80;
    pub const CHUNK_BYTES: usize = 112;
    pub const CHUNK_COUNT: usize = 116;
    pub const CHUNKS_OFFSET: usize = 120;
    pub const CHUNK_CURSOR: usize = 128;
    pub const NAME_TABLE_OFFSET: usize = 136;
    pub const NAME_CAPACITY: usize = 144;
    pub const NAME_CURSOR: usize = 148;
    pub const THREAD_TABLE_OFFSET: usize = 152;
    pub const THREAD_CAPACITY: usize = 160;
    pub const THREAD_CURSOR: usize = 164;
    pub const CATEGORIES: usize = 168;
    pub const CHUNKS_SKIPPED: usize = 176;
    pub const RECORDS_DROPPED: usize = 184;
    pub const NAME_OVERFLOW: usize = 192;
    pub const THREAD_OVERFLOW: usize = 196;
    pub const HEAP_CURSOR: usize = 200;
    pub const START_CONTINUOUS_NS: usize = 208;
    pub const CHUNKS_OVERWRITTEN: usize = 216;
    pub const RECORDING_START_CURSOR: usize = 224;
    pub const HEAP_CHUNKS_LOST: usize = 232;

    // Name entry.
    pub const N_STATE: usize = 0;
    /// `id` u16 at 4, `kind` u8 at 6, `category` u8 at 7: one u32 word.
    pub const N_META: usize = 4;
    /// `name_len` u8 at 8, then the text at 9: seven u64 words.
    pub const N_TEXT: usize = 8;

    // Thread entry.
    pub const T_STATE: usize = 0;
    pub const T_GENERATION: usize = 4;
    pub const T_TID: usize = 8;
    /// `qos` u8 at 16, `name_len` u8 at 17, the name at 18: six u64 words.
    pub const T_INFO: usize = 16;

    // Chunk header.
    pub const C_THREAD: usize = 0;
    pub const C_GENERATION: usize = 4;
    pub const C_LAP_SEQ: usize = 8;
    pub const C_PUBLISHED: usize = 16;

    // Record.
    pub const R_T_NS: usize = 0;
    pub const R_SEQ: usize = 8;
    /// `name` u16 at 12, `phase` u8 at 14, `flags` u8 at 15: one u32 word.
    pub const R_META: usize = 12;
    pub const R_ARG0: usize = 16;
    pub const R_ARG1: usize = 24;
}

/// The 8-byte header words that hold two u32 fields (every other word is one u64), so a copy
/// reads each field at the width its writer stores it.
pub(crate) const HEADER_U32_PAIRS: [usize; 7] = [
    off::VERSION,
    off::PID,
    off::CHUNK_BYTES,
    off::NAME_CAPACITY,
    off::THREAD_CAPACITY,
    off::NAME_OVERFLOW,
    off::HEAP_CHUNKS_LOST,
];

/// Name entry states.
pub(crate) const ENTRY_WRITING: u32 = 1;
pub(crate) const ENTRY_PUBLISHED: u32 = 2;
/// Thread entry states (2 live, 3 exited; 1 being written, as for names).
pub(crate) const THREAD_LIVE: u32 = 2;
pub(crate) const THREAD_EXITED: u32 = 3;

/// A record's phase (record byte 14): Chrome's `TRACE_EVENT_PHASE_*` codes
/// (`base/trace_event/common/trace_event_common.h`).
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// `B`: a slice begins on the writing thread.
    Begin = b'B',
    /// `E`: the slice of the same name ends on the same thread.
    End = b'E',
    /// `I`: an instant.
    Instant = b'I',
    /// `b`: an async slice begins; arg1 is its id ([`FLAG_ID`]).
    AsyncBegin = b'b',
    /// `e`: the async slice with id arg1 ends, on any thread.
    AsyncEnd = b'e',
    /// `s`: a flow leaves; arg1 is the flow id.
    FlowOut = b's',
    /// `f`: a flow arrives; arg1 is the flow id.
    FlowIn = b'f',
    /// `C`: a counter sample; arg0 is the value, arg1 a track id ([`FLAG_ID`]).
    Counter = b'C',
}

impl Phase {
    /// The phase stored as `raw`, if it is one (0 is invalid).
    pub fn from_raw(raw: u8) -> Option<Phase> {
        Some(match raw {
            b'B' => Phase::Begin,
            b'E' => Phase::End,
            b'I' => Phase::Instant,
            b'b' => Phase::AsyncBegin,
            b'e' => Phase::AsyncEnd,
            b's' => Phase::FlowOut,
            b'f' => Phase::FlowIn,
            b'C' => Phase::Counter,
            _ => return None,
        })
    }
}

/// Record flag bit 0: arg1 is an async id (required on `b` and `e`) or a track id.
pub const FLAG_ID: u8 = 1 << 0;
/// Record flag bit 1: `t_ns` is an estimate (for example `frame.present_estimate`).
pub const FLAG_ESTIMATE: u8 = 1 << 1;

/// Which ring of a process this is (header byte 22).
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RingKind {
    BlackBox = 1,
    Recording = 2,
}

/// What a name-table entry names (entry byte 6).
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameKind {
    /// A fixed catalog name (`SignpostName` ids, append-only, from 1).
    Catalog = 1,
    /// A name interned at run time ([`crate::InternedName`]).
    Interned = 2,
    /// A category; its `category` byte is its own bit.
    Category = 3,
}

impl NameKind {
    pub fn from_raw(raw: u8) -> Option<NameKind> {
        match raw {
            1 => Some(NameKind::Catalog),
            2 => Some(NameKind::Interned),
            3 => Some(NameKind::Category),
            _ => None,
        }
    }
}

/// One fixed name a ring's creator writes before the ring becomes active, so its id is the same in
/// every ring of the process and needs no lookup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CatalogName {
    /// The entry index, from 1.
    pub id: u16,
    /// [`NameKind::Catalog`] or [`NameKind::Category`].
    pub kind: NameKind,
    /// The category's bit index in `categories`.
    pub category: u8,
    /// UTF-8; cut at 55 bytes on a character boundary.
    pub text: &'static str,
}

/// A ring's table capacities and chunk count ("Sizes by role").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RingSizes {
    pub name_capacity: u32,
    pub thread_capacity: u32,
    pub chunk_count: u32,
}

impl RingSizes {
    /// The sizes the format allows nearest to these: a power-of-two chunk count, whole pages of
    /// thread entries and at most 65536 names.
    pub fn normalized(self) -> RingSizes {
        RingSizes {
            name_capacity: self.name_capacity.clamp(1, MAX_NAME_CAPACITY),
            thread_capacity: self
                .thread_capacity
                .clamp(1, MAX_THREAD_CAPACITY)
                .next_multiple_of(THREAD_CAPACITY_STEP),
            chunk_count: self.chunk_count.clamp(1, MAX_CHUNKS).next_power_of_two(),
        }
    }

    /// Records the chunks hold.
    pub fn records(self) -> usize {
        self.chunk_count as usize * RECORDS_PER_CHUNK as usize
    }
}

/// Where each region of a ring sits. The header gives each offset, so a decoder never computes
/// one; this writer starts every region on a 16 KiB page: the header page, the name table, the
/// thread table, then the chunks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RingLayout {
    pub sizes: RingSizes,
    pub name_table_offset: usize,
    pub thread_table_offset: usize,
    pub chunks_offset: usize,
    pub total_bytes: usize,
}

impl RingLayout {
    pub fn of(sizes: RingSizes) -> RingLayout {
        let sizes = sizes.normalized();
        let name_table_offset = PAGE_BYTES;
        let thread_table_offset = name_table_offset
            + (sizes.name_capacity as usize * NAME_ENTRY_BYTES).next_multiple_of(PAGE_BYTES);
        let chunks_offset = thread_table_offset
            + (sizes.thread_capacity as usize * THREAD_ENTRY_BYTES).next_multiple_of(PAGE_BYTES);
        RingLayout {
            sizes,
            name_table_offset,
            thread_table_offset,
            chunks_offset,
            total_bytes: chunks_offset + sizes.chunk_count as usize * CHUNK_BYTES,
        }
    }

    pub(crate) fn name_entry(&self, index: usize) -> usize {
        self.name_table_offset + index * NAME_ENTRY_BYTES
    }

    pub(crate) fn thread_entry(&self, index: usize) -> usize {
        self.thread_table_offset + index * THREAD_ENTRY_BYTES
    }

    pub(crate) fn chunk(&self, index: usize) -> usize {
        self.chunks_offset + index * CHUNK_BYTES
    }
}

/// `lap_seq` while a chunk of `lap` is owned and filling.
#[inline]
pub(crate) fn lap_owned(lap: u64) -> u64 {
    2 * lap + 1
}

/// `lap_seq` of a complete chunk of `lap`.
#[inline]
pub(crate) fn lap_complete(lap: u64) -> u64 {
    2 * lap + 2
}

/// The lap a nonzero `lap_seq` names.
#[inline]
pub(crate) fn lap_of(lap_seq: u64) -> u64 {
    (lap_seq - 1) / 2
}

/// A record's published `seq` in a chunk of `lap` (low 32 bits of `2*lap+2`).
#[inline]
pub(crate) fn seq_published(lap: u64) -> u32 {
    lap_complete(lap) as u32
}

/// The longest prefix of `text` of at most `max` bytes that ends on a character boundary.
pub(crate) fn utf8_prefix(text: &str, max: usize) -> &[u8] {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text.as_bytes()[..end]
}
