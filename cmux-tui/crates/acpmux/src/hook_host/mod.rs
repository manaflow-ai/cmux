//! The hook host: a harness's hook commands run as rules in the daemon, so a tool call starts no
//! interpreter of its own to decide whether it has anything to do.
//!
//! A coding agent's hooks are commands its harness starts on every event: before and after
//! each tool call, on each prompt, at each turn's end. Each one is a shell (often a Python
//! after it) whose first act is a cheap string test on the payload that nearly always says
//! "nothing to do". On a busy machine those starts are most of the process churn agents make.
//! The host keeps the tests (`screen`, `tools`, `every_s`: [`rules`]) in this resident process
//! and starts a rule's command only when its test matches.
//!
//! - `<home>/hooks.json` holds the rules ([`rules`]). With no file the host does not listen.
//! - The daemon listens on loopback ([`serve`]) for `POST /hook/<Event>` with the payload as the
//!   body and `X-Hook-Token` (`<home>/hooks.token`, owner-only) and answers the harness's JSON.
//!   Claude Code's `http` hook entry posts there with no process at all
//!   (`acpmux hook-host settings`).
//! - `acpmux hook-host run <Event>` is the entry for a harness with command hooks only: one
//!   exec of this binary, no runtime, which posts the same request. When the daemon cannot be
//!   reached it runs the rules itself ([`answer_local`]), so a hook never goes unjudged.
//!
//! The rules are configuration; nothing here knows any particular hook.

pub mod rules;

use rules::{Config, Ran, Throttle};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

/// The hidden first word of the client (`cli/entry.rs`, before any runtime starts).
pub const CLI_ARG: &str = "hook-host";
/// The token file beside the rules.
pub const TOKEN_FILE: &str = "hooks.token";
/// The most body one request carries (an Edit of a large file sends it whole).
const MAX_BODY: usize = 32 << 20;
/// How long the client waits for the connection itself.
const CONNECT_WAIT: Duration = Duration::from_millis(300);

/// The rules file, read again when its modification time changes.
struct Rules {
    path: PathBuf,
    seen: Mutex<Option<(SystemTime, Arc<Config>)>>,
}

impl Rules {
    fn new(home: &Path) -> Self {
        Self { path: home.join(rules::FILE), seen: Mutex::new(None) }
    }

    /// The current rules; None when the file is gone or does not parse (the error is logged once
    /// per change).
    fn current(&self) -> Option<Arc<Config>> {
        let mtime = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok()?;
        let mut seen = self.seen.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, config)) = seen.as_ref().filter(|(at, _)| *at == mtime) {
            return Some(config.clone());
        }
        let text = std::fs::read_to_string(&self.path).ok()?;
        match Config::parse(&text) {
            Ok(config) => {
                let config = Arc::new(config);
                *seen = Some((mtime, config.clone()));
                Some(config)
            }
            Err(e) => {
                tracing::warn!("hook host: {e}");
                *seen = None;
                None
            }
        }
    }
}

/// The token every request carries, made on first use (owner-only).
pub fn token(home: &Path, create: bool) -> Option<String> {
    let path = home.join(TOKEN_FILE);
    if let Ok(t) = std::fs::read_to_string(&path) {
        let t = t.trim().to_owned();
        if !t.is_empty() {
            return Some(t);
        }
    }
    if !create {
        return None;
    }
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).ok()?;
    let t: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
    match opts.open(&path) {
        Ok(mut f) => {
            f.write_all(t.as_bytes()).ok()?;
            Some(t)
        }
        // Another process made it first: its token is the one.
        Err(_) => token(home, false),
    }
}

