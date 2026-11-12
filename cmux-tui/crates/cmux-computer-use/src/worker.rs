//! The Computer Use worker's control channel (Linux and Windows: the
//! `cmux-tui __computer-use-worker` mode, started and supervised by the
//! cmux-tui daemon). JSON lines on stdin (host to worker) and stdout
//! (worker to host):
//!
//! ```text
//! -> {"type":"configure","config":<PolicyConfig>,"socket":PATH,"secret":HEX,"state_dir":PATH,"machine":NAME}
//! <- {"type":"ready","pid":N,"socket":PATH}       or {"type":"unavailable","reason":R}
//! -> {"type":"config","config":<PolicyConfig>}
//! -> {"type":"approvals","action":"forget|always|never","app_id":ID}
//! -> {"type":"approvals","action":"revoke_sessions"}
//! -> {"type":"approvals","action":"list","id":N}
//! <- {"type":"approvals","id":N,"saved":{"always":[...],"never":[...]}}
//! <- {"type":"ask","id":N,"question":{"session","agent","app":{"id","name"},"remember","from_machine"}}
//! -> {"type":"answer","id":N,"answer":"allow_once|allow_session|always|deny|never|unavailable"}
//! -> {"type":"session","action":"stop|resume","session":S,"label":L}
//! ```
//!
//! The worker serves the agent socket ([`crate::server`]) until stdin
//! closes, then stops serving and exits. A question nobody answers in
//! [`ASK_TIMEOUT`] is `unavailable` (the call is refused, nothing is saved).
//! Grants and saved approvals live in `state_dir`, so a restarted worker
//! keeps them.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};

use crate::cursor::{CursorSink, NoCursor};
use crate::desktop::Desktop;
use crate::engine::{Answer, Approver, Engine, EngineParts, NoTakeover, PersonActivity, Question};
use crate::policy::PolicyConfig;
use crate::wire;

/// How long a question waits for the person.
pub const ASK_TIMEOUT: Duration = Duration::from_secs(120);

/// Exit codes.
pub const EXIT_OK: i32 = 0;
pub const EXIT_BAD_CONFIGURE: i32 = 2;
pub const EXIT_UNAVAILABLE: i32 = 3;

type Out = Arc<Mutex<Box<dyn Write + Send>>>;

fn emit(out: &Out, value: &Value) {
    let mut out = out.lock().unwrap_or_else(PoisonError::into_inner);
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

/// Sends questions upstream and waits for their answers.
struct StdioApprover {
    out: Out,
    pending: Mutex<HashMap<u64, SyncSender<Answer>>>,
    next: AtomicU64,
    timeout: Duration,
}

impl StdioApprover {
    fn answer(&self, id: u64, answer: Answer) {
        if let Some(waiting) =
            self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id)
        {
            let _ = waiting.send(answer);
        }
    }
    /// stdin closed: every open question is unavailable.
    fn close(&self) {
        for (_, waiting) in self.pending.lock().unwrap_or_else(PoisonError::into_inner).drain() {
            let _ = waiting.send(Answer::Unavailable);
        }
    }
}

impl Approver for StdioApprover {
    fn ask(&self, q: &Question) -> Answer {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = sync_channel(1);
        self.pending.lock().unwrap_or_else(PoisonError::into_inner).insert(id, tx);
        emit(
            &self.out,
            &json!({"type": "ask", "id": id, "question": {
                "session": q.session, "agent": q.agent,
                "app": {"id": q.app.id, "name": q.app.name},
                "remember": q.remember, "from_machine": q.from_machine,
            }}),
        );
        let answer = rx.recv_timeout(self.timeout).unwrap_or(Answer::Unavailable);
        self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
        answer
    }
}

pub fn parse_answer(text: &str) -> Answer {
    match text {
        "allow_once" => Answer::AllowOnce,
        "allow_session" => Answer::AllowSession,
        "always" => Answer::AlwaysAllow,
        "deny" => Answer::Deny,
        "never" => Answer::Never,
        _ => Answer::Unavailable,
    }
}

