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
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::ChildStdin;
use tokio::sync::{oneshot, watch};

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
/// A chat keeps dialing the port it was configured at for as long as it lives, and a busy home
/// holds chats from many daemon runs: on 2026-11-22 one home's live configs named 20 ports, so a
/// bound of 8 left the oldest of them refused.
const PORTS_REMEMBERED: usize = 24;
/// Where a port with no kept one is derived: the IANA dynamic range, so a derived port cannot be
/// a registered service's.
const DERIVED_PORT_BASE: u16 = 49_152;
#[cfg(test)]
const DERIVED_PORT_SPAN: u16 = 8_192;
/// `DERIVED_PORT_SPAN - 1`. The span is a power of two, so a port is derived with a mask instead
/// of a division or a remainder: no arithmetic that can panic in a debug build, and none that can
/// divide by zero. `the_derived_port_mask_is_the_span` keeps the two in step.
const DERIVED_PORT_MASK: u64 = 8_191;
/// How many ports upward from the derived one are tried before any free port will do.
const DERIVED_PORT_TRIES: u16 = 16;
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
    /// The server's own answers to the harness's start, kept for this launch ([`Answers`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    answers: Option<Answers>,
}

/// The chat's server's answers to `initialize` and `tools/list`, from its last start for this
/// launch and binary. Every harness start (a new chat, each wake from hibernation) asks both
/// before anything else, so each started the chat's `cmux mcp serve` and kept it for
/// [`IDLE_STOP`], although most wakes never call a cmux tool: a live chat held one more
/// process than it used. The gateway answers them from here when the same request was answered
/// for the same launch and binary ([`stamp`]) before; a call starts the server as before, with
/// the harness's kept `initialize` replayed. The list the harness gets on a wake is then the one
/// it had, so its prompt prefix (and the prompt cache) stays the same.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
struct Answers {
    /// The server binary's [`stamp`] when they were given: an update answers afresh.
    stamp: String,
    /// `initialize`'s params and the server's result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    initialize: Option<(Value, Value)>,
    /// `tools/list`'s params and the server's result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    list: Option<(Value, Value)>,
}

/// The binary `launch` runs, as its size and modification time: another build (an app update at
/// the same path) has another stamp. A command found on `PATH` stamps as its name.
fn stamp(launch: &Launch) -> String {
    let at = std::fs::metadata(&launch.command).ok();
    let modified = at
        .as_ref()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_nanos());
    format!("{}:{}:{modified}", launch.command.display(), at.map_or(0, |m| m.len()))
}

/// The methods a kept answer may stand in for.
fn answered_from_kept(method: &str) -> bool {
    matches!(method, "initialize" | "tools/list")
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
        let started_ms = started_ms(pid)?;
        Some(Self { pid, started_ms, home: home.to_owned() })
    }
}

/// When `pid` started, where the platform can say (`process_identity` is Unix only). Without it
/// no holder is recorded, so a successor waits for the kept port as before the holder existed.
#[cfg(unix)]
fn started_ms(pid: u32) -> Option<u64> {
    cmux_tui_platform::process_identity::started_ms(pid)
}

#[cfg(not(unix))]
fn started_ms(_pid: u32) -> Option<u64> {
    None
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
    same_home && started_ms(holder.pid) == Some(holder.started_ms)
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
    /// Looks for idle servers made ([`reap`]); tests read it.
    reap_passes: AtomicUsize,
    /// A chat had a request: [`reap`] looks again while it may hold a server.
    used: Arc<tokio::sync::Notify>,
    /// Every chat's start answers by launch shape ([`Shared`]).
    shared: Arc<Shared>,
}

