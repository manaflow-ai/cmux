//! The C ABI of the keymap layer (`include/cmux_keymap.h`, Swift module `CCmuxKeymapFFI`),
//! linked into the macOS app through cmux-app-ffi.
//!
//! One handle per list surface holds its `app.keyStyle` list state (a pending `gg`); a
//! shortcut check needs no handle. A key arrives as its macOS virtual key code (kVK_*), what
//! the layout types on it without and with Shift (UTF-8; `Dead` for a dead key; a named key
//! as `escape`, `enter`, `up`, `down`, `left`, `right`, `pageup` or `pagedown`) and the
//! modifier bits. Calls on one handle are serialized by the caller. None unwinds across the
//! boundary.

use crate::{KeyEvent, KeyStyle, ListKeys, Mods, Outcome, ShortcutLayout, Stroke};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a constant or a function.
pub const CMUX_KEYMAP_ABI_VERSION: u32 = 1;

/// `app.keyStyle` values of `cmux_keymap_new`'s `style`; any other value is standard.
pub const CMUX_KEYMAP_STYLE_STANDARD: u8 = 0;
pub const CMUX_KEYMAP_STYLE_VIM: u8 = 1;
pub const CMUX_KEYMAP_STYLE_EMACS: u8 = 2;

/// `app.shortcutLayout` values of a `layout` argument; any other value is followLayout.
pub const CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT: u8 = 0;
pub const CMUX_KEYMAP_LAYOUT_QWERTY_POSITIONS: u8 = 1;

/// Modifier bits of a `mods` argument; other bits are ignored.
pub const CMUX_KEYMAP_MOD_CMD: u32 = 1;
pub const CMUX_KEYMAP_MOD_CTRL: u32 = 2;
pub const CMUX_KEYMAP_MOD_ALT: u32 = 4;
pub const CMUX_KEYMAP_MOD_SHIFT: u32 = 8;

/// A `mac_key_code` for a key with no known physical key: matched by its characters only.
pub const CMUX_KEYMAP_NO_KEY_CODE: u16 = 0xFFFF;

/// `cmux_keymap_feed`: the key is left to the surface.
pub const CMUX_KEYMAP_PASS: i32 = -1;
/// `cmux_keymap_feed`: the key starts a sequence (the first g of gg); consume it and wait.
pub const CMUX_KEYMAP_PENDING: i32 = -2;

/// One list surface's key state.
pub struct CmuxKeymap {
    keys: ListKeys,
}

fn style_from_u8(style: u8) -> KeyStyle {
    match style {
        CMUX_KEYMAP_STYLE_VIM => KeyStyle::Vim,
        CMUX_KEYMAP_STYLE_EMACS => KeyStyle::Emacs,
        _ => KeyStyle::Standard,
    }
}

fn layout_from_u8(layout: u8) -> ShortcutLayout {
    match layout {
        CMUX_KEYMAP_LAYOUT_QWERTY_POSITIONS => ShortcutLayout::QwertyPositions,
        _ => ShortcutLayout::FollowLayout,
    }
}

