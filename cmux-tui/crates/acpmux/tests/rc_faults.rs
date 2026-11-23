//! Remote and Cloud faults on a real acpmux daemon (cmuxterm-hq
//! `docs/design/remote-cloud-durability.md`, section 5), through the `cmux-fault` harness.
//!
//! - `disk_full_mid_turn_loses_nothing` (F20): the disk fills (ENOSPC or EDQUOT, the store's debug
//!   seam `ACPMUX_TEST_DISK_FAULT_FILE`) while a turn streams. The daemon stays up; once space
//!   returns the next prompt works, the turn's words are stored exactly once, and what the client
//!   read equals what a restarted daemon reads back from the journal. Known red (its ignore says
//!   why); lane `rc-supervisor-contract` flips it.
//!
//! ```text
//! cargo test -p acpmux --test rc_faults -- --nocapture --include-ignored   # CMUX_FAULT_RUNS (20)
//! CMUX_FAULT_SEED=3 cargo test -p acpmux --test rc_faults disk_full -- --nocapture --include-ignored
//! ```
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents (tests/fake_agent.py); the fault harness reads its seeds from these.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "CMUX_FAULT_RUNS",
    "CMUX_FAULT_SEED",
    "CMUX_FAULT_SEED_BASE",
    "CMUX_FAULT_PARALLEL",
]);

use std::collections::HashMap;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

use cmux_fault::disk::{DiskFault, Full};
use cmux_fault::invariants;
use cmux_fault::process::Recorded;
use cmux_fault::{Failed, Rng, Runs, Trace};
use serde_json::{Value, json};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const ANSWER_BOUND: Duration = Duration::from_secs(30);

struct Daemon {
    home: PathBuf,
    /// Where every start of the daemon appends its stderr (outside the home, so a failing run
    /// still reads it after the home is gone).
    log: PathBuf,
    socket: PathBuf,
    env: Vec<(String, PathBuf)>,
    child: Option<Child>,
    trace: Trace,
}

