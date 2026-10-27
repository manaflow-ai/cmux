//! The crash-key page of a Rust process (plans/cmux-next/chrome-parity/p09-observability.md, task
//! 098): one 4 KiB file of 64-bit words beside the black box, `<role>-<pid>.crashkeys`, mapped
//! `MAP_SHARED` and written with atomic stores while the process runs, so a crash, an `abort()` or
//! a kill leaves the keys of that moment on disk with no handler running.
//!
//! Chrome keeps its crash keys in static storage the crash handler reads out of the dead process
//! (`components/crash/core/common/crash_key.h`); setting one is a store, never an allocation or a
//! lock. Here the storage is the page: every value is a number (a method's stable key, a count, a
//! state, the build), never a person's text, so a crash report can carry the page as it is.
//!
//! The keys live in process memory, where every change is one atomic operation. Once
//! [`crate::init_blackbox`]'s `cmux-trace-open` thread mapped the file ([`open_page`]), each change
//! also copies its word there, and the opener copies what was set before: a change that races the
//! open still reaches the file, and a request that starts before it and ends after it frees its
//! own entry. The file is never unmapped while the process lives.
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

/// The keys: `memory` holds every key's value for the life of the process and is the only page a
/// key changes on; `file`, once [`open_page`] mapped it, gets a copy of each word after its change
/// ([`Pages::mirror`]). One copy of the truth: an entry or a count changes by one atomic operation
/// on one word, so a request that starts before the file opens and ends after it frees its own
/// entry and no other.
struct Pages {
    memory: Page,
    file: AtomicPtr<Page>,
}

static PAGES: Pages = Pages::new();
static OPENING: AtomicBool = AtomicBool::new(false);
static PATH: OnceLock<PathBuf> = OnceLock::new();

impl Pages {
    const fn new() -> Pages {
        Pages { memory: Page::new(), file: AtomicPtr::new(std::ptr::null_mut()) }
    }

    /// Changes word `index` of the memory page with `change`, then copies it to the file.
    ///
    /// Sequentially consistent with [`Pages::publish`] and [`Pages::mirror_keys`]: either the
    /// change's file load sees the file and the change copies itself, or the opener's word load
    /// after its publish sees the change (one total order over the four operations).
    #[inline]
    fn update<R>(&self, index: usize, change: impl FnOnce(&AtomicU64) -> R) -> R {
        let result = change(self.memory.at(index));
        self.mirror(index);
        result
    }

    /// Copies word `index` to the file page, if one is open, until the copy holds what the memory
    /// page held after it was written: a writer that copied an older value over a newer one finds
    /// the word changed and copies again, so once writers stop the file equals memory.
    #[inline]
    fn mirror(&self, index: usize) {
        let file = self.file.load(Ordering::SeqCst);
        if file.is_null() {
            return;
        }
        // SAFETY: only `publish` stores a non-null pointer, a page that lives for the process (a
        // mapping that is never unmapped, or a leaked test page).
        let file = unsafe { &*file };
        let mut value = self.memory.at(index).load(Ordering::SeqCst);
        loop {
            file.at(index).store(value, Ordering::SeqCst);
            let now = self.memory.at(index).load(Ordering::SeqCst);
            if now == value {
                return;
            }
            value = now;
        }
    }

    /// Makes `file` the page every later change is copied to.
    fn publish(&self, file: &'static Page) {
        self.file.store(std::ptr::from_ref(file).cast_mut(), Ordering::SeqCst);
    }

    /// Copies every key word to the file: the keys set before [`Pages::publish`].
    fn mirror_keys(&self) {
        for index in FIRST_KEY_WORD..WORDS {
            self.mirror(index);
        }
    }

    fn request(&self, method: u64) -> RequestScope {
        self.update(word::REQUEST_METHOD, |word| word.store(method, Ordering::SeqCst));
        if method == 0 {
            return RequestScope { method, entry: Entry::Nothing };
        }
        for index in word::IN_FLIGHT..word::IN_FLIGHT + IN_FLIGHT_CAPACITY {
            let taken = self.update(index, |entry| {
                entry.compare_exchange(0, method, Ordering::SeqCst, Ordering::SeqCst).is_ok()
            });
            if taken {
                return RequestScope { method, entry: Entry::Table(index) };
            }
        }
        self.update(word::UNTRACKED, |count| count.fetch_add(1, Ordering::SeqCst));
        RequestScope { method, entry: Entry::Untracked }
    }
}

/// Stores `value` in `key`.
#[inline]
pub fn set(key: Key, value: u64) {
    PAGES.update(key.word(), |word| word.store(value, Ordering::SeqCst));
}

