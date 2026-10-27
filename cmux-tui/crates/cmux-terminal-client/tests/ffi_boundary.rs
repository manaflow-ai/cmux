//! Every export of the iOS terminal client runs its body in cmux-ffi-guard's
//! boundary: a panic returns the export's documented error value, writes
//! "terminal client panicked" to its error buffer when it has one, and is
//! recorded under the export's name; the app keeps running
//! (p10-stability-154).

use std::ffi::{CStr, c_char};

use cmux_ffi_guard::testing::{panic_through, unguarded_exports};
use cmux_terminal_client::{
    cmux_terminal_client_connect, cmux_terminal_client_connect_route,
    cmux_terminal_client_copy_frame, cmux_terminal_client_create_terminal_in_workspace,
    cmux_terminal_client_disconnect, cmux_terminal_client_has_exited,
    cmux_terminal_client_list_terminals, cmux_terminal_client_send,
    cmux_terminal_client_string_free, cmux_wireguard_net_route_is_allowed,
};

const SOURCE: &str = include_str!("../src/lib.rs");

#[test]
fn every_export_is_guarded() {
    assert_eq!(unguarded_exports(SOURCE), Vec::<String>::new());
    let exports = SOURCE.matches("pub unsafe extern \"C\" fn ").count();
    let guards = SOURCE.matches("ffi_boundary(\"cmux_").count();
    assert_eq!(exports, guards, "export count == guard count");
    assert_eq!(exports, 33);
}

fn error_text(buffer: &[c_char]) -> String {
    // SAFETY: the export NUL-terminates inside the buffer.
    unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy().into_owned()
}

#[test]
fn a_guarded_panic_returns_the_error_value_and_writes_the_error() {
    let invitation = c"cmux://invalid";
    let terminal = c"term";
    let mut error = [0 as c_char; 128];
    // SAFETY: readable strings and a writable error buffer of its length.
    let (client, name) = panic_through(|| unsafe {
        cmux_terminal_client_connect(
            invitation.as_ptr(),
            terminal.as_ptr(),
            error.as_mut_ptr(),
            error.len(),
        )
    });
    assert!(client.is_null());
    assert_eq!(name.as_deref(), Some("cmux_terminal_client_connect"));
    assert_eq!(error_text(&error), "terminal client panicked");

    let route = c"ws://127.0.0.1:1";
    let state_dir = c"/nonexistent";
    let device = c"test";
    let mut error = [0 as c_char; 128];
    // SAFETY: as above; a null tunnel and invitation are allowed.
    let (client, name) = panic_through(|| unsafe {
        cmux_terminal_client_connect_route(
            route.as_ptr(),
            state_dir.as_ptr(),
            device.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            error.as_mut_ptr(),
            error.len(),
            0,
        )
    });
    assert!(client.is_null());
    assert_eq!(name.as_deref(), Some("cmux_terminal_client_connect_route"));
    assert_eq!(error_text(&error), "terminal client panicked");

    let mut error = [0 as c_char; 128];
    // SAFETY: a null client is allowed; the error buffer is writable.
    let (text, name) = panic_through(|| unsafe {
        cmux_terminal_client_list_terminals(
            std::ptr::null_mut(),
            error.as_mut_ptr(),
            error.len(),
            0,
        )
    });
    assert!(text.is_null());
    assert_eq!(name.as_deref(), Some("cmux_terminal_client_list_terminals"));
    assert_eq!(error_text(&error), "terminal client panicked");

    let mut error = [0 as c_char; 128];
    // SAFETY: a null tunnel is allowed; the route is readable.
    let (allowed, name) = panic_through(|| unsafe {
        cmux_wireguard_net_route_is_allowed(
            std::ptr::null(),
            route.as_ptr(),
            error.as_mut_ptr(),
            error.len(),
        )
    });
    assert!(!allowed);
    assert_eq!(name.as_deref(), Some("cmux_wireguard_net_route_is_allowed"));
    assert_eq!(error_text(&error), "terminal client panicked");
}

#[test]
fn a_guarded_panic_in_an_export_without_an_error_buffer_returns_its_error_value() {
    let bytes = b"ls\r";
    // SAFETY: a null client is allowed; the bytes are readable.
    let (sent, name) = panic_through(|| unsafe {
        cmux_terminal_client_send(std::ptr::null_mut(), bytes.as_ptr(), bytes.len())
    });
    assert_eq!((sent, name.as_deref()), (false, Some("cmux_terminal_client_send")));

    let mut frame = [0 as c_char; 16];
    // SAFETY: a null client is allowed; the buffer is writable.
    let (copied, name) = panic_through(|| unsafe {
        cmux_terminal_client_copy_frame(std::ptr::null(), frame.as_mut_ptr(), frame.len())
    });
    assert_eq!((copied, name.as_deref()), (0, Some("cmux_terminal_client_copy_frame")));

    // SAFETY: a null client is allowed.
    let (exited, name) =
        panic_through(|| unsafe { cmux_terminal_client_has_exited(std::ptr::null()) });
    assert_eq!((exited, name.as_deref()), (false, Some("cmux_terminal_client_has_exited")));

    // SAFETY: null is allowed.
    let ((), name) =
        panic_through(|| unsafe { cmux_terminal_client_disconnect(std::ptr::null_mut()) });
    assert_eq!(name.as_deref(), Some("cmux_terminal_client_disconnect"));

    // SAFETY: null is allowed.
    let ((), name) =
        panic_through(|| unsafe { cmux_terminal_client_string_free(std::ptr::null_mut()) });
    assert_eq!(name.as_deref(), Some("cmux_terminal_client_string_free"));
}

#[test]
fn unguarded_failures_keep_their_own_errors() {
    let mut error = [0 as c_char; 128];
    // SAFETY: a null client is allowed; the error buffer is writable.
    let text = unsafe {
        cmux_terminal_client_list_terminals(
            std::ptr::null_mut(),
            error.as_mut_ptr(),
            error.len(),
            0,
        )
    };
    assert!(text.is_null());
    assert_eq!(error_text(&error), "client is null");

    let workspace = c"current";
    let mut error = [0 as c_char; 128];
    // SAFETY: a null client is allowed; the strings and buffer are valid.
    let text = unsafe {
        cmux_terminal_client_create_terminal_in_workspace(
            std::ptr::null_mut(),
            workspace.as_ptr(),
            std::ptr::null(),
            error.as_mut_ptr(),
            error.len(),
            0,
        )
    };
    assert!(text.is_null());
    assert_eq!(error_text(&error), "client is null");

    let route = c"ws://127.0.0.1:1";
    let mut error = [0 as c_char; 128];
    // SAFETY: a null tunnel is allowed; the route and buffer are valid.
    let allowed = unsafe {
        cmux_wireguard_net_route_is_allowed(
            std::ptr::null(),
            route.as_ptr(),
            error.as_mut_ptr(),
            error.len(),
        )
    };
    assert!(!allowed);
    assert_eq!(error_text(&error), "wireguard tunnel is null");
}
