//! The `cmux` MCP server of every chat, served by the daemon over loopback HTTP instead of as a
//! stdio child of each harness. On Leo's NIGHTLY (2026-11-17, 15 open chats) each harness held
//! its own `cmux mcp serve` and that server's children for as long as the harness ran, most of
//! them for chats idle for days: 186 processes. Leo, 2026-11-16: "Agents stay alive if they need
//! to. Idle ones can obviously die".
//!
//! A harness gets `{"type": "http", "url": "http://127.0.0.1:PORT/mcp/<session>"}` with a bearer
//! token in place of the stdio `cmux` server ([`register`], `agent_tools::AgentTools::via_gateway`).
//! The daemon starts the chat's `cmux mcp serve` on its first request, with the command, env and
//! folder the stdio launch would have had, relays each request and routes each answer back by id,
//! and stops the server after [`IDLE_STOP`] with no request in flight. The next request starts it
//! again and replays the harness's `initialize` first, so the harness never sees the restart.
//! Nothing of acpmux's runs under a harness, so the idle pass's census never has to recognize it
//! (cmux#28933's class), and an idle chat holds no tool server process.
//!
//! The token is HMAC-SHA256 of the session id under a key kept with the port in
//! `run/mcp-gateway.json` (0600). The next daemon (an app update) binds the same port and takes the
//! same tokens, and finds each chat's launch in `run/mcp/<session>.gateway.json` (0600), so a
//! harness it adopts keeps its tools. A harness's config names a port, so the gateway never gives
//! up one it advertised: it waits [`HANDOVER_WAIT`] for the daemon it replaces to let the kept
//! port go ([`bind_kept`]) instead of taking a free one on the first `Address in use`, and when it
//! does have to move it remembers the port it left and binds it as well, as soon as it is free, for
//! the chats configured there (`earlier` in the record, [`bind_at`]).
//!
//! acpmux's own tool servers (`tools_mcp.rs` `SERVERS`) run in the daemon too, at
//! `/mcp/<session>/tools` with the same token: each of their upstream specs in the chat's
//! `cmux mcp serve` names it (`http`, [`tools_endpoint`]), so that server starts no
//! `acpmux tools-mcp` either. A request there runs the servers in-process, in a
//! [`crate::tool_env`] scope with the env the chat's `tools-mcp` would have had and this daemon
//! run's caller token for the session in the url; their calls go to the daemon's own socket over
//! one connection per chat, as the chat's `tools-mcp` did.
//!
//! A chat with no `cmux` server (the person has not said yes to cmux's tools in agents) has
//! acpmux's own servers as entries of their own, each its own stdio process under the harness:
//! five per chat on Leo's Mac, 2026-11-21. Each of them is an HTTP entry under its own name
//! instead, at `/mcp/<session>/tools/<server>` ([`Gateway::server_endpoint`]), so its tool names
//! stay the same and no process of theirs runs under the harness
//! (`agent_tools::AgentTools::via_gateway`).
//!
//! Only loopback, only a request whose `Host` names this listener and that carries no `Origin`
//! (no page in a browser reaches it), only `/mcp/<session>`, `/mcp/<session>/tools` and
//! `/mcp/<session>/tools/<server>` with that session's token.

use anyhow::{Context as _, Result, anyhow};
use cmux_process::{Child, Command};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::ChildStdin;
use tokio::sync::{mpsc, oneshot};

/// A chat's server ends after this long with no request in flight; its next request starts it
/// again. The same window as an upstream's in `cmux mcp serve` (`upstream::IDLE_STOP`).
pub const IDLE_STOP: Duration = Duration::from_secs(10 * 60);
/// `0` keeps every chat's `cmux` server a stdio child of its harness, as before.
pub const OFF_ENV: &str = "ACPMUX_MCP_GATEWAY";
/// How often the idle servers are looked for.
const REAP_EVERY: Duration = Duration::from_secs(30);
/// A started server's replayed `initialize`.
const START_TIMEOUT: Duration = Duration::from_secs(20);
/// After its stdin closes, a server has this long to end its own children and exit.
const STOP_GRACE: Duration = Duration::from_secs(3);
/// How long a gateway waits for the kept port before taking a free one ([`bind_kept`]): long
/// enough for the daemon it hands over from to let the port go.
pub const HANDOVER_WAIT: Duration = Duration::from_secs(10);
/// How often [`bind_kept`] tries the kept port again.
const BIND_RETRY_EVERY: Duration = Duration::from_millis(100);
/// How many earlier ports `run/mcp-gateway.json` remembers, for the harnesses configured at them.
const PORTS_REMEMBERED: usize = 8;
const MAX_HEAD: usize = 64 * 1024;
const MAX_BODY: usize = 32 * 1024 * 1024;
/// The id of the `initialize` the gateway replays to a server it started for a later request.
const REPLAY_ID: &str = "acpmux-gateway-initialize";

// test-hook-allow: holds no hook; only the daemon's start sets it, once, and tests bind their own Gateway
static GATEWAY: OnceLock<Arc<Gateway>> = OnceLock::new();

/// Where a harness reaches its chat's `cmux` server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub url: String,
    /// The `Authorization` header's value.
    pub authorization: String,
}

/// How a chat's server starts: what its stdio launch would have been.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Launch {
    pub command: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
}

/// A chat's kept launch file: the launch and the harness's last `initialize` params.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Kept {
    launch: Launch,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    initialize: Option<Value>,
}

