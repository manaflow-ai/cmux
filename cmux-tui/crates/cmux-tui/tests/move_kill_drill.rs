//! Kill-mid-move drills: a Move to Cloud whose one side dies in the middle of a step, on one Linux
//! box with real processes (the machines of `cloud_move_journey.rs`: a "Mac" headless daemon and a
//! daemon shaped like a personal Cloud VM, each with its own acpmux running the test agent).
//!
//! Each case moves a chat with a finished turn, a turn running, a prompt queued behind it, a
//! composer draft, an uncommitted edit, an untracked file, an unpushed commit and a file written
//! into the folder while the turn runs, after the folder's seed (the test writes it: the test agent
//! has no turn that writes files), with the app's own pump (`cmux link agent move
//! --interrupt --sync seed`). Both daemon sockets the pump uses go through a [`Tap`], which
//! injects the case's fault when the pump reaches its step:
//!
//! | step | when the fault lands |
//! |---|---|
//! | `before-begin` | the source's `agent-transfer-begin` is about to be sent |
//! | `after-begin` | the begin was answered (the chat is frozen), before the client reads it |
//! | `frozen-sync` | the first request to the target once frozen (the frozen `--sync seed`) |
//! | `after-receive` | the target answered `agent-transfer-receive` |
//! | `mid-copy` | the first bundle page was read from the source, before it is written |
//! | `before-finish` | the target's `agent-transfer-finish` is about to be sent |
//! | `after-finish` | the target landed the chat, before the client reads the answer |
//! | `after-commit` | the source committed, before the client reads the answer |
//!
//! | kill | what it does |
//! |---|---|
//! | `kill-src`, `kill-dst` | SIGKILL of that machine's cmux-tui daemon and its acpmux daemon |
//! | `off-src`, `off-dst` | SIGKILL of every process of that machine (its `HOME`); the Mac is the source, so `off-src` also kills the pump, as a Mac powering off kills the app |
//! | `cut` | the pump's link to the Cloud machine drops and refuses every connection |
//! | `pause-src`, `pause-dst` | SIGSTOP of every process of that machine for a seeded 3 to 60 s, then SIGCONT |
//!
//! Power-off here keeps what the machine wrote to its files (no page cache is lost); the real-VM
//! leg (`scripts/cmux-next/cloud-chaos.ts` move leg) powers off real Cloud VMs.
//!
//! After the fault: what died is started again, the cut link comes back, and the move is run once
//! more as the app's Retry does (same pump state folder). Then the case reads both machines and
//! names what was lost: the chat open in two places or none, a chat left frozen on the source, a
//! queued prompt not run or run twice, history or draft missing, the source journal's records
//! missing where the chat runs, and where the uncommitted edit, the untracked file, the mid-turn
//! file and the unpushed commit can be found (where the chat runs, the Mac's folder, or
//! nowhere). It prints its seed and fault trace.
//!
//! A chat still frozen on the Mac once the settle ends gets one more settle, past the source's
//! lease (the pump's `retry_after_seconds`, else 300 s: no env var or config shortens a daemon's
//! lease), and the table says "frozen for N s, then recovered" or "stranded for good". A pump
//! answer that is not so (the chat moved, the person is told it did not, or the other way round)
//! is a wrong answer, in its own column: not a loss of data, still a finding. The matrix fails on
//! a finding [`KNOWN`] does not list with its case and why, so it passes on base and fails on a
//! new loss or a regression.
//!
//! ```text
//! # the whole matrix (8 steps x 7 kills), a table on stderr:
//! cargo test -p cmux-tui --test move_kill_drill -- --ignored --nocapture --test-threads 1 move_kill_drill_matrix
//! # some cells:  MOVE_KILL_CASES=after-finish:off-dst,before-begin:cut
//! # N random seeded cases (CMUX_FAULT_SEED, else the clock):  MOVE_KILL_RANDOM=20
//! ```
#![cfg(target_os = "linux")]

mod journey_support;

use std::collections::BTreeSet;
use std::fs;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_fault::{Rng, Trace};
use journey_support::*;
use serde_json::{Value, json};

const HISTORY: &str = "hello from the mac";
const QUEUED: &str = "queued for the cloud";
const QUEUED_ID: &str = "p-drill-queued";
const DRAFT: &str = "an unsent thought";
const UNCOMMITTED: &str = "committed\nuncommitted change\n";
/// Written into the Mac's folder by the test while the turn runs, after the seed push.
const MID_TURN_FILE: &str = "written while the turn ran\n";

const STEPS: &[&str] = &[
    "before-begin",
    "after-begin",
    "frozen-sync",
    "after-receive",
    "mid-copy",
    "before-finish",
    "after-finish",
    "after-commit",
];
const KILLS: &[&str] =
    &["kill-src", "kill-dst", "off-src", "off-dst", "cut", "pause-src", "pause-dst"];

