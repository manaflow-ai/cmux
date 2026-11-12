#![cfg(unix)]
//! A git request does not hold its connection (perf-lead.md rule D1: no child
//! process on a request path). `git.diff` and `git.status` run git as a child
//! process, which takes seconds in a large repository on a loaded Mac. The
//! daemon runs them on its git lane (`server/git_lane.rs`):
//!
//! - while one git request runs, the connection's later requests (a
//!   `git.status` of a shown view, a liveness `ping`, a list) are read and
//!   answered;
//! - the whole daemon runs at most [`GIT_RUNS`] git reads at one time;
//! - equal reads that wait share one run, [`SHARED_READS`] and the first at most;
//! - a mutation keeps its place in its connection's order;
//! - a git that passes its limit is ended, its request gets an error and its
//!   place is free again;
//! - a client that ends its writes still gets its replies;
//! - a client that closed its whole end leaves at once: its reads that wait
//!   start no git, its mutation that waits still runs, and a client that
//!   closes later leaves when its first reply cannot be written; a client
//!   that is there and does not read is not taken for one that closed;
//! - a request that waits when the shutdown begins is refused and does not
//!   run, and a broken connection's waiting mutation still runs;
//! - the copies of a shared reply do not fill the connection's reply queue,
//!   and their wait for room holds no place of the lane;
//! - at most [`MUTATION_RUNS`] mutations run at one time, and a connection
//!   may have [`WAITING_RUNS`] runs that wait.
//!
//! The git here is a stand-in on `PATH` that waits at a gate the test holds,
//! then runs the real git: a reply that arrives while the gate is held was
//! given while git ran. No sleep decides a result, but for the test of a
//! large shared reply, where the client reads nothing for a time.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

/// The daemon's bound (`git_lane::MAX_READ_RUNS`): git reads that run at one time.
const GIT_RUNS: usize = 4;

/// The read places a long read (a diff, a file list or search) may take:
/// `git_lane::MAX_LONG_READ_RUNS`. The other one is kept for short reads.
const LONG_GIT_RUNS: usize = 3;

/// The daemon's bound of git mutations that run at one time: `git_lane::MAX_MUTATION_RUNS`.
const MUTATION_RUNS: usize = 2;

/// The git runs of one connection that may wait: `git_lane::QUEUED_PER_CLIENT`.
const WAITING_RUNS: usize = 512;

/// The equal reads that join one that waits: `git_lane::SHARED_READS`.
const SHARED_READS: usize = 64;

/// The longest a step of a test waits for something that must come.
const LONG: Duration = Duration::from_secs(60);

struct Fixture {
    dir: PathBuf,
    real: PathBuf,
}

/// The real git, as an absolute path, before the stand-in goes on `PATH`.
fn real_git() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git is on PATH")
}

/// One directory for this test process, with a stand-in `git` first on `PATH`.
///
/// The stand-in looks for a gate directory named as its working directory
/// (`gates/<repository name>`). With one, it counts itself in `active`, writes
/// that count to `peaks` and its arguments to `log`, waits while `hold-all`
/// exists (or `hold-diff`, when it is a `git diff`), and then runs the real
/// git. Its wait ends by itself after 30 s, past the daemon's 20 s limit for
/// one git run. With no gate directory it is the real git.
fn fixture() -> &'static Fixture {
    static FIXTURE: OnceLock<Fixture> = OnceLock::new();
    FIXTURE.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("glane-{}", std::process::id()));
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(dir.join("gates")).unwrap();
        let real = real_git();
        let script = format!(
            "#!/bin/sh\n\
             gate=\"{gates}/$(basename \"$PWD\")\"\n\
             if [ ! -d \"$gate\" ]; then exec \"{real}\" \"$@\"; fi\n\
             mkdir \"$gate/active/$$\"\n\
             ls \"$gate/active\" | wc -l >> \"$gate/peaks\"\n\
             echo \"$*\" >> \"$gate/log\"\n\
             held() {{\n\
             \x20 [ -e \"$gate/hold-all\" ] && return 0\n\
             \x20 [ -e \"$gate/hold-diff\" ] || return 1\n\
             \x20 case \" $* \" in *\" diff \"*) return 0;; esac\n\
             \x20 return 1\n\
             }}\n\
             n=0\n\
             while held \"$@\" && [ \"$n\" -lt 600 ]; do\n\
             \x20 : > \"$gate/held\"\n\
             \x20 sleep 0.05\n\
             \x20 n=$((n+1))\n\
             done\n\
             \"{real}\" \"$@\"\n\
             code=$?\n\
             rmdir \"$gate/active/$$\"\n\
             exit $code\n",
            gates = dir.join("gates").display(),
            real = real.display(),
        );
        let shim = bin.join("git");
        std::fs::write(&shim, script).unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut path = bin.as_os_str().to_owned();
        if let Some(old) = std::env::var_os("PATH") {
            path.push(":");
            path.push(old);
        }
        // Every test takes the fixture before it starts a daemon or a child,
        // and this runs once, under the cell's lock.
        unsafe { std::env::set_var("PATH", path) };
        Fixture { dir, real }
    })
}

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

fn git(repo: &Path, arguments: &[&str]) {
    let status = Command::new(&fixture().real)
        .arg("-C")
        .arg(repo)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?} failed");
}

/// The gate of one repository's git runs.
struct Gate {
    dir: PathBuf,
}

impl Gate {
    fn hold(&self, name: &str) {
        std::fs::write(self.dir.join(name), "").unwrap();
    }

    fn release(&self, name: &str) {
        std::fs::remove_file(self.dir.join(name)).unwrap();
    }

    /// The git runs that are in the stand-in now.
    fn active(&self) -> usize {
        std::fs::read_dir(self.dir.join("active")).map_or(0, Iterator::count)
    }

    /// The most git runs any run saw at its start, itself included.
    fn peak(&self) -> usize {
        let peaks = std::fs::read_to_string(self.dir.join("peaks")).unwrap_or_default();
        peaks.lines().filter_map(|line| line.trim().parse().ok()).max().unwrap_or(0)
    }

    /// The git runs whose arguments have the word `word`.
    fn runs_of(&self, word: &str) -> usize {
        let log = std::fs::read_to_string(self.dir.join("log")).unwrap_or_default();
        log.lines().filter(|line| line.split(' ').any(|argument| argument == word)).count()
    }

    /// Waits until a git run waits at the gate.
    fn wait_held(&self) {
        wait_for("a git run at the gate", || self.dir.join("held").exists());
    }
}

