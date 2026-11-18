//! `cmux repo mcp-lazy DIR -- CMD [ARG...]`: a project MCP server (a `.mcp.json` stdio entry)
//! that runs only once the checkout at DIR is whole. Claude Code holds its first turn until each
//! server answers `initialize`, and starts a project's servers outside the tool gate, so a start at
//! a repository's head (`cmux repo hold`) could neither run them on the partial tree nor wait for
//! them. acpmux passes each such server under its own name in `--mcp-config`, wrapped in this
//! (`acpmux::agent_tools::project_mcp`), which replaces the project's entry.
//!
//! This answers `initialize` at once with tools that may change (`listChanged`), and every list
//! empty. Once the barrier on DIR is open (the wait `cmux repo wait` uses), it starts CMD in DIR,
//! sends it the client's `initialize` under its own id ([`INIT_ID`]: the client's was answered
//! here), then the client's other lines, and tells the client its tools changed. From then on it
//! relays lines both ways. A request that came before (a call) waits for the server. A barrier
//! that fails leaves the lists empty, refuses calls, and says why on stderr. It ends with the
//! server, or once the client closes stdin and the server ends; a client that closes it before
//! the checkout is whole ends the wait too, and no server starts; one that closes it while the
//! server has not answered `initialize` ends the server. The server runs on a scoped thread of
//! [`proxy`], joined before it returns.
//!
//! What only `initialize` carries cannot reach the client: Claude reads it once, from the answer
//! given here, and MCP has no way to send it again. So the client never sees the server's
//! `instructions` or `serverInfo`, and the answer here echoes the version the client asked for,
//! not one the server negotiates. A server that ships `instructions` or settles on another
//! version says so on stderr.

use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;
use std::process::ChildStdin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_process::{Child, Command, Stdio};
use serde_json::{Value, json};

/// The id of the `initialize` this sends the server. Its answer goes nowhere.
const INIT_ID: &str = "cmux-mcp-lazy-initialize";
/// The lists the client may read before the server runs, each answered empty: its method and
/// the field of its answer.
const LISTS: &[(&str, &str)] = &[
    ("tools/list", "tools"),
    ("prompts/list", "prompts"),
    ("resources/list", "resources"),
    ("resources/templates/list", "resourceTemplates"),
];

pub(crate) type Out = Arc<Mutex<dyn Write + Send>>;

pub(super) fn run(dir: &Path, cmd: &[String]) -> i32 {
    let out: Out = Arc::new(Mutex::new(io::stdout()));
    let ended: Box<dyn FnOnce(i32) + Send> = Box::new(|code| crate::client_log::exit(code));
    proxy(io::stdin().lock(), out, dir, cmd, |closed| whole(dir, closed), ended)
}

/// The barrier on `dir` open: `cmux repo wait`'s wait, with no deadline while the sync runs, but
/// one that ends once the client has `closed` its stdin (nobody is left to serve).
fn whole(dir: &Path, closed: &AtomicBool) -> io::Result<()> {
    loop {
        match cmux_git::sync_barrier::wait_ready(dir, Duration::from_millis(200)) {
            Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                if closed.load(Ordering::SeqCst) {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "the client left"));
                }
            }
            done => return done,
        }
    }
}

enum Phase {
    /// The checkout still fills: the client's other lines wait here.
    Waiting(Vec<String>),
    /// The server runs: every client line goes to it.
    Live(ChildStdin),
    /// The barrier or the server failed: the lists stay empty and calls are refused.
    Failed,
    /// The client closed stdin.
    Closed,
}

struct Shared {
    phase: Mutex<Phase>,
    /// The server while it has not answered `initialize`: a client that closes stdin ends it.
    starting: Mutex<Option<Child>>,
    /// The client closed stdin: a wait for the checkout ends.
    closed: AtomicBool,
}

/// Serves `input` to `out` as above. `ready` blocks until the checkout is whole, or errs once
/// its flag (the client closed stdin) is set; `ended` gets the server's exit code when it ends.
/// The server's thread is this call's: it returns once that thread is done.
pub(crate) fn proxy(
    input: impl BufRead,
    out: Out,
    dir: &Path,
    cmd: &[String],
    ready: impl FnOnce(&AtomicBool) -> io::Result<()> + Send,
    ended: Box<dyn FnOnce(i32) + Send>,
) -> i32 {
    let shared = Shared {
        phase: Mutex::new(Phase::Waiting(Vec::new())),
        starting: Mutex::new(None),
        closed: AtomicBool::new(false),
    };
    std::thread::scope(|scope| {
        let mut start = Some((ready, ended));
        let mut server = None;
        for line in input.lines() {
            let Ok(line) = line else { break };
            if let Some((ready, ended)) = relay(&shared, &out, &line, &mut start) {
                let (shared, out) = (&shared, &out);
                server =
                    Some(scope.spawn(move || {
                        serve_when_whole(shared, out, dir, cmd, &line, ready, ended)
                    }));
            }
        }
        shared.closed.store(true, Ordering::SeqCst);
        // A live server's end of stdin closes here: it ends, and its thread says how.
        drop(std::mem::replace(&mut *lock(&shared.phase), Phase::Closed));
        // A server that has not answered `initialize` may never read stdin: it ends here.
        drop(lock(&shared.starting).take());
        server.and_then(|server| server.join().ok().flatten()).unwrap_or(0)
    })
}