/// `run/mcp-gateway.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Listener {
    port: u16,
    key: String,
    /// The ports earlier runs of this gateway advertised, most recent first: a harness started
    /// then still names one in its config, so a gateway serves each of them it can bind
    /// ([`bind_at`]). Written since 2026-11-22; an older record has none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    earlier: Vec<u16>,
    /// The daemon that bound `port`: a successor waits for the port only while this process
    /// still runs in this home ([`may_hand_over`]). Written since 2026-11-23; an older record has
    /// none, and its port is waited for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    holder: Option<Holder>,
}

/// The process that holds a gateway's port, as `run/mcp-gateway.json` names it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Holder {
    pid: u32,
    /// When it started (`process_identity::started_ms`): a later process under the same pid is
    /// not it.
    started_ms: u64,
    /// The acpmux home it served. A home copied from another one (a cloned machine, a copied
    /// test home) carries that home's record, whose port the original's daemon holds.
    home: PathBuf,
}

impl Holder {
    fn of_self(home: &Path) -> Option<Self> {
        let pid = std::process::id();
        let started_ms = cmux_tui_platform::process_identity::started_ms(pid)?;
        Some(Self { pid, started_ms, home: home.to_owned() })
    }
}

/// Whether the kept port, found taken, may be the daemon this one replaces letting it go: the
/// record's holder still runs and served this home (or the record is older and names none). Any
/// other program holding it never lets go for this home, and waiting [`HANDOVER_WAIT`] for it
/// only made the start miss its readiness budget (`daemon::START_BUDGET`): own-machines-e2e's
/// clone-own-identity went red on 2026-11-22, a copied home's `daemon start` failing while the
/// original's daemon kept its gateway port.
fn may_hand_over(kept: &Listener, home: &Path) -> bool {
    let Some(holder) = kept.holder.as_ref() else { return true };
    let same_home = holder.home == home
        || std::fs::canonicalize(&holder.home)
            .is_ok_and(|held| std::fs::canonicalize(home).is_ok_and(|here| held == here));
    same_home
        && cmux_tui_platform::process_identity::started_ms(holder.pid) == Some(holder.started_ms)
}

pub struct Gateway {
    port: u16,
    /// The earlier ports this gateway bound as well as `port`, all serving the same routes and
    /// tokens.
    recovered: Vec<u16>,
    key: Vec<u8>,
    home: PathBuf,
    /// The daemon socket the tool servers' calls go to.
    socket: PathBuf,
    idle: Duration,
    /// Every task of the gateway and its servers' readers.
    scope: Arc<cmux_scope::Scope>,
    chats: Mutex<HashMap<String, Arc<Chat>>>,
}

struct Chat {
    id: String,
    /// Its kept launch file.
    file: PathBuf,
    scope: Arc<cmux_scope::Scope>,
    kept: Mutex<Kept>,
    server: tokio::sync::Mutex<Option<Arc<Server>>>,
    /// Its tool servers' daemon connection, made by their first call.
    tools_daemon: Arc<crate::tools_mcp::Daemon>,
    /// Its tool servers, made by their first request for the launch they were made from.
    tools: Mutex<Option<(Launch, Arc<Vec<crate::tools_mcp::Served>>)>>,
    last: Mutex<Instant>,
    inflight: AtomicUsize,
}

/// One running `cmux mcp serve`.
struct Server {
    child: Mutex<Option<Child>>,
    stdin: tokio::sync::Mutex<Option<ChildStdin>>,
    waiting: Arc<Mutex<HashMap<String, Waiter>>>,
    alive: Arc<AtomicBool>,
}

struct Waiter {
    reply: oneshot::Sender<Value>,
    /// The request's `_meta.progressToken`: its `notifications/progress` go to `progress`.
    token: Option<Value>,
    progress: Option<mpsc::UnboundedSender<Value>>,
}

/// The daemon's gateway, once [`start`] bound it.
pub fn current() -> Option<Arc<Gateway>> {
    GATEWAY.get().cloned()
}

/// Whether sessions started now get the gateway: it runs and [`OFF_ENV`] is not `0`.
pub fn active() -> Option<Arc<Gateway>> {
    if std::env::var(OFF_ENV).is_ok_and(|v| v.trim() == "0") {
        return None;
    }
    current()
}

/// The chat's endpoint after keeping its launch, or `None` without a gateway (the harness then
/// gets the stdio server). A launch that differs from the kept one stops the running server, so
/// the next request starts the new one.
pub fn register(session: &str, launch: Launch) -> Option<Endpoint> {
    active()?.register(session, launch)
}

/// The chat ended: its server stops and its launch file goes.
pub fn forget(home: &Path, session: &str) {
    let _ = crate::home_fs::remove_file(launch_path(home, session));
    if let Some(gateway) = current() {
        let chat = gateway.chats.lock().unwrap_or_else(PoisonError::into_inner).remove(session);
        if let (Some(chat), Ok(_)) = (chat, tokio::runtime::Handle::try_current()) {
            let scope = chat.scope.clone();
            scope.spawn_named("mcp gateway stop", async move { chat.stop().await });
        }
    }
}

/// Binds the daemon's gateway ([`bind`]) and makes it the one sessions get. The daemon calls it
/// before any session starts, so each harness then gets the `cmux` server over HTTP. A gateway
/// that does not bind is logged: each harness keeps its stdio server, as before.
pub async fn start(home: &Path) {
    match bind(home, IDLE_STOP, REAP_EVERY).await {
        Ok(gateway) => {
            match gateway.recovered_ports() {
                [] => tracing::info!("mcp gateway on 127.0.0.1:{}", gateway.port),
                ports => tracing::info!(
                    "mcp gateway on 127.0.0.1:{}, and on {ports:?} for the chats configured there \
                     before a restart moved it",
                    gateway.port
                ),
            }
            let _ = GATEWAY.set(gateway);
        }
        Err(e) => {
            tracing::warn!("mcp gateway not started; chats keep their own cmux MCP server: {e:#}");
        }
    }
}

