//! Fuzz row g finding g1: a prompt that comes while the chat's previous prompt holds the turn
//! lock but has not shown its turn yet hears no `_acpmux/prompt_accepted` until that whole turn
//! ends.
//!
//! `Hub::queue_slot` (`hub/queue.rs`) decides `waiting` from `session.turn()` and the queue
//! count. A prompt that started a moment before holds `turn_lock` but sets its turn only later,
//! in `start_turn` (`hub/turns.rs`), after the awaits of `check_dispatch`,
//! `family_dispatch_check` and `hold_retry_start`. A second prompt in that window sees no turn
//! and no queue, so it does not enqueue (no `queued` acceptance) and waits on
//! `turn_lock.lock().await` for the first prompt's whole turn. A long turn (here one that runs
//! until it is cancelled) leaves that sender with no answer at all: the fuzz saw `session/prompt`
//! wait 20.5 to 22.1 s (its read timeout) in 12 of about 12,000 operations (fleet job
//! ea2a7c69880bc22c2df33873, seeds 26370, 26371, 26372, 26385, 26387, 26401, 26402).
//!
//! The control test sends the second prompt after the first turn shows: it is accepted
//! (queued) at once. The race test sends both prompts in one write, as two clients can.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents (tests/fake_agent.py).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

/// How long a prompt may wait for its acceptance (fuzz row g's budget).
const ACCEPT_BUDGET: Duration = Duration::from_secs(2);

struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: Child,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-g1-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("p")).unwrap();
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}},
                            "defaultHarness": "fake", "permissionPolicy": "approve-all",
                            "agentInbox": false, "autoResumeDelaysMs": []});
        std::fs::write(home.join("config.json"), config.to_string()).unwrap();
        std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let socket = home.join("s.sock");
        let child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            // No agent hosts: a host outlives its daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(home.join("p"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon did not listen");
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { home, socket, child }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the unreaped daemon child this test started.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGKILL) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        let mut c = Self { reader, writer: stream, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "fuzz-g1"}});
        c.call("initialize", hello);
        c
    }

    fn line(&mut self, method: &str, params: Value) -> String {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        format!("{line}\n")
    }

    /// The next message, or None when none came within the read timeout.
    fn read(&mut self) -> Option<Value> {
        let mut text = String::new();
        match self.reader.read_line(&mut text) {
            Ok(0) => panic!("the daemon closed the socket"),
            Ok(_) => Some(serde_json::from_str(&text).unwrap()),
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => None,
            Err(e) => panic!("read: {e}"),
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let line = self.line(method, params);
        let id = self.next;
        self.writer.write_all(line.as_bytes()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            if let Some(v) = self.read()
                && v.get("method").is_none()
                && v["id"] == id
            {
                assert!(v.get("error").is_none(), "{method}: {v}");
                return v["result"].clone();
            }
        }
        panic!("{method}: no answer in 30 s");
    }

    /// Waits up to `budget` for a message that `matches`; how long it took.
    fn wait_for(&mut self, budget: Duration, matches: impl Fn(&Value) -> bool) -> Option<Duration> {
        let began = Instant::now();
        while began.elapsed() < budget {
            if let Some(v) = self.read()
                && matches(&v)
            {
                return Some(began.elapsed());
            }
        }
        None
    }
}

fn prompt(session: &str, text: &str, pid: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": pid, "steer": false}}})
}

fn accepted(pid: &str) -> impl Fn(&Value) -> bool + '_ {
    move |v: &Value| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == pid
}

fn new_chat(client: &mut Client, daemon: &Daemon) -> String {
    let made = client.call("session/new", json!({"cwd": daemon.home.join("p"), "mcpServers": []}));
    made["sessionId"].as_str().unwrap().to_owned()
}