/// The start answers ([`Answers`]) of every chat, by launch shape: the launch with the chat's own
/// session id taken out ([`Chat::shape`]). Each new chat's harness asks `initialize` and
/// `tools/list` first, which started that chat's `cmux mcp serve` although most chats never call
/// a cmux tool in their first minutes, and many never do. Another chat of the same shape that was
/// answered within [`SHARED_FOR`] answers it instead, with no process; a call starts the
/// server as before. Kept in memory only: a new daemon's first chat of a shape asks its server.
#[derive(Default)]
struct Shared {
    by_shape: Mutex<HashMap<String, (Instant, Answers)>>,
}

/// How long another chat's answers stand for a new chat's ([`Shared`]): a list can change
/// without a new launch or binary (a connection the person added that the server reads at its
/// start), and the next server start after this long reads it afresh. The idle window, so a
/// burst of new chats shares one start.
const SHARED_FOR: Duration = IDLE_STOP;

/// The stand-in for a chat's own session id in a launch shape and a shared answer.
const SESSION_MARK: &str = "\u{1}session\u{1}";

/// The stand-in for a chat's own session token in a launch shape (never in an answer).
const TOKEN_MARK: &str = "\u{1}token\u{1}";

/// `value` with every `from` in its strings replaced by `to`.
fn swap_strings(value: &Value, from: &str, to: &str) -> Value {
    match value {
        Value::String(s) if s.contains(from) => Value::String(s.replace(from, to)),
        Value::Array(items) => {
            Value::Array(items.iter().map(|v| swap_strings(v, from, to)).collect())
        }
        Value::Object(fields) => Value::Object(
            fields.iter().map(|(k, v)| (k.clone(), swap_strings(v, from, to))).collect(),
        ),
        other => other.clone(),
    }
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
    /// The [`Chat::last`] request whose server and tool servers [`reap`] let go: equal to `last`,
    /// the chat holds nothing and [`reap`] need not look at it.
    reaped: Mutex<Instant>,
    /// The gateway's [`Gateway::used`].
    used: Arc<tokio::sync::Notify>,
    inflight: AtomicUsize,
    /// The gateway's start answers by launch shape.
    shared: Arc<Shared>,
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
    progress: Option<ProgressTx>,
}

/// A request's progress: a coalescing slot holding the newest `notifications/progress` and how
/// many came (RFD 0124 R4). A progress note says where the call is, so the newest says all the
/// older ones did; a harness that reads its SSE stream slowly gets the newest when it reads,
/// where an unbounded channel kept every note the server wrote meanwhile.
type ProgressTx = watch::Sender<(u64, Option<Value>)>;

/// Progress notes replaced by a newer one before their reader took them, since the daemon started.
static PROGRESS_COALESCED: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
fn progress_coalesced() -> u64 {
    PROGRESS_COALESCED.load(Ordering::Relaxed)
}

/// The newest note in `rx` past the `seen`th, counting the ones it replaced.
fn newest_progress(
    rx: &mut watch::Receiver<(u64, Option<Value>)>,
    seen: &mut u64,
) -> Option<Value> {
    let newest = rx.borrow_and_update();
    let (count, note) = &*newest;
    if *count <= *seen {
        return None;
    }
    PROGRESS_COALESCED.fetch_add(*count - *seen - 1, Ordering::Relaxed);
    *seen = *count;
    note.clone()
}

