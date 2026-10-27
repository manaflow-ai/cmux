//! The crash-key page of a Rust process (plans/cmux-next/chrome-parity/p09-observability.md, task
//! 098): one 4 KiB file of 64-bit words beside the black box, `<role>-<pid>.crashkeys`, mapped
//! `MAP_SHARED` and written with relaxed stores while the process runs, so a crash, an `abort()` or
//! a kill leaves the keys of that moment on disk with no handler running.
//!
//! Chrome keeps its crash keys in static storage the crash handler reads out of the dead process
//! (`components/crash/core/common/crash_key.h`); setting one is a store, never an allocation or a
//! lock. Here the storage is the page: every value is a number (a method's stable key, a count, a
//! state, the build), never a person's text, so a crash report can carry the page as it is.
//!
//! The page starts in process memory. [`crate::init_blackbox`]'s `cmux-trace-open` thread maps the
//! file, copies what was set so far and swaps the page ([`open_page`]); a store that races the swap
//! still reaches the file. The file is never unmapped while the process lives.
//!
//! Layout (version 1), little-endian words. The header (words 0-7) is the header of every
//! process's page: the app's (`CrashKeySlot` in CmuxNextTrace, task 078) and the C writer's (094)
//! write the same words.
//!
//! | word | key |
//! | --- | --- |
//! | 0 | magic `CMXCKEYS`, stored last when the file is made |
//! | 1 | version (low 32 bits), role ([`Role`], bits 32-47) |
//! | 2 | pid |
//! | 3 | process start (unix µs) |
//! | 4-5 | build uuid (`LC_UUID`, the GNU build id on Linux) |
//! | 6-7 | reserved, 0 |
//! | 8-11 | build version (32 ASCII bytes, NUL padded) |
//! | 12 | [`Key::RequestMethod`] |
//! | 13 | [`Key::TerminalCount`] |
//! | 14 | [`Key::HolderLink`] ([`HolderLink`]) |
//! | 15 | requests in flight past the table (the table was full) |
//! | 16-31 | the requests in flight: each one's method key, 0 for a free entry |
//!
//! Written by the session owner: each request's method ([`request`], `connection_frame.rs`), its
//! holder's link state and terminals (`holder_runtime/service.rs`). [`decode`] reads a page back
//! (the crash forwarder, task 097).

use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU64, Ordering};

use crate::Role;
use crate::identity::ProcessIdentity;
use crate::map::{self, Reserve};

/// Bytes in a page.
pub const PAGE_BYTES: usize = 4096;
/// ASCII `CMXCKEYS` (word 0).
pub const MAGIC: [u8; 8] = *b"CMXCKEYS";
/// The page format version (word 1, low 32 bits).
pub const VERSION: u32 = 1;
/// Requests the page names at once; more in flight are only counted.
pub const IN_FLIGHT_CAPACITY: usize = 16;

const WORDS: usize = PAGE_BYTES / 8;

const _: () = {
    assert!(size_of::<Page>() == PAGE_BYTES);
    assert!(word::IN_FLIGHT + IN_FLIGHT_CAPACITY <= WORDS);
};

/// Word indexes of the layout table in the module doc.
mod word {
    pub(super) const MAGIC: usize = 0;
    pub(super) const VERSION_ROLE: usize = 1;
    pub(super) const PID: usize = 2;
    pub(super) const PROCESS_START: usize = 3;
    pub(super) const BUILD_UUID: usize = 4;
    pub(super) const BUILD_VERSION: usize = 8;
    pub(super) const REQUEST_METHOD: usize = 12;
    pub(super) const TERMINAL_COUNT: usize = 13;
    pub(super) const HOLDER_LINK: usize = 14;
    pub(super) const UNTRACKED: usize = 15;
    pub(super) const IN_FLIGHT: usize = 16;
}

/// A one-word key the process sets.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    /// The method key of the request that started last: FNV-1a 64 of its wire name, the value
    /// cmux-panic-log's `crash_keys::stable_key` gives, so a page and a panic line name a method
    /// the same way. 0 before the first request.
    RequestMethod,
    /// The terminals the process's PTY holder runs for it.
    TerminalCount,
    /// The PTY holder link's state ([`HolderLink`]).
    HolderLink,
}

impl Key {
    const fn word(self) -> usize {
        match self {
            Key::RequestMethod => word::REQUEST_METHOD,
            Key::TerminalCount => word::TERMINAL_COUNT,
            Key::HolderLink => word::HOLDER_LINK,
        }
    }
}

