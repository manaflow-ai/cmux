use anyhow::{anyhow, Context, Result};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

// ---------------- Path helpers ----------------

pub fn runtime_dir() -> PathBuf {
    if let Ok(p) = std::env::var("XDG_RUNTIME_DIR") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    PathBuf::from("/tmp")
}

pub fn socket_path() -> PathBuf {
    let base = runtime_dir().join("cmux-envd");
    base.join("envd.sock")
}

fn ensure_socket_dir() -> Result<PathBuf> {
    let dir = runtime_dir().join("cmux-envd");
    fs::create_dir_all(&dir).with_context(|| format!("creating dir {}", dir.display()))?;
    Ok(dir)
}

// ---------------- Protocol ----------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ShellKind {
    Bash,
    Zsh,
    Fish,
}

impl ShellKind {}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(tag = "type", content = "path")]
pub enum Scope {
    Global,
    Dir(PathBuf),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Request {
    Ping,
    Status,
    Set { key: String, value: String, scope: Scope },
    Unset { key: String, scope: Scope },
    Get { key: String, pwd: Option<PathBuf> },
    List { pwd: Option<PathBuf> },
    Load { entries: Vec<(String, String)>, scope: Scope },
    Export { shell: ShellKind, since: u64, pwd: PathBuf },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Response {
    Pong,
    Status { generation: u64, globals: usize, scopes: usize },
    Ok,
    Value { value: Option<String> },
    Map { entries: HashMap<String, String> },
    Export { script: String, new_generation: u64 },
    Error { message: String },
}

fn read_json(stream: &mut UnixStream) -> Result<Request> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.is_empty() {
        return Err(anyhow!("empty request"));
    }
    let req: Request = serde_json::from_str(&line).context("parse request")?;
    Ok(req)
}

fn write_json(stream: &mut UnixStream, resp: &Response) -> Result<()> {
    let s = serde_json::to_string(resp)?;
    stream.write_all(s.as_bytes())?;
    stream.write_all(b"\n")?;
    Ok(())
}

// --------------- State ----------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeEvent {
    pub generation: u64,
    pub key: String,
    pub scope: Scope,
}

#[derive(Debug, Default)]
pub struct State {
    pub generation: u64,
    pub globals: HashMap<String, String>,
    pub scoped: HashMap<PathBuf, HashMap<String, String>>, // Dir -> (key -> value)
    pub history: Vec<ChangeEvent>,
}

impl State {
    pub fn set(&mut self, scope: Scope, key: String, value: String) -> bool {
        match scope {
            Scope::Global => {
                let changed = self.globals.get(&key) != Some(&value);
                if changed {
                    self.globals.insert(key.clone(), value);
                    self.bump(key, Scope::Global);
                }
                changed
            }
            Scope::Dir(path) => {
                let path_c = canon(path);
                let entry = self.scoped.entry(path_c.clone()).or_default();
                let changed = entry.get(&key) != Some(&value);
                if changed {
                    entry.insert(key.clone(), value);
                    self.bump(key, Scope::Dir(path_c));
                }
                changed
            }
        }
    }

    pub fn unset(&mut self, scope: Scope, key: String) -> bool {
        match scope {
            Scope::Global => {
                let changed = self.globals.remove(&key).is_some();
                if changed { self.bump(key, Scope::Global); }
                changed
            }
            Scope::Dir(path) => {
                let path_c = canon(path);
                let changed = self.scoped.get_mut(&path_c).map(|m| m.remove(&key).is_some()).unwrap_or(false);
                if changed { self.bump(key, Scope::Dir(path_c)); }
                changed
            }
        }
    }

    pub fn load(&mut self, scope: Scope, entries: Vec<(String, String)>) {
        for (k, v) in entries {
            let _ = self.set(scope.clone(), k, v);
        }
    }

    pub fn effective_for_pwd(&self, pwd: &Path) -> HashMap<String, String> {
        let mut out = self.globals.clone();
        // Find most specific scoped dir that is an ancestor of pwd
        let pwd = canon(pwd);
        let mut best: Option<&Path> = None;
        for dir in self.scoped.keys() {
            if pwd.starts_with(dir) {
                best = match best { Some(b) if b.as_os_str().len() >= dir.as_os_str().len() => Some(b), _ => Some(dir.as_path()) };
            }
        }
        if let Some(dir) = best { if let Some(m) = self.scoped.get(dir) { for (k, v) in m { out.insert(k.clone(), v.clone()); } } }
        out
    }

    pub fn get_effective(&self, key: &str, pwd: &Path) -> Option<String> {
        let eff = self.effective_for_pwd(pwd);
        eff.get(key).cloned()
    }