/// The UTF-8 string at `ptr`, or None for null or invalid UTF-8.
///
/// # Safety
///
/// `ptr` is null or a NUL-terminated string that stays valid for the call.
unsafe fn text<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller passes a NUL-terminated string valid for the call.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn event<'a>(
    mac_key_code: u16,
    key: Option<&'a str>,
    shifted_key: Option<&'a str>,
    mods: u32,
) -> KeyEvent<'a> {
    KeyEvent {
        code: crate::code_for_mac_key_code(mac_key_code),
        key: key.unwrap_or(""),
        shifted_key,
        mods: Mods::from_bits(mods),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_keymap_abi_version() -> u32 {
    CMUX_KEYMAP_ABI_VERSION
}

/// Creates one list surface's key state for a style (CMUX_KEYMAP_STYLE_*) and a shortcut
/// layout (CMUX_KEYMAP_LAYOUT_*). Free it with `cmux_keymap_free`. Null only on a panic.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_keymap_new(style: u8, layout: u8) -> *mut CmuxKeymap {
    catch_unwind(|| {
        Box::into_raw(Box::new(CmuxKeymap {
            keys: ListKeys::new(style_from_u8(style), layout_from_u8(layout)),
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Frees a handle from `cmux_keymap_new`. Null is ignored.
///
/// # Safety
///
/// `keymap` is null or a live handle from `cmux_keymap_new`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_keymap_free(keymap: *mut CmuxKeymap) {
    if !keymap.is_null() {
        // SAFETY: the caller hands back a handle from `cmux_keymap_new` once.
        drop(unsafe { Box::from_raw(keymap) });
    }
}

/// Feeds one key to the list layer. `in_text`: a text field has the keyboard. Returns the
/// command's index in key-styles.json's `commands` (0 list.next ... 9 list.leave),
/// CMUX_KEYMAP_PASS (also for a null handle or a panic) or CMUX_KEYMAP_PENDING.
///
/// # Safety
///
/// `keymap` is null or a live handle; `key` and `shifted_key` are null or NUL-terminated
/// UTF-8 strings valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_keymap_feed(
    keymap: *mut CmuxKeymap,
    mac_key_code: u16,
    key: *const c_char,
    shifted_key: *const c_char,
    mods: u32,
    in_text: bool,
) -> i32 {
    if keymap.is_null() {
        return CMUX_KEYMAP_PASS;
    }
    // SAFETY: a live handle, used by one caller at a time.
    let handle = unsafe { &mut *keymap };
    // SAFETY: null or NUL-terminated strings valid for the call (the caller's contract).
    let (key, shifted_key) = unsafe { (text(key), text(shifted_key)) };
    let event = event(mac_key_code, key, shifted_key, mods);
    catch_unwind(AssertUnwindSafe(|| match handle.keys.feed(&event, in_text) {
        Outcome::Command(command) => i32::try_from(command.index()).unwrap_or(CMUX_KEYMAP_PASS),
        Outcome::Pending => CMUX_KEYMAP_PENDING,
        Outcome::Pass => CMUX_KEYMAP_PASS,
    }))
    .unwrap_or(CMUX_KEYMAP_PASS)
}

/// Drops a pending sequence (focus left the list, a timeout). Null is ignored.
///
/// # Safety
///
/// `keymap` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_keymap_reset(keymap: *mut CmuxKeymap) {
    if !keymap.is_null() {
        // SAFETY: a live handle, used by one caller at a time.
        unsafe { &mut *keymap }.keys.reset();
    }
}

/// Whether a keybindings.json stroke (`cmd+shift+]`) matches a key in a shortcut layout
/// (CMUX_KEYMAP_LAYOUT_*). False for an unreadable binding, a null one or a panic.
///
/// # Safety
///
/// `binding`, `key` and `shifted_key` are null or NUL-terminated UTF-8 strings valid for the
/// call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_keymap_stroke_matches(
    layout: u8,
    binding: *const c_char,
    mac_key_code: u16,
    key: *const c_char,
    shifted_key: *const c_char,
    mods: u32,
) -> bool {
    // SAFETY: null or NUL-terminated strings valid for the call (the caller's contract).
    let (binding, key, shifted_key) = unsafe { (text(binding), text(key), text(shifted_key)) };
    let Some(binding) = binding else { return false };
    catch_unwind(|| {
        let Some(stroke) = Stroke::parse(binding) else { return false };
        let event = event(mac_key_code, key, shifted_key, mods);
        crate::stroke_matches(layout_from_u8(layout), &stroke, &event)
    })
    .unwrap_or(false)
}

/// The bytes of `CmuxKeymapStroke.key`: up to 15 bytes of UTF-8 and a NUL.
pub const CMUX_KEYMAP_STROKE_KEY_LEN: usize = 16;
/// The most strokes `cmux_keymap_candidates` gives for one key.
pub const CMUX_KEYMAP_CANDIDATES_MAX: usize = 3;

/// One stroke a key-down may mean: `key` is NUL-terminated lowercase UTF-8 (one character or
/// a named key), `mods` its CMUX_KEYMAP_MOD_* bits.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CmuxKeymapStroke {
    pub key: [u8; CMUX_KEYMAP_STROKE_KEY_LEN],
    pub mods: u32,
}

/// Writes the strokes a key-down may mean in a shortcut layout (CMUX_KEYMAP_LAYOUT_*), in
/// priority order and without duplicates, to `out` (at most `cap` of them), and returns how
/// many there are (at most CMUX_KEYMAP_CANDIDATES_MAX; more than `cap` means some were not
/// written). A binding matches the key exactly when it is one of them, as
/// `cmux_keymap_stroke_matches` says. No allocation. 0 for a panic.
///
/// # Safety
///
/// `key` and `shifted_key` are null or NUL-terminated UTF-8 strings valid for the call; `out`
/// is null (with any `cap`, nothing written) or points to `cap` writable strokes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_keymap_candidates(
    layout: u8,
    mac_key_code: u16,
    key: *const c_char,
    shifted_key: *const c_char,
    mods: u32,
    out: *mut CmuxKeymapStroke,
    cap: usize,
) -> usize {
    // SAFETY: null or NUL-terminated strings valid for the call (the caller's contract).
    let (key, shifted_key) = unsafe { (text(key), text(shifted_key)) };
    let Ok(found) = catch_unwind(|| {
        crate::key_candidates(layout_from_u8(layout), &event(mac_key_code, key, shifted_key, mods))
    }) else {
        return 0;
    };
    if !out.is_null() && cap > 0 {
        // SAFETY: `out` points to `cap` writable strokes (the caller's contract).
        let out = unsafe { std::slice::from_raw_parts_mut(out, cap) };
        for (slot, candidate) in out.iter_mut().zip(found.iter()) {
            let mut bytes = [0u8; CMUX_KEYMAP_STROKE_KEY_LEN];
            for (dst, src) in bytes.iter_mut().zip(candidate.key_bytes()) {
                *dst = *src;
            }
            *slot = CmuxKeymapStroke { key: bytes, mods: candidate.mods.bits() };
        }
    }
    found.len()
}