/// The state of the link to the PTY holder ([`Key::HolderLink`]).
#[repr(u64)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HolderLink {
    /// No link was ever made.
    Never = 0,
    /// The link is up.
    Linked = 1,
    /// The link ended; a new holder is being reached.
    Lost = 2,
    /// Another daemon of the session took the holder.
    Superseded = 3,
    /// No new holder could be reached: the terminals ended as lost.
    Failed = 4,
}

impl HolderLink {
    /// The state a page word holds; None for a value this build does not know.
    pub const fn from_raw(raw: u64) -> Option<HolderLink> {
        Some(match raw {
            0 => HolderLink::Never,
            1 => HolderLink::Linked,
            2 => HolderLink::Lost,
            3 => HolderLink::Superseded,
            4 => HolderLink::Failed,
            _ => return None,
        })
    }
}

/// The words of one page.
#[repr(C, align(64))]
struct Page([AtomicU64; WORDS]);

impl Page {
    const fn new() -> Page {
        Page([const { AtomicU64::new(0) }; WORDS])
    }

    fn at(&self, index: usize) -> &AtomicU64 {
        &self.0[index]
    }
}

/// The page while no file holds it: the keys set before [`open_page`].
static HEAP: Page = Page::new();
/// The file page once [`open_page`] mapped it (never unmapped); null before.
static ACTIVE: AtomicPtr<Page> = AtomicPtr::new(std::ptr::null_mut());
static OPENING: AtomicBool = AtomicBool::new(false);
static PATH: OnceLock<PathBuf> = OnceLock::new();

/// The page keys go to now: one acquire load.
#[inline]
fn page() -> &'static Page {
    active_in(&ACTIVE, &HEAP)
}

fn active_in(active: &AtomicPtr<Page>, heap: &'static Page) -> &'static Page {
    let file = active.load(Ordering::Acquire);
    if file.is_null() {
        heap
    } else {
        // SAFETY: only `swap_into` stores a non-null pointer, a page that lives for the process
        // (a mapping that is never unmapped, or a leaked test page).
        unsafe { &*file }
    }
}

/// Stores `value` in `key` (one relaxed store).
#[inline]
pub fn set(key: Key, value: u64) {
    page().at(key.word()).store(value, Ordering::Relaxed);
}

/// The value `key` holds now.
pub fn get(key: Key) -> u64 {
    page().at(key.word()).load(Ordering::Relaxed)
}

/// Adds one to `key` (a count).
pub fn increment(key: Key) {
    page().at(key.word()).fetch_add(1, Ordering::Relaxed);
}

/// Takes one from `key` (a count), never below 0.
pub fn decrement(key: Key) {
    let _ = page()
        .at(key.word())
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |count| Some(count.saturating_sub(1)));
}

/// Stores the PTY holder link's state.
pub fn set_holder_link(state: HolderLink) {
    set(Key::HolderLink, state as u64);
}

/// Names the request with method key `method` ([`Key::RequestMethod`]) until the guard drops: it
/// becomes the last request and takes an entry of the in-flight table, which the drop frees (the
/// table is full: it is counted instead). Lock-free and allocation-free; a key of 0 names nothing.
#[must_use = "the request leaves the page when this guard drops"]
pub fn request(method: u64) -> RequestScope {
    request_in(page(), method)
}

fn request_in(page: &Page, method: u64) -> RequestScope {
    page.at(word::REQUEST_METHOD).store(method, Ordering::Relaxed);
    if method == 0 {
        return RequestScope { entry: Entry::Nothing };
    }
    for index in word::IN_FLIGHT..word::IN_FLIGHT + IN_FLIGHT_CAPACITY {
        if page.at(index).compare_exchange(0, method, Ordering::Relaxed, Ordering::Relaxed).is_ok()
        {
            return RequestScope { entry: Entry::Table(index) };
        }
    }
    page.at(word::UNTRACKED).fetch_add(1, Ordering::Relaxed);
    RequestScope { entry: Entry::Untracked }
}

#[derive(Debug)]
enum Entry {
    Nothing,
    Table(usize),
    Untracked,
}

/// A request [`request`] named; dropping it takes it off the in-flight table.
#[derive(Debug)]
pub struct RequestScope {
    entry: Entry,
}

impl RequestScope {
    fn end_in(&self, page: &Page) {
        match self.entry {
            Entry::Nothing => {}
            Entry::Table(index) => page.at(index).store(0, Ordering::Relaxed),
            Entry::Untracked => {
                let _ = page.at(word::UNTRACKED).fetch_update(
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                    |count| Some(count.saturating_sub(1)),
                );
            }
        }
    }
}

