//! Field histograms of a Rust process in a crash-safe `MAP_SHARED` file, with the layout of the app's
//! CmuxNextMetrics (plans/cmux-next/chrome-parity/p09-observability.md section 3D, tasks 052 and 131).
//!
//! Chrome's model: a child process records its histograms into persistent memory
//! (`base::PersistentHistogramAllocator` over a mapped file, base/metrics/persistent_histogram_allocator.h), and
//! the browser reads that memory, also after the child crashed (components/metrics/file_metrics_provider.cc).
//! Here the daemon, the holder and acpmux each write `metrics-<role>-<pid>.bin`; the app maps it (task 062), and
//! the daemon's own `server-stats` reads the same counters.
//!
//! - [`MetricsStore::new`]: the counters start on the heap, no file work.
//! - [`MetricsStore::record`]: three relaxed adds (bucket, count, sum) into the active block; no lock,
//!   allocation or system call.
//! - [`MetricsStore::adopt_file`] (blocking, never on a latency path; [`MetricsStore::open_in_background`] runs
//!   it on its own thread): maps the file, writes the header and directory, swaps the writers to it and adds
//!   the heap's counters into it. A record whose writer read the heap address before the swap and adds after
//!   the heap was read is lost, as in the Swift store. The mapping is never unmapped (`map.rs`).
//! - [`MetricsFile`]: maps any metrics file (one a dead process left), validates it and reads its delta
//!   (current minus the logged shadow); [`MetricsFile::fold`] adds the delta to the shadow, so a second fold of
//!   the same file reads nothing.
//!
//! File layout (little-endian; Swift's `MetricsStore` "File layout" doc is the same table, and
//! `tests/fixtures/metrics-file-golden.txt` pins both):
//!
//! | Offset | Field |
//! | --- | --- |
//! | 0 | magic `CMXMETRC` (8 bytes) |
//! | 8 | version u32 (1) |
//! | 12 | directory offset u32 (1024) |
//! | 16 | histogram count u32 |
//! | 20 | role u16 ([`Role`]) |
//! | 22 | sub-buckets per power of two, as a shift, u16 (2) |
//! | 24 | pid u32 |
//! | 28 | directory entry bytes u32 (88) |
//! | 32 | start uptime ns u64 ([`crate::clock`]) |
//! | 40 | start wall clock ns since 1970 u64 |
//! | 48 | file bytes u64 |
//! | 56 | first block offset u64 |
//! | 64 | profile: boot session (16), build UUID (16), build day u32 `yyyymmdd` at 96, then five 64-byte NUL-padded texts at 104: version, build, channel, OS version, hardware class |
//!
//! A directory entry (88 bytes): name (64 bytes, NUL padded), kind u32 (1 log-linear, 2 linear, 3 enumeration),
//! bucket count u32 (overflow included), maximum or value count i64, block offset u64. A block (64-byte aligned)
//! is u64 words: count, sum, the buckets, then the logged count, sum and buckets. The file is a multiple of
//! 4096 bytes.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicPtr, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use crate::Role;
use crate::map::{HeapBlock, create_private_dir, map_file, reserve_blocks};

/// The file's first 8 bytes.
pub const MAGIC: [u8; 8] = *b"CMXMETRC";
/// The layout version.
pub const VERSION: u32 = 1;
/// The directory's byte offset.
pub const DIRECTORY_OFFSET: usize = 1024;
/// One directory entry's bytes.
pub const ENTRY_BYTES: usize = 88;
/// A name's bytes in an entry.
pub const NAME_BYTES: usize = 64;
/// The UTF-8 bytes a profile text keeps (a 64-byte slot, NUL padded).
pub const TEXT_BYTES: usize = 63;
/// Log-linear sub-buckets per power of two, as a shift (Swift's `logLinearSubBucketsLog2`).
const SUB_BUCKETS_LOG2: u16 = 2;
/// The alignment of each histogram's block (a cache line).
const BLOCK_ALIGN: usize = 64;
/// The file's size is a multiple of this.
const FILE_ALIGN: usize = 4096;

/// The header offsets of the profile.
mod profile_at {
    pub(super) const BOOT_SESSION: usize = 64;
    pub(super) const BUILD_UUID: usize = 80;
    pub(super) const BUILD_DAY: usize = 96;
    pub(super) const APP_VERSION: usize = 104;
    pub(super) const BUILD_NUMBER: usize = 168;
    pub(super) const CHANNEL: usize = 232;
    pub(super) const OS_VERSION: usize = 296;
    pub(super) const HARDWARE_CLASS: usize = 360;
}

