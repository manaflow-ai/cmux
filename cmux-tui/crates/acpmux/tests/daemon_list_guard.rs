//! The daemon's CPU while clients ask for the whole session list over and over (a dogfood
//! Mac, 2026-10-27): three cmux-tui servers built before #26255 reconnected about once a
//! second and asked for the full list each time, and the idle daemon spent 30-40% of a
//! core summarizing, serializing and freeing it. A list read now builds only the rows of each
//! page it sends (`hub/list_guard.rs`), with no shared build and no pace, which holds a client
//! asking once a second to a few percent. The real daemon binary runs here, through
//! its socket, over a few hundred chats with summaries the size of real ones.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

const CHATS: usize = 400;
/// How long each client runs while the daemon's CPU is measured.
const WINDOW: Duration = Duration::from_secs(15);
/// The daemon's CPU allowed while a client asks once a second, in a share of one core.
const MAX_SHARE: f64 = 0.08;
/// A broken client: a new connection for each list, as fast as it reads them.
const FAST: &str = "reconnect as fast as it reads";

/// CPU time the process has used, user and system: `/proc` on Linux, `ps` elsewhere.
fn cpu(pid: u32) -> Duration {
    if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        // utime and stime are fields 14 and 15, after the parenthesized command name.
        let fields: Vec<&str> = stat[stat.rfind(')').unwrap() + 2..].split(' ').collect();
        let ticks: u64 = fields[11].parse::<u64>().unwrap() + fields[12].parse::<u64>().unwrap();
        // SAFETY: sysconf has no preconditions.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
        return Duration::from_millis(ticks * 1000 / hz);
    }
    // `[[dd-]hh:]mm:ss.cc`
    let mut ps = std::process::Command::new("ps");
    let out = ps.args(["-o", "time=", "-p", &pid.to_string()]).output().unwrap();
    let text = String::from_utf8(out.stdout).unwrap().trim().to_owned();
    let (days, clock) = text.split_once('-').unwrap_or(("0", &text));
    let secs = clock.split(':').fold(0.0, |acc, part| acc * 60.0 + part.parse::<f64>().unwrap());
    Duration::from_secs_f64(days.parse::<f64>().unwrap() * 86_400.0 + secs)
}

struct Daemon(Child, PathBuf);

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid is this test's own child.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

fn start(dir: &Path, home: &Path) -> Daemon {
    let socket = dir.join("s.sock");
    let mut child = daemon_env::acpmux(dir)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let ready = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map_while(Result::ok)
        .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
    let daemon = Daemon(child, socket);
    assert!(ready, "the daemon exited without a readiness line");
    daemon
}

struct Rpc(BufReader<UnixStream>, UnixStream, u64);

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to daemon socket");
        s.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
        Self(BufReader::new(s.try_clone().unwrap()), s, 0)
    }

    fn line(&mut self) -> Value {
        let mut line = String::new();
        assert!(self.0.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
        serde_json::from_str(&line).unwrap()
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.2, "method": method, "params": params});
        self.1.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let v = self.line();
            if v["id"] == self.2 {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

fn id(i: usize) -> String {
    format!("01a16c00-0000-7000-8000-{i:012x}")
}

/// `CHATS` idle chats whose summaries are about 5 KB, as the dogfood Mac's were.
fn write_chats(home: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let private =
        |p: &Path, mode| std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode));
    for i in 0..CHATS {
        let dir = home.join("sessions").join(id(i));
        std::fs::create_dir_all(&dir).unwrap();
        for p in [home, &home.join("sessions"), &dir] {
            private(p, 0o700).unwrap();
        }
        let at = 1_792_000_000_000u64 + i as u64;
        let meta = json!({"schema": "acpmux.session.v1", "id": id(i), "name": format!("chat-{i}"),
            "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": at, "updatedAt": at,
            "lastSeq": 0, "eventCount": 0, "title": format!("Chat {i}"),
            "tags": {"pad": {"value": "p".repeat(3650)}}});
        std::fs::write(dir.join("session.json"), meta.to_string()).unwrap();
        private(&dir.join("session.json"), 0o600).unwrap();
    }
}

