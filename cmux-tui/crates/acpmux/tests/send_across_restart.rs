//! A send made while one daemon hands over to the next waits for the next one and is delivered.
//!
//! On 2026-10-21/22 cosmic-gray's daemon logged "shutting down" four times (22:52, 00:55, 03:00,
//! 04:10 UTC): the cmux app stopping it (`_acpmux/shutdown`) so its bundled build takes over. The
//! old daemon removes its socket at once but keeps `daemon.lock` until its agents settle, 4-13 s
//! there. A send in that window started a daemon that found the lock taken ("another acpmux
//! daemon holds daemon.lock", 00:55:21) and exited, and the send failed. A coordinator's message
//! is lost that way unless someone notices and sends it again.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-sar-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(
        dir.join("config.json"),
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    )
    .unwrap();
    dir
}

fn cli_command(dir: &Path, args: &[&str]) -> std::process::Command {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    cli_command(dir, args).output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

struct CustomDaemon(Child);

impl CustomDaemon {
    fn stop(&mut self) {
        if self.0.try_wait().unwrap().is_none() {
            // SAFETY: this is the unreaped daemon child this test started.
            unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        }
        self.0.wait().unwrap();
    }
}

impl Drop for CustomDaemon {
    fn drop(&mut self) {
        self.stop();
    }
}

fn start_custom_daemon(dir: &Path, extra: &[&str]) -> CustomDaemon {
    let mut child = daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .args(extra)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(dir.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let ready =
        BufReader::new(child.stdout.take().unwrap()).lines().map_while(Result::ok).any(|line| {
            serde_json::from_str::<serde_json::Value>(&line).is_ok_and(|v| v["ready"] == true)
        });
    assert!(ready, "custom daemon did not become ready");
    CustomDaemon(child)
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn a_send_during_a_daemon_handover_waits_for_the_next_daemon_and_is_delivered() {
    let dir = scratch("h");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(
        made.status.success(),
        "the session: {}\ndaemon.log: {}",
        text(&made),
        fs::read_to_string(dir.join("daemon.log")).unwrap_or_default()
    );
    let stopped = cli(&dir, &["daemon", "shutdown"]);
    assert!(stopped.status.success(), "the first daemon stops: {}", text(&stopped));

    // The old daemon is still settling its agents: its socket is gone, its lock is held.
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join("daemon.lock"))
        .unwrap();
    // SAFETY: flock on a descriptor this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);

    let started = Instant::now();
    let mut send = cli_command(
        &dir,
        &["send", "--no-wait", "--prompt-id", "handover-prompt", "lane", "across the handover"],
    )
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .unwrap();
    // Let the replacement client attempt the handover before releasing the lock.
    // It must still be waiting while the old daemon owns the lock; otherwise
    // this test could pass without exercising the reconnect path.
    std::thread::sleep(Duration::from_millis(500));
    assert!(send.try_wait().unwrap().is_none(), "send did not wait for the lock handover");
    // The old daemon exits.
    // SAFETY: as above.
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
    drop(lock);

    let sent = send.wait_with_output().unwrap();
    assert!(sent.status.success(), "the send failed instead of waiting: {}", text(&sent));
    assert!(started.elapsed() < Duration::from_secs(20), "the send took {:?}", started.elapsed());

    let waited = cli(&dir, &["wait", "lane", "--timeout", "20"]);
    assert!(waited.status.success(), "the session's turn: {}", text(&waited));
    let last = cli(&dir, &["last", "lane"]);
    assert!(
        String::from_utf8_lossy(&last.stdout).contains("echo: across the handover"),
        "the next daemon did not deliver the send: {}",
        text(&last)
    );

    // The retry uses the original prompt id with `resend=true`.  The handover
    // can cut the request after the old daemon recorded it, so this assertion
    // protects the exactly-once ledger contract: one user message for this
    // text, with one stable id, even though the CLI reconnects and resends.
    let tail = cli(&dir, &["tail", "lane", "--last", "100"]);
    assert!(tail.status.success(), "tail: {}", text(&tail));
    let sends: Vec<serde_json::Value> = String::from_utf8_lossy(&tail.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .filter(|event: &serde_json::Value| {
            event["kind"] == "user_message" && event["msg"]["text"] == "across the handover"
        })
        .collect();
    assert_eq!(sends.len(), 1, "the prompt was delivered more than once: {}", text(&tail));
    assert_eq!(sends[0]["msg"]["promptId"], "handover-prompt", "the retry changed its id");
}

#[test]
fn a_lock_the_daemon_cannot_open_fails_at_once_instead_of_waiting_for_a_handover() {
    let dir = scratch("l");
    let _shutdown = Shutdown(&dir);
    // Not another daemon: a lock file the daemon refuses to open.
    std::os::unix::fs::symlink(dir.join("elsewhere"), dir.join("daemon.lock")).unwrap();
    let started = Instant::now();
    let out = cli(&dir, &["send", "--no-wait", "lane", "hello"]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(started.elapsed() < Duration::from_secs(5), "failed after {:?}", started.elapsed());
    assert!(!text(&out).contains("still holds"), "{}", text(&out));
}

/// The CLI restart wrapper keeps an active hosted turn and lets the new daemon
/// adopt it, rather than ending the session or requiring a new prompt.
#[test]
fn cli_daemon_restart_reattaches_an_active_turn() {
    let dir = scratch("cli-restart");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["new", "-d", "-n", "lane", "-m", "fake"]);
    assert!(made.status.success(), "start: {}", text(&made));
    let prompted = cli(&dir, &["send", "lane", "ticking:20:100"]);
    assert!(prompted.status.success(), "prompt: {}", text(&prompted));
    let before: serde_json::Value = serde_json::from_slice(&cli(&dir, &["--json", "ls"]).stdout)
        .expect("ls JSON before restart");
    let before_id = before["sessions"][0]["sessionId"].as_str().unwrap().to_owned();

    let stopped = cli(&dir, &["daemon", "shutdown"]);
    assert!(stopped.status.success(), "shutdown: {}", text(&stopped));
    let restarted = cli(&dir, &["--json", "daemon", "start"]);
    assert!(restarted.status.success(), "start: {}", text(&restarted));
    let restart_json: serde_json::Value =
        serde_json::from_slice(&restarted.stdout).expect("restart JSON");
    assert!(
        restart_json["pid"].is_number(),
        "daemon start did not return status: {}",
        text(&restarted)
    );

    let waited = cli(&dir, &["wait", "lane", "--timeout", "30"]);
    assert!(waited.status.success(), "wait: {}", text(&waited));
    let after: serde_json::Value = serde_json::from_slice(&cli(&dir, &["--json", "ls"]).stdout)
        .expect("ls JSON after restart");
    assert_eq!(after["sessions"][0]["sessionId"], before_id);
    let last = cli(&dir, &["last", "lane"]);
    assert!(
        String::from_utf8_lossy(&last.stdout).contains("tick19"),
        "turn did not finish after restart: {}",
        text(&last)
    );
}

/// Both callers are already attached when the old daemon shuts down. The
/// harness blocks on a FIFO until the replacement is ready, so an ordinary
/// fast turn cannot make this pass without traversing the handover.
#[test]
fn streaming_send_and_active_wait_return_one_reply_across_restart() {
    let dir = scratch("waiting-stream");
    let _shutdown = Shutdown(&dir);
    let mut daemon = start_custom_daemon(&dir, &[]);
    let made = cli(&dir, &["new", "-d", "-n", "lane", "-m", "fake"]);
    assert!(made.status.success(), "new: {}", text(&made));

    let gate = dir.join("gate");
    let gate_c = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: the C string is valid and this test owns the new path.
    assert_eq!(unsafe { libc::mkfifo(gate_c.as_ptr(), 0o600) }, 0);
    // Opening both ends does not block. The fake harness reads until this
    // writer closes, which happens only after the replacement serves.
    let gate_writer = fs::OpenOptions::new().read(true).write(true).open(&gate).unwrap();
    let prompt = format!("gate: {}", gate.display());
    let mut send = cli_command(
        &dir,
        &["send", "--timeout", "30", "--prompt-id", "stream-handover", "lane", &prompt],
    )
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .unwrap();
    let mut stdout = send.stdout.take().unwrap();
    let (prefix_tx, prefix_rx) = std::sync::mpsc::channel();
    let (reply_tx, reply_rx) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        let mut prefix = [0; 11];
        let first = stdout.read_exact(&mut prefix);
        prefix_tx.send(first.map(|()| prefix)).unwrap();
        let mut reply = prefix.to_vec();
        stdout.read_to_end(&mut reply).unwrap();
        reply_tx.send(reply).unwrap();
    });
    assert_eq!(
        prefix_rx.recv_timeout(Duration::from_secs(15)).expect("no streamed prefix").unwrap(),
        *b"before-gate"
    );

    let mut wait = cli_command(&dir, &["--json", "wait", "lane", "--timeout", "30"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(500));
    assert!(wait.try_wait().unwrap().is_none(), "wait ended before the gated turn");
    // Wait for this child, not socket absence: the reconnecting clients can
    // bring the replacement up before a shutdown CLI finishes checking.
    daemon.stop();
    let started = cli(&dir, &["daemon", "start"]);
    assert!(started.status.success(), "replacement: {}", text(&started));
    drop(gate_writer);

    let reply = reply_rx.recv_timeout(Duration::from_secs(35)).expect("send never completed");
    reader.join().unwrap();
    let sent = send.wait_with_output().unwrap();
    assert!(sent.status.success(), "send: {}", text(&sent));
    assert_eq!(String::from_utf8(reply).unwrap().trim(), "before-gateafter-gate");
    let waited = wait.wait_with_output().unwrap();
    assert!(waited.status.success(), "wait: {}", text(&waited));
    let result: serde_json::Value = serde_json::from_slice(&waited.stdout).unwrap();
    assert_eq!(result["sessions"][0]["reply"], "before-gateafter-gate");
    assert_eq!(result["timedOut"], false);
    let tail = cli(&dir, &["tail", "lane", "--last", "100"]);
    assert!(tail.status.success(), "tail: {}", text(&tail));
    let occurrences = String::from_utf8_lossy(&tail.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|event| {
            event["kind"] == "user_message" && event["msg"]["promptId"] == "stream-handover"
        })
        .count();
    assert_eq!(occurrences, 1, "reconnect delivered the prompt twice: {}", text(&tail));
}

#[test]
fn cli_daemon_restart_refuses_unsaved_token_before_stopping() {
    let dir = scratch("cli-restart-custom");
    let _daemon = start_custom_daemon(&dir, &["--token", "restart+a=&b#c"]);
    let _shutdown = Shutdown(&dir);
    let before: serde_json::Value =
        serde_json::from_slice(&cli(&dir, &["--json", "daemon", "status"]).stdout)
            .expect("custom daemon status");
    let listen = before["listen"].as_str().expect("custom listen").to_owned();
    assert!(!listen.ends_with(":0"), "daemon did not report bound listener: {listen}");
    assert!(before["webUrl"].as_str().unwrap().contains("token=restart+a=&b#c"));

    let saved = fs::read(dir.join("config.json")).unwrap();
    let restarted = cli(&dir, &["--json", "daemon", "restart"]);
    assert!(!restarted.status.success(), "restart unexpectedly succeeded");
    assert!(!text(&restarted).contains("restart+a="), "token leaked");
    assert_eq!(fs::read(dir.join("config.json")).unwrap(), saved);
    let after: serde_json::Value =
        serde_json::from_slice(&cli(&dir, &["--json", "daemon", "status"]).stdout)
            .expect("restarted daemon status");
    assert_eq!(after["pid"], before["pid"]);
    assert_eq!(after["listen"], listen);
    assert!(after["webUrl"].as_str().unwrap().contains("token=restart+a=&b#c"));
}

#[test]
fn failed_reconnect_keeps_the_generated_prompt_recovery_identity() {
    let dir = scratch("reconnect-error");
    let _shutdown = Shutdown(&dir);
    let mut daemon = start_custom_daemon(&dir, &[]);
    let made = cli(&dir, &["new", "-d", "-n", "lane", "-m", "fake"]);
    assert!(made.status.success(), "new: {}", text(&made));
    let gate = dir.join("gate");
    let gate_c = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: this test owns the new path and the C string is valid.
    assert_eq!(unsafe { libc::mkfifo(gate_c.as_ptr(), 0o600) }, 0);
    let gate_writer = fs::OpenOptions::new().read(true).write(true).open(&gate).unwrap();
    let prompt = format!("gate: {}", gate.display());
    // No --prompt-id: callers need the generated identity to recover a send
    // whose acceptance and completion are ambiguous after reconnect fails.
    let send = cli_command(&dir, &["--json", "send", "--timeout", "10", "lane", &prompt])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let streamed = cli(&dir, &["wait", "lane", "--match", "before-gate", "--timeout", "5"]);
    assert!(streamed.status.success(), "first chunk: {}", text(&streamed));
    let tail = cli(&dir, &["tail", "lane", "--last", "100"]);
    assert!(tail.status.success(), "tail: {}", text(&tail));
    let accepted = String::from_utf8_lossy(&tail.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|event| event["kind"] == "user_message" && event["msg"]["text"] == prompt)
        .expect("no accepted prompt in the session log");
    let prompt_id = accepted["msg"]["promptId"].as_str().expect("generated prompt id");
    assert!(uuid::Uuid::parse_str(prompt_id).is_ok(), "not a generated prompt id");
    let sessions: serde_json::Value =
        serde_json::from_slice(&cli(&dir, &["--json", "ls"]).stdout).unwrap();
    let session_id = sessions["sessions"][0]["sessionId"].clone();

    // Refuse only the replacement's attempt to open its log, using an unsafe
    // link in this test's private home; the direct child logs to stderr, so
    // no existing log needs changing. This makes reconnect fail immediately.
    let log = dir.join("daemon.log");
    std::os::unix::fs::symlink(dir.join("outside"), &log).unwrap();
    daemon.stop();
    let sent = send.wait_with_output().unwrap();
    // Restore before cleanup starts a daemon to stop the kept harness.
    fs::remove_file(&log).unwrap();
    drop(gate_writer);
    let restarted = cli(&dir, &["daemon", "start"]);
    assert!(restarted.status.success(), "cleanup daemon: {}", text(&restarted));
    assert!(!sent.status.success(), "send unexpectedly succeeded: {}", text(&sent));
    let envelope: serde_json::Value = serde_json::from_slice(&sent.stderr).unwrap();
    assert_eq!(envelope["error"]["detail"], "daemon_closed", "{}", text(&sent));
    assert_eq!(envelope["error"]["promptId"], prompt_id, "{}", text(&sent));
    assert_eq!(envelope["error"]["sessionId"], session_id, "{}", text(&sent));
    assert_eq!(envelope["error"]["retryable"], true, "{}", text(&sent));
}

#[test]
fn agent_error_named_like_daemon_close_is_not_replayed() {
    let dir = scratch("agent-close-wording");
    let _shutdown = Shutdown(&dir);
    let marker = dir.join("agent-attempts");
    let mut cmd = cli_command(
        &dir,
        &[
            "--json",
            "run",
            "-q",
            "-n",
            "lane",
            "--prompt-id",
            "collision",
            "agent-daemon-closed-error",
        ],
    );
    cmd.env("FAKE_AGENT_DAEMON_CLOSED_MARKER", &marker)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let out = cmd.output().unwrap();
    assert!(!out.status.success(), "agent RPC failure was replayed: {}", text(&out));
    assert_eq!(fs::read_to_string(&marker).unwrap().lines().count(), 1);
    let error: serde_json::Value = serde_json::from_slice(&out.stderr).unwrap_or_default();
    assert_eq!(error["error"]["detail"], "agent_error", "{}", text(&out));
    // A retained ledger outcome is the same error. Falling back to the
    // durable log after dropping it would instead synthesize a successful
    // duplicate response, and starting another turn repeats the side effect.
    let resend = cli(
        &dir,
        &["--json", "send", "--prompt-id", "collision", "lane", "agent-daemon-closed-error"],
    );
    assert!(!resend.status.success(), "ledger outcome was lost: {}", text(&resend));
    let repeated: serde_json::Value = serde_json::from_slice(&resend.stderr).unwrap();
    assert_eq!(repeated["error"]["detail"], "agent_error");
    assert_eq!(fs::read_to_string(&marker).unwrap().lines().count(), 1);
}

#[test]
fn daemon_lock_holder_exits_with_systemd_prevented_status() {
    let dir = scratch("lock-held-exit");
    let _shutdown = Shutdown(&dir);
    let mut daemon = start_custom_daemon(&dir, &[]);
    let second = cli(&dir, &["daemon", "run", "--log", "warn"]);
    daemon.stop();
    assert_eq!(second.status.code(), Some(75), "{}", text(&second));
    drop(_shutdown);
}

#[test]
fn cli_daemon_restart_preserves_bound_listener_with_saved_token() {
    let dir = scratch("cli-listener");
    let _daemon = start_custom_daemon(&dir, &[]);
    let _shutdown = Shutdown(&dir);
    let before: serde_json::Value =
        serde_json::from_slice(&cli(&dir, &["--json", "daemon", "status"]).stdout).unwrap();
    let restarted = cli(&dir, &["--json", "daemon", "restart"]);
    assert!(restarted.status.success(), "restart: {}", text(&restarted));
    let after: serde_json::Value =
        serde_json::from_slice(&cli(&dir, &["--json", "daemon", "status"]).stdout).unwrap();
    assert_ne!(after["pid"], before["pid"]);
    assert_eq!(after["listen"], before["listen"]);
    assert_eq!(after["webUrl"], before["webUrl"]);
}

#[test]
fn a_thought_after_the_reply_does_not_print_the_reply_twice() {
    let dir = scratch("trailing-thought");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["new", "-d", "-n", "lane", "-m", "fake"]);
    assert!(made.status.success(), "{}", text(&made));
    let sent = cli(&dir, &["send", "--timeout", "10", "lane", "reply-then-thought"]);
    assert!(sent.status.success(), "{}", text(&sent));
    assert_eq!(String::from_utf8_lossy(&sent.stdout).trim(), "echo: reply-then-thought");
}

#[test]
fn no_wait_lost_acceptance_keeps_the_generated_recovery_identity() {
    let dir = scratch("outbox-close");
    std::os::unix::fs::symlink(dir.join("outside"), dir.join("daemon.log")).unwrap();
    let listener = std::os::unix::net::UnixListener::bind(dir.join("acpmux.sock")).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let lines = BufReader::new(stream.try_clone().unwrap()).lines();
        for line in lines {
            let msg: serde_json::Value = serde_json::from_str(&line.unwrap()).unwrap();
            let Some(id) = msg.get("id") else { continue };
            if msg["method"] == "_acpmux/send_queue" {
                // Recorded by the outbox, but its acknowledgement is lost.
                return msg["params"]["request"]["_meta"]["acpmux"]["promptId"].clone();
            }
            let result = match msg["method"].as_str().unwrap() {
                "initialize" => json!({}),
                "_acpmux/info" => json!({"sessionId": "lane"}),
                other => panic!("unexpected request {other}"),
            };
            writeln!(stream, "{}", json!({"jsonrpc":"2.0", "id": id, "result": result})).unwrap();
        }
        panic!("queue request never arrived")
    });
    let sent = cli(&dir, &["--json", "send", "--no-wait", "lane", "ambiguous"]);
    let id = server.join().unwrap();
    assert!(!sent.status.success(), "{}", text(&sent));
    let envelope: serde_json::Value = serde_json::from_slice(&sent.stderr).unwrap();
    assert!(id.is_string());
    assert_eq!(envelope["error"]["detail"], "daemon_closed");
    assert_eq!(envelope["error"]["promptId"], id);
    assert_eq!(envelope["error"]["sessionId"], "lane");
    assert_eq!(envelope["error"]["retryable"], true);
    fs::remove_dir_all(dir).unwrap();
}

