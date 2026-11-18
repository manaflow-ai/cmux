//! The C ABI of a bare launch's held message box for the macOS app
//! (`include/cmux_launch_draft.h`, Swift module `CCmuxLaunchDraftFFI`),
//! linked into the app through cmux-app-ffi.
//!
//! - `cmux_launch_draft_new` / `cmux_launch_draft_free`: one hold per page.
//! - `cmux_launch_draft_hold`, `_resolve`, `_next`, `_delivered`, `_cancel`:
//!   the hold and its hand-over; `_chief`, `_is_cancelled`, `_held`: its state.
//! - `cmux_launch_draft_text_of`: the text a cancel gives back to the draft.
//! - `cmux_launch_draft_save_for_quit`, `_park`, `_decode`: what a quit or a
//!   release keeps for the next launch.
//! - `cmux_launch_draft_append`: typed text after the Chief's own draft.
//!
//! Parts cross as JSON: an array of parts, in order, each a one-key object in
//! the app's own encoding (Swift's synthesized `MessagePart` Codable). A
//! `"text"` part's text is its value when a string, else its `"_0"` (Swift's
//! `{"text":{"_0":"hi","mentions":[]}}`); any other part is opaque. Each part
//! comes back as it came (the same JSON value). A send crosses as
//! `{"key": "...", "parts": [...]}`. A handle is used by one thread at a time
//! (the app's main actor). None unwinds across the boundary. Every returned
//! string belongs to the caller, who frees it with
//! `cmux_launch_draft_string_free`.

use crate::{HeldSend, HoldOutcome, LaunchDraft, Parked, Part, append_draft, text_of};
use serde_json::Value;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a function, a constant or the JSON.
pub const CMUX_LAUNCH_DRAFT_ABI_VERSION: u32 = 1;
/// Kept, after the sends before it, until it is handed to the Chief.
pub const CMUX_LAUNCH_DRAFT_HELD: i32 = 0;
/// The key was already held: the sender waits on that send.
pub const CMUX_LAUNCH_DRAFT_JOINED: i32 = 1;
/// The key was already handed to the Chief in `*chief_out`: answer with it again.
pub const CMUX_LAUNCH_DRAFT_ALREADY_DELIVERED: i32 = 2;
/// The hold was cancelled first: refused.
pub const CMUX_LAUNCH_DRAFT_CANCELLED: i32 = 4;
/// A null pointer where one is required.
pub const CMUX_LAUNCH_DRAFT_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the parts JSON.
pub const CMUX_LAUNCH_DRAFT_ERR_INVALID: i32 = -2;
/// A panic inside, caught.
pub const CMUX_LAUNCH_DRAFT_ERR_PANIC: i32 = -3;

/// One bare launch's held message box.
pub struct CmuxLaunchDraft {
    draft: LaunchDraft,
}

/// A caller-owned copy of `text`. A NUL inside (no C string can carry one)
/// is dropped.
fn to_c(text: String) -> *mut c_char {
    let text = CString::new(text).unwrap_or_else(|error| {
        let mut bytes = error.into_vec();
        bytes.retain(|&b| b != 0);
        CString::new(bytes).unwrap_or_default()
    });
    text.into_raw()
}

/// `ptr` as UTF-8; None when null or not UTF-8.
///
/// # Safety
///
/// `ptr` is null or a NUL-terminated string that outlives the borrow.
unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: a NUL-terminated string from the caller.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Runs `body`, null on a panic.
fn guarded(body: impl FnOnce() -> *mut c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(std::ptr::null_mut())
}

/// One part: a one-key object; a `"text"` part's text is a string or its
/// `"_0"` string.
fn part_from_json(item: &Value) -> Option<Part> {
    let object = item.as_object()?;
    let mut entries = object.iter();
    let (Some((kind, value)), None) = (entries.next(), entries.next()) else {
        return None;
    };
    let text = match (kind.as_str(), value) {
        ("text", Value::String(text)) => Some(text.clone()),
        ("text", Value::Object(fields)) => Some(fields.get("_0")?.as_str()?.to_owned()),
        ("text", _) => return None,
        _ => None,
    };
    Some(Part { text, raw: item.to_string() })
}

