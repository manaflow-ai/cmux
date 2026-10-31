//! The C ABI (`include/cmux_chats_mirror.h`), linked into the macOS app through cmux-app-ffi.
//!
//! A feed is locked inside, so a host may call it from any thread: the main thread applies
//! batches while a background reader takes the project list. Readers get owned snapshots.

use crate::chat::Chat;
use crate::feed::{Feed, Line};
use crate::index::Index;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, MutexGuard, PoisonError};

pub const ABI_VERSION: u32 = 1;
pub const CHANGED: u32 = 1;
pub const LAGGED: u32 = 2;
pub const PAGE: u32 = 4;
pub const INDEX_CHANGED: u32 = 8;
pub const READY: u32 = 1;
pub const ENABLED: u32 = 2;

/// The opaque feed handle.
pub struct CmuxChatsFeed {
    feed: Mutex<Feed>,
}

impl CmuxChatsFeed {
    fn lock(&self) -> MutexGuard<'_, Feed> {
        // A panic inside a call is caught at the boundary; the feed's data stays usable.
        self.feed.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// One parsed line, owned by the host until it is applied or freed.
pub struct CmuxChatsLine {
    line: Line,
}

/// UTF-8 text; `ptr` is null when the field is absent.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxChatsText {
    pub ptr: *const u8,
    pub len: usize,
}

impl CmuxChatsText {
    const ABSENT: CmuxChatsText = CmuxChatsText { ptr: std::ptr::null(), len: 0 };

    fn of(text: &str) -> Self {
        // An empty str's pointer is dangling but non-null, which marks "present, empty".
        CmuxChatsText { ptr: text.as_ptr(), len: text.len() }
    }

