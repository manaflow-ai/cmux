//! The C ABI of the Screenshots pane's rules for the macOS app (`include/cmux_screenshots.h`,
//! Swift module `CCmuxScreenshotsFFI`), linked into the app through cmux-app-ffi.
//!
//! Strings go in as UTF-8 bytes and a length (not NUL-terminated; invalid UTF-8 is replaced).
//! Strings come out NUL-terminated, owned by the caller, freed with `cmux_screenshots_string_free`,
//! except `cmux_screenshots_listing_path_at`, which lends a pointer valid until the listing
//! changes. Kinds: 1 image, 2 video, 3 other (0: not listed). Entry kinds: 1 file, 2 folder,
//! 3 package, anything else other. A handle is used by one thread at a time. No function unwinds
//! across the boundary.

use crate::detect::{Detector, Environment, Origin, looks_like_folder_key, sources_json};
use crate::gate::Gate;
use crate::listing::{Item, Listing};
use crate::open::{self, Note, Opened};
use crate::pane::{ChangePlan, EntryAction, Pane, PaneSource};
use crate::reader::{self, Entry, EntryKind};
use crate::rule::{MediaKind, ScanRule};
use crate::{names, page};
use std::collections::HashSet;
use std::ffi::{CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_SCREENSHOTS_ABI_VERSION: u32 = 5;

/// A scan rule (a source's `rule` from `cmux_screenshots_detect`).
pub struct CmuxScreenshotsRule {
    inner: ScanRule,
}

/// A newest-first listing.
pub struct CmuxScreenshotsListing {
    inner: Listing,
}

/// The Screenshots pane's sources: what to read, watch, drop and look at.
pub struct CmuxScreenshotsPane {
    inner: Pane,
}

/// The panes unlocked this launch.
pub struct CmuxScreenshotsGate {
    inner: Gate,
}

/// Where an environment callback writes its answer (`cmux_screenshots_reply_set`); no call means
/// none (nil).
pub struct CmuxScreenshotsReply {
    value: Option<String>,
}

/// One directory entry for `cmux_screenshots_newest_picture`.
#[repr(C)]
pub struct CmuxScreenshotsEntry {
    /// 1 file, 2 folder, 3 package, anything else other.
    pub kind: u32,
    /// Whether the file system hides it.
    pub hidden: bool,
    /// The name's UTF-8 bytes.
    pub name: *const u8,
    /// The name's length in bytes.
    pub name_len: usize,
    /// What the system says its extension is (1 image, 2 video, 3 other).
    pub system_kind: u32,
    /// Modification time, seconds.
    pub modified: f64,
}

/// One file for `cmux_screenshots_listing_replace`.
#[repr(C)]
pub struct CmuxScreenshotsItem {
    /// The path's UTF-8 bytes (the item's identity; its last component is the name).
    pub path: *const u8,
    /// The path's length in bytes.
    pub path_len: usize,
    /// 1 image, 2 video, 3 other.
    pub kind: u32,
    /// Size in bytes.
    pub size: i64,
    /// Modification time, seconds.
    pub modified: f64,
}

/// What `cmux_screenshots_detect` reads from this Mac. Each callback may be null (no answer).
/// Strings are UTF-8 bytes and a length; answers go through `cmux_screenshots_reply_set`.
#[repr(C)]
pub struct CmuxScreenshotsEnvironment {
    /// Passed back to every callback.
    pub context: *mut c_void,
    /// A string preference `key` of `domain`.
    pub preference: Option<
        unsafe extern "C" fn(
            *mut c_void,
            *const u8,
            usize,
            *const u8,
            usize,
            *mut CmuxScreenshotsReply,
        ),
    >,
    /// Every string preference of `domain`, as a JSON object of strings.
    pub string_preferences:
        Option<unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut CmuxScreenshotsReply)>,
    /// A small text file's contents.
    pub text:
        Option<unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut CmuxScreenshotsReply)>,
    /// Whether a folder is at the path.
    pub is_directory: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize) -> bool>,
    /// The path with symlinks resolved (`realpath`).
    pub real_path:
        Option<unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut CmuxScreenshotsReply)>,
}

/// What `cmux_screenshots_open` tells a `screenshots.open` run.
#[repr(C)]
pub struct CmuxScreenshotsOpen {
    /// 0 nothing to tell (the person's own run), 1 a new tab opened behind, 2 the tab was there.
    pub opened: u32,
    /// Whether the tab lists its screenshots.
    pub listing: bool,
    /// 0 none, 1 opened in the background, 2 open but waiting for the person's click.
    pub note: u32,
}

fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// # Safety
/// `ptr` is null or `len` readable bytes.
unsafe fn text<'a>(ptr: *const u8, len: usize) -> std::borrow::Cow<'a, str> {
    if ptr.is_null() || len == 0 {
        return std::borrow::Cow::Borrowed("");
    }
    // SAFETY: caller contract.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn out(value: Option<String>) -> *mut c_char {
    value.and_then(|v| CString::new(v).ok()).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Frees a string this library returned; null does nothing.
///
/// # Safety
/// `string` is null or a string from this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: from `CString::into_raw` in `out`, freed once.
        drop(unsafe { CString::from_raw(string) });
    }
}

/// Whether `url` is the Screenshots page (`cmux://screenshots`, any case).
///
/// # Safety
/// `url` is null or `url_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_page_matches(url: *const u8, url_len: usize) -> bool {
    // SAFETY: caller contract.
    let url = unsafe { text(url, url_len) };
    guard(false, || page::matches(&url))
}

/// Whether a preference key names a save folder (`exportPath`, `SaveLocation`; not `NS...` or
/// `recent...`).
///
/// # Safety
/// `key` is null or `key_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_looks_like_folder_key(
    key: *const u8,
    key_len: usize,
) -> bool {
    // SAFETY: caller contract.
    let key = unsafe { text(key, key_len) };
    guard(false, || looks_like_folder_key(&key))
}

/// Whether a source whose origin case is `origin` (`system`, `systemPreview`, `tool`,
/// `toolHistory`, `custom`) takes dropped files; false for any other name.
///
/// # Safety
/// `origin` is null or `origin_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_origin_accepts_drops(
    origin: *const u8,
    origin_len: usize,
) -> bool {
    // SAFETY: caller contract.
    let origin = unsafe { text(origin, origin_len) };
    guard(false, || Origin::named_accepts_drops(&origin))
}

/// What a `screenshots.open` run is told once the tab is open (`existing`: it was already there;
/// `listing`: it lists). A run's note before the tab opens is its answer for a new tab.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screenshots_open(
    persons_run: bool,
    existing: bool,
    listing: bool,
) -> CmuxScreenshotsOpen {
    let none = CmuxScreenshotsOpen { opened: 0, listing: false, note: 0 };
    guard(none, || {
        open::answer(persons_run, existing, listing).map_or(
            CmuxScreenshotsOpen { opened: 0, listing: false, note: 0 },
            |answer| CmuxScreenshotsOpen {
                opened: match answer.opened {
                    Opened::Background => 1,
                    Opened::Existing => 2,
                },
                listing: answer.listing,
                note: match answer.note {
                    None => 0,
                    Some(Note::OpenedInBackground) => 1,
                    Some(Note::ExistingNeedsClick) => 2,
                },
            },
        )
    })
}

/// The name of an image dropped as data, from the local time it was saved.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screenshots_dropped_name(
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        out(Some(names::dropped_name(year, month, day, hour, minute, second)))
    })
}

/// The name a rename gives the file (the typed name trimmed), or null when it is the current name.
///
/// # Safety
/// `current` and `typed` are null or their lengths' readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_rename_target(
    current: *const u8,
    current_len: usize,
    typed: *const u8,
    typed_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let (current, typed) = unsafe { (text(current, current_len), text(typed, typed_len)) };
    guard(std::ptr::null_mut(), || out(names::rename_target(&current, &typed)))
}

fn rule_from_json(json: &str) -> Option<ScanRule> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    Some(rule_from_value(&value))
}

/// A rule from its JSON object; a missing field takes the default.
fn rule_from_value(value: &serde_json::Value) -> ScanRule {
    let strings = |key: &str| -> Vec<String> {
        value[key]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
            .unwrap_or_default()
    };
    ScanRule {
        kinds: value["kinds"]
            .as_u64()
            .and_then(|k| u32::try_from(k).ok())
            .unwrap_or(crate::rule::IMAGES_AND_VIDEOS),
        extra_image_extensions: strings("extraImageExtensions")
            .into_iter()
            .map(|e| e.to_lowercase())
            .collect(),
        name_prefixes: strings("namePrefixes"),
        depth: value["depth"].as_u64().and_then(|d| usize::try_from(d).ok()).unwrap_or(0),
        folder_prefix: value["folderPrefix"].as_str().map(str::to_owned),
    }
}

/// A rule from its JSON (`{kinds, extraImageExtensions, namePrefixes, depth, folderPrefix}`, a
/// source's `rule` from `cmux_screenshots_detect`; a missing field takes the default); null when
/// the JSON is not an object. Free it with `cmux_screenshots_rule_free`.
///
/// # Safety
/// `json` is null or `json_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_rule_new(
    json: *const u8,
    json_len: usize,
) -> *mut CmuxScreenshotsRule {
    // SAFETY: caller contract.
    let json = unsafe { text(json, json_len) };
    guard(std::ptr::null_mut(), || match rule_from_json(&json) {
        Some(inner) => Box::into_raw(Box::new(CmuxScreenshotsRule { inner })),
        None => std::ptr::null_mut(),
    })
}