/// The log-linear bucket of `value`: 0 to 3 take buckets 0 to 3, then a value whose highest bit is `o` takes
/// `o * 4` plus its next two bits, so buckets 4 to 7 are never used (the golden
/// `tests/fixtures/metrics-log-linear-golden.txt`, shared with Swift and cmux-tui-core's daemon histograms).
#[inline(always)]
pub fn log_linear_index(value: u64) -> usize {
    if value < 4 {
        return value as usize;
    }
    let octave = 63 - value.leading_zeros();
    octave as usize * 4 + ((value >> (octave - u32::from(SUB_BUCKETS_LOG2))) & 3) as usize
}

/// The largest value in log-linear bucket `index` (`index` from a value; at most 255). The top bucket ends at
/// `u64::MAX`: (2^o - 1) + (sub + 1) * 2^(o-2) never overflows.
pub fn log_linear_upper_bound(index: usize) -> u64 {
    if index < 4 {
        return index as u64;
    }
    if index >= 256 {
        return u64::MAX;
    }
    let octave = (index / 4) as u32;
    let sub = (index % 4) as u64;
    ((1u64 << octave) - 1) + (sub + 1) * (1u64 << (octave - u32::from(SUB_BUCKETS_LOG2)))
}

/// A histogram's bucket layout (Swift's `HistogramID.Layout`, Chromium's own layout aside).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    /// Four buckets per power of two from 0 to `maximum`, then the overflow bucket.
    LogLinear { maximum: i64 },
    /// One bucket per value from 0 to `maximum`, then the overflow bucket.
    Linear { maximum: i64 },
    /// One bucket per value below `values`, then the overflow bucket.
    Enumeration { values: u32 },
}

impl Layout {
    /// The directory's kind word.
    fn kind(self) -> u32 {
        match self {
            Layout::LogLinear { .. } => 1,
            Layout::Linear { .. } => 2,
            Layout::Enumeration { .. } => 3,
        }
    }

    /// The directory's maximum or value count.
    fn limit(self) -> i64 {
        match self {
            Layout::LogLinear { maximum } | Layout::Linear { maximum } => maximum,
            Layout::Enumeration { values } => i64::from(values),
        }
    }

    /// The layout of a directory entry's kind and limit.
    fn from_directory(kind: u32, limit: i64) -> Option<Layout> {
        Some(match kind {
            1 => Layout::LogLinear { maximum: limit },
            2 => Layout::Linear { maximum: limit },
            3 => Layout::Enumeration { values: u32::try_from(limit).ok()? },
            _ => return None,
        })
    }

    /// The buckets, the overflow bucket included.
    pub fn bucket_count(self) -> usize {
        match self {
            Layout::LogLinear { maximum } => log_linear_index(maximum.max(0) as u64) + 2,
            Layout::Linear { maximum } => maximum.max(0) as usize + 2,
            Layout::Enumeration { values } => values as usize + 1,
        }
    }

    /// The bucket `sample` counts in: below 0 counts as 0 and above the maximum in the overflow bucket; an
    /// enumeration value outside the list counts in the overflow bucket (Chrome's `UMA_HISTOGRAM_ENUMERATION`).
    #[inline(always)]
    pub fn bucket_index(self, sample: i64) -> usize {
        match self {
            Layout::LogLinear { maximum } if sample > maximum => self.bucket_count() - 1,
            Layout::LogLinear { .. } => log_linear_index(sample.max(0) as u64),
            Layout::Linear { maximum } if sample > maximum => self.bucket_count() - 1,
            Layout::Linear { .. } => sample.max(0) as usize,
            Layout::Enumeration { values } => {
                if sample >= 0 && sample < i64::from(values) {
                    sample as usize
                } else {
                    values as usize
                }
            }
        }
    }

    /// The largest sample bucket `index` holds; None for the overflow bucket (no bound) and outside the layout.
    pub fn bucket_upper_bound(self, index: usize) -> Option<u64> {
        if index + 1 >= self.bucket_count() {
            return None;
        }
        Some(match self {
            Layout::LogLinear { maximum } => {
                log_linear_upper_bound(index).min(maximum.max(0) as u64)
            }
            Layout::Linear { .. } | Layout::Enumeration { .. } => index as u64,
        })
    }

    /// The bytes of a block: count, sum and buckets, twice (current, logged).
    fn block_bytes(self) -> usize {
        2 * (2 + self.bucket_count()) * 8
    }
}

/// One histogram of a process's catalog: its catalog name (Swift's `HistogramID.name`) and layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HistogramSpec {
    pub name: &'static str,
    pub layout: Layout,
}

