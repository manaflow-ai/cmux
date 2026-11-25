//! The app's connect never waits without a deadline. A route that accepts the TCP connect and
//! then never answers (a black hole mid-open) made `cmux_terminal_client_connect_route` with a
//! timeout of 0 block the embedding app's call forever; it now returns an error that names the
//! stalled stage and the peer, within the direct dial's bound.

use std::ffi::{CStr, CString, c_char};
use std::net::TcpListener;
use std::time::{Duration, Instant};

use cmux_remote::crypto::StaticIdentity;
use cmux_remote::identity::ClientIdentityStore;
use cmux_remote::provider::DIRECT_DIAL_TIMEOUT;
use cmux_terminal_client::cmux_terminal_client_connect_route;
use tempfile::tempdir;

#[test]
fn a_route_that_black_holes_the_upgrade_returns_an_error_instead_of_hanging() {
    // Accepts every connect and never reads or writes: the upgrade is never answered.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        let mut held = Vec::new();
        for stream in listener.incoming() {
            held.push(stream);
        }
    });
    let route = format!("ws://{address}/v1/link");

    // An enrolled daemon for the route, so the connect dials without an invitation.
    let state = tempdir().unwrap();
    let daemon_key = StaticIdentity::generate().unwrap().public_key();
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        ClientIdentityStore::load_or_create(state.path())
            .unwrap()
            .pin_daemon("black hole".into(), daemon_key, vec![route.clone()])
            .await
            .unwrap();
    });

    let route_c = CString::new(route).unwrap();
    let state_c = CString::new(state.path().to_str().unwrap()).unwrap();
    let device_c = CString::new("connect-deadline").unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut error = vec![0 as c_char; 1024];
        let started = Instant::now();
        // SAFETY: every string is NUL-terminated and outlives the call; the error buffer is
        // writable for its length; a null tunnel is allowed.
        let client = unsafe {
            cmux_terminal_client_connect_route(
                route_c.as_ptr(),
                state_c.as_ptr(),
                device_c.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                error.as_mut_ptr(),
                error.len(),
                0,
            )
        };
        // SAFETY: the library wrote a NUL-terminated string into the buffer on failure.
        let message = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy().into_owned();
        let _ = sender.send((client.is_null(), message, started.elapsed()));
    });

    // Past every bound the connect has: still blocked means it hangs, as it did before.
    let watchdog = DIRECT_DIAL_TIMEOUT + Duration::from_secs(30);
    let (failed, message, took) = receiver
        .recv_timeout(watchdog)
        .unwrap_or_else(|_| panic!("the connect still blocked after {watchdog:?}"));
    assert!(failed, "a connect to a black hole returned a client");
    assert!(
        message.contains(&format!("websocket upgrade to {address} did not finish within 12 s")),
        "the error does not name the stage and the peer: {message}"
    );
    assert!(took >= DIRECT_DIAL_TIMEOUT, "the connect gave up early, after {took:?}");
    assert!(took < DIRECT_DIAL_TIMEOUT + Duration::from_secs(10), "the connect took {took:?}");
}
