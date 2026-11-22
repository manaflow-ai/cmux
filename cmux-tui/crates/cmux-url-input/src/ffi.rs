//! The C ABI of the typed policy (`include/cmux_url_input.h`, Swift module
//! `CCmuxUrlInputFFI`), for the macOS app through cmux-app-ffi (which links it
//! in step A of the FFI move; step B makes the Swift call). The
//! omnibox calls it on every key, so it is a typed ABI, not a JSON op: the
//! caller owns the output buffer, nothing is allocated across the boundary and
//! nothing needs a free. Every function is pure, thread-safe and never panics
//! across the boundary (a caught panic is `CMUX_URL_INPUT_ERR_PANIC`).

use crate::chromium::{ChromiumPageRoute, chromium_internal_url, chromium_page_route};
use crate::typed::{TypedInput, contains_pairing_link, is_loopback_host};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or function in the header.
pub const ABI_VERSION: u32 = 1;

/// A URL (or page) was written to the output buffer.
pub const FOUND: i32 = 1;
/// No URL: the text is a search (or not a page).
pub const NONE: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_UTF8: i32 = -2;
/// The output buffer is too small; `*out_len` holds the length needed.
pub const ERR_SHORT: i32 = -3;
pub const ERR_PANIC: i32 = -4;

/// `flags` bit: the tab is a Chromium tab (`allowsChromiumSchemes`).
pub const FLAG_ALLOWS_CHROMIUM: u32 = 1;

/// Route kinds of [`cmux_url_input_chromium_page_route`].
pub const ROUTE_NONE: i32 = 0;
pub const ROUTE_CMUX_PAGE: i32 = 1;
pub const ROUTE_BROWSER_SETTINGS: i32 = 2;
pub const ROUTE_PASSWORDS_PAGE: i32 = 3;
pub const ROUTE_CHROMIUM: i32 = 4;

/// # Safety
///
/// `ptr` is null or points at `len` readable bytes.
unsafe fn text<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    if len == 0 {
        return Ok("");
    }
    if ptr.is_null() {
        return Err(ERR_NULL);
    }
    // SAFETY: the C caller guarantees `len` readable bytes at `ptr`.
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).map_err(|_| ERR_UTF8)
}

/// Writes `value` to the caller's buffer.
///
/// # Safety
///
/// `out` is null or points at `out_cap` writable bytes; `out_len` is a valid
/// pointer (checked non-null by the caller of this helper).
unsafe fn write_out(value: &str, out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    // SAFETY: `out_len` is valid and writable (the caller's contract).
    unsafe { *out_len = value.len() };
    if value.is_empty() {
        return FOUND;
    }
    if value.len() > out_cap || out.is_null() {
        return ERR_SHORT;
    }
    // SAFETY: `out` holds `out_cap >= value.len()` writable bytes that do not
    // overlap `value` (Rust-owned).
    unsafe { std::ptr::copy_nonoverlapping(value.as_ptr(), out, value.len()) };
    FOUND
}

fn guarded(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(ERR_PANIC)
}

/// The ABI version this library implements.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_url_input_abi_version() -> u32 {
    ABI_VERSION
}

/// Resolves typed address-bar text with the typed policy.
///
/// # Safety
///
/// `input` and `home` point at their lengths of readable UTF-8 (or are null
/// with length 0); `out` points at `out_cap` writable bytes or is null;
/// `out_len` is a valid writable pointer.
// Eight arguments: two texts, the flags and the caller's output buffer; a
// struct would only move them into the Swift caller's stack frame.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_url_input_resolve_typed(
    input: *const u8,
    input_len: usize,
    home: *const u8,
    home_len: usize,
    flags: u32,
    out: *mut u8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    guarded(|| {
        if out_len.is_null() {
            return ERR_NULL;
        }
        // SAFETY: `out_len` is valid (checked above, the caller's contract).
        unsafe { *out_len = 0 };
        // SAFETY: the caller's contract for `input` and `home`.
        let (input, home) = match unsafe { (text(input, input_len), text(home, home_len)) } {
            (Ok(input), Ok(home)) => (input, home),
            (Err(code), _) | (_, Err(code)) => return code,
        };
        let policy =
            TypedInput { home, allows_chromium_schemes: flags & FLAG_ALLOWS_CHROMIUM != 0 };
        match policy.resolve(input) {
            // SAFETY: the caller's contract for `out`, `out_cap` and `out_len`.
            Some(url) => unsafe { write_out(&url, out, out_cap, out_len) },
            None => NONE,
        }
    })
}