/// The system profile in a file's header: which build on which system recorded the samples (Swift's
/// `MetricsProfile`; Chrome embeds a `SystemProfileProto` in each persistent file,
/// components/metrics/persistent_system_profile.h).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Profile {
    pub app_version: String,
    pub build_number: String,
    /// `stable`, `nightly`, `dev`; empty when the process does not know it.
    pub channel: String,
    /// `major.minor.patch` on macOS; the kernel release elsewhere.
    pub os_version: String,
    /// macOS: `hw.model` (`Mac15,3`); elsewhere the CPU architecture.
    pub hardware_class: String,
    /// `kern.bootsessionuuid` (Linux `boot_id`); zero when unknown.
    pub boot_session: [u8; 16],
    /// The main image's `LC_UUID` (Linux: the GNU build id's first 16 bytes); zero when none.
    pub build_uuid: [u8; 16],
    /// The build's day as `yyyymmdd`; 0 when unknown.
    pub build_day: u32,
}

impl Profile {
    /// This process's profile: the build version ([`crate::build_version`]), the OS version, the hardware
    /// class, the boot session and the build UUID. A few `sysctl` reads: call it at startup, off a latency path.
    pub fn current(channel: &str) -> Profile {
        let version = crate::build_version();
        let end = version.iter().position(|&byte| byte == 0).unwrap_or(version.len());
        Profile {
            app_version: String::from_utf8_lossy(&version[..end]).into_owned(),
            build_number: String::new(),
            channel: channel.to_owned(),
            os_version: os_version(),
            hardware_class: hardware_class(),
            boot_session: crate::clock::boot_session(),
            build_uuid: crate::build_uuid(),
            build_day: 0,
        }
    }

    fn write(&self, header: &mut [u8]) {
        header[profile_at::BOOT_SESSION..][..16].copy_from_slice(&self.boot_session);
        header[profile_at::BUILD_UUID..][..16].copy_from_slice(&self.build_uuid);
        header[profile_at::BUILD_DAY..][..4].copy_from_slice(&self.build_day.to_le_bytes());
        for (text, at) in [
            (&self.app_version, profile_at::APP_VERSION),
            (&self.build_number, profile_at::BUILD_NUMBER),
            (&self.channel, profile_at::CHANNEL),
            (&self.os_version, profile_at::OS_VERSION),
            (&self.hardware_class, profile_at::HARDWARE_CLASS),
        ] {
            let bytes = crate::layout::utf8_prefix(text, TEXT_BYTES);
            header[at..][..bytes.len()].copy_from_slice(bytes);
        }
    }

    fn read(header: &[u8]) -> Profile {
        let text = |at: usize| {
            let slot = &header[at..][..TEXT_BYTES];
            let end = slot.iter().position(|&byte| byte == 0).unwrap_or(slot.len());
            String::from_utf8_lossy(&slot[..end]).into_owned()
        };
        let uuid = |at: usize| <[u8; 16]>::try_from(&header[at..][..16]).unwrap_or([0; 16]);
        Profile {
            app_version: text(profile_at::APP_VERSION),
            build_number: text(profile_at::BUILD_NUMBER),
            channel: text(profile_at::CHANNEL),
            os_version: text(profile_at::OS_VERSION),
            hardware_class: text(profile_at::HARDWARE_CLASS),
            boot_session: uuid(profile_at::BOOT_SESSION),
            build_uuid: uuid(profile_at::BUILD_UUID),
            build_day: read_u32(header, profile_at::BUILD_DAY),
        }
    }
}

/// `kern.osproductversion` as `major.minor.patch` (Swift's `operatingSystemVersion` format).
#[cfg(target_os = "macos")]
fn os_version() -> String {
    let version = sysctl_text(c"kern.osproductversion");
    match version.matches('.').count() {
        0 if !version.is_empty() => format!("{version}.0.0"),
        1 => format!("{version}.0"),
        _ => version,
    }
}

/// The kernel release (`uname -r`).
#[cfg(all(unix, not(target_os = "macos")))]
fn os_version() -> String {
    // SAFETY: utsname is plain old data; all zero is a valid value.
    let mut name: libc::utsname = unsafe { std::mem::zeroed() };
    // SAFETY: a valid out pointer for the call.
    if unsafe { libc::uname(&mut name) } != 0 {
        return String::new();
    }
    // SAFETY: uname NUL-terminates `release` inside the struct.
    let release = unsafe { std::ffi::CStr::from_ptr(name.release.as_ptr()) };
    release.to_string_lossy().into_owned()
}

#[cfg(not(unix))]
fn os_version() -> String {
    String::new()
}

#[cfg(target_os = "macos")]
fn hardware_class() -> String {
    sysctl_text(c"hw.model")
}

