//! RFD 0135 gate 2, "Close the laptop": turn the switch on, close the lid for 30 minutes mid-task,
//! open it: the work continued and the chat shows it. 10 of 10, re-run nightly.
//!
//! On one Linux box with real processes (the machines of `cloud_move_journey.rs`): a "Mac"
//! headless daemon and a daemon shaped like a personal Cloud VM, each with its own acpmux running
//! the test agent. One run:
//!
//! 1. Switch on: the Mac's chat (a finished turn, a turn running, a task queued behind it) moves
//!    to the VM with the app's own pump (`cmux link agent move --interrupt --sync seed`), as
//!    "Keep running" does. The queued task is `work-for: W`, a turn that calls one tool a second
//!    for W seconds, each call stamped with the wall clock it ran at.
//! 2. Mid-task, the lid closes: once the task's first tick is on the VM, every process of the Mac
//!    (its `HOME`: daemon, acpmux, agents) gets SIGSTOP, as a sleeping Mac runs nothing, for
//!    `LID_CLOSE_SECS`.
//! 3. The lid opens: SIGCONT. Pass when, within 60 s of opening:
//!    - the Mac's daemon answers again;
//!    - the chat is open on the VM and not on the Mac (it did not run in two places);
//!    - the work continued: the ticks stamped inside the closed window cover it (no gap over
//!      5 s, at least 80 % of the window's seconds), and the task ran to its end ("worked W s");
//!    - the chat shows it: a fresh read of the chat, as the woken app makes, carries every tick
//!      and the task's result, once each.
//!
//! `LID_CLOSE_RUNS` runs go at once, each with its own pair of machines.
//!
//! Prints one line per run and a last line `GATE lid-close {json}` (`runs`, `passed`, `lid_s`,
//! and each run's covered seconds and longest gap); `LID_CLOSE_OUT` also writes it there. The
//! gate's number is `passed` of `runs`.
//!
//! ```text
//! # the nightly gate (10 runs, 30 min each):
//! LID_CLOSE_RUNS=10 LID_CLOSE_SECS=1800 cargo test -p cmux-tui --test lid_close_gate -- --ignored --nocapture
//! # a quick check (the defaults: 1 run, 20 s):
//! cargo test -p cmux-tui --test lid_close_gate -- --ignored --nocapture
//! ```
//!
//! What it does not cover: a real Mac's sleep (its network goes down with it; here the Mac's
//! processes stop and its sockets stay), and a real Cloud VM's own idle policy (a machine that
//! pauses when no client is attached); `scripts/cmux-next/rfd0135-gates.sh` names both.
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

const HISTORY: &str = "hello before the lid closes";
const TASK_ID: &str = "p-lid-close-task";
const TITLE: &str = "/params/update/title";

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
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

/// `pid command state wchan` of each of the machine's processes, sorted, for the lid's log.
fn vm_processes(home: &Path) -> String {
    let mut rows: Vec<String> = machine_pids(home)
        .into_iter()
        .map(|pid| {
            let read = |f: &str| fs::read_to_string(format!("/proc/{pid}/{f}")).unwrap_or_default();
            let cmd = read("cmdline").replace('\0', " ");
            let cmd: String = cmd.split_whitespace().take(3).collect::<Vec<_>>().join(" ");
            let state = read("stat")
                .rsplit(')')
                .next()
                .unwrap_or("")
                .split_whitespace()
                .next()
                .unwrap_or("?")
                .to_owned();
            format!("{pid} [{cmd}] {state} {}", read("wchan"))
        })
        .collect();
    rows.sort();
    format!("{} processes: {}", rows.len(), rows.join("; "))
}

/// The last `lines` lines of each log under `dir` (two levels down).
fn log_tails(dir: &Path, lines: usize) -> String {
    let mut out = String::new();
    let mut files = Vec::new();
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            files.extend(fs::read_dir(&path).into_iter().flatten().flatten().map(|e| e.path()));
        } else {
            files.push(path);
        }
    }
    files.sort();
    for file in files.iter().filter(|f| f.extension().is_some_and(|e| e == "log")) {
        let text = fs::read_to_string(file).unwrap_or_default();
        let all: Vec<&str> = text.lines().collect();
        out.push_str(&format!("== {} ({} lines)\n", file.display(), all.len()));
        for line in &all[all.len().saturating_sub(lines)..] {
            out.push_str(&line.chars().take(400).collect::<String>());
            out.push('\n');
        }
    }
    out
}

fn signal(pids: &[libc::pid_t], sig: libc::c_int) {
    for &pid in pids {
        assert!(pid > 1, "refusing to signal pid {pid}");
        // SAFETY: a plain kill(2) on a pid this run's own Mac runs (found by its unique HOME); a
        // gone pid only answers ESRCH.
        unsafe {
            libc::kill(pid, sig);
        }
    }
}