/// Frees a rule; null does nothing.
///
/// # Safety
/// `rule` is null or from `cmux_screenshots_rule_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_rule_free(rule: *mut CmuxScreenshotsRule) {
    if !rule.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screenshots_rule_new`, freed once.
        drop(unsafe { Box::from_raw(rule) });
    }
}

/// The kind the grid shows a directory entry as (1 image, 2 video, 3 other), or 0 when the rule
/// does not list it. `system_kind` is what the system says its extension is.
///
/// # Safety
/// `rule` is null or a live rule; `name` is null or `name_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_rule_item_kind(
    rule: *const CmuxScreenshotsRule,
    entry_kind: u32,
    hidden: bool,
    name: *const u8,
    name_len: usize,
    system_kind: u32,
) -> u32 {
    // SAFETY: caller contract.
    let Some(rule) = (unsafe { rule.as_ref() }) else { return 0 };
    // SAFETY: caller contract.
    let name = unsafe { text(name, name_len) };
    guard(0, || {
        let entry = Entry {
            kind: EntryKind::from_raw(entry_kind),
            hidden,
            name: &name,
            system_kind: MediaKind::from_raw(system_kind).unwrap_or(MediaKind::Other),
            modified: 0.0,
        };
        reader::item_kind(&entry, &rule.inner).map_or(0, MediaKind::raw)
    })
}

/// The position of the newest picture among `entries` (the first listed wins a tie), or -1.
///
/// # Safety
/// `entries` is null or `count` readable entries whose names are readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_newest_picture(
    entries: *const CmuxScreenshotsEntry,
    count: usize,
) -> i64 {
    if entries.is_null() || count == 0 {
        return -1;
    }
    // SAFETY: caller contract.
    let raw = unsafe { std::slice::from_raw_parts(entries, count) };
    // SAFETY: caller contract (each name readable).
    let names: Vec<_> = raw.iter().map(|e| unsafe { text(e.name, e.name_len) }).collect();
    guard(-1, || {
        let list: Vec<Entry<'_>> = raw
            .iter()
            .zip(&names)
            .map(|(e, name)| Entry {
                kind: EntryKind::from_raw(e.kind),
                hidden: e.hidden,
                name,
                system_kind: MediaKind::from_raw(e.system_kind).unwrap_or(MediaKind::Other),
                modified: e.modified,
            })
            .collect();
        reader::newest_picture(&list).and_then(|i| i64::try_from(i).ok()).unwrap_or(-1)
    })
}

/// An empty listing. Free it with `cmux_screenshots_listing_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screenshots_listing_new() -> *mut CmuxScreenshotsListing {
    Box::into_raw(Box::new(CmuxScreenshotsListing { inner: Listing::default() }))
}

/// Frees a listing; null does nothing.
///
/// # Safety
/// `listing` is null or from `cmux_screenshots_listing_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_free(listing: *mut CmuxScreenshotsListing) {
    if !listing.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screenshots_listing_new`, freed once.
        drop(unsafe { Box::from_raw(listing) });
    }
}

fn kind_or_other(raw: u32) -> MediaKind {
    MediaKind::from_raw(raw).unwrap_or(MediaKind::Other)
}

/// Adds a file of `source`, or moves it to its new place when its path is listed.
///
/// # Safety
/// `listing` is null or a live listing; `path` and `source` are null or their lengths' bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_upsert(
    listing: *mut CmuxScreenshotsListing,
    path: *const u8,
    path_len: usize,
    kind: u32,
    size: i64,
    modified: f64,
    source: *const u8,
    source_len: usize,
) {
    // SAFETY: caller contract.
    let Some(listing) = (unsafe { listing.as_mut() }) else { return };
    // SAFETY: caller contract.
    let (path, source) = unsafe { (text(path, path_len), text(source, source_len)) };
    guard((), || {
        listing.inner.upsert(Item::new(path, kind_or_other(kind), size, modified, source));
    });
}

/// Removes the file at `path`.
///
/// # Safety
/// `listing` is null or a live listing; `path` is null or `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_remove(
    listing: *mut CmuxScreenshotsListing,
    path: *const u8,
    path_len: usize,
) {
    // SAFETY: caller contract.
    let Some(listing) = (unsafe { listing.as_mut() }) else { return };
    // SAFETY: caller contract.
    let path = unsafe { text(path, path_len) };
    guard((), || listing.inner.remove(&path));
}