#[cfg(not(target_os = "macos"))]
fn hardware_class() -> String {
    std::env::consts::ARCH.to_owned()
}

/// A string sysctl, empty when the kernel does not answer.
#[cfg(target_os = "macos")]
fn sysctl_text(name: &std::ffi::CStr) -> String {
    let mut buffer = [0u8; 128];
    let mut len = buffer.len();
    // SAFETY: a NUL-terminated name, a buffer of `len` bytes, and no new value.
    let status = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return String::new();
    }
    let text = &buffer[..len.min(buffer.len())];
    let end = text.iter().position(|&byte| byte == 0).unwrap_or(text.len());
    String::from_utf8_lossy(&text[..end]).into_owned()
}

/// The header fields: the writer and its profile.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub role: Role,
    pub pid: u32,
    /// [`crate::clock::now_ns`] when the store was made.
    pub start_uptime_ns: u64,
    /// The wall clock then, ns since 1970.
    pub start_unix_ns: u64,
    pub profile: Profile,
}

impl Header {
    /// This process as `role`, starting now.
    pub fn current(role: Role, profile: Profile) -> Header {
        let start_unix_ns = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
        Header {
            role,
            pid: std::process::id(),
            start_uptime_ns: crate::clock::now_ns(),
            start_unix_ns,
            profile,
        }
    }
}

/// The name of `role`'s metrics file in process `pid` (Swift's `MetricsStore.fileName(role:pid:)`).
pub fn file_name(role: Role, pid: u32) -> String {
    format!("metrics-{}-{pid}.bin", role.as_str())
}

/// Where one histogram's counters are.
#[derive(Clone, Copy, Debug)]
struct Slot {
    layout: Layout,
    /// The block's first word (its count) from the start of the image.
    word: usize,
}

/// `value` rounded up to a multiple of `alignment`.
fn align(value: usize, alignment: usize) -> usize {
    value.div_ceil(alignment) * alignment
}

/// The slots, the first block's offset and the file's size of `catalog` (Swift's `MetricsStore.Layout`).
fn plan(catalog: &[HistogramSpec]) -> (Vec<Slot>, usize, usize) {
    let blocks_offset = align(DIRECTORY_OFFSET + catalog.len() * ENTRY_BYTES, BLOCK_ALIGN);
    let mut offset = blocks_offset;
    let mut slots = Vec::with_capacity(catalog.len());
    for spec in catalog {
        slots.push(Slot { layout: spec.layout, word: offset / 8 });
        offset += align(spec.layout.block_bytes(), BLOCK_ALIGN);
    }
    (slots, blocks_offset, align(offset, FILE_ALIGN))
}

/// The header and directory bytes (everything before the first block).
fn image(
    catalog: &[HistogramSpec],
    slots: &[Slot],
    blocks_offset: usize,
    byte_count: usize,
    header: &Header,
) -> Vec<u8> {
    let mut bytes = vec![0u8; blocks_offset];
    put(&mut bytes, 0, &MAGIC);
    put(&mut bytes, 8, &VERSION.to_le_bytes());
    put(&mut bytes, 12, &(DIRECTORY_OFFSET as u32).to_le_bytes());
    put(&mut bytes, 16, &(catalog.len() as u32).to_le_bytes());
    put(&mut bytes, 20, &(header.role as u16).to_le_bytes());
    put(&mut bytes, 22, &SUB_BUCKETS_LOG2.to_le_bytes());
    put(&mut bytes, 24, &header.pid.to_le_bytes());
    put(&mut bytes, 28, &(ENTRY_BYTES as u32).to_le_bytes());
    put(&mut bytes, 32, &header.start_uptime_ns.to_le_bytes());
    put(&mut bytes, 40, &header.start_unix_ns.to_le_bytes());
    put(&mut bytes, 48, &(byte_count as u64).to_le_bytes());
    put(&mut bytes, 56, &(blocks_offset as u64).to_le_bytes());
    header.profile.write(&mut bytes);
    for (index, (spec, slot)) in catalog.iter().zip(slots).enumerate() {
        let at = DIRECTORY_OFFSET + index * ENTRY_BYTES;
        put(&mut bytes, at, crate::layout::utf8_prefix(spec.name, NAME_BYTES));
        put(&mut bytes, at + 64, &spec.layout.kind().to_le_bytes());
        put(&mut bytes, at + 68, &(spec.layout.bucket_count() as u32).to_le_bytes());
        put(&mut bytes, at + 72, &spec.layout.limit().to_le_bytes());
        put(&mut bytes, at + 80, &((slot.word * 8) as u64).to_le_bytes());
    }
    bytes
}