    fn optional(text: Option<&str>) -> Self {
        text.map_or(Self::ABSENT, Self::of)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxChatsRow {
    pub key: CmuxChatsText,
    pub session_id: CmuxChatsText,
    pub harness: CmuxChatsText,
    pub title: CmuxChatsText,
    pub cwd: CmuxChatsText,
    pub source_path: CmuxChatsText,
    pub brand: CmuxChatsText,
    pub attention: CmuxChatsText,
    pub preview: CmuxChatsText,
    pub parent: CmuxChatsText,
    pub accounts: *const CmuxChatsText,
    pub accounts_len: usize,
    pub roots: *const CmuxChatsText,
    pub roots_len: usize,
    pub created_ms: f64,
    pub updated_ms: f64,
    pub message_count: i64,
    pub has_created: u8,
    pub has_message_count: u8,
}

/// An owned snapshot of rows: the chats it points into, their list texts, and the rows.
pub struct CmuxChatsRows {
    _chats: Vec<Chat>,
    _lists: Vec<Vec<CmuxChatsText>>,
    rows: Vec<CmuxChatsRow>,
}

impl CmuxChatsRows {
    fn of(chats: Vec<Chat>) -> Box<Self> {
        let mut lists = Vec::with_capacity(chats.len().saturating_mul(2));
        let mut rows = Vec::with_capacity(chats.len());
        for chat in &chats {
            let accounts: Vec<CmuxChatsText> =
                chat.accounts.iter().map(|text| CmuxChatsText::of(text)).collect();
            let roots: Vec<CmuxChatsText> =
                chat.roots.iter().map(|text| CmuxChatsText::of(text)).collect();
            rows.push(CmuxChatsRow {
                key: CmuxChatsText::of(&chat.key),
                session_id: CmuxChatsText::of(&chat.session_id),
                harness: CmuxChatsText::of(&chat.harness),
                title: CmuxChatsText::optional(chat.title.as_deref()),
                cwd: CmuxChatsText::optional(chat.cwd.as_deref()),
                source_path: CmuxChatsText::optional(chat.source_path.as_deref()),
                brand: CmuxChatsText::optional(chat.brand.as_deref()),
                attention: CmuxChatsText::optional(chat.attention.as_deref()),
                preview: CmuxChatsText::optional(chat.preview.as_deref()),
                parent: CmuxChatsText::optional(chat.parent.as_deref()),
                // A Vec's heap buffer does not move when the Vec itself is moved into `lists`.
                accounts: accounts.as_ptr(),
                accounts_len: accounts.len(),
                roots: roots.as_ptr(),
                roots_len: roots.len(),
                created_ms: chat.created_ms.unwrap_or(0.0),
                updated_ms: chat.updated_ms,
                message_count: chat.message_count.unwrap_or(0),
                has_created: u8::from(chat.created_ms.is_some()),
                has_message_count: u8::from(chat.message_count.is_some()),
            });
            lists.push(accounts);
            lists.push(roots);
        }
        Box::new(CmuxChatsRows { _chats: chats, _lists: lists, rows })
    }
}

/// Owned bytes (a JSON answer).
pub struct CmuxChatsBytes {
    bytes: Vec<u8>,
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

fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

unsafe fn feed_ref<'a>(feed: *const CmuxChatsFeed) -> Option<&'a CmuxChatsFeed> {
    // SAFETY: the caller passes null or a live handle from `cmux_chats_feed_new`.
    unsafe { feed.as_ref() }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_chats_mirror_abi_version() -> u32 {
    ABI_VERSION
}

/// Creates a feed. Free it with [`cmux_chats_feed_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_chats_feed_new() -> *mut CmuxChatsFeed {
    Box::into_raw(Box::new(CmuxChatsFeed { feed: Mutex::new(Feed::new()) }))
}

/// # Safety
///
/// `feed` is null or a live handle from `cmux_chats_feed_new`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_free(feed: *mut CmuxChatsFeed) {
    if !feed.is_null() {
        // SAFETY: the caller hands back a handle from `cmux_chats_feed_new` once.
        drop(unsafe { Box::from_raw(feed) });
    }
}

/// # Safety
///
/// `bytes` points to `len` readable bytes (or is null with length 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_line_parse(bytes: *const u8, len: usize) -> *mut CmuxChatsLine {
    let Some(bytes) = (unsafe { input(bytes, len) }) else { return std::ptr::null_mut() };
    guarded(std::ptr::null_mut(), || match Line::parse(bytes) {
        Some(line) => Box::into_raw(Box::new(CmuxChatsLine { line })),
        None => std::ptr::null_mut(),
    })
}

/// # Safety
///
/// `line` is null or a line from `cmux_chats_line_parse` that was never applied or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_line_free(line: *mut CmuxChatsLine) {
    if !line.is_null() {
        // SAFETY: the caller hands back an unapplied line once.
        drop(unsafe { Box::from_raw(line) });
    }
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_connection_started(feed: *mut CmuxChatsFeed) {
    if let Some(feed) = unsafe { feed_ref(feed) } {
        guarded((), || feed.lock().connection_started());
    }
}

/// Applies `count` lines in order, taking ownership of each (null entries are skipped).
///
/// # Safety
///
/// `feed` is null or a live handle; `lines` points to `count` entries, each null or an
/// unapplied line from `cmux_chats_line_parse`, none used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_apply(
    feed: *mut CmuxChatsFeed,
    lines: *const *mut CmuxChatsLine,
    count: usize,
) -> u32 {
    let owned: Vec<Line> = if lines.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: `count` readable entries; each non-null one is handed over once.
        unsafe { std::slice::from_raw_parts(lines, count) }
            .iter()
            .filter(|line| !line.is_null())
            .map(|line| unsafe { Box::from_raw(*line) }.line)
            .collect()
    };
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return 0 };
    guarded(0, || {
        let outcome = feed.lock().apply(owned);
        (if outcome.changed { CHANGED } else { 0 })
            | (if outcome.lagged { LAGGED } else { 0 })
            | (if outcome.page { PAGE } else { 0 })
            | (if outcome.index_changed { INDEX_CHANGED } else { 0 })
    })
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_want_list(feed: *mut CmuxChatsFeed) -> i32 {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return 0 };
    guarded(0, || i32::from(feed.lock().want_list()))
}

/// # Safety
///
/// `feed` is null or a live handle; `json` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_load(
    feed: *mut CmuxChatsFeed,
    json: *const u8,
    len: usize,
) -> i32 {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return -1 };
    let Some(json) = (unsafe { input(json, len) }) else { return -1 };
    guarded(-1, || {
        // A result object is a page line's `result`: parse it as the watch's own page.
        let mut line = b"{\"id\":2,\"result\":".to_vec();
        line.extend_from_slice(json);
        line.push(b'}');
        match Line::parse(&line) {
            Some(Line::Page { index, .. }) => {
                feed.lock().load(index);
                0
            }
            _ => -2,
        }
    })
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_status(feed: *const CmuxChatsFeed) -> u32 {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return 0 };
    guarded(0, || {
        let feed = feed.lock();
        (if feed.is_ready() { READY } else { 0 }) | (if feed.is_enabled() { ENABLED } else { 0 })
    })
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_count(feed: *const CmuxChatsFeed) -> usize {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return 0 };
    guarded(0, || feed.lock().index().len())
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_generation(feed: *const CmuxChatsFeed) -> u64 {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return 0 };
    guarded(0, || feed.lock().generation())
}

