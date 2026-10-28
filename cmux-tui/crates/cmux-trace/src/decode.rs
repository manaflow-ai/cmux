//! Decoding a ring file or snapshot ("Decode a chunk"). Bad bytes are errors, never panics.

use crate::layout::{
    CHUNK_BYTES, ENTRY_PUBLISHED, HEADER_BYTES, MAGIC, MAX_NAME_CAPACITY, NAME_ENTRY_BYTES,
    NAME_TEXT_BYTES, PAGE_BYTES, RECORD_BYTES, RECORDS_PER_CHUNK, THREAD_ENTRY_BYTES,
    THREAD_EXITED, THREAD_LIVE, THREAD_NAME_BYTES, VERSION, lap_of, off, seq_published,
};

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

/// Every header field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub version: u32,
    pub pid: u32,
    pub role: u16,
    pub ring_kind: u8,
    pub clock_domain: u8,
    pub start_uptime_ns: u64,
    pub start_unix_ns: u64,
    pub process_start_unix_us: u64,
    pub boot_session_uuid: [u8; 16],
    pub build_uuid: [u8; 16],
    pub build_version: [u8; 32],
    pub chunk_count: u32,
    pub chunks_offset: u64,
    pub chunk_cursor: u64,
    pub name_table_offset: u64,
    pub name_capacity: u32,
    pub name_cursor: u32,
    pub thread_table_offset: u64,
    pub thread_capacity: u32,
    pub thread_cursor: u32,
    pub categories: u64,
    pub chunks_skipped: u64,
    pub records_dropped: u64,
    pub name_overflow: u32,
    pub thread_overflow: u32,
    pub heap_cursor: u64,
    pub start_continuous_ns: u64,
    pub chunks_overwritten: u64,
    pub recording_start_cursor: u64,
    pub heap_chunks_lost: u32,
}

impl Header {
    /// The first lap of this ring's current recording (0 for a black box).
    pub fn start_lap(&self) -> u64 {
        self.recording_start_cursor / u64::from(self.chunk_count)
    }
}

/// A published name-table entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NameEntry {
    pub id: u16,
    pub kind: u8,
    pub category: u8,
    pub text: String,
}

/// A live or exited thread-table entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadEntry {
    pub index: u32,
    /// 2 live, 3 exited.
    pub state: u32,
    pub generation: u32,
    pub tid: u64,
    pub qos: u8,
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
    pub names: Vec<NameEntry>,
    pub threads: Vec<ThreadEntry>,
    pub records: Vec<DecodedRecord>,
}

impl Decoded {
    /// The text of name `id` in this ring.
    pub fn name(&self, id: u16) -> Option<&str> {
        self.names.iter().find(|entry| entry.id == id).map(|entry| entry.text.as_str())
    }

    /// The thread that wrote `record`: its entry when the generations match. None for a chunk of
    /// an earlier occupant of the entry (`thread <index> (generation <g>)`) or of a thread that
    /// found the table full.
    pub fn thread_of(&self, record: &DecodedRecord) -> Option<&ThreadEntry> {
        self.threads.iter().find(|thread| {
            thread.index == record.thread_index && thread.generation == record.thread_generation
        })
    }
}

fn u32_at(bytes: &[u8], at: usize) -> Result<u32, DecodeError> {
    let word = bytes.get(at..).and_then(<[u8]>::first_chunk).ok_or(DecodeError::Truncated)?;
    Ok(u32::from_le_bytes(*word))
}

fn u64_at(bytes: &[u8], at: usize) -> Result<u64, DecodeError> {
    let word = bytes.get(at..).and_then(<[u8]>::first_chunk).ok_or(DecodeError::Truncated)?;
    Ok(u64::from_le_bytes(*word))
}

fn array_at<const N: usize>(bytes: &[u8], at: usize) -> Result<[u8; N], DecodeError> {
    bytes.get(at..).and_then(<[u8]>::first_chunk).copied().ok_or(DecodeError::Truncated)
}

fn text_at(bytes: &[u8], at: usize, len: usize) -> Result<String, DecodeError> {
    let text = bytes.get(at..at + len).ok_or(DecodeError::Truncated)?;
    Ok(String::from_utf8_lossy(text).into_owned())
}