impl Drop for RequestScope {
    fn drop(&mut self) {
        self.end_in(page());
    }
}

/// The page file of `role` in process `pid`.
pub fn page_file_name(role: Role, pid: u32) -> String {
    format!("{}-{pid}.crashkeys", role.as_str())
}

/// The page's file once [`open_page`] made it.
pub fn page_path() -> Option<&'static Path> {
    PATH.get().map(PathBuf::as_path)
}

/// Makes this process's page file in `dir` and moves the keys into it: the header, then every key
/// set so far, then the swap, then the magic. Once per process (the `cmux-trace-open` thread);
/// blocking. On an error the keys stay in process memory.
pub(crate) fn open_page(
    dir: &Path,
    role: Role,
    identity: &ProcessIdentity,
    reserve: Reserve,
) -> io::Result<PathBuf> {
    if OPENING.swap(true, Ordering::AcqRel) {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists, "the crash-key page has a file"));
    }
    let path = dir.join(page_file_name(role, identity.pid));
    map::create_private_dir(dir)?;
    let mapping = map::map_file(&path, PAGE_BYTES, reserve)?;
    // SAFETY: a zeroed, page-aligned, read-write mapping of PAGE_BYTES that is never unmapped; a
    // Page is PAGE_BYTES of AtomicU64, which has the layout of the u64 words there.
    let file: &'static Page = unsafe { &*mapping.as_ptr().cast::<Page>() };
    write_header(file, role, identity);
    swap_into(&ACTIVE, &HEAP, file);
    file.at(word::MAGIC).store(u64::from_le_bytes(MAGIC), Ordering::Release);
    let _ = PATH.set(path.clone());
    Ok(path)
}

fn write_header(page: &Page, role: Role, identity: &ProcessIdentity) {
    let store = |index: usize, value: u64| page.at(index).store(value, Ordering::Relaxed);
    store(word::VERSION_ROLE, u64::from(VERSION) | (role as u64) << 32);
    store(word::PID, u64::from(identity.pid));
    store(word::PROCESS_START, identity.process_start_unix_us);
    for (index, bytes) in identity.build_uuid.chunks_exact(8).enumerate() {
        store(word::BUILD_UUID + index, u64::from_le_bytes(bytes.try_into().unwrap_or([0; 8])));
    }
    for (index, bytes) in identity.build_version.chunks_exact(8).enumerate() {
        store(word::BUILD_VERSION + index, u64::from_le_bytes(bytes.try_into().unwrap_or([0; 8])));
    }
}

/// The first word [`swap_into`] copies: the header words before it only [`write_header`] writes.
const FIRST_KEY_WORD: usize = word::REQUEST_METHOD;

/// Copies the keys of `heap` into `file` and makes `file` the page, then carries over the keys
/// stored into `heap` meanwhile ([`carry_late_stores`]).
fn swap_into(active: &AtomicPtr<Page>, heap: &Page, file: &'static Page) {
    let mut copied = [0u64; WORDS];
    for (index, value) in copied.iter_mut().enumerate().skip(FIRST_KEY_WORD) {
        *value = heap.at(index).load(Ordering::Relaxed);
        file.at(index).store(*value, Ordering::Relaxed);
    }
    active.store(std::ptr::from_ref(file).cast_mut(), Ordering::Release);
    carry_late_stores(heap, file, &copied);
}

/// A writer that read the old page a moment before the swap stored into `heap` after the copy:
/// its key goes into `file` too, unless `file` already holds a newer one than the copy.
fn carry_late_stores(heap: &Page, file: &Page, copied: &[u64; WORDS]) {
    for (index, &old) in copied.iter().enumerate().skip(FIRST_KEY_WORD) {
        let now = heap.at(index).load(Ordering::Relaxed);
        if now != old {
            let _ = file.at(index).compare_exchange(old, now, Ordering::Relaxed, Ordering::Relaxed);
        }
    }
}

/// Why bytes are not a crash-key page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageError {
    /// Fewer than [`PAGE_BYTES`] bytes.
    TooShort(usize),
    /// No magic: not a page, or its file was being made when the process died.
    NotAPage,
    /// A version this build does not read.
    UnknownVersion(u32),
}

