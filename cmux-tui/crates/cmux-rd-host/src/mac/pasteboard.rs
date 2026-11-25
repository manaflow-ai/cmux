//! The Mac's general pasteboard (NSPasteboard) as the session's clipboard: plain UTF-8 text
//! only (`public.utf8-plain-text`), read and written through the Objective-C runtime like
//! the rest of the host (sys.rs), so the CLI binary loads AppKit only for a session.

use super::sys::{self, appkit, msg, release, sel, send_id, AutoreleasePool, Id, Sel};
use crate::clipboard::{Pasteboard, TextRead};
use std::ffi::c_void;

/// NSUTF8StringEncoding.
const UTF8: usize = 4;
/// NSPasteboardTypeString's value.
const PLAIN_TEXT: &[u8] = b"public.utf8-plain-text";

/// Whether this Mac's pasteboard can be reached: the frameworks load and NSPasteboard exists.
pub fn available() -> bool {
    sys::load().is_ok() && appkit::available().is_ok() && !sys::class(c"NSPasteboard").is_null()
}

/// The general pasteboard, a process-wide object AppKit keeps alive.
pub struct MacPasteboard {
    board: Id,
}

impl MacPasteboard {
    pub fn open() -> Option<Self> {
        if !available() {
            return None;
        }
        let _pool = AutoreleasePool::new();
        let board = send_id(sys::class(c"NSPasteboard"), c"generalPasteboard");
        (!board.is_null()).then_some(Self { board })
    }
}

/// A retained NSString of `bytes` (UTF-8), released by the caller; nil when not UTF-8.
fn ns_string(bytes: &[u8]) -> Id {
    let alloc = send_id(sys::class(c"NSString"), c"alloc");
    if alloc.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: -initWithBytes:length:encoding: reads `bytes.len()` bytes and returns a
    // retained string (nil when they are not valid in the encoding; alloc is then freed).
    unsafe {
        msg::<unsafe extern "C" fn(Id, Sel, *const c_void, usize, usize) -> Id>()(
            alloc,
            sel(c"initWithBytes:length:encoding:"),
            bytes.as_ptr().cast(),
            bytes.len(),
            UTF8,
        )
    }
}

impl Pasteboard for MacPasteboard {
    fn change_count(&mut self) -> i64 {
        // SAFETY: -changeCount returns an NSInteger.
        let count = unsafe {
            msg::<unsafe extern "C" fn(Id, Sel) -> isize>()(self.board, sel(c"changeCount"))
        };
        count as i64
    }

    fn read_text(&mut self, max: usize) -> TextRead {
        let _pool = AutoreleasePool::new();
        let kind = ns_string(PLAIN_TEXT);
        if kind.is_null() {
            return TextRead::None;
        }
        // SAFETY: -stringForType: returns an autoreleased NSString or nil.
        let text = unsafe {
            msg::<unsafe extern "C" fn(Id, Sel, Id) -> Id>()(
                self.board,
                sel(c"stringForType:"),
                kind,
            )
        };
        release(kind);
        if text.is_null() {
            return TextRead::None;
        }
        // SAFETY: -lengthOfBytesUsingEncoding: returns an NSUInteger (0 when not encodable).
        let len = unsafe {
            msg::<unsafe extern "C" fn(Id, Sel, usize) -> usize>()(
                text,
                sel(c"lengthOfBytesUsingEncoding:"),
                UTF8,
            )
        };
        if len > max {
            return TextRead::TooLarge(len);
        }
        // SAFETY: -dataUsingEncoding: returns an autoreleased NSData or nil; -bytes points at
        // its -length bytes while the data lives (inside this pool), copied at once.
        unsafe {
            let data = msg::<unsafe extern "C" fn(Id, Sel, usize) -> Id>()(
                text,
                sel(c"dataUsingEncoding:"),
                UTF8,
            );
            if data.is_null() {
                return TextRead::None;
            }
            let n = msg::<unsafe extern "C" fn(Id, Sel) -> usize>()(data, sel(c"length"));
            if n > max {
                return TextRead::TooLarge(n);
            }
            let bytes = msg::<unsafe extern "C" fn(Id, Sel) -> *const u8>()(data, sel(c"bytes"));
            if bytes.is_null() || n == 0 {
                return TextRead::Text(String::new());
            }
            let slice = std::slice::from_raw_parts(bytes, n);
            TextRead::Text(String::from_utf8_lossy(slice).into_owned())
        }
    }

    fn write_text(&mut self, text: &str) -> Result<(), String> {
        let _pool = AutoreleasePool::new();
        let value = ns_string(text.as_bytes());
        let kind = ns_string(PLAIN_TEXT);
        if value.is_null() || kind.is_null() {
            release(value);
            release(kind);
            return Err("NSString refused the text".into());
        }
        // SAFETY: -clearContents returns an NSInteger; -setString:forType: returns a BOOL
        // (one byte on arm64 and x86_64 alike). Both strings are ours and released after.
        let ok = unsafe {
            msg::<unsafe extern "C" fn(Id, Sel) -> isize>()(self.board, sel(c"clearContents"));
            msg::<unsafe extern "C" fn(Id, Sel, Id, Id) -> u8>()(
                self.board,
                sel(c"setString:forType:"),
                value,
                kind,
            )
        };
        release(value);
        release(kind);
        if ok == 0 {
            return Err("NSPasteboard refused setString:forType:".into());
        }
        Ok(())
    }
}
