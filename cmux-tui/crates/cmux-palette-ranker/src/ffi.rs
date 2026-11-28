//! The C ABI of the palette ranker (`include/cmux_palette_ranker.h`), linked into the macOS app
//! through cmux-app-ffi.
//!
//! A host creates one ranker, installs each entry snapshot once per version, then sends one
//! JSON request per keystroke. The response (ranked sections JSON, or an error message) stays
//! owned by the ranker until its next call or until it is freed.

use crate::{Entry, Frecency, RankRequest, Ranker};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const ABI_VERSION: u32 = 2;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_NOT_INSTALLED: i32 = -3;
pub const ERR_PANIC: i32 = -4;

/// The opaque ranker handle.
pub struct CmuxPaletteRanker {
    ranker: Ranker,
    response: Vec<u8>,
}

unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the C caller guarantees `len` readable bytes at `ptr`.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_palette_ranker_abi_version() -> u32 {
    ABI_VERSION
}

/// Creates a ranker. Free it with [`cmux_palette_ranker_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_palette_ranker_new() -> *mut CmuxPaletteRanker {
    Box::into_raw(Box::new(CmuxPaletteRanker { ranker: Ranker::new(), response: Vec::new() }))
}

/// Frees a ranker from [`cmux_palette_ranker_new`]. Null is ignored.
///
/// # Safety
///
/// `ranker` is null or a live handle from `cmux_palette_ranker_new`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_free(ranker: *mut CmuxPaletteRanker) {
    if !ranker.is_null() {
        // SAFETY: the caller hands back a handle from `cmux_palette_ranker_new` once.
        drop(unsafe { Box::from_raw(ranker) });
    }
}

/// Installs a JSON array of entries for `version`.
///
/// # Safety
///
/// `ranker` is a live handle; `entries` points to `entries_len` readable bytes (or is null with
/// length 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_install(
    ranker: *mut CmuxPaletteRanker,
    version: i64,
    entries: *const u8,
    entries_len: usize,
) -> i32 {
    if ranker.is_null() {
        return ERR_NULL;
    }
    let Some(entries) = (unsafe { input(entries, entries_len) }) else { return ERR_NULL };
    // SAFETY: a live handle, used by one caller at a time.
    let handle = unsafe { &mut *ranker };
    let result =
        catch_unwind(AssertUnwindSafe(|| match serde_json::from_slice::<Vec<Entry>>(entries) {
            Ok(entries) => {
                handle.ranker.install(version, entries);
                OK
            }
            Err(_) => ERR_INVALID,
        }));
    result.unwrap_or(ERR_PANIC)
}

/// Installs a JSON usage history (`PaletteFrecency`: entries, picks, hidden keys) for
/// `revision`; a request naming that `historyRevision` may omit `frecency`.
///
/// # Safety
///
/// `ranker` is a live handle; `history` points to `history_len` readable bytes (or is null with
/// length 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_install_history(
    ranker: *mut CmuxPaletteRanker,
    revision: i64,
    history: *const u8,
    history_len: usize,
) -> i32 {
    if ranker.is_null() {
        return ERR_NULL;
    }
    let Some(history) = (unsafe { input(history, history_len) }) else { return ERR_NULL };
    // SAFETY: a live handle, used by one caller at a time.
    let handle = unsafe { &mut *ranker };
    let result =
        catch_unwind(AssertUnwindSafe(|| match serde_json::from_slice::<Frecency>(history) {
            Ok(history) => {
                handle.ranker.install_history(revision, history);
                OK
            }
            Err(_) => ERR_INVALID,
        }));
    result.unwrap_or(ERR_PANIC)
}

/// Ranks one JSON request. On `OK` the response is the ranked sections JSON; on an error it is a
/// message, except `ERR_NULL`, which leaves a null response of length 0 (or writes nothing when
/// an out pointer is null). `*response`/`*response_len` stay valid until the next call on this
/// ranker. A handle is not thread-safe: one caller at a time.
///
/// # Safety
///
/// `ranker` is a live handle; `request` points to `request_len` readable bytes; `response` and
/// `response_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_rank(
    ranker: *mut CmuxPaletteRanker,
    request: *const u8,
    request_len: usize,
    response: *mut *const u8,
    response_len: *mut usize,
) -> i32 {
    if response.is_null() || response_len.is_null() {
        return ERR_NULL;
    }
    // SAFETY: both out pointers were checked non-null and are writable by the caller.
    unsafe {
        *response = std::ptr::null();
        *response_len = 0;
    }
    if ranker.is_null() {
        return ERR_NULL;
    }
    let Some(request) = (unsafe { input(request, request_len) }) else { return ERR_NULL };
    // SAFETY: a live handle, used by one caller at a time.
    let handle = unsafe { &mut *ranker };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let request: RankRequest = match serde_json::from_slice(request) {
            Ok(request) => request,
            Err(error) => return (ERR_INVALID, error.to_string().into_bytes()),
        };
        if request.operation == "filter" {
            // The query's filter tokens alone (`crate::filter`): for the host's own searches
            // beside the ranker (agent chats), so they keep and drop the same sections.
            let names = request.section_names.as_deref().unwrap_or_default();
            let parsed = crate::filter::parse(request.query.as_deref().unwrap_or(""), names);
            return match serde_json::to_vec(&parsed) {
                Ok(bytes) => (OK, bytes),
                Err(error) => (ERR_INVALID, error.to_string().into_bytes()),
            };
        }
        match handle.ranker.rank(&request) {
            Ok(sections) => match serde_json::to_vec(&sections) {
                Ok(bytes) => (OK, bytes),
                Err(error) => (ERR_INVALID, error.to_string().into_bytes()),
            },
            Err(error) => (ERR_NOT_INSTALLED, error.to_string().into_bytes()),
        }
    }));
    let (code, bytes) = result.unwrap_or_else(|_| (ERR_PANIC, b"palette ranker panicked".to_vec()));
    handle.response = bytes;
    // SAFETY: both out pointers were checked non-null and are writable by the caller.
    unsafe {
        *response = handle.response.as_ptr();
        *response_len = handle.response.len();
    }
    code
}