/// Puts `note` in the slot, over any note not yet read.
fn post_progress(progress: &ProgressTx, note: Value) {
    progress.send_modify(|(count, slot)| {
        *count += 1;
        *slot = Some(note);
    });
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

/// The chat's harness hibernated (`hub/idle.rs`): nothing will ask its server anything until
/// the harness starts again, so the server stops now instead of after [`IDLE_STOP`]. Its launch
/// and kept answers stay, so the wake answers its start from them ([`Answers`]).
pub fn hibernated(session: &str) {
    if let Some(gateway) = current() {
        gateway.stop_chat(session);
    }
}

/// The chat ended: its server stops and its launch file goes.
pub fn forget(home: &Path, session: &str) {
    forget_on(current().as_deref(), home, session);
}

/// [`forget`] on `gateway`.
fn forget_on(gateway: Option<&Gateway>, home: &Path, session: &str) {
    let _ = crate::home_fs::remove_file(launch_path(home, session));
    // Its Computer Use session ends on the worker, as the stdio bridge's ended with its pipe.
    crate::computer_use::served::end(session);
    if let Some(gateway) = gateway {
        gateway.forget_chat(session);
    }
}

/// A pooled session ended (`hub/pool`: discarded, expired, or the daemon stopping). Its
/// harness registered the chat's `cmux` server here at its start like any chat's, and its first
/// `initialize` may have started that server; but a pooled session never reaches the chat close
/// that [`forget`]s a chat, so the server ran on, the daemon's child, until the idle window
/// ([`IDLE_STOP`]) let it go. A spare pool that started and ended hundreds of spares in a few
/// minutes left the daemon parent of hundreds of `cmux mcp serve`, gigabytes of them.
///
/// One no chat claimed goes whole: server, launch file and MCP config. One a chat claimed is
/// that chat's id from then on (the chat starts cold under it, `hub/pool`'s `take`), so only its
/// server stops, as at a hibernation ([`hibernated`]); the chat's next request starts it again.
pub fn pooled_ended(home: &Path, session: &str, claimed: bool) {
    pooled_ended_on(current().as_deref(), home, session, claimed);
}

/// [`pooled_ended`] on `gateway`.
fn pooled_ended_on(gateway: Option<&Gateway>, home: &Path, session: &str, claimed: bool) {
    if claimed {
        if let Some(gateway) = gateway {
            gateway.stop_chat(session);
        }
        return;
    }
    let config = crate::agent_tools::mcp_config_path(home, session);
    let _ = crate::home_fs::remove_file(crate::bg_hook::denied_path(&config));
    let _ = crate::home_fs::remove_file(config);
    forget_on(gateway, home, session);
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
                bind_derived(home).await?
            }
        },
        None => bind_derived(home).await?,
    };
    let port = listener.local_addr()?.port();
    // The record is one daemon's memory and can be short, stale or lost; the configs the daemon
    // wrote are what the live harnesses dial. Both, so a chat whose port fell off the record is
    // served again.
    earlier.extend(ports_chats_are_configured_at(home));
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
        reap_passes: AtomicUsize::new(0),
        used: Arc::new(tokio::sync::Notify::new()),
        shared: Arc::default(),
    });
    for listener in listeners {
        gateway.scope.spawn_named("mcp gateway listener", serve(gateway.clone(), listener));
    }
    gateway.scope.spawn_named("mcp gateway idle stop", reap(gateway.clone(), reap_every));
    Ok(gateway)
}

