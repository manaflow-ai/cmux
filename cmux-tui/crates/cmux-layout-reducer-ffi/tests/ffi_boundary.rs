//! Every export runs its body in cmux-ffi-guard's boundary: a panic returns
//! the documented error value and is recorded under the export's name, the
//! process keeps running.

use cmux_ffi_guard::testing::{panic_through, panic_through_boundaries, unguarded_exports};
use cmux_layout_reducer_ffi::focus::{
    CmuxFocusEvent, CmuxFocusStr, cmux_focus_changes_view, cmux_focus_current, cmux_focus_free,
    cmux_focus_import_json, cmux_focus_new, cmux_focus_send,
};
use cmux_layout_reducer_ffi::{
    ERR_INVALID, ERR_PANIC, cmux_layout_reducer_json, cmux_sidebar_mirror_free,
    cmux_sidebar_mirror_load, cmux_sidebar_mirror_load_typed, cmux_sidebar_mirror_new,
    cmux_sidebar_mirror_string_free,
};

#[test]
fn every_export_is_guarded() {
    for (file, source) in
        [("lib.rs", include_str!("../src/lib.rs")), ("focus.rs", include_str!("../src/focus.rs"))]
    {
        assert_eq!(unguarded_exports(source), Vec::<String>::new(), "{file}");
    }
}

fn recorded(name: &str, got: Option<String>) {
    assert_eq!(got.as_deref(), Some(name));
}

fn empty_event() -> CmuxFocusEvent {
    let none = CmuxFocusStr { offset: 0, len: 0 };
    CmuxFocusEvent {
        kind: 0,
        source: 0,
        target: 0,
        target_keyboard: 0,
        value: 0,
        reserved: [0; 3],
        list_count: 0,
        reserved2: 0,
        generation: 0,
        a: none,
        b: none,
        c: none,
        list: std::ptr::null(),
    }
}

#[test]
fn a_guarded_panic_returns_the_error_value() {
    let mut out = [0_u8; 64];
    let mut len = 0;
    let (code, name) = panic_through(|| {
        // SAFETY: a NUL-terminated operation and a writable buffer and length.
        unsafe {
            cmux_layout_reducer_json(
                b"{}".as_ptr(),
                2,
                c"resolve".as_ptr(),
                out.as_mut_ptr(),
                out.len(),
                &mut len,
            )
        }
    });
    assert_eq!(code, ERR_PANIC);
    recorded("cmux_layout_reducer_json", name);

    let mirror = cmux_sidebar_mirror_new();
    // SAFETY: a live mirror, freed below.
    let (text, name) =
        panic_through(|| unsafe { cmux_sidebar_mirror_load(mirror, b"{}".as_ptr(), 2) });
    recorded("cmux_sidebar_mirror_load", name);
    assert!(!text.is_null());
    // SAFETY: a NUL-terminated string from the mirror, freed below.
    let reply = unsafe { std::ffi::CStr::from_ptr(text) }.to_str().unwrap().to_owned();
    assert_eq!(reply, r#"{"error":"panic"}"#);
    // SAFETY: freed once.
    unsafe { cmux_sidebar_mirror_string_free(text) };
    // SAFETY: a live mirror.
    let (typed, name) =
        panic_through(|| unsafe { cmux_sidebar_mirror_load_typed(mirror, b"{}".as_ptr(), 2) });
    recorded("cmux_sidebar_mirror_load_typed", name);
    assert!(typed.is_null());
    // SAFETY: freed once.
    unsafe { cmux_sidebar_mirror_free(mirror) };
}

#[test]
fn a_focus_panic_answers_the_recovered_state() {
    let focus = cmux_focus_new();
    let event = empty_event();
    // SAFETY: a live handle and a readable event.
    let (reply, name) =
        panic_through(|| unsafe { cmux_focus_send(focus, &event, std::ptr::null(), 0) });
    recorded("cmux_focus_send", name);
    assert!(!reply.is_null());
    // SAFETY: the reply belongs to the live handle until its next call.
    assert_eq!(unsafe { (*reply).ok }, 0);
    // SAFETY: a live handle.
    let current = unsafe { cmux_focus_current(focus) };
    // SAFETY: as above.
    assert_eq!(unsafe { (*current).ok }, 1, "the machine still answers after the panic");

    // SAFETY: a readable event.
    let (changes, name) =
        panic_through(|| unsafe { cmux_focus_changes_view(&event, std::ptr::null(), 0) });
    assert_eq!((changes, name.as_deref()), (0, Some("cmux_focus_changes_view")));
    // SAFETY: a live handle.
    let (code, name) =
        panic_through(|| unsafe { cmux_focus_import_json(focus, b"{}".as_ptr(), 2) });
    assert_eq!((code, name.as_deref()), (ERR_INVALID, Some("cmux_focus_import_json")));
    // SAFETY: freed once.
    unsafe { cmux_focus_free(focus) };
}

#[test]
fn a_focus_panic_in_the_recovery_answers_the_failed_reply() {
    let focus = cmux_focus_new();
    let event = empty_event();
    // The reduction's boundary and then the recovery's both panic.
    // SAFETY: a live handle and a readable event.
    let (reply, unfired, name) = panic_through_boundaries(2, || unsafe {
        cmux_focus_send(focus, &event, std::ptr::null(), 0)
    });
    assert_eq!(unfired, 0, "both armed boundaries ran inside the export");
    recorded("cmux_focus_send", name);
    assert!(!reply.is_null());
    // SAFETY: the reply belongs to the live handle until its next call.
    let reply = unsafe { &*reply };
    // The failed reply, not the recovered one (`changed` 1).
    assert_eq!((reply.ok, reply.changed, reply.effect_count), (0, 0, 0));
    // SAFETY: a live handle.
    let current = unsafe { cmux_focus_current(focus) };
    assert!(!current.is_null());
    // SAFETY: as above.
    assert_eq!(unsafe { (*current).ok }, 1, "the machine still answers after both panics");
    // SAFETY: freed once.
    unsafe { cmux_focus_free(focus) };
}
