use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Cursor, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

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

fn write_pid_file(dir: &Path) -> Result<()> {
    let pid_path = dir.join("envd.pid");
    fs::write(&pid_path, format!("{}\n", std::process::id()))
        .with_context(|| format!("writing pid file {}", pid_path.display()))?;
    Ok(())
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
    Set {
        key: String,
        value: String,
        scope: Scope,
    },
    Unset {
        key: String,
        scope: Scope,
    },
    Get {
        key: String,
        pwd: Option<PathBuf>,
    },
    List {
        pwd: Option<PathBuf>,
    },
    Load {
        entries: Vec<(String, String)>,
        scope: Scope,
    },
    Export {
        shell: ShellKind,
        since: u64,
        pwd: PathBuf,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Response {
    Pong,
    Status {
        generation: u64,
        globals: usize,
        scopes: usize,
    },
    Ok,
    Value {
        value: Option<String>,
    },
    Map {
        entries: HashMap<String, String>,
    },
    Export {
        script: String,
        new_generation: u64,
    },
    Error {
        message: String,
    },
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
                let existed = self.globals.remove(&key).is_some();
                if existed {
                    self.bump(key, Scope::Global);
                }
                existed
            }
            Scope::Dir(path) => {
                let path = canon(path);
                if let Some(map) = self.scoped.get_mut(&path) {
                    let existed = map.remove(&key).is_some();
                    if existed {
                        self.bump(key, Scope::Dir(path));
                    }
                    existed
                } else {
                    false
                }
            }
        }
    }

    fn bump(&mut self, key: String, scope: Scope) {
        self.generation += 1;
        // normalize dir scope to canonical form
        let scope = match scope {
            Scope::Dir(p) => Scope::Dir(canon(p)),
            x => x,
        };
        self.history.push(ChangeEvent {
            generation: self.generation,
            key,
            scope,
        });
    }

    pub fn load(&mut self, scope: Scope, entries: Vec<(String, String)>) {
        for (k, v) in entries {
            self.set(scope.clone(), k, v);
        }
    }

    pub fn effective_for_pwd(&self, pwd: &Path) -> HashMap<String, String> {
        let mut map = self.globals.clone();
        if let Some((_, overlay)) = self.best_scope_for_pwd(pwd) {
            for (k, v) in overlay.iter() {
                map.insert(k.clone(), v.clone());
            }
        }
        map
    }

    pub fn get_effective(&self, key: &str, pwd: &Path) -> Option<String> {
        if let Some((_, overlay)) = self.best_scope_for_pwd(pwd) {
            if let Some(v) = overlay.get(key) {
                return Some(v.clone());
            }
        }
        self.globals.get(key).cloned()
    }

    // Returns best matching directory scope (deepest ancestor) and its map
    fn best_scope_for_pwd(&self, pwd: &Path) -> Option<(PathBuf, &HashMap<String, String>)> {
        let pwd = canon(pwd);
        let mut best: Option<(PathBuf, &HashMap<String, String>)> = None;
        for (dir, vars) in &self.scoped {
            if is_ancestor(dir, &pwd) {
                match &best {
                    None => best = Some((dir.clone(), vars)),
                    Some((bdir, _)) => {
                        if dir.components().count() > bdir.components().count() {
                            best = Some((dir.clone(), vars));
                        }
                    }
                }
            }
        }
        best
    }

    pub fn export_since(&self, shell: ShellKind, since: u64, pwd: &Path) -> (String, u64) {
        let new_gen = self.generation;
        let mut changed_keys: HashSet<String> = HashSet::new();
        let pwd_c = canon(pwd);
        for ev in self.history.iter().filter(|e| e.generation > since) {
            match &ev.scope {
                Scope::Global => {
                    changed_keys.insert(ev.key.clone());
                }
                Scope::Dir(dir) => {
                    if is_ancestor(dir, &pwd_c) {
                        changed_keys.insert(ev.key.clone());
                    }
                }
            }
        }

        // For each changed key, compute current effective value for pwd
        let mut actions: Vec<(String, Option<String>)> = Vec::new();
        for key in changed_keys.into_iter() {
            let val = self.get_effective(&key, &pwd_c);
            actions.push((key, val));
        }
        actions.sort_by(|a, b| a.0.cmp(&b.0));
        let script = render_script(shell, &actions, new_gen);
        (script, new_gen)
    }
}

