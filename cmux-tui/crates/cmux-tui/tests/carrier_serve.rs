//! `cmux carrier serve` end to end, on the same stand-in platform, real
//! relay and real daemon as `carrier_dial.rs`: each connection to the
//! served socket is its own carrier dial and its own session, a refused
//! dial closes only its connection, and the socket is 0600 and gone once
//! serve exits.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use carrier_support::*;
use serde_json::{Value, json};

fn serve(world: &World, socket: &Path) -> Child {
    Command::new(BIN)
        .args(["carrier", "serve", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(["--socket", socket.to_str().unwrap()])
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn socket_path(world: &World) -> PathBuf {
    world.dir.path().join("carrier.sock")
}

/// The first stderr line, as JSON, and the rest of stderr.
fn first_line(child: &mut Child) -> (Value, BufReader<ChildStderr>) {
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply = serde_json::from_str(&line(&mut stderr)).unwrap();
    (reply, stderr)
}

fn open(socket: &Path) -> BufReader<UnixStream> {
    let stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(40))).unwrap();
    BufReader::new(stream)
}

/// Sends one line and reads the daemon's echo and its push: the mux
/// connection that answered.
fn ask(conn: &mut BufReader<UnixStream>, id: u32) -> u64 {
    let sent = format!("{{\"cmd\":\"identify\",\"id\":{id}}}\n");
    conn.get_mut().write_all(sent.as_bytes()).unwrap();
    assert_eq!(line(conn), sent, "the line reached the daemon and came back");
    let pushed: Value = serde_json::from_str(&line(conn)).unwrap();
    assert_eq!(pushed["event"], "pushed", "{pushed}");
    pushed["conn"].as_u64().unwrap()
}

fn connect_log(world: &World) -> String {
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    std::fs::read_to_string(log).unwrap_or_default()
}

#[test]
fn two_connections_each_get_their_own_session_on_an_owner_only_socket() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready, json!({"ok": true, "socket": socket.to_str().unwrap(), "route": "carrier"}));
    let mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "the socket is the person's alone");

    let mut first = open(&socket);
    let mut second = open(&socket);
    let a = ask(&mut first, 1);
    let b = ask(&mut second, 2);
    assert_ne!(a, b, "each connection is its own session");
    assert_eq!(ask(&mut first, 3), a, "a connection keeps its session");
    assert!(asked.load(Ordering::SeqCst) >= 2, "each connection dialed with its own grant");

    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0), "serve ends with its stdin");
    assert!(!socket.exists(), "the socket is removed on exit");
    let mut rest = String::new();
    stderr.read_to_string(&mut rest).unwrap();
    assert_eq!(rest, "", "nothing on stderr after the ready line");
    let log = connect_log(&world);
    let connects: Vec<_> = log.lines().collect();
    assert_eq!(connects.len(), 2, "{log}");
    for route in connects {
        assert!(
            route.starts_with(&format!(
                "cloud.connect route=carrier machine={MACHINE} phase=connect outcome=ok ms="
            )),
            "{route}"
        );
    }
}

#[test]
fn a_refused_dial_closes_only_its_connection_and_serve_goes_on() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, _stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");

    let mut kept = open(&socket);
    let session = ask(&mut kept, 1);

    world.status.store(403, Ordering::SeqCst);
    let mut refused = open(&socket);
    let mut read = Vec::new();
    refused.read_to_end(&mut read).unwrap();
    assert!(read.is_empty(), "a refused dial writes nothing before it closes");
    assert_eq!(ask(&mut kept, 2), session, "the other connection is untouched");

    world.status.store(200, Ordering::SeqCst);
    let mut later = open(&socket);
    ask(&mut later, 3);
    assert!(
        connect_log(&world).contains("phase=connect outcome=ticket"),
        "{}",
        connect_log(&world)
    );

    let pid = i32::try_from(child.id()).unwrap();
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0), "SIGTERM ends serve");
    assert!(!socket.exists(), "SIGTERM removes the socket");
}

#[test]
fn the_socket_path_is_claimed_only_when_free_or_stale() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let socket = socket_path(&world);

    std::fs::write(&socket, "not a socket").unwrap();
    let mut child = serve(&world, &socket);
    let (reply, _) = first_line(&mut child);
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "socket", "{reply}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(6));
    assert_eq!(std::fs::read_to_string(&socket).unwrap(), "not a socket", "never replaced");
    std::fs::remove_file(&socket).unwrap();

    // A socket nothing accepts on is stale: serve takes its place.
    drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
    let mut serving = serve(&world, &socket);
    let (ready, _) = first_line(&mut serving);
    assert_eq!(ready["ok"], true, "{ready}");

    // A live one is not.
    let mut second = serve(&world, &socket);
    let (reply, _) = first_line(&mut second);
    assert_eq!(reply["error_code"], "socket", "{reply}");
    assert_eq!(wait(&mut second, Duration::from_secs(20)), Some(6));
    assert!(socket.exists(), "the refused serve left the live socket alone");

    drop(serving.stdin.take());
    assert_eq!(wait(&mut serving, Duration::from_secs(20)), Some(0));
    assert!(!socket.exists());
}