/// The value `key` holds now.
pub fn get(key: Key) -> u64 {
    PAGES.memory.at(key.word()).load(Ordering::SeqCst)
}

/// Adds one to `key` (a count).
pub fn increment(key: Key) {
    PAGES.update(key.word(), |count| count.fetch_add(1, Ordering::SeqCst));
}

/// Takes one from `key` (a count), never below 0.
pub fn decrement(key: Key) {
    PAGES.update(key.word(), saturating_decrement);
}

fn saturating_decrement(count: &AtomicU64) {
    let _ = count
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |count| Some(count.saturating_sub(1)));
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
    PAGES.request(method)
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
    method: u64,
    entry: Entry,
}

impl RequestScope {
    fn end_in(&self, pages: &Pages) {
        match self.entry {
            Entry::Nothing => {}
            Entry::Table(index) => {
                // The entry is this request's own (it took it from 0): only it frees it.
                let freed = pages.update(index, |entry| {
                    entry.compare_exchange(self.method, 0, Ordering::SeqCst, Ordering::SeqCst)
                });
                debug_assert!(freed.is_ok(), "in-flight entry {index} was not this request's");
            }
            Entry::Untracked => pages.update(word::UNTRACKED, saturating_decrement),
        }
    }
}

impl Drop for RequestScope {
    fn drop(&mut self) {
        self.end_in(&PAGES);
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

/// Makes this process's page file in `dir` and copies the keys into it: the header, then the
/// publish, then every key set so far, then the magic. Once per process (the `cmux-trace-open`
/// thread); blocking. On an error the keys stay in process memory only.
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
    PAGES.publish(file);
    PAGES.mirror_keys();
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

/// The first word a key change copies: the header words before it only [`write_header`] writes.
const FIRST_KEY_WORD: usize = word::REQUEST_METHOD;

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

    fn leaked_page() -> &'static Page {
        Box::leak(Box::new(Page::new()))
    }