/// One client line, before or after the server runs. The first `initialize` gives back what
/// starts the server (`start`), for a thread of its own; its line holds the params.
fn relay<R, E>(
    shared: &Shared,
    out: &Out,
    line: &str,
    start: &mut Option<(R, E)>,
) -> Option<(R, E)> {
    if line.trim().is_empty() {
        return None;
    }
    let mut phase = lock(&shared.phase);
    if let Phase::Live(stdin) = &mut *phase {
        // A server gone ends this through its stdout.
        let _ = writeln!(stdin, "{line}").and_then(|()| stdin.flush());
        return None;
    }
    let message = serde_json::from_str::<Value>(line).ok()?;
    let method = message.get("method").and_then(Value::as_str);
    let id = message.get("id").cloned();
    let list = LISTS.iter().find(|(name, _)| Some(*name) == method);
    if let (Some((_, field)), Some(id)) = (list, &id) {
        send(out, &answer(id, json!({ *field: [] })));
        return None;
    }
    match (method, id) {
        (Some("initialize"), Some(id)) => {
            let version = message.pointer("/params/protocolVersion").cloned();
            send(out, &answer(&id, initialized(version)));
            return start.take();
        }
        // The server gets its own once it runs.
        (Some("notifications/initialized"), None) => {}
        (Some("ping"), Some(id)) => send(out, &answer(&id, json!({}))),
        (method, id) => match &mut *phase {
            Phase::Waiting(queue) => queue.push(line.to_owned()),
            _ => {
                if let (Some(_), Some(id)) = (method, id) {
                    send(out, &refused(&id));
                }
            }
        },
    }
    None
}