/// `FOUND` when `text` holds a Mac Screen pairing link, else `NONE`.
///
/// # Safety
///
/// `text` points at `len` readable UTF-8 bytes, or is null with length 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_url_input_contains_pairing_link(
    text_ptr: *const u8,
    len: usize,
) -> i32 {
    guarded(|| {
        // SAFETY: the caller's contract for the text pointer and length.
        match unsafe { text(text_ptr, len) } {
            Ok(value) if contains_pairing_link(value) => FOUND,
            Ok(_) => NONE,
            Err(code) => code,
        }
    })
}

/// `FOUND` when `host` (lowercased, IPv6 brackets stripped) is a loopback host.
///
/// # Safety
///
/// `host` points at `len` readable UTF-8 bytes, or is null with length 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_url_input_is_loopback_host(host: *const u8, len: usize) -> i32 {
    guarded(|| {
        // SAFETY: the caller's contract for the text pointer and length.
        match unsafe { text(host, len) } {
            Ok(value) if is_loopback_host(value) => FOUND,
            Ok(_) => NONE,
            Err(code) => code,
        }
    })
}

/// `ChromiumInternalURL(typed:)`: writes the canonical page URL and returns
/// `FOUND`, or returns `NONE`.
///
/// # Safety
///
/// As [`cmux_url_input_resolve_typed`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_url_input_chromium_internal_url(
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    guarded(|| {
        if out_len.is_null() {
            return ERR_NULL;
        }
        // SAFETY: `out_len` is valid (checked above).
        unsafe { *out_len = 0 };
        // SAFETY: the caller's contract for `input`.
        let input = match unsafe { text(input, input_len) } {
            Ok(input) => input,
            Err(code) => return code,
        };
        match chromium_internal_url(input) {
            // SAFETY: the caller's contract for `out`, `out_cap` and `out_len`.
            Some(page) => unsafe { write_out(&page, out, out_cap, out_len) },
            None => NONE,
        }
    })
}

/// `ChromiumPageRoute(url)`: returns a `CMUX_URL_INPUT_ROUTE_*` kind. For
/// `CMUX_PAGE` the cmux page URL, and for `CHROMIUM` the canonical page URL,
/// is written to `out`; the other kinds write nothing (`*out_len` 0). A
/// negative value is an error (`ERR_SHORT`: call again with `*out_len` bytes).
///
/// # Safety
///
/// As [`cmux_url_input_resolve_typed`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_url_input_chromium_page_route(
    url: *const u8,
    url_len: usize,
    out: *mut u8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    guarded(|| {
        if out_len.is_null() {
            return ERR_NULL;
        }
        // SAFETY: `out_len` is valid (checked above).
        unsafe { *out_len = 0 };
        // SAFETY: the caller's contract for `url`.
        let url = match unsafe { text(url, url_len) } {
            Ok(url) => url,
            Err(code) => return code,
        };
        let (kind, address) = match chromium_page_route(url) {
            None => return ROUTE_NONE,
            Some(ChromiumPageRoute::BrowserSettings) => return ROUTE_BROWSER_SETTINGS,
            Some(ChromiumPageRoute::PasswordsPage) => return ROUTE_PASSWORDS_PAGE,
            Some(ChromiumPageRoute::CmuxPage(address)) => (ROUTE_CMUX_PAGE, address.to_string()),
            Some(ChromiumPageRoute::Chromium(page)) => (ROUTE_CHROMIUM, page),
        };
        // SAFETY: the caller's contract for `out`, `out_cap` and `out_len`.
        match unsafe { write_out(&address, out, out_cap, out_len) } {
            FOUND => kind,
            error => error,
        }
    })
}
