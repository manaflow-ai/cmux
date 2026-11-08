//! `cmux carrier serve` end to end, on the same stand-in platform, real
//! relay and real daemon as `carrier_dial.rs`: the first connection to the
//! served socket dials the machine's session and every later one rides it
//! on its own mux stream, a refused dial closes only its connection, and
//! the socket is 0600 and gone once serve exits.
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

/// The next stderr line: a connection's ok line, with `vmk` when given.
fn assert_served(stderr: &mut BufReader<ChildStderr>, vmk: Option<&str>) {
    let served: Value = serde_json::from_str(&line(stderr)).unwrap();
    let mut want = json!({"ok": true, "route": "carrier"});
    if let Some(vmk) = vmk {
        want["vmk"] = json!(vmk);
    }
    assert_eq!(served, want, "one ok line per connected connection");
}

fn serve(world: &World, socket: &Path) -> Child {
    serve_with_token(world, socket, TOKEN)
}

fn serve_with_token(world: &World, socket: &Path, token: &str) -> Child {
    serve_env(world, socket, token, &[])
}

fn serve_env(world: &World, socket: &Path, token: &str, env: &[(&str, &str)]) -> Child {
    Command::new(BIN)
        .args(["carrier", "serve", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(["--socket", socket.to_str().unwrap()])
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", token)
        .envs(env.iter().copied())
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
fn later_connections_ride_the_first_one_s_session_on_an_owner_only_socket() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready, json!({"ok": true, "socket": socket.to_str().unwrap(), "route": "carrier"}));
    let mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "the socket is the person's alone");

    let mut first = open(&socket);
    let a = ask(&mut first, 1);
    let mut second = open(&socket);
    let mut third = open(&socket);
    let b = ask(&mut second, 2);
    let c = ask(&mut third, 3);
    assert!(a != b && b != c && a != c, "each connection is its own mux stream");
    assert_eq!(ask(&mut first, 4), a, "a connection keeps its stream");
    assert_eq!(asked.load(Ordering::SeqCst), 1, "one dial, one grant, for all three");

    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0), "serve ends with its stdin");
    assert!(!socket.exists(), "the socket is removed on exit");
    for _ in 0..3 {
        assert_served(&mut stderr, None);
    }
    let mut rest = String::new();
    stderr.read_to_string(&mut rest).unwrap();
    assert_eq!(rest, "", "one line per connection and nothing else");
    let log = connect_log(&world);
    let routes: Vec<_> = log.lines().filter(|l| l.starts_with("cloud.connect ")).collect();
    assert_eq!(routes.len(), 1, "{log}");
    assert!(
        routes[0].starts_with(&format!(
            "cloud.connect route=carrier machine={MACHINE} phase=connect outcome=ok ms="
        )),
        "{log}"
    );
    let phases: Vec<_> = log.lines().filter(|l| l.starts_with("carrier.phases ")).collect();
    let prefix = format!("carrier.phases machine={MACHINE} phase=");
    assert_eq!(phases.len(), 3, "{log}");
    assert!(
        phases[0].starts_with(&format!("{prefix}connect carrier=relay:0 outcome=ok ")),
        "{log}"
    );
    assert!(phases[0].contains(" lanes="), "{log}");
    for stream in &phases[1..] {
        assert!(
            stream.starts_with(&format!("{prefix}stream carrier=relay:0 outcome=ok ")),
            "{log}"
        );
    }
}

#[test]
fn an_idle_session_is_closed_and_the_next_connection_dials_again() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let socket = socket_path(&world);
    let mut child = serve_env(&world, &socket, TOKEN, &[("CMUX_CARRIER_SERVE_IDLE_MS", "200")]);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");
    let mut first = open(&socket);
    ask(&mut first, 1);
    assert_served(&mut stderr, None);
    drop(first);
    std::thread::sleep(Duration::from_millis(1500));
    let mut later = open(&socket);
    ask(&mut later, 2);
    assert_served(&mut stderr, None);
    assert_eq!(asked.load(Ordering::SeqCst), 2, "the idle session was closed: a new dial");
    let log = connect_log(&world);
    assert_eq!(log.lines().filter(|l| l.contains("phase=connect outcome=ok")).count(), 2, "{log}");
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

#[test]
fn a_refused_dial_closes_only_its_connection_and_serve_goes_on() {
    let world = world(403, Arc::new(AtomicUsize::new(0)));
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");

    let mut refused = open(&socket);
    let mut read = Vec::new();
    refused.read_to_end(&mut read).unwrap();
    assert!(read.is_empty(), "a refused dial writes nothing before it closes");
    let failed = line(&mut stderr);
    assert!(!failed.contains("cloud.connect"), "{failed}");
    let failed: Value = serde_json::from_str(&failed).unwrap();
    assert_eq!(failed["ok"], false, "{failed}");
    assert_eq!(failed["error_code"], "ticket", "{failed}");
    assert_eq!(failed["route"], "carrier", "{failed}");
    assert!(failed["error_detail"].as_str().unwrap().contains("auth.forbidden"), "{failed}");
    assert!(
        connect_log(&world).contains("phase=connect outcome=ticket"),
        "{}",
        connect_log(&world)
    );

    world.status.store(200, Ordering::SeqCst);
    let mut kept = open(&socket);
    let session = ask(&mut kept, 1);
    assert_served(&mut stderr, None);

    // Once a session is held, a later connection rides it: the platform is
    // not asked, so its refusal now reaches no one.
    world.status.store(403, Ordering::SeqCst);
    let mut later = open(&socket);
    assert_ne!(ask(&mut later, 2), session, "its own stream");
    assert_served(&mut stderr, None);
    assert_eq!(ask(&mut kept, 3), session, "the other connection is untouched");

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
    assert_eq!(reply["error_code"], "bad_request", "{reply}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(64));
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
    assert_eq!(reply["error_code"], "bad_request", "{reply}");
    assert_eq!(wait(&mut second, Duration::from_secs(20)), Some(64), "a live listener is refused");
    assert!(socket.exists(), "the refused serve left the live socket alone");

    drop(serving.stdin.take());
    assert_eq!(wait(&mut serving, Duration::from_secs(20)), Some(0));
    assert!(!socket.exists());
}

#[test]
fn a_token_line_on_stdin_is_the_credential_of_later_dials() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let socket = socket_path(&world);
    let mut child = serve_with_token(&world, &socket, "an-expired-credential");
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");

    let mut before = open(&socket);
    let mut read = Vec::new();
    before.read_to_end(&mut read).unwrap();
    assert!(read.is_empty(), "the platform refused the old credential");
    let failed: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(failed["error_code"], "ticket", "{failed}");

    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(format!("{{\"access_token\":\"{TOKEN}\"}}\n\nnot json\n").as_bytes()).unwrap();
    stdin.flush().unwrap();
    // Lines apply in order: once the bad line is refused, the token is in.
    let refused: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "bad_request", "{refused}");

    let mut after = open(&socket);
    ask(&mut after, 1);
    assert_served(&mut stderr, None);
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    assert!(!socket.exists(), "the socket is removed on exit");
}

