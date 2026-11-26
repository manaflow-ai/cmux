//! The person's own stdio MCP servers, one process per identical launch for every chat (Leo,
//! 2026-11-25: "we prev did stuff with tool server sharing among other stuff... and if we own the
//! transport layer, could we also optimize for these cases?").
//!
//! A harness starts each stdio server of its own config (Claude Code's `~/.claude.json` and
//! `.mcp.json`, Codex's `config.toml`) as a child of its own: twenty chats with one `npx`
//! filesystem server hold twenty Node servers, 3.8 GB on a lane VM (acpmux#10, 2026-11-25). A
//! server the person shares ([`crate::agent_tools::shared_servers`]) instead goes to the harness
//! under its own name as `acpmux mcp-shim <socket> <key>`, which replaces the harness's entry of
//! that name: a relay of a few MB that copies the harness's stdio to the daemon's pool socket.
//! The daemon starts the real server on the first chat's connection, with the command, args, env
//! and folder of the person's entry ([`Spec`], kept 0600 in `run/mcp-pool/<key>.json`, so the
//! next daemon still knows it), and every chat whose entry launches the same thing shares it.
//!
//! The pool gives each chat its own JSON-RPC ids and progress tokens, answers a second chat's
//! `initialize` with the first one's answer and sends the server one `notifications/initialized`,
//! broadcasts the server's notifications, and sends each request of the server's (roots,
//! sampling, elicitation, ping) to the longest-connected chat. A server with no chat for
//! [`IDLE_STOP`] ends; the next chat starts it again. When the server or the daemon goes away the
//! shim answers the chat's open requests with an error, connects again and replays its
//! `initialize`, so the harness keeps its tools.

use anyhow::{Context as _, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;

/// The subcommand the harness runs in place of a shared server.
pub const SHIM_ARG: &str = "mcp-shim";
/// A server with no chat attached ends after this long.
pub const IDLE_STOP: Duration = Duration::from_secs(60);
/// After its stdin closes, a server has this long to exit before it is killed.
const STOP_GRACE: Duration = Duration::from_secs(3);
/// A server's stderr lines the daemon's log keeps per start.
const STDERR_LINES: usize = 20;
/// The longest line the pool takes from a chat or a server (a tool result with an image).
const MAX_LINE: usize = 64 << 20;
/// Where a subscription's notification names its `subscriptions/listen` request.
const SUBSCRIPTION_ID: &str = "/params/_meta/io.modelcontextprotocol~1subscriptionId";

/// One shared server's launch: what the person's entry starts, where.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct Spec {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Set over the daemon's environment.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub cwd: Option<PathBuf>,
}

impl Spec {
    /// The pool's name for this launch: the same command, args, env and folder share a server.
    pub fn key(&self) -> String {
        let bytes = serde_json::to_vec(self).unwrap_or_default();
        let digest = ring::digest::digest(&ring::digest::SHA256, &bytes);
        digest.as_ref()[..16].iter().map(|b| format!("{b:02x}")).collect()
    }
}

/// The pool's socket: beside the daemon's own (`acpmux.sock` gives `acpmux.mcp.sock`), so it is
/// as short and as private as that one.
pub fn socket_path() -> PathBuf {
    crate::config::socket_path().with_extension("mcp.sock")
}

fn spec_dir(home: &Path) -> PathBuf {
    home.join("run").join("mcp-pool")
}

