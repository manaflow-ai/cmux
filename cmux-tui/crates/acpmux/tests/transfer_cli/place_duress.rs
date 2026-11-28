//! Duress for "Cloud only" on an existing chat (`_acpmux/place_set` mode cloud, cmux#54560):
//! the source machine sleeps mid-turn, goes offline during the move, or dies (power, app killed)
//! during the move or while the move waits for the turn. Two real daemons, the stand-in ssh of
//! `session_move.rs` (extended so the target's git steps run here), a stand-in `cmux` for the
//! Cloud steps. Sleep is SIGSTOP of the source daemon and its agent; offline is a `cmux move`
//! that fails as a dropped network does; death is SIGKILL of the source's process tree and a
//! restart on the same home. Each scenario prints `DURESS <name> <key>=<value>` lines.
use super::session_move::prompt;
use super::*;
use std::collections::BTreeMap;
use std::process::Command;
use std::time::Instant;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git");
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// The chat's folder: a clone of a local bare origin on branch `work`, with three uncommitted
/// changes (one tracked edit, two untracked files).
fn repo(scratch: &Path, cwd: &Path) {
    let origin = scratch.join("origin.git");
    git(scratch, &["init", "--bare", origin.to_str().unwrap()]);
    git(scratch, &["clone", origin.to_str().unwrap(), cwd.to_str().unwrap()]);
    // origin reads as a GitHub repository (as a person's does: `remote get-url` applies
    // `insteadOf`, so only `pushInsteadOf` keeps it reading so); pushes go to the bare one.
    git(cwd, &["remote", "set-url", "origin", GITHUB]);
    git(cwd, &["config", &format!("url.{}.pushInsteadOf", origin.display()), GITHUB]);
    git(cwd, &["checkout", "-b", "work"]);
    std::fs::write(cwd.join("README.md"), "base\n").unwrap();
    git(cwd, &["add", "README.md"]);
    git(cwd, &["commit", "-m", "base"]);
    git(cwd, &["push", "-u", "origin", "work"]);
    std::fs::write(cwd.join("README.md"), "base\nedited, not committed\n").unwrap();
    std::fs::write(cwd.join("new-a.txt"), "untracked a\n").unwrap();
    std::fs::write(cwd.join("new-b.txt"), "untracked b\n").unwrap();
}

const GITHUB: &str = "https://github.com/duress/project.git";

fn dirty(cwd: &Path) -> Vec<String> {
    git(cwd, &["status", "--porcelain"]).lines().map(str::to_owned).collect()
}

/// An ssh in front of the stand-in one: the commands it knows go to it, any other (the
/// target's worktree and carry scripts) runs here under bash, as the target machine would.
fn ssh_shim(dir: &Path, source_home: &Path) -> PathBuf {
    let shim = dir.join("shim");
    std::fs::create_dir_all(&shim).unwrap();
    let script = format!(
        r#"#!/usr/bin/env python3
import os, sys
orig = {orig}
args = sys.argv[1:]
# session_move.rs PLAIN_SCRIPT, the folder a move makes on the target, by its exact text:
# other scripts (the carry's APPLY_SCRIPT) also read `d` and `mkdir -p`.
PLAIN = 'read -r d || exit 2; mkdir -p -- "$d"'
cmd = args[-1] if args else ''
known = ('-L' in args or '-W' in args or 'acpmux daemon status --json' in cmd
         or 'cat ~/.acpmux/config.json' in cmd or PLAIN in cmd)
if known:
    os.execv(orig, [orig] + args)
# The target's clone of GITHUB fetches the bare origin.
os.environ.update({{'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': {key}, 'GIT_CONFIG_VALUE_0': {github}}})
os.execvp('bash', ['bash', '-c', cmd])
"#,
        orig = json!(source_home.join("bin").join("ssh")),
        key = json!(format!("url.{}.insteadOf", dir.join("origin.git").display())),
        github = json!(GITHUB),
    );
    let path = shim.join("ssh");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    shim
}