/// Swaps every file of `source` for `items` (a fresh scan of that folder; `count` 0 drops them).
///
/// # Safety
/// `listing` is null or a live listing; `source` is null or `source_len` bytes; `items` is null
/// or `count` readable items whose paths are readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_replace(
    listing: *mut CmuxScreenshotsListing,
    source: *const u8,
    source_len: usize,
    items: *const CmuxScreenshotsItem,
    count: usize,
) {
    // SAFETY: caller contract.
    let Some(listing) = (unsafe { listing.as_mut() }) else { return };
    // SAFETY: caller contract.
    let source = unsafe { text(source, source_len) }.into_owned();
    let raw = if items.is_null() || count == 0 {
        &[][..]
    } else {
        // SAFETY: caller contract.
        unsafe { std::slice::from_raw_parts(items, count) }
    };
    // SAFETY: caller contract (each path readable).
    let paths: Vec<_> =
        raw.iter().map(|i| unsafe { text(i.path, i.path_len) }.into_owned()).collect();
    guard((), || {
        let new = raw.iter().zip(paths).map(|(i, path)| {
            Item::new(path, kind_or_other(i.kind), i.size, i.modified, source.clone())
        });
        listing.inner.replace(&source, new);
    });
}

/// The number of files listed.
///
/// # Safety
/// `listing` is null or a live listing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_count(
    listing: *const CmuxScreenshotsListing,
) -> usize {
    // SAFETY: caller contract.
    unsafe { listing.as_ref() }.map_or(0, |l| l.inner.len())
}

/// The position of the file at `path`, newest first, or -1 when it is not listed.
///
/// # Safety
/// `listing` is null or a live listing; `path` is null or `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_position(
    listing: *const CmuxScreenshotsListing,
    path: *const u8,
    path_len: usize,
) -> i64 {
    // SAFETY: caller contract.
    let Some(listing) = (unsafe { listing.as_ref() }) else { return -1 };
    // SAFETY: caller contract.
    let path = unsafe { text(path, path_len) };
    guard(-1, || listing.inner.position(&path).and_then(|i| i64::try_from(i).ok()).unwrap_or(-1))
}

/// The path of the file at `index` (newest first): its UTF-8 bytes, length in `*len`, valid until
/// the listing changes; null (and `*len` 0) past the end.
///
/// # Safety
/// `listing` is null or a live listing; `len` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_path_at(
    listing: *const CmuxScreenshotsListing,
    index: usize,
    len: *mut usize,
) -> *const u8 {
    // SAFETY: caller contract.
    let item = unsafe { listing.as_ref() }.and_then(|l| l.inner.items().get(index));
    let (ptr, n) = item.map_or((std::ptr::null(), 0), |i| (i.path.as_ptr(), i.path.len()));
    if !len.is_null() {
        // SAFETY: caller contract.
        unsafe { *len = n };
    }
    ptr
}

/// Writes the positions of the files whose name contains `query` (case- and diacritic-insensitive)
/// and whose source is one of `sources` (newline-separated ids; null means every source) into
/// `out`, up to `capacity`, newest first. Returns how many match (more than `capacity`: call again
/// with a bigger buffer).
///
/// # Safety
/// `listing` is null or a live listing; `query` and `sources` are null or their lengths' bytes;
/// `out` is null or `capacity` writable positions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_filter(
    listing: *const CmuxScreenshotsListing,
    query: *const u8,
    query_len: usize,
    sources: *const u8,
    sources_len: usize,
    out: *mut usize,
    capacity: usize,
) -> usize {
    // SAFETY: caller contract.
    let Some(listing) = (unsafe { listing.as_ref() }) else { return 0 };
    // SAFETY: caller contract.
    let query = unsafe { text(query, query_len) };
    let set: Option<HashSet<String>> = (!sources.is_null())
        // SAFETY: caller contract.
        .then(|| unsafe { text(sources, sources_len) }.split('\n').map(str::to_owned).collect());
    let found = guard(Vec::new(), || listing.inner.filtered_indices(&query, set.as_ref()));
    if !out.is_null() {
        for (slot, index) in found.iter().take(capacity).enumerate() {
            // SAFETY: caller contract (`capacity` writable).
            unsafe { *out.add(slot) = *index };
        }
    }
    found.len()
}

/// How many files each source lists, as a JSON object of source id to count; null for a null
/// listing.
///
/// # Safety
/// `listing` is null or a live listing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_listing_counts(
    listing: *const CmuxScreenshotsListing,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(listing) = (unsafe { listing.as_ref() }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || {
        out(serde_json::to_string(&listing.inner.counts_by_source()).ok())
    })
}

/// No pane unlocked. Free it with `cmux_screenshots_gate_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screenshots_gate_new() -> *mut CmuxScreenshotsGate {
    Box::into_raw(Box::new(CmuxScreenshotsGate { inner: Gate::default() }))
}