/// The ports this home's chats are configured at: every `http://127.0.0.1:PORT/mcp/` in the
/// `--mcp-config` files the daemon wrote (`run/mcp/<session>.json`), newest file first. A harness
/// only ever dials the url its config named at launch, so these are the ports where a chat gets
/// `ECONNREFUSED` once the gateway moves — ground truth, where `run/mcp-gateway.json` is one
/// daemon's memory of its own runs and may have been truncated, replaced or lost.
fn ports_chats_are_configured_at(home: &Path) -> Vec<u16> {
    let Ok(entries) = std::fs::read_dir(home.join("run").join("mcp")) else {
        return Vec::new();
    };
    let mut found: Vec<(std::time::SystemTime, u16)> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        // `<session>.gateway.json` is the kept launch, which names no url.
        if !name.ends_with(".json") || name.ends_with(".gateway.json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        let when = entry
            .metadata()
            .and_then(|m| m.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        for port in configured_ports(&text) {
            found.push((when, port));
        }
    }
    // Newest config first: the ports most likely to belong to a chat that is still running.
    found.sort_by_key(|a| std::cmp::Reverse(a.0));
    let mut seen = std::collections::HashSet::new();
    found.into_iter().map(|(_, port)| port).filter(|p| seen.insert(*p)).collect()
}

/// Every loopback gateway port named in one config's text.
fn configured_ports(text: &str) -> Vec<u16> {
    const MARK: &str = "http://127.0.0.1:";
    text.split(MARK)
        .skip(1)
        .filter_map(|rest| {
            let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
            // Only this gateway's routes: another loopback server's url is not ours. `strip_prefix`
            // rather than a slice at `digits.len()`, which is an index into `rest` this code would
            // have to prove is a char boundary.
            if !rest.strip_prefix(digits.as_str())?.starts_with("/mcp/") {
                return None;
            }
            digits.parse().ok()
        })
        .collect()
}

/// A port derived from the home path, probing upward, instead of a fresh ephemeral one: with no
/// kept port (a lost or unreadable record, a first run after a reinstall) the gateway lands on the
/// port its predecessor landed on, which is the port the live chats are configured at.
async fn bind_derived(home: &Path) -> std::io::Result<TcpListener> {
    let first = derived_port(home);
    for step in 0..DERIVED_PORT_TRIES {
        let within_span = (u64::from(first.saturating_sub(DERIVED_PORT_BASE))
            .saturating_add(u64::from(step)))
            & DERIVED_PORT_MASK;
        let port = DERIVED_PORT_BASE.saturating_add(u16::try_from(within_span).unwrap_or(0));
        match TcpListener::bind(("127.0.0.1", port)).await {
            Ok(listener) => return Ok(listener),
            Err(e) => tracing::debug!("mcp gateway: derived port {port} is taken ({e})"),
        }
    }
    TcpListener::bind(("127.0.0.1", 0)).await
}

/// `DERIVED_PORT_BASE + FNV-1a(home) & DERIVED_PORT_MASK`. The hash is written out here rather
/// than taken from `DefaultHasher`, which the standard library may change between releases: this
/// port has to be the same after an app update, not only after a restart.
pub(crate) fn derived_port(home: &Path) -> u16 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in home.as_os_str().as_encoded_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    // The mask holds the result inside the span, so neither the conversion nor the add can lose a
    // bit: `DERIVED_PORT_BASE + DERIVED_PORT_MASK` is 57343, well inside a `u16`.
    DERIVED_PORT_BASE.saturating_add(u16::try_from(hash & DERIVED_PORT_MASK).unwrap_or(0))
}