/// Search All Windows' corpus handle (`crate::global_search`).
pub struct CmuxGlobalSearch {
    corpus: crate::global_search::Corpus,
    response: Vec<u8>,
}

/// Creates a corpus of tabs titled by a JSON array of strings, none of their text read yet.
/// Null on invalid JSON. Free it with [`cmux_global_search_free`].
///
/// # Safety
///
/// `titles` points to `titles_len` readable bytes (or is null with length 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_global_search_new(
    titles: *const u8,
    titles_len: usize,
) -> *mut CmuxGlobalSearch {
    let Some(titles) = (unsafe { input(titles, titles_len) }) else { return std::ptr::null_mut() };
    let parsed = catch_unwind(|| serde_json::from_slice::<Vec<String>>(titles).ok());
    match parsed {
        Ok(Some(titles)) => Box::into_raw(Box::new(CmuxGlobalSearch {
            corpus: crate::global_search::Corpus::new(&titles),
            response: Vec::new(),
        })),
        _ => std::ptr::null_mut(),
    }
}

/// Frees a corpus from [`cmux_global_search_new`]. Null is ignored.
///
/// # Safety
///
/// `search` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_global_search_free(search: *mut CmuxGlobalSearch) {
    if !search.is_null() {
        // SAFETY: the caller hands back a handle from `cmux_global_search_new` once.
        drop(unsafe { Box::from_raw(search) });
    }
}

/// Puts tab `document`'s texts in place: a JSON array of texts, each an array of lines (the
/// transcript first). `ERR_INVALID` on bad JSON or no such tab.
///
/// # Safety
///
/// `search` is a live handle; `texts` points to `texts_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_global_search_apply(
    search: *mut CmuxGlobalSearch,
    document: usize,
    texts: *const u8,
    texts_len: usize,
) -> i32 {
    if search.is_null() {
        return ERR_NULL;
    }
    let Some(texts) = (unsafe { input(texts, texts_len) }) else { return ERR_NULL };
    // SAFETY: a live handle, used by one caller at a time.
    let handle = unsafe { &mut *search };
    let result = catch_unwind(AssertUnwindSafe(|| {
        match serde_json::from_slice::<Vec<Vec<String>>>(texts) {
            Ok(texts) => {
                let texts =
                    texts.iter().map(|lines| crate::global_search::Text::new(lines)).collect();
                if handle.corpus.apply(document, texts) { OK } else { ERR_INVALID }
            }
            Err(_) => ERR_INVALID,
        }
    }));
    result.unwrap_or(ERR_PANIC)
}

/// The tabs matching `query` (UTF-8), at most `limit`, as JSON
/// `{"hits": [{"document", "text", "line", "count", "titleMatched"}], "limited", "linesScanned"}`.
/// `*response` stays valid until the next call on this handle; on an error it is a message.
///
/// # Safety
///
/// `search` is a live handle; `query` points to `query_len` readable bytes; `response` and
/// `response_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_global_search_hits(
    search: *mut CmuxGlobalSearch,
    query: *const u8,
    query_len: usize,
    limit: usize,
    response: *mut *const u8,
    response_len: *mut usize,
) -> i32 {
    if response.is_null() || response_len.is_null() {
        return ERR_NULL;
    }
    // SAFETY: both out pointers were checked non-null and are writable by the caller.
    unsafe {
        *response = std::ptr::null();
        *response_len = 0;
    }
    if search.is_null() {
        return ERR_NULL;
    }
    let Some(query) = (unsafe { input(query, query_len) }) else { return ERR_NULL };
    // SAFETY: a live handle, used by one caller at a time.
    let handle = unsafe { &mut *search };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let Ok(query) = std::str::from_utf8(query) else {
            return (ERR_INVALID, b"the query is not UTF-8".to_vec());
        };
        let answer = handle.corpus.hits(&crate::global_search::words(query), limit);
        match serde_json::to_vec(&answer) {
            Ok(bytes) => (OK, bytes),
            Err(error) => (ERR_INVALID, error.to_string().into_bytes()),
        }
    }));
    let (code, bytes) = result.unwrap_or_else(|_| (ERR_PANIC, b"global search panicked".to_vec()));
    handle.response = bytes;
    // SAFETY: both out pointers were checked non-null and are writable by the caller.
    unsafe {
        *response = handle.response.as_ptr();
        *response_len = handle.response.len();
    }
    code
}