impl Daemon {
    fn new(tag: &str, log: PathBuf, env: &[(&str, &Path)], trace: &Trace) -> Self {
        use std::os::unix::fs::PermissionsExt;
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-rcf-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("p")).unwrap();
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
        let config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}},
                            "defaultHarness": "fake", "permissionPolicy": "approve-all",
                            "agentInbox": false, "autoResumeDelaysMs": []});
        std::fs::write(home.join("config.json"), config.to_string()).unwrap();
        let socket = home.join("s.sock");
        let env = env.iter().map(|(k, v)| (k.to_string(), v.to_path_buf())).collect();
        let mut daemon = Self { home, log, socket, env, child: None, trace: trace.clone() };
        daemon.start();
        daemon
    }

    fn log(&self) -> Stdio {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log)
            .map_or_else(|_| Stdio::null(), Stdio::from)
    }

    fn start(&mut self) {
        assert!(self.child.is_none());
        let child = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "info"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .current_dir(self.home.join("p"))
            .stdin(Stdio::null())
            .stdout(self.log())
            .stderr(self.log())
            .spawn()
            .unwrap();
        self.trace.note(format!("acpmux started (pid {})", child.id()));
        self.child = Some(child);
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon did not listen");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn recorded(&self) -> Recorded {
        Recorded::child(self.child.as_ref().unwrap(), "acpmux", &self.trace)
    }

    /// The daemon's exit, if it ended.
    fn exited(&mut self) -> Option<std::process::ExitStatus> {
        self.child.as_mut().and_then(|child| child.try_wait().unwrap())
    }

    /// An orderly stop (SIGTERM) and the wait for it.
    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SAFETY: the unreaped daemon child this test started.
            unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
            let deadline = Instant::now() + Duration::from_secs(15);
            while child.try_wait().unwrap().is_none() {
                if Instant::now() > deadline {
                    let _ = child.kill();
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            self.trace.note("acpmux stopped");
        }
    }

    fn client(&self) -> Client {
        Client::connect(&self.socket)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // End every agent host this daemon started (they outlive it by design).
        if let Ok(dir) = std::fs::read_dir(self.home.join("hosts")) {
            for path in dir.filter_map(|e| e.ok().map(|e| e.path())) {
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                let record: Value =
                    serde_json::from_slice(&std::fs::read(&path).unwrap_or_default())
                        .unwrap_or_default();
                for pid in [record["harness_pid"].as_i64(), record["host_pid"].as_i64()]
                    .into_iter()
                    .flatten()
                {
                    // SAFETY: process groups this test's daemon created.
                    unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

/// A JSON-RPC client over the daemon's socket that keeps every answer it reads, so a prompt sent
/// early is answered whenever its answer comes.
struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
    answers: HashMap<u64, Value>,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        let mut client = Self { reader, writer: stream, next: 0, answers: HashMap::new() };
        client.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "rcf"}}));
        client
    }

    fn send(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        self.next
    }

    /// The answer to request `id` (`result` or `error`) within `wait`.
    fn answer(&mut self, id: u64, wait: Duration) -> Option<Value> {
        let deadline = Instant::now() + wait;
        loop {
            if let Some(answer) = self.answers.remove(&id) {
                return Some(answer);
            }
            if Instant::now() >= deadline {
                return None;
            }
            let mut text = String::new();
            match self.reader.read_line(&mut text) {
                Ok(0) => return None,
                Ok(_) => {
                    let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
                    if v.get("method").is_none()
                        && let Some(id) = v["id"].as_u64()
                    {
                        self.answers.insert(id, v);
                    }
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(_) => return None,
            }
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        let answer = self
            .answer(id, ANSWER_BOUND)
            .unwrap_or_else(|| panic!("{method}: no answer in {ANSWER_BOUND:?}"));
        assert!(answer.get("error").is_none(), "{method}: {answer}");
        answer["result"].clone()
    }

    /// The chat's agent words, in order, with their seqs.
    fn words(&mut self, session: &str) -> Vec<(u64, String)> {
        let page = self.call(
            "_acpmux/events",
            json!({"sessionId": session, "kinds": ["agent_message_chunk"], "limit": 10000}),
        );
        page["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| {
                let text = e.pointer("/msg/params/update/content/text")?.as_str()?;
                Some((e["seq"].as_u64()?, text.to_owned()))
            })
            .collect()
    }
}

/// The last `lines` lines of a log, indented under a failure.
fn log_tail(path: &Path, lines: usize) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let all: Vec<&str> = text.lines().collect();
    all[all.len().saturating_sub(lines)..].iter().map(|line| format!("    {line}\n")).collect()
}

fn prompt(session: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]})
}

/// F20: the disk fills while a turn streams (between its first and its last words) and stays full
/// for a seeded while, then space returns. The daemon never exits; the turn is answered; the next
/// prompt runs; every word the agent said is stored once; and what the client read equals what a
/// restarted daemon reads from its journal.
///
/// Red on feat-cmux-next, 20 of 20 seeds (cmux run 43881964417): the daemon stays up, but the
/// turn's last words and its answer never reach the client, and the prompt sent after space
/// returned is never answered (60 s). The agent's host kept them: a restarted daemon reads
/// "after-gate" from the journal. The live daemon's link to the host broke on the entry it could
/// not log, and the reattach that replays it waits for the next request, which queues behind the
/// turn that never ends. Lane `rc-supervisor-contract` (piece P1, F20) makes it pass and removes
/// the ignore.
#[test]
#[ignore = "rc-supervisor-contract: after a full disk mid-turn the live daemon never reattaches \
            the agent's host, so the turn and the next prompt hang until a restart (F20)"]