/// Polls until `done`, for [`LONG`] at most.
fn wait_for(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + LONG;
    while !done() {
        assert!(Instant::now() < deadline, "no {what} in {LONG:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Polls until `done`, for `wait` at most. Returns whether it was done.
fn done_in(wait: Duration, done: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + wait;
    while !done() {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    true
}

/// How long a client that closed may stay a client of the daemon. Far below
/// the 20 s limit of one git read, which is where a held read frees its place.
const GONE: Duration = Duration::from_secs(10);

/// Fills each read place of the lane with a git run of `repo`, whose gate
/// holds every run (`hold-all`): [`LONG_GIT_RUNS`] long reads and one short
/// read. Returns their ids.
fn fill_the_read_places(connection: &mut Connection, repo: &str, gate: &Gate) -> Vec<String> {
    let mut ids = Vec::new();
    for number in 0..LONG_GIT_RUNS {
        // A different `context_lines` makes a different read, so no two share a run.
        let id = format!("fill{number}");
        let params = json!({"path": repo, "scope": "uncommitted", "context_lines": number + 1});
        connection.send(&id, "git.diff", params);
        ids.push(id);
    }
    connection.send("fill-short", "git.status", json!({"path": repo}));
    ids.push("fill-short".to_string());
    wait_for("full git lane", || gate.active() >= GIT_RUNS);
    ids
}

/// A repository with one commit and one changed file, and the gate of its git runs.
fn repository(name: &str) -> (String, Gate) {
    let name = unique(name);
    let repo = fixture().dir.join("repos").join(&name);
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "--quiet", "-m", "one"]);
    std::fs::write(repo.join("a.txt"), "two\n").unwrap();
    let gate = Gate { dir: fixture().dir.join("gates").join(&name) };
    std::fs::create_dir_all(gate.dir.join("active")).unwrap();
    (repo.to_string_lossy().into_owned(), gate)
}

/// A daemon on a socket of its own.
fn daemon() -> PathBuf {
    let name = unique("d");
    let socket = fixture().dir.join(format!("{name}.sock"));
    let mux =
        Mux::new(format!("git-lane-{}-{name}", std::process::id()), SurfaceOptions::default());
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    // The daemon lives as long as the test process.
    std::mem::forget(mux);
    socket
}

/// A daemon with a state directory (the diff comments need one), and its mux.
fn persistent_daemon(name: &str) -> (PathBuf, Arc<Mux>) {
    let dir = fixture().dir.join(unique("state"));
    let socket = fixture().dir.join(format!("{}.sock", unique("m")));
    let name = format!("git-lane-{name}-{}", std::process::id());
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &dir).unwrap();
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    // The daemon lives as long as the test process.
    std::mem::forget(mux.clone());
    (socket, mux)
}

/// One connection: requests go out without a wait for their replies.
struct Connection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    seen: Vec<Value>,
}

impl Connection {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        let writer = stream.try_clone().unwrap();
        let mut connection = Self { writer, reader: BufReader::new(stream), seen: Vec::new() };
        connection.ping(0);
        connection.reply(&json!(0));
        connection
    }

    fn ping(&mut self, id: u64) {
        writeln!(self.writer, "{}", json!({"id": id, "cmd": "ping"})).unwrap();
    }

    /// A `cmux.protocol/2` request with the id `id`.
    fn send(&mut self, id: &str, operation: &str, mut params: Value) {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if operation == "diff.comments.save" || operation == "git.commit" {
            request["idempotency_key"] = json!(format!("glane-{}-{id}", std::process::id()));
        }
        writeln!(self.writer, "{request}").unwrap();
    }

    /// The reply with `id` among the lines the connection sends in `wait`;
    /// `None` when it did not come by then.
    fn reply_in(&mut self, id: &Value, wait: Duration) -> Option<Value> {
        if let Some(index) = self.seen.iter().position(|reply| &reply["id"] == id) {
            return Some(self.seen.remove(index));
        }
        let deadline = Instant::now() + wait;
        loop {
            let left = deadline.checked_duration_since(Instant::now())?;
            let left = left.max(Duration::from_millis(1));
            self.reader.get_ref().set_read_timeout(Some(left)).unwrap();
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => panic!("the connection closed before the reply {id}"),
                Ok(_) => {}
                Err(_) => return None,
            }
            let reply: Value = serde_json::from_str(&line).unwrap();
            if &reply["id"] == id {
                return Some(reply);
            }
            if reply.get("id").is_some() {
                self.seen.push(reply);
            }
        }
    }

    fn reply(&mut self, id: &Value) -> Value {
        self.reply_in(id, LONG).unwrap_or_else(|| panic!("no reply {id} in {LONG:?}"))
    }

    /// The replies the connection sends, `count` at most, until it closes
    /// or `wait` ends; and whether it closed.
    fn replies(&mut self, count: usize, wait: Duration) -> (Vec<Value>, bool) {
        let mut replies = std::mem::take(&mut self.seen);
        let deadline = Instant::now() + wait;
        while replies.len() < count {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { break };
            let left = left.max(Duration::from_millis(1));
            self.reader.get_ref().set_read_timeout(Some(left)).unwrap();
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => return (replies, true),
                Ok(_) => {}
                Err(_) => break,
            }
            // A line that the close cut is not a reply.
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { return (replies, true) };
            if reply.get("id").is_some() {
                replies.push(reply);
            }
        }
        (replies, false)
    }

    fn answered(&self, id: &str) -> bool {
        self.seen.iter().any(|reply| reply["id"] == json!(id))
    }

    /// Whether the daemon closed the connection in `wait`.
    fn closed_in(&mut self, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        loop {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { return false };
            let left = left.max(Duration::from_millis(1));
            self.reader.get_ref().set_read_timeout(Some(left)).unwrap();
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }

    /// A connection whose far end wrote `lines` and then closed its whole
    /// end, before any look of this client. A daemon that ends a connection
    /// does that: it closes each descriptor of its socket at once.
    fn closed_after(lines: &str) -> Self {
        let (near, mut far) = UnixStream::pair().unwrap();
        far.write_all(lines.as_bytes()).unwrap();
        drop(far);
        let writer = near.try_clone().unwrap();
        Self { writer, reader: BufReader::new(near), seen: Vec::new() }
    }
}

/// 2 reply lines, as a daemon writes them.
const TWO_REPLIES: &str = "{\"id\":\"a\",\"ok\":true}\n{\"id\":\"b\",\"ok\":true}\n";

/// The 3 looks of the test client itself, each on a connection that closed
/// before the look. macOS refuses a read timeout on such a socket; a look
/// that takes that for a fault of the test makes its test fail by chance,
/// when the daemon's close comes before the look.
#[test]
fn git_lane_the_test_client_sees_a_close_that_came_before_its_look() {
    let closed = Connection::closed_after("").closed_in(Duration::from_secs(1));
    assert!(closed, "the look for a close did not see a connection that closed before it");
}

#[test]
fn git_lane_the_test_client_reads_the_replies_that_a_closed_connection_left() {
    let mut connection = Connection::closed_after(TWO_REPLIES);
    let (replies, closed) = connection.replies(3, Duration::from_secs(1));
    let ids: Vec<Value> = replies.iter().map(|reply| reply["id"].clone()).collect();
    assert_eq!((ids, closed), (vec![json!("a"), json!("b")], true), "the 2 lines, then closed");
}

#[test]
fn git_lane_the_test_client_finds_the_reply_that_a_closed_connection_left() {
    let mut connection = Connection::closed_after(TWO_REPLIES);
    let reply = connection.reply_in(&json!("b"), Duration::from_secs(1));
    assert_eq!(reply.map(|reply| reply["ok"].clone()), Some(json!(true)), "the reply b");
    assert!(connection.answered("a"), "the reply a is kept for a later look");
}

