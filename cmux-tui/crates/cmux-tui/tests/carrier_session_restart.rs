//! A machine's session host restarts (the updater restarts it at boot, or
//! it crashes) under a carrier session: the restarted host has the same
//! identity and none of the old sessions, and answers a resume with
//! `SessionUnavailable`. The client opens a fresh session at once instead
//! of failing; a resume to a live host still keeps its session; a resume
//! that can never succeed gives up within `RESUME_DEADLINE` and falls back
//! to one fresh session; and a chat re-attached with `afterSeq` across the
//! restart gets every event exactly once.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, ChildStderr, Command, Stdio};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use carrier_support::host::{HostWorld, Mux, Restart, host_world};

/// `MAX_FRESH_SESSIONS` in `carrier/contract.rs`.
const MAX_FRESH_SESSIONS: usize = 2;
use carrier_support::{BIN, MACHINE, TOKEN, line, wait};
use serde_json::{Value, json};

fn dial(world: &HostWorld) -> Child {
    dial_with(world, &[])
}

fn dial_with(world: &HostWorld, extra: &[&str]) -> Child {
    Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(extra)
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn serve(world: &HostWorld) -> (Child, BufReader<ChildStderr>) {
    let mut child = Command::new(BIN)
        .args(["carrier", "serve", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(["--socket", world.socket_path().to_str().unwrap()])
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
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
fn ask(conn: &mut BufReader<impl std::io::Read + Write>, id: u32) -> u64 {
    let sent = format!("{{\"cmd\":\"identify\",\"id\":{id}}}\n");
    conn.get_mut().write_all(sent.as_bytes()).unwrap();
    conn.get_mut().flush().unwrap();
    assert_eq!(line(conn), sent, "the line reached the daemon and came back");
    let pushed: Value = serde_json::from_str(&line(conn)).unwrap();
    assert_eq!(pushed["event"], "pushed", "{pushed}");
    pushed["conn"].as_u64().unwrap()
}

/// The route lines (`cloud.connect …`) of the connect log.
fn routes(world: &HostWorld) -> Vec<String> {
    world
        .connect_log()
        .lines()
        .filter(|l| l.starts_with("cloud.connect "))
        .map(String::from)
        .collect()
}

/// Dials that connected: a first connect or a later attempt of one dial.
fn connected(routes: &[String]) -> usize {
    routes
        .iter()
        .filter(|l| {
            (l.contains(" phase=connect ") || l.contains(" phase=reconnect "))
                && l.contains(" outcome=ok ")
        })
        .count()
}

/// The first connect's handshake finishes, then the session host restarts
/// before the first stream opens: the resume reaches the restarted host,
/// which has no record of the session. The dial opens a fresh session on
/// it at once and ends ready, well inside the dial's deadline, and the
/// caller never sees `SessionUnavailable`.
#[test]
fn a_carrier_dial_whose_session_host_restarts_after_the_handshake_ends_ready_on_a_fresh_session() {
    let world = host_world(Restart::AfterFirstSession, Mux::Echo);
    let started = Instant::now();
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    let ready_after = started.elapsed();
    assert_eq!(
        reply,
        json!({"ok": true, "path_state": "relay", "route": "carrier"}),
        "the dial ends ready, with no SessionUnavailable surfaced: {}",
        world.connect_log()
    );
    assert!(ready_after < Duration::from_secs(8), "ready in {ready_after:?}");
    assert_eq!(world.starts.load(Ordering::SeqCst), 2, "the session host restarted once");

    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    stdin.write_all(b"{\"cmd\":\"identify\",\"id\":1}\n").unwrap();
    stdin.flush().unwrap();
    assert_eq!(line(&mut stdout), "{\"cmd\":\"identify\",\"id\":1}\n", "on the fresh session");
    assert_eq!(line(&mut stdout), "{\"event\":\"pushed\",\"conn\":0}\n");

    let attempts: Vec<_> =
        routes(&world).into_iter().filter(|l| !l.contains(" phase=resume ")).collect();
    assert_eq!(attempts.len(), 2, "one failed attempt, one fresh session: {attempts:?}");
    assert!(attempts[0].contains(" phase=connect outcome=handshake "), "{attempts:?}");
    assert!(attempts[1].contains(" phase=reconnect outcome=ok "), "{attempts:?}");
    drop(stdin);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// A link drop to a host that is still up resumes the same session: the
/// stream goes on (the same mux connection answers), nothing is dialed
/// again and the host never restarted.
#[test]
fn a_carrier_dial_whose_link_drops_resumes_the_same_live_session() {
    let world = host_world(Restart::OnRequest, Mux::Echo);
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    let mut stdio = BufReader::new(Stdio2 {
        stdin: child.stdin.take().unwrap(),
        stdout: BufReader::new(child.stdout.take().unwrap()),
    });
    assert_eq!(ask(&mut stdio, 1), 0);
    let links = world.links();
    world.cut();
    assert_eq!(ask(&mut stdio, 2), 0, "the same stream, on the same session, goes on");

    let routes = routes(&world);
    assert_eq!(connected(&routes), 1, "no fresh session: {routes:?}");
    assert!(world.links() > links, "the links were cut and made again: {routes:?}");
    assert_eq!(world.starts.load(Ordering::SeqCst), 1);
    drop(stdio);
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// The dial's stdin and stdout as one stream, for [`ask`].
struct Stdio2 {
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl std::io::Read for Stdio2 {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        std::io::Read::read(&mut self.stdout, buf)
    }
}

impl Write for Stdio2 {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.stdin.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.stdin.flush()
    }
}

/// The relay is unreachable for longer than `RESUME_DEADLINE` (10 s): the
/// held session stops resuming, and the next connection opens exactly one
/// fresh session once the relay is back, instead of waiting on the old one
/// forever.
#[test]
fn a_carrier_serve_session_whose_resume_keeps_failing_falls_back_to_one_fresh_session() {
    let world = host_world(Restart::OnRequest, Mux::Echo);
    let (mut child, mut stderr) = serve(&world);
    let socket = world.socket_path();
    let mut first = open(&socket);
    assert_eq!(ask(&mut first, 1), 0);
    assert_eq!(serde_json::from_str::<Value>(&line(&mut stderr)).unwrap()["ok"], true);

    world.hold();
    let held = Instant::now();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            // Past the resume deadline, the relay comes back.
            std::thread::sleep(Duration::from_secs(13));
            world.release();
        });
        let mut second = open(&socket);
        ask(&mut second, 2);
        assert_eq!(serde_json::from_str::<Value>(&line(&mut stderr)).unwrap()["ok"], true);
    });
    let served_after = held.elapsed();
    assert!(served_after < Duration::from_secs(25), "served in {served_after:?}");
    let routes = routes(&world);
    assert_eq!(
        connected(&routes),
        2,
        "the old session gave up, and one fresh session served the connection: {routes:?}"
    );
    assert_eq!(world.starts.load(Ordering::SeqCst), 1, "the host never restarted");
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// A chat's client side: attaches with `afterSeq` = the last seq it holds,
/// and drops any event it already has.
#[derive(Default)]
struct Chat {
    events: Vec<u64>,
    dropped: usize,
}

impl Chat {
    fn last(&self) -> u64 {
        self.events.last().copied().unwrap_or(0)
    }

    fn attach(&self, socket: &Path) -> BufReader<UnixStream> {
        let mut conn = open(socket);
        let attach = format!("{}\n", json!({"cmd": "attach", "afterSeq": self.last()}));
        conn.get_mut().write_all(attach.as_bytes()).unwrap();
        conn
    }

    /// Reads one event line; false at the stream's end.
    fn read(&mut self, conn: &mut BufReader<UnixStream>) -> bool {
        let mut text = String::new();
        match conn.read_line(&mut text) {
            Ok(0) => false,
            Ok(_) => {
                let event: Value = serde_json::from_str(&text).unwrap();
                let seq = event["seq"].as_u64().unwrap();
                if seq <= self.last() {
                    self.dropped += 1;
                } else {
                    self.events.push(seq);
                }
                true
            }
            Err(error) => panic!("the chat stream neither went on nor ended: {error}"),
        }
    }

    fn read_through(&mut self, conn: &mut BufReader<UnixStream>, seq: u64) {
        while self.last() < seq {
            assert!(self.read(conn), "the stream ended at {} before {seq}", self.last());
        }
    }
}

/// The session host restarts mid-chat: the chat's stream on the old
/// session ends, the client re-attaches on a fresh session with `afterSeq`
/// = the last seq it holds, and every event (before the restart, during it
/// and after it) arrives exactly once: nothing lost, nothing repeated.
#[test]
fn a_carrier_chat_reattached_after_its_session_host_restarts_gets_every_event_exactly_once() {
    let world = host_world(Restart::OnRequest, Mux::Events);
    let (mut child, _stderr) = serve(&world);
    let socket = world.socket_path();
    let mut chat = Chat::default();
    let mut conn = chat.attach(&socket);
    for _ in 0..3 {
        world.events.append();
    }
    chat.read_through(&mut conn, 3);

    world.restart();
    for _ in 0..3 {
        world.events.append();
    }
    // The old session is gone: its stream ends.
    while chat.read(&mut conn) {}
    let mut conn = chat.attach(&socket);
    for _ in 0..2 {
        world.events.append();
    }
    chat.read_through(&mut conn, 8);

    assert_eq!(chat.events, (1..=8).collect::<Vec<_>>(), "every event, in order, once");
    assert_eq!(chat.dropped, 0, "afterSeq sent nothing the chat already had");
    assert_eq!(world.starts.load(Ordering::SeqCst), 2);
    let routes = routes(&world);
    assert_eq!(connected(&routes), 2, "the re-attach rode a fresh session: {routes:?}");
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}

/// The session host restarts after the dial's mux-control stream opened and
/// before its desktop stream does (`--service desktop`): the desktop open
/// finds the session gone. The dial opens a fresh session and asks for the
/// desktop again there, so the answer is the restarted host's own: this
/// test's grants carry no `vmk`, so it refuses the desktop as a service
/// (exit 6), not a relay failure from the lost session.
#[test]
fn a_carrier_desktop_dial_whose_session_host_restarts_before_the_desktop_opens_asks_a_fresh_session()
 {
    let world = host_world(Restart::AfterMuxOpen, Mux::Echo);
    let mut child = dial_with(&world, &["--service", "desktop"]);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(
        reply["error_code"],
        "service_refused",
        "the restarted host answered the desktop on a fresh session: {reply} {}",
        world.connect_log()
    );
    assert!(
        reply["error_detail"].as_str().unwrap().contains("does not allow local-socket"),
        "{reply}"
    );
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(6));
    assert_eq!(world.starts.load(Ordering::SeqCst), 2, "the session host restarted once");
    let routes = routes(&world);
    assert_eq!(connected(&routes), 2, "the first session, then one fresh one: {routes:?}");
}

/// The session host restarts on every session, in both windows in turn:
/// right after the handshake (the mux-control open finds the session gone)
/// and between mux control and the desktop (the desktop open does). One
/// desktop dial spends one budget of fresh sessions across both, so it
/// opens at most 1 + `MAX_FRESH_SESSIONS` sessions before it gives up.
#[test]
fn a_carrier_desktop_dial_spends_one_fresh_session_budget_across_both_restart_windows() {
    let world = host_world(Restart::Always, Mux::Echo);
    let mut child = dial_with(&world, &["--service", "desktop"]);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false, "no session lasts, so the dial fails: {reply}");
    // The third session's mux-control open found it gone with the budget
    // spent: that, not the desktop, ends the dial.
    assert_eq!(reply["error_code"], "handshake", "{reply}");
    assert_ne!(wait(&mut child, Duration::from_secs(20)), Some(0));
    let sessions = world.sessions.load(Ordering::SeqCst);
    assert_eq!(
        sessions,
        1 + MAX_FRESH_SESSIONS,
        "the first session and MAX_FRESH_SESSIONS fresh ones, in all: {reply} {}",
        world.connect_log()
    );
}