fn put(bytes: &mut [u8], at: usize, value: &[u8]) {
    bytes[at..at + value.len()].copy_from_slice(value);
}

fn read_u16(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn read_u32(bytes: &[u8], at: usize) -> u32 {
    bytes[at..].first_chunk().map_or(0, |word| u32::from_le_bytes(*word))
}

fn read_u64(bytes: &[u8], at: usize) -> u64 {
    bytes[at..].first_chunk().map_or(0, |word| u64::from_le_bytes(*word))
}

/// The counter word `word` of the image at `base`.
///
/// # Safety
/// `base` is 8-byte aligned, the image holds `word`, the memory outlives `'a`, and its counters are only
/// ever accessed through atomics.
#[inline(always)]
unsafe fn counter<'a>(base: *mut u8, word: usize) -> &'a AtomicU64 {
    // SAFETY: the caller's contract; AtomicU64 has u64's size and alignment.
    unsafe { AtomicU64::from_ptr(base.add(word * 8).cast::<u64>()) }
}

/// One histogram's counters read at one moment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HistogramCounts {
    pub count: u64,
    /// The sum of the samples (one below 0 counted as 0), wrapping.
    pub sum: u64,
    /// Every bucket, the overflow bucket last.
    pub buckets: Vec<u64>,
}

