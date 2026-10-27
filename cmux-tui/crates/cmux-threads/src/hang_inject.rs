//! Hang injection, debug builds only (p09-observability-088): the daemon's
//! `debug-hang-inject` arms a named hang-watch lane of one process, and the
//! next scope that lane's thread opens sleeps inside the scope, so the
//! process's own watcher reports the lane's real thread, deadline and stack.
//! Chrome hangs a target thread the same way for its own checks:
//! `chrome://uithreadhang` and `chrome://gpuhang` run the hang on the thread
//! itself (content/browser/renderer_host/debug_urls.cc, `HangCurrentThread`).
//!
//! One file of two 4 KiB pages, `/tmp/cmux-hang-inject-<uid>.page`
//! (`CMUX_HANG_INJECT_PAGE` names another file), is mapped shared by every
//! debug cmux process that opens a watched scope: the daemon, its holder, its
//! terminal hosts and acpmux. An entry names a lane and the one pid that may
//! take it, and expires a minute after it is armed, so a stale arm never
//! hangs another session's process. It is taken once, with a
//! compare-exchange.
//!
//! The rest of the file is the registry: each process publishes the lanes it
//! watches ([`publish`], once per thread registration or hang site), so
//! hang-matrix.py tells a lane no thread registers from one that did not run.
//! A registration of a process that has exited is reused.
//!
//! The scope's cost ([`hold_if_armed`]) is one load of the mapping and one
//! relaxed load of the armed count while nothing is armed. Release builds do
//! not compile this module.

use std::io;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// The environment variable that names the page file (tests, a second matrix).
pub const PAGE_ENV: &str = "CMUX_HANG_INJECT_PAGE";
/// The longest block one entry may ask for.
pub const MAX_BLOCK: Duration = Duration::from_secs(30);
/// How long an armed entry waits for its lane before it expires.
pub const ARM_TTL: Duration = Duration::from_secs(60);
/// Entries one page holds.
pub const ENTRIES: usize = 32;
/// Bytes of a lane name an entry keeps.
pub const NAME_BYTES: usize = 32;
/// Registrations one page holds.
pub const REGISTRATIONS: usize = 95;
/// The bytes the page file is sized to (two 4 KiB pages: the arms, then the registry).
pub const PAGE_BYTES: usize = 8192;

const NAME_WORDS: usize = NAME_BYTES / 8;
const MAGIC: u64 = u64::from_le_bytes(*b"cmuxhgi2");
const FREE: u64 = 0;
const WRITING: u64 = 1;
const ARMED: u64 = 2;
/// Taken: the low byte, then the taking thread's process id in the high 32 bits.
const TAKEN: u64 = 3;

/// One armed lane (64 bytes, one cache line).
#[repr(C, align(64))]
struct Entry {
    state: AtomicU64,
    block_ms: AtomicU64,
    pid: AtomicU64,
    /// [`monotonic_ms`] after which the entry is not taken.
    expires_ms: AtomicU64,
    name: [AtomicU64; NAME_WORDS],
}

const _: () = assert!(size_of::<Entry>() == 64);

/// A registration's `word`: the low byte its state, the pid above it.
const REG_FREE: u64 = 0;
const REG_WRITING: u64 = 1;
const REG_PUBLISHED: u64 = 2;

/// One lane a process registered (64 bytes, one cache line).
#[repr(C, align(64))]
struct Registration {
    word: AtomicU64,
    name: [AtomicU64; NAME_WORDS],
    _pad: [AtomicU64; 3],
}

const _: () = assert!(size_of::<Registration>() == 64);

/// The shared page: a header line, then the entries.
#[repr(C, align(64))]
pub struct Page {
    magic: AtomicU64,
    /// Entries in [`ARMED`]: [`Page::take`] reads only this while it is 0.
    armed: AtomicU64,
    _header: [AtomicU64; 6],
    entries: [Entry; ENTRIES],
    registrations: [Registration; REGISTRATIONS],
}

const _: () = assert!(size_of::<Page>() <= PAGE_BYTES);

/// An armed or taken entry, as [`Page::entries`] reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EntryState {
    pub lane: String,
    /// The process the entry is armed for.
    pub pid: u32,
    pub block_ms: u64,
    /// True once the lane's thread took it.
    pub taken: bool,
}