impl std::fmt::Display for PageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PageError::TooShort(len) => {
                write!(f, "a crash-key page is {PAGE_BYTES} bytes, not {len}")
            }
            PageError::NotAPage => f.write_str("no crash-key page magic"),
            PageError::UnknownVersion(version) => {
                write!(f, "crash-key page version {version} is not {VERSION}")
            }
        }
    }
}

impl std::error::Error for PageError {}

/// The keys of a page file ([`decode`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PageKeys {
    /// The writer's role, raw ([`Role::from_raw`]).
    pub role: u16,
    pub pid: u32,
    pub process_start_unix_us: u64,
    pub build_uuid: [u8; 16],
    /// ASCII, NUL padded ([`PageKeys::build_version_text`]).
    pub build_version: [u8; 32],
    pub request_method: u64,
    pub terminal_count: u64,
    /// Raw ([`HolderLink::from_raw`]).
    pub holder_link: u64,
    /// Requests in flight that the full table did not name.
    pub requests_untracked: u64,
    in_flight: [u64; IN_FLIGHT_CAPACITY],
}

impl PageKeys {
    /// The method keys of the requests in flight, in table order.
    pub fn requests_in_flight(&self) -> impl Iterator<Item = u64> + '_ {
        self.in_flight.iter().copied().filter(|&method| method != 0)
    }

    /// The build version up to its first NUL; empty when it is not UTF-8.
    pub fn build_version_text(&self) -> &str {
        let end = self.build_version.iter().position(|&byte| byte == 0).unwrap_or(32);
        std::str::from_utf8(&self.build_version[..end]).unwrap_or("")
    }
}