/// Frees a gate; null does nothing.
///
/// # Safety
/// `gate` is null or from `cmux_screenshots_gate_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_gate_free(gate: *mut CmuxScreenshotsGate) {
    if !gate.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screenshots_gate_new`, freed once.
        drop(unsafe { Box::from_raw(gate) });
    }
}

/// Unlocks the pane `key` (the app then remembers access).
///
/// # Safety
/// `gate` is null or a live gate; `key` is null or `key_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_gate_unlock(
    gate: *mut CmuxScreenshotsGate,
    key: *const u8,
    key_len: usize,
) {
    // SAFETY: caller contract.
    let Some(gate) = (unsafe { gate.as_mut() }) else { return };
    // SAFETY: caller contract.
    let key = unsafe { text(key, key_len) };
    guard((), || gate.inner.unlock(&key));
}

/// Whether the pane `key` was unlocked this launch.
///
/// # Safety
/// `gate` is null or a live gate; `key` is null or `key_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_gate_is_unlocked(
    gate: *const CmuxScreenshotsGate,
    key: *const u8,
    key_len: usize,
) -> bool {
    // SAFETY: caller contract.
    let Some(gate) = (unsafe { gate.as_ref() }) else { return false };
    // SAFETY: caller contract.
    let key = unsafe { text(key, key_len) };
    guard(false, || gate.inner.is_unlocked(&key))
}

/// Whether sources may be detected (some pane is unlocked).
///
/// # Safety
/// `gate` is null or a live gate.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_gate_may_detect(
    gate: *const CmuxScreenshotsGate,
) -> bool {
    // SAFETY: caller contract.
    unsafe { gate.as_ref() }.is_some_and(|g| g.inner.may_detect())
}

/// Whether the pane `key`, shown now, starts listing on its own: access is remembered and it is
/// not unlocked yet.
///
/// # Safety
/// `gate` is null or a live gate; `key` is null or `key_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_gate_starts_when_shown(
    gate: *const CmuxScreenshotsGate,
    key: *const u8,
    key_len: usize,
    remembers_access: bool,
) -> bool {
    // SAFETY: caller contract.
    let Some(gate) = (unsafe { gate.as_ref() }) else { return false };
    // SAFETY: caller contract.
    let key = unsafe { text(key, key_len) };
    guard(false, || gate.inner.starts_when_shown(&key, remembers_access))
}

/// Answers an environment callback with `value`'s UTF-8 bytes (the last call wins).
///
/// # Safety
/// `reply` is null or the reply the callback was given; `value` is null or `value_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_reply_set(
    reply: *mut CmuxScreenshotsReply,
    value: *const u8,
    value_len: usize,
) {
    // SAFETY: caller contract.
    let Some(reply) = (unsafe { reply.as_mut() }) else { return };
    // SAFETY: caller contract.
    reply.value = Some(unsafe { text(value, value_len) }.into_owned());
}

/// The environment the C caller provides, plus the home and temporary folders.
struct CallerEnvironment<'a> {
    env: &'a CmuxScreenshotsEnvironment,
    home: String,
    temporary: String,
}

impl CallerEnvironment<'_> {
    fn ask(&self, call: impl FnOnce(*mut c_void, *mut CmuxScreenshotsReply)) -> Option<String> {
        let mut reply = CmuxScreenshotsReply { value: None };
        call(self.env.context, &raw mut reply);
        reply.value
    }
}

impl Environment for CallerEnvironment<'_> {
    fn home(&self) -> String {
        self.home.clone()
    }

    fn temporary_directory(&self) -> String {
        self.temporary.clone()
    }

    fn preference(&self, key: &str, domain: &str) -> Option<String> {
        let f = self.env.preference?;
        // SAFETY: the caller's callback, given readable strings and a live reply.
        self.ask(|ctx, reply| unsafe {
            f(ctx, domain.as_ptr(), domain.len(), key.as_ptr(), key.len(), reply);
        })
    }

    fn string_preferences(&self, domain: &str) -> Vec<(String, String)> {
        let Some(f) = self.env.string_preferences else { return Vec::new() };
        // SAFETY: as above.
        let json = self.ask(|ctx, reply| unsafe { f(ctx, domain.as_ptr(), domain.len(), reply) });
        match json.and_then(|j| serde_json::from_str::<serde_json::Value>(&j).ok()) {
            Some(serde_json::Value::Object(map)) => {
                map.into_iter().filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_owned()))).collect()
            }
            _ => Vec::new(),
        }
    }

    fn text(&self, path: &str) -> Option<String> {
        let f = self.env.text?;
        // SAFETY: as above.
        self.ask(|ctx, reply| unsafe { f(ctx, path.as_ptr(), path.len(), reply) })
    }

    fn is_directory(&self, path: &str) -> bool {
        // SAFETY: the caller's callback, given a readable string.
        self.env
            .is_directory
            .is_some_and(|f| unsafe { f(self.env.context, path.as_ptr(), path.len()) })
    }

    fn real_path(&self, path: &str) -> Option<String> {
        let f = self.env.real_path?;
        // SAFETY: as above.
        self.ask(|ctx, reply| unsafe { f(ctx, path.as_ptr(), path.len(), reply) })
    }
}