/// The person's case: the warm `git.diff` of a hidden chat runs for seconds,
/// and the `git.status` of the view the person looks at comes behind it on
/// the app's git connection.
#[test]
fn git_lane_a_git_status_behind_a_running_git_diff_is_answered_while_the_diff_runs() {
    let (repo, gate) = repository("person");
    let mut app = Connection::open(&daemon());

    gate.hold("hold-diff");
    app.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    gate.wait_held();

    let asked = Instant::now();
    app.send("status", "git.status", json!({"path": repo}));
    let status = app.reply_in(&json!("status"), Duration::from_secs(10));
    let status_ms = asked.elapsed().as_millis();
    let diff_early = app.answered("diff");

    gate.release("hold-diff");
    let diff = app.reply(&json!("diff"));
    let late = status.is_none().then(|| app.reply(&json!("status")));
    eprintln!(
        "git-lane: git.status behind a held git.diff: answered while the diff ran: {} (waited \
         {status_ms} ms); answered only after the diff ended: {} ({} ms after it was sent)",
        status.is_some(),
        late.is_some(),
        asked.elapsed().as_millis(),
    );

    assert!(!diff_early, "git.diff answered while its git was held");
    assert_eq!(diff["ok"], true, "git.diff failed: {diff}");
    assert_eq!(diff["result"]["files"][0]["path"], "a.txt", "{diff}");
    let status = status.expect("a git.status behind a running git.diff waited for the diff");
    assert_eq!(status["ok"], true, "git.status failed: {status}");
    assert_eq!(status["result"]["detached"], false, "{status}");
}

/// A burst of turn ends: the diffs of hidden chats take each place a long
/// read may take and 21 more wait. The `git.status` of the view the person
/// just opened comes last, and must not wait for them: a place is kept for
/// short reads.
#[test]
fn git_lane_a_git_status_behind_held_and_queued_git_diffs_is_answered_while_they_are_held() {
    const DIFFS: usize = 24;
    let (repo, gate) = repository("short");
    let mut app = Connection::open(&daemon());

    gate.hold("hold-diff");
    for number in 0..DIFFS {
        // A different `context_lines` makes a different read, so no two share a run.
        let params = json!({"path": repo, "scope": "uncommitted", "context_lines": number + 4});
        app.send(&format!("d{number}"), "git.diff", params);
    }
    // A `git diff` child of each: a diff also runs other git children before
    // it, which the gate does not hold.
    wait_for("each diff place held", || gate.runs_of("diff") >= LONG_GIT_RUNS);

    let asked = Instant::now();
    app.send("status", "git.status", json!({"path": repo}));
    let status = app.reply_in(&json!("status"), Duration::from_secs(10));
    let status_ms = asked.elapsed().as_millis();
    let diffs_early = (0..DIFFS).filter(|number| app.answered(&format!("d{number}"))).count();
    let held = gate.runs_of("diff");

    gate.release("hold-diff");
    for number in 0..DIFFS {
        let diff = app.reply(&json!(format!("d{number}")));
        assert_eq!(diff["ok"], true, "git.diff {number} failed: {diff}");
    }
    let late = status.is_none().then(|| app.reply(&json!("status")));
    eprintln!(
        "git-lane: git.status behind {DIFFS} git.diff ({held} held in git, the rest waiting): \
         answered while they were held: {} (waited {status_ms} ms); answered only after they \
         ended: {}",
        status.is_some(),
        late.is_some(),
    );

    assert_eq!(diffs_early, 0, "a git.diff answered while its git was held");
    let status = status.expect("a git.status waited behind held and queued git.diff requests");
    assert_eq!(status["ok"], true, "git.status failed: {status}");
    assert_eq!(held, LONG_GIT_RUNS, "git.diff runs at one time, with a place kept for short reads");
}

/// A liveness ping and a request that is not git, behind a running `git.diff`.
#[test]
fn git_lane_requests_behind_a_running_git_diff_are_answered_while_git_runs() {
    let (repo, gate) = repository("other");
    let mut app = Connection::open(&daemon());

    gate.hold("hold-all");
    app.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    gate.wait_held();

    let asked = Instant::now();
    app.ping(2);
    app.send("list", "workspace.list", json!({}));
    let ping = app.reply_in(&json!(2), Duration::from_secs(10));
    let list = app.reply_in(&json!("list"), Duration::from_secs(10));
    let waited_ms = asked.elapsed().as_millis();
    let diff_early = app.answered("diff");

    gate.release("hold-all");
    let diff = app.reply(&json!("diff"));
    eprintln!(
        "git-lane: behind a held git.diff: ping answered while git ran: {}; list answered while \
         git ran: {} (waited {waited_ms} ms)",
        ping.is_some(),
        list.is_some(),
    );

    assert!(!diff_early, "git.diff answered while its git was held");
    assert_eq!(diff["ok"], true, "git.diff failed: {diff}");
    assert!(ping.is_some(), "a ping behind a running git.diff waited for git");
    let list = list.expect("workspace.list behind a running git.diff waited for git");
    assert_eq!(list["ok"], true, "workspace.list failed: {list}");
}

/// 50 different reads from 2 connections: the daemon runs [`GIT_RUNS`] of
/// them at one time, never more, and answers each one.
#[test]
fn git_lane_fifty_queued_reads_run_at_most_the_bound_of_git_children() {
    let (repo, gate) = repository("bound");
    let socket = daemon();
    let mut connections = [Connection::open(&socket), Connection::open(&socket)];

    gate.hold("hold-all");
    let mut sent = Vec::new();
    for number in 0..48usize {
        // A different `limit` makes a different read, so no two share a run.
        let id = format!("b{number}");
        let params = json!({"path": repo, "limit": number + 1});
        connections[number % 2].send(&id, "git.branches", params);
        sent.push((number % 2, id));
    }
    // One short read of each connection: a short read may take the place
    // that long reads leave free.
    for (index, connection) in connections.iter_mut().enumerate() {
        let id = format!("s{index}");
        connection.send(&id, "git.status", json!({"path": repo}));
        sent.push((index, id));
    }
    wait_for("full git lane", || gate.active() >= GIT_RUNS);
    // Each connection read all its requests: its later ping is answered.
    for connection in &mut connections {
        connection.ping(9);
        connection.reply(&json!(9));
    }
    // The other 46 wait in the daemon, not in git: no more children come.
    let watch = Instant::now() + Duration::from_millis(1500);
    let mut most = gate.active();
    while Instant::now() < watch {
        most = most.max(gate.active());
        std::thread::sleep(Duration::from_millis(10));
    }

    gate.release("hold-all");
    for (index, id) in &sent {
        let reply = connections[*index].reply(&json!(id));
        assert_eq!(reply["ok"], true, "the read {id} failed: {reply}");
    }
    eprintln!(
        "git-lane: 50 reads: most git children while held: {most}; most at the start of any \
         run: {}",
        gate.peak()
    );
    assert_eq!(most, GIT_RUNS, "git children at one time while 50 reads waited");
    assert_eq!(gate.peak(), GIT_RUNS, "git children at one time in the full test");
}