fn parts_from_value(value: &Value) -> Option<Vec<Part>> {
    value.as_array()?.iter().map(part_from_json).collect()
}

fn parts_from_json(json: &str) -> Option<Vec<Part>> {
    parts_from_value(&serde_json::from_str(json).ok()?)
}

/// `{"key": ..., "parts": [...]}`, each part's JSON as it came.
fn send_json(send: &HeldSend) -> String {
    let parts: Vec<&str> = send.parts.iter().map(|part| part.raw.as_str()).collect();
    format!(r#"{{"key":{},"parts":[{}]}}"#, Value::String(send.key.clone()), parts.join(","))
}

fn sends_json(sends: &[HeldSend]) -> String {
    format!("[{}]", sends.iter().map(send_json).collect::<Vec<_>>().join(","))
}

/// `CMUX_LAUNCH_DRAFT_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_draft_abi_version() -> u32 {
    CMUX_LAUNCH_DRAFT_ABI_VERSION
}

/// A new, empty hold. Free it with `cmux_launch_draft_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_draft_new() -> *mut CmuxLaunchDraft {
    Box::into_raw(Box::new(CmuxLaunchDraft { draft: LaunchDraft::new() }))
}

/// Frees a hold. Null is ignored.
///
/// # Safety
///
/// `draft` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_free(draft: *mut CmuxLaunchDraft) {
    if !draft.is_null() {
        // SAFETY: from `cmux_launch_draft_new`, freed once.
        drop(unsafe { Box::from_raw(draft) });
    }
}

/// Frees a string this library returned. Null is ignored.
///
/// # Safety
///
/// `text` is null or a string from this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: from `to_c` (`CString::into_raw`), freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// Holds a send: `parts_json` (the parts JSON) under `key`. Returns one of
/// the outcome constants, or an error constant. For ALREADY_DELIVERED,
/// `*chief_out` gets the Chief's id (the caller frees it); otherwise null.
/// `chief_out` may be null.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time; `key` and
/// `parts_json` are NUL-terminated; `chief_out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_hold(
    draft: *mut CmuxLaunchDraft,
    key: *const c_char,
    parts_json: *const c_char,
    chief_out: *mut *mut c_char,
) -> i32 {
    if !chief_out.is_null() {
        // SAFETY: writable per the contract.
        unsafe { *chief_out = std::ptr::null_mut() };
    }
    if draft.is_null() || key.is_null() || parts_json.is_null() {
        return CMUX_LAUNCH_DRAFT_ERR_NULL;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: NUL-terminated strings from the caller.
        let (Some(key), Some(parts)) = (unsafe { str_arg(key) }, unsafe { str_arg(parts_json) })
        else {
            return CMUX_LAUNCH_DRAFT_ERR_INVALID;
        };
        let Some(parts) = parts_from_json(parts) else {
            return CMUX_LAUNCH_DRAFT_ERR_INVALID;
        };
        // SAFETY: a live handle, one thread at a time.
        let draft = unsafe { &mut (*draft).draft };
        let (code, chief) = match draft.hold(key, parts) {
            HoldOutcome::Held => (CMUX_LAUNCH_DRAFT_HELD, None),
            HoldOutcome::Joined => (CMUX_LAUNCH_DRAFT_JOINED, None),
            HoldOutcome::AlreadyDelivered { chief } => {
                (CMUX_LAUNCH_DRAFT_ALREADY_DELIVERED, Some(chief))
            }
            HoldOutcome::Cancelled => (CMUX_LAUNCH_DRAFT_CANCELLED, None),
        };
        if let Some(chief) = chief
            && !chief_out.is_null()
        {
            // SAFETY: writable per the contract.
            unsafe { *chief_out = to_c(chief) };
        }
        code
    }))
    .unwrap_or(CMUX_LAUNCH_DRAFT_ERR_PANIC)
}