/// Binds a gateway (the kept port when it is free), keeps its port and key, and serves it,
/// stopping a chat's server after `idle` with no request, looked for every `reap_every`.
pub async fn bind(home: &Path, idle: Duration, reap_every: Duration) -> Result<Arc<Gateway>> {
    bind_at(home, crate::config::socket_path(), idle, reap_every, HANDOVER_WAIT).await
}

/// [`bind`], its tool servers' calls going to the daemon at `socket`, waiting `handover` for the
/// kept port.
pub async fn bind_at(
    home: &Path,
    socket: PathBuf,
    idle: Duration,
    reap_every: Duration,
    handover: Duration,
) -> Result<Arc<Gateway>> {
    let path = home.join("run").join("mcp-gateway.json");
    let kept: Option<Listener> =
        std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok());
    let key = match kept.as_ref().map(|k| decode_hex(&k.key)) {
        Some(Some(key)) if key.len() == 32 => key,
        _ => {
            let mut key = vec![0u8; 32];
            getrandom::fill(&mut key).map_err(|e| anyhow!("the OS random generator: {e}"))?;
            key
        }
    };
    let mut earlier: Vec<u16> = kept.as_ref().map(|k| k.earlier.clone()).unwrap_or_default();
    // A port held by anything but the daemon this one replaces is not waited for.
    let handover = match kept.as_ref() {
        Some(kept) if !may_hand_over(kept, home) => Duration::ZERO,
        _ => handover,
    };
    let listener = match kept.as_ref().map(|k| k.port).filter(|p| *p != 0) {
        Some(port) => match bind_kept(port, handover).await {
            Ok(l) => l,
            Err(e) => {
                // New chats get the free port; the kept one stays in `earlier`, so the harnesses
                // configured at it reach their tools again as soon as a daemon can bind it.
                tracing::warn!(
                    "mcp gateway: port {port} is still taken after {handover:?} ({e}); taking a \
                     free one and keeping {port} in run/mcp-gateway.json"
                );
                earlier.insert(0, port);
                TcpListener::bind(("127.0.0.1", 0)).await?
            }
        },
        None => TcpListener::bind(("127.0.0.1", 0)).await?,
    };
    let port = listener.local_addr()?.port();
    let mut seen = std::collections::HashSet::new();
    earlier.retain(|p| *p != 0 && *p != port && seen.insert(*p));
    earlier.truncate(PORTS_REMEMBERED);
    // Every earlier port that is free now, served with this gateway's routes and tokens.
    let mut recovered = Vec::new();
    let mut listeners = vec![listener];
    for earlier in &earlier {
        match TcpListener::bind(("127.0.0.1", *earlier)).await {
            Ok(l) => {
                recovered.push(*earlier);
                listeners.push(l);
            }
            Err(e) => tracing::debug!("mcp gateway: earlier port {earlier} is not free ({e})"),
        }
    }
    let record = Listener { port, key: encode_hex(&key), earlier, holder: Holder::of_self(home) };
    crate::agent_tools::write_private(&path, &serde_json::to_vec(&record)?)
        .context("mcp gateway: keeping the port and key")?;
    let gateway = Arc::new(Gateway {
        port,
        recovered,
        key,
        home: home.to_owned(),
        socket,
        idle,
        scope: Arc::new(cmux_scope::Scope::new("mcp gateway")),
        chats: Mutex::new(HashMap::new()),
    });
    for listener in listeners {
        gateway.scope.spawn_named("mcp gateway listener", serve(gateway.clone(), listener));
    }
    gateway.scope.spawn_named("mcp gateway idle stop", reap(gateway.clone(), reap_every));
    Ok(gateway)
}

/// Binds the kept port, trying again until `wait` runs out. A daemon hands over to its successor:
/// the successor starts while the daemon it replaces still holds the port and only exits a second
/// or so later (`daemon.stops.json`, `handover: another daemon of this home starts`). Taking a
/// free port on the first `Address in use` made every restart move the gateway, and each move
/// stranded every live harness, whose config names the port it was started with (big-red,
/// 2026-11-22: eight restarts, eight new ports, `ECONNREFUSED ... dialing
/// http://127.0.0.1:41227/mcp/...` in a chat for the rest of its life).
async fn bind_kept(port: u16, wait: Duration) -> std::io::Result<TcpListener> {
    let deadline = Instant::now() + wait;
    loop {
        match TcpListener::bind(("127.0.0.1", port)).await {
            Ok(listener) => return Ok(listener),
            Err(e) => {
                if Instant::now() >= deadline {
                    return Err(e);
                }
                tokio::time::sleep(BIND_RETRY_EVERY).await;
            }
        }
    }
}