/// Equal reads that wait for a place share one run, and each gets its reply.
#[test]
fn git_lane_equal_queued_reads_share_one_git_run() {
    let (busy, busy_gate) = repository("busy");
    let (repo, gate) = repository("equal");
    let mut app = Connection::open(&daemon());

    // The lane is full: later reads wait.
    busy_gate.hold("hold-all");
    let fill = fill_the_read_places(&mut app, &busy, &busy_gate);
    for number in 0..5 {
        app.send(&format!("s{number}"), "git.status", json!({"path": repo}));
    }
    // A read with other params is a different read: it has its own run.
    app.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    app.ping(9);
    app.reply(&json!(9));

    busy_gate.release("hold-all");
    let mut results = Vec::new();
    for number in 0..5 {
        let reply = app.reply(&json!(format!("s{number}")));
        assert_eq!(reply["ok"], true, "git.status {number} failed: {reply}");
        results.push(reply["result"].clone());
    }
    let diff = app.reply(&json!("diff"));
    assert_eq!(diff["ok"], true, "git.diff failed: {diff}");
    for id in &fill {
        let reply = app.reply(&json!(id));
        assert_eq!(reply["ok"], true, "the held read {id} failed: {reply}");
    }
    eprintln!(
        "git-lane: 5 equal git.status that waited: {} git status runs",
        gate.runs_of("status")
    );
    assert!(results.iter().all(|result| result == &results[0]), "{results:?}");
    assert_eq!(gate.runs_of("status"), 1, "git status runs for 5 equal reads that waited");
}

/// One run takes a bounded count of equal reads: [`SHARED_READS`] join the
/// first, and the next equal read is a run of its own. So the most that one
/// run takes get one run, and one read more gets a second run.
#[test]
fn git_lane_equal_reads_above_the_bound_of_one_run_get_a_second_run() {
    const ONE_RUN: usize = SHARED_READS + 1;
    const EQUAL: usize = SHARED_READS + 2;
    let (busy, busy_gate) = repository("busy");
    let (full, full_gate) = repository("full");
    let (repo, gate) = repository("many");
    let mut app = Connection::open(&daemon());

    // The lane is full: later reads wait.
    busy_gate.hold("hold-all");
    let fill = fill_the_read_places(&mut app, &busy, &busy_gate);
    for number in 0..ONE_RUN {
        app.send(&format!("r{number}"), "git.status", json!({"path": full}));
    }
    for number in 0..EQUAL {
        app.send(&format!("s{number}"), "git.status", json!({"path": repo}));
    }
    app.ping(9);
    app.reply(&json!(9));

    busy_gate.release("hold-all");
    let (replies, closed) = app.replies(fill.len() + ONE_RUN + EQUAL, LONG);
    let answered_of = |first: char| {
        replies
            .iter()
            .filter(|reply| reply["id"].as_str().is_some_and(|id| id.starts_with(first)))
            .filter(|reply| reply["ok"] == true)
            .count()
    };
    let (answered_one, answered) = (answered_of('r'), answered_of('s'));
    let (runs_one, runs) = (full_gate.runs_of("status"), gate.runs_of("status"));
    eprintln!(
        "git-lane: {ONE_RUN} equal git.status that waited: {answered_one} answered, {runs_one} \
         git status runs; {EQUAL} equal git.status that waited: {answered} answered, {runs} git \
         status runs, closed by the daemon: {closed}"
    );
    assert_eq!(answered_one, ONE_RUN, "equal git.status of one run that got their answer");
    assert_eq!(runs_one, 1, "git status runs for the {ONE_RUN} equal reads that one run takes");
    assert_eq!(answered, EQUAL, "equal git.status that got their answer");
    assert_eq!(runs, 2, "git status runs: one for the first {ONE_RUN} reads, one more");
}

/// A mutation keeps its place in its connection's order: it starts after the
/// git requests before it ended, and the reads after it see what it wrote.
#[test]
fn git_lane_a_mutation_keeps_its_place_in_its_connections_order() {
    let (repo, gate) = repository("order");
    let (socket, _mux) = persistent_daemon("order");
    let mut app = Connection::open(&socket);

    gate.hold("hold-diff");
    app.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    gate.wait_held();
    let comment = json!({"filePath": "a.txt", "message": "kept in order"});
    app.send("save", "diff.comments.save", json!({"root": repo, "comment": comment}));
    app.send("list", "diff.comments.list", json!({"root": repo}));
    app.ping(9);
    app.reply(&json!(9));
    // The save waits for the diff before it, and the list for the save.
    let early = app.reply_in(&json!("list"), Duration::from_millis(1000));
    let save_early = app.answered("save");

    gate.release("hold-diff");
    let diff = app.reply(&json!("diff"));
    let save = app.reply(&json!("save"));
    let list = early.clone().unwrap_or_else(|| app.reply(&json!("list")));
    assert_eq!(diff["ok"], true, "git.diff failed: {diff}");
    assert_eq!(save["ok"], true, "diff.comments.save failed: {save}");
    assert_eq!(list["ok"], true, "diff.comments.list failed: {list}");
    assert!(!save_early, "the mutation ran beside the git.diff before it");
    assert!(early.is_none(), "the read behind the mutation was answered before it");
    let comments = list["result"]["comments"].as_array().unwrap();
    assert_eq!(comments.len(), 1, "the list after the save has its comment: {list}");
    assert_eq!(comments[0]["message"], "kept in order", "{list}");
}

/// The 20 s limit of a git run stays: a git that passes it is ended, its
/// request gets an error, and its place in the lane is free again.
#[test]
fn git_lane_a_git_past_its_limit_gets_an_error_and_frees_its_place() {
    let (stuck, stuck_gate) = repository("stuck");
    let (repo, _gate) = repository("free");
    let socket = daemon();
    let mut first = Connection::open(&socket);
    let mut second = Connection::open(&socket);

    // Never released: each of these git runs ends at the daemon's limit.
    stuck_gate.hold("hold-all");
    let fill = fill_the_read_places(&mut first, &stuck, &stuck_gate);
    let asked = Instant::now();
    second.send("status", "git.status", json!({"path": repo}));

    for id in &fill {
        let reply = first.reply(&json!(id));
        assert_eq!(reply["ok"], false, "a git held past its limit answered ok: {reply}");
        assert_eq!(reply["error"]["code"], "operation.failed", "{reply}");
    }
    let status = second.reply(&json!("status"));
    eprintln!(
        "git-lane: {GIT_RUNS} git runs held past the limit got errors; the read behind them was \
         answered {} ms after it was sent",
        asked.elapsed().as_millis()
    );
    assert_eq!(status["ok"], true, "the read behind the ended runs failed: {status}");
}

/// A client that sends a git request and ends its writes still gets the reply
/// before the daemon closes the connection.
#[test]
fn git_lane_a_client_that_ends_its_writes_still_gets_its_git_reply() {
    let (repo, gate) = repository("eof");
    let mut cli = Connection::open(&daemon());

    gate.hold("hold-all");
    cli.send("status", "git.status", json!({"path": repo}));
    cli.writer.shutdown(Shutdown::Write).unwrap();
    gate.wait_held();
    gate.release("hold-all");

    let status = cli.reply(&json!("status"));
    assert_eq!(status["ok"], true, "git.status failed: {status}");
}

