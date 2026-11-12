//! The daemon's CPU while clients ask for the whole session list over and over (a dogfood
//! Mac, 2026-10-27): three cmux-tui servers built before #26255 reconnected about once a
//! second and asked for the full list each time, and the idle daemon spent 30-40% of a
//! core summarizing, serializing and freeing it. The list guard (`hub/list_guard.rs`)
//! holds that to a few percent for any client. The real daemon binary runs here, through
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
/// The daemon CPU of one list in each phase, after the daemon's idle CPU, at most this many
/// times the CPU of one list of the plain reconnect phase of the same run. A share of a core
/// over wall time moved with the host (one testbox host: 5.5% in the fast phase, another:
/// 8.7%, the same code), so each phase is measured against the same run's plain reconnect.
/// Each limit is the worst ratio of 39 runs times 1.5 (2026-11-12: 20 runs of one host, an A/B
/// of 6 runs on another, the red run, and 12 runs of this test): 1.279, 0.525 and 0.591.
const MAX_PER_LIST_RATIO: [(&str, f64); 3] = [
    ("one connection at 1 Hz", 1.92),
    ("three clients reconnecting at 1 Hz", 0.79),
    ("reconnect as fast as it reads", 0.89),
];
/// The phase every ratio is measured against.
const BASE_PHASE: &str = "reconnect at 1 Hz";
/// One list of the plain reconnect phase, after the idle CPU, at most this much daemon CPU on
/// any host: it was 19 to 29 ms on two testbox hosts, so ten times the fast host's cost fails
/// on that host too.
const MAX_BASE_PER_LIST: Duration = Duration::from_millis(100);

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
    // The daemon's own CPU with no client, taken off each phase's.
    let idle = {
        let (start, before) = (Instant::now(), cpu(daemon.0.id()));
        std::thread::sleep(WINDOW);
        (cpu(daemon.0.id()) - before).as_secs_f64() / start.elapsed().as_secs_f64()
    };

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
        ("reconnect as fast as it reads", 1, true, reconnect),
    ] {
        let (share, lists) = measured(&daemon, clients, fast, ask);
        assert!(lists > 0, "{name}: no list was read in {WINDOW:?}");
        // Daemon CPU of one list, after the idle CPU of the same time.
        let per_list =
            Duration::from_secs_f64((share - idle).max(0.0) * WINDOW.as_secs_f64() / lists as f64);
        report.push((
            name,
            per_list,
            format!(
                "{name}: {:.1}% of a core, {lists} lists, {:.1} ms of CPU each",
                share * 100.0,
                per_list.as_secs_f64() * 1000.0
            ),
        ));
    }
    let lines: Vec<&str> = report.iter().map(|r| r.2.as_str()).collect();
    eprintln!(
        "daemon CPU while a client asks ({CHATS} chats, idle {:.2}% of a core):\n  {}",
        idle * 100.0,
        lines.join("\n  ")
    );

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
    // A watcher never reads a list that lacks a change it was already told of.
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
    // `lagged`: the lists read again after a `_acpmux/lagged` notice; `owed`: the notice a list
    // read again must not be older than.
    let (mut told, mut lists, mut lagged, mut owed) = (String::new(), 0, 0, None::<String>);
    while !renames.is_finished() || lists < 3 {
        // One list, page by page, to the page that holds the renamed chat.
        let mut params = json!({});
        'list: loop {
            watcher.2 += 1;
            let ask = json!({"jsonrpc": "2.0", "id": watcher.2, "method": "_acpmux/sessions",
                "params": params});
            watcher.1.write_all(format!("{ask}\n").as_bytes()).unwrap();
            loop {
                let v = watcher.line();
                let session = &v["params"]["session"];
                if session["sessionId"] == id(9).as_str()
                    && let Some(name) = session["name"].as_str()
                {
                    told = told.max(name.to_owned());
                }
                if v["id"] != watcher.2 {
                    continue;
                }
                let rows = v["result"]["sessions"].as_array().unwrap();
                if let Some(row) = rows.iter().find(|s| s["sessionId"] == id(9).as_str()) {
                    let listed = row["name"].as_str().unwrap();
                    if let Some(notice) = owed.take() {
                        assert!(
                            listed >= notice.as_str(),
                            "the list read again after a lag shows {listed}, older than the \
                             notice of {notice} it lagged behind"
                        );
                    }
                    if listed < told.as_str() {
                        // A notice overtook this list twice, so it went anyway, and the very
                        // next message tells the client to read again (`server/list_reply.rs`).
                        let next = watcher.line();
                        assert!(
                            next["method"] == "_acpmux/lagged"
                                && next["params"]["watch"] == true
                                && next["params"]["reason"] == "list_changed",
                            "listed {listed} after a notice of {told}, and the next message is \
                             not `_acpmux/lagged {{watch: true, reason: list_changed}}`: {next}"
                        );
                        lagged += 1;
                        owed = Some(told.clone());
                        params = json!({});
                        break;
                    }
                    break 'list;
                }
                let next = &v["result"]["nextCursor"];
                assert!(next.is_string(), "no page of the list holds the renamed chat");
                params = json!({"cursor": next});
                break;
            }
        }
        lists += 1;
    }
    renames.join().unwrap();
    eprintln!("watcher: {lists} lists in the rename race, {lagged} read again after a lag");
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
    let per_list = |phase: &str| report.iter().find(|r| r.0 == phase).map(|r| r.1).unwrap();
    let base = per_list(BASE_PHASE);
    let mut over = Vec::new();
    if base > MAX_BASE_PER_LIST {
        over.push(format!("{BASE_PHASE}: {base:?} a list (ceiling {MAX_BASE_PER_LIST:?})"));
    }
    for (phase, limit) in MAX_PER_LIST_RATIO {
        let cost = per_list(phase);
        if cost.as_secs_f64() > base.as_secs_f64() * limit {
            over.push(format!("{phase}: {cost:?} a list, over {limit} x {base:?}"));
        }
    }
    assert!(over.is_empty(), "list CPU over its limit: {over:?}\n  {}", lines.join("\n  "));
}
