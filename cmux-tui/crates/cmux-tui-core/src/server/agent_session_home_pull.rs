//! A fresh Cloud chat starts with the person's agent home (hq
//! `plans/cloud/agent-memory-follows-user.md`, step 5): on the caller's own Cloud VM,
//! `agent-session-start` asks the machine's agent (cmux-host, root) to pull the person's
//! user-wide carried files (their `~/.claude/CLAUDE.md`) into this home, and the harness is
//! spawned (`session/new`) only after that pull answered or ran out of time.
//!
//! The pull starts with the start and runs beside acpmux's connect and catalog read, so most of
//! it costs the start nothing. The start waits for it at most [`PULL_WAIT`] (cmux-host stops the
//! pull itself at 5 s). It is refused only when the pull left files the person revoked in place
//! (cmux-host's `refuse`, the pull's exit 1). Any other failure is noted in the answer, and the
//! chat starts with the home it has.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Refusal;

/// The machine agent's socket (cmux-host `cloud/wire.rs`).
pub(super) const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// The ask's key (cmux-host `cloud/agent_home_pull.rs`).
pub(super) const REQUEST_KEY: &str = "agent_home_pull";
/// The longest a start waits for the pull: cmux-host's own 5 s bound, plus its bearer mint
/// and the reply.
pub(super) const PULL_WAIT: Duration = Duration::from_secs(7);
const MAX_REPLY: u64 = 64 * 1024;

/// One pull, answered with cmux-host's reply line (or what stood in for it).
pub(crate) type AgentHomePuller = Arc<dyn Fn() -> Value + Send + Sync>;

/// The pull through the machine agent's socket.
pub(super) fn socket_puller() -> AgentHomePuller {
    Arc::new(|| ask_socket(Path::new(AGENT_SOCKET), PULL_WAIT))
}

/// One `{"agent_home_pull": {}}` line on `socket`, and its one reply line.
pub(super) fn ask_socket(socket: &Path, timeout: Duration) -> Value {
    let unreachable = |why: &str| json!({"ok": false, "refuse": false, "code": "agent_home.unreachable", "message": why});
    let Ok(mut stream) = UnixStream::connect(socket) else {
        return unreachable("this machine's agent is not listening");
    };
    if stream.set_read_timeout(Some(timeout)).is_err()
        || stream.set_write_timeout(Some(timeout)).is_err()
    {
        return unreachable("this machine's agent socket could not be set up");
    }
    if writeln!(stream, "{}", json!({REQUEST_KEY: {}})).is_err() {
        return unreachable("this machine's agent did not take the ask");
    }
    let mut line = String::new();
    if BufReader::new(stream).take(MAX_REPLY).read_line(&mut line).is_err() || !line.ends_with('\n')
    {
        return unreachable("this machine's agent did not answer");
    }
    serde_json::from_str(&line)
        .unwrap_or_else(|_| unreachable("this machine's agent answered something else"))
}

/// A pull in flight beside the start.
pub(super) struct HomePull {
    answer: mpsc::Receiver<Value>,
    began: Instant,
}

/// How a pull ended for the start: the ms from its beginning to its answer (or the wait's end),
/// and what the start's answer says of it.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Pulled {
    pub ms: u64,
    pub note: Value,
    pub refuse: bool,
}

impl HomePull {
    /// Starts `pull` on its own thread; None when the thread cannot start (the start goes on).
    pub(super) fn begin(pull: AgentHomePuller) -> Option<HomePull> {
        let (tx, answer) = mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("mux-agent-home-pull".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                let _ = tx.send(pull());
            })
            .ok()?;
        Some(HomePull { answer, began: Instant::now() })
    }

    /// Waits for the pull until `wait` after it began.
    pub(super) fn finish(self, wait: Duration) -> Pulled {
        let left = wait.saturating_sub(self.began.elapsed());
        let answer = self.answer.recv_timeout(left).ok();
        let ms = u64::try_from(self.began.elapsed().as_millis()).unwrap_or(u64::MAX);
        let Some(answer) = answer else {
            return Pulled {
                ms,
                note: json!({"ok": false, "code": "agent_home.timeout"}),
                refuse: false,
            };
        };
        let refuse = answer.get("refuse").and_then(Value::as_bool) == Some(true);
        let mut note = serde_json::Map::new();
        for key in ["ok", "code", "exit", "ms"] {
            if let Some(value) = answer.get(key) {
                note.insert(key.to_owned(), value.clone());
            }
        }
        note.entry("ok").or_insert(json!(false));
        Pulled { ms, note: Value::Object(note), refuse }
    }
}

/// The pull, then the spawn: `spawn` runs only after the pull answered (or its wait ended),
/// and never when the pull left revoked files in place. `noted` gets how the pull ended.
pub(super) fn then_spawn<T>(
    pull: Option<HomePull>,
    noted: &mut Option<Pulled>,
    spawn: impl FnOnce() -> Result<T, (Refusal, Option<Value>)>,
) -> Result<T, (Refusal, Option<Value>)> {
    if let Some(pull) = pull {
        let pulled = pull.finish(PULL_WAIT);
        let refuse = pulled.refuse;
        let note = pulled.note.clone();
        *noted = Some(pulled);
        if refuse {
            return Err((Refusal::AgentHomeNotCleared, Some(json!({"agent_home": note}))));
        }
    }
    spawn()
}