/// A CLI that a person stops: it sent a `git.status`, each read place holds a
/// git of the app, and the CLI closed its whole end. Nobody can read that
/// reply. The daemon must not keep the client (its registration holds its
/// size leases and its attached surfaces) until a place is free and its git
/// ran: the client leaves while the places are still held, and its read
/// starts no git.
#[test]
fn git_lane_a_client_that_closed_leaves_while_its_git_read_waits_and_the_read_starts_no_git() {
    let (held_repo, held) = repository("gone-held");
    let (repo, gate) = repository("gone");
    let (socket, mux) = persistent_daemon("gone");
    let mut app = Connection::open(&socket);
    held.hold("hold-all");
    let fills = fill_the_read_places(&mut app, &held_repo, &held);
    let clients = mux.client_count();

    let mut cli = Connection::open(&socket);
    cli.send("status", "git.status", json!({"path": repo}));
    // The daemon read the status line: it answers the line after it.
    cli.ping(1);
    cli.reply(&json!(1));
    assert_eq!(mux.client_count(), clients + 1, "the CLI is a client");
    let closed_at = Instant::now();
    drop(cli);

    let left = done_in(GONE, || mux.client_count() == clients);
    let (stayed, places_held) = (closed_at.elapsed(), held.active());
    held.release("hold-all");
    for id in &fills {
        let reply = app.reply(&json!(id));
        assert_eq!(reply["ok"], true, "{id} failed: {reply}");
    }
    // The CLI's status came before this one, so a status that still waited
    // started before it.
    app.send("after", "git.status", json!({"path": held_repo}));
    app.reply(&json!("after"));
    let runs = gate.runs_of("status");
    eprintln!(
        "git-lane: a client that closed with a git.status that waits: left in {GONE:?}: {left} \
         (looked for {stayed:?}, {places_held} git runs held then); git runs of its status: {runs}"
    );
    assert!(left, "a client that closed stayed a client while its git.status waited for a place");
    assert_eq!(runs, 0, "the git.status of a client that closed started git");
}

/// A client that closes later: it ended its writes with one `git.status` in
/// git and one `git.diff` that waits, and then closed its whole end. Its
/// first reply cannot be written, which closes its writer. From then nobody
/// reads the reply of the diff: the client leaves while the diff still waits
/// for a place.
#[test]
fn git_lane_a_client_whose_writer_closed_leaves_while_its_next_git_read_waits() {
    let (held_repo, held) = repository("late-held");
    let (repo, gate) = repository("late");
    let (socket, mux) = persistent_daemon("late");
    let mut app = Connection::open(&socket);
    held.hold("hold-all");
    for number in 0..LONG_GIT_RUNS {
        let params =
            json!({"path": held_repo, "scope": "uncommitted", "context_lines": number + 1});
        app.send(&format!("fill{number}"), "git.diff", params);
    }
    wait_for("each long read place held", || held.active() >= LONG_GIT_RUNS);
    let clients = mux.client_count();

    let mut cli = Connection::open(&socket);
    gate.hold("hold-all");
    // The status takes the place for short reads and waits at its gate; the
    // diff waits for a place behind the app's diffs.
    cli.send("status", "git.status", json!({"path": repo}));
    gate.wait_held();
    cli.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    cli.ping(1);
    cli.reply(&json!(1));
    assert_eq!(mux.client_count(), clients + 1, "the CLI is a client");
    // First the end of its writes, as a client that waits for its replies;
    // the daemon is at the end of its input before the whole end closes.
    cli.writer.shutdown(Shutdown::Write).unwrap();
    // This sleep decides no result. It decides which way the client leaves:
    // without it the daemon can see the whole close at the end of its input.
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(mux.client_count(), clients + 1, "a client that ended its writes stays");
    drop(cli);
    // Its status runs to its end; the write of that reply fails.
    let released_at = Instant::now();
    gate.release("hold-all");

    let left = done_in(GONE, || mux.client_count() == clients);
    let (stayed, places_held) = (released_at.elapsed(), held.active());
    held.release("hold-all");
    for number in 0..LONG_GIT_RUNS {
        let id = format!("fill{number}");
        let reply = app.reply(&json!(id));
        assert_eq!(reply["ok"], true, "{id} failed: {reply}");
    }
    eprintln!(
        "git-lane: a client that closed after it ended its writes, with a git.diff that waits: \
         left in {GONE:?}: {left} (looked for {stayed:?}, {places_held} git runs of the app \
         held then)"
    );
    // No count of the git runs of its diff: a read whose writer closed runs
    // no git in any case (`Job::run`), so that count shows nothing here.
    assert!(left, "a client whose writer closed stayed a client while its git.diff waited");
}

/// The one ask the daemon makes at the end of a client's input
/// (`transport::Stream::peer_gone`): is the client gone, or did it only end
/// its writes and still reads its replies? Beside it, what the older ask
/// says (`peer_closed`, a poll for reading), which is "closed" for both on
/// macOS.
#[test]
fn git_lane_a_closed_peer_is_gone_and_one_that_ended_its_writes_is_not() {
    use cmux_tui_core::platform::transport::Stream;
    let mut said = Vec::new();
    for state in ["open", "ended its writes", "closed", "sent a line and closed"] {
        let (mut near, mut far) = UnixStream::pair().unwrap();
        match state {
            "open" => {}
            "ended its writes" => far.shutdown(Shutdown::Write).unwrap(),
            "closed" => drop(far),
            _ => {
                far.write_all(b"line\n").unwrap();
                drop(far);
            }
        }
        if state != "open" {
            // As the daemon's reader: at the end of the input.
            let mut input = Vec::new();
            std::io::Read::read_to_end(&mut near, &mut input).unwrap();
        }
        let (gone, closed) = (near.peer_gone(), near.peer_closed());
        eprintln!("git-lane: the peer {state}: gone: {gone} (the older ask, closed: {closed})");
        said.push((state, gone));
    }
    let wanted = [
        ("open", false),
        ("ended its writes", false),
        ("closed", true),
        ("sent a line and closed", true),
    ];
    assert_eq!(said, wanted, "whether each peer is gone");
}

/// A client that is there and does not read: this side's send buffer is full,
/// so a poll for writing does not say "writable". That is not a hang-up. The
/// client is not gone, also when it ended its writes before: it gets its
/// replies when it reads again. Only after it closed its whole end is it gone.
#[test]
fn git_lane_a_peer_that_does_not_read_is_not_gone_while_the_send_buffer_is_full() {
    use cmux_tui_core::platform::transport::Stream;
    let mut said = Vec::new();
    for state in ["open", "ended its writes"] {
        let (mut near, far) = UnixStream::pair().unwrap();
        if state == "ended its writes" {
            far.shutdown(Shutdown::Write).unwrap();
            // As the daemon's reader: at the end of the input.
            let mut input = Vec::new();
            std::io::Read::read_to_end(&mut near, &mut input).unwrap();
        }
        near.set_nonblocking(true).unwrap();
        let (chunk, mut filled) = ([0u8; 4096], 0usize);
        loop {
            match near.write(&chunk) {
                Ok(written) => filled += written,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("the write to a peer that is there failed: {error}"),
            }
        }
        let full = near.peer_gone();
        drop(far);
        let closed = near.peer_gone();
        eprintln!(
            "git-lane: the peer {state} and does not read, {filled} bytes fill the send buffer: \
             gone: {full}; after it closed its whole end: gone: {closed}"
        );
        said.push((state, full, closed));
    }
    let wanted = [("open", false, true), ("ended its writes", false, true)];
    assert_eq!(said, wanted, "whether a peer that does not read is gone, then after it closed");
}