/// Binds the kept port, trying again until `wait` runs out. A daemon hands over to its successor:
/// the successor starts while the daemon it replaces still holds the port and only exits a second
/// or so later (`daemon.stops.json`, `handover: another daemon of this home starts`). Taking a
/// free port on the first `Address in use` made every restart move the gateway, and each move
/// stranded every live harness, whose config names the port it was started with (a Linux workstation,
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
            crate::computer_use::mcp::SESSION_ENV,
            crate::cloud_repo_mcp::SESSION_ENV,
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

    /// Drops the chat and stops its server (closed stdin, then SIGTERM and SIGKILL past
    /// [`STOP_GRACE`]), a request in flight or not: nothing will ask it anything again.
    fn forget_chat(&self, session: &str) {
        let chat = self.chats.lock().unwrap_or_else(PoisonError::into_inner).remove(session);
        if let (Some(chat), Ok(_)) = (chat, tokio::runtime::Handle::try_current()) {
            chat.release_tools();
            let scope = chat.scope.clone();
            scope.spawn_named("mcp gateway stop", async move { chat.stop().await });
        }
    }

    /// Stops the chat's server and drops its tool servers, unless a request is in flight.
    pub fn stop_chat(&self, session: &str) {
        let chat = self.chats.lock().unwrap_or_else(PoisonError::into_inner).get(session).cloned();
        let Some(chat) = chat.filter(|c| c.inflight.load(Ordering::SeqCst) == 0) else { return };
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        chat.release_tools();
        let scope = chat.scope.clone();
        scope.spawn_named("mcp gateway stop", async move { chat.stop().await });
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
        let same = before.as_ref().filter(|k| k.launch == launch);
        let initialize = same.and_then(|k| k.initialize.clone());
        let answers = same.and_then(|k| k.answers.clone());
        let kept = Kept { launch, initialize, answers };
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
        let now = Instant::now();
        Chat {
            id: id.to_owned(),
            file,
            scope: gateway.scope.clone(),
            kept: Mutex::new(kept),
            server: tokio::sync::Mutex::new(None),
            tools_daemon: Arc::new(crate::tools_mcp::Daemon::at(gateway.socket.clone())),
            tools: Mutex::new(None),
            // Made holding nothing: nothing to let go until its first request.
            last: Mutex::new(now),
            reaped: Mutex::new(now),
            used: gateway.used.clone(),
            inflight: AtomicUsize::new(0),
            shared: gateway.shared.clone(),
        }
    }

    /// Its launch with its session id taken out, and the binary's [`stamp`]: chats of one shape
    /// start the same server but for the session ([`Shared`]).
    fn shape(&self, launch: &Launch) -> String {
        let mut text = serde_json::to_string(launch).unwrap_or_default();
        // Each chat's own secret: equal launches differ only by it and by the session id.
        let token = launch.env.iter().find(|(k, _)| k == "ACPMUX_SESSION_TOKEN").map(|(_, v)| v);
        if let Some(token) = token.filter(|t| !t.is_empty()) {
            text = text.replace(token.as_str(), TOKEN_MARK);
        }
        let shape = if self.id.is_empty() { text } else { text.replace(&self.id, SESSION_MARK) };
        format!("{}\n{shape}", stamp(launch))
    }

    /// Another chat's answer for `method` asked with `params` ([`Shared`]), for this chat.
    fn shared_answer(&self, launch: &Launch, method: &str, params: &Value) -> Option<Value> {
        let shape = self.shape(launch);
        let asked = swap_strings(params, &self.id, SESSION_MARK);
        let by_shape = self.shared.by_shape.lock().unwrap_or_else(PoisonError::into_inner);
        let (_, answers) = by_shape.get(&shape).filter(|(at, _)| at.elapsed() < SHARED_FOR)?;
        let slot = if method == "initialize" { &answers.initialize } else { &answers.list };
        let (_, result) = slot.as_ref().filter(|(p, _)| *p == asked)?;
        Some(swap_strings(result, SESSION_MARK, &self.id))
    }

    /// Keeps this chat's server's `result` for every new chat of its shape ([`Shared`]).
    fn share_answer(&self, launch: &Launch, method: &str, params: &Value, result: &Value) {
        let shape = self.shape(launch);
        let asked = swap_strings(params, &self.id, SESSION_MARK);
        let result = swap_strings(result, &self.id, SESSION_MARK);
        let mut by_shape = self.shared.by_shape.lock().unwrap_or_else(PoisonError::into_inner);
        by_shape.retain(|_, (at, _)| at.elapsed() < SHARED_FOR);
        let (at, answers) = by_shape.entry(shape).or_insert_with(|| {
            (Instant::now(), Answers { stamp: stamp(launch), ..Answers::default() })
        });
        *at = Instant::now();
        let slot = if method == "initialize" { &mut answers.initialize } else { &mut answers.list };
        *slot = Some((asked, result));
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
    /// The kept result for `method` asked with `params` ([`Answers`]), if the same was answered
    /// for this launch and binary.
    fn kept_answer(&self, method: &str, params: &Value) -> Option<Value> {
        let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        let answers = kept.answers.as_ref().filter(|a| a.stamp == stamp(&kept.launch))?;
        let slot = if method == "initialize" { &answers.initialize } else { &answers.list };
        slot.as_ref().filter(|(asked, _)| asked == params).map(|(_, result)| result.clone())
    }

    /// [`Chat::kept_answer`], else another chat's of the same shape ([`Shared`]), which is then
    /// this chat's own kept answer too (its wakes get the same list).
    fn start_answer(&self, method: &str, params: &Value) -> Option<Value> {
        if let Some(own) = self.kept_answer(method, params) {
            return Some(own);
        }
        let launch = self.kept.lock().unwrap_or_else(PoisonError::into_inner).launch.clone();
        let result = self.shared_answer(&launch, method, params)?;
        self.keep_answer(method, params.clone(), result.clone());
        Some(result)
    }

    /// Keeps the server's `result` for `method` asked with `params`, in memory and in the chat's
    /// launch file (so the next daemon has it too).
    fn keep_answer(&self, method: &str, params: Value, result: Value) {
        let mut kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        let stamp = stamp(&kept.launch);
        let answers = kept.answers.get_or_insert_with(Answers::default);
        if answers.stamp != stamp {
            *answers = Answers { stamp, ..Answers::default() };
        }
        let slot = if method == "initialize" { &mut answers.initialize } else { &mut answers.list };
        if slot.as_ref().is_some_and(|(p, r)| *p == params && *r == result) {
            return;
        }
        *slot = Some((params, result));
        let bytes = serde_json::to_vec(&*kept).unwrap_or_default();
        drop(kept);
        let _ = crate::agent_tools::write_private(&self.file, &bytes);
    }

    fn release_tools(&self) {
        self.tools.lock().unwrap_or_else(PoisonError::into_inner).take();
        self.tools_daemon.release();
    }

    fn touch(&self) {
        *self.last.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
        // A permit when the look is not waiting: it looks once more, then sleeps again.
        self.used.notify_one();
    }

    fn last(&self) -> Instant {
        *self.last.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Whether a request came since [`reap`] last let this chat's servers go.
    fn may_hold(&self) -> bool {
        self.last() != *self.reaped.lock().unwrap_or_else(PoisonError::into_inner)
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
        progress: Option<ProgressTx>,
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
                post_progress(progress, message);
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

/// Stops each chat's server that had no request in flight for the gateway's idle window, looking
/// every `every` while a chat used since its last stop may hold a server or tool servers. With
/// none it sleeps until a request ([`Chat::touch`]): an idle daemon with chats that all stopped
/// wakes for nothing (it looked every 30 s, the last periodic wake of an idle daemon but the lag
/// canary's).
async fn reap(gateway: Arc<Gateway>, every: Duration) {
    loop {
        let chats: Vec<_> = gateway
            .chats
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        if !chats.iter().any(|chat| chat.may_hold()) {
            // A request after the list was read left a permit: no request is missed.
            gateway.used.notified().await;
            continue;
        }
        tokio::time::sleep(every).await;
        gateway.reap_passes.fetch_add(1, Ordering::Relaxed);
        for chat in chats {
            let last = chat.last();
            if chat.inflight.load(Ordering::SeqCst) == 0 && last.elapsed() >= gateway.idle {
                chat.release_tools();
                let server = match chat.server.try_lock() {
                    Ok(mut slot) => slot.take(),
                    // A request holds the slot: looked at again next time.
                    Err(_) => continue,
                };
                if let Some(server) = server {
                    tracing::debug!(session = %chat.id, "mcp gateway: idle server stops");
                    server.stop().await;
                }
                // A request since `last` keeps the chat looked at.
                *chat.reaped.lock().unwrap_or_else(PoisonError::into_inner) = last;
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

/// A request's body: one JSON-RPC message, or a batch of them (a JSON array, MCP 2025-03-26).
enum Body {
    One(Value),
    Batch(Vec<Value>),
}

/// The request's message or batch, or None once it answered that there is neither.
async fn body_of(request: &Request, stream: &mut TcpStream) -> Option<Body> {
    let (code, text) = match serde_json::from_slice(&request.body) {
        Ok(v @ Value::Object(_)) => return Some(Body::One(v)),
        Ok(Value::Array(batch)) if !batch.is_empty() && batch.iter().all(Value::is_object) => {
            return Some(Body::Batch(batch));
        }
        Ok(Value::Array(_)) => (-32600, "a batch is a non-empty array of JSON-RPC messages"),
        _ => (-32700, "one JSON-RPC message, or a batch of them, per request"),
    };
    let error = json!({"jsonrpc": "2.0", "id": null, "error": {"code": code, "message": text}});
    let _ =
        respond(stream, "400 Bad Request", "application/json", error.to_string().as_bytes()).await;
    None
}

/// One message's answer: a JSON body, or 202 for a notification.
async fn respond_one(stream: &mut TcpStream, answer: Option<Value>) {
    let _ = match answer {
        Some(answer) => {
            respond(stream, "200 OK", "application/json", answer.to_string().as_bytes()).await
        }
        None => respond(stream, "202 Accepted", "text/plain", b"").await,
    };
}

/// A batch's answers as one array, in the batch's order, none for its notifications; 202 when
/// it held only notifications.
async fn respond_batch(stream: &mut TcpStream, answers: Vec<Option<Value>>) {
    let answers: Vec<Value> = answers.into_iter().flatten().collect();
    respond_one(stream, (!answers.is_empty()).then_some(Value::Array(answers))).await;
}

/// A request to acpmux's own tool servers of the chat, answered here (`tools_mcp::answer`) in
/// the chat's tool env. A call runs in this request's own task, so a card that waits on the
/// person for up to an hour holds no other request; a batch's calls run at once.
async fn post_tools(
    gateway: &Gateway,
    chat: &Arc<Chat>,
    request: &Request,
    server: Option<&'static str>,
    stream: &mut TcpStream,
) {
    match body_of(request, stream).await {
        None => {}
        Some(Body::One(message)) => {
            respond_one(stream, tool_answer(gateway, chat, message, server).await).await;
        }
        Some(Body::Batch(batch)) => {
            let answers = futures::future::join_all(
                batch.into_iter().map(|message| tool_answer(gateway, chat, message, server)),
            )
            .await;
            respond_batch(stream, answers).await;
        }
    }
}

/// `message`'s answer from the chat's own tool servers; none for a notification.
async fn tool_answer(
    gateway: &Gateway,
    chat: &Arc<Chat>,
    mut message: Value,
    server: Option<&'static str>,
) -> Option<Value> {
    if let Some(name) = server {
        for_server(&mut message, name);
    }
    chat.touch();
    // `initialized` and the like carry no id: the servers here keep no state for them.
    message.get("id")?;
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
    answer
}

/// `message` for server `name` of a chat's tool servers: its params' `_meta` names it
/// ([`crate::tools_mcp::SERVER_META`]) as the `cmux` server's request would, whatever the
/// harness put there.
pub(crate) fn for_server(message: &mut Value, name: &str) {
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

/// What one relayed message gets back.
enum Reply {
    /// Nothing: a notification.
    None,
    /// This answer, as the response's body.
    Json(Value),
    /// This answer, as the last event of the SSE stream already under way.
    Event(Value),
}

/// A request to the chat's own MCP server. A batch's messages are relayed at once: the server's
/// answers come back by id ([`read_answers`]), so none waits on another.
async fn post(chat: &Arc<Chat>, request: &Request, stream: &mut TcpStream) {
    match body_of(request, stream).await {
        None => {}
        Some(Body::One(message)) => {
            let sse = request.header("accept").is_some_and(|a| a.contains("text/event-stream"));
            match relay_answer(chat, message, sse.then_some(&mut *stream)).await {
                Reply::Event(answer) => {
                    let _ = stream.write_all(&sse_event(&answer)).await;
                    let _ = stream.shutdown().await;
                }
                Reply::Json(answer) => respond_one(stream, Some(answer)).await,
                Reply::None => respond_one(stream, None).await,
            }
        }
        Some(Body::Batch(batch)) => {
            // No progress stream for a batch: its answers go back as one array.
            let answers = futures::future::join_all(batch.into_iter().map(|message| async move {
                match relay_answer(chat, message, None).await {
                    Reply::Json(answer) | Reply::Event(answer) => Some(answer),
                    Reply::None => None,
                }
            }))
            .await;
            respond_batch(stream, answers).await;
        }
    }
}

/// `message` relayed to the chat's server, or answered from what the chat kept. With `sse`, a
/// call that carries a progress token streams its progress there as it comes.
async fn relay_answer(chat: &Arc<Chat>, message: Value, sse: Option<&mut TcpStream>) -> Reply {
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
        return Reply::None;
    };
    if method == "initialize" {
        let mut kept = chat.kept.lock().unwrap_or_else(PoisonError::into_inner);
        kept.initialize = message.get("params").cloned();
        let bytes = serde_json::to_vec(&*kept).unwrap_or_default();
        drop(kept);
        let _ = crate::agent_tools::write_private(&chat.file, &bytes);
    }
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    if method == "ping" || answered_from_kept(&method) {
        let kept =
            if method == "ping" { Some(json!({})) } else { chat.start_answer(&method, &params) };
        if let Some(result) = kept {
            return Reply::Json(json!({"jsonrpc": "2.0", "id": id, "result": result}));
        }
    }
    chat.inflight.fetch_add(1, Ordering::SeqCst);
    let sse = sse.filter(|_| message.pointer("/params/_meta/progressToken").is_some());
    let mut streamed = false;
    let answer = relay(chat, &message, &method, sse, &mut streamed).await;
    chat.inflight.fetch_sub(1, Ordering::SeqCst);
    chat.touch();
    if let (true, Ok(result)) =
        (answered_from_kept(&method), answer.as_ref().map(|a| a.get("result")))
        && let Some(result) = result
    {
        // Only a server's own answer is shared, so the window counts from a real start.
        let launch = chat.kept.lock().unwrap_or_else(PoisonError::into_inner).launch.clone();
        chat.share_answer(&launch, &method, &params, result);
        chat.keep_answer(&method, params, result.clone());
    }
    let answer = answer.unwrap_or_else(|e| {
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": format!("cmux MCP server: {e:#}")}})
    });
    // A server that failed to start before the stream's head went out answers as plain JSON.
    if streamed { Reply::Event(answer) } else { Reply::Json(answer) }
}

/// Sends the request to the chat's server (started if need be, once more if the running one
/// died before it took the request) and waits for its answer. With `stream`, the SSE head goes
/// out first (`streamed` is set then) and each progress notification is written as it comes.
async fn relay(
    chat: &Arc<Chat>,
    message: &Value,
    method: &str,
    stream: Option<&mut TcpStream>,
    streamed: &mut bool,
) -> Result<Value> {
    let streams = stream.is_some();
    let (progress_tx, mut progress_rx) = watch::channel((0, None));
    let mut seen = 0;
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
    let Some(stream) = stream else {
        return reply.await.map_err(|_| anyhow!("the server ended before it answered"));
    };
    let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store\r\nconnection: close\r\n\r\n";
    *streamed = true;
    stream.write_all(head.as_bytes()).await?;
    tokio::pin!(reply);
    loop {
        // Progress first: the reader queues a call's progress before its answer, and an
        // unbiased pick could take the answer while a note still waits.
        tokio::select! {
            biased;
            Ok(()) = progress_rx.changed() => {
                if let Some(note) = newest_progress(&mut progress_rx, &mut seen) {
                    stream.write_all(&sse_event(&note)).await?;
                }
            }
            answer = &mut reply => {
                if let Some(note) = newest_progress(&mut progress_rx, &mut seen) {
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