/// Waits for the checkout, starts the server and relays its lines to the client until it ends:
/// its exit code, `None` when it never ran.
fn serve_when_whole(
    shared: &Shared,
    out: &Out,
    dir: &Path,
    cmd: &[String],
    initialize: &str,
    ready: impl FnOnce(&AtomicBool) -> io::Result<()>,
    ended: Box<dyn FnOnce(i32) + Send>,
) -> Option<i32> {
    let params = serde_json::from_str::<Value>(initialize)
        .ok()
        .and_then(|message| message.get("params").cloned())
        .unwrap_or_else(|| json!({}));
    let say = |why: String| {
        eprintln!("cmux repo mcp-lazy: {}: {why}; its tools stay empty", dir.display());
        fail(shared, out);
        None
    };
    if let Err(error) = ready(&shared.closed) {
        if shared.closed.load(Ordering::SeqCst) {
            return None;
        }
        return say(format!("the checkout did not finish: {error}"));
    }
    if matches!(*lock(&shared.phase), Phase::Closed) {
        return None;
    }
    let Some((program, args)) = cmd.split_first() else { return say("no command".into()) };
    let spawned = Command::new(program)
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return say(format!("cannot start {program}: {error}")),
    };
    let (Some(stdin), Some(stdout)) = (child.stdin.as_mut(), child.stdout.take()) else {
        return say(format!("{program} has no pipes"));
    };
    let init = json!({"jsonrpc": "2.0", "id": INIT_ID, "method": "initialize", "params": params});
    if writeln!(stdin, "{init}").and_then(|()| stdin.flush()).is_err() {
        return say(format!("{program} ended before it was initialized"));
    }
    {
        // Under the lock: once the client closes stdin, `proxy` ends the server (or it ends here).
        let phase = lock(&shared.phase);
        if matches!(*phase, Phase::Closed) {
            return None;
        }
        *lock(&shared.starting) = Some(child);
    }
    let mut lines = BufReader::new(stdout).lines();
    // What the server says before it answers (a log line) still goes to the client.
    let capabilities = loop {
        let Some(Ok(line)) = lines.next() else {
            if shared.closed.load(Ordering::SeqCst) {
                return None;
            }
            drop(lock(&shared.starting).take());
            return say(format!("{program} ended before it answered initialize"));
        };
        let message = serde_json::from_str::<Value>(&line).unwrap_or(Value::Null);
        // The client's answers wait for the server to be live, so a ping the server sends while
        // it initializes is answered here, or a server waiting on it would never answer.
        if let (Some("ping"), Some(id)) =
            (message.get("method").and_then(Value::as_str), message.get("id"))
        {
            if let Some(stdin) =
                lock(&shared.starting).as_mut().and_then(|child| child.stdin.as_mut())
            {
                let _ = writeln!(stdin, "{}", answer(id, json!({}))).and_then(|()| stdin.flush());
            }
            continue;
        }
        if message.get("id").and_then(Value::as_str) != Some(INIT_ID) {
            send_line(out, &line);
            continue;
        }
        match message.get("result") {
            Some(result) => {
                for note in unrelayed(params.get("protocolVersion"), result) {
                    eprintln!("cmux repo mcp-lazy: {}: {program} {note}", dir.display());
                }
                break result.get("capabilities").cloned().unwrap_or(Value::Null);
            }
            None => {
                // A server that refused stays out: its drop ends it now, not when the client leaves.
                drop(lock(&shared.starting).take());
                return say(format!("{program} refused initialize: {line}"));
            }
        }
    };
    // None: the client left, and the server ended with it.
    let mut child = lock(&shared.starting).take()?;
    let mut stdin = child.stdin.take()?;
    let initialized = json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
    if writeln!(stdin, "{initialized}").and_then(|()| stdin.flush()).is_err() {
        return say(format!("{program} ended as it was initialized"));
    }
    {
        let mut phase = lock(&shared.phase);
        let Phase::Waiting(queue) = std::mem::replace(&mut *phase, Phase::Closed) else {
            // The client left: the child's drop ends it.
            return None;
        };
        for line in queue {
            let _ = writeln!(stdin, "{line}");
        }
        let _ = stdin.flush();
        *phase = Phase::Live(stdin);
        // Under the lock: a list the client asks for after this goes to the server.
        for kind in ["tools", "prompts", "resources"] {
            if kind == "tools" || capabilities.get(kind).is_some() {
                let method = format!("notifications/{kind}/list_changed");
                send(out, &json!({"jsonrpc": "2.0", "method": method}));
            }
        }
    }
    for line in lines {
        let Ok(line) = line else { break };
        send_line(out, &line);
    }
    let code = child.wait().ok().and_then(|status| status.code()).unwrap_or(1);
    ended(code);
    Some(code)
}

/// The barrier or server failed: what waited is refused, and so is every later call.
fn fail(shared: &Shared, out: &Out) {
    let mut phase = lock(&shared.phase);
    let Phase::Waiting(queue) = std::mem::replace(&mut *phase, Phase::Failed) else {
        *phase = Phase::Closed;
        return;
    };
    for line in queue {
        let message = serde_json::from_str::<Value>(&line).unwrap_or(Value::Null);
        if let (Some(_), Some(id)) = (message.get("method"), message.get("id")) {
            send(out, &refused(id));
        }
    }
}

/// What the server's `initialize` `result` says that the client, answered here with the version
/// it `requested`, never sees: one line each.
fn unrelayed(requested: Option<&Value>, result: &Value) -> Vec<String> {
    let mut notes = Vec::new();
    if let (Some(requested), Some(version)) = (requested, result.get("protocolVersion"))
        && requested != version
    {
        notes.push(format!("speaks MCP {version}; the client was answered {requested}"));
    }
    if result.get("instructions").and_then(Value::as_str).is_some_and(|text| !text.is_empty()) {
        notes.push("has instructions, which the client never sees (it was answered before)".into());
    }
    notes
}

/// The answer to the client's `initialize`: the `version` it asked for, never the server's.
fn initialized(version: Option<Value>) -> Value {
    let changes = json!({"listChanged": true});
    json!({
        "protocolVersion": version.unwrap_or_else(|| json!("2025-06-18")),
        "capabilities": {"tools": changes, "prompts": changes, "resources": changes},
        "serverInfo": {"name": "cmux-mcp-lazy", "version": env!("CARGO_PKG_VERSION")},
    })
}

fn answer(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn refused(id: &Value) -> Value {
    let message = "this MCP server did not start: its checkout did not finish syncing";
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": message}})
}

fn send(out: &Out, message: &Value) {
    send_line(out, &message.to_string());
}

fn send_line(out: &Out, line: &str) {
    let mut out = lock(out);
    let _ = writeln!(out, "{line}").and_then(|()| out.flush());
}

fn lock<T: ?Sized>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
#[path = "repo_mcp_lazy_tests.rs"]
mod tests;