/// A lane a live process registered, as [`Page::registrations`] reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Registered {
    pub lane: String,
    pub pid: u32,
}

/// Why an arm or the page map failed.
#[derive(Debug)]
pub enum InjectError {
    /// This process has no page (it could not be mapped, or the platform has none).
    NotMapped,
    /// The lane name is empty, longer than [`NAME_BYTES`], or not a catalog
    /// name (`[a-z0-9._-]`).
    BadLane,
    /// The block is 0 or longer than [`MAX_BLOCK`].
    BadBlock,
    /// The pid is 0.
    BadPid,
    /// The lane is armed already for that process.
    AlreadyArmed,
    /// Every entry is armed, or every registration is a live process's.
    Full,
    /// The page file holds another format.
    Format,
    /// The page file belongs to another user, or others may write it.
    NotOwned,
    /// The page could not be opened or mapped.
    Io(io::Error),
}

impl std::fmt::Display for InjectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InjectError::NotMapped => f.write_str("this process has no hang-injection page"),
            InjectError::BadLane => f.write_str(
                "lane must be 1 to 32 bytes of lower-case letters, digits, '.', '_' or '-'",
            ),
            InjectError::BadBlock => f.write_str("ms must be 1 to 30000"),
            InjectError::BadPid => f.write_str("pid must be a process id"),
            InjectError::AlreadyArmed => f.write_str("this lane is armed already for that process"),
            InjectError::Full => f.write_str("every hang-injection entry is armed"),
            InjectError::Format => f.write_str("the hang-injection page holds another format"),
            InjectError::NotOwned => {
                f.write_str("the hang-injection page is another user's or writable by others")
            }
            InjectError::Io(error) => write!(f, "the hang-injection page: {error}"),
        }
    }
}

impl std::error::Error for InjectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            InjectError::Io(error) => Some(error),
            _ => None,
        }
    }
}

/// A lane name in an entry's encoding: little-endian words, zero padded.
fn encode(lane: &str) -> Result<[u64; NAME_WORDS], InjectError> {
    let valid = !lane.is_empty()
        && lane.len() <= NAME_BYTES
        && lane.bytes().all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'_' | b'-'));
    if !valid {
        return Err(InjectError::BadLane);
    }
    let mut bytes = [0u8; NAME_BYTES];
    bytes[..lane.len()].copy_from_slice(lane.as_bytes());
    let mut words = [0u64; NAME_WORDS];
    for (word, chunk) in words.iter_mut().zip(bytes.chunks_exact(8)) {
        let mut le = [0u8; 8];
        le.copy_from_slice(chunk);
        *word = u64::from_le_bytes(le);
    }
    Ok(words)
}

fn decode(words: &[AtomicU64; NAME_WORDS]) -> String {
    let mut bytes = [0u8; NAME_BYTES];
    for (word, chunk) in words.iter().zip(bytes.chunks_exact_mut(8)) {
        chunk.copy_from_slice(&word.load(Ordering::Relaxed).to_le_bytes());
    }
    let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(NAME_BYTES);
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// Milliseconds on the system-wide monotonic clock, the same in every process.
#[cfg(unix)]
fn monotonic_ms() -> u64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid timespec for clock_gettime to write.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    u64::try_from(now.tv_sec).unwrap_or(0) * 1000
        + u64::try_from(now.tv_nsec).unwrap_or(0) / 1_000_000
}

#[cfg(not(unix))]
fn monotonic_ms() -> u64 {
    0
}

fn names(name: &[AtomicU64; NAME_WORDS], words: &[u64; NAME_WORDS]) -> bool {
    name.iter().zip(words).all(|(stored, word)| stored.load(Ordering::Relaxed) == *word)
}