/// The sources the pane lists, in menu order, as JSON: an array of `{id, folder, origin (system,
/// systemPreview, tool, toolHistory, custom), tool, toolName, acceptsDrops, rule}`; null when
/// `env` is null. `extra_folders` is a JSON array of path strings (anything else: none);
/// `find_tools` false lists only macOS's folders and those.
///
/// # Safety
/// `env` is null or readable with callbacks safe to call during this call; the strings are null or
/// their lengths' readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_detect(
    env: *const CmuxScreenshotsEnvironment,
    home: *const u8,
    home_len: usize,
    temporary: *const u8,
    temporary_len: usize,
    find_tools: bool,
    extra_folders: *const u8,
    extra_folders_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(env) = (unsafe { env.as_ref() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let (home, temporary, extra) = unsafe {
        (
            text(home, home_len),
            text(temporary, temporary_len),
            text(extra_folders, extra_folders_len),
        )
    };
    guard(std::ptr::null_mut(), || {
        let caller =
            CallerEnvironment { env, home: home.into_owned(), temporary: temporary.into_owned() };
        let extra: Vec<String> = serde_json::from_str(&extra).unwrap_or_default();
        out(Some(sources_json(&Detector::new(&caller).detect(find_tools, &extra))))
    })
}

/// macOS's screenshot folder: the `location` preference when it is a folder, else the Desktop.
///
/// # Safety
/// As `cmux_screenshots_detect`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_system_folder(
    env: *const CmuxScreenshotsEnvironment,
    home: *const u8,
    home_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(env) = (unsafe { env.as_ref() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let home = unsafe { text(home, home_len) };
    guard(std::ptr::null_mut(), || {
        let caller = CallerEnvironment { env, home: home.into_owned(), temporary: String::new() };
        out(Some(Detector::new(&caller).system_folder()))
    })
}

/// A pane with no sources; `listing` reads and watches as soon as sources are set. Free it with
/// `cmux_screenshots_pane_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_screenshots_pane_new(listing: bool) -> *mut CmuxScreenshotsPane {
    Box::into_raw(Box::new(CmuxScreenshotsPane { inner: Pane::new(listing) }))
}

/// Frees a pane; null does nothing.
///
/// # Safety
/// `pane` is null or from `cmux_screenshots_pane_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_free(pane: *mut CmuxScreenshotsPane) {
    if !pane.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screenshots_pane_new`, freed once.
        drop(unsafe { Box::from_raw(pane) });
    }
}

/// Starts reading and watching; false when it already was. On true the app reads every source
/// and watches the state's `watched` folders.
///
/// # Safety
/// `pane` is null or a live pane.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_start(pane: *mut CmuxScreenshotsPane) -> bool {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_mut() }) else { return false };
    guard(false, || pane.inner.start())
}

/// Stops reading and watching (access was taken back): forgets failed reads and entered
/// subfolders.
///
/// # Safety
/// `pane` is null or a live pane.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_pause(pane: *mut CmuxScreenshotsPane) {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_mut() }) else { return };
    guard((), || pane.inner.pause());
}

fn pane_sources(json: &str) -> Vec<PaneSource> {
    let value: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
    let Some(list) = value.as_array() else { return Vec::new() };
    list.iter()
        .filter_map(|s| {
            Some(PaneSource {
                id: s["id"].as_str()?.to_owned(),
                label: s["label"].as_str().unwrap_or_default().to_owned(),
                folder: s["folder"].as_str()?.to_owned(),
                accepts_drops: s["acceptsDrops"].as_bool().unwrap_or(false),
                rule: rule_from_value(&s["rule"]),
            })
        })
        .collect()
}

fn json_strings(json: &str) -> Vec<String> {
    let value: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
    value
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
        .unwrap_or_default()
}

/// Shows these sources: `json` is an array, in menu order, of `{id, label, folder, acceptsDrops,
/// rule: {kinds, extraImageExtensions, namePrefixes, depth, folderPrefix}}` (an entry without an
/// id or a folder is skipped). Returns `{changed, removed: [id], read: [id]}`: when changed, the
/// app drops the removed sources' reads and files and reads the `read` ones (when listing).
///
/// # Safety
/// `pane` is null or a live pane; `json` is null or `json_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_set_sources(
    pane: *mut CmuxScreenshotsPane,
    json: *const u8,
    json_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_mut() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let json = unsafe { text(json, json_len) };
    guard(std::ptr::null_mut(), || {
        let plan = pane.inner.set_sources(pane_sources(&json));
        out(Some(
            serde_json::json!({"changed": plan.changed, "removed": plan.removed, "read": plan.read})
                .to_string(),
        ))
    })
}

/// Takes a finished read of source `id`: `folders_json` is the JSON array of the folders it
/// covered (read when `readable`). False when `id` is no longer a source (the app drops the read).
///
/// # Safety
/// `pane` is null or a live pane; `id` and `folders_json` are null or their lengths' bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_read_done(
    pane: *mut CmuxScreenshotsPane,
    id: *const u8,
    id_len: usize,
    readable: bool,
    folders_json: *const u8,
    folders_json_len: usize,
) -> bool {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_mut() }) else { return false };
    // SAFETY: caller contract.
    let (id, folders) = unsafe { (text(id, id_len), text(folders_json, folders_json_len)) };
    guard(false, || pane.inner.read_done(&id, readable, json_strings(&folders)))
}