/// A process's field histograms: one counter block per catalog histogram, first on the heap, then in its
/// `metrics-<role>-<pid>.bin` (see the module doc). The process's composition root owns it and hands it to
/// whatever records (an `Arc`), as Chrome's metrics service owns its `GlobalHistogramAllocator`.
pub struct MetricsStore {
    header: Header,
    names: Box<[&'static str]>,
    slots: Box<[Slot]>,
    /// The header and directory, written into the heap now and into the file at adoption.
    image: Box<[u8]>,
    byte_count: usize,
    /// The heap block (freed on drop, when no writer can hold `&self`).
    heap: HeapBlock,
    /// The block writers add to: the heap, then the file's mapping (never unmapped).
    active: AtomicPtr<u8>,
    /// 0 before adoption, 1 while it runs, 2 after it succeeded.
    adoption: AtomicU8,
    file: OnceLock<PathBuf>,
}

impl MetricsStore {
    /// A store of `catalog` whose counters start on the heap; no file work. A name listed twice records into
    /// its first entry.
    pub fn new(catalog: &[HistogramSpec], header: Header) -> MetricsStore {
        let (slots, blocks_offset, byte_count) = plan(catalog);
        let image = image(catalog, &slots, blocks_offset, byte_count, &header);
        let heap = HeapBlock::zeroed(byte_count);
        // SAFETY: the block holds `byte_count` >= `image.len()` bytes and nothing else sees it yet.
        unsafe { std::ptr::copy_nonoverlapping(image.as_ptr(), heap.as_ptr(), image.len()) };
        let active = AtomicPtr::new(heap.as_ptr());
        MetricsStore {
            header,
            names: catalog.iter().map(|spec| spec.name).collect(),
            slots: slots.into_boxed_slice(),
            image: image.into_boxed_slice(),
            byte_count,
            heap,
            active,
            adoption: AtomicU8::new(0),
            file: OnceLock::new(),
        }
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    /// The file's bytes (and the heap block's).
    pub fn byte_count(&self) -> usize {
        self.byte_count
    }

    /// The position of `name` in the catalog: what [`Self::record`] and [`Self::read`] take.
    pub fn index_of(&self, name: &str) -> Option<usize> {
        self.names.iter().position(|known| *known == name)
    }

    /// The layout of the histogram at `index`.
    pub fn layout(&self, index: usize) -> Option<Layout> {
        self.slots.get(index).map(|slot| slot.layout)
    }

    /// Adds `sample` to the bucket, count and sum of the histogram at `index`: three relaxed adds; nothing for
    /// an index outside the catalog.
    #[inline]
    pub fn record(&self, index: usize, sample: i64) {
        let Some(slot) = self.slots.get(index) else { return };
        let base = self.active.load(Ordering::Acquire);
        // SAFETY: `base` is the heap block or the file mapping, both `byte_count` bytes, page aligned and alive
        // while `self` is; the slot's block lies inside them (`plan`).
        unsafe {
            counter(base, slot.word + 2 + slot.layout.bucket_index(sample))
                .fetch_add(1, Ordering::Relaxed);
            counter(base, slot.word).fetch_add(1, Ordering::Relaxed);
            counter(base, slot.word + 1).fetch_add(sample.max(0) as u64, Ordering::Relaxed);
        }
    }

    /// Adds `samples` samples to the bucket of `value` and `sum` to the sum of the histogram at `index`: how
    /// counts a process kept elsewhere before it had this store move into it. Nothing outside the catalog.
    pub fn add(&self, index: usize, value: i64, samples: u64, sum: u64) {
        let Some(slot) = self.slots.get(index) else { return };
        let base = self.active.load(Ordering::Acquire);
        // SAFETY: as in `record`.
        unsafe {
            counter(base, slot.word + 2 + slot.layout.bucket_index(value))
                .fetch_add(samples, Ordering::Relaxed);
            counter(base, slot.word).fetch_add(samples, Ordering::Relaxed);
            counter(base, slot.word + 1).fetch_add(sum, Ordering::Relaxed);
        }
    }

    /// The histogram at `index` now: relaxed loads of the active block, so `server-stats` reads what the
    /// file holds. None outside the catalog.
    pub fn read(&self, index: usize) -> Option<HistogramCounts> {
        let slot = self.slots.get(index)?;
        let base = self.active.load(Ordering::Acquire);
        // SAFETY: as in `record`.
        let load = |word: usize| unsafe { counter(base, slot.word + word) }.load(Ordering::Relaxed);
        Some(HistogramCounts {
            count: load(0),
            sum: load(1),
            buckets: (0..slot.layout.bucket_count()).map(|bucket| load(2 + bucket)).collect(),
        })
    }

    /// A copy of the active block, header included (relaxed loads of the counters).
    pub fn snapshot_bytes(&self) -> Vec<u8> {
        let base = self.active.load(Ordering::Acquire);
        let mut bytes = self.image.to_vec();
        bytes.reserve(self.byte_count - self.image.len());
        for word in self.image.len() / 8..self.byte_count / 8 {
            // SAFETY: as in `record`; `word` is inside the block.
            let value = unsafe { counter(base, word) }.load(Ordering::Relaxed);
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes
    }

    /// Whether the counters live in the file now.
    pub fn is_file_backed(&self) -> bool {
        self.adoption.load(Ordering::Acquire) == 2
    }

    /// The file's path once [`Self::adopt_file`] succeeded.
    pub fn file_path(&self) -> Option<&Path> {
        self.file.get().map(PathBuf::as_path)
    }

    /// Moves the counters into `dir`/[`file_name`]: creates the private directory, maps a new file with its
    /// blocks reserved (`map.rs`), writes the header and directory, swaps the writers to it, then adds the
    /// heap's counters into it. Blocking file work: never on a latency path. One-shot: a call after one that
    /// succeeded, or during one, returns `AlreadyExists`; a failed one leaves the counters on the heap.
    pub fn adopt_file(&self, dir: &Path) -> io::Result<PathBuf> {
        if self.adoption.compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire).is_err() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the metrics file is adopted",
            ));
        }
        let path = dir.join(file_name(self.header.role, self.header.pid));
        let mapping = match create_private_dir(dir)
            .and_then(|()| map_file(&path, self.byte_count, reserve_blocks))
        {
            Ok(mapping) => mapping,
            Err(error) => {
                self.adoption.store(0, Ordering::Release);
                return Err(error);
            }
        };
        let file = mapping.as_ptr();
        // SAFETY: a fresh zeroed mapping of `byte_count` >= `image.len()` bytes that no writer sees yet.
        unsafe { std::ptr::copy_nonoverlapping(self.image.as_ptr(), file, self.image.len()) };
        self.active.store(file, Ordering::Release);
        let heap = self.heap.as_ptr();
        for word in self.image.len() / 8..self.byte_count / 8 {
            // SAFETY: both blocks are `byte_count` bytes, page aligned and alive while `self` is.
            let value = unsafe { counter(heap, word) }.load(Ordering::Relaxed);
            if value != 0 {
                // SAFETY: as above.
                unsafe { counter(file, word) }.fetch_add(value, Ordering::Relaxed);
            }
        }
        let _ = self.file.set(path.clone());
        self.adoption.store(2, Ordering::Release);
        Ok(path)
    }

    /// Runs [`Self::adopt_file`] on the one-shot thread `cmux-metrics-open`, as the black box opens its ring
    /// (`init_blackbox`): the caller never waits for the file.
    pub fn open_in_background(self: &Arc<Self>, dir: PathBuf) -> MetricsOpen {
        let store = Arc::clone(self);
        let handle = std::thread::Builder::new()
            .name("cmux-metrics-open".into())
            .spawn(move || store.adopt_file(&dir));
        MetricsOpen(handle.ok())
    }
}

