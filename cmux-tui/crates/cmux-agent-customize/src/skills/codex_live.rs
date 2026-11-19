//! Codex's own skill list: `codex app-server`'s `skills/list`, the list a Codex chat loads (remote
//! plugins included, which no folder names). One short-lived app-server per read; it writes nothing.

use std::io::{BufRead as _, BufReader, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Agent, Kind, Problem, Scope, Skill};
use crate::paths::Homes;

/// How to reach Codex's app-server.
#[derive(Debug, Clone)]
pub struct CodexLive {
    pub program: PathBuf,
    /// The whole read gives up after this (then cmux reads the folders instead).
    pub timeout: Duration,
}

impl CodexLive {
    /// `$CMUX_CODEX_BIN`, else `codex` on `PATH`, else where Codex's installers put it (an app
    /// started from the Dock has a short `PATH`), with a 10 s bound.
    pub fn find() -> Option<Self> {
        let named = std::env::var_os("CMUX_CODEX_BIN").filter(|v| !v.is_empty()).map(PathBuf::from);
        let on_path = std::env::var_os("PATH")
            .map(|path| {
                std::env::split_paths(&path).map(|dir| dir.join("codex")).collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let home = std::env::var_os("HOME").map(PathBuf::from);
        let installed = home
            .iter()
            .flat_map(|home| {
                [
                    home.join(".local/bin/codex"),
                    home.join(".codex/packages/standalone/current/bin/codex"),
                ]
            })
            .chain([
                PathBuf::from("/opt/homebrew/bin/codex"),
                PathBuf::from("/usr/local/bin/codex"),
            ]);
        named
            .into_iter()
            .chain(on_path)
            .chain(installed)
            .find(|candidate| candidate.is_file())
            .map(|program| Self { program, timeout: Duration::from_secs(10) })
    }

    /// The skills Codex loads in `cwd` (the home folder when `None`), or `None` when the
    /// app-server did not answer in time or answered something else.
    pub fn list(&self, homes: &Homes, cwd: Option<&Path>) -> Option<(Vec<Skill>, Vec<Problem>)> {
        let cwd = cwd.unwrap_or(&homes.home);
        let reply = self.request(homes, cwd)?;
        Some(parse(&reply))
    }

    fn request(&self, homes: &Homes, cwd: &Path) -> Option<Value> {
        let mut child = Command::new(&self.program)
            .arg("app-server")
            .current_dir(cwd)
            .env("HOME", &homes.home)
            .env("CODEX_HOME", &homes.codex)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let reply = (|| {
            let mut stdin = child.stdin.take()?;
            let stdout = child.stdout.take()?;
            let (lines, received) = mpsc::channel::<String>();
            std::thread::spawn(move || {
                for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                    if lines.send(line).is_err() {
                        break;
                    }
                }
            });
            let deadline = Instant::now() + self.timeout;
            let await_id = |id: u64| -> Option<Value> {
                loop {
                    let left = deadline.checked_duration_since(Instant::now())?;
                    let line = received.recv_timeout(left).ok()?;
                    let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                    if message.get("id").and_then(Value::as_u64) == Some(id) {
                        return Some(message);
                    }
                }
            };
            let send = |stdin: &mut std::process::ChildStdin, message: Value| -> Option<()> {
                writeln!(stdin, "{message}").ok()?;
                stdin.flush().ok()
            };
            send(
                &mut stdin,
                json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "cmux", "version": env!("CARGO_PKG_VERSION")}}}),
            )?;
            await_id(1)?;
            send(&mut stdin, json!({"method": "initialized"}))?;
            send(&mut stdin, json!({"id": 2, "method": "skills/list", "params": {"cwds": [cwd]}}))?;
            await_id(2)
        })();
        let _ = child.kill();
        let _ = child.wait();
        reply?.get("result").cloned()
    }
}

/// `skills/list`'s result: `data[0].skills` and `data[0].errors`.
pub(super) fn parse(result: &Value) -> (Vec<Skill>, Vec<Problem>) {
    let entry = result.get("data").and_then(Value::as_array).and_then(|d| d.first());
    let skills = entry
        .and_then(|e| e.get("skills"))
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|skill| {
                    let text = |key: &str| skill.get(key).and_then(Value::as_str);
                    let plugin = text("pluginId").map(str::to_owned);
                    let scope = match (text("scope")?, &plugin) {
                        (_, Some(_)) => Scope::Plugin,
                        ("repo", _) => Scope::Project,
                        ("system", _) => Scope::System,
                        ("admin", _) => Scope::Admin,
                        _ => Scope::User,
                    };
                    Some(Skill {
                        agent: Agent::Codex,
                        kind: Kind::Skill,
                        scope,
                        name: text("name")?.to_owned(),
                        description: text("description").unwrap_or_default().to_owned(),
                        path: PathBuf::from(text("path")?),
                        plugin,
                        enabled: skill.get("enabled").and_then(Value::as_bool).unwrap_or(true),
                        r#override: None,
                        switch_file: None,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let problems = entry
        .and_then(|e| e.get("errors"))
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|error| {
                    Some(Problem {
                        agent: Agent::Codex,
                        path: PathBuf::from(error.get("path")?.as_str()?),
                        message: error
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    (skills, problems)
}