/// Names the real Chief `chief`: the held sends go to it, `_next` first.
/// Once: true for the call that named it; false for a later call, one after a
/// cancel, or an argument null or not UTF-8.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time; `chief` is
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_resolve(
    draft: *mut CmuxLaunchDraft,
    chief: *const c_char,
) -> bool {
    if draft.is_null() {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Some(chief) = (unsafe { str_arg(chief) }) else {
            return false;
        };
        // SAFETY: a live handle, one thread at a time.
        unsafe { &mut (*draft).draft }.resolve(chief)
    }))
    .unwrap_or(false)
}

/// The send to hand to the Chief now, as `{"key": "...", "parts": [...]}`:
/// the first one held, once the Chief is named, the same until
/// `_delivered`. Null when there is none (or `draft` is null).
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_next(draft: *const CmuxLaunchDraft) -> *mut c_char {
    if draft.is_null() {
        return std::ptr::null_mut();
    }
    guarded(|| {
        // SAFETY: a live handle, one thread at a time.
        match unsafe { &(*draft).draft }.next() {
            Some(send) => to_c(send_json(send)),
            None => std::ptr::null_mut(),
        }
    })
}

/// The send under `key` was handed to the Chief: it leaves the hold, and a
/// resend of its key is ALREADY_DELIVERED. False when no Chief is named, no
/// send is held under `key`, or an argument is null or not UTF-8.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time; `key` is
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_delivered(
    draft: *mut CmuxLaunchDraft,
    key: *const c_char,
) -> bool {
    if draft.is_null() {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Some(key) = (unsafe { str_arg(key) }) else {
            return false;
        };
        // SAFETY: a live handle, one thread at a time.
        unsafe { &mut (*draft).draft }.delivered(key)
    }))
    .unwrap_or(false)
}

/// The sends not handed over yet, in order, as a JSON array of
/// `{"key": "...", "parts": [...]}`. Null when `draft` is null.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_held(draft: *const CmuxLaunchDraft) -> *mut c_char {
    if draft.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: a live handle, one thread at a time.
    guarded(|| to_c(sends_json(unsafe { &(*draft).draft }.held())))
}

/// Ends the hold before the Chief was named (later sends are CANCELLED) and
/// returns the held sends, in order, as a JSON array of
/// `{"key": "...", "parts": [...]}` (`[]` after a resolve or a second
/// cancel). Null when `draft` is null.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_cancel(draft: *mut CmuxLaunchDraft) -> *mut c_char {
    if draft.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: a live handle, one thread at a time.
    guarded(|| to_c(sends_json(&unsafe { &mut (*draft).draft }.cancel())))
}

/// True once the hold was cancelled (by `_cancel` or `_park`); false before,
/// or when `draft` is null.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_is_cancelled(draft: *const CmuxLaunchDraft) -> bool {
    if draft.is_null() {
        return false;
    }
    // SAFETY: a live handle, one thread at a time.
    catch_unwind(AssertUnwindSafe(|| unsafe { &(*draft).draft }.is_cancelled())).unwrap_or(false)
}

/// The text of `sends_json`, a JSON array of sends' parts arrays
/// (`[[part, ...], ...]`): one send per paragraph, its text parts joined,
/// sends with no text left out (what a cancel gives back to the draft). Null
/// when the argument is null, not UTF-8 or not that JSON.
///
/// # Safety
///
/// `sends_json` is null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_text_of(sends_json: *const c_char) -> *mut c_char {
    guarded(|| {
        // SAFETY: null or a NUL-terminated string from the caller.
        let Some(json) = (unsafe { str_arg(sends_json) }) else {
            return std::ptr::null_mut();
        };
        let sends = serde_json::from_str::<Value>(json).ok().and_then(|value| {
            value.as_array()?.iter().map(parts_from_value).collect::<Option<Vec<_>>>()
        });
        match sends {
            Some(sends) => to_c(text_of(sends.iter().map(Vec::as_slice))),
            None => std::ptr::null_mut(),
        }
    })
}