fn header(bytes: &[u8]) -> Result<Header, DecodeError> {
    if bytes.get(..8).ok_or(DecodeError::Truncated)? != MAGIC {
        return Err(DecodeError::BadMagic);
    }
    let version = u32_at(bytes, off::VERSION)?;
    if version != VERSION {
        return Err(DecodeError::UnsupportedVersion(version));
    }
    if u32_at(bytes, off::HEADER_BYTES)? as usize != HEADER_BYTES
        || u32_at(bytes, off::CHUNK_BYTES)? as usize != CHUNK_BYTES
    {
        return Err(DecodeError::BadLayout("header or chunk size"));
    }
    let role_kind_clock = u32_at(bytes, off::ROLE_KIND_CLOCK)?;
    Ok(Header {
        version,
        pid: u32_at(bytes, off::PID)?,
        role: role_kind_clock as u16,
        ring_kind: (role_kind_clock >> 16) as u8,
        clock_domain: (role_kind_clock >> 24) as u8,
        start_uptime_ns: u64_at(bytes, off::START_UPTIME_NS)?,
        start_unix_ns: u64_at(bytes, off::START_UNIX_NS)?,
        process_start_unix_us: u64_at(bytes, off::PROCESS_START_UNIX_US)?,
        boot_session_uuid: array_at(bytes, off::BOOT_SESSION_UUID)?,
        build_uuid: array_at(bytes, off::BUILD_UUID)?,
        build_version: array_at(bytes, off::BUILD_VERSION)?,
        chunk_count: u32_at(bytes, off::CHUNK_COUNT)?,
        chunks_offset: u64_at(bytes, off::CHUNKS_OFFSET)?,
        chunk_cursor: u64_at(bytes, off::CHUNK_CURSOR)?,
        name_table_offset: u64_at(bytes, off::NAME_TABLE_OFFSET)?,
        name_capacity: u32_at(bytes, off::NAME_CAPACITY)?,
        name_cursor: u32_at(bytes, off::NAME_CURSOR)?,
        thread_table_offset: u64_at(bytes, off::THREAD_TABLE_OFFSET)?,
        thread_capacity: u32_at(bytes, off::THREAD_CAPACITY)?,
        thread_cursor: u32_at(bytes, off::THREAD_CURSOR)?,
        categories: u64_at(bytes, off::CATEGORIES)?,
        chunks_skipped: u64_at(bytes, off::CHUNKS_SKIPPED)?,
        records_dropped: u64_at(bytes, off::RECORDS_DROPPED)?,
        name_overflow: u32_at(bytes, off::NAME_OVERFLOW)?,
        thread_overflow: u32_at(bytes, off::THREAD_OVERFLOW)?,
        heap_cursor: u64_at(bytes, off::HEAP_CURSOR)?,
        start_continuous_ns: u64_at(bytes, off::START_CONTINUOUS_NS)?,
        chunks_overwritten: u64_at(bytes, off::CHUNKS_OVERWRITTEN)?,
        recording_start_cursor: u64_at(bytes, off::RECORDING_START_CURSOR)?,
        heap_chunks_lost: u32_at(bytes, off::HEAP_CHUNKS_LOST)?,
    })
}

/// The end of a region of `count` entries of `size` bytes at `offset`, if it fits in `len`.
fn region_end(offset: u64, count: u32, size: usize, len: usize) -> Result<usize, DecodeError> {
    let end = usize::try_from(offset)
        .ok()
        .and_then(|offset| offset.checked_add(count as usize * size))
        .ok_or(DecodeError::BadLayout("region offset"))?;
    if offset < HEADER_BYTES as u64 {
        return Err(DecodeError::BadLayout("a region overlaps the header"));
    }
    if end > len {
        return Err(DecodeError::Truncated);
    }
    Ok(end)
}

fn check_layout(header: &Header, len: usize) -> Result<(), DecodeError> {
    if header.chunk_count == 0 || !header.chunk_count.is_power_of_two() {
        return Err(DecodeError::BadLayout("chunk_count is not a power of two"));
    }
    if !header.chunks_offset.is_multiple_of(PAGE_BYTES as u64) {
        return Err(DecodeError::BadLayout("chunks_offset is not on a 16 KiB boundary"));
    }
    if header.name_capacity > MAX_NAME_CAPACITY {
        return Err(DecodeError::BadLayout("name_capacity is over 65536"));
    }
    region_end(header.name_table_offset, header.name_capacity, NAME_ENTRY_BYTES, len)?;
    region_end(header.thread_table_offset, header.thread_capacity, THREAD_ENTRY_BYTES, len)?;
    region_end(header.chunks_offset, header.chunk_count, CHUNK_BYTES, len)?;
    Ok(())
}

