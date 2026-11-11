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
//! - equal reads that wait share one run;
//! - a mutation keeps its place in its connection's order;
//! - a git that passes its limit is ended, its request gets an error and its
//!   place is free again;
//! - a client that ends its writes still gets its replies.
//!
//! The git here is a stand-in on `PATH` that waits at a gate the test holds,
//! then runs the real git: a reply that arrives while the gate is held was
//! given while git ran. No sleep decides a result.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// The daemon's bound (`git_lane::MAX_READ_RUNS`): git reads that run at one time.
const GIT_RUNS: usize = 4;

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
        if operation == "diff.comments.save" {
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

    fn answered(&self, id: &str) -> bool {
        self.seen.iter().any(|reply| reply["id"] == json!(id))
    }
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
    for number in 0..50usize {
        // A different `limit` makes a different read, so no two share a run.
        let connection = &mut connections[number % 2];
        let params = json!({"path": repo, "limit": number + 1});
        connection.send(&format!("b{number}"), "git.branches", params);
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
    for number in 0..50usize {
        let reply = connections[number % 2].reply(&json!(format!("b{number}")));
        assert_eq!(reply["ok"], true, "git.branches {number} failed: {reply}");
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
    for number in 0..GIT_RUNS {
        app.send(
            &format!("busy{number}"),
            "git.branches",
            json!({"path": busy, "limit": number + 1}),
        );
    }
    wait_for("full git lane", || busy_gate.active() >= GIT_RUNS);
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
    for number in 0..GIT_RUNS {
        let reply = app.reply(&json!(format!("busy{number}")));
        assert_eq!(reply["ok"], true, "git.branches {number} failed: {reply}");
    }
    eprintln!(
        "git-lane: 5 equal git.status that waited: {} git status runs",
        gate.runs_of("status")
    );
    assert!(results.iter().all(|result| result == &results[0]), "{results:?}");
    assert_eq!(gate.runs_of("status"), 1, "git status runs for 5 equal reads that waited");
}

/// A mutation keeps its place in its connection's order: it starts after the
/// git requests before it ended, and the reads after it see what it wrote.
#[test]
fn git_lane_a_mutation_keeps_its_place_in_its_connections_order() {
    let (repo, gate) = repository("order");
    let dir = fixture().dir.join(unique("state"));
    let socket = fixture().dir.join(format!("{}.sock", unique("m")));
    let name = format!("git-lane-order-{}", std::process::id());
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &dir).unwrap();
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    std::mem::forget(mux);
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
    for number in 0..GIT_RUNS {
        first.send(
            &format!("x{number}"),
            "git.branches",
            json!({"path": stuck, "limit": number + 1}),
        );
    }
    wait_for("full git lane", || stuck_gate.active() >= GIT_RUNS);
    let asked = Instant::now();
    second.send("status", "git.status", json!({"path": repo}));

    for number in 0..GIT_RUNS {
        let reply = first.reply(&json!(format!("x{number}")));
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