/// A wire peer can return arbitrary error text; only a real EOF permits replay.
#[tokio::test]
async fn a_daemon_error_named_connection_closed_never_replays() {
    for quiet in [false, true] {
        let (out, prompts, _) = restart_wire_case("collision", quiet).await;
        assert!(!out.status.success(), "{}", text(&out));
        assert_eq!(prompts, 1, "ordinary RPC error replayed a side effect: {}", text(&out));
        assert!(!String::from_utf8_lossy(&out.stderr).contains("\"detail\":\"daemon_closed\""));
    }
}

async fn assert_recovery_deadline(phase: &'static str) {
    for quiet in [false, true] {
        let (out, _, elapsed) = restart_wire_case(phase, quiet).await;
        assert_eq!(out.status.code(), Some(3), "{phase}: {}", text(&out));
        assert!(elapsed < Duration::from_millis(1800), "{phase} escaped deadline: {elapsed:?}");
    }
}

#[tokio::test]
async fn replacement_attach_shares_the_prompt_deadline() {
    assert_recovery_deadline("attach").await;
}

#[tokio::test]
async fn replacement_reply_reads_share_the_prompt_deadline() {
    assert_recovery_deadline("reply").await;
}

#[tokio::test]
async fn replacement_reply_paging_shares_the_prompt_deadline() {
    assert_recovery_deadline("paging").await;
}

