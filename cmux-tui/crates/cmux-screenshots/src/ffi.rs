//! The C ABI of the Screenshots pane's rules for the macOS app (`include/cmux_screenshots.h`,
//! Swift module `CCmuxScreenshotsFFI`), linked into the app through cmux-app-ffi.
//!
//! Strings go in as UTF-8 bytes and a length (not NUL-terminated; invalid UTF-8 is replaced).
//! Strings come out NUL-terminated, owned by the caller, freed with `cmux_screenshots_string_free`,
//! except `cmux_screenshots_listing_path_at`, which lends a pointer valid until the listing
//! changes. Kinds: 1 image, 2 video, 3 other (0: not listed). Entry kinds: 1 file, 2 folder,
//! 3 package, anything else other. A handle is used by one thread at a time. No function unwinds
//! across the boundary.

use crate::detect::{Detector, Environment, looks_like_folder_key, sources_json};
use crate::gate::Gate;
use crate::listing::{Item, Listing};
use crate::reader::{self, Entry, EntryKind};
use crate::rule::{MediaKind, ScanRule};
use crate::{names, page};
use std::collections::HashSet;
use std::ffi::{CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_SCREENSHOTS_ABI_VERSION: u32 = 1;

/// A scan rule (a source's `rule` from `cmux_screenshots_detect`).
pub struct CmuxScreenshotsRule {
    inner: ScanRule,
}

/// A newest-first listing.
pub struct CmuxScreenshotsListing {
    inner: Listing,
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
    let strings = |key: &str| -> Vec<String> {
        value[key]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
            .unwrap_or_default()
    };
    Some(ScanRule {
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
    })
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

/// Whether the scan reads a directory entry as a subfolder, `depth` levels below the source folder.
///
/// # Safety
/// `rule` is null or a live rule; `name` is null or `name_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_screenshots_rule_enters(
    rule: *const CmuxScreenshotsRule,
    entry_kind: u32,
    hidden: bool,
    name: *const u8,
    name_len: usize,
    depth: usize,
) -> bool {
    // SAFETY: caller contract.
    let Some(rule) = (unsafe { rule.as_ref() }) else { return false };
    // SAFETY: caller contract.
    let name = unsafe { text(name, name_len) };
    guard(false, || {
        let entry = Entry {
            kind: EntryKind::from_raw(entry_kind),
            hidden,
            name: &name,
            system_kind: MediaKind::Other,
            modified: 0.0,
        };
        reader::enters(&entry, depth, &rule.inner)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    fn take(ptr: *mut c_char) -> Option<String> {
        if ptr.is_null() {
            return None;
        }
        // SAFETY: a string from this library.
        let s = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
        // SAFETY: freed once.
        unsafe { cmux_screenshots_string_free(ptr) };
        Some(s)
    }

    #[test]
    fn small_functions_answer() {
        let url = "CMUX://screenshots";
        // SAFETY: valid bytes.
        assert!(unsafe { cmux_screenshots_page_matches(url.as_ptr(), url.len()) });
        // SAFETY: null is allowed.
        assert!(!unsafe { cmux_screenshots_page_matches(std::ptr::null(), 0) });
        let key = "exportPath";
        // SAFETY: valid bytes.
        assert!(unsafe { cmux_screenshots_looks_like_folder_key(key.as_ptr(), key.len()) });
        assert_eq!(
            take(cmux_screenshots_dropped_name(2026, 11, 26, 9, 5, 3)),
            Some("Dropped Image 2026-11-26 at 09.05.03.png".into())
        );
        let (c, n) = ("a.png", " a.png ");
        // SAFETY: valid bytes.
        assert_eq!(
            take(unsafe {
                cmux_screenshots_rename_target(c.as_ptr(), c.len(), n.as_ptr(), n.len())
            }),
            None
        );
    }

    #[test]
    fn rule_handle_reads_detect_json() {
        let json = r#"{"kinds":2,"namePrefixes":["Screen Recording"],"extraImageExtensions":["SNAGX"],"depth":1,"folderPrefix":"m_"}"#;
        // SAFETY: valid bytes.
        let rule = unsafe { cmux_screenshots_rule_new(json.as_ptr(), json.len()) };
        assert!(!rule.is_null());
        let movie = "Screen Recording 1.mov";
        // SAFETY: live rule, valid bytes.
        assert_eq!(
            unsafe {
                cmux_screenshots_rule_item_kind(rule, 1, false, movie.as_ptr(), movie.len(), 2)
            },
            2
        );
        // SAFETY: as above.
        assert_eq!(
            unsafe {
                cmux_screenshots_rule_item_kind(rule, 1, true, movie.as_ptr(), movie.len(), 2)
            },
            0
        );
        let folder = "m_1";
        // SAFETY: as above.
        assert!(unsafe {
            cmux_screenshots_rule_enters(rule, 2, false, folder.as_ptr(), folder.len(), 0)
        });
        // SAFETY: as above.
        assert!(!unsafe {
            cmux_screenshots_rule_enters(rule, 2, false, folder.as_ptr(), folder.len(), 1)
        });
        // SAFETY: freed once.
        unsafe { cmux_screenshots_rule_free(rule) };
        let bad = "[]";
        // SAFETY: valid bytes.
        let none = unsafe { cmux_screenshots_rule_new(bad.as_ptr(), bad.len()) };
        // A JSON array has no fields: every field takes its default.
        assert!(!none.is_null());
        // SAFETY: freed once.
        unsafe { cmux_screenshots_rule_free(none) };
        let junk = "nope";
        // SAFETY: valid bytes.
        assert!(unsafe { cmux_screenshots_rule_new(junk.as_ptr(), junk.len()) }.is_null());
    }

    #[test]
    fn listing_handle_keeps_order_and_filters() {
        let listing = cmux_screenshots_listing_new();
        let paths = ["/s/a/Shot 10.png", "/s/a/Shot 2.png", "/s/b/Café.png"];
        let items: Vec<CmuxScreenshotsItem> = paths[..2]
            .iter()
            .map(|p| CmuxScreenshotsItem {
                path: p.as_ptr(),
                path_len: p.len(),
                kind: 1,
                size: 1,
                modified: 5.0,
            })
            .collect();
        // SAFETY: live listing, valid items.
        unsafe {
            cmux_screenshots_listing_replace(
                listing,
                b"a".as_ptr(),
                1,
                items.as_ptr(),
                items.len(),
            );
        };
        // SAFETY: live listing, valid bytes.
        unsafe {
            cmux_screenshots_listing_upsert(
                listing,
                paths[2].as_ptr(),
                paths[2].len(),
                1,
                1,
                9.0,
                b"b".as_ptr(),
                1,
            );
        };
        // SAFETY: live listing.
        assert_eq!(unsafe { cmux_screenshots_listing_count(listing) }, 3);
        let order: Vec<String> = (0..3)
            .map(|i| {
                let mut len = 0;
                // SAFETY: live listing, writable len.
                let ptr = unsafe { cmux_screenshots_listing_path_at(listing, i, &raw mut len) };
                // SAFETY: lent bytes.
                String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
                    .into_owned()
            })
            .collect();
        assert_eq!(order, ["/s/b/Café.png", "/s/a/Shot 2.png", "/s/a/Shot 10.png"]);
        // SAFETY: live listing; past the end gives null.
        assert!(
            unsafe { cmux_screenshots_listing_path_at(listing, 3, std::ptr::null_mut()) }.is_null()
        );
        let mut found = [0usize; 4];
        // SAFETY: live listing, valid bytes, writable buffer.
        let n = unsafe {
            cmux_screenshots_listing_filter(
                listing,
                b"CAFE".as_ptr(),
                4,
                std::ptr::null(),
                0,
                found.as_mut_ptr(),
                4,
            )
        };
        assert_eq!((n, found[0]), (1, 0));
        // SAFETY: as above.
        let n = unsafe {
            cmux_screenshots_listing_filter(
                listing,
                std::ptr::null(),
                0,
                b"a".as_ptr(),
                1,
                found.as_mut_ptr(),
                1,
            )
        };
        assert_eq!((n, found[0]), (2, 1));
        // SAFETY: live listing, valid bytes.
        assert_eq!(
            unsafe {
                cmux_screenshots_listing_position(listing, paths[0].as_ptr(), paths[0].len())
            },
            2
        );
        // SAFETY: as above.
        unsafe { cmux_screenshots_listing_remove(listing, paths[0].as_ptr(), paths[0].len()) };
        // SAFETY: as above.
        assert_eq!(
            unsafe {
                cmux_screenshots_listing_position(listing, paths[0].as_ptr(), paths[0].len())
            },
            -1
        );
        // SAFETY: drops source a.
        unsafe { cmux_screenshots_listing_replace(listing, b"a".as_ptr(), 1, std::ptr::null(), 0) };
        // SAFETY: live listing.
        assert_eq!(unsafe { cmux_screenshots_listing_count(listing) }, 1);
        // SAFETY: freed once.
        unsafe { cmux_screenshots_listing_free(listing) };
    }

    #[test]
    fn newest_picture_and_gate() {
        let names = ["a.png", "b.mov", "c.png"];
        let entries: Vec<CmuxScreenshotsEntry> = names
            .iter()
            .zip([(1, 1.0), (2, 9.0), (1, 3.0)])
            .map(|(n, (k, m))| CmuxScreenshotsEntry {
                kind: 1,
                hidden: false,
                name: n.as_ptr(),
                name_len: n.len(),
                system_kind: k,
                modified: m,
            })
            .collect();
        // SAFETY: valid entries.
        assert_eq!(unsafe { cmux_screenshots_newest_picture(entries.as_ptr(), entries.len()) }, 2);
        // SAFETY: null allowed.
        assert_eq!(unsafe { cmux_screenshots_newest_picture(std::ptr::null(), 0) }, -1);
        let gate = cmux_screenshots_gate_new();
        // SAFETY: live gate, valid bytes.
        unsafe {
            assert!(!cmux_screenshots_gate_may_detect(gate));
            assert!(cmux_screenshots_gate_starts_when_shown(gate, b"p".as_ptr(), 1, true));
            cmux_screenshots_gate_unlock(gate, b"p".as_ptr(), 1);
            assert!(cmux_screenshots_gate_may_detect(gate));
            assert!(cmux_screenshots_gate_is_unlocked(gate, b"p".as_ptr(), 1));
            assert!(!cmux_screenshots_gate_starts_when_shown(gate, b"p".as_ptr(), 1, true));
            cmux_screenshots_gate_free(gate);
        }
    }

    /// A C-style environment: every folder below `/mac/` exists, one preference is set.
    unsafe extern "C" fn pref(
        _: *mut c_void,
        d: *const u8,
        dl: usize,
        k: *const u8,
        kl: usize,
        r: *mut CmuxScreenshotsReply,
    ) {
        // SAFETY: the library passes readable strings.
        let (d, k) = unsafe { (text(d, dl), text(k, kl)) };
        if d == "com.apple.screencapture" && k == "location" {
            let v = "~/Shots";
            // SAFETY: the reply we were given.
            unsafe { cmux_screenshots_reply_set(r, v.as_ptr(), v.len()) };
        }
    }

    unsafe extern "C" fn is_dir(_: *mut c_void, p: *const u8, pl: usize) -> bool {
        // SAFETY: the library passes readable strings.
        let p = unsafe { text(p, pl) };
        p == "/mac/home/Shots" || p == "/mac/tmp/TemporaryItems" || p == "/mac/home/Mine"
    }

    #[test]
    fn detect_calls_back_and_returns_json() {
        let env = CmuxScreenshotsEnvironment {
            context: std::ptr::null_mut(),
            preference: Some(pref),
            string_preferences: None,
            text: None,
            is_directory: Some(is_dir),
            real_path: None,
        };
        let (home, tmp, extra) = ("/mac/home", "/mac/tmp", r#"["~/Mine"]"#);
        // SAFETY: a live environment and valid bytes.
        let json = take(unsafe {
            cmux_screenshots_detect(
                &raw const env,
                home.as_ptr(),
                home.len(),
                tmp.as_ptr(),
                tmp.len(),
                true,
                extra.as_ptr(),
                extra.len(),
            )
        })
        .expect("json");
        let value: serde_json::Value = serde_json::from_str(&json).expect("valid json");
        let ids: Vec<&str> =
            value.as_array().expect("array").iter().filter_map(|s| s["id"].as_str()).collect();
        assert_eq!(ids, ["system", "system.preview", "custom./mac/home/Mine"]);
        assert_eq!(value[0]["folder"], "/mac/home/Shots");
        // SAFETY: as above.
        assert_eq!(
            take(unsafe {
                cmux_screenshots_system_folder(&raw const env, home.as_ptr(), home.len())
            })
            .as_deref(),
            Some("/mac/home/Shots")
        );
        // SAFETY: null env.
        assert!(
            unsafe {
                cmux_screenshots_detect(
                    std::ptr::null(),
                    home.as_ptr(),
                    0,
                    tmp.as_ptr(),
                    0,
                    true,
                    std::ptr::null(),
                    0,
                )
            }
            .is_null()
        );
    }
}