/// Run every rule of `config` that applies to `event` and `payload`, at once, each to its bound,
/// and make their one answer. `env` is the caller's variables; `throttle` keeps `every_s`.
pub fn run_rules(
    config: &Config,
    event: &str,
    payload: &Value,
    body: &[u8],
    env: &HashMap<String, String>,
    throttle: Option<&Mutex<Throttle>>,
) -> Value {
    let session = payload.get("session_id").and_then(Value::as_str).unwrap_or("");
    let now = Instant::now();
    let chosen: Vec<&rules::Rule> = config
        .for_event(event)
        .filter(|r| r.applies(event, payload))
        .filter(|r| match throttle {
            Some(t) => t.lock().unwrap_or_else(|e| e.into_inner()).take(r, session, now),
            None => true,
        })
        .collect();
    if chosen.is_empty() {
        return Value::Object(Default::default());
    }
    let cwd = payload.get("cwd").and_then(Value::as_str).map(PathBuf::from).filter(|p| p.is_dir());
    let runs: Vec<Ran> = std::thread::scope(|s| {
        let handles: Vec<_> = chosen
            .iter()
            .map(|rule| {
                let cwd = cwd.as_deref();
                s.spawn(move || run_one(rule, body, env, cwd, now))
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap_or_default()).collect()
    });
    rules::answer(event, &runs)
}

/// One rule's command, with the payload on stdin (a file: a command that never reads it cannot
/// block on a full pipe) and its output in files, waited on to its bound.
fn run_one(
    rule: &rules::Rule,
    body: &[u8],
    env: &HashMap<String, String>,
    cwd: Option<&Path>,
    started: Instant,
) -> Ran {
    let files = (|| -> std::io::Result<_> {
        let mut input = tempfile::tempfile()?;
        input.write_all(body)?;
        input.rewind()?;
        Ok((input, tempfile::tempfile()?, tempfile::tempfile()?))
    })();
    let Ok((input, mut out, mut err)) = files else { return Ran::default() };
    let mut cmd = cmux_process::Command::new(&rule.argv[0]);
    cmd.args(&rule.argv[1..]);
    for name in &rule.env {
        match env.get(name) {
            Some(v) if !v.is_empty() => {
                cmd.env(name, v);
            }
            _ => {}
        }
    }
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let (Ok(o), Ok(e)) = (out.try_clone(), err.try_clone()) else { return Ran::default() };
    cmd.stdin(input).stdout(o).stderr(e);
    cmd.process_group(0);
    reap_lingering();
    let Ok(mut child) = cmd.spawn() else { return Ran::default() };
    let left = rule.timeout.saturating_sub(started.elapsed()).max(Duration::from_millis(10));
    let status = child.wait_timeout(left).ok().flatten();
    let Some(status) = status else {
        if rule.kill {
            #[cfg(unix)]
            // SAFETY: a plain signal to the process group this rule's command leads (made above).
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            // The drop ends what is left of its group and reaps it.
            drop(child);
        } else {
            // The answer goes on without it; it runs on, and the next rule's run reaps it.
            child.detach("a hook rule without `kill` runs on past its timeout");
            LINGERING.lock().unwrap_or_else(|e| e.into_inner()).push(child);
        }
        return Ran::default();
    };
    let read = |f: &mut std::fs::File| {
        let mut s = String::new();
        let _ = f.rewind();
        let _ = f.take(1 << 20).read_to_string(&mut s);
        s
    };
    Ran { code: status.code(), stdout: read(&mut out), stderr: read(&mut err) }
}

/// Commands past their timeout that run on (`kill` false), held until they end.
static LINGERING: Mutex<Vec<cmux_process::Child>> = Mutex::new(Vec::new());

/// Reap every lingering command that has ended; the rest stay held.
fn reap_lingering() {
    let mut held = LINGERING.lock().unwrap_or_else(|e| e.into_inner());
    held.retain_mut(|c| matches!(c.try_wait(), Ok(None)));
}

/// The client's own answer when the daemon cannot be reached: the same rules, run here.
pub fn answer_local(home: &Path, event: &str, body: &[u8]) -> Value {
    let rules = Rules::new(home);
    let Some(config) = rules.current() else { return Value::Object(Default::default()) };
    let payload: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let env: HashMap<String, String> = std::env::vars().collect();
    run_rules(&config, event, &payload, body, &env, None)
}

// ---- the daemon's listener ----

/// Serve the hook host from the daemon until the runtime ends. Returns at once when `home` has
/// no rules file, or its address is taken (another daemon on this machine serves it).
pub async fn serve(home: PathBuf) {
    let rules = Arc::new(Rules::new(&home));
    let Some(config) = rules.current() else { return };
    let Some(token) = token(&home, true) else {
        tracing::warn!("hook host: no token; not listening");
        return;
    };
    let listener = match tokio::net::TcpListener::bind(&config.listen).await {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!("hook host: {}: {e}; not listening", config.listen);
            return;
        }
    };
    if !listener.local_addr().is_ok_and(|a| a.ip().is_loopback()) {
        tracing::warn!("hook host: {} is not a loopback address; not listening", config.listen);
        return;
    }
    tracing::info!("hook host: listening on {}", config.listen);
    let throttle = Arc::new(Mutex::new(Throttle::default()));
    let token = Arc::new(token);
    let connections = cmux_scope::Scope::new("hook host");
    loop {
        let Ok((stream, _)) = listener.accept().await else { continue };
        let (rules, throttle, token) = (rules.clone(), throttle.clone(), token.clone());
        connections.spawn_named("hook-host connection", async move {
            let _ = connection(stream, rules, throttle, token).await;
        });
    }
}

/// A parsed request: method, path, headers (names lowercased), body.
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