/// The rows of the list reply `first` and of each page after it: a list past one reply page
/// comes in pages, each with the `nextCursor` of the rest (`server/list_reply.rs`), and a
/// client that wants every row follows it.
fn with_rest(rpc: &mut Rpc, first: Value) -> Vec<Value> {
    let (mut rows, mut page, mut cursor) = (Vec::new(), first, Value::Null);
    loop {
        rows.extend(page["sessions"].as_array().unwrap().iter().cloned());
        let next = page["nextCursor"].clone();
        if next.is_null() {
            return rows;
        }
        assert_ne!(next, cursor, "the list's cursor did not move past a page");
        cursor = next;
        page = rpc.call("_acpmux/sessions", json!({"cursor": cursor}));
    }
}

/// The whole list on `rpc`, every page of it: its rows.
fn list_all(rpc: &mut Rpc) -> Vec<Value> {
    let first = rpc.call("_acpmux/sessions", json!({}));
    with_rest(rpc, first)
}

/// The whole list on a new connection, every page of it: its rows. (The old servers asked on a
/// new connection each time; a list of this size was one reply then.)
fn list_once(socket: &Path) -> Vec<Value> {
    list_all(&mut Rpc::connect(socket))
}

/// `clients` threads each running `ask` (one list each) for `WINDOW`, at 1 Hz unless
/// `fast`: the daemon's share of one core meanwhile, and the lists read.
fn measured(
    daemon: &Daemon,
    clients: usize,
    fast: bool,
    ask: fn(&Path, &mut Option<Rpc>),
) -> (f64, usize) {
    let (start, before) = (Instant::now(), cpu(daemon.0.id()));
    let threads: Vec<_> = (0..clients)
        .map(|_| {
            let socket = daemon.1.clone();
            std::thread::spawn(move || {
                let (mut lists, mut rpc) = (0, None);
                while start.elapsed() < WINDOW {
                    if !fast {
                        let next = Duration::from_secs(start.elapsed().as_secs() + 1);
                        std::thread::sleep(next.saturating_sub(start.elapsed()));
                    }
                    ask(&socket, &mut rpc);
                    lists += 1;
                }
                lists
            })
        })
        .collect();
    let lists = threads.into_iter().map(|t| t.join().unwrap()).sum();
    ((cpu(daemon.0.id()) - before).as_secs_f64() / start.elapsed().as_secs_f64(), lists)
}