/// A Claude Code config with each gateway server put back as the stdio launch it stands for, for
/// readers that judge the `cmux` server by its args and env (`bg_hook::route`).
pub fn stdio_view(home: &Path, session: &str, mut config: Value) -> Value {
    let Some(servers) = config.get_mut("mcpServers").and_then(Value::as_object_mut) else {
        return config;
    };
    let kept = || -> Option<Kept> {
        serde_json::from_slice(&std::fs::read(launch_path(home, session)).ok()?).ok()
    };
    // Only this chat's own gateway entry: another HTTP server is the user's, whatever its path.
    let Some(listener) = std::fs::read(home.join("run").join("mcp-gateway.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Listener>(&b).ok())
    else {
        return config;
    };
    // Its current port, and the earlier ones it still serves: a config written before a restart
    // names one of those.
    let ours: Vec<String> = std::iter::once(listener.port)
        .chain(listener.earlier.iter().copied())
        .map(|port| format!("http://127.0.0.1:{port}/mcp/{session}"))
        .collect();
    for server in servers.values_mut() {
        if server.get("type").and_then(Value::as_str) != Some("http")
            || !server
                .get("url")
                .and_then(Value::as_str)
                .is_some_and(|url| ours.iter().any(|ours| ours == url))
        {
            continue;
        }
        if let Some(kept) = kept() {
            let env: serde_json::Map<String, Value> =
                kept.launch.env.into_iter().map(|(k, v)| (k, Value::String(v))).collect();
            *server = json!({"type": "stdio", "command": kept.launch.command, "args": kept.launch.args, "env": env});
        }
    }
    config
}

/// `<home>/run/mcp/<session>.gateway.json`, beside the session's Claude Code config.
pub fn launch_path(home: &Path, session: &str) -> PathBuf {
    let config = crate::agent_tools::mcp_config_path(home, session);
    config.with_extension("gateway.json")
}

impl Gateway {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The earlier ports it serves besides [`Gateway::port`], for the harnesses configured at
    /// them before a restart moved the gateway.
    pub fn recovered_ports(&self) -> &[u16] {
        &self.recovered
    }

    /// Every port it serves: `port` first, then the earlier ones it took back.
    fn ports(&self) -> impl Iterator<Item = u16> + '_ {
        std::iter::once(self.port).chain(self.recovered.iter().copied())
    }

    pub fn endpoint(&self, session: &str) -> Endpoint {
        Endpoint {
            url: format!("http://127.0.0.1:{}/mcp/{session}", self.port),
            authorization: format!("Bearer {}", self.token(session)),
        }
    }

    /// Where the chat's `cmux mcp serve` reaches acpmux's own tool servers: the chat's endpoint
    /// and token, at `/tools`.
    pub fn tools_endpoint(&self, session: &str) -> Endpoint {
        let Endpoint { url, authorization } = self.endpoint(session);
        Endpoint { url: format!("{url}/tools"), authorization }
    }

    /// Where a harness reaches acpmux's own server `name` of the chat as its own entry (no `cmux`
    /// server in front of it): the tool endpoint, the server named by the path.
    pub fn server_endpoint(&self, session: &str, name: &str) -> Endpoint {
        let Endpoint { url, authorization } = self.tools_endpoint(session);
        Endpoint { url: format!("{url}/{name}"), authorization }
    }

    /// [`register`] on this gateway.
    pub fn register(&self, session: &str, launch: Launch) -> Option<Endpoint> {
        self.keep(session, launch)
            .map_err(|e| tracing::warn!("mcp gateway: {session}: {e:#}"))
            .ok()?;
        Some(self.endpoint(session))
    }

    /// The env the chat's `acpmux tools-mcp` would have had, for its servers run here: the
    /// `cmux` server's launch env, then each of acpmux's own upstream specs' env, then this daemon
    /// run's caller token for `session`, sent only to this gateway's daemon socket. Each server's
    /// session is `session`.
    fn tools_env(&self, session: &str, launch: &Launch) -> HashMap<String, String> {
        let upstreams_key = crate::agent_tools::UPSTREAMS_ENV;
        let mut env: HashMap<String, String> = launch.env.iter().cloned().collect();
        let specs: Vec<Value> = env
            .remove(upstreams_key)
            .and_then(|specs| serde_json::from_str(&specs).ok())
            .unwrap_or_default();
        for spec in &specs {
            let name = spec["name"].as_str().unwrap_or_default();
            let args: Vec<String> = spec["args"]
                .as_array()
                .map(|args| args.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            if !crate::tools_mcp::owns(name, &args) {
                continue;
            }
            for (key, value) in spec["env"].as_object().into_iter().flatten() {
                if let Some(value) = value.as_str() {
                    env.insert(key.clone(), value.to_owned());
                }
            }
        }
        let socket = self.socket.to_string_lossy().into_owned();
        env.insert("ACPMUX_SOCKET".to_owned(), socket.clone());
        env.insert(
            crate::person_tokens::CALLER_TOKEN_ENV.to_owned(),
            crate::person_tokens::caller_token(session),
        );
        env.insert(crate::person_tokens::CALLER_SOCKET_ENV.to_owned(), socket);
        for key in [
            crate::acpmux_mcp_names::SESSION_ENV,
            crate::secret_mcp::SESSION_ENV,
            crate::offer_mcp::SESSION_ENV,
        ] {
            if let Some(value) = env.get_mut(key) {
                *value = session.to_owned();
            }
        }
        env
    }

    fn token(&self, session: &str) -> String {
        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &self.key);
        encode_hex(ring::hmac::sign(&key, session.as_bytes()).as_ref())
    }

    /// The pid of the chat's running server.
    pub async fn server_pid(&self, session: &str) -> Option<u32> {
        let chat =
            self.chats.lock().unwrap_or_else(PoisonError::into_inner).get(session).cloned()?;
        let server = chat.server.lock().await.clone()?;
        let child = server.child.lock().unwrap_or_else(PoisonError::into_inner);
        child.as_ref().map(Child::id).filter(|_| server.live())
    }

    /// How many chats have a server running now.
    pub fn running(&self) -> usize {
        let chats: Vec<_> =
            self.chats.lock().unwrap_or_else(PoisonError::into_inner).values().cloned().collect();
        chats
            .iter()
            .filter(|c| c.server.try_lock().map_or(true, |s| s.as_ref().is_some_and(|s| s.live())))
            .count()
    }

    pub fn keep(&self, session: &str, launch: Launch) -> Result<()> {
        if !valid_session(session) {
            return Err(anyhow!("not a session id"));
        }
        let path = launch_path(&self.home, session);
        let mut chats = self.chats.lock().unwrap_or_else(PoisonError::into_inner);
        let before = chats
            .get(session)
            .map(|c| c.kept.lock().unwrap_or_else(PoisonError::into_inner).clone());
        // The harness starting again sends `initialize` again; until then a kept one replays.
        let initialize =
            before.as_ref().filter(|k| k.launch == launch).and_then(|k| k.initialize.clone());
        let kept = Kept { launch, initialize };
        crate::agent_tools::write_private(&path, &serde_json::to_vec(&kept)?)?;
        match chats.get(session) {
            Some(_) if before.as_ref().is_some_and(|k| k.launch == kept.launch) => {}
            Some(chat) => {
                *chat.kept.lock().unwrap_or_else(PoisonError::into_inner) = kept;
                let chat = chat.clone();
                if tokio::runtime::Handle::try_current().is_ok() {
                    let scope = chat.scope.clone();
                    scope.spawn_named("mcp gateway stop", async move { chat.stop().await });
                }
            }
            None => {
                let chat = Chat::new(session, path, kept, self);
                chats.insert(session.to_owned(), Arc::new(chat));
            }
        }
        Ok(())
    }

    /// The chat, from memory or from its kept launch (a chat an earlier daemon registered).
    fn chat(&self, session: &str) -> Option<Arc<Chat>> {
        let mut chats = self.chats.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(chat) = chats.get(session) {
            return Some(chat.clone());
        }
        let file = launch_path(&self.home, session);
        let kept: Kept = serde_json::from_slice(&std::fs::read(&file).ok()?).ok()?;
        let chat = Arc::new(Chat::new(session, file, kept, self));
        chats.insert(session.to_owned(), chat.clone());
        Some(chat)
    }

    fn authorized(&self, session: &str, header: Option<&str>) -> bool {
        let Some(given) = header.and_then(|h| h.strip_prefix("Bearer ")) else {
            return false;
        };
        let want = self.token(session);
        given.len() == want.len()
            && given.bytes().zip(want.bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
    }
}

impl Chat {
    fn new(id: &str, file: PathBuf, kept: Kept, gateway: &Gateway) -> Self {
        Chat {
            id: id.to_owned(),
            file,
            scope: gateway.scope.clone(),
            kept: Mutex::new(kept),
            server: tokio::sync::Mutex::new(None),
            tools_daemon: Arc::new(crate::tools_mcp::Daemon::at(gateway.socket.clone())),
            tools: Mutex::new(None),
            last: Mutex::new(Instant::now()),
            inflight: AtomicUsize::new(0),
        }
    }

    /// Its tool servers for the env `env` ([`Gateway::tools_env`]) of `launch`: the ones made
    /// for that launch, else made now in that env (each reads its session and its tool list
    /// from it, as its own process reads them at its start).
    fn tools(
        &self,
        launch: &Launch,
        env: &HashMap<String, String>,
    ) -> Arc<Vec<crate::tools_mcp::Served>> {
        let mut held = self.tools.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((made_for, servers)) = held.as_ref()
            && made_for == launch
        {
            return servers.clone();
        }
        let servers = Arc::new(crate::tool_env::sync_scope(env.clone(), || {
            crate::tools_mcp::servers(&self.tools_daemon)
        }));
        *held = Some((launch.clone(), servers.clone()));
        servers
    }

    /// An idle chat's tool servers go with their daemon connection; its next request makes them
    /// again.
    fn release_tools(&self) {
        self.tools.lock().unwrap_or_else(PoisonError::into_inner).take();
        self.tools_daemon.release();
    }

    fn touch(&self) {
        *self.last.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
    }

    fn idle_for(&self) -> Duration {
        self.last.lock().unwrap_or_else(PoisonError::into_inner).elapsed()
    }

    /// The running server, or a new one. A server started for anything but `initialize` gets the
    /// harness's kept `initialize` first.
    async fn server(&self, for_initialize: bool) -> Result<Arc<Server>> {
        let mut slot = self.server.lock().await;
        if let Some(server) = slot.as_ref().filter(|s| s.live()) {
            return Ok(server.clone());
        }
        let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let server = Arc::new(Server::spawn(&kept.launch, &self.scope).with_context(|| {
            format!("starting {} for {}", kept.launch.command.display(), self.id)
        })?);
        if !for_initialize {
            let params = kept.initialize.unwrap_or_else(|| {
                json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "acpmux", "version": env!("CARGO_PKG_VERSION")}})
            });
            let ask = json!({"jsonrpc": "2.0", "id": REPLAY_ID, "method": "initialize", "params": params});
            let (reply, _) = server.send(&ask, None).await?;
            let reply = tokio::time::timeout(START_TIMEOUT, reply)
                .await
                .map_err(|_| anyhow!("the server did not answer initialize"))?
                .map_err(|_| anyhow!("the server ended before it answered initialize"))?;
            if let Some(error) = reply.get("error") {
                return Err(anyhow!("initialize: {error}"));
            }
            server.write(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await?;
        }
        *slot = Some(server.clone());
        Ok(server)
    }

    async fn stop(&self) {
        let server = self.server.lock().await.take();
        if let Some(server) = server {
            server.stop().await;
        }
    }
}