/// Read one HTTP/1.1 request from `buf` once it holds a whole one: Ok(None) is "read more".
pub fn parse_request(buf: &[u8]) -> Result<Option<Request>, &'static str> {
    let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if buf.len() > 64 << 10 { Err("headers too large") } else { Ok(None) };
    };
    let head = std::str::from_utf8(&buf[..end]).map_err(|_| "headers are not UTF-8")?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let method = first.next().unwrap_or("").to_owned();
    let path = first.next().unwrap_or("").to_owned();
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_owned());
        }
    }
    let len: usize = match headers.get("content-length") {
        Some(v) => v.parse().map_err(|_| "bad content-length")?,
        None => 0,
    };
    if len > MAX_BODY {
        return Err("body too large");
    }
    let start = end + 4;
    if buf.len() < start + len {
        return Ok(None);
    }
    Ok(Some(Request { method, path, headers, body: buf[start..start + len].to_vec() }))
}

/// The caller's variables an entry sent as `X-Env-NAME` headers (empty is unset: Claude Code
/// sends an unset variable as "").
pub fn header_env(headers: &HashMap<String, String>, names: &[String]) -> HashMap<String, String> {
    names
        .iter()
        .filter_map(|n| {
            let v = headers.get(&format!("x-env-{}", n.to_ascii_lowercase()))?;
            (!v.is_empty()).then(|| (n.clone(), v.clone()))
        })
        .collect()
}