/// The pane's state: `{listing, accessMissing, unreadable: [id], watched: [path] or null}`
/// (`watched` null when not listing: the app keeps its watches as they are).
///
/// # Safety
/// `pane` is null or a live pane.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_state(
    pane: *const CmuxScreenshotsPane,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_ref() }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || {
        let pane = &pane.inner;
        out(Some(
            serde_json::json!({
                "listing": pane.is_listing(),
                "accessMissing": pane.access_missing(),
                "unreadable": pane.unreadable(),
                "watched": pane.watched(),
            })
            .to_string(),
        ))
    })
}

/// The id of the source a drop is saved into: `selected` (null or empty for none) when it takes
/// drops, else the first that does; null when none does.
///
/// # Safety
/// `pane` is null or a live pane; `selected` is null or `selected_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_drop_source(
    pane: *const CmuxScreenshotsPane,
    selected: *const u8,
    selected_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_ref() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let selected = unsafe { text(selected, selected_len) };
    guard(std::ptr::null_mut(), || {
        let selected = (!selected.is_empty()).then_some(selected.as_ref());
        out(pane.inner.drop_source(selected).map(|s| s.id.clone()))
    })
}

/// The id of the source whose folder holds `path` (the deepest), or null.
///
/// # Safety
/// `pane` is null or a live pane; `path` is null or `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_source_containing(
    pane: *const CmuxScreenshotsPane,
    path: *const u8,
    path_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_ref() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let path = unsafe { text(path, path_len) };
    guard(std::ptr::null_mut(), || out(pane.inner.source_containing(&path).map(|s| s.id.clone())))
}

/// What a watch event of `folder` asks: `names_json` is the JSON array of the changed entries'
/// names, null for an event that is not a list of names. Returns null for nothing,
/// `{"rescan": id}` to read the source again, or `{"source": id, "relist": bool, "paths": [path]}`
/// to look at each path alone (`cmux_screenshots_pane_entry_action`) and then read the source
/// again when `relist`.
///
/// # Safety
/// `pane` is null or a live pane; `folder` and `names_json` are null or their lengths' bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_change(
    pane: *const CmuxScreenshotsPane,
    folder: *const u8,
    folder_len: usize,
    names_json: *const u8,
    names_json_len: usize,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_ref() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let folder = unsafe { text(folder, folder_len) };
    let names = (!names_json.is_null())
        // SAFETY: caller contract.
        .then(|| json_strings(&unsafe { text(names_json, names_json_len) }));
    guard(std::ptr::null_mut(), || match pane.inner.change(&folder, names.as_deref()) {
        ChangePlan::Ignore => std::ptr::null_mut(),
        ChangePlan::Rescan(id) => out(Some(serde_json::json!({ "rescan": id }).to_string())),
        ChangePlan::Look { source, relist, paths } => out(Some(
            serde_json::json!({"source": source, "relist": relist, "paths": paths}).to_string(),
        )),
    })
}

/// What a looked-at `path` of a watch event of `folder` in source `id` does to the listing:
/// 0 remove it, 1 read the source again (a subfolder the rule enters), 2 list it. `entry` is
/// what the disk says is at `path` now (its name, kind, hidden flag and system kind), null when
/// it is gone.
///
/// # Safety
/// `pane` is null or a live pane; `id`, `folder` and `path` are null or their lengths' bytes;
/// `entry` is null or one readable entry whose name is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_pane_entry_action(
    pane: *const CmuxScreenshotsPane,
    id: *const u8,
    id_len: usize,
    folder: *const u8,
    folder_len: usize,
    path: *const u8,
    path_len: usize,
    entry: *const CmuxScreenshotsEntry,
) -> u32 {
    // SAFETY: caller contract.
    let Some(pane) = (unsafe { pane.as_ref() }) else { return 0 };
    // SAFETY: caller contract.
    let (id, folder, path) =
        unsafe { (text(id, id_len), text(folder, folder_len), text(path, path_len)) };
    // SAFETY: caller contract.
    let raw = unsafe { entry.as_ref() };
    // SAFETY: caller contract (the name readable).
    let name = raw.map(|e| unsafe { text(e.name, e.name_len) });
    guard(0, || {
        let entry = raw.zip(name.as_deref()).map(|(e, name)| Entry {
            kind: EntryKind::from_raw(e.kind),
            hidden: e.hidden,
            name,
            system_kind: kind_or_other(e.system_kind),
            modified: e.modified,
        });
        match pane.inner.entry_action(&id, &folder, &path, entry.as_ref()) {
            EntryAction::Remove => 0,
            EntryAction::Relist => 1,
            EntryAction::Upsert => 2,
        }
    })
}