/// Whether process `pid` still runs (a registration of an exited one is reused).
#[cfg(unix)]
fn alive(pid: u32) -> bool {
    let Ok(raw) = libc::pid_t::try_from(pid) else { return true };
    // SAFETY: signal 0 only checks that the process exists; it sends nothing.
    let exists = unsafe { libc::kill(raw, 0) } == 0;
    exists || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[cfg(not(unix))]
fn alive(_pid: u32) -> bool {
    true
}

impl Entry {
    fn names(&self, words: &[u64; NAME_WORDS]) -> bool {
        names(&self.name, words)
    }

    fn is_for(&self, words: &[u64; NAME_WORDS], pid: u32) -> bool {
        self.pid.load(Ordering::Relaxed) == u64::from(pid) && self.names(words)
    }
}

impl Page {
    /// An empty page in this process's memory (tests).
    pub fn new() -> Page {
        Page {
            magic: AtomicU64::new(MAGIC),
            armed: AtomicU64::new(0),
            _header: [const { AtomicU64::new(0) }; 6],
            entries: [const {
                Entry {
                    state: AtomicU64::new(FREE),
                    block_ms: AtomicU64::new(0),
                    pid: AtomicU64::new(0),
                    expires_ms: AtomicU64::new(0),
                    name: [const { AtomicU64::new(0) }; NAME_WORDS],
                }
            }; ENTRIES],
            registrations: [const {
                Registration {
                    word: AtomicU64::new(REG_FREE),
                    name: [const { AtomicU64::new(0) }; NAME_WORDS],
                    _pad: [const { AtomicU64::new(0) }; 3],
                }
            }; REGISTRATIONS],
        }
    }

    /// Arms `lane` in process `pid`: the next scope of that lane blocks for `block`.
    pub fn arm(&self, lane: &str, pid: u32, block: Duration) -> Result<(), InjectError> {
        self.arm_at(lane, pid, block, monotonic_ms())
    }

    fn arm_at(
        &self,
        lane: &str,
        pid: u32,
        block: Duration,
        now_ms: u64,
    ) -> Result<(), InjectError> {
        let words = encode(lane)?;
        if block.is_zero() || block > MAX_BLOCK {
            return Err(InjectError::BadBlock);
        }
        if pid == 0 {
            return Err(InjectError::BadPid);
        }
        self.expire(now_ms);
        if self
            .entries
            .iter()
            .any(|entry| entry.state.load(Ordering::Acquire) == ARMED && entry.is_for(&words, pid))
        {
            return Err(InjectError::AlreadyArmed);
        }
        let claimed = self.entries.iter().find(|entry| {
            let state = entry.state.load(Ordering::Relaxed);
            (state == FREE || state & 0xFF == TAKEN)
                && entry
                    .state
                    .compare_exchange(state, WRITING, Ordering::Acquire, Ordering::Relaxed)
                    .is_ok()
        });
        let Some(entry) = claimed else { return Err(InjectError::Full) };
        for (stored, word) in entry.name.iter().zip(words) {
            stored.store(word, Ordering::Relaxed);
        }
        entry.block_ms.store(millis(block), Ordering::Relaxed);
        entry.pid.store(u64::from(pid), Ordering::Relaxed);
        entry.expires_ms.store(now_ms.saturating_add(millis(ARM_TTL)), Ordering::Relaxed);
        entry.state.store(ARMED, Ordering::Release);
        self.armed.fetch_add(1, Ordering::Release);
        Ok(())
    }

    /// Frees every armed entry past its expiry.
    fn expire(&self, now_ms: u64) {
        for entry in &self.entries {
            if entry.state.load(Ordering::Acquire) == ARMED
                && entry.expires_ms.load(Ordering::Relaxed) < now_ms
                && entry
                    .state
                    .compare_exchange(ARMED, FREE, Ordering::AcqRel, Ordering::Relaxed)
                    .is_ok()
            {
                self.armed.fetch_sub(1, Ordering::Release);
            }
        }
    }

    /// Disarms `lane` in process `pid`; returns how many entries.
    pub fn disarm(&self, lane: &str, pid: u32) -> usize {
        let Ok(words) = encode(lane) else { return 0 };
        let mut disarmed = 0;
        for entry in &self.entries {
            if entry.is_for(&words, pid)
                && entry
                    .state
                    .compare_exchange(ARMED, FREE, Ordering::AcqRel, Ordering::Relaxed)
                    .is_ok()
            {
                self.armed.fetch_sub(1, Ordering::Release);
                disarmed += 1;
            }
        }
        disarmed
    }

    /// Takes the entry armed for `lane` in process `pid`: how long to block,
    /// once per arm across every process that maps the page.
    #[inline]
    pub fn take(&self, lane: &str, pid: u32) -> Option<Duration> {
        if self.armed.load(Ordering::Relaxed) == 0 {
            return None;
        }
        self.take_armed(lane, pid, monotonic_ms())
    }

    #[cold]
    fn take_armed(&self, lane: &str, pid: u32, now_ms: u64) -> Option<Duration> {
        self.expire(now_ms);
        let words = encode(lane).ok()?;
        for entry in &self.entries {
            if entry.state.load(Ordering::Acquire) != ARMED || !entry.is_for(&words, pid) {
                continue;
            }
            let block_ms = entry.block_ms.load(Ordering::Relaxed);
            let taken = TAKEN | (u64::from(pid) << 32);
            if entry
                .state
                .compare_exchange(ARMED, taken, Ordering::AcqRel, Ordering::Relaxed)
                .is_ok()
            {
                self.armed.fetch_sub(1, Ordering::Release);
                return Some(Duration::from_millis(block_ms));
            }
        }
        None
    }

    /// Publishes that process `pid` watches `lane`; once per lane and pid.
    /// A registration of a process that has exited is reused.
    pub fn register(&self, lane: &str, pid: u32) -> Result<(), InjectError> {
        self.register_with(lane, pid, alive)
    }

    fn register_with(
        &self,
        lane: &str,
        pid: u32,
        alive: impl Fn(u32) -> bool,
    ) -> Result<(), InjectError> {
        let words = encode(lane)?;
        if pid == 0 {
            return Err(InjectError::BadPid);
        }
        let published = (u64::from(pid) << 8) | REG_PUBLISHED;
        if self.registrations.iter().any(|registration| {
            registration.word.load(Ordering::Acquire) == published
                && names(&registration.name, &words)
        }) {
            return Ok(());
        }
        let claimed = self.registrations.iter().find(|registration| {
            let word = registration.word.load(Ordering::Relaxed);
            let owner = u32::try_from(word >> 8).unwrap_or(0);
            (word == REG_FREE || !alive(owner))
                && registration
                    .word
                    .compare_exchange(
                        word,
                        (u64::from(pid) << 8) | REG_WRITING,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    )
                    .is_ok()
        });
        let Some(registration) = claimed else { return Err(InjectError::Full) };
        for (stored, word) in registration.name.iter().zip(words) {
            stored.store(word, Ordering::Relaxed);
        }
        registration.word.store(published, Ordering::Release);
        Ok(())
    }

    /// The lanes live processes registered, each (lane, pid) once.
    pub fn registrations(&self) -> Vec<Registered> {
        self.registrations_with(alive)
    }

    fn registrations_with(&self, alive: impl Fn(u32) -> bool) -> Vec<Registered> {
        let mut found: Vec<Registered> = Vec::new();
        for registration in &self.registrations {
            let word = registration.word.load(Ordering::Acquire);
            let pid = u32::try_from(word >> 8).unwrap_or(0);
            if word & 0xFF != REG_PUBLISHED || !alive(pid) {
                continue;
            }
            let entry = Registered { lane: decode(&registration.name), pid };
            if !found.contains(&entry) {
                found.push(entry);
            }
        }
        found
    }

    /// Registrations a new (lane, pid) may take now: free ones and those of exited processes.
    pub fn registrations_free(&self) -> usize {
        self.registrations
            .iter()
            .filter(|registration| {
                let word = registration.word.load(Ordering::Acquire);
                word == REG_FREE || !alive(u32::try_from(word >> 8).unwrap_or(0))
            })
            .count()
    }

    /// Every armed or taken entry.
    pub fn entries(&self) -> Vec<EntryState> {
        self.entries
            .iter()
            .filter_map(|entry| {
                let state = entry.state.load(Ordering::Acquire);
                let taken = match state & 0xFF {
                    ARMED => false,
                    TAKEN => true,
                    _ => return None,
                };
                Some(EntryState {
                    lane: decode(&entry.name),
                    pid: u32::try_from(entry.pid.load(Ordering::Relaxed)).unwrap_or(0),
                    block_ms: entry.block_ms.load(Ordering::Relaxed),
                    taken,
                })
            })
            .collect()
    }
}

impl Default for Page {
    fn default() -> Page {
        Page::new()
    }
}

/// The page file every process of this user maps: [`PAGE_ENV`], else
/// `/tmp/cmux-hang-inject-<uid>.page`, a path that does not depend on the
/// process's `TMPDIR` (a terminal host may start with another environment).
/// None on Windows.
pub fn page_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(PAGE_ENV).filter(|path| !path.is_empty()) {
        return Some(PathBuf::from(path));
    }
    default_page_path()
}