/// The longest one pump run may take before the case calls it hung and stops it (its own
/// longest call bound is 90 s, `agent_cli/daemon.rs` FINISH_TIMEOUT).
const PUMP_BOUND: Duration = Duration::from_secs(150);
/// How long the chat has, once the Retry ended, to settle (its queue run where it landed).
const SETTLE: Duration = Duration::from_secs(45);
/// The source's own lease on a move nobody reads (`acpmux` `hub/transfer_watch.rs`
/// TRANSFER_LEASE), when the pump's answer names no `retry_after_seconds`. Only an in-process
/// hub can shorten it (`Hub::set_transfer_lease`); no env var or config reaches a daemon, so a
/// stranded case waits the real lease.
const SOURCE_LEASE: Duration = Duration::from_secs(300);
/// Past the lease, how long a stranded chat has to come back and run its queue.
const PAST_LEASE: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Side {
    Src,
    Dst,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum When {
    /// Before the request goes on.
    Before,
    /// After its answer came back, before the client reads it.
    After,
}

/// Where a case's fault lands.
#[derive(Clone, Copy, Debug)]
enum Trigger {
    /// The `nth` (1-based) request of `cmd` on `side`'s tap.
    Cmd { side: Side, cmd: &'static str, nth: usize, when: When },
    /// The first request on the target's tap once the begin was answered.
    FirstDstAfterBegin,
}

fn trigger(step: &str) -> Trigger {
    use When::*;
    let cmd = |side, cmd, when| Trigger::Cmd { side, cmd, nth: 1, when };
    match step {
        "before-begin" => cmd(Side::Src, "agent-transfer-begin", Before),
        "after-begin" => cmd(Side::Src, "agent-transfer-begin", After),
        "frozen-sync" => Trigger::FirstDstAfterBegin,
        "after-receive" => cmd(Side::Dst, "agent-transfer-receive", After),
        "mid-copy" => cmd(Side::Dst, "agent-transfer-write", Before),
        "before-finish" => cmd(Side::Dst, "agent-transfer-finish", Before),
        "after-finish" => cmd(Side::Dst, "agent-transfer-finish", After),
        "after-commit" => cmd(Side::Src, "agent-transfer-commit", After),
        other => panic!("unknown step {other}"),
    }
}

/// What every tap of one case shares: the trigger, whether it fired, and the fault to run.
struct Shared {
    trigger: Trigger,
    fired: AtomicBool,
    /// When the fault fired: the start of a stranded chat's freeze.
    fired_at: Mutex<Option<Instant>>,
    begin_answered: AtomicBool,
    counts: Mutex<std::collections::HashMap<(u8, String), usize>>,
    fault: Box<dyn Fn() + Send + Sync>,
    trace: Trace,
}

impl Shared {
    fn fire(&self, why: &str) {
        if !self.fired.swap(true, Ordering::SeqCst) {
            *self.fired_at.lock().unwrap() = Some(Instant::now());
            self.trace.note(format!("fault fires: {why}"));
            (self.fault)();
        }
    }

    /// Counts a request of `cmd` on `side`; whether it is the trigger's, with its `When`.
    fn request(&self, side: Side, cmd: Option<&str>) -> Option<When> {
        if self.fired.load(Ordering::SeqCst) {
            return None;
        }
        match self.trigger {
            Trigger::FirstDstAfterBegin => (side == Side::Dst
                && self.begin_answered.load(Ordering::SeqCst))
            .then_some(When::Before),
            Trigger::Cmd { side: s, cmd: c, nth, when } => {
                let cmd = cmd?;
                let mut counts = self.counts.lock().unwrap();
                let n = counts.entry((side as u8, cmd.to_owned())).or_default();
                *n += 1;
                (s == side && c == cmd && *n == nth).then_some(when)
            }
        }
    }
}

/// A unix-socket tap in front of one daemon socket: it passes bytes both ways and reads the
/// client's request lines for their `cmd`, so a case's fault lands at an exact step. While cut,
/// every connection through it is dropped and new ones are refused.
struct Tap {
    path: PathBuf,
}

fn request_cmd(line: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(line).ok()?;
    let value: Value = serde_json::from_str(text.trim()).ok()?;
    value.get("cmd").and_then(Value::as_str).map(str::to_owned)
}

/// A tap's cut switch and its open connections; the cut and a new connection's registration
/// take the same lock, so no connection slips in beside a cut.
#[derive(Clone, Default)]
struct Link {
    cut: Arc<AtomicBool>,
    open: Arc<Mutex<Vec<UnixStream>>>,
}

impl Link {
    /// Cuts (drops every open connection; new ones are refused) or restores the link, at once.
    fn set_cut(&self, cut: bool) {
        let mut open = self.open.lock().unwrap();
        self.cut.store(cut, Ordering::SeqCst);
        if cut {
            for stream in open.drain(..) {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        }
    }
}

impl Tap {
    fn start(
        path: PathBuf,
        upstream: PathBuf,
        side: Side,
        shared: Arc<Shared>,
        link: Link,
    ) -> Self {
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let Link { cut: cut2, open: open2 } = link;
        std::thread::spawn(move || {
            for client in listener.incoming() {
                let Ok(client) = client else { continue };
                if cut2.load(Ordering::SeqCst) {
                    let _ = client.shutdown(std::net::Shutdown::Both);
                    continue;
                }
                let Ok(server) = UnixStream::connect(&upstream) else {
                    let _ = client.shutdown(std::net::Shutdown::Both);
                    continue;
                };
                {
                    let mut open = open2.lock().unwrap();
                    if cut2.load(Ordering::SeqCst) {
                        let _ = client.shutdown(std::net::Shutdown::Both);
                        let _ = server.shutdown(std::net::Shutdown::Both);
                        continue;
                    }
                    open.push(client.try_clone().unwrap());
                    open.push(server.try_clone().unwrap());
                }
                let pending = Arc::new(AtomicBool::new(false));
                let saw_begin = Arc::new(AtomicBool::new(false));
                // Client to server: request lines, each checked against the trigger first.
                {
                    let (shared, cut, pending, saw_begin) =
                        (shared.clone(), cut2.clone(), pending.clone(), saw_begin.clone());
                    let mut reader = BufReader::new(client.try_clone().unwrap());
                    let mut server = server.try_clone().unwrap();
                    std::thread::spawn(move || {
                        let mut line = Vec::new();
                        loop {
                            line.clear();
                            match reader.read_until(b'\n', &mut line) {
                                Ok(0) | Err(_) => break,
                                Ok(_) => {}
                            }
                            let cmd = request_cmd(&line);
                            if cmd.as_deref() == Some("agent-transfer-begin") {
                                saw_begin.store(true, Ordering::SeqCst);
                            }
                            // A `Before` fault runs here, before the line goes on: a cut fault
                            // cuts in this call, so the request below is not forwarded.
                            match shared.request(side, cmd.as_deref()) {
                                Some(When::Before) => shared.fire(&format!(
                                    "before {side:?} {}",
                                    cmd.as_deref().unwrap_or("request")
                                )),
                                Some(When::After) => pending.store(true, Ordering::SeqCst),
                                None => {}
                            }
                            if cut.load(Ordering::SeqCst) || server.write_all(&line).is_err() {
                                break;
                            }
                        }
                        let _ = server.shutdown(std::net::Shutdown::Write);
                    });
                }
                // Server to client: answers; the first answer after a pending request fires.
                {
                    let (shared, cut) = (shared.clone(), cut2.clone());
                    let mut reader = BufReader::new(server);
                    let mut client = client;
                    std::thread::spawn(move || {
                        let mut line = Vec::new();
                        loop {
                            line.clear();
                            match reader.read_until(b'\n', &mut line) {
                                Ok(0) | Err(_) => break,
                                Ok(_) => {}
                            }
                            let answer = serde_json::from_slice::<Value>(&line)
                                .ok()
                                .filter(|v| v.get("event").is_none() && v.get("ok").is_some());
                            if answer.is_some() {
                                if saw_begin.swap(false, Ordering::SeqCst) {
                                    shared.begin_answered.store(true, Ordering::SeqCst);
                                }
                                // An `After` fault runs before the answer goes back: a cut
                                // fault cuts in this call, so the client never reads it.
                                if pending.swap(false, Ordering::SeqCst) {
                                    shared.fire(&format!("after {side:?} answer"));
                                }
                            }
                            if cut.load(Ordering::SeqCst) || client.write_all(&line).is_err() {
                                break;
                            }
                        }
                        let _ = client.shutdown(std::net::Shutdown::Both);
                    });
                }
            }
        });
        Self { path }
    }
}

/// Every process of `machine`: those whose `HOME` is its home (its daemon, acpmux and agents).
fn machine_pids(home: &Path) -> Vec<libc::pid_t> {
    let needle = format!("HOME={}", home.display());
    let mut pids = Vec::new();
    let Ok(dir) = fs::read_dir("/proc") else { return pids };
    for entry in dir.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|s| s.parse::<libc::pid_t>().ok())
        else {
            continue;
        };
        let Ok(environ) = fs::read(entry.path().join("environ")) else { continue };
        if environ.split(|b| *b == 0).any(|var| var == needle.as_bytes()) {
            pids.push(pid);
        }
    }
    pids
}

/// The machine's cmux-tui daemon pid (`identify`) and its acpmux daemon pid (`daemon.pid`).
fn daemon_pids(machine: &Machine) -> Vec<libc::pid_t> {
    let identity = machine.rpc(json!({"id": 1, "cmd": "identify"}));
    let mut pids = Vec::new();
    if let Some(pid) = identity["data"]["pid"].as_i64() {
        pids.push(pid as libc::pid_t);
    }
    if let Some(pid) = fs::read_to_string(machine.dir.join("acpmux/daemon.pid"))
        .ok()
        .and_then(|s| s.trim().parse::<libc::pid_t>().ok())
    {
        pids.push(pid);
    }
    pids
}

fn signal(pids: &[libc::pid_t], sig: libc::c_int) {
    for &pid in pids {
        assert!(pid > 1, "refusing to signal pid {pid}");
        // SAFETY: a plain kill(2) on a pid this case's own machines run (read from their files
        // or their unique HOME); a gone pid only answers ESRCH.
        unsafe {
            libc::kill(pid, sig);
        }
    }
}

/// Starts what of `machine` is not running again, as its supervisor or a restarted machine does.
fn revive(machine: &Machine) {
    let ensure = machine.server("ensure").output().unwrap();
    assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
    let started = machine.command().args(["acp", "daemon", "start"]).output().unwrap();
    assert!(started.status.success(), "acp: {}", String::from_utf8_lossy(&started.stderr));
}

/// A working copy with a commit pushed to its GitHub remote, a commit not pushed, an uncommitted
/// change and an untracked file. Answers the folder and the unpushed commit.
fn dirty_repo(at: &Path, github: &Path) -> (PathBuf, String) {
    let repo = at.join("app");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let bare = github.join("acme/app.git");
    fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare"]);
    git(&bare, &["config", "uploadpack.allowFilter", "true"]);
    git(&repo, &["remote", "add", "origin", "https://github.com/acme/app.git"]);
    let local = format!("url.file://{}/.insteadOf", github.display());
    git(&repo, &["config", &local, "https://github.com/"]);
    git(&repo, &["-c", "protocol.file.allow=always", "push", "-q", "-u", "origin", "main"]);
    fs::write(repo.join("src/unpushed.txt"), "only on the mac\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "not pushed"]);
    let unpushed = git(&repo, &["rev-parse", "HEAD"]).trim().to_owned();
    fs::write(repo.join("src/lib.txt"), UNCOMMITTED).unwrap();
    fs::write(repo.join("notes.txt"), "untracked\n").unwrap();
    (repo, unpushed)
}

fn chat_with_history_draft_and_queue(acpmux: &mut Acpmux, cwd: &Path) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, HISTORY, "p-drill-history"));
    acpmux.send("session/prompt", prompt(&session, "until-cancel", "p-drill-running"));
    wait_until(20, "the running turn", || {
        acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    acpmux.send("session/prompt", prompt(&session, QUEUED, QUEUED_ID));
    wait_until(20, "the queued prompt", || {
        acpmux.summary(&session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
    });
    acpmux.call("_acpmux/draft_set", json!({"sessionId": session, "text": DRAFT}));
    session
}

/// A pump run: its JSON line (or why there is none) and how long it took.
struct PumpRun {
    answer: Value,
    ms: u128,
}

fn pump(
    mac: &Machine,
    from: &Path,
    to: &Path,
    surface: u64,
    repo: &Path,
    synced: &Path,
    state: &Path,
) -> Command {
    let mut command = Command::new(bin());
    command
        .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["link", "agent", "move", "--from-socket"])
        .arg(from)
        .args(["--surface", &surface.to_string(), "--to-socket"])
        .arg(to)
        .arg("--cwd")
        .arg(synced)
        .arg("--interrupt")
        .args(["--vm-kind", "owner"])
        .args(["--sync", "seed", "--sync-socket"])
        .arg(to)
        .arg("--sync-local")
        .arg(repo)
        .arg("--sync-remote")
        .arg(synced)
        .arg("--state-dir")
        .arg(state)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// Waits for the pump with [`PUMP_BOUND`]; a pump past it is stopped and called hung.
fn finish_pump(mut child: Child, started: Instant) -> PumpRun {
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() > PUMP_BOUND => {
                let _ = child.kill();
                let _ = child.wait();
                return PumpRun {
                    answer: json!({"ok": false, "error_code": "drill.pump_hung"}),
                    ms: started.elapsed().as_millis(),
                };
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => break,
        }
    }
    let output = child.wait_with_output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or_else(|| {
            let how = match output.status.code() {
                Some(code) => format!("exit {code}"),
                None => "killed".to_owned(),
            };
            json!({"ok": false, "error_code": format!("drill.no_answer ({how})")})
        });
    PumpRun { answer, ms: started.elapsed().as_millis() }
}

/// One case's result: what was lost, and where the work can be found.
#[derive(Default)]
struct Outcome {
    lost: Vec<String>,
    /// What the pump's last answer told the person that is not so (the move went through but it
    /// says it did not, or the other way round): a finding, not a loss of data.
    wrong: Vec<String>,
    /// A chat still frozen on the Mac after [`SETTLE`]: whether it came back past the lease.
    frozen: String,
    found: Vec<String>,
    person: String,
}

/// Where the chat stands: open on the Mac, open on the Cloud machine, frozen in a move on the
/// Mac, and how many times its queued prompt ran (in the journal where it is open).
struct Stand {
    on_mac: bool,
    on_vm: bool,
    frozen: bool,
    ran: usize,
}

fn stand(mac: &mut Acpmux, vm: &mut Acpmux, session: &str) -> Stand {
    let on_mac = open_on(mac, session);
    let on_vm = open_on(vm, session);
    let mac_events = mac.events(session);
    let frozen = last_move_record(&mac_events).as_deref() == Some("transfer_out");
    // Where the chat is open, its journal holds every record: a landed chat's carries the
    // Mac's, so the two sides are never added.
    let ran = if on_vm {
        turn_results(&vm.events(session), QUEUED_ID)
    } else {
        turn_results(&mac_events, QUEUED_ID)
    };
    Stand { on_mac, on_vm, frozen, ran }
}

impl Stand {
    /// Open on one machine, not frozen there, its queue run.
    fn settled(&self) -> bool {
        self.on_mac ^ self.on_vm && !(self.on_mac && self.frozen) && self.ran >= 1
    }

    /// Open only on the Mac and frozen there in a move.
    fn stranded(&self) -> bool {
        self.on_mac && !self.on_vm && self.frozen
    }
}

/// Whether the chat is open on the machine this acpmux connection reaches: listed, and not closed.
fn open_on(acpmux: &mut Acpmux, session: &str) -> bool {
    acpmux.summary(session).is_some_and(|s| s["status"] != json!("closed"))
}

/// The last of the source log's own move records (`transfer_out`, `transfer_aborted`,
/// `transferred`): `transfer_out` last means the chat is still frozen in a move.
fn last_move_record(events: &[Value]) -> Option<String> {
    events
        .iter()
        .filter_map(|e| e["kind"].as_str())
        .filter(|k| matches!(*k, "transfer_out" | "transfer_aborted" | "transferred"))
        .last()
        .map(str::to_owned)
}

fn read_or_none(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok()
}

fn has_commit(dir: &Path, sha: &str) -> bool {
    Command::new("git")
        .args(["cat-file", "-e", &format!("{sha}^{{commit}}")])
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .is_ok_and(|s| s.success())
}

fn turn_results(events: &[Value], prompt_id: &str) -> usize {
    events
        .iter()
        .filter(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == prompt_id)
        .count()
}

/// Runs one case and answers what was lost.
fn run_case(step: &str, kill: &str, seed: u64) -> (Outcome, Trace) {
    let trace = Trace::new();
    let mut rng = Rng::new(seed);
    trace.note(format!("case {step} x {kill}, seed {seed}"));
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("mkd-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let github = root.join("github");
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-move-kill-drill".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );

    // The app's bulk copy before the move (the chat still runs): `cmux link seed push`.
    let (repo, unpushed) = dirty_repo(&mac.home(), &github);
    let synced = vm.home().join("work/app");
    let (ok, summary) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "seed", "push", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && summary["ok"] == json!(true), "seed push: {summary}");

    let mut mac_acpmux = mac.acpmux();
    let session = chat_with_history_draft_and_queue(&mut mac_acpmux, &repo);
    let surface = bound_agent_tab(&mac, &session);
    fs::write(repo.join("src/turn.txt"), MID_TURN_FILE).unwrap();
    let before: BTreeSet<(u64, String)> = mac_acpmux
        .events(&session)
        .iter()
        .filter_map(|e| Some((e["seq"].as_u64()?, e["kind"].as_str()?.to_owned())))
        .collect();
    drop(mac_acpmux);
    trace.note(format!("chat {session}: {} records before the move", before.len()));

    // The fault.
    let src_daemons = daemon_pids(&mac);
    let dst_daemons = daemon_pids(&vm);
    let pump_pid = Arc::new(AtomicI32::new(0));
    let pause_secs = rng.range(3, 60);
    let paused: Arc<Mutex<Option<std::thread::JoinHandle<()>>>> = Arc::default();
    // The link to the Cloud machine: the cut fault drops it from the tap thread that fires,
    // before that thread forwards the triggering request or answer.
    let dst_link = Link::default();
    let killed = Arc::new(AtomicUsize::new(0)); // bit 1: src, bit 2: dst
    let fault: Box<dyn Fn() + Send + Sync> = {
        let (mac_home, vm_home) = (mac.home(), vm.home());
        let pump_pid = pump_pid.clone();
        let paused = paused.clone();
        let dst_link = dst_link.clone();
        let killed = killed.clone();
        let trace = trace.clone();
        let kill = kill.to_owned();
        Box::new(move || {
            let probe = |side: Side| if side == Side::Src { &mac_home } else { &vm_home };
            match kill.as_str() {
                "kill-src" | "kill-dst" => {
                    let side = if kill == "kill-src" { Side::Src } else { Side::Dst };
                    let pids = if side == Side::Src { &src_daemons } else { &dst_daemons };
                    trace.note(format!("SIGKILL {side:?} daemons {pids:?}"));
                    signal(pids, libc::SIGKILL);
                    killed.fetch_or(if side == Side::Src { 1 } else { 2 }, Ordering::SeqCst);
                }
                "off-src" | "off-dst" => {
                    let side = if kill == "off-src" { Side::Src } else { Side::Dst };
                    let pids = machine_pids(probe(side));
                    trace.note(format!("power off {side:?}: SIGKILL {pids:?}"));
                    signal(&pids, libc::SIGKILL);
                    if side == Side::Src {
                        let pump = pump_pid.load(Ordering::SeqCst);
                        if pump > 1 {
                            trace.note(format!("power off the Mac: SIGKILL the pump {pump}"));
                            signal(&[pump], libc::SIGKILL);
                        }
                    }
                    killed.fetch_or(if side == Side::Src { 1 } else { 2 }, Ordering::SeqCst);
                }
                "cut" => {
                    trace.note("cut the link to the Cloud machine");
                    dst_link.set_cut(true);
                }
                "pause-src" | "pause-dst" => {
                    let side = if kill == "pause-src" { Side::Src } else { Side::Dst };
                    let pids = machine_pids(probe(side));
                    trace.note(format!("SIGSTOP {side:?} for {pause_secs} s: {pids:?}"));
                    signal(&pids, libc::SIGSTOP);
                    let trace = trace.clone();
                    // The fault's own length, not a synchronization: the machine stays stopped
                    // this long whatever the pump does meanwhile.
                    *paused.lock().unwrap() = Some(std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_secs(pause_secs));
                        trace.note(format!("SIGCONT {side:?}"));
                        signal(&pids, libc::SIGCONT);
                    }));
                }
                other => panic!("unknown kill {other}"),
            }
        })
    };
    let shared = Arc::new(Shared {
        trigger: trigger(step),
        fired: AtomicBool::new(false),
        fired_at: Mutex::default(),
        begin_answered: AtomicBool::new(false),
        counts: Mutex::default(),
        fault,
        trace: trace.clone(),
    });
    let src_tap = Tap::start(
        root.join("t-src.sock"),
        mac.socket.clone(),
        Side::Src,
        shared.clone(),
        Link::default(),
    );
    let dst_tap = Tap::start(
        root.join("t-dst.sock"),
        vm.socket.clone(),
        Side::Dst,
        shared.clone(),
        dst_link.clone(),
    );

    let state = root.join("pump");
    let started = Instant::now();
    let child =
        pump(&mac, &src_tap.path, &dst_tap.path, surface, &repo, &synced, &state).spawn().unwrap();
    pump_pid.store(child.id() as i32, Ordering::SeqCst);
    let first = finish_pump(child, started);
    trace.note(format!("pump: {} in {} ms", first.answer, first.ms));
    if !shared.fired.load(Ordering::SeqCst) {
        trace.note("the step was never reached: the fault did not fire");
    }

    // Recovery: what was stopped goes on, what died starts again, the link comes back.
    if let Some(handle) = paused.lock().unwrap().take() {
        let _ = handle.join();
    }
    dst_link.set_cut(false);
    let k = killed.load(Ordering::SeqCst);
    if k & 1 != 0 {
        revive(&mac);
        trace.note("the Mac's daemons started again");
    }
    if k & 2 != 0 {
        revive(&vm);
        trace.note("the Cloud machine's daemons started again");
    }

    // The app's Retry (the relaunched app finishes a pinned move): the same pump, same state,
    // same sockets. The move record is keyed by the `--from-socket` path and names the
    // `--to-socket` one, so a Retry on other paths could never resolve it. The taps stay: each
    // fires once, and they forward to the revived daemons' sockets.
    let mut retry = None;
    if first.answer["ok"] != json!(true) {
        let started = Instant::now();
        let child = pump(&mac, &src_tap.path, &dst_tap.path, surface, &repo, &synced, &state)
            .spawn()
            .unwrap();
        let run = finish_pump(child, started);
        trace.note(format!("retry: {} in {} ms", run.answer, run.ms));
        retry = Some(run);
    }

    // Settle: the chat's queue runs wherever it is open.
    let mut mac_acpmux = mac.acpmux();
    let mut vm_acpmux = vm.acpmux();
    let pumped = Instant::now();
    let deadline = pumped + SETTLE;
    let mut now = stand(&mut mac_acpmux, &mut vm_acpmux, &session);
    while !now.settled() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
        now = stand(&mut mac_acpmux, &mut vm_acpmux, &session);
    }
    // Still frozen on the Mac: one more settle, past the source's lease (the pump's
    // `retry_after_seconds`, else its default), so the table says whether the freeze ends.
    let mut frozen_note = String::new();
    if now.stranded() {
        let last = retry.as_ref().unwrap_or(&first);
        let lease = last.answer["retry_after_seconds"]
            .as_u64()
            .map(Duration::from_secs)
            .unwrap_or(SOURCE_LEASE);
        // The lease counts from the pump's last word to the source, at latest its end.
        let until = pumped + lease + PAST_LEASE;
        let secs = lease.as_secs();
        trace.note(format!("stranded after the settle: waiting past the {secs} s lease"));
        while !now.settled() && Instant::now() < until {
            std::thread::sleep(Duration::from_secs(1));
            now = stand(&mut mac_acpmux, &mut vm_acpmux, &session);
        }
        let since = shared.fired_at.lock().unwrap().unwrap_or(started);
        let secs = since.elapsed().as_secs();
        frozen_note = if now.frozen {
            format!("stranded for good (still frozen {secs} s after the fault)")
        } else {
            format!("frozen for {secs} s, then recovered")
        };
        trace.note(frozen_note.clone());
    }
    // A second look later: nothing runs it again.
    std::thread::sleep(Duration::from_secs(2));

    let mut out = Outcome { frozen: frozen_note, ..Outcome::default() };
    let on_mac = open_on(&mut mac_acpmux, &session);
    let on_vm = open_on(&mut vm_acpmux, &session);
    let mac_events = mac_acpmux.events(&session);
    let vm_events =
        if vm_acpmux.summary(&session).is_some() { vm_acpmux.events(&session) } else { Vec::new() };
    let frozen = last_move_record(&mac_events).as_deref() == Some("transfer_out");
    match (on_mac, on_vm) {
        (true, true) => out.lost.push("chat open on both machines".into()),
        (false, false) => out.lost.push("chat open nowhere".into()),
        (true, false) if frozen => out.lost.push("chat stranded: frozen on the Mac".into()),
        _ => {}
    }
    let (live_events, live, live_name) = if on_vm {
        (&vm_events, &mut vm_acpmux, "cloud")
    } else {
        (&mac_events, &mut mac_acpmux, "mac")
    };
    // The live journal holds every record of the chat (a landed one carries the Mac's), so a
    // prompt run on the Mac before a given-back move and carried over counts once.
    let ran = turn_results(live_events, QUEUED_ID);
    match ran {
        1 => {}
        0 => out.lost.push("queued prompt never ran".into()),
        n => out.lost.push(format!(
            "queued prompt ran {n} times (mac {}, cloud {})",
            turn_results(&mac_events, QUEUED_ID),
            turn_results(&vm_events, QUEUED_ID)
        )),
    }
    if count(live_events, "user_message", USER_TEXT, HISTORY) != 1 {
        out.lost.push(format!("history missing on the {live_name} side"));
    }
    let have: BTreeSet<(u64, String)> = live_events
        .iter()
        .filter_map(|e| Some((e["seq"].as_u64()?, e["kind"].as_str()?.to_owned())))
        .collect();
    let missing = before.difference(&have).count();
    if missing > 0 {
        out.lost.push(format!("{missing} journal records missing on the {live_name} side"));
    }
    if on_mac || on_vm {
        let draft = live.call("_acpmux/draft_get", json!({"sessionId": session}));
        if draft["draft"] != json!(DRAFT) {
            out.lost.push(format!("draft missing on the {live_name} side ({})", draft["draft"]));
        }
    }
    // The work: where the chat runs, else the Mac's folder, else nowhere.
    let live_dir = if on_vm { synced.clone() } else { repo.clone() };
    for (what, rel, want) in [
        ("uncommitted edit", "src/lib.txt", UNCOMMITTED),
        ("untracked file", "notes.txt", "untracked\n"),
        ("mid-turn file", "src/turn.txt", MID_TURN_FILE),
    ] {
        let at = if read_or_none(&live_dir.join(rel)).as_deref() == Some(want) {
            format!("with the chat ({live_name})")
        } else if read_or_none(&repo.join(rel)).as_deref() == Some(want) {
            out.lost.push(format!("{what} not with the chat (only in the Mac's folder)"));
            "Mac folder".to_owned()
        } else {
            out.lost.push(format!("{what} lost"));
            "nowhere".to_owned()
        };
        out.found.push(format!("{what}: {at}"));
    }
    let commit_at = if has_commit(&live_dir, &unpushed) {
        format!("with the chat ({live_name})")
    } else if has_commit(&repo, &unpushed) {
        out.lost.push("unpushed commit not with the chat (only in the Mac's repo)".into());
        "Mac repo".to_owned()
    } else {
        out.lost.push("unpushed commit lost".into());
        "nowhere".to_owned()
    };
    out.found.push(format!("unpushed commit: {commit_at}"));
    let said = |run: &PumpRun| {
        if run.answer["ok"] == json!(true) {
            format!("moved ({} ms)", run.ms)
        } else {
            format!("{} ({} ms)", run.answer["error_code"].as_str().unwrap_or("?"), run.ms)
        }
    };
    out.person = match &retry {
        None => format!("move: {}", said(&first)),
        Some(r) => format!("move: {}; Retry: {}", said(&first), said(r)),
    };
    // What the person was told last against where the chat is.
    let last = retry.as_ref().unwrap_or(&first);
    let told_moved = last.answer["ok"] == json!(true);
    let moved = on_vm && !on_mac;
    if moved && !told_moved {
        out.wrong.push(format!(
            "told {} but the chat moved",
            last.answer["error_code"].as_str().unwrap_or("a failure")
        ));
    } else if told_moved && !moved {
        out.wrong.push(format!(
            "told moved but the chat is {}",
            if on_mac { "on the Mac" } else { "open nowhere or on both" }
        ));
    }
    if !shared.fired.load(Ordering::SeqCst) {
        out.found.push("fault never fired (step not reached)".into());
    }
    trace.note(format!("chat open: mac {on_mac}, cloud {on_vm}; frozen {frozen}"));
    (out, trace)
}