/// The stand-in `cmux`: `vm new --wait` answers m-fake after `vm_delay` s; `move` by `mode`:
/// `ok`, `delay:N` (N s, then the move), `netfail:N` (N s, then the error a dropped network
/// gives); `cloud pause-machine` ok. Each call is a line of calls.log: [unix_ms, args].
fn fake_cmux(dir: &Path, arrive: &Path, shim: &Path, vm_delay: f64, mode: &str) -> PathBuf {
    let script = format!(
        r#"#!/usr/bin/env python3
import json, os, subprocess, sys, time
args = sys.argv[1:]
with open({log}, 'a') as f:
    f.write(json.dumps([int(time.time() * 1000), args]) + '\n')
mode = {mode}
if args[:3] == ['vm', 'new', '--wait']:
    time.sleep({vm_delay})
    print(json.dumps({{"ok": True, "result": {{"machine_id": "m-fake"}}}}))
    sys.exit(0)
if args[:1] == ['move'] and args[2:4] == ['--to', 'vm:m-fake']:
    if mode.startswith('netfail:'):
        time.sleep(float(mode.split(':')[1]))
        print(json.dumps({{"error": {{"code": "network", "message": "network is unreachable"}}}}), file=sys.stderr)
        sys.exit(1)
    if mode.startswith('delay:'):
        time.sleep(float(mode.split(':')[1]))
    env = dict(os.environ)
    env['PATH'] = {shim} + ':' + env.get('PATH', '')
    argv = [{bin}, '--json', 'session', 'move', args[1], '--machine', 'target', '--carry-changes']
    if mode != 'carry':
        argv += ['--cwd', {arrive}]
    done = subprocess.run(argv, capture_output=True, text=True, env=env)
    with open({log} + '.move', 'a') as f:
        f.write(json.dumps({{"rc": done.returncode, "out": done.stdout[-4000:], "err": done.stderr[-4000:]}}) + '\n')
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    sys.exit(done.returncode)
if args[:2] == ['cloud', 'pause-machine']:
    print(json.dumps({{"ok": True}}))
    sys.exit(0)
sys.exit(2)
"#,
        log = json!(dir.join("calls.log")),
        bin = json!(daemon_env::bin()),
        arrive = json!(arrive),
        shim = json!(shim),
        mode = json!(mode),
        vm_delay = vm_delay,
    );
    let path = dir.join("cmux");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// The fake's calls, the daemon's `--json auth token` reads aside (`hosted_mcp.rs` asks for a
/// token on its own schedule; it is not a step of the move).
fn calls(dir: &Path) -> Vec<(u64, Vec<String>)> {
    std::fs::read_to_string(dir.join("calls.log"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str::<(u64, Vec<String>)>(l).unwrap())
        .filter(|(_, a)| !(a.len() >= 2 && a[0] == "--json" && a[1] == "auth"))
        .collect()
}

fn verbs(dir: &Path) -> Vec<String> {
    calls(dir).into_iter().map(|(_, a)| a[..2.min(a.len())].join(" ")).collect()
}

fn move_log(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("calls.log.move")).unwrap_or_default()
}

/// The daemon's pid and every descendant's (the agent, a running `cmux` step).
fn tree(root: u32) -> Vec<u32> {
    let mut parent = BTreeMap::new();
    for entry in std::fs::read_dir("/proc").unwrap().flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else { continue };
        let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else { continue };
        let Some(after) = stat.rfind(')').map(|i| &stat[i + 2..]) else { continue };
        if let Some(ppid) = after.split(' ').nth(1).and_then(|p| p.parse::<u32>().ok()) {
            parent.insert(pid, ppid);
        }
    }
    let mut out = vec![root];
    let mut i = 0;
    while i < out.len() {
        let p = out[i];
        out.extend(parent.iter().filter(|(_, pp)| **pp == p).map(|(c, _)| *c));
        i += 1;
    }
    out
}