/// A script that sends a save and closes its whole end with no wait for the
/// reply: the save is work the daemon took, so it still runs.
#[test]
fn git_lane_a_mutation_that_waits_when_its_client_closes_still_runs() {
    let (repo, gate) = repository("gone-save");
    let (socket, mux) = persistent_daemon("gone-save");
    let mut other = Connection::open(&socket);
    let clients = mux.client_count();
    let mut script = Connection::open(&socket);

    gate.hold("hold-diff");
    script.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    gate.wait_held();
    let comment = json!({"filePath": "a.txt", "message": "kept after the close"});
    script.send("save", "diff.comments.save", json!({"root": repo, "comment": comment}));
    script.ping(9);
    script.reply(&json!(9));
    // The save waits for the diff before it, and the client closes.
    drop(script);
    let left = done_in(GONE, || mux.client_count() == clients);
    gate.release("hold-diff");

    let saved = a_comment_is_saved(&mut other, &repo);
    eprintln!(
        "git-lane: a save that waited when its client closed (the client left while the diff \
         before it was held: {left}): saved: {saved}"
    );
    assert!(saved, "a diff.comments.save the daemon took was dropped when its client closed");
}

/// The lane is one queue for the whole daemon, so a CLI's `git.status` on a
/// connection of its own comes behind the app's diffs. They are long reads
/// and the place for short reads is free: it is answered while they are held.
/// The time it prints is of a stand-in git on a small repository and an idle
/// machine: a lower bound.
#[test]
fn git_lane_a_git_status_of_another_connection_is_answered_while_the_apps_git_diffs_are_held() {
    const DIFFS: usize = 24;
    const ASKS: usize = 20;
    let (repo, gate) = repository("cli");
    let socket = daemon();
    let mut app = Connection::open(&socket);
    let mut cli = Connection::open(&socket);

    gate.hold("hold-diff");
    for number in 0..DIFFS {
        let params = json!({"path": repo, "scope": "uncommitted", "context_lines": number + 4});
        app.send(&format!("d{number}"), "git.diff", params);
    }
    wait_for("a diff held", || gate.runs_of("diff") >= 1);
    // The lane holds 3 diffs in git. A daemon that runs a connection's git
    // on its reader holds 1: the wait for 3 has an end of its own.
    let all_held = Instant::now() + Duration::from_secs(3);
    while gate.runs_of("diff") < LONG_GIT_RUNS && Instant::now() < all_held {
        std::thread::sleep(Duration::from_millis(5));
    }
    let held = gate.runs_of("diff");

    let mut waits = Vec::new();
    let mut unanswered = 0;
    for number in 0..ASKS {
        let id = format!("s{number}");
        let asked = Instant::now();
        cli.send(&id, "git.status", json!({"path": repo}));
        match cli.reply_in(&json!(id), Duration::from_secs(10)) {
            Some(status) => {
                waits.push(asked.elapsed());
                assert_eq!(status["ok"], true, "git.status {number} failed: {status}");
            }
            None => unanswered += 1,
        }
    }
    let diffs_early = (0..DIFFS).filter(|number| app.answered(&format!("d{number}"))).count();

    gate.release("hold-diff");
    for number in 0..DIFFS {
        let diff = app.reply(&json!(format!("d{number}")));
        assert_eq!(diff["ok"], true, "git.diff {number} failed: {diff}");
    }
    waits.sort_unstable();
    let ms = |index: usize| waits.get(index).map_or(-1.0, |wait| wait.as_secs_f64() * 1000.0);
    eprintln!(
        "git-lane: a git.status of another connection while the app has {DIFFS} git.diff \
         ({held} held in git, the rest waiting): {} of {ASKS} answered while they were held: min \
         {:.1} ms, p50 {:.1} ms, max {:.1} ms",
        waits.len(),
        ms(0),
        ms(waits.len() / 2),
        ms(waits.len().saturating_sub(1)),
    );
    assert_eq!(diffs_early, 0, "a git.diff answered while its git was held");
    assert_eq!(unanswered, 0, "a git.status of another connection waited for the app's diffs");
}

/// A daemon that shuts down (an update, a logout) or hands its session over
/// refuses each line it reads after that as "not executed", so the client
/// sends it again to the next daemon. A git request that still waits for a
/// place then has not run either: it gets the same refusal and never starts.
#[test]
fn git_lane_a_git_request_that_waits_when_the_shutdown_begins_is_refused_and_does_not_run() {
    let (repo, gate) = repository("fence");
    let (socket, mux) = persistent_daemon("fence");
    let mut app = Connection::open(&socket);

    gate.hold("hold-diff");
    app.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    gate.wait_held();
    let comment = json!({"filePath": "a.txt", "message": "after the fence"});
    app.send("save", "diff.comments.save", json!({"root": repo, "comment": comment}));
    app.send("list", "diff.comments.list", json!({"root": repo}));
    // The reader took both: its later ping is answered.
    app.ping(9);
    app.reply(&json!(9));

    mux.request_daemon_shutdown();
    gate.release("hold-diff");
    let diff = app.reply(&json!("diff"));
    let save = app.reply(&json!("save"));
    let list = app.reply(&json!("list"));

    assert_eq!(diff["ok"], true, "the git.diff that ran before the shutdown failed: {diff}");
    for (name, reply) in [("diff.comments.save", &save), ("diff.comments.list", &list)] {
        assert_eq!(reply["ok"], false, "{name} started after the shutdown began: {reply}");
        assert_eq!(reply["error"]["code"], "operation.failed", "{name}: {reply}");
        assert_eq!(
            reply["error"]["details"]["reason"], "daemon_handoff_pending",
            "{name}: {reply}"
        );
    }
}

/// A connection that breaks has no reader for its replies, so its reads that
/// wait are dropped. A mutation that waits is work the daemon took: it still
/// runs, as it did when the reader ran each line it read.
#[test]
fn git_lane_a_mutation_that_waits_when_its_connection_breaks_still_runs() {
    let (repo, gate) = repository("broken");
    let (socket, _mux) = persistent_daemon("broken");
    let mut app = Connection::open(&socket);

    gate.hold("hold-diff");
    app.send("diff", "git.diff", json!({"path": repo, "scope": "uncommitted"}));
    gate.wait_held();
    let comment = json!({"filePath": "a.txt", "message": "kept after the break"});
    app.send("save", "diff.comments.save", json!({"root": repo, "comment": comment}));
    app.ping(9);
    app.reply(&json!(9));
    // Not UTF-8: the daemon cannot read this line and ends the connection as
    // a broken one, while the save waits for the diff before it.
    app.writer.write_all(b"\xff\n").unwrap();
    let closed = app.closed_in(Duration::from_secs(5));
    gate.release("hold-diff");

    let saved = a_comment_is_saved(&mut Connection::open(&socket), &repo);
    eprintln!(
        "git-lane: a save that waited when its connection broke (closed by the daemon: \
         {closed}): saved: {saved}"
    );
    assert!(saved, "a diff.comments.save the daemon took was dropped when its connection broke");
}