/// SIGCONT on drop, so a failed run never leaves the Mac stopped for the next one.
struct Lid(Vec<libc::pid_t>);

impl Drop for Lid {
    fn drop(&mut self) {
        signal(&self.0, libc::SIGCONT);
    }
}

fn dirty_repo(at: &Path, github: &Path) -> PathBuf {
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
    fs::write(repo.join("src/lib.txt"), "committed\nuncommitted change\n").unwrap();
    repo
}

/// The tick times (unix ms) of the task's tool calls, one per tick (a tick's `tool_call`).
fn ticks(events: &[Value]) -> Vec<u64> {
    let mut seen = Vec::new();
    for e in events {
        let update = &e["msg"]["params"]["update"];
        if update["sessionUpdate"] != json!("tool_call") {
            continue;
        }
        let Some(title) = e["msg"].pointer(TITLE).and_then(Value::as_str) else { continue };
        if let Some(at) = title.strip_prefix("tick ").and_then(|t| t.split(" at ").nth(1)) {
            if let Ok(at) = at.parse::<u64>() {
                seen.push(at);
            }
        }
    }
    seen
}

fn open_on(acpmux: &mut Acpmux, session: &str) -> bool {
    acpmux.summary(session).is_some_and(|s| s["status"] != json!("closed"))
}

fn task_done(events: &[Value]) -> bool {
    events.iter().any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == TASK_ID)
}

struct Run {
    pass: bool,
    covered_s: u64,
    longest_gap_ms: u64,
    why: Vec<String>,
}

