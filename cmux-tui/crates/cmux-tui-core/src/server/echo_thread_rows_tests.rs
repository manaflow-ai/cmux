//! The daemon's echo path threads run at UserInteractive with blocking
//! disallowed (p02-threads task 210): a served connection's writer, its
//! attach writers, a local PTY surface's reader and the frame producer are
//! registered at that class. Connection readers stay at their own class until
//! the client class is known (task 224).

use std::time::{Duration, Instant};

use serde_json::json;

use super::client_hello::tests::Client;
use crate::echo_thread::ECHO_PATH_QOS;
use crate::server::listen::ServedSession;
use crate::server::*;

fn declared(name: &str) -> Vec<cmux_threads::ThreadQos> {
    cmux_threads::snapshot()
        .into_iter()
        .filter(|row| row.name == name)
        .map(|row| row.declared)
        .collect()
}

/// Waits for `name` to have a row, then asserts every row of it is `qos`.
fn assert_rows(name: &str, qos: cmux_threads::ThreadQos) {
    let deadline = Instant::now() + Duration::from_secs(5);
    let rows = loop {
        let rows = declared(name);
        if !rows.is_empty() || Instant::now() >= deadline {
            break rows;
        }
        std::thread::yield_now();
    };
    let names: Vec<_> = cmux_threads::snapshot().into_iter().map(|row| row.name).collect();
    assert!(!rows.is_empty(), "{name} is registered while it runs: {names:?}");
    assert!(rows.iter().all(|declared| *declared == qos), "{name}: {rows:?}");
}

#[test]
fn connection_writers_and_surface_reader_are_echo_path_threads() {
    let mux = Mux::new_for_test("echo-rows", crate::SurfaceOptions::default());
    let attached = mux.new_workspace(None, Some((20, 8))).unwrap();
    let options = crate::SurfaceOptions {
        command: Some(vec!["sleep".into(), "30".into()]),
        ..crate::SurfaceOptions::default()
    };
    let local = crate::Surface::spawn(9_210, options, Arc::downgrade(&mux)).unwrap();
    let mut client = Client::connect(&mux, "echo-rows");
    assert_eq!(client.request(json!({"cmd": "ping"}))["ok"], true);
    let bytes = client.request(json!({"cmd": "attach-surface", "surface": attached.id}));
    assert_eq!(bytes["ok"], true, "{bytes}");
    let render =
        client.request(json!({"cmd": "attach-surface", "surface": attached.id, "mode": "render"}));
    assert_eq!(render["ok"], true, "{render}");

    let reader = format!("surface-{}-reader", local.id);
    for name in ["mux-line-out", "mux-attach-out", "mux-render-attach-out", &reader] {
        assert_rows(name, ECHO_PATH_QOS);
    }
    assert_rows("surface-frames", ECHO_PATH_QOS);
    drop(client);
    local.kill();
    mux.shutdown();
}

/// RUN-4: a local connection's reader runs request handlers inline for
/// automation clients too, so the accept path does not raise it to the echo
/// class.
#[test]
fn an_accepted_connection_reader_stays_at_the_connection_class() {
    let mux = Mux::new_for_test("echo-rows-conn", crate::SurfaceOptions::default());
    let directory = cmux_unix_socket::short_test_dir("echo-conn");
    let path = directory.path().join("s.sock");
    let listener = transport::listen(&path).unwrap();
    let client = transport::connect(&path).unwrap();
    let session =
        ServedSession { mux: mux.clone(), render_service: Arc::new(RenderService::new()) };
    session.serve(listener.accept().unwrap());

    assert_rows("mux-conn", super::CONNECTION_READER_QOS);
    let _ = client.shutdown(Shutdown::Both);
    mux.shutdown();
}