/// `sig` to each of `pids` (a [`tree`] snapshot). A descendant that exited between the snapshot
/// and the signal (the `cmux vm new` step ending, a short helper the agent ran) is gone, not a
/// failure: `kill -STOP` of the whole list exited 1 for that one pid and failed the test
/// (`place_duress.rs:182`, jobs 140712197510 and the `_carrying_changes` runs, 2026-11-27),
/// though every live process was stopped. The daemon itself, `pids[0]`, must take it.
fn signal(pids: &[u32], sig: &str) {
    let number = match sig {
        "STOP" => libc::SIGSTOP,
        "CONT" => libc::SIGCONT,
        "KILL" => libc::SIGKILL,
        other => panic!("no signal {other}"),
    };
    for (i, pid) in pids.iter().enumerate() {
        let pid = libc::pid_t::try_from(*pid).expect("a pid");
        // SAFETY: kill(2) with a pid from /proc and a valid signal number reads no memory.
        if unsafe { libc::kill(pid, number) } == 0 {
            continue;
        }
        let error = std::io::Error::last_os_error();
        let gone = error.raw_os_error() == Some(libc::ESRCH);
        assert!(gone && (i > 0 || sig == "KILL"), "kill -{sig} {pid} of {pids:?}: {error}");
    }
}

