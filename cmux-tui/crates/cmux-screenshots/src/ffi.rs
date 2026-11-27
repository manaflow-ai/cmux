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
use crate::pane::{ChangePlan, EntryAction, Pane, PaneSource};
use crate::reader::{self, Entry, EntryKind};
use crate::rule::{MediaKind, ScanRule};
use crate::{names, page};
use std::collections::HashSet;
use std::ffi::{CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_SCREENSHOTS_ABI_VERSION: u32 = 4;

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
    Some(rule_from_value(&value))
}

/// A rule from its JSON object; a missing field takes the default.
fn rule_from_value(value: &serde_json::Value) -> ScanRule {
    let strings = |key: &str| -> Vec<String> {
        value
            .get(key)
            .and_then(serde_json::Value::as_array)
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
            .unwrap_or_default()
    };
    ScanRule {
        kinds: value
            .get("kinds")
            .and_then(serde_json::Value::as_u64)
            .and_then(|k| u32::try_from(k).ok())
            .unwrap_or(crate::rule::IMAGES_AND_VIDEOS),
        extra_image_extensions: strings("extraImageExtensions")
            .into_iter()
            .map(|e| e.to_lowercase())
            .collect(),
        name_prefixes: strings("namePrefixes"),
        depth: value
            .get("depth")
            .and_then(serde_json::Value::as_u64)
            .and_then(|d| usize::try_from(d).ok())
            .unwrap_or(0),
        folder_prefix: value
            .get("folderPrefix")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
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

    #[test]
    fn pane_round_trip() {
        let pane = cmux_screenshots_pane_new(true);
        let sources = r#"[{"id":"d","label":"Desktop","folder":"/u/Desktop","acceptsDrops":false,"rule":{"namePrefixes":["Screenshot"]}},
            {"id":"s","label":"Shots","folder":"/u/Shots","acceptsDrops":true,"rule":{"depth":1}},
            {"label":"no id","folder":"/x"}]"#;
        // SAFETY: live pane, valid bytes.
        let plan = take(unsafe {
            cmux_screenshots_pane_set_sources(pane, sources.as_ptr(), sources.len())
        });
        assert_eq!(plan.as_deref(), Some(r#"{"changed":true,"read":["d","s"],"removed":[]}"#));
        // SAFETY: live pane, valid bytes.
        let again = take(unsafe {
            cmux_screenshots_pane_set_sources(pane, sources.as_ptr(), sources.len())
        });
        assert_eq!(again.as_deref(), Some(r#"{"changed":false,"read":[],"removed":[]}"#));
        // SAFETY: live pane.
        assert!(!unsafe { cmux_screenshots_pane_start(pane) });
        let folders = r#"["/u/Shots","/u/Shots/a"]"#;
        // SAFETY: live pane, valid bytes.
        assert!(unsafe {
            cmux_screenshots_pane_read_done(
                pane,
                b"s".as_ptr(),
                1,
                true,
                folders.as_ptr(),
                folders.len(),
            )
        });
        // SAFETY: live pane, valid bytes.
        assert!(unsafe {
            cmux_screenshots_pane_read_done(pane, b"d".as_ptr(), 1, false, b"[]".as_ptr(), 2)
        });
        // SAFETY: live pane, valid bytes.
        assert!(!unsafe {
            cmux_screenshots_pane_read_done(pane, b"gone".as_ptr(), 4, true, std::ptr::null(), 0)
        });
        // SAFETY: live pane.
        let state = take(unsafe { cmux_screenshots_pane_state(pane) });
        assert_eq!(
            state.as_deref(),
            Some(
                r#"{"accessMissing":false,"listing":true,"unreadable":["d"],"watched":["/u/Desktop","/u/Shots","/u/Shots/a"]}"#
            )
        );
        // SAFETY: live pane, valid bytes.
        assert_eq!(
            take(unsafe { cmux_screenshots_pane_drop_source(pane, b"d".as_ptr(), 1) }).as_deref(),
            Some("s")
        );
        // SAFETY: live pane, null selection.
        assert_eq!(
            take(unsafe { cmux_screenshots_pane_drop_source(pane, std::ptr::null(), 0) })
                .as_deref(),
            Some("s")
        );
        let path = "/u/Shots/a/x.png";
        // SAFETY: live pane, valid bytes.
        assert_eq!(
            take(unsafe {
                cmux_screenshots_pane_source_containing(pane, path.as_ptr(), path.len())
            })
            .as_deref(),
            Some("s")
        );
        // SAFETY: live pane, valid bytes.
        assert!(
            unsafe { cmux_screenshots_pane_source_containing(pane, b"/elsewhere".as_ptr(), 10) }
                .is_null()
        );
        let folder = "/u/Shots";
        let names = r#"["a","x.png","x.png"]"#;
        // SAFETY: live pane, valid bytes.
        let look = take(unsafe {
            cmux_screenshots_pane_change(
                pane,
                folder.as_ptr(),
                folder.len(),
                names.as_ptr(),
                names.len(),
            )
        });
        assert_eq!(
            look.as_deref(),
            Some(r#"{"paths":["/u/Shots/x.png"],"relist":true,"source":"s"}"#)
        );
        // SAFETY: live pane, valid bytes, null names.
        let rescan = take(unsafe {
            cmux_screenshots_pane_change(pane, folder.as_ptr(), folder.len(), std::ptr::null(), 0)
        });
        assert_eq!(rescan.as_deref(), Some(r#"{"rescan":"s"}"#));
        let file = "/u/Shots/x.png";
        let png = CmuxScreenshotsEntry {
            kind: 1,
            hidden: false,
            name: b"x.png".as_ptr(),
            name_len: 5,
            system_kind: 1,
            modified: 1.0,
        };
        let action = |entry: *const CmuxScreenshotsEntry| {
            // SAFETY: live pane, valid bytes, entry null or live.
            unsafe {
                cmux_screenshots_pane_entry_action(
                    pane,
                    b"s".as_ptr(),
                    1,
                    folder.as_ptr(),
                    folder.len(),
                    file.as_ptr(),
                    file.len(),
                    entry,
                )
            }
        };
        assert_eq!(action(&raw const png), 2);
        assert_eq!(action(std::ptr::null()), 0);
        let sub = CmuxScreenshotsEntry { kind: 2, name: b"b".as_ptr(), name_len: 1, ..png };
        assert_eq!(action(&raw const sub), 1);
        // SAFETY: live pane.
        unsafe { cmux_screenshots_pane_pause(pane) };
        // SAFETY: live pane.
        let paused = take(unsafe { cmux_screenshots_pane_state(pane) });
        assert_eq!(
            paused.as_deref(),
            Some(r#"{"accessMissing":false,"listing":false,"unreadable":[],"watched":null}"#)
        );
        // SAFETY: live pane, freed once; null does nothing.
        unsafe {
            cmux_screenshots_pane_free(pane);
            cmux_screenshots_pane_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn walk_round_trip() {
        let json = r#"{"depth":1,"folderPrefix":"NSIRD_"}"#;
        // SAFETY: valid bytes.
        let rule = unsafe { cmux_screenshots_rule_new(json.as_ptr(), json.len()) };
        // SAFETY: live rule, valid bytes.
        let walk = unsafe { cmux_screenshots_walk_new(rule, b"/s".as_ptr(), 2) };
        // SAFETY: freed once; the walk holds its own copy.
        unsafe { cmux_screenshots_rule_free(rule) };
        let raw = |name: &'static [u8], kind: u32, system_kind: u32| CmuxScreenshotsEntry {
            kind,
            hidden: false,
            name: name.as_ptr(),
            name_len: name.len(),
            system_kind,
            modified: 0.0,
        };
        // SAFETY: live walk.
        assert_eq!(take(unsafe { cmux_screenshots_walk_next(walk) }).as_deref(), Some("/s"));
        let top = [raw(b"NSIRD_a", 2, 3), raw(b"top.png", 1, 1), raw(b"notes.txt", 1, 3)];
        let mut kinds = [9u32; 3];
        // SAFETY: live walk, 3 entries, 3 slots.
        unsafe {
            cmux_screenshots_walk_listed(walk, true, top.as_ptr(), top.len(), kinds.as_mut_ptr())
        };
        assert_eq!(kinds, [0, 1, 0]);
        // SAFETY: live walk.
        assert_eq!(
            take(unsafe { cmux_screenshots_walk_next(walk) }).as_deref(),
            Some("/s/NSIRD_a")
        );
        // SAFETY: live walk; an unreadable subfolder has no entries.
        unsafe {
            cmux_screenshots_walk_listed(walk, false, std::ptr::null(), 0, std::ptr::null_mut())
        };
        // SAFETY: live walk.
        assert!(unsafe { cmux_screenshots_walk_next(walk) }.is_null());
        // SAFETY: live walk.
        assert_eq!(
            take(unsafe { cmux_screenshots_walk_result(walk) }).as_deref(),
            Some(r#"{"folders":["/s"],"readable":true}"#)
        );
        // SAFETY: live walk, freed once; null does nothing.
        unsafe {
            cmux_screenshots_walk_free(walk);
            cmux_screenshots_walk_free(std::ptr::null_mut());
        }
    }
}