fn names(bytes: &[u8], header: &Header) -> Result<Vec<NameEntry>, DecodeError> {
    let mut out = Vec::new();
    for index in 1..header.name_cursor.min(header.name_capacity) as usize {
        let at = header.name_table_offset as usize + index * NAME_ENTRY_BYTES;
        if u32_at(bytes, at + off::N_STATE)? != ENTRY_PUBLISHED {
            continue;
        }
        let meta = u32_at(bytes, at + off::N_META)?;
        let len = usize::from(bytes[at + off::N_TEXT]).min(NAME_TEXT_BYTES);
        out.push(NameEntry {
            id: meta as u16,
            kind: (meta >> 16) as u8,
            category: (meta >> 24) as u8,
            text: text_at(bytes, at + off::N_TEXT + 1, len)?,
        });
    }
    Ok(out)
}

fn threads(bytes: &[u8], header: &Header) -> Result<Vec<ThreadEntry>, DecodeError> {
    let mut out = Vec::new();
    for index in 0..header.thread_cursor.min(header.thread_capacity) {
        let at = header.thread_table_offset as usize + index as usize * THREAD_ENTRY_BYTES;
        let state = u32_at(bytes, at + off::T_STATE)?;
        if state != THREAD_LIVE && state != THREAD_EXITED {
            continue;
        }
        let len = usize::from(bytes[at + off::T_INFO + 1]).min(THREAD_NAME_BYTES);
        out.push(ThreadEntry {
            index,
            state,
            generation: u32_at(bytes, at + off::T_GENERATION)?,
            tid: u64_at(bytes, at + off::T_TID)?,
            qos: bytes[at + off::T_INFO],
            name: text_at(bytes, at + off::T_INFO + 2, len)?,
        });
    }
    Ok(out)
}

fn chunk_records(
    bytes: &[u8],
    header: &Header,
    chunk: u32,
    out: &mut Vec<DecodedRecord>,
) -> Result<(), DecodeError> {
    let at = header.chunks_offset as usize + chunk as usize * CHUNK_BYTES;
    let lap_seq = u64_at(bytes, at + off::C_LAP_SEQ)?;
    if lap_seq == 0 || lap_of(lap_seq) < header.start_lap() {
        return Ok(());
    }
    let lap = lap_of(lap_seq);
    let published = seq_published(lap);
    let thread_index = u32_at(bytes, at + off::C_THREAD)?;
    let thread_generation = u32_at(bytes, at + off::C_GENERATION)?;
    for slot in 1..=RECORDS_PER_CHUNK as usize {
        let record = at + slot * RECORD_BYTES;
        let t_ns = u64_at(bytes, record + off::R_T_NS)?;
        if u32_at(bytes, record + off::R_SEQ)? != published || t_ns < header.start_uptime_ns {
            continue;
        }
        let meta = u32_at(bytes, record + off::R_META)?;
        out.push(DecodedRecord {
            position: lap * u64::from(header.chunk_count) + u64::from(chunk),
            slot: slot as u8,
            thread_index,
            thread_generation,
            t_ns,
            name: meta as u16,
            phase: (meta >> 16) as u8,
            flags: (meta >> 24) as u8,
            arg0: u64_at(bytes, record + off::R_ARG0)?,
            arg1: u64_at(bytes, record + off::R_ARG1)?,
        });
    }
    Ok(())
}

/// Decodes a ring file (or a snapshot). Keeps only records whose `seq` is the published `seq` of
/// their chunk's lap, of this recording (lap and time), so a torn, overwritten or earlier
/// recording's record never appears.
pub fn decode(bytes: &[u8]) -> Result<Decoded, DecodeError> {
    let header = header(bytes)?;
    check_layout(&header, bytes.len())?;
    let names = names(bytes, &header)?;
    let threads = threads(bytes, &header)?;
    let mut records = Vec::new();
    for chunk in 0..header.chunk_count {
        chunk_records(bytes, &header, chunk, &mut records)?;
    }
    records.sort_by_key(|record| (record.t_ns, record.position, record.slot));
    Ok(Decoded { header, names, threads, records })
}