fn disk_full_mid_turn_loses_nothing() -> Result<(), Failed> {
    let replay = "cargo test -p acpmux --test rc_faults disk_full";
    Runs::new("disk-full mid-turn", replay).at_most_parallel(4).run(|seed, trace| {
        let mut rng = Rng::new(seed);
        let full = *rng.pick(&[Full::NoSpace, Full::Quota]);
        let before_words = Duration::from_millis(rng.range(0, 300));
        let held = Duration::from_millis(rng.range(300, 1_500));

        let scratch = PathBuf::from("/tmp").join(format!("amx-rcf-d{seed}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).unwrap();
        let disk = DiskFault::new(&scratch, trace);
        let log = scratch.join("acpmux.log");
        let mut daemon = Daemon::new(&format!("{seed}"), log, &[disk.env()], trace);
        let pid = daemon.recorded();
        let mut client = daemon.client();
        let session = client.call(
            "session/new",
            json!({"cwd": daemon.home.join("p"), "mcpServers": [],
                   "_meta": {"acpmux": {"harness": "fake"}}}),
        )["sessionId"]
            .as_str()
            .unwrap()
            .to_owned();

        let fifo = scratch.join("gate");
        let made = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: a path this run owns.
        assert_eq!(unsafe { libc::mkfifo(made.as_ptr(), 0o600) }, 0);
        let gated =
            client.send("session/prompt", prompt(&session, &format!("gate: {}", fifo.display())));
        // The turn has begun once its first words are stored.
        let begun = Instant::now() + ANSWER_BOUND;
        while !client.words(&session).iter().any(|(_, text)| text == "before-gate") {
            if Instant::now() > begun {
                return Err("the turn never began".into());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        disk.fill(full).map_err(|e| format!("set the disk switch: {e}"))?;
        std::thread::sleep(before_words);
        // Opening the FIFO waits for the agent, which holds it open for reading.
        std::fs::write(&fifo, "go").unwrap();
        trace.note("the agent says its last words and ends the turn");
        std::thread::sleep(held);
        let up_while_full = daemon.exited();
        disk.free();
        if let Some(status) = up_while_full {
            return Err(format!("acpmux exited while the disk was full: {status}"));
        }
        if !pid.alive() {
            return Err("acpmux is gone while the disk was full".into());
        }

        let next = client.send("session/prompt", prompt(&session, "after-space"));
        let next = client.answer(next, ANSWER_BOUND);
        let gated = client.answer(gated, ANSWER_BOUND);
        trace.note(format!("gated prompt answered: {gated:?}; next: {next:?}"));
        let seen = client.words(&session);
        trace.note(format!("the client read {seen:?}"));
        let exited = daemon.exited();

        daemon.stop();
        daemon.start();
        let journal = daemon.client().words(&session);
        trace.note(format!("the journal holds {journal:?}"));
        daemon.stop();
        drop(daemon);
        let daemon_log = log_tail(&scratch.join("acpmux.log"), 40);
        let _ = std::fs::remove_dir_all(&scratch);

        let texts =
            |words: &[(u64, String)]| words.iter().map(|(_, t)| t.clone()).collect::<Vec<_>>();
        let held = invariants::all([
            match exited {
                None => Ok(()),
                Some(status) => Err(format!("acpmux exited after space returned: {status}")),
            },
            match gated {
                Some(answer) if answer.get("error").is_none() => Ok(()),
                Some(answer) => Err(format!("the turn the disk filled in failed: {answer}")),
                None => Err("the turn the disk filled in was never answered".into()),
            },
            match next {
                Some(answer) if answer.get("error").is_none() => Ok(()),
                Some(answer) => Err(format!("the prompt after space returned failed: {answer}")),
                None => Err("the prompt after space returned was never answered".into()),
            },
            invariants::each_once(
                &["before-gate".to_owned(), "after-gate".to_owned(), "after-space".to_owned()],
                &texts(&journal),
            ),
            invariants::client_equals_journal(&journal, &seen),
        ]);
        held.map_err(|why| format!("{why}\n  daemon log (tail):\n{daemon_log}"))
    })
}