#[tokio::test]
async fn send_initialize_shares_the_caller_deadline() {
    assert_full_call_deadline("initialize", "stream").await;
}

#[tokio::test]
async fn run_initialize_shares_the_caller_deadline() {
    assert_full_call_deadline("initialize", "run").await;
}

#[tokio::test]
async fn run_creation_shares_the_caller_deadline() {
    assert_full_call_deadline("new", "run").await;
}

#[tokio::test]
async fn send_info_shares_the_caller_deadline() {
    assert_full_call_deadline("info", "stream").await;
}

#[tokio::test]
async fn no_wait_reconnect_queue_shares_the_caller_deadline() {
    assert_full_call_deadline("queue", "no-wait").await;
}

#[tokio::test]
async fn no_wait_reconnect_status_shares_the_caller_deadline() {
    assert_full_call_deadline("status", "no-wait").await;
}

#[tokio::test]
async fn no_wait_legacy_queue_timeout_preserves_recovery_identity() {
    assert_full_call_deadline("legacy", "no-wait").await;
}

#[tokio::test]
async fn no_wait_replay_keeps_given_prompt_id_and_resend() {
    assert_full_call_deadline("queue", "no-wait-given").await;
}

#[tokio::test]
async fn streaming_permission_response_shares_the_caller_deadline() {
    assert_full_call_deadline("permission", "stream").await;
}