/// Whether `repo` gets its one saved comment in 10 s, asked on `other`.
fn a_comment_is_saved(other: &mut Connection, repo: &str) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let id = unique("l");
        other.send(&id, "diff.comments.list", json!({"root": repo}));
        let list = other.reply(&json!(id));
        assert_eq!(list["ok"], true, "diff.comments.list failed: {list}");
        let comments = list["result"]["comments"].as_array().map_or(0, Vec::len);
        if comments == 1 {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Sends [`GIT_RUNS`] different `operation` reads of a repository whose git
/// is held, then a `git.status` of another repository on the same
/// connection: the status must be answered while they are held.
fn a_git_status_behind_four_held(name: &str, operation: &str, extra: &Value) {
    let (tree, tree_gate) = repository("tree");
    let (repo, _gate) = repository("view");
    let (socket, _mux) = persistent_daemon(name);
    let mut app = Connection::open(&socket);

    tree_gate.hold("hold-all");
    for number in 0..GIT_RUNS {
        // A different `limit` makes a different read, so no two share a run.
        let mut params = extra.clone();
        params["path"] = json!(tree);
        params["limit"] = json!(number + 1);
        app.send(&format!("t{number}"), operation, params);
    }
    let asked = Instant::now();
    app.send("status", "git.status", json!({"path": repo}));
    let status = app.reply_in(&json!("status"), Duration::from_secs(5));
    let waited = asked.elapsed().as_millis();
    let early: Vec<usize> =
        (0..GIT_RUNS).filter(|number| app.answered(&format!("t{number}"))).collect();

    tree_gate.release("hold-all");
    for number in 0..GIT_RUNS {
        let reply = app.reply(&json!(format!("t{number}")));
        assert_eq!(reply["ok"], true, "{operation} {number} failed: {reply}");
    }
    eprintln!(
        "git-lane: a git.status behind {GIT_RUNS} held {operation}: answered while they were \
         held: {} (waited {waited} ms)",
        status.is_some()
    );
    assert!(early.is_empty(), "{operation} {early:?} answered while git was held");
    let Some(status) = status else {
        panic!("the git.status waited for {GIT_RUNS} held {operation}");
    };
    assert_eq!(status["ok"], true, "git.status failed: {status}");
}

/// The branches are a long read: a git child for each branch, so their git
/// work grows with the repository. Four of them do not take the place that
/// is kept for short reads.
#[test]
fn git_lane_a_git_status_is_answered_while_four_git_branches_are_held() {
    a_git_status_behind_four_held("branches", "git.branches", &json!({}));
}

/// A checkpoint list with its candidates is a long read: it lists the
/// untracked and the ignored paths of the whole tree.
#[test]
fn git_lane_a_git_status_is_answered_while_four_checkpoint_lists_with_candidates_are_held() {
    let extra = json!({"include_candidates": true});
    a_git_status_behind_four_held("candidates", "git.checkpoint.list", &extra);
}

/// Equal reads that share one run each get a copy of its reply. The copies
/// of a large reply go to the connection one after the other: all at one
/// time they are more than the connection's reply queue takes (32 MiB), and
/// the daemon closes a connection whose queue is full.
#[test]
fn git_lane_equal_reads_with_a_large_reply_each_get_it_and_the_connection_stays_open() {
    const EQUAL: usize = 60;
    let (busy, busy_gate) = repository("busy");
    let (repo, _gate) = repository("large");
    // A change of about 800 KiB: 60 copies of its patch are about 48 MiB.
    let line = "a line of a large change that a person made in one file\n";
    std::fs::write(Path::new(&repo).join("a.txt"), line.repeat(14_000)).unwrap();
    let mut app = Connection::open(&daemon());

    // Each long place is held, so the equal reads wait and share one run.
    busy_gate.hold("hold-all");
    let fill = fill_the_read_places(&mut app, &busy, &busy_gate);
    let params = json!({
        "path": repo,
        "scope": "uncommitted",
        "include_patch": true,
        "max_patch_bytes": 4_194_304,
    });
    for number in 0..EQUAL {
        app.send(&format!("e{number}"), "git.diff", params.clone());
    }
    app.ping(9);
    app.reply(&json!(9));

    busy_gate.release("hold-all");
    // The client reads nothing for a time (less than the daemon's 2 s limit
    // of one write): the daemon has more copies than its queue takes before
    // the client reads the first.
    std::thread::sleep(Duration::from_millis(700));
    let (replies, closed) = app.replies(fill.len() + EQUAL, LONG);
    let equal: Vec<&Value> = replies
        .iter()
        .filter(|reply| reply["id"].as_str().is_some_and(|id| id.starts_with('e')))
        .collect();
    let patch_bytes = |reply: &Value| {
        let files = reply["result"]["files"].as_array();
        let patches = files.into_iter().flatten().filter_map(|file| file["patch"].as_str());
        patches.map(str::len).sum::<usize>()
    };
    let smallest = equal.iter().copied().map(patch_bytes).min().unwrap_or(0);
    eprintln!(
        "git-lane: {EQUAL} equal git.diff that waited, one git run: {} answered, the smallest \
         patch {smallest} bytes, the connection closed by the daemon: {closed}",
        equal.len()
    );
    assert_eq!(
        equal.len(),
        EQUAL,
        "equal git.diff answered before the connection closed ({closed}) or the wait ended"
    );
    assert!(equal.iter().all(|reply| reply["ok"] == true), "an equal git.diff failed");
    assert!(smallest > 700_000, "the patch of a copy has {smallest} bytes");
    assert!(!closed, "the daemon closed the connection");
}

/// A connection that stops to read while the copies of a shared reply go to
/// it: the copies wait for room in its reply queue, and that wait holds no
/// place of the lane. So while they wait, another connection's long reads
/// take each of the long places, a `git.status` of another connection
/// answers, and a `git.status` of the same connection runs to its end: the
/// test reads again only after the last git child of that status ended, so
/// its reply is in the connection's queue before the copies that still wait.
///
/// The connection reads up to the first of its 60 equal replies (the sign
/// that their one run ended) and then nothing more until the checks are
/// done: 59 copies of about 800 KiB (46 MiB) are then not read, more than
/// the reply queue (32 MiB) and the socket take, so copies wait until the
/// connection reads again. The daemon closes a connection that reads
/// nothing after its 2 s limit of one write, and that ends the wait: the
/// check of the long places has a bound below it, and a daemon that closed
/// the connection fails the test.
#[test]
fn git_lane_copies_that_wait_for_a_connection_that_does_not_read_hold_no_place() {
    const EQUAL: usize = 60;
    let (busy, busy_gate) = repository("busy");
    let (repo, _gate) = repository("large");
    let (held, held_gate) = repository("held");
    let (seen, _seen_gate) = repository("seen");
    let (own, own_gate) = repository("own");
    let line = "a line of a large change that a person made in one file\n";
    std::fs::write(Path::new(&repo).join("a.txt"), line.repeat(14_000)).unwrap();
    let socket = daemon();
    let mut slow = Connection::open(&socket);
    let mut other = Connection::open(&socket);

    // Each read place is held, so the equal reads wait and share one run.
    busy_gate.hold("hold-all");
    let fill = fill_the_read_places(&mut slow, &busy, &busy_gate);
    let params = json!({
        "path": repo,
        "scope": "uncommitted",
        "include_patch": true,
        "max_patch_bytes": 4_194_304,
    });
    for number in 0..EQUAL {
        slow.send(&format!("e{number}"), "git.diff", params.clone());
    }
    slow.ping(9);
    slow.reply(&json!(9));
    held_gate.hold("hold-all");
    busy_gate.release("hold-all");
    // The run of the equal reads ended: its first reply is here. From now
    // the connection reads nothing, and the copies wait.
    let first = slow.reply(&json!("e0"));
    assert_eq!(first["ok"], true, "the first of the equal reads: {first}");

    // The check that the repair decides: each long place is free. Its
    // bound is below the 2 s limit of one write, which closes the slow
    // connection and so ends the wait of its copies.
    let long_asked = Instant::now();
    for number in 0..LONG_GIT_RUNS {
        let params = json!({"path": held, "scope": "uncommitted", "context_lines": number + 1});
        other.send(&format!("long{number}"), "git.diff", params);
    }
    while held_gate.active() < LONG_GIT_RUNS && long_asked.elapsed() < Duration::from_secs(1) {
        std::thread::sleep(Duration::from_millis(2));
    }
    let long_reads = (held_gate.active(), long_asked.elapsed());
    assert_eq!(
        long_reads.0, LONG_GIT_RUNS,
        "long reads of another connection that run while the copies wait"
    );

    // The two times are records, not bounds.
    let other_asked = Instant::now();
    other.send("status", "git.status", json!({"path": seen}));
    let status = other.reply(&json!("status"));
    let other_status = other_asked.elapsed();
    assert_eq!(status["ok"], true, "the git.status of another connection: {status}");
    let own_asked = Instant::now();
    slow.send("own-status", "git.status", json!({"path": own}));
    wait_for("the git.status of the slow connection in git", || own_gate.runs_of("status") > 0);
    let own_status = own_asked.elapsed();
    // The last git child of a `git.status` asks for the common directory.
    // After it the reply goes to the queue, while copies still wait there.
    wait_for("the end of the git.status of the slow connection", || {
        own_gate.runs_of("--git-common-dir") > 0 && own_gate.active() == 0
    });
    let own_ended = own_asked.elapsed();

    // Now the connection reads. It is open, so the copies waited until
    // here: the checks above were while they waited.
    let (replies, closed) = slow.replies(fill.len() + EQUAL, LONG);
    let is_copy = |reply: &Value| reply["id"].as_str().is_some_and(|id| id.starts_with('e'));
    let copies = replies.iter().filter(|reply| is_copy(reply) && reply["ok"] == true).count();
    let own_at = replies.iter().position(|reply| reply["id"] == "own-status");
    let copies_after_own =
        own_at.map_or(0, |at| replies[at..].iter().filter(|reply| is_copy(reply)).count());
    eprintln!(
        "git-lane: {} copies of a shared reply wait for a connection that does not read: {} long \
         reads of another connection ran in {:?}; a git.status of another connection answered \
         in {other_status:?}; a git.status of the same connection started in {own_status:?}, its \
         git ended in {own_ended:?} and its answer came {copies_after_own} copies before the \
         last; then the connection read {copies} copies, closed by the daemon: {closed}",
        EQUAL - 1,
        long_reads.0,
        long_reads.1
    );
    held_gate.release("hold-all");
    assert!(!closed, "the daemon closed the connection before it read again");
    assert_eq!(copies, EQUAL - 1, "copies that came after the connection read again");
    assert!(
        own_at.is_some_and(|at| replies[at]["ok"] == true),
        "the git.status of the slow connection was answered"
    );
    assert!(
        copies_after_own > 0,
        "the git.status of the slow connection was answered while its copies waited"
    );
}

/// The daemon runs at most [`MUTATION_RUNS`] git mutations at one time,
/// whatever the count of connections. The result of a commit is not this
/// test's subject: only how many run.
#[test]
fn git_lane_three_commits_of_three_connections_run_at_most_the_bound_of_mutations() {
    let (socket, _mux) = persistent_daemon("commits");
    let repositories: Vec<(String, Gate)> = (0..3).map(|_| repository("commit")).collect();
    let mut connections: Vec<Connection> =
        repositories.iter().map(|_| Connection::open(&socket)).collect();
    let active = || repositories.iter().map(|(_, gate)| gate.active()).sum::<usize>();

    for (_, gate) in &repositories {
        gate.hold("hold-all");
    }
    for (number, (repo, _)) in repositories.iter().enumerate() {
        let params = json!({"path": repo, "message": "a commit", "all": true});
        connections[number].send(&format!("commit{number}"), "git.commit", params);
    }
    wait_for("each mutation place held", || active() >= MUTATION_RUNS);
    // The third commit waits in the daemon, not in git: no more children come.
    let watch = Instant::now() + Duration::from_millis(1500);
    let mut most = active();
    while Instant::now() < watch {
        most = most.max(active());
        std::thread::sleep(Duration::from_millis(10));
    }

    for (_, gate) in &repositories {
        gate.release("hold-all");
    }
    let answered = connections
        .iter_mut()
        .enumerate()
        .filter_map(|(number, connection)| {
            connection.reply_in(&json!(format!("commit{number}")), LONG)
        })
        .count();
    eprintln!(
        "git-lane: 3 git.commit of 3 connections: most git children while held: {most}; \
         answered: {answered}"
    );
    assert_eq!(most, MUTATION_RUNS, "git children of mutations at one time");
    assert_eq!(answered, 3, "each git.commit gets a reply");
}

/// A connection may have [`WAITING_RUNS`] git runs that wait. One more gets
/// an error that names the bound and does not run, and the connection stays open.
#[test]
fn git_lane_a_request_above_the_waiting_bound_of_its_connection_gets_an_error() {
    let (busy, busy_gate) = repository("busy");
    let (repo, gate) = repository("many");
    let mut app = Connection::open(&daemon());

    busy_gate.hold("hold-all");
    fill_the_read_places(&mut app, &busy, &busy_gate);
    // A different `context_lines` makes a different read, so each is a run of its own.
    let read =
        |number: usize| json!({"path": repo, "scope": "uncommitted", "context_lines": number});
    for number in 0..WAITING_RUNS {
        app.send(&format!("w{number}"), "git.diff", read(number));
    }
    app.send("over", "git.diff", read(WAITING_RUNS));
    let over = app.reply(&json!("over"));
    app.ping(9);
    let open = app.reply_in(&json!(9), Duration::from_secs(10)).is_some();
    let early = (0..WAITING_RUNS).filter(|number| app.answered(&format!("w{number}"))).count();
    let runs = gate.runs_of("diff");
    eprintln!(
        "git-lane: request {} of one connection while {WAITING_RUNS} wait: {}; the connection \
         answers a later ping: {open}; git diff runs of the waiting requests: {runs}",
        WAITING_RUNS + 1,
        over["error"]
    );
    // The connection breaks: the daemon drops its reads that wait, so the test ends.
    app.writer.write_all(b"\xff\n").unwrap();
    busy_gate.release("hold-all");

    assert_eq!(over["ok"], false, "the request above the bound was taken: {over}");
    assert_eq!(over["error"]["code"], "operation.failed", "{over}");
    let error = over["error"].to_string();
    assert!(error.contains("git_queue_capacity"), "the error does not name the bound: {over}");
    assert!(open, "the connection closed after the error");
    assert_eq!(early, 0, "waiting requests answered while each place was held");
    assert_eq!(runs, 0, "git diff runs of requests that waited");
}