#[cfg(unix)]
fn default_page_path() -> Option<PathBuf> {
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    Some(PathBuf::from(format!("/tmp/cmux-hang-inject-{uid}.page")))
}

#[cfg(not(unix))]
fn default_page_path() -> Option<PathBuf> {
    None
}

/// This process's page, mapped at its first use and never unmapped.
static PROCESS_PAGE: OnceLock<Option<&'static Page>> = OnceLock::new();

/// This process's page; None when it cannot be mapped.
pub fn page() -> Option<&'static Page> {
    *PROCESS_PAGE.get_or_init(|| page_path().and_then(|path| map(&path).ok()))
}

/// Maps `path` (made and sized when missing) as a [`Page`].
#[cfg(unix)]
pub fn map(path: &std::path::Path) -> Result<&'static Page, InjectError> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    // Never through a link, and only a file of this user that no one else may write: the page
    // decides which threads of this user's processes hang.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(InjectError::Io)?;
    let metadata = file.metadata().map_err(InjectError::Io)?;
    // SAFETY: getuid has no preconditions and cannot fail.
    if metadata.uid() != unsafe { libc::getuid() } || metadata.mode() & 0o022 != 0 {
        return Err(InjectError::NotOwned);
    }
    let bytes = PAGE_BYTES as u64;
    if metadata.len() < bytes {
        // Grows a new file with zeros (an empty page), or an older one-page file by its registry
        // (zeros: free); never shrinks one another process mapped.
        file.set_len(bytes).map_err(InjectError::Io)?;
    }
    // SAFETY: a new shared read-write mapping of PAGE_BYTES of an open file at
    // least that long, with no address hint, so it overlaps nothing. It
    // outlives the descriptor (mmap(2)).
    let address = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            PAGE_BYTES,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            file.as_raw_fd(),
            0,
        )
    };
    if address == libc::MAP_FAILED {
        return Err(InjectError::Io(io::Error::last_os_error()));
    }
    // SAFETY: the mapping is page aligned (above Page's 64-byte alignment),
    // PAGE_BYTES long (at least size_of::<Page>()), zero or a Page another
    // process wrote, and every field is an atomic integer, for which any bit
    // pattern is valid. It is never unmapped, so 'static holds.
    let page = unsafe { &*address.cast::<Page>() };
    match page.magic.compare_exchange(0, MAGIC, Ordering::AcqRel, Ordering::Acquire) {
        Ok(_) => Ok(page),
        Err(MAGIC) => Ok(page),
        Err(_) => Err(InjectError::Format),
    }
}

