//! The memory tools `zoom` and `date` (section 7.1), answered by the host from
//! the live memory on a Unix socket in `$MUX_HOME/optchat/`. The `mcp`
//! subcommand, which the turn session runs as its MCP server, forwards each
//! call here, so the answers always come from the one process that owns the
//! chat. Wire: one JSON line per request and per answer.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use optchat_host::OptChat;
use serde_json::{Value, json};

/// What the tools read.
pub trait Memory: Send + Sync {
    fn zoom(&self, id: u64, n: u64) -> String;
    fn date(&self, id: u64) -> String;
    /// The whole memory as one HTML page (`optchat-chief browse`).
    fn browse(&self) -> String {
        "browsing is not available".to_owned()
    }
}

impl Memory for OptChat {
    fn zoom(&self, id: u64, n: u64) -> String {
        // A bad address answers "No line id+n." (section 7.1), not an error.
        OptChat::zoom(self, id, n).unwrap_or_else(|e| e.to_string())
    }

    fn date(&self, id: u64) -> String {
        OptChat::date(self, id).unwrap_or_else(|| format!("No message {id}."))
    }

    fn browse(&self) -> String {
        crate::browse::html(self)
    }
}

/// One tool call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Call {
    Zoom { id: u64, n: u64 },
    Date { id: u64 },
}

impl Call {
    /// The call named `tool` with JSON `args`.
    pub fn parse(tool: &str, args: &Value) -> Result<Call, String> {
        let num = |key: &str| {
            args.get(key)
                .and_then(|v| {
                    v.as_u64()
                        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
                })
                .ok_or_else(|| format!("{tool}: `{key}` must be a non-negative integer"))
        };
        match tool {
            "zoom" => Ok(Call::Zoom {
                id: num("id")?,
                n: num("n")?,
            }),
            "date" => Ok(Call::Date { id: num("id")? }),
            other => Err(format!("unknown tool {other}")),
        }
    }

    pub fn answer(self, memory: &dyn Memory) -> String {
        match self {
            Call::Zoom { id, n } => memory.zoom(id, n),
            Call::Date { id } => memory.date(id),
        }
    }

    fn to_json(self) -> Value {
        match self {
            Call::Zoom { id, n } => json!({"tool": "zoom", "id": id, "n": n}),
            Call::Date { id } => json!({"tool": "date", "id": id}),
        }
    }
}

/// The host's per-Chief settings over the socket (`optchat-chief settings`):
/// `Some((key, value))` sets one, None shows them all. Not a model tool:
/// the MCP server never offers it, and the host refuses turning
/// `remote.autoApprove` on during remote-origin work.
pub type Control = Arc<dyn Fn(ControlRequest) -> Result<String, String> + Send + Sync>;

/// What `optchat-chief settings` and `chief agents spawn` ask the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlRequest {
    /// The per-Chief settings as JSON.
    Show,
    /// Sets one setting.
    Set(String, String),
    /// The policy floor for a child spawned now: `ask`, or empty for none.
    SpawnPolicy,
}

/// Serves the tools on `path` until the process ends. The host holds the
/// host lock, so a socket file left by an earlier host is stale and replaced.
pub fn serve(path: &Path, memory: Arc<dyn Memory>) -> std::io::Result<()> {
    serve_with(path, memory, None)
}

/// `serve`, with the host's settings `control`.
pub fn serve_with(
    path: &Path,
    memory: Arc<dyn Memory>,
    control: Option<Control>,
) -> std::io::Result<()> {
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    std::thread::Builder::new()
        .name("tools".into())
        .spawn(move || {
            for conn in listener.incoming().flatten() {
                let memory = memory.clone();
                let control = control.clone();
                let _ = std::thread::Builder::new()
                    .name("tools-conn".into())
                    .spawn(move || connection(conn, &*memory, control.as_ref()));
            }
        })?;
    Ok(())
}

fn connection(conn: UnixStream, memory: &dyn Memory, control: Option<&Control>) {
    let Ok(mut out) = conn.try_clone() else {
        return;
    };
    for line in BufReader::new(conn).lines() {
        let Ok(line) = line else { return };
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                let tool = req.get("tool").and_then(Value::as_str).unwrap_or("");
                // Not a model tool: the `browse` command asks the live host.
                if tool == "settings" || tool == "spawn_policy" {
                    let ask = match req.get("key").and_then(Value::as_str) {
                        _ if tool == "spawn_policy" => ControlRequest::SpawnPolicy,
                        Some(k) => {
                            let v = req.get("value").and_then(Value::as_str).unwrap_or("");
                            ControlRequest::Set(k.to_owned(), v.to_owned())
                        }
                        None => ControlRequest::Show,
                    };
                    let answer = match control {
                        Some(control) => match control(ask) {
                            Ok(text) => json!({"text": text}),
                            Err(e) => json!({"error": e}),
                        },
                        None => json!({"error": "settings are not served here"}),
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                if tool == "browse" {
                    let answer = json!({"text": memory.browse()});
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                match Call::parse(tool, &req) {
                    Ok(call) => json!({"text": call.answer(memory)}),
                    Err(e) => json!({"error": e}),
                }
            }
            Err(e) => json!({"error": format!("bad request: {e}")}),
        };
        if writeln!(out, "{answer}").is_err() {
            return;
        }
    }
}

/// Asks the host on `path`; Err when it does not answer.
pub fn ask(path: &Path, call: Call) -> Result<String, String> {
    ask_json(path, &call.to_json())
}

/// Shows (None) or sets (`Some((key, value))`) the live host's settings.
pub fn ask_settings(path: &Path, set: Option<(&str, &str)>) -> Result<String, String> {
    let request = match set {
        Some((key, value)) => json!({"tool": "settings", "key": key, "value": value}),
        None => json!({"tool": "settings"}),
    };
    ask_json(path, &request)
}

/// The live host's policy floor for a child spawned now (`Some("ask")`),
/// or None. Err when no host answers: the caller fails closed.
pub fn ask_spawn_policy(path: &Path) -> Result<Option<String>, String> {
    let text = ask_json(path, &json!({"tool": "spawn_policy"}))?;
    Ok((!text.is_empty()).then_some(text))
}

/// The browse page from the live host; Err when no host answers on `path`.
pub fn ask_browse(path: &Path) -> Result<String, String> {
    ask_json(path, &json!({"tool": "browse"}))
}

fn ask_json(path: &Path, request: &Value) -> Result<String, String> {
    let mut conn = UnixStream::connect(path)
        .map_err(|e| format!("the Chief host is not running ({}: {e})", path.display()))?;
    conn.set_read_timeout(Some(Duration::from_secs(30)))
        .map_err(|e| e.to_string())?;
    writeln!(conn, "{request}").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(conn)
        .read_line(&mut line)
        .map_err(|e| format!("reading the answer: {e}"))?;
    let answer: Value = serde_json::from_str(&line).map_err(|e| format!("bad answer: {e}"))?;
    match (
        answer.get("text").and_then(Value::as_str),
        answer.get("error").and_then(Value::as_str),
    ) {
        (Some(text), _) => Ok(text.to_owned()),
        (None, Some(error)) => Err(error.to_owned()),
        (None, None) => Err("empty answer".to_owned()),
    }
}
