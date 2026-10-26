//! The daemon's echo path threads run at UserInteractive with blocking
//! disallowed (p02-threads task 210): a served connection's writer, a local
//! PTY surface's reader and the frame producer are registered at that class.

use serde_json::json;

use super::client_hello::tests::Client;
use crate::echo_thread::ECHO_PATH_QOS;
use crate::server::*;

fn declared(name: &str) -> Vec<cmux_threads::ThreadQos> {
    cmux_threads::snapshot()
        .into_iter()
        .filter(|row| row.name == name)
        .map(|row| row.declared)
        .collect()
}

#[test]
fn connection_writer_and_surface_reader_are_echo_path_threads() {
    let mux = Mux::new_for_test("echo-rows", crate::SurfaceOptions::default());
    let options = crate::SurfaceOptions {
        command: Some(vec!["sleep".into(), "30".into()]),
        ..crate::SurfaceOptions::default()
    };
    let surface = crate::Surface::spawn(9_210, options, Arc::downgrade(&mux)).unwrap();
    let mut client = Client::connect(&mux, "echo-rows");
    assert_eq!(client.request(json!({"cmd": "ping"}))["ok"], true);

    for name in ["mux-line-out", &format!("surface-{}-reader", surface.id), "surface-frames"] {
        let rows = declared(name);
        let names: Vec<_> = cmux_threads::snapshot().into_iter().map(|row| row.name).collect();
        assert!(!rows.is_empty(), "{name} is registered while it runs: {names:?}");
        assert!(rows.iter().all(|qos| *qos == ECHO_PATH_QOS), "{name}: {rows:?}");
    }
    drop(client);
    surface.kill();
}