#[cfg(not(unix))]
pub fn map(_path: &std::path::Path) -> Result<&'static Page, InjectError> {
    Err(InjectError::NotMapped)
}

/// Whether any lane of any process is armed now: one load of the mapping and
/// one relaxed load, for a watcher that must build the lane's name first.
#[inline]
pub fn any_armed() -> bool {
    page().is_some_and(|page| page.armed.load(Ordering::Relaxed) != 0)
}

/// Publishes that this process watches `lane` (a thread registration or a
/// hang site's first scope); nothing when the page is not mapped or full.
pub fn publish(lane: &str) {
    if let Some(page) = page() {
        let _ = page.register(lane, std::process::id());
    }
}

/// Blocks the calling thread for the entry armed for `lane` in this process,
/// if any: called by a hang watcher right after it opened a scope of `lane`,
/// so the block is inside that scope, on its thread.
#[inline]
pub fn hold_if_armed(lane: &str) {
    hold_if_armed_on(page(), lane);
}

/// [`hold_if_armed`] on `page` (a watcher's injected page; None: no page).
#[inline]
pub fn hold_if_armed_on(page: Option<&Page>, lane: &str) {
    if let Some(block) = page.and_then(|page| page.take(lane, std::process::id())) {
        hold(block);
    }
}

#[cold]
#[expect(
    clippy::disallowed_methods,
    reason = "the injected hang itself: the blocking detector must not refuse it"
)]
fn hold(block: Duration) {
    // wakeup-allow: debug the injected hang hang-matrix.py arms; this module is compiled only with debug_assertions
    std::thread::sleep(block);
}

#[cfg(test)]
#[path = "hang_inject_tests.rs"]
mod tests;