/// The real Chief's id once named; null before (or when `draft` is null).
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_chief(draft: *const CmuxLaunchDraft) -> *mut c_char {
    if draft.is_null() {
        return std::ptr::null_mut();
    }
    guarded(|| {
        // SAFETY: a live handle, one thread at a time.
        match unsafe { &(*draft).draft }.chief() {
            Some(chief) => to_c(chief.to_owned()),
            None => std::ptr::null_mut(),
        }
    })
}

/// `typed` after the Chief's draft `own`, on a line of its own (`typed` alone
/// when `own` is empty). Null when `typed` is empty (nothing changes) or an
/// argument is null or not UTF-8.
///
/// # Safety
///
/// `own` and `typed` are NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_append(
    own: *const c_char,
    typed: *const c_char,
) -> *mut c_char {
    guarded(|| {
        // SAFETY: NUL-terminated strings from the caller.
        let (Some(own), Some(typed)) = (unsafe { str_arg(own) }, unsafe { str_arg(typed) }) else {
            return std::ptr::null_mut();
        };
        append_draft(own, typed).map_or(std::ptr::null_mut(), to_c)
    })
}

/// Quit's save step: the held sends' text and `typed`, encoded for
/// `cmux_launch_draft_decode` ("" when both are empty). The hold goes on as
/// it was. Null when an argument is null or not UTF-8.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time; `typed` is
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_save_for_quit(
    draft: *const CmuxLaunchDraft,
    typed: *const c_char,
) -> *mut c_char {
    if draft.is_null() {
        return std::ptr::null_mut();
    }
    guarded(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Some(typed) = (unsafe { str_arg(typed) }) else {
            return std::ptr::null_mut();
        };
        // SAFETY: a live handle, one thread at a time.
        to_c(unsafe { &(*draft).draft }.save_for_quit(typed).encode())
    })
}

/// Released before the Chief answered: cancels the hold and returns the held
/// sends' text and `typed`, encoded for `cmux_launch_draft_decode` (after a
/// resolve only `typed`). Null when an argument is null or not UTF-8.
///
/// # Safety
///
/// `draft` is a live handle used by one thread at a time; `typed` is
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_park(
    draft: *mut CmuxLaunchDraft,
    typed: *const c_char,
) -> *mut c_char {
    if draft.is_null() {
        return std::ptr::null_mut();
    }
    guarded(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Some(typed) = (unsafe { str_arg(typed) }) else {
            return std::ptr::null_mut();
        };
        // SAFETY: a live handle, one thread at a time.
        to_c(unsafe { &mut (*draft).draft }.park(typed).encode())
    })
}