    pub fn export_since(&self, shell: ShellKind, since: u64, pwd: &Path) -> (String, u64) {
        let eff = self.effective_for_pwd(pwd);

        // Build a map of changes since generation
        let mut changed_keys: HashSet<String> = HashSet::new();
        let mut new_gen = self.generation;
        for ch in self.history.iter().filter(|c| c.generation > since) {
            changed_keys.insert(ch.key.clone());
            new_gen = new_gen.max(ch.generation);
        }

        // Prepare script lines for changed keys only
        let mut lines: Vec<String> = Vec::new();
        // Unsets: changed key that is not present in eff
        for k in &changed_keys {
            if !eff.contains_key(k) {
                match shell {
                    ShellKind::Bash | ShellKind::Zsh => lines.push(format!("unset -v {}", k)),
                    ShellKind::Fish => lines.push(format!("set -e {}", k)),
                }
            }
        }
        // Sets: changed key present in eff
        for (k, v) in eff.iter().filter(|(k, _)| changed_keys.contains(*k)) {
            match shell {
                ShellKind::Bash | ShellKind::Zsh => lines.push(format!("export {}='{}'", k, escape_sh(v))),
                ShellKind::Fish => lines.push(format!("set -x {} '{}'", k, escape_sh(v))),
            }
        }
        // Always bump ENVCTL_GEN to new_gen
        match shell {
            ShellKind::Bash | ShellKind::Zsh => lines.push(format!("export ENVCTL_GEN={}", new_gen)),
            ShellKind::Fish => lines.push(format!("set -x ENVCTL_GEN {}", new_gen)),
        }

        (lines.join("\n") + "\n", new_gen)
    }

    fn bump(&mut self, key: String, scope: Scope) {
        self.generation = self.generation.saturating_add(1);
        self.history.push(ChangeEvent { generation: self.generation, key, scope });
        if self.history.len() > 10_000 { self.history.drain(..self.history.len() - 10_000); }
    }
}

fn escape_sh(s: &str) -> String {
    s.replace('\'', "'\\''")
}

fn canon<P: AsRef<Path>>(p: P) -> PathBuf {
    let p = p.as_ref();
    match fs::canonicalize(p) { Ok(x) => x, Err(_) => p.to_path_buf() }
}

// --------------- Server/client ---------------

pub fn run_server() -> Result<()> {
    let dir = ensure_socket_dir()?;
    let sock = dir.join("envd.sock");
    let _ = fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).with_context(|| format!("bind {}", sock.display()))?;
    let state = Arc::new(Mutex::new(State::default()));

    loop {
        let (mut stream, _addr) = listener.accept()?;
        let st = state.clone();
        std::thread::spawn(move || {
            if let Ok(req) = read_json(&mut stream) {
                let resp = handle_request(st, req);
                let _ = write_json(&mut stream, &resp);
            }
        });
    }
}

fn handle_request(state: Arc<Mutex<State>>, req: Request) -> Response {
    let mut st = state.lock();
    match req {
        Request::Ping => Response::Pong,
        Request::Status => Response::Status { generation: st.generation, globals: st.globals.len(), scopes: st.scoped.len() },
        Request::Set { key, value, scope } => { let _ = st.set(scope, key, value); Response::Ok }
        Request::Unset { key, scope } => { let _ = st.unset(scope, key); Response::Ok }
        Request::Get { key, pwd } => { let v = st.get_effective(&key, &pwd.unwrap_or_else(|| std::env::current_dir().unwrap())); Response::Value { value: v } }
        Request::List { pwd } => { let m = st.effective_for_pwd(&pwd.unwrap_or_else(|| std::env::current_dir().unwrap())); Response::Map { entries: m } }
        Request::Load { entries, scope } => { st.load(scope, entries); Response::Ok }
        Request::Export { shell, since, pwd } => { let (script, new_generation) = st.export_since(shell, since, &pwd); Response::Export { script, new_generation } }
    }
}

pub fn client_send(req: &Request) -> Result<Response> {
    let sock = socket_path();
    let mut stream = UnixStream::connect(&sock).with_context(|| format!("connect {}", sock.display()))?;
    write_json(&mut stream, &req)?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.is_empty() { return Err(anyhow!("empty response")); }
    let resp: Response = serde_json::from_str(&line).context("parse response")?;
    Ok(resp)
}

pub fn parse_dotenv<R: Read>(mut r: R) -> Result<Vec<(String, String)>> {
    let mut buf = String::new();
    r.read_to_string(&mut buf)?;
    let mut out = Vec::new();
    for line in buf.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        if let Some(eq) = line.find('=') {
            let (k, v) = line.split_at(eq);
            let v = v[1..].to_string();
            if !k.is_empty() { out.push((k.to_string(), v)); }
        }
    }
    Ok(out)
}