#[tokio::test]
async fn collected_permission_response_shares_the_caller_deadline() {
    assert_full_call_deadline("permission", "quiet").await;
}

#[tokio::test]
async fn streaming_steered_permission_timeout_leaves_the_other_turn_running() {
    assert_full_call_deadline("permission", "stream-steer").await;
}

#[tokio::test]
async fn collected_steered_permission_timeout_leaves_the_other_turn_running() {
    assert_full_call_deadline("permission", "quiet-steer").await;
}

#[test]
fn unrepresentable_send_timeout_is_usage_without_connecting() {
    let dir = scratch("overflow-timeout");
    let out = cli(&dir, &["send", "--timeout", "18446744073709551615", "lane", "hello"]);
    fs::remove_dir_all(dir).unwrap();
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    assert!(!String::from_utf8_lossy(&out.stderr).contains("panicked"), "{}", text(&out));
}

/// The fixture accepts every connection and stalls one known RPC for three
/// seconds. It eventually answers even on the old CLI, so the regression red
/// finishes without a test-runner timeout. A lost outbox acceptance exercises
/// the replacement connection before it stalls its queue/status operation.
async fn assert_full_call_deadline(phase: &'static str, mode: &'static str) {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let dir = scratch(&format!("deadline-{phase}-{mode}"));
    let listener = tokio::net::UnixListener::bind(dir.join("acpmux.sock")).unwrap();
    let cancels = Arc::new(AtomicUsize::new(0));
    let observed_cancels = cancels.clone();
    let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
    let observed_requests = requests.clone();
    let server = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        let mut generation = 0;
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            generation += 1;
            let generation = generation;
            let cancels = cancels.clone();
            let requests = requests.clone();
            connections.spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                let mut prompt_id = None;
                while let Ok(Ok(Some(line))) = tokio::time::timeout(Duration::from_secs(3), lines.next_line()).await {
                    let msg: serde_json::Value = serde_json::from_str(&line).unwrap();
                    if msg["method"] == "session/cancel" {
                        cancels.fetch_add(1, Ordering::SeqCst);
                        if let Some(id) = prompt_id.take() {
                            let answer = json!({"jsonrpc":"2.0", "id":id, "result":{"stopReason":"cancelled"}});
                            let _ = write.write_all(format!("{answer}\n").as_bytes()).await;
                        }
                        continue;
                    }
                    let Some(id) = msg.get("id") else { continue };
                    let method = msg["method"].as_str().unwrap();
                    if method == "_acpmux/send_queue" {
                        requests.lock().unwrap().push(msg["params"]["request"]["_meta"]["acpmux"].clone());
                    }
                    if phase == "legacy" && generation > 1 && method == "_acpmux/send_queue" {
                        let response = json!({"jsonrpc":"2.0", "id":id, "error":{"code":-32601,"message":"method not found"}});
                        if write.write_all(format!("{response}\n").as_bytes()).await.is_err() { break; }
                        continue;
                    }
                    if phase == "legacy" && method == "session/prompt" {
                        requests.lock().unwrap().push(msg["params"]["_meta"]["acpmux"].clone());
                    }
                    let stall = match phase {
                        "initialize" => method == "initialize",
                        "new" => method == "session/new",
                        "info" => method == "_acpmux/info",
                        "queue" => generation > 1 && method == "_acpmux/send_queue",
                        "status" => generation > 1 && method == "_acpmux/send_status",
                        "legacy" => method == "session/prompt",
                        "permission" => false,
                        _ => unreachable!(),
                    };
                    if stall {
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                    let result = match method {
                        "initialize" => json!({}),
                        "session/new" => json!({"sessionId":"lane"}),
                        "_acpmux/info" => json!({"sessionId":"lane", "status":"ready", "turnCount":1}),
                        "_acpmux/attach" | "_acpmux/events" | "_acpmux/history" => json!({"events":[],"hasMore":false}),
                        "_acpmux/send_queue" if generation == 1 => return,
                        "_acpmux/send_queue" => json!({"deliveryId":"receipt", "status":"queued"}),
                        "_acpmux/send_status" => json!({"deliveryId":"receipt", "status":"delivered", "accepted":{"sessionId":"lane"}}),
                        "session/prompt" if phase == "permission" => {
                            prompt_id = Some(id.clone());
                            let note = json!({"jsonrpc":"2.0", "method":"_acpmux/permission_pending", "params":{
                                "sessionId":"lane", "permissionId":"permission", "request":{
                                    "toolCall":{"title":"write file"},
                                    "options":[{"optionId":"deny", "kind":"reject_once"}]
                                }
                            }});
                            if write.write_all(format!("{note}\n").as_bytes()).await.is_err() { break; }
                            continue;
                        }
                        "session/prompt" => json!({"stopReason":"end_turn"}),
                        "_acpmux/permission_respond" => {
                            // Hold this response while continuing to read: a timeout
                            // must still deliver cancellation for the caller's turn.
                            continue;
                        }
                        other => panic!("unexpected deadline fixture request: {other}"),
                    };
                    let response = json!({"jsonrpc":"2.0", "id":id, "result":result});
                    if write.write_all(format!("{response}\n").as_bytes()).await.is_err() { break; }
                }
            });
        }
    });
    let mut args = match mode {
        "run" => vec!["run", "--timeout", "1", "-n", "lane", "side effect"],
        "no-wait" => vec!["send", "--no-wait", "--timeout", "1", "lane", "side effect"],
        "no-wait-given" => vec![
            "send",
            "--no-wait",
            "--prompt-id",
            "original-prompt",
            "--timeout",
            "1",
            "lane",
            "side effect",
        ],
        "quiet" => vec!["send", "--quiet", "--timeout", "1", "lane", "side effect"],
        "stream" => vec!["send", "--timeout", "1", "lane", "side effect"],
        "quiet-steer" => {
            vec!["send", "--quiet", "--steer", "--timeout", "1", "lane", "side effect"]
        }
        "stream-steer" => vec!["send", "--steer", "--timeout", "1", "lane", "side effect"],
        _ => unreachable!(),
    };
    if phase == "permission" {
        args.splice(1..1, ["--on-permission", "deny"]);
    }
    if mode.starts_with("no-wait") {
        args.insert(0, "--json");
    }
    let started = Instant::now();
    let out = tokio::process::Command::from(cli_command(&dir, &args)).output().await.unwrap();
    let elapsed = started.elapsed();
    // The notification can still be in the socket at process exit: give the
    // reader its next scheduling turn before dropping the fixture.
    tokio::task::yield_now().await;
    server.abort();
    let _ = server.await;
    fs::remove_dir_all(dir).unwrap();
    assert_eq!(out.status.code(), Some(3), "{phase}/{mode}: {}", text(&out));
    assert!(
        elapsed < Duration::from_millis(1800),
        "{phase}/{mode} escaped deadline: {elapsed:?}; {}",
        text(&out)
    );
    if phase == "permission" {
        assert_eq!(
            observed_cancels.load(Ordering::SeqCst),
            usize::from(!mode.ends_with("-steer")),
            "{phase}/{mode}: cancellation ownership"
        );
    }
    if mode.starts_with("no-wait") {
        let requests = observed_requests.lock().unwrap();
        assert!(requests.len() >= 2, "replacement never retried queue: {requests:?}");
        let prompt = &requests[0]["promptId"];
        assert!(prompt.as_str().is_some_and(|id| !id.is_empty()), "no generated prompt id");
        for request in requests.iter().skip(1) {
            assert_eq!(&request["promptId"], prompt, "retry changed identity");
            assert_eq!(request["resend"], true, "retry did not request dedupe");
        }
        if mode == "no-wait-given" {
            assert_eq!(prompt, "original-prompt");
            assert_eq!(requests[0]["resend"], true);
        }
        let envelope = String::from_utf8_lossy(&out.stderr)
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .find(|value| value.get("error").is_some())
            .expect("no JSON error envelope");
        assert_eq!(
            &envelope["error"]["promptId"],
            prompt,
            "timeout lost accepted prompt identity: {}",
            text(&out)
        );
        assert_eq!(envelope["error"]["retryable"], true);
        if phase == "status" {
            assert_eq!(
                envelope["error"]["data"]["deliveryId"], "receipt",
                "lost accepted delivery receipt"
            );
        }
    }
}

