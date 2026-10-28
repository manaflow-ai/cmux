//! The daemon's echo path threads run at UserInteractive with blocking
//! disallowed (p02-threads task 210): the read loop a local PTY surface
//! reads on, the sequenced pool's input workers its attach views drain on
//! and the frame producer are registered at that class. Its attach views
//! hold no thread, and neither does a connection: the one
//! `mux-io` loop reads and writes it.

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

    // A local PTY reads on its owner's read loop, not a thread of its own.
    let reader = crate::mux::terminal_work::read_loop::READ_LOOP_THREAD;
    // The views' output is a drain on the sequenced pool's input workers,
    // which keep the echo class, not a thread per view.
    for name in ["mux-seq-input", reader] {
        assert_rows(name, ECHO_PATH_QOS);
    }
    for name in ["mux-attach-out", "mux-render-attach-out", "mux-attach-notifications"] {
        assert!(declared(name).is_empty(), "{name} is a thread per view");
    }
    assert_rows("surface-frames", ECHO_PATH_QOS);
    drop(client);
    local.kill();
    mux.shutdown();
}

/// An accepted connection starts no thread. The one
/// `mux-io` loop, at user-initiated, reads and writes it; no `mux-conn` or
/// `mux-line-out` thread exists.
#[test]
fn an_accepted_connection_is_served_by_the_mux_io_loop() {
    use std::io::{BufRead, BufReader, Write};

    let mux = Mux::new_for_test("echo-rows-conn", crate::SurfaceOptions::default());
    let directory = cmux_unix_socket::short_test_dir("echo-conn");
    let path = directory.path().join("s.sock");
    let listener = transport::listen(&path).unwrap();
    let mut client = transport::connect(&path).unwrap();
    let session =
        ServedSession { mux: mux.clone(), render_service: Arc::new(RenderService::new()) };
    session.serve(listener.accept().unwrap());

    client.write_all(b"{\"id\":1,\"cmd\":\"ping\"}\n").unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reply = String::new();
    BufReader::new(client.try_clone_box().unwrap()).read_line(&mut reply).unwrap();
    let reply: Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");

    assert_rows(mux_io::MUX_IO_THREAD, mux_io::MUX_IO_QOS);
    for gone in ["mux-conn", "mux-line-out", "mux-events-out"] {
        assert!(declared(gone).is_empty(), "no {gone} thread");
    }
    let _ = client.shutdown(Shutdown::Both);
    mux.shutdown();
}