/// Control: the second prompt comes once the first prompt's turn shows. It queues and is
/// accepted at once.
#[test]
fn fuzz_g1_control_a_prompt_behind_a_running_turn_is_accepted_at_once() {
    let daemon = Daemon::start("ctl");
    let mut client = Client::connect(&daemon.socket);
    let id = new_chat(&mut client, &daemon);
    let first = client.line("session/prompt", prompt(&id, "until-cancel", "g1-ctl-a"));
    client.writer.write_all(first.as_bytes()).unwrap();
    let running = client.wait_for(Duration::from_secs(30), |v| {
        v["method"] == "session/update" && v["params"]["update"]["content"]["text"] == "running"
    });
    assert!(running.is_some(), "the first turn did not start");
    let second = client.line("session/prompt", prompt(&id, "after", "g1-ctl-b"));
    client.writer.write_all(second.as_bytes()).unwrap();
    let took = client.wait_for(ACCEPT_BUDGET, accepted("g1-ctl-b"));
    assert!(took.is_some(), "a prompt behind a running turn was not accepted within 2 s");
}

/// The race: the second prompt comes while the first one holds the turn lock and has not shown
/// its turn yet. It must be accepted (queued) within 2 s like any other; it hears nothing until
/// the first turn ends, which here is never.
#[test]
fn fuzz_g1_a_prompt_right_behind_another_is_accepted_within_two_seconds() {
    let daemon = Daemon::start("race");
    let mut client = Client::connect(&daemon.socket);
    let trials = 20;
    let mut silent = Vec::new();
    for n in 0..trials {
        let id = new_chat(&mut client, &daemon);
        let (a, b) = (format!("g1-a-{n}"), format!("g1-b-{n}"));
        // Both prompts in one write: the daemon reads and dispatches them back to back.
        let both = client.line("session/prompt", prompt(&id, "until-cancel", &a))
            + &client.line("session/prompt", prompt(&id, "behind", &b));
        client.writer.write_all(both.as_bytes()).unwrap();
        if client.wait_for(ACCEPT_BUDGET, accepted(&b)).is_none() {
            let info = client.call("_acpmux/info", json!({"sessionId": id}));
            silent.push(format!(
                "trial {n}: no prompt_accepted for {b} in 2 s (status {}, queued {}, queue {})",
                info["status"], info["queued"], info["queue"]
            ));
        }
    }
    println!("FUZZ-G1 silent={} of {trials}", silent.len());
    assert!(
        silent.is_empty(),
        "{} of {trials} prompts sent right behind another got no acceptance:\n{}",
        silent.len(),
        silent.join("\n")
    );
}

/// The acceptance of a prompt right behind another says what happened to it: queued, next in
/// line (`state: "queued"`, `position: 1`), while the other's says its turn started. Which of
/// the two the daemon takes first is its choice: both come in one write.
#[test]
fn fuzz_g1_a_prompt_right_behind_another_is_accepted_queued_next() {
    let daemon = Daemon::start("state");
    let mut client = Client::connect(&daemon.socket);
    let id = new_chat(&mut client, &daemon);
    let both = client.line("session/prompt", prompt(&id, "until-cancel", "g1-s-a"))
        + &client.line("session/prompt", prompt(&id, "until-cancel", "g1-s-b"));
    client.writer.write_all(both.as_bytes()).unwrap();
    let mut seen: Vec<Value> = Vec::new();
    let began = Instant::now();
    while began.elapsed() < Duration::from_secs(30) && seen.len() < 2 {
        if let Some(v) = client.read()
            && v["method"] == "_acpmux/prompt_accepted"
        {
            seen.push(v["params"].clone());
        }
    }
    assert_eq!(seen.len(), 2, "both prompts are accepted: {seen:?}");
    let started: Vec<_> = seen.iter().filter(|p| p["state"] == "started").collect();
    let queued: Vec<_> = seen.iter().filter(|p| p["state"] == "queued").collect();
    assert_eq!((started.len(), queued.len()), (1, 1), "one started, one queued: {seen:?}");
    assert_eq!(started[0]["queued"], json!(false), "{seen:?}");
    assert_eq!(
        (&queued[0]["queued"], &queued[0]["position"]),
        (&json!(true), &json!(1)),
        "{seen:?}"
    );
}
