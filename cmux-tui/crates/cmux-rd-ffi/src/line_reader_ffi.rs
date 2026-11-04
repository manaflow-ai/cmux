//! C ABI of the app line reader (`CmuxRdLineReader` in `include/cmux_rd_ffi.h`):
//! the stdout bytes of `cmux rd serve|connect` in, typed lines out
//! (`cmux_rd_proto::app_line::AppLine`, the type the host prints). The app
//! no longer decodes the lines itself. Same rules as the other handles: no
//! I/O, no threads, panics caught, a panic poisons only that reader, and the
//! pointers in a `CmuxRdLine` stay valid until the next call on the same reader.

use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_proto::app_line::{AppLine, LineSplitter};

use crate::{CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in};

/// Fields a `CmuxRdLine` holds (`CMUX_RD_LINE_*`, bits of `CmuxRdLine::fields`).
pub const CMUX_RD_LINE_KEY: u32 = 1 << 0;
pub const CMUX_RD_LINE_CANDIDATE: u32 = 1 << 1;
pub const CMUX_RD_LINE_CANDIDATES_DONE: u32 = 1 << 2;
pub const CMUX_RD_LINE_CONNECTED: u32 = 1 << 3;
pub const CMUX_RD_LINE_LISTENING: u32 = 1 << 4;
pub const CMUX_RD_LINE_ENDED: u32 = 1 << 5;
pub const CMUX_RD_LINE_PATH: u32 = 1 << 6;
pub const CMUX_RD_LINE_PATH_KIND: u32 = 1 << 7;
pub const CMUX_RD_LINE_PATH_RTT: u32 = 1 << 8;
pub const CMUX_RD_LINE_DISPLAYS: u32 = 1 << 9;
pub const CMUX_RD_LINE_CURRENT: u32 = 1 << 10;
pub const CMUX_RD_LINE_ERROR: u32 = 1 << 11;

/// One typed line (`CmuxRdLine`). A text field is UTF-8 bytes, not
/// NUL-terminated; it and `displays` point into the reader and stay valid
/// until the next call on it. A field whose bit is not in `fields` is empty.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxRdLine {
    pub fields: u32,
    pub key: *const u8,
    pub key_len: usize,
    pub candidate: *const u8,
    pub candidate_len: usize,
    pub ended: *const u8,
    pub ended_len: usize,
    pub error: *const u8,
    pub error_len: usize,
    pub path_kind: *const u8,
    pub path_kind_len: usize,
    pub path_rtt_ms: f64,
    /// `display_count` pairs: width, height, width, height, ...
    pub displays: *const u32,
    pub display_count: usize,
    pub current: u64,
}

impl Default for CmuxRdLine {
    fn default() -> Self {
        Self {
            fields: 0,
            key: std::ptr::null(),
            key_len: 0,
            candidate: std::ptr::null(),
            candidate_len: 0,
            ended: std::ptr::null(),
            ended_len: 0,
            error: std::ptr::null(),
            error_len: 0,
            path_kind: std::ptr::null(),
            path_kind_len: 0,
            path_rtt_ms: 0.0,
            displays: std::ptr::null(),
            display_count: 0,
            current: 0,
        }
    }
}

/// The opaque reader handle (`CmuxRdLineReader`).
#[derive(Debug, Default)]
pub struct CmuxRdLineReader {
    splitter: LineSplitter,
    ready: VecDeque<AppLine>,
    /// The line last handed out and its flat display sizes: they back the pointers.
    current: Option<(AppLine, Vec<u32>)>,
    poisoned: bool,
}

