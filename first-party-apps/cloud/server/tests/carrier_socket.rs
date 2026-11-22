//! The server reaches a Cloud machine only through the Mac app's carrier
//! (src/link/dial.rs): each new link asks the host for the app's carrier
//! socket of the machine (`relay.carrier`), and every stream and every file
//! op is one connection to that socket. The server spawns no process and
//! holds no credential; a refusal of the app's carrier is a typed op error.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::link::{Attach, CarrierSpawner, LinkPaths};
use cmux_cloud::{Origin, Request, Server};
use common::{FakeControlPlane, carrier_socket_of};
use serde_json::json;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

fn connect() -> Request {
    Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" })).key("c-1")
}

#[test]
fn a_connect_asks_the_app_for_its_carrier_socket_and_streams_go_there() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let up = s.handle(&connect()).map(|r| r["state"].clone());
    assert_eq!(up.as_ref().ok(), Some(&json!("up")), "{up:?}");
    assert_eq!(s.control_plane().carrier_asks, ["vm-alpha01"], "one ask, naming the machine");
    let command = spawner.log().commands[0].clone();
    assert_eq!(command.upstream, carrier_socket_of("vm-alpha01"));
    // A connect over the up link asks nothing more.
    let again = s.handle(&connect()).map(|r| r["state"].clone());
    assert_eq!(again.as_ref().ok(), Some(&json!("up")), "{again:?}");
    assert_eq!(s.control_plane().carrier_asks.len(), 1);
}

#[test]
fn each_carrier_refusal_is_a_typed_connect_error_and_nothing_spawns() {
    for (code, message, ours, retryable) in [
        ("ticket", "the platform answered 403", "cmux.cloud.forbidden", false),
        ("ticket", "the machine is paused", "cmux.cloud.machine_paused", true),
        ("service_refused", "not the owner", "cmux.cloud.forbidden", false),
        ("relay", "the relay dropped", "cmux.cloud.link_down", true),
        ("parked_timeout", "never registered", "cmux.cloud.link_down", true),
        ("handshake", "the daemon key differs", "cmux.cloud.link_down", true),
        ("bad_request", "usage", "cmux.cloud.link_unavailable", false),
        ("cloud.machine.not_found", "no session", "cmux.cloud.not_found", false),
        ("unavailable", "no bundled cmux-tui", "cmux.cloud.link_unavailable", true),
        ("socket", "another cmux", "cmux.cloud.link_unavailable", true),
    ] {
        let spawner = FakeSpawner::default();
        let mut cloud = FakeControlPlane::with(&["vm-get"]);
        cloud.refuse_carrier(code, message);
        let mut s = Server::with_attach(cloud, attach(&spawner, &FakeTransport::default()));
        let error = s.handle(&connect()).expect_err("refused");
        assert_eq!(error.code, ours, "{code} {message}: {error:?}");
        assert_eq!(error.retryable, retryable, "{code} {message}: {error:?}");
        assert!(error.message.contains("vm-alpha01"), "{}", error.message);
        assert_eq!(spawner.spawns(), 0, "{code}: no link without the app's socket");
    }
}

#[test]
fn a_file_op_goes_to_the_apps_carrier_socket() {
    let dir = std::env::temp_dir().join(format!("cmux-carrier-job-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("upload.txt");
    std::fs::write(&local, b"payload").unwrap();
    let mut rig = edge_common::rig(&["vm-get", "connect-info-fs"]);
    let push = Request::new(
        "cloud.file.push",
        json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/upload.txt"}),
    )
    .key("p-1")
    .origin(Origin::User);
    rig.server.handle(&push).expect("push");
    rig.server.wait_transfers();
    let job = rig.transfer.log().jobs[0].clone();
    assert_eq!(job.target.socket, carrier_socket_of("vm-alpha01"));
    assert_eq!(rig.server.control_plane().carrier_asks, ["vm-alpha01"]);
    std::fs::remove_dir_all(dir).unwrap();
}

/// The app's `carrier serve` stand-in: answers each line with `echo <line>`.
fn echo_serve(socket: &Path) {
    let listener = UnixListener::bind(socket).expect("the fake serve listens");
    std::thread::spawn(move || {
        for connection in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().expect("clone");
                for line in BufReader::new(connection).lines().map_while(Result::ok) {
                    let _ = writeln!(writer, "echo {line}");
                }
            });
        }
    });
}

#[test]
fn the_real_carrier_carries_a_stream_over_the_socket_the_app_answered() {
    let dir = PathBuf::from("/tmp").join(format!("cx-carrier-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let upstream = dir.join("serve.sock");
    echo_serve(&upstream);
    let mut cloud = FakeControlPlane::with(&["vm-get"]);
    cloud.set_carrier_socket(upstream);
    let paths = LinkPaths {
        state_dir: dir.join("state"),
        socket_dir: dir.join("sockets"),
        device_name: "test-mac".into(),
    };
    let attach =
        Attach::new(Box::new(CarrierSpawner), Some(paths), Box::new(FakeTransport::default()));
    let mut s = Server::with_attach(cloud, attach);
    let up = s.handle(&connect()).expect("up");
    let socket = up["socket"].as_str().expect("the carrier's local socket").to_owned();
    let mut stream = UnixStream::connect(&socket).expect("a carrier stream");
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    writeln!(stream, "{{\"cmd\":\"identify\",\"id\":1}}").unwrap();
    let mut answer = String::new();
    BufReader::new(stream.try_clone().unwrap()).read_line(&mut answer).expect("answer");
    assert_eq!(answer, "echo {\"cmd\":\"identify\",\"id\":1}\n");
    drop(stream);
    s.handle(
        &Request::new("cloud.machine.disconnect", json!({ "machine": "vm-alpha01" })).key("d-1"),
    )
    .expect("disconnect");
    std::fs::remove_dir_all(dir).unwrap();
}