/// The file-open thread of [`MetricsStore::open_in_background`].
pub struct MetricsOpen(Option<std::thread::JoinHandle<io::Result<PathBuf>>>);

impl MetricsOpen {
    /// Waits for the file (tests and tools; a process drops this and never waits): its path, or why the
    /// counters stay on the heap.
    pub fn wait(self) -> io::Result<PathBuf> {
        match self.0 {
            Some(handle) => handle
                .join()
                .unwrap_or_else(|_| Err(io::Error::other("metrics-open thread panicked"))),
            None => Err(io::Error::other("metrics-open thread did not start")),
        }
    }
}

/// Why [`MetricsFile::open`] read nothing.
#[derive(Debug)]
pub enum MetricsFileError {
    /// The file could not be opened or mapped.
    Io(io::Error),
    /// Not a version 1 metrics file whose blocks all lie inside it (a process ended while it wrote the header).
    Invalid,
}

impl std::fmt::Display for MetricsFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MetricsFileError::Io(error) => write!(f, "cannot map the metrics file: {error}"),
            MetricsFileError::Invalid => f.write_str("not a version 1 metrics file"),
        }
    }
}

impl std::error::Error for MetricsFileError {}

/// One histogram's samples since the last fold.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeltaHistogram {
    pub name: String,
    pub layout: Layout,
    pub count: u64,
    pub sum: u64,
    /// The non-empty buckets: (index, samples).
    pub buckets: Vec<(usize, u64)>,
    /// The directory position in its file.
    entry: usize,
}

/// What a file recorded since its last fold, per histogram with samples (Swift's `MetricsDelta`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Delta {
    pub histograms: Vec<DeltaHistogram>,
}

impl Delta {
    pub fn is_empty(&self) -> bool {
        self.histograms.is_empty()
    }

    pub fn histogram(&self, name: &str) -> Option<&DeltaHistogram> {
        self.histograms.iter().find(|histogram| histogram.name == name)
    }
}

/// A directory entry of a mapped file.
struct Entry {
    name: String,
    layout: Layout,
    bucket_count: usize,
    offset: usize,
}

/// A metrics file mapped read-write and shared (Swift's `MetricsImage` over `MetricsLaunchFileReader`'s
/// mapping): its header and counters, read in place. Unmapped on drop.
pub struct MetricsFile {
    base: std::ptr::NonNull<u8>,
    len: usize,
    header: Header,
    entries: Vec<Entry>,
}

// SAFETY: the mapping is plain shared memory; its counters are read and written only through atomics.
unsafe impl Send for MetricsFile {}

impl MetricsFile {
    /// Maps `path` and validates it. Blocking file work: never on a latency path.
    #[cfg(unix)]
    pub fn open(path: &Path) -> Result<MetricsFile, MetricsFileError> {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .map_err(MetricsFileError::Io)?;
        let len = usize::try_from(file.metadata().map_err(MetricsFileError::Io)?.len())
            .map_err(|_| MetricsFileError::Invalid)?;
        if len < DIRECTORY_OFFSET {
            return Err(MetricsFileError::Invalid);
        }
        // SAFETY: a shared read-write mapping of a descriptor opened read-write, `len` bytes long.
        let raw = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if raw == libc::MAP_FAILED {
            return Err(MetricsFileError::Io(io::Error::last_os_error()));
        }
        let Some(base) = std::ptr::NonNull::new(raw.cast::<u8>()) else {
            return Err(MetricsFileError::Io(io::Error::other("mmap returned null")));
        };
        // SAFETY: the mapping holds `len` bytes; only the header and directory are read through this slice,
        // and nothing here writes them.
        let bytes = unsafe { std::slice::from_raw_parts(base.as_ptr(), len) };
        match validate(bytes) {
            Some((header, entries)) => Ok(MetricsFile { base, len, header, entries }),
            None => {
                // SAFETY: the mapping made above, unmapped once.
                unsafe { libc::munmap(raw, len) };
                Err(MetricsFileError::Invalid)
            }
        }
    }

    /// No file mapping on this platform yet (task 132).
    #[cfg(not(unix))]
    pub fn open(_path: &Path) -> Result<MetricsFile, MetricsFileError> {
        Err(MetricsFileError::Io(io::Error::new(
            io::ErrorKind::Unsupported,
            "cmux-trace maps metrics files on unix only",
        )))
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    /// The names of the histograms, in directory order.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|entry| entry.name.as_str())
    }