/// The draft text a saved or parked string keeps: its held text, then its
/// typed text, a line apart. "" for anything that is not one (null, not
/// UTF-8, another version, garbage).
///
/// # Safety
///
/// `encoded` is null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_draft_decode(encoded: *const c_char) -> *mut c_char {
    guarded(|| {
        // SAFETY: null or a NUL-terminated string from the caller.
        let parked = unsafe { str_arg(encoded) }.map(Parked::decode).unwrap_or_default();
        to_c(parked.text())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn c(text: &str) -> CString {
        CString::new(text).unwrap()
    }

    /// Takes a returned string, freeing it; None for null.
    fn take(ptr: *mut c_char) -> Option<String> {
        if ptr.is_null() {
            return None;
        }
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        unsafe { cmux_launch_draft_string_free(ptr) };
        Some(text)
    }

    fn take_json(ptr: *mut c_char) -> Option<Value> {
        take(ptr).map(|text| serde_json::from_str(&text).unwrap())
    }

    fn hold(draft: *mut CmuxLaunchDraft, key: &str, parts: &str) -> (i32, Option<String>) {
        let mut chief = std::ptr::null_mut();
        let code = unsafe {
            cmux_launch_draft_hold(draft, c(key).as_ptr(), c(parts).as_ptr(), &mut chief)
        };
        (code, take(chief))
    }

    fn resolve(draft: *mut CmuxLaunchDraft, chief: &str) -> bool {
        unsafe { cmux_launch_draft_resolve(draft, c(chief).as_ptr()) }
    }

    /// Hands every send over as the app does: `_next`, then `_delivered`.
    fn deliver_all(draft: *mut CmuxLaunchDraft) -> Vec<Value> {
        let mut sent = Vec::new();
        while let Some(send) = take_json(unsafe { cmux_launch_draft_next(draft) }) {
            let key = c(send["key"].as_str().unwrap());
            assert!(unsafe { cmux_launch_draft_delivered(draft, key.as_ptr()) });
            sent.push(send);
        }
        sent
    }

    /// Swift's synthesized `MessagePart` Codable: a text part with a mention.
    const SWIFT_TEXT: &str =
        r#"{"text":{"_0":"hi","mentions":[{"start":0,"length":2,"participant":"p"}]}}"#;
    /// Swift's synthesized `MessagePart` Codable: an attachment part.
    const SWIFT_ATTACHMENT: &str = r#"{"attachment":{"_0":{"hash":"h","name":"a.png","mime_type":"image/png","byte_count":3}}}"#;

    #[test]
    fn hold_resolve_and_resend_through_the_abi() {
        let draft = cmux_launch_draft_new();
        assert_eq!(
            hold(draft, "a", &format!("[{SWIFT_TEXT},{SWIFT_ATTACHMENT}]")),
            (CMUX_LAUNCH_DRAFT_HELD, None)
        );
        assert_eq!(hold(draft, "a", r#"[{"text":"again"}]"#), (CMUX_LAUNCH_DRAFT_JOINED, None));
        assert_eq!(hold(draft, "b", r#"[{"text":"two"}]"#), (CMUX_LAUNCH_DRAFT_HELD, None));
        assert_eq!(take(unsafe { cmux_launch_draft_chief(draft) }), None);
        assert_eq!(take(unsafe { cmux_launch_draft_next(draft) }), None);

        assert!(resolve(draft, "chief-1"));
        assert!(!resolve(draft, "chief-2"));
        assert_eq!(take(unsafe { cmux_launch_draft_chief(draft) }).as_deref(), Some("chief-1"));
        // A send made now waits behind the held ones.
        assert_eq!(hold(draft, "c", "[]"), (CMUX_LAUNCH_DRAFT_HELD, None));
        let text: Value = serde_json::from_str(SWIFT_TEXT).unwrap();
        let attachment: Value = serde_json::from_str(SWIFT_ATTACHMENT).unwrap();
        let sends = json!([
            {"key": "a", "parts": [text, attachment]},
            {"key": "b", "parts": [{"text": "two"}]},
            {"key": "c", "parts": []}
        ]);
        assert_eq!(take_json(unsafe { cmux_launch_draft_held(draft) }), Some(sends.clone()));
        assert_eq!(Value::Array(deliver_all(draft)), sends);
        assert!(!unsafe { cmux_launch_draft_delivered(draft, c("a").as_ptr()) });
        assert_eq!(
            hold(draft, "a", "[]"),
            (CMUX_LAUNCH_DRAFT_ALREADY_DELIVERED, Some("chief-1".into()))
        );
        assert_eq!(take(unsafe { cmux_launch_draft_cancel(draft) }).as_deref(), Some("[]"));
        assert!(!unsafe { cmux_launch_draft_is_cancelled(draft) });
        unsafe { cmux_launch_draft_free(draft) };
    }

    #[test]
    fn cancel_and_park_through_the_abi() {
        let draft = cmux_launch_draft_new();
        hold(draft, "a", r#"[{"text":"one"}]"#);
        hold(draft, "b", &format!("[{SWIFT_ATTACHMENT}]"));
        hold(draft, "c", r#"[{"text":{"_0":"two","mentions":[]}}]"#);
        let saved =
            take(unsafe { cmux_launch_draft_save_for_quit(draft, c("typed").as_ptr()) }).unwrap();
        assert_eq!(
            take(unsafe { cmux_launch_draft_decode(c(&saved).as_ptr()) }).as_deref(),
            Some("one\ntwo\ntyped")
        );
        let parked = take(unsafe { cmux_launch_draft_park(draft, c("typed").as_ptr()) }).unwrap();
        assert_eq!(parked, saved);
        assert!(unsafe { cmux_launch_draft_is_cancelled(draft) });
        assert_eq!(hold(draft, "d", "[]"), (CMUX_LAUNCH_DRAFT_CANCELLED, None));
        assert_eq!(take(unsafe { cmux_launch_draft_cancel(draft) }).as_deref(), Some("[]"));
        assert!(!resolve(draft, "chief"));
        unsafe { cmux_launch_draft_free(draft) };

        let draft = cmux_launch_draft_new();
        hold(draft, "a", r#"[{"text":"one"},{"text":"more"}]"#);
        hold(draft, "b", r#"[{"text":"two"}]"#);
        assert_eq!(
            take_json(unsafe { cmux_launch_draft_cancel(draft) }),
            Some(json!([
                {"key": "a", "parts": [{"text": "one"}, {"text": "more"}]},
                {"key": "b", "parts": [{"text": "two"}]}
            ]))
        );
        assert!(unsafe { cmux_launch_draft_is_cancelled(draft) });
        unsafe { cmux_launch_draft_free(draft) };
    }

    #[test]
    fn text_of_through_the_abi() {
        let text_of = |json: &str| take(unsafe { cmux_launch_draft_text_of(c(json).as_ptr()) });
        let sends =
            format!(r#"[[{SWIFT_TEXT},{{"text":"!"}}],[{SWIFT_ATTACHMENT}],[{{"text":"two"}}]]"#);
        assert_eq!(text_of(&sends).as_deref(), Some("hi!\ntwo"));
        assert_eq!(text_of("[]").as_deref(), Some(""));
        assert_eq!(text_of("[[]]").as_deref(), Some(""));
        assert_eq!(text_of(r#"[{"text":"x"}]"#), None);
        assert_eq!(text_of("garbage"), None);
        assert!(unsafe { cmux_launch_draft_text_of(std::ptr::null()) }.is_null());
    }

    #[test]
    fn append_and_decode_through_the_abi() {
        let append = |own: &str, typed: &str| {
            take(unsafe { cmux_launch_draft_append(c(own).as_ptr(), c(typed).as_ptr()) })
        };
        assert_eq!(append("", "typed").as_deref(), Some("typed"));
        assert_eq!(append("own", "typed").as_deref(), Some("own\ntyped"));
        assert_eq!(append("own", ""), None);
        assert_eq!(
            take(unsafe { cmux_launch_draft_decode(c("garbage").as_ptr()) }).as_deref(),
            Some("")
        );
        assert_eq!(
            take(unsafe { cmux_launch_draft_decode(std::ptr::null()) }).as_deref(),
            Some("")
        );
    }

    #[test]
    fn bad_arguments_are_refused() {
        let draft = cmux_launch_draft_new();
        assert_eq!(hold(draft, "a", "not json"), (CMUX_LAUNCH_DRAFT_ERR_INVALID, None));
        assert_eq!(hold(draft, "a", r#"{"text":"x"}"#), (CMUX_LAUNCH_DRAFT_ERR_INVALID, None));
        assert_eq!(
            hold(draft, "a", r#"[{"text":"x","attachment":"y"}]"#),
            (CMUX_LAUNCH_DRAFT_ERR_INVALID, None)
        );
        assert_eq!(hold(draft, "a", "[{}]"), (CMUX_LAUNCH_DRAFT_ERR_INVALID, None));
        assert_eq!(hold(draft, "a", r#"["x"]"#), (CMUX_LAUNCH_DRAFT_ERR_INVALID, None));
        assert_eq!(hold(draft, "a", r#"[{"text":1}]"#), (CMUX_LAUNCH_DRAFT_ERR_INVALID, None));
        assert_eq!(
            hold(draft, "a", r#"[{"text":{"mentions":[]}}]"#),
            (CMUX_LAUNCH_DRAFT_ERR_INVALID, None)
        );
        let parts = c("[]");
        assert_eq!(
            unsafe {
                cmux_launch_draft_hold(
                    std::ptr::null_mut(),
                    parts.as_ptr(),
                    parts.as_ptr(),
                    std::ptr::null_mut(),
                )
            },
            CMUX_LAUNCH_DRAFT_ERR_NULL
        );
        assert_eq!(
            unsafe {
                cmux_launch_draft_hold(
                    draft,
                    std::ptr::null(),
                    parts.as_ptr(),
                    std::ptr::null_mut(),
                )
            },
            CMUX_LAUNCH_DRAFT_ERR_NULL
        );
        assert!(!unsafe { cmux_launch_draft_resolve(draft, std::ptr::null()) });
        assert!(!unsafe { cmux_launch_draft_resolve(std::ptr::null_mut(), parts.as_ptr()) });
        assert!(unsafe { cmux_launch_draft_next(std::ptr::null()) }.is_null());
        assert!(!unsafe { cmux_launch_draft_delivered(draft, std::ptr::null()) });
        assert!(!unsafe { cmux_launch_draft_delivered(std::ptr::null_mut(), parts.as_ptr()) });
        assert!(unsafe { cmux_launch_draft_held(std::ptr::null()) }.is_null());
        assert!(unsafe { cmux_launch_draft_cancel(std::ptr::null_mut()) }.is_null());
        assert!(!unsafe { cmux_launch_draft_is_cancelled(std::ptr::null()) });
        assert!(unsafe { cmux_launch_draft_park(draft, std::ptr::null()) }.is_null());
        assert!(
            unsafe { cmux_launch_draft_save_for_quit(std::ptr::null(), parts.as_ptr()) }.is_null()
        );
        assert!(unsafe { cmux_launch_draft_append(std::ptr::null(), parts.as_ptr()) }.is_null());
        // Nothing was held by the refused calls.
        assert_eq!(take(unsafe { cmux_launch_draft_held(draft) }).as_deref(), Some("[]"));
        unsafe {
            cmux_launch_draft_free(draft);
            cmux_launch_draft_free(std::ptr::null_mut());
            cmux_launch_draft_string_free(std::ptr::null_mut());
        }
        assert_eq!(cmux_launch_draft_abi_version(), CMUX_LAUNCH_DRAFT_ABI_VERSION);
    }

    #[test]
    fn a_nul_in_returned_text_is_dropped() {
        let draft = cmux_launch_draft_new();
        hold(draft, "a", r#"[{"text":"a\u0000b"}]"#);
        let sends = take(unsafe { cmux_launch_draft_held(draft) }).unwrap();
        assert!(!sends.contains('\0'));
        let text_of = c(r#"[[{"text":"a\u0000b"}]]"#);
        assert_eq!(
            take(unsafe { cmux_launch_draft_text_of(text_of.as_ptr()) }).as_deref(),
            Some("ab")
        );
        unsafe { cmux_launch_draft_free(draft) };
    }
}