pub fn answer_name(answer: Answer) -> &'static str {
    match answer {
        Answer::AllowOnce => "allow_once",
        Answer::AllowSession => "allow_session",
        Answer::AlwaysAllow => "always",
        Answer::Deny => "deny",
        Answer::Never => "never",
        Answer::Unavailable => "unavailable",
    }
}

/// The platform pieces the worker builds its engine from.
pub struct Platform {
    pub desktop: Arc<dyn Desktop>,
    pub cursor: Arc<dyn CursorSink>,
    pub takeover: Arc<dyn PersonActivity>,
}

/// This machine's desktop, or why there is none. Debug and test builds
/// honor `CMUX_CU_FAKE_DESKTOP=1` (the in-memory desktop, for end-to-end
/// tests of the worker); release builds never do.
pub fn platform() -> Result<Platform, String> {
    #[cfg(debug_assertions)]
    if std::env::var_os("CMUX_CU_FAKE_DESKTOP").is_some_and(|v| v == "1") {
        return Ok(Platform {
            desktop: Arc::new(crate::desktop::fake::FakeDesktop::standard()),
            cursor: Arc::new(NoCursor),
            takeover: Arc::new(NoTakeover),
        });
    }
    #[cfg(feature = "desktop")]
    {
        Ok(Platform {
            desktop: crate::platform::open()?,
            cursor: crate::platform::cursor_overlay(),
            takeover: crate::platform::person_activity(),
        })
    }
    #[cfg(not(feature = "desktop"))]
    {
        Err("this build of cmux has no Computer Use desktop".into())
    }
}

struct Configure {
    config: PolicyConfig,
    socket: String,
    secret: Vec<u8>,
    state_dir: Option<PathBuf>,
    machine: String,
}

fn parse_configure(v: &Value) -> Result<Configure, String> {
    if v.get("type").and_then(Value::as_str) != Some("configure") {
        return Err("the first line must be configure".into());
    }
    let config = match v.get("config") {
        Some(c) if !c.is_null() => {
            serde_json::from_value(c.clone()).map_err(|e| format!("bad config: {e}"))?
        }
        _ => PolicyConfig::default(),
    };
    let socket = v
        .get("socket")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or("socket is required")?;
    let secret = v
        .get("secret")
        .and_then(Value::as_str)
        .and_then(wire::unhex)
        .filter(|s| s.len() >= 16)
        .ok_or("secret must be at least 16 bytes of hex")?;
    let state_dir =
        v.get("state_dir").and_then(Value::as_str).filter(|s| !s.is_empty()).map(PathBuf::from);
    let machine = v.get("machine").and_then(Value::as_str).unwrap_or_default().to_string();
    Ok(Configure { config, socket: socket.to_string(), secret, state_dir, machine })
}

fn prepare_state_dir(dir: &std::path::Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        crate::server::private_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))
    }
}

/// Runs the worker on the given control channel with this machine's desktop.
pub fn run_stdio(input: impl BufRead, output: impl Write + Send + 'static) -> i32 {
    run(input, output, platform, ASK_TIMEOUT)
}