/// The status and body for one request.
pub fn respond(
    req: &Request,
    config: Option<&Config>,
    token: &str,
    throttle: &Mutex<Throttle>,
) -> (u16, String) {
    if req.method == "GET" && req.path == "/health" {
        return (200, r#"{"ok":true}"#.to_owned());
    }
    if req.headers.get("x-hook-token").map(String::as_str) != Some(token) {
        return (403, r#"{"error":"bad token"}"#.to_owned());
    }
    let Some(event) = req.path.strip_prefix("/hook/").filter(|e| !e.contains('/')) else {
        return (404, r#"{"error":"no such path"}"#.to_owned());
    };
    let Some(config) = config else { return (200, "{}".to_owned()) };
    let payload: Value = serde_json::from_slice(&req.body).unwrap_or(Value::Null);
    let env = header_env(&req.headers, &config.env_names());
    let answer = run_rules(config, event, &payload, &req.body, &env, Some(throttle));
    (200, answer.to_string())
}

async fn connection(
    mut stream: tokio::net::TcpStream,
    rules: Arc<Rules>,
    throttle: Arc<Mutex<Throttle>>,
    token: Arc<String>,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buf = Vec::with_capacity(8192);
    let req = loop {
        let mut chunk = [0u8; 16384];
        let n = tokio::time::timeout(Duration::from_secs(10), stream.read(&mut chunk))
            .await
            .map_err(|_| std::io::Error::other("read timed out"))??;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
        match parse_request(&buf) {
            Ok(Some(req)) => break req,
            Ok(None) => continue,
            Err(e) => {
                let body = format!(r#"{{"error":"{e}"}}"#);
                return write_response(&mut stream, 400, &body).await;
            }
        }
    };
    let (status, body) = tokio::task::spawn_blocking(move || {
        let config = rules.current();
        respond(&req, config.as_deref(), &token, &throttle)
    })
    .await
    .unwrap_or((200, "{}".to_owned()));
    write_response(&mut stream, status, &body).await?;
    stream.shutdown().await
}

async fn write_response(
    stream: &mut tokio::net::TcpStream,
    status: u16,
    body: &str,
) -> std::io::Result<()> {
    use tokio::io::AsyncWriteExt;
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        _ => "Not Found",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await
}

// ---- the client: `acpmux hook-host run|settings|check` ----

/// The client's main (no runtime). Always exits 0 for `run`: a hook must never break a session.
pub fn main(args: &[std::ffi::OsString], home: &Path) -> anyhow::Result<()> {
    let words: Vec<String> = args.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    match words.first().map(String::as_str) {
        Some("run") => {
            let event = words.get(1).cloned().unwrap_or_default();
            let mut body = Vec::new();
            let _ = std::io::stdin().take(MAX_BODY as u64).read_to_end(&mut body);
            let answer = run_client(home, &event, &body);
            if answer.as_object().is_some_and(|o| !o.is_empty()) {
                println!("{answer}");
            }
            Ok(())
        }
        Some("settings") => {
            let kind = words.iter().position(|w| w == "--kind").and_then(|i| words.get(i + 1));
            let exe = std::env::current_exe()?.to_string_lossy().into_owned();
            let rules = Rules::new(home);
            let Some(config) = rules.current() else {
                anyhow::bail!("no rules: write {}", home.join(rules::FILE).display());
            };
            let token = token(home, true).ok_or_else(|| anyhow::anyhow!("no token"))?;
            let kind = kind.map(String::as_str).unwrap_or("http");
            let value = settings(&config, kind, &token, &exe)?;
            println!("{}", serde_json::to_string_pretty(&value)?);
            Ok(())
        }
        Some("check") => {
            let rules = Rules::new(home);
            let config = rules.current();
            let up = config
                .as_ref()
                .is_some_and(|c| post(&c.listen, "GET", "/health", "", &[], &[]).is_ok());
            println!(
                "{}",
                serde_json::json!({
                    "rules": config.as_ref().map(|c| c.rules.len()),
                    "listen": config.as_ref().map(|c| c.listen.clone()),
                    "answering": up,
                })
            );
            Ok(())
        }
        _ => anyhow::bail!(
            "usage: acpmux {CLI_ARG} run EVENT | settings [--kind http|command] | check"
        ),
    }
}

/// `run`: post to the daemon; when it cannot be reached, answer here.
pub fn run_client(home: &Path, event: &str, body: &[u8]) -> Value {
    let rules = Rules::new(home);
    let Some(config) = rules.current() else { return Value::Object(Default::default()) };
    if let Some(token) = token(home, false) {
        let env: Vec<(String, String)> = config
            .env_names()
            .into_iter()
            .filter_map(|n| std::env::var(&n).ok().map(|v| (n, v)))
            .collect();
        if let Ok(text) =
            post(&config.listen, "POST", &format!("/hook/{event}"), &token, &env, body)
        {
            return serde_json::from_str(&text).unwrap_or(Value::Object(Default::default()));
        }
    }
    answer_local(home, event, body)
}

/// One blocking request to the host. Err when it cannot be reached or does not answer 200.
fn post(
    listen: &str,
    method: &str,
    path: &str,
    token: &str,
    env: &[(String, String)],
    body: &[u8],
) -> std::io::Result<String> {
    use std::net::ToSocketAddrs;
    let addr =
        listen.to_socket_addrs()?.next().ok_or_else(|| std::io::Error::other("no address"))?;
    let mut s = std::net::TcpStream::connect_timeout(&addr, CONNECT_WAIT)?;
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {listen}\r\nX-Hook-Token: {token}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (k, v) in env {
        if !v.contains(['\r', '\n']) {
            head.push_str(&format!("X-Env-{k}: {v}\r\n"));
        }
    }
    head.push_str("\r\n");
    s.write_all(head.as_bytes())?;
    s.write_all(body)?;
    let mut resp = Vec::new();
    s.read_to_end(&mut resp)?;
    let text = String::from_utf8_lossy(&resp);
    let (status, rest) = text.split_once("\r\n").unwrap_or(("", ""));
    if !status.contains(" 200 ") {
        return Err(std::io::Error::other(status.to_owned()));
    }
    Ok(rest.split_once("\r\n\r\n").map(|(_, b)| b.to_owned()).unwrap_or_default())
}

/// The `hooks` block a Claude Code settings file takes for these rules: one entry per event,
/// `http` (no process; a host that is down lets the call through, as any unreachable http hook
/// does) or `command` (one exec of this binary, which runs the rules itself when the host is
/// down). Each entry's matcher is the union of its rules' `tools`.
pub fn settings(config: &Config, kind: &str, token: &str, exe: &str) -> anyhow::Result<Value> {
    use serde_json::json;
    let names = config.env_names();
    let mut hooks = serde_json::Map::new();
    for event in config.events() {
        // The harness's own bound sits above the rules' longest, so the host always answers first.
        let timeout = config.longest(&event).as_secs() + 5;
        let entry = match kind {
            "http" => {
                let mut headers = serde_json::Map::new();
                headers.insert("X-Hook-Token".into(), json!(token));
                for n in &names {
                    headers.insert(format!("X-Env-{n}"), json!(format!("${{{n}}}")));
                }
                json!({"type": "http", "url": format!("http://{}/hook/{event}", config.listen),
                       "timeout": timeout, "headers": headers, "allowedEnvVars": names})
            }
            "command" => {
                let quoted = format!("'{}'", exe.replace('\'', "'\\''"));
                json!({"type": "command", "command": format!("{quoted} {CLI_ARG} run {event}"),
                       "timeout": timeout})
            }
            other => anyhow::bail!("--kind {other}: http or command"),
        };
        let mut group = json!({"hooks": [entry]});
        if let Some(m) = config.matcher(&event) {
            group["matcher"] = json!(m);
        }
        hooks.insert(event, json!([group]));
    }
    Ok(Value::Object(hooks))
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