impl Server {
    /// Starts the server; its reader runs in `scope`. The [`Child`] ends it when dropped.
    fn spawn(launch: &Launch, scope: &cmux_scope::Scope) -> Result<Self> {
        let mut command = Command::new(&launch.command);
        command
            .args(&launch.args)
            .envs(launch.env.iter().map(|(k, v)| (k, v)))
            .stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null());
        // As the harness's own stdio launch: a chat folder that is gone fails the start, never
        // runs the tools in the daemon's folder.
        if let Some(cwd) = &launch.cwd {
            if !cwd.is_dir() {
                return Err(anyhow!("the chat's folder {} is not there", cwd.display()));
            }
            command.current_dir(cwd);
        }
        let mut child = command.spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
        let stdin = tokio::process::ChildStdin::from_std(stdin)?;
        let stdout = tokio::process::ChildStdout::from_std(stdout)?;
        let waiting: Arc<Mutex<HashMap<String, Waiter>>> = Arc::default();
        let alive = Arc::new(AtomicBool::new(true));
        scope.spawn_named(
            "mcp gateway reader",
            read_answers(stdout, waiting.clone(), alive.clone()),
        );
        Ok(Server {
            child: Mutex::new(Some(child)),
            stdin: tokio::sync::Mutex::new(Some(stdin)),
            waiting,
            alive,
        })
    }

    fn live(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    async fn write(&self, message: &Value) -> Result<()> {
        let mut line = serde_json::to_vec(message)?;
        line.push(b'\n');
        let mut stdin = self.stdin.lock().await;
        let pipe = stdin.as_mut().ok_or_else(|| anyhow!("the server is stopping"))?;
        if let Err(e) = pipe.write_all(&line).await {
            self.alive.store(false, Ordering::SeqCst);
            return Err(e.into());
        }
        Ok(())
    }

    /// Sends request `message` and gives the receiver of its answer, and of its progress when
    /// `progress` is set.
    async fn send(
        &self,
        message: &Value,
        progress: Option<mpsc::UnboundedSender<Value>>,
    ) -> Result<(oneshot::Receiver<Value>, ())> {
        let id = message.get("id").map(Value::to_string).ok_or_else(|| anyhow!("no id"))?;
        let token = message.pointer("/params/_meta/progressToken").cloned();
        let (tx, rx) = oneshot::channel();
        self.waiting
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id.clone(), Waiter { reply: tx, token, progress });
        if let Err(e) = self.write(message).await {
            self.waiting.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            return Err(e);
        }
        Ok((rx, ()))
    }

    /// Closes stdin so the server ends its own children and exits; kills it after [`STOP_GRACE`].
    async fn stop(&self) {
        self.alive.store(false, Ordering::SeqCst);
        drop(self.stdin.lock().await.take());
        let child = self.child.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(mut child) = child {
            // A server still running after the grace is signalled and reaped by the drop.
            let _ = tokio::task::spawn_blocking(move || {
                let _ = child.wait_timeout(STOP_GRACE);
                drop(child);
            })
            .await;
        }
    }
}