fn cases() -> Vec<(String, String, u64)> {
    let base: u64 = std::env::var("CMUX_FAULT_SEED")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs());
    if let Ok(n) = std::env::var("MOVE_KILL_RANDOM") {
        let n: u64 = n.parse().expect("MOVE_KILL_RANDOM is a count");
        let mut rng = Rng::new(base);
        return (0..n)
            .map(|_| {
                let seed = rng.next_u64();
                let mut pick = Rng::new(seed);
                (pick.pick(STEPS).to_string(), pick.pick(KILLS).to_string(), seed)
            })
            .collect();
    }
    let wanted = std::env::var("MOVE_KILL_CASES").ok();
    let mut out = Vec::new();
    for (i, step) in STEPS.iter().enumerate() {
        for (j, kill) in KILLS.iter().enumerate() {
            let name = format!("{step}:{kill}");
            if wanted.as_deref().is_some_and(|w| !w.split(',').any(|c| c == name)) {
                continue;
            }
            out.push((step.to_string(), kill.to_string(), base ^ ((i * 16 + j) as u64)));
        }
    }
    out
}

/// What a case can find beyond its table row: a loss of the person's work or chat, or a wrong
/// answer to the person.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Finding {
    Loss,
    WrongAnswer,
}

/// The findings base is known to have, each with its case and why. The matrix passes with these
/// and fails on any other: a new loss, a new wrong answer, or a case that was clean losing
/// something. A known case that comes out clean is printed so its entry can go.
const KNOWN: &[(&str, Finding, &str)] = &[
    (
        "after-begin:off-src",
        Finding::Loss,
        "the Mac powers off right after the freeze: the Retry is refused as move_unresolved by the \
         move the dead pump began, and the chat stays frozen on the Mac until the source's lease",
    ),
    (
        "after-commit:off-src",
        Finding::WrongAnswer,
        "the Mac powers off after its commit, before the pump reads it: the chat is on the Cloud \
         machine, but the Retry's pump has no record of the commit and answers move_unresolved",
    ),
];