#[test]
fn clients_asking_for_the_whole_list_over_and_over_cost_the_daemon_a_few_percent() {
    let dir = std::env::temp_dir().join(format!("amx-listguard-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    write_chats(&home);
    let daemon = start(&dir, &home);
    assert_eq!(list_once(&daemon.1).len(), CHATS);
    std::thread::sleep(Duration::from_secs(5));

    let reconnect: fn(&Path, &mut Option<Rpc>) =
        |socket, _| assert_eq!(list_once(socket).len(), CHATS);
    let keep: fn(&Path, &mut Option<Rpc>) = |socket, rpc| {
        let rpc = rpc.get_or_insert_with(|| Rpc::connect(socket));
        assert_eq!(list_all(rpc).len(), CHATS);
    };
    let mut report = Vec::new();
    for (name, clients, fast, ask) in [
        // What the old servers did: a new connection for each list, once a second.
        ("reconnect at 1 Hz", 1, false, reconnect),
        ("one connection at 1 Hz", 1, false, keep),
        ("three clients reconnecting at 1 Hz", 3, false, reconnect),
        // A broken client: a new connection for each list, as fast as it reads them.
        (FAST, 1, true, reconnect),
    ] {
        let (share, lists) = measured(&daemon, clients, fast, ask);
        report.push((
            name,
            share,
            format!("{name}: {:.1}% of a core, {lists} lists", share * 100.0),
        ));
    }
    let lines: Vec<&str> = report.iter().map(|r| r.2.as_str()).collect();
    eprintln!("daemon CPU while a client asks ({CHATS} chats):\n  {}", lines.join("\n  "));

    // Still correct: a watcher hears each change, and every list after a change shows it.
    let mut watcher = Rpc::connect(&daemon.1);
    let watched = watcher.call("_acpmux/watch", json!({"enabled": true}));
    assert_eq!(with_rest(&mut watcher, watched).len(), CHATS);
    let mut rpc = Rpc::connect(&daemon.1);
    for round in 0..6 {
        let name = format!("renamed-{round}");
        rpc.call("_acpmux/rename", json!({"sessionId": id(round), "newName": name}));
        let listed = list_once(&daemon.1);
        let row = listed.iter().find(|s| s["sessionId"] == id(round).as_str()).unwrap();
        assert_eq!(row["name"], name.as_str(), "the list after a rename shows it");
        while watcher.line()["params"]["session"]["name"] != name.as_str() {}
    }
    // A watch reply is current to its `listSeq`: it never lacks a change whose notice carried a
    // position at or below it. Notices and replies may go in either order (no reply is read again
    // or followed by a lag when a notice overtook it); a client keeps the row with the higher
    // position (`hub/row_log.rs`). Each rename moves the chat to the top: a page of one holds it.
    let socket = daemon.1.clone();
    let renames = std::thread::spawn(move || {
        let mut rpc = Rpc::connect(&socket);
        for n in 0..60 {
            rpc.call(
                "_acpmux/rename",
                json!({"sessionId": id(9), "newName": format!("race-{n:02}")}),
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    let (mut told, mut lists) = (Vec::<(u64, String)>::new(), 0);
    while !renames.is_finished() || lists < 3 {
        watcher.2 += 1;
        let ask = json!({"jsonrpc": "2.0", "id": watcher.2, "method": "_acpmux/watch",
            "params": {"enabled": true, "limit": 1}});
        watcher.1.write_all(format!("{ask}\n").as_bytes()).unwrap();
        loop {
            let v = watcher.line();
            let params = &v["params"];
            if params["sessionId"] == id(9).as_str()
                && let (Some(at), Some(name)) =
                    (params["listSeq"].as_u64(), params["session"]["name"].as_str())
            {
                told.push((at, name.to_owned()));
            }
            if v["id"] != watcher.2 {
                continue;
            }
            let at = v["result"]["listSeq"].as_u64().expect("a watch reply has its listSeq");
            let rows = v["result"]["sessions"].as_array().unwrap();
            if let Some(row) = rows.iter().find(|s| s["sessionId"] == id(9).as_str()) {
                let listed = row["name"].as_str().unwrap();
                let owed = told.iter().filter(|(seq, _)| *seq <= at).map(|(_, n)| n.as_str()).max();
                assert!(
                    owed.is_none_or(|owed| listed >= owed),
                    "listed {listed} at listSeq {at} after a notice of {owed:?} at or below it"
                );
                lists += 1;
            }
            break;
        }
    }
    renames.join().unwrap();
    // Pages cut from the shared list by count are the whole list, in order: newest first, ties
    // by id. A whole list past one reply page comes in its own page order
    // (`session_pages::byte_page`), and its reader puts it in that order (`client.rs`
    // `whole_list`), as here.
    let mut whole = list_once(&daemon.1);
    assert_eq!(whole.len(), CHATS);
    whole.sort_by_key(|s| {
        let updated = s["updatedAt"].as_u64().unwrap();
        (std::cmp::Reverse(updated), s["sessionId"].as_str().unwrap().to_owned())
    });
    let whole: Vec<Value> = whole.iter().map(|s| s["sessionId"].clone()).collect();
    let (mut paged, mut cursor) = (Vec::new(), Value::Null);
    loop {
        let page = rpc.call("_acpmux/sessions", json!({"limit": 64, "cursor": cursor}));
        paged.extend(page["sessions"].as_array().unwrap().iter().map(|s| s["sessionId"].clone()));
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            break;
        }
    }
    assert_eq!(paged, whole);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
    // A broken client that reads as fast as it can costs what it reads: no list request waits or
    // is refused (Leo, 2026-11-12: "Delete the pacer"); it is measured, not bounded.
    let over: Vec<&str> =
        report.iter().filter(|r| r.0 != FAST && r.1 > MAX_SHARE).map(|r| r.0).collect();
    assert!(
        over.is_empty(),
        "over {:.0}% of a core: {over:?}\n  {}",
        MAX_SHARE * 100.0,
        lines.join("\n  ")
    );
}