/// Keep `spec` for the pool and give the stdio entry that reaches it: `{command, args}` of the
/// `acpmux mcp-shim` run. `None` when the spec cannot be kept (the chat then gets the person's
/// own entry, untouched).
pub fn register(home: &Path, spec: &Spec) -> Option<(PathBuf, Vec<String>)> {
    let key = spec.key();
    let known = specs().lock().unwrap_or_else(PoisonError::into_inner).contains_key(&key);
    if !known {
        let file = spec_dir(home).join(format!("{key}.json"));
        if let Err(e) = crate::agent_tools::write_private(
            &file,
            serde_json::to_vec(spec).unwrap_or_default().as_slice(),
        ) {
            tracing::warn!(
                "mcp pool: spec {} not written, server not shared: {e:#}",
                file.display()
            );
            return None;
        }
        specs().lock().unwrap_or_else(PoisonError::into_inner).insert(key.clone(), spec.clone());
    }
    let own = crate::self_command::SelfCommand::current().ok()?;
    let socket = socket_path().to_string_lossy().into_owned();
    // The path, not `program()`: the harness starts it, where `/proc/self/exe` is the harness.
    Some((own.exe.clone(), own.args_lossy(&[SHIM_ARG, &socket, &key])))
}

fn specs() -> &'static Mutex<HashMap<String, Spec>> {
    static SPECS: OnceLock<Mutex<HashMap<String, Spec>>> = OnceLock::new();
    SPECS.get_or_init(Mutex::default)
}

fn lookup(home: &Path, key: &str) -> Option<Spec> {
    if let Some(spec) = specs().lock().unwrap_or_else(PoisonError::into_inner).get(key) {
        return Some(spec.clone());
    }
    // A key is hex: never a path out of the folder.
    if key.is_empty() || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let data = std::fs::read(spec_dir(home).join(format!("{key}.json"))).ok()?;
    let spec: Spec = serde_json::from_slice(&data).ok()?;
    (spec.key() == key).then_some(spec)
}

struct Pool {
    home: PathBuf,
    scope: cmux_scope::Scope,
    servers: tokio::sync::Mutex<HashMap<String, Arc<Shared>>>,
    next_client: std::sync::atomic::AtomicU64,
}

static POOL: OnceLock<Arc<Pool>> = OnceLock::new();

/// Listen on [`socket_path`]. Servers start on their first chat. Called once, before any
/// session starts; a socket that cannot be bound leaves every server unshared.
pub async fn start(home: &Path) {
    let path = socket_path();
    match bind(&path) {
        Ok(listener) => {
            let pool = new_pool(home);
            if POOL.set(pool.clone()).is_ok() {
                pool.scope.spawn_named("mcp pool listener", serve(pool.clone(), listener));
            }
        }
        Err(e) => tracing::warn!("mcp pool: socket {}: {e:#}", path.display()),
    }
}

fn new_pool(home: &Path) -> Arc<Pool> {
    Arc::new(Pool {
        home: home.to_path_buf(),
        scope: cmux_scope::Scope::new("mcp pool"),
        servers: Default::default(),
        next_client: Default::default(),
    })
}

/// Whether the pool listens in this daemon: an entry goes to the shim only then.
pub fn listening() -> bool {
    POOL.get().is_some()
}

fn bind(path: &Path) -> Result<UnixListener> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    // The daemon before this one (an app update) let it go; a shim of its chats connects here
    // again.
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

async fn serve(pool: Arc<Pool>, listener: UnixListener) {
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                tracing::warn!("mcp pool: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let pool2 = pool.clone();
        pool.scope.spawn_named("mcp pool client", async move {
            if let Err(e) = client(pool2, stream).await {
                tracing::debug!("mcp pool: client: {e:#}");
            }
        });
    }
}

type Out = mpsc::UnboundedSender<String>;

struct Pending {
    client: u64,
    id: Value,
}

#[derive(Default)]
struct State {
    /// Lines for the running server's stdin, in order.
    to_server: Option<mpsc::UnboundedSender<String>>,
    child: Option<cmux_process::Child>,
    generation: u64,
    next: u64,
    clients: HashMap<u64, Out>,
    order: Vec<u64>,
    pending: HashMap<u64, Pending>,
    /// The id a request of the server's was given to its chat -> (chat, the server's own id).
    server_requests: HashMap<String, (u64, Value)>,
    /// A token the server got -> (chat, the chat's own token).
    progress: HashMap<String, (u64, Value)>,
    init_answer: Option<Value>,
    init_waiters: Vec<(u64, Value)>,
    init_id: Option<u64>,
    sent_initialized: bool,
    /// When the running server started, for the time its first answer took.
    started: Option<std::time::Instant>,
}

