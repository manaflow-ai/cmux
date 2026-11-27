//! `cmux carrier serve`'s quiet socket (`<socket>.quiet`) end to end, on the
//! stand-in platform, real relay and real daemon of `carrier_serve.rs`: with
//! no held session and a paused machine a quiet connection is closed without
//! asking for a carrier (the request that starts a paused machine); with a
//! held session it rides it; and the machine's state is read at most once
//! per recheck time.
#![cfg(target_os = "linux")]

use crate::carrier_support;

use std::io::{BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use carrier_support::*;
use serde_json::{Value, json};

fn serve(world: &World, socket: &Path, env: &[(&str, &str)]) -> Child {
    Command::new(BIN)
        .args(["carrier", "serve", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(["--socket", socket.to_str().unwrap()])
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .envs(env.iter().copied())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn sockets(world: &World) -> (PathBuf, PathBuf) {
    let socket = world.dir.path().join("carrier.sock");
    let quiet = world.dir.path().join("carrier.sock.quiet");
    (socket, quiet)
}

/// Starts serve and reads its ready line.
fn started(world: &World, env: &[(&str, &str)]) -> (Child, BufReader<ChildStderr>) {
    let (socket, _) = sockets(world);
    let mut child = serve(world, &socket, env);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let ready: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(ready["ok"], true, "{ready}");
    (child, stderr)
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

/// A quiet connection that serve closes having written nothing.
fn refused(quiet: &Path) {
    let mut conn = open(quiet);
    let mut read = Vec::new();
    conn.read_to_end(&mut read).unwrap();
    assert!(read.is_empty(), "a quiet refusal writes nothing before it closes");
}

fn connect_log(world: &World) -> String {
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    std::fs::read_to_string(log).unwrap_or_default()
}

/// The connect log's `carrier.quiet` lines, once there are `count` of them.
fn quiet_lines(world: &World, count: usize) -> Vec<String> {
    let started = Instant::now();
    loop {
        let log = connect_log(world);
        let lines: Vec<String> =
            log.lines().filter(|l| l.starts_with("carrier.quiet ")).map(str::to_owned).collect();
        if lines.len() >= count {
            return lines;
        }
        assert!(started.elapsed() < Duration::from_secs(20), "{count} quiet lines: {log}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Waits until `value` reads `want`.
fn settles(what: &str, value: impl Fn() -> usize, want: usize) {
    let started = Instant::now();
    while value() != want {
        assert!(started.elapsed() < Duration::from_secs(20), "{what}: {} not {want}", value());
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Ends serve and returns what it wrote to stderr after the lines read.
fn stopped(mut child: Child, mut stderr: BufReader<ChildStderr>) -> String {
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0), "serve ends with its stdin");
    let mut rest = String::new();
    stderr.read_to_string(&mut rest).unwrap();
    rest
}

fn assert_served(stderr: &mut BufReader<ChildStderr>) {
    let served: Value = serde_json::from_str(&line(stderr)).unwrap();
    assert_eq!(served, json!({"ok": true, "route": "carrier"}), "one ok line per stream");
}

#[test]
fn a_quiet_connection_to_a_paused_machine_with_no_session_asks_for_no_carrier() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    world.machine.set("paused");
    let (child, stderr) = started(&world, &[]);
    let (socket, quiet) = sockets(&world);
    let mode = std::fs::metadata(&quiet).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "the quiet socket is the person's alone");

    refused(&quiet);
    let lines = quiet_lines(&world, 1);
    assert!(
        lines[0]
            .starts_with(&format!("carrier.quiet machine={MACHINE} outcome=asleep seen=read ms=")),
        "{lines:?}"
    );
    settles("machine reads", || world.machine.reads.load(Ordering::SeqCst), 1);

    // Inside the recheck time the last read stands: no second read.
    refused(&quiet);
    let lines = quiet_lines(&world, 2);
    assert!(
        lines[1].starts_with(&format!(
            "carrier.quiet machine={MACHINE} outcome=asleep seen=cached ms="
        )),
        "{lines:?}"
    );
    assert_eq!(world.machine.reads.load(Ordering::SeqCst), 1, "one read for both");
    assert_eq!(asked.load(Ordering::SeqCst), 0, "no carrier request: nothing woke the machine");
    let log = connect_log(&world);
    assert!(!log.contains("cloud.connect"), "a quiet refusal is no dial: {log}");

    assert_eq!(stopped(child, stderr), "", "a quiet refusal writes nothing to stderr");
    assert!(!socket.exists() && !quiet.exists(), "both sockets are removed on exit");
}

#[test]
fn a_quiet_connection_rides_the_session_a_main_connection_got() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let (child, mut stderr) = started(&world, &[]);
    let (socket, quiet) = sockets(&world);

    let mut main = open(&socket);
    let a = ask(&mut main, 1);
    assert_served(&mut stderr);
    assert_eq!(asked.load(Ordering::SeqCst), 1);

    // The machine's state is never read while a session is held: the quiet
    // connection rides it whatever the read would say.
    world.machine.set("paused");
    let mut rider = open(&quiet);
    let b = ask(&mut rider, 2);
    assert_served(&mut stderr);
    assert_ne!(a, b, "the rider is its own mux stream on the held session");
    assert_eq!(ask(&mut main, 3), a, "the main connection keeps its stream");
    assert_eq!(asked.load(Ordering::SeqCst), 1, "the rider asked for no carrier");
    assert_eq!(world.machine.reads.load(Ordering::SeqCst), 0, "nor read the machine");
    assert!(quiet_lines_now(&world).is_empty(), "{}", connect_log(&world));

    drop((main, rider));
    assert_eq!(stopped(child, stderr), "");
}

#[test]
fn the_machine_s_state_is_read_at_most_once_per_recheck_time() {
    const WINDOW: Duration = Duration::from_millis(5000);
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    world.machine.set("paused");
    let (child, mut stderr) = started(&world, &[("CMUX_CARRIER_SERVE_ASLEEP_RECHECK_MS", "5000")]);
    let (_, quiet) = sockets(&world);

    let first = Instant::now();
    refused(&quiet);
    refused(&quiet);
    refused(&quiet);
    let lines = quiet_lines(&world, 3);
    settles("machine reads", || world.machine.reads.load(Ordering::SeqCst), 1);

    // The machine wakes elsewhere. Inside the window the asleep read still
    // stands, so the quiet connection is closed without a read.
    world.machine.set("running");
    refused(&quiet);
    let lines_after = quiet_lines(&world, 4);
    assert!(first.elapsed() < WINDOW, "the test outran its window: rerun on a lighter host");
    assert!(lines[0].contains(" seen=read "), "{lines:?}");
    for cached in &lines_after[1..] {
        assert!(cached.contains(" outcome=asleep seen=cached "), "{lines_after:?}");
    }
    assert_eq!(world.machine.reads.load(Ordering::SeqCst), 1, "one read inside the window");
    assert_eq!(asked.load(Ordering::SeqCst), 0);

    // Past the window the next quiet connection reads again, sees `running`
    // and dials as a main-socket connection does.
    std::thread::sleep(WINDOW.saturating_sub(first.elapsed()) + Duration::from_millis(200));
    let mut woke = open(&quiet);
    ask(&mut woke, 1);
    assert_served(&mut stderr);
    assert_eq!(world.machine.reads.load(Ordering::SeqCst), 2, "a second read, past the window");
    assert_eq!(asked.load(Ordering::SeqCst), 1, "running: one carrier request");
    assert_eq!(quiet_lines_now(&world).len(), 4, "the dial wrote no quiet line");

    drop(woke);
    assert_eq!(stopped(child, stderr), "");
}

fn quiet_lines_now(world: &World) -> Vec<String> {
    connect_log(world)
        .lines()
        .filter(|l| l.starts_with("carrier.quiet "))
        .map(str::to_owned)
        .collect()
}