/// Reads a page file's bytes.
pub fn decode(bytes: &[u8]) -> Result<PageKeys, PageError> {
    let words = bytes.get(..PAGE_BYTES).ok_or(PageError::TooShort(bytes.len()))?;
    let at = |index: usize| {
        let start = index * 8;
        u64::from_le_bytes(words[start..start + 8].try_into().unwrap_or([0; 8]))
    };
    if at(word::MAGIC) != u64::from_le_bytes(MAGIC) {
        return Err(PageError::NotAPage);
    }
    let version_role = at(word::VERSION_ROLE);
    let version = version_role as u32;
    if version != VERSION {
        return Err(PageError::UnknownVersion(version));
    }
    let bytes_of = |first: usize, out: &mut [u8]| {
        for (index, chunk) in out.chunks_exact_mut(8).enumerate() {
            chunk.copy_from_slice(&at(first + index).to_le_bytes());
        }
    };
    let mut build_uuid = [0u8; 16];
    bytes_of(word::BUILD_UUID, &mut build_uuid);
    let mut build_version = [0u8; 32];
    bytes_of(word::BUILD_VERSION, &mut build_version);
    let mut in_flight = [0u64; IN_FLIGHT_CAPACITY];
    for (index, method) in in_flight.iter_mut().enumerate() {
        *method = at(word::IN_FLIGHT + index);
    }
    Ok(PageKeys {
        role: (version_role >> 32) as u16,
        pid: at(word::PID) as u32,
        process_start_unix_us: at(word::PROCESS_START),
        build_uuid,
        build_version,
        request_method: at(word::REQUEST_METHOD),
        terminal_count: at(word::TERMINAL_COUNT),
        holder_link: at(word::HOLDER_LINK),
        requests_untracked: at(word::UNTRACKED),
        in_flight,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaked() -> &'static Page {
        Box::leak(Box::new(Page::new()))
    }

    fn bytes_of(page: &Page) -> Vec<u8> {
        page.0.iter().flat_map(|word| word.load(Ordering::Relaxed).to_le_bytes()).collect()
    }

    #[test]
    fn crash_keys_requests_take_and_free_in_flight_entries() {
        let page = leaked();
        let first = request_in(page, 11);
        let second = request_in(page, 22);
        assert_eq!(page.at(word::REQUEST_METHOD).load(Ordering::Relaxed), 22);
        first.end_in(page);
        std::mem::forget(first);
        let third = request_in(page, 33);
        assert!(matches!(third.entry, Entry::Table(index) if index == word::IN_FLIGHT));
        let mut full: Vec<RequestScope> =
            (0..IN_FLIGHT_CAPACITY).map(|method| request_in(page, 100 + method as u64)).collect();
        assert_eq!(page.at(word::UNTRACKED).load(Ordering::Relaxed), 2, "two past the table");
        for scope in full.drain(..).chain([second, third]) {
            scope.end_in(page);
            std::mem::forget(scope);
        }
        assert_eq!(page.at(word::UNTRACKED).load(Ordering::Relaxed), 0);
        let in_flight = word::IN_FLIGHT..word::IN_FLIGHT + IN_FLIGHT_CAPACITY;
        assert!(in_flight.into_iter().all(|index| page.at(index).load(Ordering::Relaxed) == 0));
        let none = request_in(page, 0);
        assert!(matches!(none.entry, Entry::Nothing));
        std::mem::forget(none);
    }

    #[test]
    fn crash_keys_swap_keeps_keys_set_before_it() {
        let heap = leaked();
        let file = leaked();
        let active = AtomicPtr::new(std::ptr::null_mut());
        heap.at(word::TERMINAL_COUNT).store(5, Ordering::Relaxed);
        heap.at(word::IN_FLIGHT).store(77, Ordering::Relaxed);
        heap.at(word::PID).store(9, Ordering::Relaxed);
        swap_into(&active, heap, file);
        assert!(std::ptr::eq(active_in(&active, heap), file));
        assert_eq!(file.at(word::TERMINAL_COUNT).load(Ordering::Relaxed), 5);
        assert_eq!(file.at(word::IN_FLIGHT).load(Ordering::Relaxed), 77);
        assert_eq!(file.at(word::PID).load(Ordering::Relaxed), 0, "the header is the opener's");
    }

    /// The copy saw (Linked, 4); then a late writer moved the heap page to Lost and a writer of
    /// the new page set 9: Lost is carried over, 9 is kept.
    #[test]
    fn crash_keys_swap_carries_a_late_store_but_never_over_a_newer_one() {
        let heap = leaked();
        let file = leaked();
        let mut copied = [0u64; WORDS];
        copied[word::HOLDER_LINK] = HolderLink::Linked as u64;
        copied[word::TERMINAL_COUNT] = 4;
        for (index, value) in copied.iter().enumerate() {
            file.at(index).store(*value, Ordering::Relaxed);
        }
        heap.at(word::HOLDER_LINK).store(HolderLink::Lost as u64, Ordering::Relaxed);
        heap.at(word::TERMINAL_COUNT).store(3, Ordering::Relaxed);
        file.at(word::TERMINAL_COUNT).store(9, Ordering::Relaxed);
        carry_late_stores(heap, file, &copied);
        assert_eq!(file.at(word::HOLDER_LINK).load(Ordering::Relaxed), HolderLink::Lost as u64);
        assert_eq!(file.at(word::TERMINAL_COUNT).load(Ordering::Relaxed), 9);
    }

    #[test]
    fn crash_keys_page_round_trips_through_decode() {
        let page = leaked();
        let mut identity = ProcessIdentity::current_fast();
        identity.pid = 4242;
        identity.process_start_unix_us = 1_700_000_000_000_000;
        identity.build_uuid = *b"0123456789abcdef";
        let mut version = [0u8; 32];
        version[..9].copy_from_slice(b"1.0.0-abc");
        identity.build_version = version;
        write_header(page, Role::Daemon, &identity);
        page.at(word::TERMINAL_COUNT).store(12, Ordering::Relaxed);
        page.at(word::HOLDER_LINK).store(HolderLink::Superseded as u64, Ordering::Relaxed);
        let scope = request_in(page, 0xfeed);
        assert_eq!(decode(&bytes_of(page)), Err(PageError::NotAPage), "no magic yet");
        page.at(word::MAGIC).store(u64::from_le_bytes(MAGIC), Ordering::Release);
        let keys = decode(&bytes_of(page)).expect("decodes");
        assert_eq!(Role::from_raw(keys.role), Some(Role::Daemon));
        assert_eq!(keys.pid, 4242);
        assert_eq!(keys.process_start_unix_us, 1_700_000_000_000_000);
        assert_eq!(&keys.build_uuid, b"0123456789abcdef");
        assert_eq!(keys.build_version_text(), "1.0.0-abc");
        assert_eq!(keys.request_method, 0xfeed);
        assert_eq!(keys.requests_in_flight().collect::<Vec<_>>(), [0xfeed]);
        assert_eq!(keys.terminal_count, 12);
        assert_eq!(HolderLink::from_raw(keys.holder_link), Some(HolderLink::Superseded));
        scope.end_in(page);
        std::mem::forget(scope);

        let mut bytes = bytes_of(page);
        assert_eq!(decode(&bytes[..100]), Err(PageError::TooShort(100)));
        bytes[8] = 2;
        assert_eq!(decode(&bytes), Err(PageError::UnknownVersion(2)));
    }
}