struct Shared {
    key: String,
    spec: Spec,
    st: Mutex<State>,
}

fn line(v: &Value) -> String {
    let mut s = v.to_string();
    s.push('\n');
    s
}

fn error(id: Value, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": message}})
}

impl Shared {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl State {
    fn send_server(&self, v: &Value) {
        if let Some(tx) = &self.to_server {
            let _ = tx.send(line(v));
        }
    }
    fn send_client(&self, client: u64, v: &Value) {
        if let Some(out) = self.clients.get(&client) {
            let _ = out.send(line(v));
        }
    }
}

/// Start the server when none runs. Its writer and reader run in `scope`.
fn ensure_server(sh: &Arc<Shared>, st: &mut State, scope: &cmux_scope::Scope) -> Result<()> {
    if st.to_server.is_some() {
        return Ok(());
    }
    let spec = &sh.spec;
    let mut command = cmux_process::Command::new(&spec.command);
    command
        .args(&spec.args)
        .envs(spec.env.iter())
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped());
    if let Some(cwd) = &spec.cwd {
        // As the harness's own launch: a folder that is gone fails the start.
        if !cwd.is_dir() {
            return Err(anyhow!("the server's folder {} is not there", cwd.display()));
        }
        command.current_dir(cwd);
    }
    let mut child = command.spawn().with_context(|| format!("start {}", spec.command))?;
    let stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
    let mut stdin = tokio::process::ChildStdin::from_std(stdin)?;
    let stdout = tokio::process::ChildStdout::from_std(stdout)?;
    let stderr = child.stderr.take().map(tokio::process::ChildStderr::from_std).transpose()?;
    tracing::info!(key = %sh.key, command = %spec.command, "mcp pool: shared server started");
    st.child = Some(child);
    st.generation += 1;
    st.init_answer = None;
    st.init_id = None;
    st.sent_initialized = false;
    st.started = Some(std::time::Instant::now());
    let generation = st.generation;
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    st.to_server = Some(tx);
    // Its own writer, so a server that stops reading never holds the pool's lock.
    scope.spawn_named("mcp pool server writer", async move {
        while let Some(l) = rx.recv().await {
            if stdin.write_all(l.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                break;
            }
        }
    });
    if let Some(stderr) = stderr {
        // What the server says on stderr, as the harness would log it: the first lines in the
        // daemon's log, the rest read and dropped so a chatty server never blocks.
        let key = sh.key.clone();
        scope.spawn_named("mcp pool server stderr", async move {
            let mut lines = BufReader::new(stderr).lines();
            let mut shown = 0;
            while let Ok(Some(l)) = lines.next_line().await {
                if shown < STDERR_LINES {
                    shown += 1;
                    let l: String = l.chars().take(300).collect();
                    tracing::info!(key = %key, "mcp pool: server stderr: {l}");
                }
            }
        });
    }
    let sh2 = sh.clone();
    scope.spawn_named("mcp pool server reader", async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(l)) = lines.next_line().await {
            if l.len() > MAX_LINE {
                continue;
            }
            let Ok(m) = serde_json::from_str::<Value>(&l) else { continue };
            from_server(&sh2, m);
        }
        reap(server_gone(&sh2, generation)).await;
    });
    Ok(())
}