    /// Current minus logged for every histogram with a sample since the last [`Self::mark_logged`].
    pub fn delta(&self) -> Delta {
        let base = self.base.as_ptr();
        let mut histograms = Vec::new();
        for (position, entry) in self.entries.iter().enumerate() {
            let word = entry.offset / 8;
            let logged = word + 2 + entry.bucket_count;
            // SAFETY: `validate` put every block inside the mapping at an 8-byte aligned offset.
            let since = |at: usize| unsafe {
                counter(base, word + at)
                    .load(Ordering::Relaxed)
                    .wrapping_sub(counter(base, logged + at).load(Ordering::Relaxed))
            };
            let count = since(0);
            if count == 0 {
                continue;
            }
            let buckets = (0..entry.bucket_count)
                .map(|index| (index, since(2 + index)))
                .filter(|&(_, samples)| samples != 0)
                .collect();
            histograms.push(DeltaHistogram {
                name: entry.name.clone(),
                layout: entry.layout,
                count,
                sum: since(1),
                buckets,
                entry: position,
            });
        }
        Delta { histograms }
    }

    /// Adds `delta` (from [`Self::delta`] of this file) to the logged shadow, so the next delta leaves its
    /// samples out. A histogram whose position names another histogram is left alone.
    pub fn mark_logged(&self, delta: &Delta) {
        let base = self.base.as_ptr();
        for histogram in &delta.histograms {
            let Some(entry) = self.entries.get(histogram.entry) else { continue };
            if entry.name != histogram.name {
                continue;
            }
            let logged = entry.offset / 8 + 2 + entry.bucket_count;
            // SAFETY: as in `delta`.
            unsafe {
                counter(base, logged).fetch_add(histogram.count, Ordering::Relaxed);
                counter(base, logged + 1).fetch_add(histogram.sum, Ordering::Relaxed);
                for &(index, samples) in &histogram.buckets {
                    if index < entry.bucket_count {
                        counter(base, logged + 2 + index).fetch_add(samples, Ordering::Relaxed);
                    }
                }
            }
        }
    }

    /// [`Self::delta`], then [`Self::mark_logged`] of it, so each sample is read by one fold. One owner folds a
    /// file.
    pub fn fold(&self) -> Delta {
        let delta = self.delta();
        self.mark_logged(&delta);
        delta
    }
}

impl Drop for MetricsFile {
    fn drop(&mut self) {
        #[cfg(unix)]
        // SAFETY: the mapping `open` made, unmapped once, here.
        unsafe {
            libc::munmap(self.base.as_ptr().cast(), self.len);
        }
    }
}

/// The header and directory of `bytes`; None unless it is a version 1 metrics image whose blocks all lie inside
/// it at 8-byte aligned offsets past the directory (Swift's `MetricsImage(validating:byteCount:)`).
fn validate(bytes: &[u8]) -> Option<(Header, Vec<Entry>)> {
    let len = bytes.len();
    if len < DIRECTORY_OFFSET
        || bytes[..8] != MAGIC
        || read_u32(bytes, 8) != VERSION
        || read_u32(bytes, 12) as usize != DIRECTORY_OFFSET
        || read_u32(bytes, 28) as usize != ENTRY_BYTES
    {
        return None;
    }
    let count = read_u32(bytes, 16) as usize;
    let directory_end = count.checked_mul(ENTRY_BYTES)?.checked_add(DIRECTORY_OFFSET)?;
    if directory_end > len {
        return None;
    }
    let mut entries = Vec::with_capacity(count);
    for index in 0..count {
        let at = DIRECTORY_OFFSET + index * ENTRY_BYTES;
        let name_slot = &bytes[at..at + NAME_BYTES];
        let end = name_slot.iter().position(|&byte| byte == 0).unwrap_or(NAME_BYTES);
        let layout =
            Layout::from_directory(read_u32(bytes, at + 64), read_u64(bytes, at + 72) as i64)?;
        let bucket_count = read_u32(bytes, at + 68) as usize;
        let offset = usize::try_from(read_u64(bytes, at + 80)).ok()?;
        let block_end =
            (2 + bucket_count).checked_mul(16).and_then(|block| offset.checked_add(block))?;
        if bucket_count == 0 || offset % 8 != 0 || offset < directory_end || block_end > len {
            return None;
        }
        entries.push(Entry {
            name: String::from_utf8_lossy(&name_slot[..end]).into_owned(),
            layout,
            bucket_count,
            offset,
        });
    }
    let header = Header {
        role: Role::from_raw(read_u16(bytes, 20))?,
        pid: read_u32(bytes, 24),
        start_uptime_ns: read_u64(bytes, 32),
        start_unix_ns: read_u64(bytes, 40),
        profile: Profile::read(bytes),
    };
    Some((header, entries))
}

#[cfg(test)]
#[path = "metrics_tests.rs"]
mod tests;