/// What `line` holds, pointing into `line` and `displays` (which must outlive the use).
fn view(line: &AppLine, displays: &[u32]) -> CmuxRdLine {
    let mut out = CmuxRdLine::default();
    let text = |value: &Option<String>, bit: u32, out: &mut CmuxRdLine| {
        value.as_deref().map(|s| {
            out.fields |= bit;
            (s.as_ptr(), s.len())
        })
    };
    if let Some((ptr, len)) = text(&line.key, CMUX_RD_LINE_KEY, &mut out) {
        (out.key, out.key_len) = (ptr, len);
    }
    if let Some((ptr, len)) = text(&line.candidate, CMUX_RD_LINE_CANDIDATE, &mut out) {
        (out.candidate, out.candidate_len) = (ptr, len);
    }
    if let Some((ptr, len)) = text(&line.ended, CMUX_RD_LINE_ENDED, &mut out) {
        (out.ended, out.ended_len) = (ptr, len);
    }
    if let Some((ptr, len)) = text(&line.error, CMUX_RD_LINE_ERROR, &mut out) {
        (out.error, out.error_len) = (ptr, len);
    }
    for (on, bit) in [
        (line.candidates_done, CMUX_RD_LINE_CANDIDATES_DONE),
        (line.connected, CMUX_RD_LINE_CONNECTED),
        (line.listening, CMUX_RD_LINE_LISTENING),
    ] {
        if on {
            out.fields |= bit;
        }
    }
    if let Some(path) = &line.path {
        out.fields |= CMUX_RD_LINE_PATH;
        if let Some((ptr, len)) = text(&path.kind, CMUX_RD_LINE_PATH_KIND, &mut out) {
            (out.path_kind, out.path_kind_len) = (ptr, len);
        }
        if let Some(rtt) = path.rtt_ms {
            out.fields |= CMUX_RD_LINE_PATH_RTT;
            out.path_rtt_ms = rtt;
        }
    }
    if line.displays.is_some() {
        out.fields |= CMUX_RD_LINE_DISPLAYS;
        out.displays = displays.as_ptr();
        out.display_count = displays.len() / 2;
    }
    if let Some(current) = line.current {
        out.fields |= CMUX_RD_LINE_CURRENT;
        out.current = u64::try_from(current).unwrap_or(u64::MAX);
    }
    out
}

/// Creates a reader; NULL only when allocation fails. Free it with
/// [`cmux_rd_line_reader_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_line_reader_new() -> *mut CmuxRdLineReader {
    catch_unwind(|| Box::into_raw(Box::<CmuxRdLineReader>::default()))
        .unwrap_or(std::ptr::null_mut())
}

/// Frees a reader; NULL is ignored.
///
/// # Safety
/// `reader` is NULL or came from [`cmux_rd_line_reader_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_line_reader_free(reader: *mut CmuxRdLineReader) {
    if reader.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(reader) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Runs `f` on a live reader; maps NULL, a poisoned reader and panics to codes.
pub(crate) fn with_reader(
    ptr: *mut CmuxRdLineReader,
    f: impl FnOnce(&mut CmuxRdLineReader) -> i32,
) -> i32 {
    // SAFETY: the caller passes NULL or a live reader and does not call into it concurrently.
    let Some(handle) = (unsafe { ptr.as_mut() }) else { return CMUX_RD_ERR_NULL };
    if handle.poisoned {
        return CMUX_RD_ERR_PANIC;
    }
    match catch_unwind(AssertUnwindSafe(|| f(handle))) {
        Ok(code) => code,
        Err(_) => {
            // SAFETY: as above; the closure's borrow ended when it unwound.
            if let Some(handle) = unsafe { ptr.as_mut() } {
                handle.poisoned = true;
            }
            CMUX_RD_ERR_PANIC
        }
    }
}

/// Adds stdout bytes. Each line they complete that reads as an app line is
/// queued; a line that is not one (not JSON, or a field of another type) is
/// dropped. Returns the number of lines ready.
///
/// # Safety
/// `reader` is NULL or live and not used concurrently; `bytes` is readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_line_reader_push(
    reader: *mut CmuxRdLineReader,
    bytes: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: readable for `len` bytes by contract.
    let Some(bytes) = (unsafe { bytes_in(bytes, len) }) else { return CMUX_RD_ERR_NULL };
    with_reader(reader, |handle| {
        for line in handle.splitter.push(bytes) {
            if let Some(line) = AppLine::decode(&line) {
                handle.ready.push_back(line);
            }
        }
        i32::try_from(handle.ready.len()).unwrap_or(i32::MAX)
    })
}

/// Takes the next ready line into `*out`: 1 when it wrote one, `CMUX_RD_OK`
/// (0) when none is ready. The pointers in `*out` stay valid until the next
/// call on this reader.
///
/// # Safety
/// `reader` is NULL or live and not used concurrently; `out` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_line_reader_next(
    reader: *mut CmuxRdLineReader,
    out: *mut CmuxRdLine,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    with_reader(reader, |handle| {
        let Some(line) = handle.ready.pop_front() else {
            handle.current = None;
            return CMUX_RD_OK;
        };
        let displays: Vec<u32> =
            line.displays.iter().flatten().flat_map(|&(width, height)| [width, height]).collect();
        let (line, displays) = handle.current.insert((line, displays));
        let typed = view(line, displays);
        // SAFETY: checked non-NULL; writable by contract.
        unsafe { *out = typed };
        1
    })
}