/// The server's stdout closed: its chats' open requests fail and every chat is let go, so each
/// shim connects again, replays its `initialize` and starts a fresh server.
fn server_gone(sh: &Arc<Shared>, generation: u64) -> Option<cmux_process::Child> {
    {
        let mut st = sh.lock();
        if st.generation != generation {
            return None;
        }
        tracing::warn!(key = %sh.key, "mcp pool: shared server exited");
        st.to_server = None;
        for (_, p) in std::mem::take(&mut st.pending) {
            st.send_client(p.client, &error(p.id, "MCP server exited"));
        }
        for (client, id) in std::mem::take(&mut st.init_waiters) {
            st.send_client(client, &error(id, "MCP server exited"));
        }
        st.server_requests.clear();
        st.progress.clear();
        st.clients.clear();
        st.order.clear();
        st.child.take()
    }
}

/// Waits up to [`STOP_GRACE`] for a server whose stdin closed to exit; one still running then
/// is killed by the drop.
async fn reap(child: Option<cmux_process::Child>) {
    let Some(mut child) = child else { return };
    let until = tokio::time::Instant::now() + STOP_GRACE;
    while matches!(child.try_wait(), Ok(None)) && tokio::time::Instant::now() < until {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn from_server(sh: &Arc<Shared>, mut m: Value) {
    let mut st = sh.lock();
    let method = m.get("method").and_then(Value::as_str).map(str::to_owned);
    match (method, m.get("id").cloned()) {
        (None, Some(id)) => {
            let Some(g) = id.as_u64() else { return };
            if st.init_id == Some(g) {
                st.init_id = None;
                st.init_answer = Some(m.clone());
                let ms = st.started.map_or(0, |t| t.elapsed().as_millis());
                tracing::info!(key = %sh.key, ms, waiters = st.init_waiters.len(), "mcp pool: server initialized");
                for (client, id) in std::mem::take(&mut st.init_waiters) {
                    m["id"] = id;
                    st.send_client(client, &m);
                }
                return;
            }
            if let Some(p) = st.pending.remove(&g) {
                m["id"] = p.id;
                st.send_client(p.client, &m);
            }
        }
        (Some(_), Some(id)) => {
            // A request of the server's: the longest-connected chat answers it.
            match st.order.first().copied() {
                Some(client) => {
                    st.next += 1;
                    let given = format!("acpmux-pool-{}", st.next);
                    st.server_requests.insert(given.clone(), (client, id));
                    m["id"] = Value::String(given);
                    st.send_client(client, &m);
                }
                None => st.send_server(&error(id, "no chat attached")),
            }
        }
        (Some(method), None) => {
            // Progress goes to the chat whose request it is, with that chat's own token.
            if method == "notifications/progress" {
                let token = m.pointer("/params/progressToken").map(Value::to_string);
                if let Some((client, own)) = token.and_then(|t| st.progress.get(&t).cloned()) {
                    m["params"]["progressToken"] = own;
                    st.send_client(client, &m);
                }
                return;
            }
            if method == "notifications/cancelled" {
                return;
            }
            // A subscription's notifications (MCP 2026-07-28 `subscriptions/listen`) name the
            // listen request's id: they go to the chat that opened it, under its own id. Broadcast
            // with the pool's id, no chat would see its ack and each waits out its connect bound.
            if let Some(sub) = m.pointer(SUBSCRIPTION_ID).cloned() {
                if let Some(p) = sub.as_u64().and_then(|g| st.pending.get(&g)) {
                    let (client, own) = (p.client, p.id.clone());
                    if let Some(meta) = m.pointer_mut("/params/_meta") {
                        meta["io.modelcontextprotocol/subscriptionId"] = own;
                    }
                    st.send_client(client, &m);
                }
                return;
            }
            let l = line(&m);
            for out in st.clients.values() {
                let _ = out.send(l.clone());
            }
        }
        (None, None) => {}
    }
}

fn on_client(st: &mut State, client: u64, mut m: Value) {
    let method = m.get("method").and_then(Value::as_str).map(str::to_owned);
    match (method.as_deref(), m.get("id").cloned()) {
        (Some("initialize"), Some(id)) => {
            if let Some(answer) = &st.init_answer {
                let mut answer = answer.clone();
                answer["id"] = id;
                st.send_client(client, &answer);
                return;
            }
            st.init_waiters.push((client, id));
            if st.init_id.is_none() {
                st.next += 1;
                st.init_id = Some(st.next);
                m["id"] = json!(st.next);
                st.send_server(&m);
            }
        }
        (Some("notifications/initialized"), None) => {
            if !st.sent_initialized {
                st.sent_initialized = true;
                st.send_server(&m);
            }
        }
        (Some("notifications/cancelled"), None) => {
            let want = m.pointer("/params/requestId").cloned();
            let found = st
                .pending
                .iter()
                .find(|(_, p)| p.client == client && Some(&p.id) == want.as_ref())
                .map(|(g, _)| *g);
            if let Some(g) = found {
                m["params"]["requestId"] = json!(g);
                st.send_server(&m);
            }
        }
        (Some(_), Some(id)) => {
            st.next += 1;
            let g = st.next;
            if let Some(token) = m.pointer("/params/_meta/progressToken").cloned() {
                let given = format!("acpmux-pool-p{g}");
                st.progress.insert(Value::String(given.clone()).to_string(), (client, token));
                m["params"]["_meta"]["progressToken"] = Value::String(given);
            }
            st.pending.insert(g, Pending { client, id });
            m["id"] = json!(g);
            st.send_server(&m);
        }
        (None, Some(id)) => {
            // A chat's answer to a request of the server's.
            let given = id.as_str().map(str::to_owned).unwrap_or_else(|| id.to_string());
            if let Some((_, own)) = st.server_requests.remove(&given) {
                m["id"] = own;
                st.send_server(&m);
            }
        }
        (Some(_), None) => st.send_server(&m),
        (None, None) => {}
    }
}

async fn client(pool: Arc<Pool>, stream: UnixStream) -> Result<()> {
    let (r, mut w) = stream.into_split();
    let mut lines = BufReader::new(r).lines();
    // The shim's first line names the launch.
    let key = lines.next_line().await?.ok_or_else(|| anyhow!("no key"))?;
    let key = key.trim().to_owned();
    let sh = {
        let mut servers = pool.servers.lock().await;
        match servers.get(&key) {
            Some(sh) => sh.clone(),
            None => {
                let spec = lookup(&pool.home, &key).ok_or_else(|| anyhow!("unknown key {key}"))?;
                let sh = Arc::new(Shared { key: key.clone(), spec, st: Default::default() });
                servers.insert(key.clone(), sh.clone());
                sh
            }
        }
    };
    let id = pool.next_client.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    {
        let mut st = sh.lock();
        st.clients.insert(id, tx);
        st.order.push(id);
    }
    let writer = pool.scope.spawn_named("mcp pool client writer", async move {
        while let Some(l) = rx.recv().await {
            if w.write_all(l.as_bytes()).await.is_err() {
                break;
            }
        }
    });
    while let Ok(Some(l)) = lines.next_line().await {
        if l.len() > MAX_LINE {
            continue;
        }
        let Ok(m) = serde_json::from_str::<Value>(&l) else { continue };
        let mut st = sh.lock();
        if !st.clients.contains_key(&id) {
            break; // the server went away under this chat
        }
        if let Err(e) = ensure_server(&sh, &mut st, &pool.scope) {
            if let Some(rid) = m.get("id").filter(|_| m.get("method").is_some()) {
                st.send_client(id, &error(rid.clone(), &format!("cannot start MCP server: {e:#}")));
            }
            continue;
        }
        on_client(&mut st, id, m);
    }
    writer.abort();
    let idle = {
        let mut st = sh.lock();
        st.clients.remove(&id);
        st.order.retain(|c| *c != id);
        st.pending.retain(|_, p| p.client != id);
        st.init_waiters.retain(|(c, _)| *c != id);
        st.progress.retain(|_, (c, _)| *c != id);
        // A request of the server's this chat held goes to no one: the server hears so.
        let lost: Vec<String> = st
            .server_requests
            .iter()
            .filter(|(_, (c, _))| *c == id)
            .map(|(k, _)| k.clone())
            .collect();
        for k in lost {
            if let Some((_, own)) = st.server_requests.remove(&k) {
                st.send_server(&error(own, "the chat went away"));
            }
        }
        (st.clients.is_empty() && st.to_server.is_some()).then_some(st.generation)
    };
    if let Some(generation) = idle {
        let sh = sh.clone();
        pool.scope.spawn_until_cancelled("mcp pool idle stop", async move {
            tokio::time::sleep(IDLE_STOP).await;
            let child = {
                let mut st = sh.lock();
                if !st.clients.is_empty() || st.generation != generation {
                    return;
                }
                tracing::info!(key = %sh.key, "mcp pool: shared server idle, stopping");
                st.generation += 1;
                st.to_server = None; // closes its stdin
                st.child.take()
            };
            reap(child).await;
        });
    }
    Ok(())
}

/// `acpmux mcp-shim <socket> <key>`: the harness's stdio, relayed to the daemon's pool. Plain
/// threads and no runtime, so each copy stays small. When the daemon or the server goes away it
/// answers the open requests with an error, connects again and replays the harness's
/// `initialize`, so the harness keeps its tools across an app update.
pub fn shim_main(args: &[std::ffi::OsString]) -> Result<()> {
    let (Some(socket), Some(key)) = (args.first(), args.get(1)) else {
        return Err(anyhow!("usage: acpmux {SHIM_ARG} <socket> <key>"));
    };
    shim(
        Path::new(socket),
        &key.to_string_lossy(),
        std::io::BufReader::new(std::io::stdin()),
        std::io::stdout(),
    )
}

/// The id the shim gives a replayed `initialize`, whose answer the harness never sees.
const REPLAY_ID: &str = "acpmux-shim-replay";

#[derive(Default)]
struct ShimState {
    up: Option<std::os::unix::net::UnixStream>,
    initialize: Option<Value>,
    initialized: bool,
    /// The harness's requests with no answer yet, by their id's text.
    open: HashMap<String, Value>,
    /// The harness closed stdin: the shim is done.
    closed: bool,
}

/// The shim over the harness's `input` and `output`.
fn shim<I: std::io::BufRead + Send, O: std::io::Write + Send>(
    socket: &Path,
    key: &str,
    input: I,
    output: O,
) -> Result<()> {
    use std::io::{BufRead, Write};
    let state = Arc::new(Mutex::new(ShimState::default()));
    let out = Arc::new(Mutex::new(output));
    let write_out = |out: &Mutex<O>, v: &Value| {
        let mut o = out.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = o.write_all(line(v).as_bytes());
        let _ = o.flush();
    };
    // The first connection fails the start: the harness shows a server that did not start. It
    // is up before stdin is read, so the harness's first `initialize` always goes through.
    let first = std::os::unix::net::UnixStream::connect(socket)
        .with_context(|| format!("connect {}", socket.display()))?;
    {
        let mut up = first.try_clone()?;
        up.write_all(format!("{key}\n").as_bytes())?;
        state.lock().unwrap_or_else(PoisonError::into_inner).up = Some(up);
    }
    let mut first_stream = Some(first);
    // Scoped: the stdin reader ends at the harness's EOF, which also ends the relay.
    std::thread::scope(|threads| {
        {
            let state = state.clone();
            let out = out.clone();
            threads.spawn(move || {
                for l in input.lines() {
                    let Ok(l) = l else { break };
                    let Ok(m) = serde_json::from_str::<Value>(&l) else { continue };
                    let mut st = state.lock().unwrap_or_else(PoisonError::into_inner);
                    let method = m.get("method").and_then(Value::as_str);
                    match (method, m.get("id")) {
                        (Some("initialize"), Some(_)) => st.initialize = Some(m.clone()),
                        (Some("notifications/initialized"), None) => st.initialized = true,
                        _ => {}
                    }
                    let request = method.is_some().then(|| m.get("id").cloned()).flatten();
                    let sent =
                        st.up.as_mut().is_some_and(|up| up.write_all(line(&m).as_bytes()).is_ok());
                    match request {
                        Some(id) if sent => {
                            st.open.insert(id.to_string(), id);
                        }
                        // The next connection replays it under its own id: it is answered then.
                        Some(id) if method == Some("initialize") => {
                            st.open.insert(id.to_string(), id);
                        }
                        // Between connections a request fails at once; the harness can ask again.
                        Some(id) => {
                            write_out(&out, &error(id, "the shared MCP server is starting again"))
                        }
                        None => {}
                    }
                }
                // The harness is done with the server: the relay below sees its socket end.
                let mut st = state.lock().unwrap_or_else(PoisonError::into_inner);
                st.closed = true;
                if let Some(up) = st.up.take() {
                    let _ = up.shutdown(std::net::Shutdown::Both);
                }
            });
        }
        let mut backoff = Duration::from_millis(100);
        let closed =
            |state: &Mutex<ShimState>| state.lock().unwrap_or_else(PoisonError::into_inner).closed;
        loop {
            if closed(&state) {
                return Ok(());
            }
            let started = std::time::Instant::now();
            let stream = if let Some(s) = first_stream.take() {
                s
            } else {
                let stream = match std::os::unix::net::UnixStream::connect(socket) {
                    Ok(s) => s,
                    Err(_) => {
                        std::thread::sleep(backoff);
                        backoff = (backoff * 2).min(Duration::from_secs(5));
                        continue;
                    }
                };
                let mut up = stream.try_clone()?;
                let mut st = state.lock().unwrap_or_else(PoisonError::into_inner);
                let mut hello = format!("{key}\n");
                // A new daemon or server: it hears the harness's `initialize` again, under the
                // harness's own id when that one is still unanswered.
                if let Some(init) = &st.initialize {
                    let mut init = init.clone();
                    let own = init.get("id").map(Value::to_string);
                    if !own.is_some_and(|own| st.open.contains_key(&own)) {
                        init["id"] = json!(REPLAY_ID);
                    }
                    hello.push_str(&line(&init));
                }
                if st.initialized {
                    hello.push_str(&line(
                        &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                    ));
                }
                if st.closed {
                    return Ok(());
                }
                if up.write_all(hello.as_bytes()).is_err() {
                    continue;
                }
                st.up = Some(up);
                drop(st);
                stream
            };
            let reader = std::io::BufReader::new(stream);
            for l in reader.lines() {
                let Ok(l) = l else { break };
                let Ok(m) = serde_json::from_str::<Value>(&l) else { continue };
                if m.get("method").is_none()
                    && let Some(id) = m.get("id")
                {
                    if id == REPLAY_ID {
                        continue;
                    }
                    state
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .open
                        .remove(&id.to_string());
                }
                write_out(&out, &m);
            }
            if closed(&state) {
                return Ok(());
            }
            // The daemon or the server went away: the harness's open requests fail.
            let open = {
                let mut st = state.lock().unwrap_or_else(PoisonError::into_inner);
                st.up = None;
                std::mem::take(&mut st.open)
            };
            for (_, id) in open {
                write_out(
                    &out,
                    &error(id, "the shared MCP server went away; it is starting again"),
                );
            }
            if started.elapsed() > Duration::from_secs(30) {
                backoff = Duration::from_millis(100);
            }
            std::thread::sleep(backoff);
            backoff = (backoff * 2).min(Duration::from_secs(5));
        }
    })
}

#[cfg(test)]
#[path = "mcp_pool_tests.rs"]
mod tests;