/// The source machine dies: its daemon and everything under it, SIGKILL; then it starts again
/// on the same home (the machine back, the app relaunched).
async fn die_and_restart(d: &mut Daemon, vars: &[(&str, &str)]) -> Vec<u32> {
    let pids = tree(d.child.id());
    signal(&pids, "KILL");
    let _ = d.child.wait();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let path = format!("{}:{}", d.home.join("bin").display(), daemon_env::bare_path(&[]));
    let mut command = daemon_env::command(&d.home, daemon_env::Agents::StandIn, &[]);
    command
        .env("PATH", path)
        .args(["daemon", "run", "--log", "warn"])
        .env("ACPMUX_HOME", &d.home)
        .env("ACPMUX_SOCKET", &d.socket)
        .env("ACPMUX_AGENT_HOSTS", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .envs(vars.iter().copied())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    d.child = command.spawn().expect("respawn daemon");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while tokio::net::UnixStream::connect(&d.socket).await.is_err() {
        assert!(tokio::time::Instant::now() < deadline, "the source never listened again");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    pids
}

/// The chat's records by dir/kind, the move lines aside.
async fn tally(rpc: &mut Rpc, id: &str) -> BTreeMap<String, usize> {
    let mut out = BTreeMap::new();
    for e in super::session_move_live::events(rpc, id).await {
        if e["kind"] == "moved" {
            continue;
        }
        let key =
            format!("{}/{}", e["dir"].as_str().unwrap_or(""), e["kind"].as_str().unwrap_or(""));
        *out.entry(key).or_default() += 1;
    }
    out
}

fn total(t: &BTreeMap<String, usize>) -> usize {
    t.values().sum()
}

async fn moved_lines(rpc: &mut Rpc, id: &str) -> Vec<Value> {
    super::session_move_live::events(rpc, id)
        .await
        .into_iter()
        .filter(|e| e["kind"] == "moved")
        .map(|e| e["msg"].clone())
        .collect()
}

async fn wait_closed(rpc: &mut Rpc, id: &str, limit: Duration) -> Option<Value> {
    let deadline = tokio::time::Instant::now() + limit;
    loop {
        let info = rpc.call("_acpmux/info", json!({"sessionId": id})).await;
        if info["status"] == "closed" {
            return Some(info);
        }
        if tokio::time::Instant::now() > deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

struct Rig {
    scratch: daemon_env::Scratch,
    target: Daemon,
    source: Daemon,
    cmux: String,
    /// The source's `pushInsteadOf` key: its branch push goes to the bare origin.
    push_key: String,
    cwd: PathBuf,
}

impl Rig {
    /// The source's env as the rig started it, for a restart after it dies.
    fn source_vars(&self) -> [(&str, &str); 4] {
        [
            ("CMUX_BIN", self.cmux.as_str()),
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", self.push_key.as_str()),
            ("GIT_CONFIG_VALUE_0", GITHUB),
        ]
    }
}

async fn rig(tag: &str, vm_delay: f64, mode: &str) -> Rig {
    let scratch = daemon_env::Scratch::new(&format!("pd-{tag}"));
    let target = Daemon::start(&format!("pdt-{tag}")).await;
    let (source_home, _) = Daemon::place(&format!("pds-{tag}"));
    let shim = ssh_shim(scratch.path(), &source_home);
    let cmux = fake_cmux(scratch.path(), &target.home.join("arrived"), &shim, vm_delay, mode);
    let cmux = cmux.to_str().unwrap().to_owned();
    // The source's push of the branch goes to the bare origin.
    let key = format!("url.{}.pushInsteadOf", scratch.path().join("origin.git").display());
    let source = Daemon::with_env(
        &format!("pds-{tag}"),
        Some(&target),
        json!({}),
        &[
            ("CMUX_BIN", cmux.as_str()),
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", key.as_str()),
            ("GIT_CONFIG_VALUE_0", GITHUB),
        ],
        "approve-all",
    )
    .await;
    let cwd = scratch.path().join("project");
    repo(scratch.path(), &cwd);
    Rig { scratch, target, source, cmux, push_key: key, cwd }
}

async fn new_chat(rig: &Rig, rpc: &mut Rpc) -> String {
    let made = rpc.call("session/new", json!({"cwd": rig.cwd, "mcpServers": []})).await;
    made["sessionId"].as_str().unwrap().to_owned()
}

async fn two_turns(rpc: &mut Rpc, id: &str) {
    rpc.call("session/prompt", prompt(id, "p-1", "first message")).await;
    rpc.call("session/prompt", prompt(id, "p-2", "second message")).await;
}

fn cancel_note(id: &str) -> String {
    format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": id}})
    )
}

fn report(name: &str, key: &str, value: impl std::fmt::Display) {
    eprintln!("DURESS {name} {key}={value}");
}

/// (a) Cloud only asked mid-turn, then the source sleeps 20 s (SIGSTOP of the daemon and its
/// agent), wakes, and the turn ends: the move waits for the turn end and loses nothing.
#[tokio::test]
async fn duress_a_sleep_mid_turn_then_the_move() {
    sleep_case("a-sleep", "as", "ok").await;
}

/// The same, the target making its own worktree of the branch and the uncommitted work
/// carried into it (no `--cwd`).
#[tokio::test]
async fn duress_a_sleep_mid_turn_then_the_move_carrying_changes() {
    sleep_case("a-sleep-carry", "ac", "carry").await;
}

async fn sleep_case(n: &str, tag: &str, mode: &str) {
    let rig = rig(tag, 2.0, mode).await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    let id = new_chat(&rig, &mut src).await;
    two_turns(&mut src, &id).await;
    let before = tally(&mut src, &id).await;
    let dirty_before = dirty(&rig.cwd);
    report(n, "records_before", total(&before));
    report(n, "kinds_before", json!(before));
    report(n, "uncommitted_before", dirty_before.len());

    src.send_prompt(&id, "p-3", "until-cancel").await;
    src.notification("session/update", |p| p["update"]["content"]["text"] == "running").await;
    let asked = Instant::now();
    let set = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": {"mode": "cloud"}, "confirm": true}),
        )
        .await;
    report(n, "place_set_state", &set["state"]);
    assert_eq!(set["state"], "after_turn", "{set}");
    // The machine starts at once, mid-turn.
    let deadline = Instant::now() + Duration::from_secs(20);
    while !verbs(rig.scratch.path()).iter().any(|v| v == "vm new") && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    report(n, "vm_new_started_after_ms", asked.elapsed().as_millis());

    let pids = tree(rig.source.child.id());
    report(n, "stopped_pids", pids.len());
    signal(&pids, "STOP");
    tokio::time::sleep(Duration::from_secs(20)).await;
    signal(&pids, "CONT");
    tokio::time::sleep(Duration::from_secs(1)).await;
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    report(n, "state_after_wake", &got["state"]);
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    report(n, "status_after_wake", &info["status"]);
    report(n, "moved_lines_mid_turn", moved_lines(&mut src, &id).await.len());
    report(n, "calls_mid_turn", json!(verbs(rig.scratch.path())));

    let turn_end = Instant::now();
    src.wr.write_all(cancel_note(&id).as_bytes()).await.unwrap();
    let closed = wait_closed(&mut src, &id, Duration::from_secs(90)).await;
    report(n, "moved", closed.is_some());
    report(n, "move_ms_after_turn_end", turn_end.elapsed().as_millis());
    report(n, "total_ms_from_ask", asked.elapsed().as_millis());
    report(n, "calls", json!(verbs(rig.scratch.path())));
    if closed.is_none() {
        report(n, "move_log", move_log(rig.scratch.path()));
        report(n, "lines_source", json!(moved_lines(&mut src, &id).await));
        panic!("the chat did not move after its turn");
    }
    let on_source = moved_lines(&mut src, &id).await;
    report(n, "moved_lines_source", on_source.len());
    report(n, "moved_text", &on_source[0]["text"]);
    let mut dst = Rpc::connect(&rig.target.socket).await;
    let after = tally(&mut dst, &id).await;
    report(n, "records_after_on_target", total(&after));
    report(n, "kinds_after", json!(after));
    report(n, "moved_lines_target", moved_lines(&mut dst, &id).await.len());
    let there = dst.call("_acpmux/info", json!({"sessionId": id})).await;
    let cwd = there["cwd"].as_str().map(PathBuf::from);
    report(n, "target_cwd", json!(cwd));
    report(n, "move_log", json!(move_log(rig.scratch.path())));
    if let Some(cwd) = cwd.filter(|c| c.join(".git").exists()) {
        let d = dirty(&cwd);
        report(n, "uncommitted_after", d.len());
        report(n, "uncommitted_after_list", json!(d));
        report(n, "readme_after", json!(std::fs::read_to_string(cwd.join("README.md")).ok()));
    } else {
        report(n, "uncommitted_after", "no git folder on target");
    }
    // Nothing lost: every record the chat had before the move is on the target.
    for (k, v) in &before {
        assert!(after.get(k).copied().unwrap_or(0) >= *v, "{k}: {v} before, {after:?} after");
    }
}

/// (a, long) A turn that runs past ten minutes: the move asked mid-turn waits, then fails.
/// Ignored by default (11 min); run with --ignored.
#[tokio::test]
#[ignore]
async fn duress_a_turn_longer_than_ten_minutes() {
    let n = "a-long-turn";
    let rig = rig("al", 1.0, "ok").await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    let id = new_chat(&rig, &mut src).await;
    two_turns(&mut src, &id).await;
    src.send_prompt(&id, "p-3", "until-cancel").await;
    src.notification("session/update", |p| p["update"]["content"]["text"] == "running").await;
    let set = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": {"mode": "cloud"}, "confirm": true}),
        )
        .await;
    report(n, "place_set_state", &set["state"]);
    tokio::time::sleep(Duration::from_secs(610)).await;
    src.wr.write_all(cancel_note(&id).as_bytes()).await.unwrap();
    let closed = wait_closed(&mut src, &id, Duration::from_secs(30)).await;
    report(n, "moved", closed.is_some());
    report(n, "calls", json!(verbs(rig.scratch.path())));
    report(n, "lines", json!(moved_lines(&mut src, &id).await));
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    report(n, "place_get", got);
}

/// (b) The source goes offline during the move (`cmux move` fails as a dropped network does,
/// 3 s in): the chat stays here, intact, says why, and the machine is paused.
#[tokio::test]
async fn duress_b_offline_during_the_move() {
    let n = "b-offline";
    let rig = rig("bo", 1.0, "netfail:3").await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    let id = new_chat(&rig, &mut src).await;
    two_turns(&mut src, &id).await;
    let before = tally(&mut src, &id).await;
    let dirty_before = dirty(&rig.cwd);
    report(n, "records_before", total(&before));
    report(n, "uncommitted_before", dirty_before.len());
    let asked = Instant::now();
    let set = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": {"mode": "cloud"}, "confirm": true}),
        )
        .await;
    report(n, "place_set_state", &set["state"]);
    report(n, "place_set_reason", &set["reason"]);
    report(n, "place_set_answer_ms", asked.elapsed().as_millis());
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut lines = moved_lines(&mut src, &id).await;
    while !(lines.len() >= 2 && verbs(rig.scratch.path()).len() >= 3) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
        lines = moved_lines(&mut src, &id).await;
    }
    report(n, "rollback_ms", asked.elapsed().as_millis());
    report(n, "lines", json!(lines.iter().map(|l| l["text"].clone()).collect::<Vec<_>>()));
    report(n, "calls", json!(verbs(rig.scratch.path())));
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    report(n, "status_after", &info["status"]);
    let after = tally(&mut src, &id).await;
    report(n, "records_after", total(&after));
    let dirty_after = dirty(&rig.cwd);
    report(n, "uncommitted_after", dirty_after.len());
    report(n, "uncommitted_same", dirty_after == dirty_before);
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    report(n, "place_get", &got);
    // The chat still works here.
    let reply = src.call("session/prompt", prompt(&id, "p-9", "still here?")).await;
    report(n, "prompt_after_stop_reason", &reply["stopReason"]);
    // Undo after a failed move.
    let undo = src.call("_acpmux/place_undo", json!({"sessionId": id})).await;
    report(n, "undo_after_failed_move", &undo);
    assert_ne!(info["status"], "closed");
    assert_eq!(dirty_after, dirty_before);
    // A failed move leaves the mode as it was, and its Undo pins nothing.
    assert_eq!(got["mode"]["mode"], "auto", "{got}");
    assert_eq!(undo["chats"][0]["state"], "refused", "{undo}");
    assert_eq!(undo["chats"][0]["reason"], "this chat has no move to undo", "{undo}");
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    assert_eq!(got["mode"]["mode"], "auto", "after undo: {got}");
}