#[test]
fn a_new_person_s_credential_during_a_running_dial_never_holds_up_stdin() {
    // The platform answers nothing: the first connection's dial stays in
    // its ticket step for the 20 s fetch timeout.
    let world = world(HANG, Arc::new(AtomicUsize::new(0)));
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, _stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");
    let _dialing = UnixStream::connect(&socket).unwrap();
    std::thread::sleep(Duration::from_millis(500));

    // Another person's credential retires what that dial makes, and stdin
    // ending still ends serve at once.
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"{\"access_token\":\"someone-else\"}\n").unwrap();
    drop(stdin);
    assert_eq!(
        wait(&mut child, Duration::from_secs(8)),
        Some(0),
        "serve ends with its stdin while the dial still runs"
    );
    assert!(!socket.exists(), "the socket is removed on exit");
}

#[test]
fn each_connected_connection_says_the_grant_s_vmk() {
    let world = world_signed(
        200,
        Arc::new(AtomicUsize::new(0)),
        "mux-control",
        DaemonKey::Real,
        Some("owner"),
    );
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");
    let mut conn = open(&socket);
    ask(&mut conn, 1);
    assert_served(&mut stderr, Some("owner"));
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

#[test]
fn an_overlong_last_stdin_line_is_refused_before_serve_exits() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let socket = socket_path(&world);
    let mut child = serve(&world, &socket);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all("x".repeat(40 * 1024).as_bytes()).unwrap();
    drop(stdin);
    let refused: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(refused["error_code"], "bad_request", "{refused}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    assert!(!socket.exists());
}

/// Writes `lines` on serve's stdin and then a line it refuses, and reads
/// that refusal: the lines before it are applied by then.
fn apply(stdin: &mut std::process::ChildStdin, stderr: &mut BufReader<ChildStderr>, lines: &str) {
    stdin.write_all(format!("{lines}not json\n").as_bytes()).unwrap();
    stdin.flush().unwrap();
    let refused: Value = serde_json::from_str(&line(stderr)).unwrap();
    assert_eq!(refused["error_code"], "bad_request", "{refused}");
}

#[test]
fn a_carrier_answer_on_stdin_starts_the_next_dial_without_asking_for_it() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let socket = socket_path(&world);
    // A short idle close, so each connection below dials its own session.
    let mut child = serve_env(&world, &socket, TOKEN, &[("CMUX_CARRIER_SERVE_IDLE_MS", "100")]);
    let (ready, mut stderr) = first_line(&mut child);
    assert_eq!(ready["ok"], true, "{ready}");
    let idle = || std::thread::sleep(Duration::from_millis(1000));
    // A first connection asks as usual; its ask names this serve's device key.
    let mut first = open(&socket);
    ask(&mut first, 1);
    assert_served(&mut stderr, None);
    drop(first);
    let device = world.keys.lock().unwrap()[0].clone().expect("a dial asks with its key");
    let mut stdin = child.stdin.take().unwrap();
    idle();

    // A spare claim's answer has the daemon key: the dial asks nothing.
    apply(&mut stdin, &mut stderr, &world.answer_line(&device, true));
    let before = asked.load(Ordering::SeqCst);
    let mut spare = open(&socket);
    ask(&mut spare, 2);
    assert_served(&mut stderr, None);
    assert_eq!(asked.load(Ordering::SeqCst), before, "the handed-over answer was enough");
    drop(spare);
    idle();

    // A fresh create's has none yet: one ticket-only ask for the key while
    // the relay holds the connect, and the handshake is pinned to it.
    apply(&mut stdin, &mut stderr, &world.answer_line(&device, false));
    let mut fresh = open(&socket);
    ask(&mut fresh, 3);
    assert_served(&mut stderr, None);
    assert_eq!(asked.load(Ordering::SeqCst), before + 1, "one ask, for the daemon key");
    assert_eq!(world.keys.lock().unwrap().last(), Some(&None), "a ticket-only ask mints no grant");
    drop(fresh);
    idle();

    // One dial takes it: the next asks as before, with its key.
    let mut later = open(&socket);
    ask(&mut later, 4);
    assert_served(&mut stderr, None);
    assert_eq!(world.keys.lock().unwrap().last(), Some(&Some(device)));
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}