fn rows(feed: &CmuxChatsFeed, pick: impl FnOnce(&Index) -> Vec<Chat>) -> *mut CmuxChatsRows {
    guarded(std::ptr::null_mut(), || {
        let chats = pick(feed.lock().index());
        Box::into_raw(CmuxChatsRows::of(chats))
    })
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_listed(
    feed: *const CmuxChatsFeed,
    offset: usize,
    limit: usize,
) -> *mut CmuxChatsRows {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return std::ptr::null_mut() };
    rows(feed, |index| index.listed().skip(offset).take(limit).cloned().collect())
}

/// # Safety
///
/// `feed` is null or a live handle; `key` points to `key_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_chat(
    feed: *const CmuxChatsFeed,
    key: *const u8,
    key_len: usize,
) -> *mut CmuxChatsRows {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return std::ptr::null_mut() };
    let Some(key) = (unsafe { input(key, key_len) }).and_then(|key| std::str::from_utf8(key).ok())
    else {
        return std::ptr::null_mut();
    };
    rows(feed, |index| index.get(key).cloned().into_iter().collect())
}

/// # Safety
///
/// `feed` is null or a live handle; `session` points to `session_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_by_session(
    feed: *const CmuxChatsFeed,
    session: *const u8,
    session_len: usize,
) -> *mut CmuxChatsRows {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return std::ptr::null_mut() };
    let Some(session) = (unsafe { input(session, session_len) })
        .and_then(|session| std::str::from_utf8(session).ok())
    else {
        return std::ptr::null_mut();
    };
    rows(feed, |index| index.by_session(session).cloned().into_iter().collect())
}

/// # Safety
///
/// `feed` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_feed_projects(
    feed: *const CmuxChatsFeed,
) -> *mut CmuxChatsBytes {
    let Some(feed) = (unsafe { feed_ref(feed) }) else { return std::ptr::null_mut() };
    guarded(std::ptr::null_mut(), || {
        let bytes = serde_json::to_vec(&feed.lock().index().projects()).unwrap_or_default();
        Box::into_raw(Box::new(CmuxChatsBytes { bytes }))
    })
}

/// # Safety
///
/// `rows` is null or a live snapshot; `count` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_rows_items(
    rows: *const CmuxChatsRows,
    count: *mut usize,
) -> *const CmuxChatsRow {
    // SAFETY: null or a live snapshot from this module.
    let rows = unsafe { rows.as_ref() };
    let (items, len) =
        rows.map_or((std::ptr::null(), 0), |rows| (rows.rows.as_ptr(), rows.rows.len()));
    if !count.is_null() {
        // SAFETY: checked non-null; the caller passes a writable pointer.
        unsafe { *count = len };
    }
    items
}

/// # Safety
///
/// `rows` is null or a live snapshot, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_rows_free(rows: *mut CmuxChatsRows) {
    if !rows.is_null() {
        // SAFETY: the caller hands back a snapshot once.
        drop(unsafe { Box::from_raw(rows) });
    }
}

/// # Safety
///
/// `bytes` is null or a live buffer; `len` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_bytes_data(
    bytes: *const CmuxChatsBytes,
    len: *mut usize,
) -> *const u8 {
    // SAFETY: null or a live buffer from this module.
    let bytes = unsafe { bytes.as_ref() };
    let (data, size) =
        bytes.map_or((std::ptr::null(), 0), |bytes| (bytes.bytes.as_ptr(), bytes.bytes.len()));
    if !len.is_null() {
        // SAFETY: checked non-null; the caller passes a writable pointer.
        unsafe { *len = size };
    }
    data
}

/// # Safety
///
/// `bytes` is null or a live buffer, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chats_bytes_free(bytes: *mut CmuxChatsBytes) {
    if !bytes.is_null() {
        // SAFETY: the caller hands back a buffer once.
        drop(unsafe { Box::from_raw(bytes) });
    }
}
