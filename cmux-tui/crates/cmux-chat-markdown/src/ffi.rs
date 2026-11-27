//! The C ABI of the chat markdown parser for the macOS app (`include/cmux_chat_markdown.h`,
//! Swift module `CCmuxChatMarkdownFFI`), linked into the app through cmux-app-ffi.
//!
//! `cmux_chat_markdown_parse` returns the parsed document as bytes (`crate::encode`); the app
//! decodes them into its model and frees them with `cmux_chat_markdown_free`. The app's link
//! policy answers through a callback during the call, and its two localized image placeholder
//! forms come with the policy. No function unwinds across the boundary; any thread may call.

use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::{DefaultPolicy, LinkPolicy, encode, placeholder_from_templates};

/// Bumped on any change to a type, a function or the byte format.
pub const CMUX_CHAT_MARKDOWN_ABI_VERSION: u32 = 1;
/// `from_line` for a whole text (two passes when it has reference definitions).
pub const CMUX_CHAT_MARKDOWN_WHOLE_TEXT: u32 = 0xFFFF_FFFF;

/// Whether `url` (`len` UTF-8 bytes, edge whitespace removed, with an RFC 3986 scheme) may be a
/// link. Called on the parsing thread during `cmux_chat_markdown_parse`.
pub type CmuxChatMarkdownAllowsFn =
    Option<unsafe extern "C" fn(ctx: *mut c_void, url: *const u8, len: usize) -> bool>;

/// The host's link policy and image placeholder texts.
#[repr(C)]
pub struct CmuxChatMarkdownPolicy {
    /// Null: the built-in policy (http and https with a host, mailto).
    pub allows: CmuxChatMarkdownAllowsFn,
    /// Passed back to `allows`.
    pub ctx: *mut c_void,
    /// An image with no alt text ("[Image]"), UTF-8; null with length 0 takes that default.
    pub image_empty: *const u8,
    pub image_empty_len: usize,
    /// An image with alt text, its one "%@" the alt ("[Image: %@]"); null takes that default.
    pub image_template: *const u8,
    pub image_template_len: usize,
}

struct Host {
    allows: CmuxChatMarkdownAllowsFn,
    ctx: *mut c_void,
    empty: String,
    template: String,
}

impl LinkPolicy for Host {
    fn allows(&self, url: &str) -> bool {
        match self.allows {
            // SAFETY: the caller's callback, called with its own context and a live buffer.
            Some(f) => unsafe { f(self.ctx, url.as_ptr(), url.len()) },
            None => DefaultPolicy.allows(url),
        }
    }

    fn image_placeholder(&self, alt: &str) -> String {
        placeholder_from_templates(&self.empty, &self.template, alt)
    }
}

/// # Safety
/// `ptr` is null or points at `len` readable bytes.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: caller contract.
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

/// # Safety
/// `ptr` is null or points at `len` readable bytes.
unsafe fn string_or(ptr: *const u8, len: usize, fallback: &str) -> String {
    if ptr.is_null() {
        return fallback.to_owned();
    }
    // SAFETY: caller contract.
    String::from_utf8_lossy(unsafe { bytes(ptr, len) }).into_owned()
}

fn into_raw(v: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    let boxed = v.into_boxed_slice();
    if !out_len.is_null() {
        // SAFETY: the caller's out pointer, writable when not null.
        unsafe { *out_len = boxed.len() };
    }
    Box::into_raw(boxed).cast::<u8>()
}

/// The ABI version of this library.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_chat_markdown_abi_version() -> u32 {
    CMUX_CHAT_MARKDOWN_ABI_VERSION
}

/// Cheap pre-check, no allocation: could `text` (`len` UTF-8 bytes) contain markdown syntax?
/// False means the plain path for sure.
///
/// # Safety
/// `text` is null or points at `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chat_markdown_might_contain(text: *const u8, len: usize) -> bool {
    // SAFETY: caller contract.
    let t = unsafe { bytes(text, len) };
    catch_unwind(|| crate::might_contain(t)).unwrap_or(true)
}

/// Parses `text` (`len` UTF-8 bytes; invalid sequences read as U+FFFD). `from_line`
/// `CMUX_CHAT_MARKDOWN_WHOLE_TEXT` returns a document (`encode::document`); any other value
/// returns the top-level blocks from that source line on (`encode::blocks`, a stream's re-parse:
/// one pass, no reference definitions, line ranges from the text's start). Writes the byte
/// count to `out_len` and returns the bytes, to free with `cmux_chat_markdown_free`; null on a
/// failure (nothing to free). `policy` null takes the built-in policy and English placeholders.
///
/// # Safety
/// `text` is null or points at `len` readable bytes; `policy` is null or a valid policy whose
/// pointers stay valid during the call and whose callback is safe to call from this thread;
/// `out_len` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chat_markdown_parse(
    text: *const u8,
    len: usize,
    from_line: u32,
    policy: *const CmuxChatMarkdownPolicy,
    out_len: *mut usize,
) -> *mut u8 {
    if !out_len.is_null() {
        // SAFETY: caller contract.
        unsafe { *out_len = 0 };
    }
    // SAFETY: caller contract.
    let text = String::from_utf8_lossy(unsafe { bytes(text, len) });
    // SAFETY: caller contract.
    let host = match unsafe { policy.as_ref() } {
        Some(p) => Host {
            allows: p.allows,
            ctx: p.ctx,
            // SAFETY: caller contract.
            empty: unsafe { string_or(p.image_empty, p.image_empty_len, "[Image]") },
            // SAFETY: caller contract.
            template: unsafe { string_or(p.image_template, p.image_template_len, "[Image: %@]") },
        },
        None => Host {
            allows: None,
            ctx: std::ptr::null_mut(),
            empty: "[Image]".to_owned(),
            template: "[Image: %@]".to_owned(),
        },
    };
    let out = catch_unwind(AssertUnwindSafe(|| {
        if from_line == CMUX_CHAT_MARKDOWN_WHOLE_TEXT {
            encode::document(&crate::parse(&text, &host))
        } else {
            let from = usize::try_from(from_line).unwrap_or(usize::MAX);
            encode::blocks(&crate::parse_tail(&text, from, &host))
        }
    }));
    match out {
        Ok(v) => into_raw(v, out_len),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Frees bytes from `cmux_chat_markdown_parse`; null does nothing.
///
/// # Safety
/// `bytes` is null or from `cmux_chat_markdown_parse` with its `len`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_chat_markdown_free(bytes: *mut u8, len: usize) {
    if bytes.is_null() {
        return;
    }
    let slice = std::ptr::slice_from_raw_parts_mut(bytes, len);
    // SAFETY: from `Box::into_raw` of a boxed slice of `len` bytes, freed once.
    drop(unsafe { Box::from_raw(slice) });
}