/// (b, death) The source dies 2 s into the move (power off, the app killed) and comes back.
#[tokio::test]
async fn duress_b_source_dies_during_the_move() {
    let n = "b-dies-moving";
    let mut rig = rig("bd", 1.0, "delay:4").await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    let id = new_chat(&rig, &mut src).await;
    two_turns(&mut src, &id).await;
    let before = tally(&mut src, &id).await;
    let dirty_before = dirty(&rig.cwd);
    report(n, "records_before", total(&before));
    report(n, "uncommitted_before", dirty_before.len());
    let set = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": {"mode": "cloud"}, "confirm": true}),
        )
        .await;
    report(n, "place_set_state", &set["state"]);
    let deadline = Instant::now() + Duration::from_secs(20);
    while !verbs(rig.scratch.path()).iter().any(|v| v.starts_with("move"))
        && Instant::now() < deadline
    {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    drop(src);
    let vars: Vec<(String, String)> =
        rig.source_vars().iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    let vars: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let killed = die_and_restart(&mut rig.source, &vars).await;
    report(n, "killed_pids", killed.len());
    tokio::time::sleep(Duration::from_secs(8)).await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    report(n, "status_after_restart", &info["status"]);
    report(n, "moving_after_restart", &info["moving"]);
    let lines = moved_lines(&mut src, &id).await;
    report(n, "lines", json!(lines.iter().map(|l| l["text"].clone()).collect::<Vec<_>>()));
    report(n, "calls", json!(verbs(rig.scratch.path())));
    report(n, "paused", verbs(rig.scratch.path()).iter().any(|v| v == "cloud pause-machine"));
    let after = tally(&mut src, &id).await;
    report(n, "records_after", total(&after));
    let dirty_after = dirty(&rig.cwd);
    report(n, "uncommitted_after", dirty_after.len());
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    report(n, "place_get", &got);
    let mut dst = Rpc::connect(&rig.target.socket).await;
    let on_target = dst.try_call("_acpmux/info", json!({"sessionId": id})).await;
    report(n, "on_target", json!(on_target.map(|v| v["status"].clone()).unwrap_or_else(|e| e)));
    if info["status"] != "closed" {
        let reply = src.try_call("session/prompt", prompt(&id, "p-9", "still here?")).await;
        report(
            n,
            "prompt_after_restart",
            json!(reply.map(|r| r["stopReason"].clone()).unwrap_or_else(|e| e)),
        );
        // Cut mid-move and still here: one line says why, its machine is paused, the mode is as
        // it was.
        let failed: Vec<_> = lines.iter().filter(|l| l["failed"] == json!(true)).collect();
        assert_eq!(failed.len(), 1, "{lines:?}");
        assert!(verbs(rig.scratch.path()).iter().any(|v| v == "cloud pause-machine"));
        assert_eq!(got["mode"]["mode"], "auto", "{got}");
    }
}

