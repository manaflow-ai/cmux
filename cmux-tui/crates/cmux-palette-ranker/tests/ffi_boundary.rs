//! Every export runs its body in cmux-ffi-guard's boundary: a panic returns
//! the documented error value and is recorded under the export's name, the
//! process keeps running.

use cmux_ffi_guard::testing::{panic_through, unguarded_exports};
use cmux_palette_ranker::ffi::{
    ERR_PANIC, OK, cmux_palette_ranker_free, cmux_palette_ranker_install, cmux_palette_ranker_new,
    cmux_palette_ranker_rank,
};

#[test]
fn every_export_is_guarded() {
    assert_eq!(unguarded_exports(include_str!("../src/ffi.rs")), Vec::<String>::new());
}

#[test]
fn a_guarded_panic_returns_the_error_value() {
    let (handle, name) = panic_through(|| cmux_palette_ranker_new());
    assert!(handle.is_null());
    assert_eq!(name.as_deref(), Some("cmux_palette_ranker_new"));

    let ranker = cmux_palette_ranker_new();
    let entries = br#"[{"title": "New Tab"}]"#;
    // SAFETY: a live ranker and readable entries, freed below.
    let (code, name) = panic_through(|| unsafe {
        cmux_palette_ranker_install(ranker, 1, entries.as_ptr(), entries.len())
    });
    assert_eq!((code, name.as_deref()), (ERR_PANIC, Some("cmux_palette_ranker_install")));

    let request = br#"{"operation": "rank", "query": "tab", "now": 0}"#;
    let mut response = std::ptr::null();
    let mut response_len = 0;
    // SAFETY: a live ranker, a readable request and writable outs.
    let (code, name) = panic_through(|| unsafe {
        cmux_palette_ranker_rank(
            ranker,
            request.as_ptr(),
            request.len(),
            &mut response,
            &mut response_len,
        )
    });
    assert_eq!((code, name.as_deref()), (ERR_PANIC, Some("cmux_palette_ranker_rank")));
    // SAFETY: the response stays valid until the next call on the ranker.
    let message = unsafe { std::slice::from_raw_parts(response, response_len) };
    assert_eq!(message, b"palette ranker panicked");

    // The ranker still works after the panics.
    // SAFETY: as above.
    let code = unsafe { cmux_palette_ranker_install(ranker, 1, entries.as_ptr(), entries.len()) };
    assert_eq!(code, OK);
    // SAFETY: freed once.
    unsafe { cmux_palette_ranker_free(ranker) };
}
