//! The C ABI of the launch images for the macOS app (`include/cmux_launch_image.h`, Swift module
//! `CCmuxLaunchImageFFI`), linked into the app through cmux-app-ffi.
//!
//! - `cmux_launch_image_publish`: write a window's newest image (the app's PNG bytes) and get its
//!   path and pixel size for the launch record's `image_path` / `image_pixel_*`.
//! - `cmux_launch_image_current`: a window's newest readable image, or false (no image is valid).
//! - `cmux_launch_image_remove_window`, `cmux_launch_image_prune`: a closed window's images; every
//!   image but the live windows'.
//! - `cmux_launch_image_schedule_*`: one capture schedule per window (`crate::schedule`).
//! - `cmux_launch_image_page_region`: whether a page's cached image may fill its region of a
//!   capture, else the region is plain (`crate::region`).
//!
//! The store functions take the folder each call and use the default caps (8 MiB per image, 16
//! windows, 2 images per window). They do file I/O: call them off the main thread. A schedule is
//! used by one thread at a time. No function unwinds across the boundary.
//!
//! A capture: `take_due` (or `take_quit`) true, read `epoch`, capture and encode, then publish only
//! while `is_current(epoch)` holds, hand the path to the launch record, and note 7 (done); note 6
//! (failed) when nothing was published. Calls for one folder may run concurrently: a publish never
//! reuses a path, and a prune leaves files younger than 60 s alone.

use crate::region::{PageRegion, page_region};
use crate::schedule::{Event, Schedule};
use crate::{Caps, Image, Store};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_LAUNCH_IMAGE_ABI_VERSION: u32 = 2;
/// The size of [`CmuxLaunchImage::path`], NUL included (the launch record's image path limit).
pub const CMUX_LAUNCH_IMAGE_PATH_CAPACITY: usize = 1025;
/// The age a file must reach before `cmux_launch_image_prune` removes it (60 s).
pub const CMUX_LAUNCH_IMAGE_PRUNE_GRACE_MS: u64 = 60_000;
/// `cmux_launch_image_schedule_note`'s reply when no capture is due.
pub const CMUX_LAUNCH_IMAGE_NOT_DUE: i64 = -1;
/// The most a page image may lag the composite it is painted into (`crate::region`).
pub const CMUX_LAUNCH_IMAGE_MAX_PAGE_IMAGE_LAG_MS: u64 = 120_000;
/// `cmux_launch_image_page_region`: paint the page's cached image. Every other reply paints the
/// region plain: 1 no image, 2 the page's version moved, 3 the page changed after the image, 4 the
/// image is too old, 5 the image is newer than the composite.
pub const CMUX_LAUNCH_IMAGE_REGION_IMAGE: u8 = 0;

/// One page region of a window at capture time (`crate::region::PageRegion`): times in one monotonic
/// clock's milliseconds, versions the page's picture version. A `has_*` false means the value is
/// unknown.
#[repr(C)]
pub struct CmuxLaunchImagePageRegion {
    pub has_image: bool,
    pub image_taken_ms: u64,
    pub has_image_version: bool,
    pub image_version: u64,
    pub page_version: u64,
    pub has_page_changed: bool,
    pub page_changed_ms: u64,
    pub composite_ms: u64,
}

/// A window's published image. On false every field is zero and `path` is empty.
#[repr(C)]
pub struct CmuxLaunchImage {
    pub generation: u64,
    pub bytes: u64,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// NUL-terminated UTF-8.
    pub path: [c_char; CMUX_LAUNCH_IMAGE_PATH_CAPACITY],
}

/// One window's capture schedule.
pub struct CmuxLaunchImageSchedule {
    inner: Schedule,
}

fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// # Safety
/// `ptr` is null or a NUL-terminated string valid for the call.
unsafe fn string<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller passes a NUL-terminated string valid for the call.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn store(dir: &str) -> Store {
    Store::new(dir, Caps::default())
}

/// Zeroes `out` (null does nothing).
///
/// # Safety
/// `out` is null or valid for writes of one `CmuxLaunchImage`.
unsafe fn zero(out: *mut CmuxLaunchImage) {
    if !out.is_null() {
        // SAFETY: valid for writes (caller contract); all-zero is a valid `CmuxLaunchImage`.
        unsafe { out.write_bytes(0, 1) };
    }
}