/// (a/b, death) The source dies while the move waits for the turn (its machine already
/// started) and comes back.
#[tokio::test]
async fn duress_b_source_dies_while_the_move_waits_for_the_turn() {
    let n = "b-dies-waiting";
    let mut rig = rig("bw", 1.0, "ok").await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    let id = new_chat(&rig, &mut src).await;
    two_turns(&mut src, &id).await;
    let before = tally(&mut src, &id).await;
    report(n, "records_before", total(&before));
    src.send_prompt(&id, "p-3", "until-cancel").await;
    src.notification("session/update", |p| p["update"]["content"]["text"] == "running").await;
    let set = src
        .call(
            "_acpmux/place_set",
            json!({"sessionId": id, "place": {"mode": "cloud"}, "confirm": true}),
        )
        .await;
    report(n, "place_set_state", &set["state"]);
    let deadline = Instant::now() + Duration::from_secs(20);
    while !verbs(rig.scratch.path()).iter().any(|v| v == "vm new") && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    drop(src);
    let vars: Vec<(String, String)> =
        rig.source_vars().iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    let vars: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    die_and_restart(&mut rig.source, &vars).await;
    let mut src = Rpc::connect(&rig.source.socket).await;
    // The move the dead daemon left goes on once the restarted one is up (its turn died with it).
    let moved = wait_closed(&mut src, &id, Duration::from_secs(30)).await;
    report(n, "moved_after_restart", moved.is_some());
    let info = src.call("_acpmux/info", json!({"sessionId": id})).await;
    report(n, "status_after_restart", &info["status"]);
    let got = src.call("_acpmux/place_get", json!({"sessionId": id})).await;
    report(n, "place_get", &got);
    let lines = moved_lines(&mut src, &id).await;
    report(n, "lines", json!(lines));
    let calls = verbs(rig.scratch.path());
    report(n, "calls", json!(calls));
    report(n, "paused", calls.iter().any(|v| v == "cloud pause-machine"));
    let after = tally(&mut src, &id).await;
    report(n, "records_after", total(&after));
    report(n, "uncommitted_after", dirty(&rig.cwd).len());
    assert!(moved.is_some(), "the move was lost with the daemon: {info}");
    // One machine started (none twice), the move ran on it, and one line says so.
    assert_eq!(calls.iter().filter(|v| *v == "vm new").count(), 1, "{calls:?}");
    assert!(calls.iter().any(|v| v.starts_with("move")), "{calls:?}");
    assert!(!calls.iter().any(|v| v == "cloud pause-machine"), "{calls:?}");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_ne!(lines[0]["failed"], json!(true), "{lines:?}");
}