/// A read of one source in progress (`cmux_screenshots_walk_new`).
pub struct CmuxScreenshotsWalk {
    inner: reader::Walk,
}

/// A read of the folder at `root` under `rule` (the rule is copied). Free it with
/// `cmux_screenshots_walk_free`; null when `rule` is null.
///
/// # Safety
/// `rule` is null or a live rule; `root` is null or `root_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_walk_new(
    rule: *const CmuxScreenshotsRule,
    root: *const u8,
    root_len: usize,
) -> *mut CmuxScreenshotsWalk {
    // SAFETY: caller contract.
    let Some(rule) = (unsafe { rule.as_ref() }) else { return std::ptr::null_mut() };
    // SAFETY: caller contract.
    let root = unsafe { text(root, root_len) };
    guard(std::ptr::null_mut(), || {
        let inner = reader::Walk::new(&root, rule.inner.clone());
        Box::into_raw(Box::new(CmuxScreenshotsWalk { inner }))
    })
}

/// Frees a walk; null does nothing.
///
/// # Safety
/// `walk` is null or from `cmux_screenshots_walk_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_walk_free(walk: *mut CmuxScreenshotsWalk) {
    if !walk.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_screenshots_walk_new`, freed once.
        drop(unsafe { Box::from_raw(walk) });
    }
}

/// The next folder to list (the caller frees it), or null when the read is done. Hand its
/// listing to `cmux_screenshots_walk_listed` before asking again.
///
/// # Safety
/// `walk` is null or a live walk.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_walk_next(walk: *mut CmuxScreenshotsWalk) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(walk) = (unsafe { walk.as_mut() }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || out(walk.inner.next_folder().map(str::to_owned)))
}

/// Takes the listing of the folder `cmux_screenshots_walk_next` named (`readable` false: it could
/// not be read) and writes into `kinds` the kind each entry is listed as (1 image, 2 video,
/// 3 other; 0: not listed, or a subfolder the walk reads next).
///
/// # Safety
/// `walk` is null or a live walk; `entries` is null or `count` readable entries whose names are
/// readable; `kinds` is null or `count` writable values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_walk_listed(
    walk: *mut CmuxScreenshotsWalk,
    readable: bool,
    entries: *const CmuxScreenshotsEntry,
    count: usize,
    kinds: *mut u32,
) {
    // SAFETY: caller contract.
    let Some(walk) = (unsafe { walk.as_mut() }) else { return };
    let raw = if entries.is_null() || count == 0 {
        &[][..]
    } else {
        // SAFETY: caller contract.
        unsafe { std::slice::from_raw_parts(entries, count) }
    };
    // SAFETY: caller contract (each name readable).
    let names: Vec<_> = raw.iter().map(|e| unsafe { text(e.name, e.name_len) }).collect();
    let found = guard(Vec::new(), || {
        let list: Vec<Entry<'_>> = raw
            .iter()
            .zip(&names)
            .map(|(e, name)| Entry {
                kind: EntryKind::from_raw(e.kind),
                hidden: e.hidden,
                name,
                system_kind: MediaKind::from_raw(e.system_kind).unwrap_or(MediaKind::Other),
                modified: e.modified,
            })
            .collect();
        walk.inner.listed(readable.then_some(list.as_slice()))
    });
    if kinds.is_null() || raw.is_empty() {
        return;
    }
    // SAFETY: caller contract (`count` writable values).
    let kinds = unsafe { std::slice::from_raw_parts_mut(kinds, raw.len()) };
    for (slot, kind) in kinds.iter_mut().zip(found.iter().chain(std::iter::repeat(&None))) {
        *slot = kind.map_or(0, MediaKind::raw);
    }
}

/// What the read found, as JSON `{"folders": [...], "readable": bool}` (the caller frees it):
/// every folder listed (the source's and each subfolder entered), and false when the source's
/// own folder could not be read. Null when `walk` is null.
///
/// # Safety
/// `walk` is null or a live walk.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_walk_result(
    walk: *const CmuxScreenshotsWalk,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(walk) = (unsafe { walk.as_ref() }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || {
        out(Some(
            serde_json::json!({"folders": walk.inner.folders(), "readable": walk.inner.readable()})
                .to_string(),
        ))
    })
}

#[cfg(test)]
#[path = "ffi_tests.rs"]
mod tests;