/// Fills `out` from `image`; false (and `out` zeroed) when its path does not fit.
///
/// # Safety
/// `out` is null or valid for writes of one `CmuxLaunchImage`.
unsafe fn fill(out: *mut CmuxLaunchImage, image: Option<Image>) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is valid for writes (caller contract); all-zero is a valid `CmuxLaunchImage`.
    let out = unsafe {
        out.write_bytes(0, 1);
        &mut *out
    };
    let Some(image) = image else { return false };
    let Some(path) = image.path.to_str() else { return false };
    if path.len() >= CMUX_LAUNCH_IMAGE_PATH_CAPACITY || path.as_bytes().contains(&0) {
        return false;
    }
    for (slot, byte) in out.path.iter_mut().zip(path.bytes()) {
        *slot = byte as c_char;
    }
    out.generation = image.generation;
    out.bytes = image.bytes;
    out.pixel_width = image.pixel_width;
    out.pixel_height = image.pixel_height;
    true
}

/// Writes `png` (`len` bytes) as window `window_id`'s newest image in folder `dir` (made when
/// missing) and fills `out` with it. False, and `out` zeroed, when nothing was written: a null or
/// non-UTF-8 argument, bytes that are not a PNG with a size, an image over 8 MiB, or a failed write.
/// The window's previous image then stays.
///
/// # Safety
/// `dir` and `window_id` are NUL-terminated strings; `png` is valid for reads of `len` bytes (or
/// null with `len` 0); `out` is null or valid for writes of one `CmuxLaunchImage`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_publish(
    dir: *const c_char,
    window_id: *const c_char,
    png: *const u8,
    len: usize,
    out: *mut CmuxLaunchImage,
) -> bool {
    // SAFETY: caller contract on `out`; zeroed first, so a panic below still leaves it zeroed.
    unsafe { zero(out) };
    guard(false, || {
        // SAFETY: caller contract.
        let (dir, id) = unsafe { (string(dir), string(window_id)) };
        let image = match (dir, id, png.is_null()) {
            (Some(dir), Some(id), false) => {
                // SAFETY: `png` is valid for reads of `len` bytes (caller contract).
                let bytes = unsafe { std::slice::from_raw_parts(png, len) };
                store(dir).publish(id, bytes).ok()
            }
            _ => None,
        };
        // SAFETY: caller contract on `out`.
        unsafe { fill(out, image) }
    })
}

/// Fills `out` with window `window_id`'s newest readable image in `dir`. False, and `out` zeroed,
/// when it has none (missing, over 8 MiB, not a PNG): the launch's empty first frame, not an error.
/// Reads 24 bytes of the file, never the whole image.
///
/// # Safety
/// `dir` and `window_id` are NUL-terminated strings; `out` is null or valid for writes of one
/// `CmuxLaunchImage`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_current(
    dir: *const c_char,
    window_id: *const c_char,
    out: *mut CmuxLaunchImage,
) -> bool {
    // SAFETY: caller contract on `out`; zeroed first, so a panic below still leaves it zeroed.
    unsafe { zero(out) };
    guard(false, || {
        // SAFETY: caller contract.
        let image = match unsafe { (string(dir), string(window_id)) } {
            (Some(dir), Some(id)) => store(dir).current(id),
            _ => None,
        };
        // SAFETY: caller contract on `out`.
        unsafe { fill(out, image) }
    })
}

/// Removes every image of window `window_id` in `dir` (the window closed). Returns how many files
/// went.
///
/// # Safety
/// `dir` and `window_id` are NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_remove_window(
    dir: *const c_char,
    window_id: *const c_char,
) -> usize {
    guard(0, || match unsafe { (string(dir), string(window_id)) } {
        (Some(dir), Some(id)) => store(dir).remove_window(id),
        _ => 0,
    })
}

/// Keeps only the images of the `count` windows in `live_ids` in `dir`, and removes stray partial
/// writes, each only once older than `grace_ms` (the app passes `CMUX_LAUNCH_IMAGE_PRUNE_GRACE_MS`:
/// a publish in progress or a window opened after `live_ids` was read keeps its files). Returns how many files went. Does
/// nothing (returns 0) when an id is null or not UTF-8.
///
/// # Safety
/// `dir` is a NUL-terminated string; `live_ids` is valid for reads of `count` pointers to
/// NUL-terminated strings (or null with `count` 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_prune(
    dir: *const c_char,
    live_ids: *const *const c_char,
    count: usize,
    grace_ms: u64,
) -> usize {
    guard(0, || {
        // SAFETY: caller contract.
        let Some(dir) = (unsafe { string(dir) }) else { return 0 };
        if count != 0 && live_ids.is_null() {
            return 0;
        }
        let mut live = Vec::with_capacity(count);
        for i in 0..count {
            // SAFETY: `live_ids` is valid for reads of `count` pointers (caller contract).
            match unsafe { string(*live_ids.add(i)) } {
                Some(id) => live.push(id),
                None => return 0,
            }
        }
        store(dir).prune_older_than(&live, std::time::Duration::from_millis(grace_ms))
    })
}