/// A table cell: the items joined, or `none`.
fn cell(items: &[String], none: &str) -> String {
    if items.is_empty() { none.to_owned() } else { items.join("; ") }
}

fn known(case: &str, finding: Finding) -> Option<&'static str> {
    KNOWN.iter().find(|(c, f, _)| *c == case && *f == finding).map(|(_, _, why)| *why)
}

/// The whole matrix (or `MOVE_KILL_CASES`, or `MOVE_KILL_RANDOM` seeded cases): a table row per
/// case on stderr, and a failure naming every case with a finding [`KNOWN`] does not list.
#[test]
#[ignore = "a drill: minutes per sweep; run with --ignored (the module doc)"]
fn move_kill_drill_matrix() {
    let mut rows = Vec::new();
    let mut failed = Vec::new();
    let mut known_seen = Vec::new();
    let mut clean = 0usize;
    for (step, kill, seed) in cases() {
        let case = format!("{step}:{kill}");
        // Machine processes left by a case that panicked are stopped by its Drop; one case's
        // panic is a finding, not the sweep's end.
        let result = std::panic::catch_unwind(|| run_case(&step, &kill, seed));
        let (out, trace) = match result {
            Ok((out, trace)) => (out, trace.to_string()),
            Err(panic) => {
                let why = panic
                    .downcast_ref::<String>()
                    .cloned()
                    .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                    .unwrap_or_default();
                (
                    Outcome { lost: vec![format!("drill error: {why}")], ..Outcome::default() },
                    String::new(),
                )
            }
        };
        let row = format!(
            "| local->cloud | {step} | {kill} | {seed} | {} | {} | {} | {} | {} |",
            cell(&out.lost, "nothing lost"),
            if out.frozen.is_empty() { "-" } else { out.frozen.as_str() },
            cell(&out.wrong, "-"),
            out.found.join("; "),
            out.person,
        );
        eprintln!("{row}");
        let mut new = Vec::new();
        for (finding, what) in [(Finding::Loss, &out.lost), (Finding::WrongAnswer, &out.wrong)] {
            if what.is_empty() {
                if known(&case, finding).is_some() {
                    eprintln!("  known {finding:?} of {case} did not happen: drop it from KNOWN");
                }
                continue;
            }
            match known(&case, finding) {
                Some(why) => known_seen.push(format!("{case} ({finding:?}): {why}")),
                None => new.push(format!("{finding:?}")),
            }
        }
        if !out.lost.is_empty() || !out.wrong.is_empty() {
            eprintln!("  seed {seed}, fault trace:\n{trace}");
            eprintln!(
                "  replay: CMUX_FAULT_SEED={seed} MOVE_KILL_CASES={case} cargo test -p cmux-tui --test move_kill_drill -- --ignored --nocapture"
            );
        }
        if !new.is_empty() {
            failed.push(format!("{case} (seed {seed}): {}", new.join(", ")));
        }
        rows.push(row);
        if out.lost.is_empty() && out.wrong.is_empty() {
            clean += 1;
        }
    }
    eprintln!(
        "\n| direction | step | kill | seed | lost | frozen past the settle | wrong answer to the person | where the work is | what the person sees |"
    );
    eprintln!("|---|---|---|---|---|---|---|---|---|");
    for row in &rows {
        eprintln!("{row}");
    }
    // One line a gate runner parses (RFD 0135 gate 3): cells, clean ones, cells with only
    // KNOWN findings, and cells with a finding KNOWN does not list.
    let summary = json!({
        "cells": rows.len(),
        "clean": clean,
        "known": rows.len() - clean - failed.len(),
        "new": failed.len(),
    });
    eprintln!("\nMOVE_KILL_MATRIX {summary}");
    if !known_seen.is_empty() {
        eprintln!("\nknown on base (KNOWN):");
        for k in &known_seen {
            eprintln!("  {k}");
        }
    }
    assert!(
        failed.is_empty(),
        "{} of {} cases have a finding KNOWN does not list: {}",
        failed.len(),
        rows.len(),
        failed.join(", ")
    );
}