async fn restart_wire_case(phase: &'static str, quiet: bool) -> (Output, usize, Duration) {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let dir = scratch(&format!("wire-{phase}-{quiet}"));
    let listener = tokio::net::UnixListener::bind(dir.join("acpmux.sock")).unwrap();
    let prompts = Arc::new(AtomicUsize::new(0));
    let count = prompts.clone();
    let server = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        let mut generation = 0;
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            generation += 1;
            let generation = generation;
            let count = count.clone();
            connections.spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                while let Some(line) = lines.next_line().await.unwrap() {
                    let msg: serde_json::Value = serde_json::from_str(&line).unwrap();
                    let Some(id) = msg.get("id") else { continue };
                    let method = msg["method"].as_str().unwrap();
                    if generation > 1
                        && ((phase == "attach" && method == "_acpmux/attach")
                            || (phase == "reply" && method == "_acpmux/attach" && msg["params"]["limit"].as_u64().unwrap_or(0) > 0)
                            || (phase == "paging" && method == "_acpmux/events"))
                    {
                        // Bounded so an unfixed CLI eventually exits and the red run finishes.
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                    let mut error = None;
                    let result = match method {
                        "initialize" => json!({}),
                        "_acpmux/info" => {
                            json!({"sessionId":"lane", "status":"ready", "turnCount":1})
                        }
                        "_acpmux/attach" if phase == "paging" && msg["params"]["limit"].as_u64().unwrap_or(0) > 0 => {
                            json!({"events":[{"seq":100,"kind":"transcript","msg":{}}], "hasMore":true})
                        }
                        "_acpmux/attach" | "_acpmux/events" | "_acpmux/history" => {
                            json!({"events":[], "hasMore":false})
                        }
                        "session/prompt" => {
                            count.fetch_add(1, Ordering::SeqCst);
                            if phase == "collision" {
                                error = Some(
                                    json!({"code":-32603,"message":"daemon connection closed"}),
                                );
                            } else if generation == 1 {
                                return; // accepted prompt loses its acknowledgement
                            }
                            json!({"stopReason":"end_turn","_meta":{"acpmux":{"turnId":"turn"}}})
                        }
                        other => panic!("unexpected wire request: {other}"),
                    };
                    let response = match error {
                        Some(error) => json!({"jsonrpc":"2.0","id":id,"error":error}),
                        None => json!({"jsonrpc":"2.0","id":id,"result":result}),
                    };
                    if write.write_all(format!("{response}\n").as_bytes()).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    let mut args = vec!["send", "--timeout", "1", "lane", "side effect"];
    if quiet {
        args.insert(1, "--quiet");
    }
    let started = Instant::now();
    let out = tokio::process::Command::from(cli_command(&dir, &args)).output().await.unwrap();
    let elapsed = started.elapsed();
    server.abort();
    let _ = server.await;
    let count = prompts.load(Ordering::SeqCst);
    fs::remove_dir_all(dir).unwrap();
    (out, count, elapsed)
}

#[test]
fn collected_reply_survives_an_active_turn_restart() {
    let dir = scratch("collect-restart");
    let _shutdown = Shutdown(&dir);
    let mut daemon = start_custom_daemon(&dir, &[]);
    let made = cli(&dir, &["new", "-d", "-n", "lane", "-m", "fake"]);
    assert!(made.status.success(), "{}", text(&made));
    let gate = dir.join("gate");
    let gate_c = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: test-owned path, valid C string.
    assert_eq!(unsafe { libc::mkfifo(gate_c.as_ptr(), 0o600) }, 0);
    let writer = fs::OpenOptions::new().read(true).write(true).open(&gate).unwrap();
    let prompt = format!("gate: {}", gate.display());
    let send = cli_command(&dir, &["--json", "send", "--timeout", "10", "lane", &prompt])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let waiting = cli(&dir, &["wait", "lane", "--match", "before-gate", "--timeout", "5"]);
    assert!(waiting.status.success(), "{}", text(&waiting));
    daemon.stop();
    let started = cli(&dir, &["daemon", "start"]);
    assert!(started.status.success(), "{}", text(&started));
    drop(writer);
    let out = send.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", text(&out));
    let result: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(result["reply"], "before-gateafter-gate");
}