/// A new window's capture schedule (hidden, unchanged, no capture yet); `debounce_ms` 0 takes the
/// default (750 ms). Free it with `cmux_launch_image_schedule_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_image_schedule_new(debounce_ms: u64) -> *mut CmuxLaunchImageSchedule {
    let debounce =
        if debounce_ms == 0 { crate::schedule::DEFAULT_DEBOUNCE_MS } else { debounce_ms };
    Box::into_raw(Box::new(CmuxLaunchImageSchedule { inner: Schedule::new(debounce) }))
}

/// Frees a schedule; null does nothing.
///
/// # Safety
/// `schedule` is null or from `cmux_launch_image_schedule_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_schedule_free(schedule: *mut CmuxLaunchImageSchedule) {
    if !schedule.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_launch_image_schedule_new`, freed once.
        drop(unsafe { Box::from_raw(schedule) });
    }
}

/// Records `event` (1 changed, 2 hidden, 3 shown, 4 transition began, 5 transition ended, 6 capture
/// failed, 7 capture done: published and handed to the launch record) at `now_ms` and returns when
/// a capture is due, in the same clock's milliseconds, or `CMUX_LAUNCH_IMAGE_NOT_DUE`. An unknown event changes nothing.
///
/// # Safety
/// `schedule` is null or a live schedule used by no other thread during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_schedule_note(
    schedule: *mut CmuxLaunchImageSchedule,
    event: u32,
    now_ms: u64,
) -> i64 {
    // SAFETY: caller contract.
    let Some(schedule) = (unsafe { schedule.as_mut() }) else { return CMUX_LAUNCH_IMAGE_NOT_DUE };
    let due = match Event::from_raw(event) {
        Some(event) => schedule.inner.note(event, now_ms),
        None => schedule.inner.due_at(),
    };
    due.and_then(|ms| i64::try_from(ms).ok()).unwrap_or(CMUX_LAUNCH_IMAGE_NOT_DUE)
}

/// True when a capture is due at `now_ms`: capture now (a capture that writes nothing notes event 6).
///
/// # Safety
/// As `cmux_launch_image_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_schedule_take_due(
    schedule: *mut CmuxLaunchImageSchedule,
    now_ms: u64,
) -> bool {
    // SAFETY: caller contract.
    unsafe { schedule.as_mut() }.is_some_and(|s| s.inner.take_due(now_ms))
}

/// True when the quit should capture this window now (shown, settled, changed since its last
/// capture or never captured in this run).
///
/// # Safety
/// As `cmux_launch_image_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_schedule_take_quit(
    schedule: *mut CmuxLaunchImageSchedule,
) -> bool {
    // SAFETY: caller contract.
    unsafe { schedule.as_mut() }.is_some_and(|s| s.inner.take_quit())
}

/// The window's change epoch; read it when a capture starts (`cmux_launch_image_schedule_is_current`).
///
/// # Safety
/// As `cmux_launch_image_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_schedule_epoch(
    schedule: *const CmuxLaunchImageSchedule,
) -> u64 {
    // SAFETY: caller contract.
    unsafe { schedule.as_ref() }.map_or(0, |s| s.inner.epoch())
}

/// True when nothing happened to the window since `epoch` and it is still capturable: only then is a
/// capture started at `epoch` handed to the launch record. False for a null schedule.
///
/// # Safety
/// As `cmux_launch_image_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_schedule_is_current(
    schedule: *const CmuxLaunchImageSchedule,
    epoch: u64,
) -> bool {
    // SAFETY: caller contract.
    unsafe { schedule.as_ref() }.is_some_and(|s| s.inner.is_current(epoch))
}

/// Whether a page's cached image may fill its region of a capture: `CMUX_LAUNCH_IMAGE_REGION_IMAGE`
/// paints it; any other reply (see that constant) paints the region plain. Null gives 1 (no image).
///
/// # Safety
/// `region` is null or valid for reads of one `CmuxLaunchImagePageRegion`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_image_page_region(
    region: *const CmuxLaunchImagePageRegion,
) -> u8 {
    // SAFETY: caller contract.
    let Some(r) = (unsafe { region.as_ref() }) else {
        return crate::region::RegionReason::NoImage as u8;
    };
    page_region(&PageRegion {
        image_taken_ms: r.has_image.then_some(r.image_taken_ms),
        image_version: r.has_image_version.then_some(r.image_version),
        page_version: r.page_version,
        page_changed_ms: r.has_page_changed.then_some(r.page_changed_ms),
        composite_ms: r.composite_ms,
    }) as u8
}