/// Routes each line of the server's stdout: an answer to its request, a progress notification to
/// the request that carries its token. Other messages (the list-changed notice) have no request
/// to go back on and are dropped: a harness lists again when it starts.
async fn read_answers(
    stdout: tokio::process::ChildStdout,
    waiting: Arc<Mutex<HashMap<String, Waiter>>>,
    alive: Arc<AtomicBool>,
) {
    let mut lines = BufReader::new(stdout).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let waiting = &mut *waiting.lock().unwrap_or_else(PoisonError::into_inner);
        if message.get("method").and_then(Value::as_str) == Some("notifications/progress") {
            let token = message.pointer("/params/progressToken");
            if let Some(w) = waiting.values().find(|w| w.token.as_ref() == token && token.is_some())
                && let Some(progress) = &w.progress
            {
                let _ = progress.send(message);
            }
            continue;
        }
        if message.get("method").is_none()
            && let Some(id) = message.get("id").map(Value::to_string)
            && let Some(w) = waiting.remove(&id)
        {
            let _ = w.reply.send(message);
        }
    }
    alive.store(false, Ordering::SeqCst);
    // Every request still waiting gets its error: the receivers see their senders drop.
    waiting.lock().unwrap_or_else(PoisonError::into_inner).clear();
}

async fn serve(gateway: Arc<Gateway>, listener: TcpListener) {
    loop {
        match listener.accept().await {
            Ok((stream, peer)) if peer.ip().is_loopback() => {
                gateway
                    .scope
                    .spawn_named("mcp gateway request", connection(gateway.clone(), stream));
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!("mcp gateway: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// Stops each chat's server that had no request in flight for the gateway's idle window.
async fn reap(gateway: Arc<Gateway>, every: Duration) {
    loop {
        tokio::time::sleep(every).await;
        let chats: Vec<_> = gateway
            .chats
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for chat in chats {
            if chat.inflight.load(Ordering::SeqCst) == 0 && chat.idle_for() >= gateway.idle {
                chat.release_tools();
                let server = match chat.server.try_lock() {
                    Ok(mut slot) => slot.take(),
                    Err(_) => None,
                };
                if let Some(server) = server {
                    tracing::debug!(session = %chat.id, "mcp gateway: idle server stops");
                    server.stop().await;
                }
            }
        }
    }
}

struct Request {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Request {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

/// One request per connection: the answer closes it.
async fn connection(gateway: Arc<Gateway>, mut stream: TcpStream) {
    let request = match read_request(&mut stream).await {
        Ok(r) => r,
        Err(e) => {
            let _ = respond(&mut stream, "400 Bad Request", "text/plain", e.to_string().as_bytes())
                .await;
            return;
        }
    };
    // Any port this gateway listens on: a harness configured before a restart names an earlier
    // one ([`bind_at`]), and its `Host` is the port it dialed.
    let host_ok = request.header("host").is_some_and(|h| {
        gateway.ports().any(|port| {
            h == format!("127.0.0.1:{port}")
                || h == format!("localhost:{port}")
                || h == format!("[::1]:{port}")
        })
    });
    if !host_ok || request.header("origin").is_some() {
        let _ = respond(&mut stream, "403 Forbidden", "text/plain", b"forbidden").await;
        return;
    }
    let path = request.path.split_once('?').map_or(request.path.as_str(), |(p, _)| p);
    let rest = path.strip_prefix("/mcp/").unwrap_or_default();
    // `/mcp/<session>/tools/<server>`: one of acpmux's own servers, named by the path, for a
    // harness that has it as its own entry (no `cmux` server to name it in `_meta`).
    let (session, tools, server) = match rest.split_once("/tools/") {
        Some((session, name)) => (session, true, Some(name)),
        None => match rest.strip_suffix("/tools") {
            Some(session) => (session, true, None),
            None => (rest, false, None),
        },
    };
    let server = match server {
        None => None,
        Some(name) => match crate::tools_mcp::SERVERS.iter().find(|(n, _)| *n == name) {
            Some((name, _)) => Some(*name),
            None => {
                let _ = respond(&mut stream, "404 Not Found", "text/plain", b"not found").await;
                return;
            }
        },
    };
    if !valid_session(session) {
        let _ = respond(&mut stream, "404 Not Found", "text/plain", b"not found").await;
        return;
    }
    if !gateway.authorized(session, request.header("authorization")) {
        let _ = respond(&mut stream, "401 Unauthorized", "text/plain", b"unauthorized").await;
        return;
    }
    let Some(chat) = gateway.chat(session) else {
        let _ = respond(&mut stream, "404 Not Found", "text/plain", b"no such chat").await;
        return;
    };
    match request.method.as_str() {
        "POST" if tools => post_tools(&gateway, &chat, &request, server, &mut stream).await,
        "POST" => post(&chat, &request, &mut stream).await,
        "DELETE" if tools => {
            let _ = respond(&mut stream, "200 OK", "text/plain", b"").await;
        }
        // No server-sent stream of its own: a notice with no request to answer is dropped.
        "GET" => {
            let _ = respond(&mut stream, "405 Method Not Allowed", "text/plain", b"").await;
        }
        "DELETE" => {
            chat.stop().await;
            let _ = respond(&mut stream, "200 OK", "text/plain", b"").await;
        }
        _ => {
            let _ = respond(&mut stream, "405 Method Not Allowed", "text/plain", b"").await;
        }
    }
}

/// The request's one JSON-RPC message, or None once it answered that there is none.
async fn message_of(request: &Request, stream: &mut TcpStream) -> Option<Value> {
    match serde_json::from_slice(&request.body) {
        Ok(v @ Value::Object(_)) => Some(v),
        _ => {
            let error = json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "one JSON-RPC message per request"}});
            let _ = respond(
                stream,
                "400 Bad Request",
                "application/json",
                error.to_string().as_bytes(),
            )
            .await;
            None
        }
    }
}

/// A request to acpmux's own tool servers of the chat, answered here (`tools_mcp::answer`) in
/// the chat's tool env. A call runs in this request's own task, so a card that waits on the
/// person for up to an hour holds no other request.
async fn post_tools(
    gateway: &Gateway,
    chat: &Arc<Chat>,
    request: &Request,
    server: Option<&'static str>,
    stream: &mut TcpStream,
) {
    let Some(mut message) = message_of(request, stream).await else { return };
    if let Some(name) = server {
        for_server(&mut message, name);
    }
    chat.touch();
    if message.get("id").is_none() {
        // `initialized` and the like: the servers here keep no state for them.
        let _ = respond(stream, "202 Accepted", "text/plain", b"").await;
        return;
    }
    let launch = chat.kept.lock().unwrap_or_else(PoisonError::into_inner).launch.clone();
    let env = gateway.tools_env(&chat.id, &launch);
    let servers = chat.tools(&launch, &env);
    chat.inflight.fetch_add(1, Ordering::SeqCst);
    let answer = crate::tool_env::scope(env, async {
        match crate::tools_mcp::answer(&servers, &message) {
            crate::tools_mcp::Answer::None => None,
            crate::tools_mcp::Answer::Now(answer) => Some(answer),
            crate::tools_mcp::Answer::Call(call) => Some(call.await),
        }
    })
    .await;
    chat.inflight.fetch_sub(1, Ordering::SeqCst);
    chat.touch();
    let _ = match answer {
        Some(answer) => {
            respond(stream, "200 OK", "application/json", answer.to_string().as_bytes()).await
        }
        None => respond(stream, "202 Accepted", "text/plain", b"").await,
    };
}

/// `message` for server `name` of a chat's tool servers: its params' `_meta` names it
/// ([`crate::tools_mcp::SERVER_META`]) as the `cmux` server's request would, whatever the
/// harness put there.
fn for_server(message: &mut Value, name: &str) {
    let Some(fields) = message.as_object_mut() else { return };
    let params = fields.entry("params").or_insert_with(|| json!({}));
    if !params.is_object() {
        *params = json!({});
    }
    let Some(params) = params.as_object_mut() else { return };
    let meta = params.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    if let Some(meta) = meta.as_object_mut() {
        meta.insert(crate::tools_mcp::SERVER_META.to_owned(), json!(name));
    }
}

async fn post(chat: &Arc<Chat>, request: &Request, stream: &mut TcpStream) {
    let Some(message) = message_of(request, stream).await else { return };
    chat.touch();
    let method = message.get("method").and_then(Value::as_str).unwrap_or("").to_owned();
    let Some(id) = message.get("id").cloned() else {
        // A notification, or an answer to a request the server never sends. `initialized` and
        // `cancelled` go to a running server; a server started later gets its own `initialized`.
        if matches!(method.as_str(), "notifications/initialized" | "notifications/cancelled") {
            let server = chat.server.lock().await.clone();
            if let Some(server) = server.filter(|s| s.live()) {
                let _ = server.write(&message).await;
            }
        }
        let _ = respond(stream, "202 Accepted", "text/plain", b"").await;
        return;
    };
    if method == "initialize" {
        let mut kept = chat.kept.lock().unwrap_or_else(PoisonError::into_inner);
        kept.initialize = message.get("params").cloned();
        let bytes = serde_json::to_vec(&*kept).unwrap_or_default();
        drop(kept);
        let _ = crate::agent_tools::write_private(&chat.file, &bytes);
    }
    chat.inflight.fetch_add(1, Ordering::SeqCst);
    let streams = request.header("accept").is_some_and(|a| a.contains("text/event-stream"))
        && message.pointer("/params/_meta/progressToken").is_some();
    let answer = relay(chat, &message, &method, streams, stream).await;
    chat.inflight.fetch_sub(1, Ordering::SeqCst);
    chat.touch();
    let answer = answer.unwrap_or_else(|e| {
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": format!("cmux MCP server: {e:#}")}})
    });
    if streams {
        let _ = stream.write_all(&sse_event(&answer)).await;
        let _ = stream.shutdown().await;
    } else {
        let _ = respond(stream, "200 OK", "application/json", answer.to_string().as_bytes()).await;
    }
}

/// Sends the request to the chat's server (started if need be, once more if the running one
/// died before it took the request) and waits for its answer. With `streams`, the SSE head goes
/// out first and each progress notification is written as it comes.
async fn relay(
    chat: &Arc<Chat>,
    message: &Value,
    method: &str,
    streams: bool,
    stream: &mut TcpStream,
) -> Result<Value> {
    let (progress_tx, mut progress_rx) = mpsc::unbounded_channel();
    let progress = streams.then_some(progress_tx);
    let mut tries = 0;
    let reply = loop {
        tries += 1;
        let server = chat.server(method == "initialize").await?;
        match server.send(message, progress.clone()).await {
            Ok((reply, ())) => break reply,
            Err(_) if tries < 2 => continue,
            Err(e) => return Err(e),
        }
    };
    drop(progress);
    if !streams {
        return reply.await.map_err(|_| anyhow!("the server ended before it answered"));
    }
    let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store\r\nconnection: close\r\n\r\n";
    stream.write_all(head.as_bytes()).await?;
    tokio::pin!(reply);
    loop {
        // Progress first: the reader queues a call's progress before its answer, and an
        // unbiased pick could take the answer while a note still waits.
        tokio::select! {
            biased;
            Some(note) = progress_rx.recv() => {
                stream.write_all(&sse_event(&note)).await?;
            }
            answer = &mut reply => {
                while let Ok(note) = progress_rx.try_recv() {
                    stream.write_all(&sse_event(&note)).await?;
                }
                return answer.map_err(|_| anyhow!("the server ended before it answered"));
            }
        }
    }
}

fn sse_event(message: &Value) -> Vec<u8> {
    format!("event: message\ndata: {message}\n\n").into_bytes()
}

async fn read_request(stream: &mut TcpStream) -> Result<Request> {
    let mut buf = Vec::with_capacity(4096);
    let head_end = loop {
        if let Some(at) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break at;
        }
        if buf.len() > MAX_HEAD {
            return Err(anyhow!("head too long"));
        }
        let mut chunk = [0u8; 4096];
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Err(anyhow!("closed before the head ended"));
        }
        buf.extend_from_slice(chunk.get(..n).unwrap_or_default());
    };
    let head = std::str::from_utf8(buf.get(..head_end).unwrap_or_default())
        .map_err(|_| anyhow!("head is not UTF-8"))?;
    let mut lines = head.split("\r\n");
    let first = lines.next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("").to_ascii_uppercase();
    let path = parts.next().unwrap_or("/").to_owned();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_owned()))
        .collect();
    let length = headers
        .iter()
        .find(|(k, _)| k == "content-length")
        .map(|(_, v)| v.parse::<usize>())
        .transpose()
        .map_err(|_| anyhow!("bad content-length"))?
        .unwrap_or(0);
    if headers.iter().any(|(k, v)| k == "transfer-encoding" && !v.eq_ignore_ascii_case("identity"))
    {
        return Err(anyhow!("chunked bodies are not taken; send content-length"));
    }
    if length > MAX_BODY {
        return Err(anyhow!("body too long"));
    }
    let mut body = buf.get(head_end + 4..).unwrap_or_default().to_vec();
    while body.len() < length {
        let mut chunk = vec![0u8; (length - body.len()).min(64 * 1024)];
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Err(anyhow!("closed before the body ended"));
        }
        body.extend_from_slice(chunk.get(..n).unwrap_or_default());
    }
    body.truncate(length);
    Ok(Request { method, path, headers, body })
}

async fn respond(
    stream: &mut TcpStream,
    status: &str,
    ctype: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.shutdown().await
}

fn valid_session(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn encode_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn decode_hex(text: &str) -> Option<Vec<u8>> {
    text.len()
        .is_multiple_of(2)
        .then(|| {
            (0..text.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
                .collect()
        })
        .flatten()
}

#[cfg(test)]
#[path = "mcp_gateway_tests.rs"]
mod tests;