fn is_ancestor(a: &Path, b: &Path) -> bool {
    let a = canon(a);
    let b = canon(b);
    b.starts_with(a)
}

fn canon<P: AsRef<Path>>(p: P) -> PathBuf {
    let p = p.as_ref();
    match p.canonicalize() {
        Ok(c) => c,
        Err(_) => p.to_path_buf(),
    }
}

// --------------- Scripting ---------------

fn sh_single_quote(val: &str) -> String {
    // Replace ' with '\'' pattern
    let mut out = String::with_capacity(val.len() + 2);
    out.push('\'');
    for ch in val.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

fn render_script(shell: ShellKind, actions: &[(String, Option<String>)], new_gen: u64) -> String {
    let mut out = String::new();
    match shell {
        ShellKind::Bash | ShellKind::Zsh => {
            for (k, v) in actions {
                if is_valid_key(k) {
                    match v {
                        Some(val) => {
                            out.push_str(&format!("export {}={}\n", k, sh_single_quote(val)));
                        }
                        None => {
                            out.push_str(&format!("unset -v {}\n", k));
                        }
                    }
                }
            }
            out.push_str(&format!("export ENVCTL_GEN={}\n", new_gen));
        }
        ShellKind::Fish => {
            for (k, v) in actions {
                if is_valid_key(k) {
                    match v {
                        Some(val) => {
                            out.push_str(&format!("set -x {} {}\n", k, sh_single_quote(val)))
                        }
                        None => out.push_str(&format!("set -e {}\n", k)),
                    }
                }
            }
            out.push_str(&format!("set -x ENVCTL_GEN {}\n", new_gen));
        }
    }
    out
}

fn is_valid_key(k: &str) -> bool {
    let first = k.chars().next();
    if !first
        .map(|c| c == '_' || c.is_ascii_alphabetic())
        .unwrap_or(false)
    {
        return false;
    }
    k.chars().all(|c| c == '_' || c.is_ascii_alphanumeric())
}

// --------------- Server plumbing ---------------

pub fn run_server() -> Result<()> {
    let dir = ensure_socket_dir()?;
    let sock = socket_path();
    if sock.exists() {
        let _ = fs::remove_file(&sock);
    }
    let listener = UnixListener::bind(&sock).with_context(|| format!("bind {}", sock.display()))?;
    write_pid_file(&dir)?;
    let state = Arc::new(Mutex::new(State::default()));

    loop {
        let (mut stream, _addr) = listener.accept()?;
        let state = state.clone();
        std::thread::spawn(move || {
            let resp = match read_json(&mut stream) {
                Ok(req) => handle_request(req, &state),
                Err(e) => Response::Error {
                    message: format!("read error: {}", e),
                },
            };
            let _ = write_json(&mut stream, &resp);
        });
    }
}

fn resolve_pwd(pwd: Option<PathBuf>) -> PathBuf {
    pwd.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

fn handle_request(req: Request, state: &Arc<Mutex<State>>) -> Response {
    let mut st = state.lock();
    match req {
        Request::Ping => Response::Pong,
        Request::Status => Response::Status {
            generation: st.generation,
            globals: st.globals.len(),
            scopes: st.scoped.len(),
        },
        Request::Set { key, value, scope } => {
            st.set(scope, key, value);
            Response::Ok
        }
        Request::Unset { key, scope } => {
            st.unset(scope, key);
            Response::Ok
        }
        Request::Get { key, pwd } => {
            let pwd = resolve_pwd(pwd);
            let v = st.get_effective(&key, &pwd);
            Response::Value { value: v }
        }
        Request::List { pwd } => {
            let pwd = resolve_pwd(pwd);
            let entries = st.effective_for_pwd(&pwd);
            Response::Map { entries }
        }
        Request::Load { entries, scope } => {
            st.load(scope, entries);
            Response::Ok
        }
        Request::Export { shell, since, pwd } => {
            let (script, new_generation) = st.export_since(shell, since, &pwd);
            Response::Export {
                script,
                new_generation,
            }
        }
    }
}

// --------------- Client plumbing ---------------

pub fn client_send(req: &Request) -> Result<Response> {
    client_send_inner(req, false)
}

pub fn client_send_autostart(req: &Request) -> Result<Response> {
    client_send_inner(req, true)
}

fn client_send_inner(req: &Request, autostart: bool) -> Result<Response> {
    let mut stream = connect_daemon(autostart)?;
    let s = serde_json::to_string(req)?;
    stream.write_all(s.as_bytes())?;
    stream.write_all(b"\n")?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.is_empty() {
        return Err(anyhow!("empty response"));
    }
    let resp: Response = serde_json::from_str(&line).context("parse response")?;
    Ok(resp)
}

fn connect_daemon(autostart: bool) -> Result<UnixStream> {
    let sock = socket_path();
    match UnixStream::connect(&sock) {
        Ok(stream) => Ok(stream),
        Err(err) => {
            if autostart && should_autostart(err.kind()) {
                start_daemon_and_connect(&sock)
            } else {
                Err(err).with_context(|| format!("connect {}", sock.display()))
            }
        }
    }
}

fn should_autostart(kind: std::io::ErrorKind) -> bool {
    matches!(
        kind,
        std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound
    )
}

fn start_daemon_and_connect(sock: &Path) -> Result<UnixStream> {
    ensure_socket_dir()?;
    let envd_path = envd_executable_path()?;
    let mut cmd = Command::new(&envd_path);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());
    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawn {}", envd_path.display()))?;

    let timeout = Duration::from_secs(3);
    let start = Instant::now();
    loop {
        match UnixStream::connect(sock) {
            Ok(stream) => return Ok(stream),
            Err(err) => {
                if !should_autostart(err.kind()) {
                    let _ = child.kill();
                    return Err(err).with_context(|| format!("connect {}", sock.display()));
                }
                if let Some(status) = child.try_wait()? {
                    return Err(anyhow!("envd exited immediately with status {}", status));
                }
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    return Err(anyhow!("envd did not become ready in {:?}", timeout));
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn envd_executable_path() -> Result<PathBuf> {
    if let Some(custom) = std::env::var_os("ENVCTL_ENVD_PATH") {
        let path = PathBuf::from(custom);
        if path.exists() {
            return Ok(path);
        }
        return Err(anyhow!(
            "ENVCTL_ENVD_PATH points to missing envd binary: {}",
            path.display()
        ));
    }

    let mut exe = std::env::current_exe().context("determine envctl executable path")?;
    exe.set_file_name(envd_binary_name());
    if exe.exists() {
        Ok(exe)
    } else {
        Err(anyhow!(
            "could not find envd binary next to envctl at {}",
            exe.display()
        ))
    }
}

#[cfg(windows)]
fn envd_binary_name() -> &'static str {
    "envd.exe"
}

#[cfg(not(windows))]
fn envd_binary_name() -> &'static str {
    "envd"
}

pub fn parse_dotenv<R: Read>(mut r: R) -> Result<Vec<(String, String)>> {
    let mut s = String::new();
    r.read_to_string(&mut s)?;
    let mut out = Vec::new();
    for (idx, line) in s.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        if let Some(eq) = line.find('=') {
            let (k, v) = line.split_at(eq);
            let k = k.trim().to_string();
            let v = v[1..].trim().to_string();
            let v = strip_quotes(&v);
            if !is_valid_key(&k) {
                return Err(anyhow!("invalid key at line {}: {}", idx + 1, k));
            }
            out.push((k, v));
        } else {
            return Err(anyhow!("invalid line {}: {}", idx + 1, line));
        }
    }
    Ok(out)
}

pub fn parse_dotenv_base64<S: AsRef<str>>(data: S) -> Result<Vec<(String, String)>> {
    let raw = data.as_ref();
    let sanitized: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
    if sanitized.is_empty() {
        return Err(anyhow!("empty base64 payload"));
    }
    let decoded = BASE64_STANDARD
        .decode(sanitized.as_bytes())
        .map_err(|e| anyhow!("invalid base64 payload: {}", e))?;
    parse_dotenv(Cursor::new(decoded))
}

fn strip_quotes(s: &str) -> String {
    if (s.starts_with('\"') && s.ends_with('\"')) || (s.starts_with('\'') && s.ends_with('\'')) {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}