    fn leaked_pages() -> &'static Pages {
        Box::leak(Box::new(Pages::new()))
    }

    fn bytes_of(page: &Page) -> Vec<u8> {
        page.0.iter().flat_map(|word| word.load(Ordering::Relaxed).to_le_bytes()).collect()
    }

    fn word_of(page: &Page, index: usize) -> u64 {
        page.at(index).load(Ordering::Relaxed)
    }

    fn in_flight(page: &Page) -> Vec<u64> {
        (word::IN_FLIGHT..word::IN_FLIGHT + IN_FLIGHT_CAPACITY)
            .map(|index| word_of(page, index))
            .filter(|&method| method != 0)
            .collect()
    }

    fn end(pages: &Pages, scope: RequestScope) {
        scope.end_in(pages);
        std::mem::forget(scope);
    }

    /// Every key word of the file is the memory page's.
    fn assert_file_is_memory(pages: &Pages, file: &Page) {
        for index in FIRST_KEY_WORD..WORDS {
            assert_eq!(word_of(file, index), word_of(&pages.memory, index), "word {index}");
        }
    }

    #[test]
    fn crash_keys_requests_take_and_free_in_flight_entries() {
        let pages = leaked_pages();
        let first = pages.request(11);
        let second = pages.request(22);
        assert_eq!(word_of(&pages.memory, word::REQUEST_METHOD), 22);
        end(pages, first);
        let third = pages.request(33);
        assert!(matches!(third.entry, Entry::Table(index) if index == word::IN_FLIGHT));
        let full: Vec<RequestScope> =
            (0..IN_FLIGHT_CAPACITY).map(|method| pages.request(100 + method as u64)).collect();
        assert_eq!(word_of(&pages.memory, word::UNTRACKED), 2, "two past the table");
        for scope in full.into_iter().chain([second, third]) {
            end(pages, scope);
        }
        assert_eq!(word_of(&pages.memory, word::UNTRACKED), 0);
        assert!(in_flight(&pages.memory).is_empty());
        let none = pages.request(0);
        assert!(matches!(none.entry, Entry::Nothing));
        end(pages, none);
    }

    #[test]
    fn crash_keys_open_copies_the_keys_set_before_it() {
        let pages = leaked_pages();
        let file = leaked_page();
        pages.memory.at(word::TERMINAL_COUNT).store(5, Ordering::Relaxed);
        pages.memory.at(word::PID).store(9, Ordering::Relaxed);
        let early = pages.request(77);
        pages.publish(file);
        pages.mirror_keys();
        assert_eq!(word_of(file, word::TERMINAL_COUNT), 5);
        assert_eq!(in_flight(file), [77]);
        assert_eq!(word_of(file, word::PID), 0, "the header is the opener's");
        end(pages, early);
        assert!(in_flight(file).is_empty());
    }

    /// A request named before the open that ends after it, whether its end comes before or after
    /// the opener's copy: neither page keeps it.
    #[test]
    fn crash_keys_a_request_across_the_open_leaves_no_entry() {
        for end_before_copy in [true, false] {
            let pages = leaked_pages();
            let file = leaked_page();
            let early = pages.request(0x51);
            pages.publish(file);
            if end_before_copy {
                end(pages, early);
                pages.mirror_keys();
            } else {
                pages.mirror_keys();
                assert_eq!(in_flight(file), [0x51]);
                end(pages, early);
            }
            assert!(in_flight(&pages.memory).is_empty(), "memory, end first: {end_before_copy}");
            assert!(in_flight(file).is_empty(), "file, end first: {end_before_copy}");
            assert_eq!(word_of(file, word::UNTRACKED), 0);
        }
    }

    /// A writer whose file load came before the publish changes only memory; the opener's copy
    /// after the publish carries it, and its end later clears the file.
    #[test]
    fn crash_keys_a_change_that_missed_the_publish_reaches_the_file_by_the_copy() {
        let pages = leaked_pages();
        let file = leaked_page();
        pages.publish(file);
        pages.memory.at(word::IN_FLIGHT).store(0x52, Ordering::SeqCst);
        pages.memory.at(word::TERMINAL_COUNT).fetch_add(1, Ordering::SeqCst);
        pages.mirror_keys();
        assert_eq!(in_flight(file), [0x52]);
        assert_eq!(word_of(file, word::TERMINAL_COUNT), 1);
        end(pages, RequestScope { method: 0x52, entry: Entry::Table(word::IN_FLIGHT) });
        pages.update(word::TERMINAL_COUNT, saturating_decrement);
        assert!(in_flight(file).is_empty());
        assert_eq!(word_of(file, word::TERMINAL_COUNT), 0);
    }

    /// Request M (before the open) and N (after it, the same method) run at once: M's end never
    /// takes N's entry, on either page.
    #[test]
    fn crash_keys_an_early_request_never_frees_a_later_ones_entry() {
        let pages = leaked_pages();
        let file = leaked_page();
        let m = pages.request(0x53);
        pages.publish(file);
        let n = pages.request(0x53);
        pages.mirror_keys();
        end(pages, m);
        assert_eq!(in_flight(&pages.memory), [0x53], "N runs");
        assert_eq!(in_flight(file), [0x53], "N runs");
        end(pages, n);
        assert!(in_flight(file).is_empty());
    }

    /// Requests, counts and states change on many threads while the page opens: when they stop,
    /// the table is empty, the counts are 0 and the file holds what memory holds.
    #[test]
    fn crash_keys_changes_racing_the_open_leave_the_file_equal_to_memory() {
        const THREADS: u64 = 24;
        const ROUNDS: u64 = 2_000;
        for _ in 0..8 {
            let pages = leaked_pages();
            let file = leaked_page();
            let start = std::sync::Barrier::new(THREADS as usize + 1);
            std::thread::scope(|threads| {
                for thread in 0..THREADS {
                    let start = &start;
                    threads.spawn(move || {
                        start.wait();
                        for round in 0..ROUNDS {
                            let scope = pages.request(1 + (thread + round) % 5);
                            pages.update(word::TERMINAL_COUNT, |count| {
                                count.fetch_add(1, Ordering::SeqCst)
                            });
                            pages.update(word::HOLDER_LINK, |state| {
                                state.store(HolderLink::Linked as u64, Ordering::SeqCst);
                            });
                            pages.update(word::TERMINAL_COUNT, saturating_decrement);
                            end(pages, scope);
                        }
                    });
                }
                start.wait();
                std::thread::yield_now();
                pages.publish(file);
                pages.mirror_keys();
            });
            assert!(in_flight(&pages.memory).is_empty());
            assert_eq!(word_of(&pages.memory, word::UNTRACKED), 0);
            assert_eq!(word_of(&pages.memory, word::TERMINAL_COUNT), 0);
            assert_file_is_memory(pages, file);
        }
    }

    #[test]
    fn crash_keys_page_round_trips_through_decode() {
        let pages = leaked_pages();
        let page = &pages.memory;
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
        let scope = pages.request(0xfeed);
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
        end(pages, scope);

        let mut bytes = bytes_of(page);
        assert_eq!(decode(&bytes[..100]), Err(PageError::TooShort(100)));
        bytes[8] = 2;
        assert_eq!(decode(&bytes), Err(PageError::UnknownVersion(2)));
    }
}