/// [`run_stdio`] with the platform and the question timeout given (tests).
pub fn run(
    mut input: impl BufRead,
    output: impl Write + Send + 'static,
    platform: impl FnOnce() -> Result<Platform, String>,
    ask_timeout: Duration,
) -> i32 {
    let out: Out = Arc::new(Mutex::new(Box::new(output)));
    let mut line = String::new();
    let configure = match input.read_line(&mut line) {
        Ok(n) if n > 0 => serde_json::from_str::<Value>(&line)
            .map_err(|e| format!("configure is not JSON: {e}"))
            .and_then(|v| parse_configure(&v)),
        _ => return EXIT_OK,
    };
    let configure = match configure {
        Ok(c) => c,
        Err(reason) => {
            emit(&out, &json!({"type": "error", "reason": reason}));
            return EXIT_BAD_CONFIGURE;
        }
    };
    // The Linux portal keeps its restore token next to the grants, so the
    // person approves screen access once; set before the desktop opens.
    #[cfg(all(target_os = "linux", feature = "desktop"))]
    if let Some(dir) = &configure.state_dir {
        crate::platform::linux::set_state_dir(dir.clone());
    }
    let platform = match platform() {
        Ok(p) => p,
        Err(reason) => {
            emit(&out, &json!({"type": "unavailable", "reason": reason}));
            return EXIT_UNAVAILABLE;
        }
    };
    if let Some(dir) = &configure.state_dir
        && let Err(reason) = prepare_state_dir(dir)
    {
        emit(&out, &json!({"type": "unavailable", "reason": reason}));
        return EXIT_UNAVAILABLE;
    }
    let approver = Arc::new(StdioApprover {
        out: Arc::clone(&out),
        pending: Mutex::new(HashMap::new()),
        next: AtomicU64::new(1),
        timeout: ask_timeout,
    });
    let mut parts = EngineParts::new(platform.desktop);
    parts.config = configure.config;
    parts.state_dir = configure.state_dir;
    parts.cursor = platform.cursor;
    parts.takeover = platform.takeover;
    parts.approver = approver.clone();
    parts.machine_name = configure.machine;
    let engine = Arc::new(Engine::new(parts));
    let server = match crate::server::serve(
        Arc::clone(&engine),
        &configure.socket,
        &configure.secret,
    ) {
        Ok(server) => server,
        Err(error) => {
            emit(
                &out,
                &json!({"type": "unavailable", "reason": format!("cannot serve {}: {error}", configure.socket)}),
            );
            return EXIT_UNAVAILABLE;
        }
    };
    emit(&out, &json!({"type": "ready", "pid": std::process::id(), "socket": configure.socket}));
    loop {
        line.clear();
        match input.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        control(&engine, &approver, &out, &message);
    }
    approver.close();
    server.stop();
    EXIT_OK
}

fn control(engine: &Engine, approver: &StdioApprover, out: &Out, message: &Value) {
    match message.get("type").and_then(Value::as_str).unwrap_or_default() {
        "config" => {
            if let Some(Ok(config)) =
                message.get("config").map(|c| serde_json::from_value::<PolicyConfig>(c.clone()))
            {
                engine.set_config(config);
            }
        }
        "approvals" => {
            let app = message.get("app_id").and_then(Value::as_str).unwrap_or_default();
            let sessions = engine.sessions();
            match message.get("action").and_then(Value::as_str).unwrap_or_default() {
                "forget" if !app.is_empty() => sessions.update_saved(|s| s.forget(app)),
                "always" if !app.is_empty() => sessions.update_saved(|s| s.set_always(app)),
                "never" if !app.is_empty() => sessions.update_saved(|s| s.set_never(app)),
                "revoke_sessions" => sessions.revoke_all(None),
                "list" => emit(
                    out,
                    &json!({"type": "approvals", "id": message.get("id"), "saved": sessions.saved()}),
                ),
                _ => {}
            }
        }
        // The person's Stop or Resume of one agent session (the cmux menu bar).
        "session" => {
            let session = message.get("session").and_then(Value::as_str).unwrap_or_default();
            let label = message.get("label").and_then(Value::as_str).unwrap_or_default();
            if !session.is_empty() {
                match message.get("action").and_then(Value::as_str).unwrap_or_default() {
                    "stop" => {
                        engine.stop_session(session, label);
                    }
                    "resume" => {
                        engine.resume_session(session);
                    }
                    _ => {}
                }
            }
        }
        "answer" => {
            if let Some(id) = message.get("id").and_then(Value::as_u64) {
                let answer = message
                    .get("answer")
                    .and_then(Value::as_str)
                    .map_or(Answer::Unavailable, parse_answer);
                approver.answer(id, answer);
            }
        }
        _ => {}
    }
}

#[cfg(all(test, unix))]
#[path = "worker_tests.rs"]
mod tests;