fn run_once(n: u64, lid_s: u64) -> Run {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("lid-{}-{n}-{stamp}", std::process::id()));
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
            ("CMUX_VM_ID", "vm-lid-close-gate".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let repo = dirty_repo(&mac.home(), &github);
    let synced = vm.home().join("work/app");

    // The chat: history, a running turn, and the task queued behind it.
    let task_s = lid_s + 10;
    let mut mac_acpmux = mac.acpmux();
    let created = mac_acpmux.call("session/new", json!({"cwd": repo, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    mac_acpmux.call("session/prompt", prompt(&session, HISTORY, "p-lid-history"));
    mac_acpmux.send("session/prompt", prompt(&session, "until-cancel", "p-lid-running"));
    wait_until(20, "the running turn", || {
        mac_acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    mac_acpmux.send("session/prompt", prompt(&session, &format!("work-for: {task_s}"), TASK_ID));
    wait_until(20, "the queued task", || {
        mac_acpmux.summary(&session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
    });
    let surface = bound_agent_tab(&mac, &session);

    // 1. Switch on: the chat goes to its Cloud machine with its folder.
    let (ok, seeded) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "seed", "push", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && seeded["ok"] == json!(true), "seed push: {seeded}");
    let (ok, moved) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&vm.socket)
            .arg("--cwd")
            .arg(&synced)
            .arg("--interrupt")
            .args(["--vm-kind", "owner"])
            .args(["--sync", "seed", "--sync-socket"])
            .arg(&vm.socket)
            .arg("--sync-local")
            .arg(&repo)
            .arg("--sync-remote")
            .arg(&synced)
            .arg("--state-dir")
            .arg(root.join("pump")),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved}");

    // 2. Mid-task: the task's first tick is on the VM, then the lid closes.
    let mut vm_acpmux = vm.acpmux();
    wait_until(30, "the task's first tick on the VM", || {
        (!ticks(&vm_acpmux.events(&session)).is_empty()).then_some(())
    });
    drop(vm_acpmux);
    drop(mac_acpmux);
    let pids = machine_pids(&mac.home());
    assert!(!pids.is_empty(), "no Mac process to stop");
    // LID_CLOSE_NO_STOP=1: the same run with the lid left open (a control for a failing gate).
    let stop = std::env::var("LID_CLOSE_NO_STOP").as_deref() != Ok("1");
    let closed_at = now_ms();
    if stop {
        signal(&pids, libc::SIGSTOP);
    }
    let lid = Lid(pids);
    // While it is closed, the VM's processes every 30 s: a line each time one starts, ends or
    // changes what it waits on, so a run whose work stops says which process stopped and how.
    let mut seen = String::new();
    while now_ms() < closed_at + lid_s * 1000 {
        let now = vm_processes(&vm.home());
        if now != seen {
            eprintln!(
                "lid-close run {n}: at {} s the VM runs {now}",
                (now_ms() - closed_at) / 1000
            );
            seen = now;
        }
        std::thread::sleep(Duration::from_millis(
            (closed_at + lid_s * 1000).saturating_sub(now_ms()).min(30_000),
        ));
    }
    let opened_at = now_ms();
    drop(lid);

    // 3. Open: the Mac answers, the chat shows the work done while it slept.
    let mut why = Vec::new();
    let woke = Instant::now();
    let mut answered = false;
    while woke.elapsed() < Duration::from_secs(60) {
        if mac.rpc(json!({"id": 9, "cmd": "identify"}))["ok"] == json!(true) {
            answered = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    if !answered {
        why.push("the Mac's daemon did not answer within 60 s of opening".to_owned());
    }
    let mut vm_view = vm.acpmux();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut events = vm_view.events(&session);
    while !task_done(&events) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(250));
        events = vm_view.events(&session);
    }
    if !task_done(&events) {
        why.push("the task did not finish on the VM".to_owned());
    }
    let worked = format!("worked {task_s} s");
    let said =
        events.iter().filter(|e| e["msg"].pointer(AGENT_TEXT) == Some(&json!(worked))).count();
    if said != 1 {
        why.push(format!("the task's result shows {said} times, not once"));
    }
    let mut mac_view = mac.acpmux();
    if open_on(&mut mac_view, &session) {
        why.push("the chat is open on the Mac too".to_owned());
    }
    if !open_on(&mut vm_view, &session) {
        why.push("the chat is not open on the VM".to_owned());
    }
    let all = ticks(&events);
    let mut dedup = all.clone();
    dedup.dedup();
    if dedup.len() != all.len() {
        why.push(format!("{} ticks show twice", all.len() - dedup.len()));
    }
    // The work through the closed window: every gap between ticks (and the window's edges).
    let mut edges = vec![closed_at];
    edges.extend(all.iter().copied().filter(|t| *t > closed_at && *t < opened_at));
    edges.push(opened_at);
    let longest_gap_ms = edges.windows(2).map(|w| w[1] - w[0]).max().unwrap_or(0);
    let covered_s = (edges.len() - 2) as u64;
    if longest_gap_ms > 5_000 {
        why.push(format!("the work stopped for {} ms while the lid was closed", longest_gap_ms));
    }
    if covered_s * 10 < lid_s * 8 {
        why.push(format!("{covered_s} ticks in a {lid_s} s window"));
    }
    let pass = why.is_empty();
    if !pass {
        eprintln!("lid-close run {n}: the VM's logs:\n{}", log_tails(&vm.dir.join("acpmux"), 40));
    }
    eprintln!(
        "lid-close run {n}: {} covered {covered_s}/{lid_s} s, longest gap {longest_gap_ms} ms{}",
        if pass { "PASS" } else { "FAIL" },
        if why.is_empty() { String::new() } else { format!(": {}", why.join("; ")) }
    );
    Run { pass, covered_s, longest_gap_ms, why }
}

#[test]
#[ignore = "RFD 0135 gate 2: minutes to hours of wall clock; run by scripts/cmux-next/rfd0135-gates.sh"]
fn lid_close_gate() {
    let runs = env_u64("LID_CLOSE_RUNS", 1).max(1);
    let lid_s = env_u64("LID_CLOSE_SECS", 20).max(5);
    // The runs share no process, folder or socket, so they close their lids at once: ten 30-minute
    // windows take one window of wall clock. A run whose setup panicked is a failed run.
    let results: Vec<Run> = std::thread::scope(|scope| {
        let handles: Vec<_> = (1..=runs)
            .map(|n| {
                scope.spawn(move || {
                    // Spread the starts so ten pairs of daemons do not boot in the same second.
                    std::thread::sleep(Duration::from_millis(500 * (n - 1)));
                    run_once(n, lid_s)
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| {
                h.join().unwrap_or_else(|panic| {
                    let why = panic
                        .downcast_ref::<String>()
                        .cloned()
                        .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                        .unwrap_or_else(|| "panicked".to_owned());
                    eprintln!("lid-close run: FAIL before the lid closed: {why}");
                    Run { pass: false, covered_s: 0, longest_gap_ms: 0, why: vec![why] }
                })
            })
            .collect()
    });
    let passed = results.iter().filter(|r| r.pass).count();
    let line = json!({
        "gate": "lid-close",
        "runs": runs,
        "passed": passed,
        "lid_s": lid_s,
        "each": results.iter().map(|r| json!({
            "pass": r.pass, "covered_s": r.covered_s, "longest_gap_ms": r.longest_gap_ms, "why": r.why,
        })).collect::<Vec<_>>(),
    });
    println!("GATE lid-close {line}");
    if let Ok(out) = std::env::var("LID_CLOSE_OUT") {
        fs::write(out, format!("{line}\n")).unwrap();
    }
    assert_eq!(passed as u64, runs, "lid-close: {passed} of {runs} runs passed");
}
