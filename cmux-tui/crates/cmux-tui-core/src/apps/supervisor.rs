//! The app supervisor: owner of the install mirror, grants, storage, egress
//! and the app host processes on this machine (plan section 13.1).
//!
//! Locking: one mutex guards [`Inner`]. Work that talks to the outside
//! (client sinks, host sockets, the op router, the network) never runs under
//! it: locked sections return [`Out`] lists that [`Supervisor::emit`] runs
//! after the lock is released, in order.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::catalog::{self, Catalog, Package, Sources};
use super::egress::Fetcher;
use super::grants::{Gestures, Grant};
use super::host::HostProcess;
use super::mirror::{self, Effect, Mirror, Op, Origin, Record, SetOp};
use super::storage::Storage;
use super::timer::{TimerId, Timers};
use crate::backoff::Backoff;

/// Writes one event or response to a control client; false when it is gone.
pub type Sink = Arc<dyn Fn(&Value) -> bool + Send + Sync>;
/// Answers one asynchronous request (`apps-run`).
pub type Responder = Box<dyn FnOnce(Result<Value, ApiError>) + Send>;

const LOG_LINES: usize = 500;
pub(super) const MAX_CRASHES: u32 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    pub code: String,
    pub message: String,
    /// The owner's error details, passed through unchanged (for example a
    /// server's `details.status` and `details.upstream_code`).
    pub details: Option<Value>,
    pub retryable: bool,
}

impl ApiError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_string(), message: message.into(), details: None, retryable: false }
    }

    /// An error body in the ABI shape `{code, message, details?, retryable}`,
    /// with `fallback` as the code when the body has none.
    pub fn from_body(body: &Value, fallback: &str) -> Self {
        Self {
            code: body["code"].as_str().unwrap_or(fallback).to_string(),
            message: body["message"].as_str().unwrap_or(fallback).to_string(),
            details: body.get("details").filter(|d| !d.is_null()).cloned(),
            retryable: body["retryable"] == true,
        }
    }
}

/// Routes an app's catalog op to the daemon's own dispatcher.
pub trait OpRouter: Send + Sync {
    /// Runs `op` for `app`. Ok is the ABI ok body (`{value, ...}`), Err the
    /// ABI error body (`{code, message, details?, retryable}`).
    fn route(
        &self,
        app: &str,
        op: &str,
        params: Value,
        idempotency_key: Option<String>,
        origin: Origin,
    ) -> Result<Value, Value>;
    /// Starts delivering daemon change events as stream names
    /// (`workspace.changed`, `agent.changed`, …). Called once, on the first
    /// app subscription.
    fn start_events(&self, publish: Box<dyn Fn(&str) + Send + Sync>);
    /// True when the daemon's own dispatcher owns `op`; other ops go to a
    /// provider.
    fn owns(&self, op: &str) -> bool;
    /// Creates the zero-view session-host terminal of an app's byte-backend
    /// terminal. Without a session host: an error.
    fn spawn_backend_terminal(
        &self,
        side: crate::terminal_backend::pty::BackendSide,
    ) -> anyhow::Result<crate::mux::app_terminals::BackendTerminal> {
        anyhow::bail!("no session host for {}", side.terminal)
    }
    /// True when the backend terminal ever had a view.
    fn backend_terminal_viewed(&self, surface: crate::SurfaceId) -> bool {
        let _ = surface;
        false
    }
    /// Removes and stops a never-viewed backend terminal.
    fn close_backend_terminal(&self, surface: crate::SurfaceId) {
        let _ = surface;
    }
}

pub struct Config {
    pub state_dir: Option<PathBuf>,
    pub host_binary: Option<PathBuf>,
    /// Arguments for the host binary (empty in production; the tests run a
    /// scripted host from the test executable).
    pub host_args: Vec<String>,
    /// Where first-party app server binaries ship (`servers.rs`).
    pub server_dir: Option<PathBuf>,
    pub sources: Sources,
    /// `apps.idleStopSeconds` (default 60).
    pub idle_stop: Duration,
    /// How long a provider may take to answer (default 30 s), and ops that
    /// wait for the user such as a file panel (default 10 min).
    pub provider_deadline: Duration,
    pub provider_user_deadline: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(super) struct HostKey {
    pub app: String,
    pub preview: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(super) struct MountKey {
    pub client: u64,
    pub mount_id: String,
}

impl MountKey {
    /// The mount id the host sees: unique across clients.
    pub fn wire(&self) -> String {
        format!("{}:{}", self.client, self.mount_id)
    }
}

pub(super) struct Mount {
    pub host: HostKey,
    pub export: String,
    pub context: Value,
    /// The next scene batch starts a fresh tree (after a host restart).
    pub reset: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum HostState {
    Starting,
    Running,
    /// Asked to exit (idle stop, uninstall); the exit is expected.
    Stopping,
    /// Asked to exit so it restarts with a new grant.
    Restarting,
    /// Crashed; a restart is scheduled after the backoff.
    Waiting,
}

pub(super) struct Host {
    pub generation: u64,
    pub process: Option<Arc<HostProcess>>,
    pub state: HostState,
    pub grant: Grant,
    pub subs: HashMap<u64, String>,
    pub runs: HashMap<u64, Responder>,
    /// The gesture token of each run that has one, revoked at its `done`.
    pub run_gestures: HashMap<u64, String>,
    /// `run` messages for a host that has no process yet (restart pending).
    pub queued_runs: Vec<ToHost>,
    pub next_cb: u64,
    pub idle: Option<TimerId>,
    pub backoff: Backoff,
    pub crashes: u32,
    /// When the current process answered `ready`; a crash after a long
    /// healthy run starts the backoff over.
    pub ready_at: Option<Instant>,
    /// App calls being worked on (at most the VM's 64; the supervisor checks
    /// again because the VM is untrusted).
    pub inflight: usize,
}

#[derive(Debug, Clone)]
pub(super) struct LogLine {
    pub level: String,
    pub message: String,
    pub ts_ms: u64,
}

pub(super) struct Inner {
    pub mirror: Mirror,
    pub catalog: Catalog,
    pub hosts: HashMap<HostKey, Host>,
    pub mounts: HashMap<MountKey, Mount>,
    pub sinks: HashMap<u64, Sink>,
    pub followers: HashMap<String, BTreeSet<u64>>,
    pub logs: HashMap<String, VecDeque<LogLine>>,
    pub gestures: Gestures,
    pub next_generation: u64,
    pub events_started: bool,
    /// Provider connection per family, and calls waiting for a provider
    /// (`provider.rs`).
    pub providers: HashMap<String, u64>,
    pub provider_calls: HashMap<u64, super::provider::ProviderCall>,
    pub next_provider_request: u64,
    /// `apps-run` replay by idempotency key (`runs.rs`).
    pub run_keys: HashMap<String, super::runs::RunKey>,
    pub run_key_order: VecDeque<String>,
    /// One server process per app with a manifest `server` (`servers.rs`).
    pub servers: HashMap<String, super::servers::Server>,
    /// Open tokens minted for user runs of server ops (`servers.rs`).
    pub open_tokens: HashMap<String, super::open_tokens::OpenToken>,
    pub server_crashes: HashMap<String, super::servers::Crashes>,
    /// Run callers and the ops they wait for (`cancel.rs`).
    pub calls: super::cancel::Calls,
}

/// Work to do after the lock is released. Messages to hosts are not in this
/// list: `HostProcess::send` only queues, so they are sent under the lock and
/// reach each host in lock order.
pub(super) enum Out {
    Client(u64, Value),
    /// An `apps-provider-request` to its provider; a failed send fails the
    /// call at once (`provider.rs`).
    Provider(u64, u64, Value),
    Broadcast(Value),
    Respond(Responder, Result<Value, ApiError>),
    StartEvents,
}

pub struct Supervisor {
    pub(super) config: Config,
    pub(super) inner: Mutex<Inner>,
    pub(super) router: Box<dyn OpRouter>,
    pub(super) fetcher: Box<dyn Fetcher>,
    pub(super) storage: Mutex<Option<Storage>>,
    pub(super) timers: Timers,
    pub(super) me: Weak<Supervisor>,
    /// Connector links of the terminal interfaces (`terminal_ops.rs`).
    pub(super) terminals: super::terminal_links::Terminals,
    transactions: AtomicU64,
}

pub(super) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or_default()
}

impl Supervisor {
    pub fn new(config: Config, router: Box<dyn OpRouter>, fetcher: Box<dyn Fetcher>) -> Arc<Self> {
        let catalog = catalog::load(&config.sources);
        let mut mirror = load_mirror(config.state_dir.as_deref());
        let mut logs: HashMap<String, VecDeque<LogLine>> = HashMap::new();
        for (dir, issue) in &catalog.rejected {
            logs.entry("cmux/supervisor".into()).or_default().push_back(LogLine {
                level: "warn".into(),
                message: format!("{}: {issue}", dir.display()),
                ts_ms: now_ms(),
            });
        }
        let mut seeded = false;
        for app in &catalog.defaults {
            let Some(package) = catalog.packages.get(app) else { continue };
            if let Ok(outcome) =
                mirror::reduce(&mirror, &Op::Seed { app: app.clone() }, Some(&package.facts()))
                && outcome.changed
            {
                mirror = outcome.mirror;
                seeded = true;
            }
        }
        let supervisor = Arc::new_cyclic(|me| Self {
            inner: Mutex::new(Inner {
                mirror,
                catalog,
                hosts: HashMap::new(),
                mounts: HashMap::new(),
                sinks: HashMap::new(),
                followers: HashMap::new(),
                logs,
                gestures: Gestures::default(),
                next_generation: 1,
                events_started: false,
                providers: HashMap::new(),
                provider_calls: HashMap::new(),
                next_provider_request: 0,
                run_keys: HashMap::new(),
                run_key_order: VecDeque::new(),
                servers: HashMap::new(),
                open_tokens: HashMap::new(),
                server_crashes: HashMap::new(),
                calls: Default::default(),
            }),
            config,
            router,
            fetcher,
            storage: Mutex::new(None),
            timers: Timers::default(),
            me: me.clone(),
            terminals: Default::default(),
            transactions: AtomicU64::new(1),
        });
        if seeded {
            let _ = supervisor.persist(&supervisor.inner.lock().unwrap().mirror);
        }
        supervisor.start_always_servers();
        supervisor
    }

    /// Makes `client` receive `apps-changed` and `apps-host`.
    pub fn register_client(&self, client: u64, sink: Sink) {
        self.inner.lock().unwrap().sinks.entry(client).or_insert(sink);
    }

    /// A control connection closed: its mounts unmount, its follows end, its
    /// runs are cancelled.
    pub fn disconnect(&self, client: u64) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            inner.sinks.remove(&client);
            let mut provider_outs = self.provider_disconnect_locked(&mut inner, client);
            provider_outs.extend(self.cancel_client_locked(&mut inner, client));
            for set in inner.followers.values_mut() {
                set.remove(&client);
            }
            let keys: Vec<MountKey> =
                inner.mounts.keys().filter(|k| k.client == client).cloned().collect();
            let mut outs = provider_outs;
            for key in keys {
                outs.extend(self.unmount_locked(&mut inner, &key));
            }
            outs
        };
        self.emit(outs);
    }

    pub fn list(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        let mut ids: BTreeSet<&String> = inner.catalog.packages.keys().collect();
        ids.extend(inner.mirror.apps.iter().filter(|(_, r)| r.installed).map(|(id, _)| id));
        let apps: Vec<Value> = ids
            .into_iter()
            .map(|id| entry(id, inner.catalog.packages.get(id), inner.mirror.apps.get(id)))
            .collect();
        json!({ "revision": inner.mirror.revision, "apps": apps })
    }

    /// `apps-set`: one validated commit of the install mirror. Every request
    /// ends with `request-settled`, rejects and no-ops included. The mirror
    /// is written to disk before it is applied; a failed write rejects.
    pub fn set(&self, client: u64, op: SetOp) -> Result<Value, ApiError> {
        let app = op.app.clone();
        let transaction = format!("apps-{}", self.transactions.fetch_add(1, Ordering::Relaxed));
        let (outs, result) = {
            let mut inner = self.inner.lock().unwrap();
            let mut outs = Vec::new();
            let result = self.commit_locked(&mut inner, op, &transaction, &mut outs).map(|()| {
                let mut record =
                    entry(&app, inner.catalog.packages.get(&app), inner.mirror.apps.get(&app));
                // Lets a client drop list replies older than this commit.
                record["revision"] = json!(inner.mirror.revision);
                record
            });
            outs.push(Out::Client(client, json!({ "event": "request-settled", "transaction": transaction, "sequence": inner.mirror.revision })));
            (outs, result)
        };
        self.emit(outs);
        result
    }

    fn commit_locked(
        &self,
        inner: &mut Inner,
        op: SetOp,
        transaction: &str,
        outs: &mut Vec<Out>,
    ) -> Result<(), ApiError> {
        let app = op.app.clone();
        let facts = inner.catalog.packages.get(&op.app).map(Package::facts);
        let outcome = mirror::reduce(&inner.mirror, &Op::Set(op), facts.as_ref())
            .map_err(|r| ApiError::new(r.code(), r.message()))?;
        if outcome.replayed {
            return Ok(());
        }
        // A no-op still records its key, so the key cannot be reused later.
        self.persist(&outcome.mirror)
            .map_err(|e| ApiError::new("apps.persist", format!("apps.json: {e}")))?;
        inner.mirror = outcome.mirror;
        for effect in &outcome.effects {
            outs.extend(self.apply_effect(inner, effect));
        }
        if outcome.changed {
            outs.extend(self.sync_server_locked(inner, &app));
        }
        if outcome.changed {
            outs.push(Out::Broadcast(json!({ "event": "apps-changed", "revision": inner.mirror.revision, "transaction": transaction })));
        }
        Ok(())
    }

    fn apply_effect(&self, inner: &mut Inner, effect: &Effect) -> Vec<Out> {
        match effect {
            // Under the lock, so no call that runs after the commit sees the
            // old data (storage calls check the install under the same lock).
            Effect::ClearStorage(app) => {
                if let Some(storage) = self.storage().as_ref() {
                    let _ = storage.clear(app);
                }
                self.remove_server_dirs(app);
                vec![]
            }
            Effect::StopHost(app) => {
                let mut outs = self.terminal_access_changed_locked(inner, app);
                outs.extend(self.stop_app_locked(inner, app, "disabled"));
                outs.extend(self.stop_server_locked(inner, app, "disabled"));
                outs
            }
            Effect::GrantsChanged(app) => {
                let mut outs = self.terminal_access_changed_locked(inner, app);
                outs.extend(self.regrant_locked(inner, app));
                outs
            }
        }
    }

    /// `apps-logs`: the ring for `app`; `follow` streams `apps-log` events.
    pub fn logs(&self, client: u64, app: &str, follow: bool) -> Value {
        let mut inner = self.inner.lock().unwrap();
        if follow {
            inner.followers.entry(app.to_string()).or_default().insert(client);
        }
        let lines: Vec<Value> = inner
            .logs
            .get(app)
            .into_iter()
            .flatten()
            .map(|l| json!({ "level": l.level, "message": l.message, "ts_ms": l.ts_ms }))
            .collect();
        json!({ "lines": lines })
    }

    pub(super) fn log_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        level: &str,
        message: String,
    ) -> Vec<Out> {
        let line = LogLine { level: level.to_string(), message, ts_ms: now_ms() };
        let ring = inner.logs.entry(app.to_string()).or_default();
        ring.push_back(line.clone());
        while ring.len() > LOG_LINES {
            ring.pop_front();
        }
        inner
            .followers
            .get(app)
            .into_iter()
            .flatten()
            .map(|client| Out::Client(*client, json!({ "event": "apps-log", "app": app, "level": line.level, "message": line.message, "ts_ms": line.ts_ms })))
            .collect()
    }

    pub(super) fn emit(&self, outs: Vec<Out>) {
        if outs.is_empty() {
            return;
        }
        let sinks: HashMap<u64, Sink> = self.inner.lock().unwrap().sinks.clone();
        for out in outs {
            match out {
                Out::Client(client, value) => {
                    if let Some(sink) = sinks.get(&client) {
                        sink(&value);
                    }
                }
                Out::Provider(client, request_id, event) => {
                    if !sinks.get(&client).is_some_and(|sink| sink(&event)) {
                        self.provider_send_failed(request_id);
                    }
                }
                Out::Broadcast(value) => {
                    for sink in sinks.values() {
                        sink(&value);
                    }
                }
                Out::Respond(responder, result) => responder(result),
                Out::StartEvents => {
                    let me = self.me.clone();
                    self.router.start_events(Box::new(move |stream| {
                        if let Some(me) = me.upgrade() {
                            me.publish(stream, json!({}));
                        }
                    }));
                }
            }
        }
    }

    /// The storage database, opened on first use. Lock order: `inner`, then
    /// `storage`.
    pub(super) fn storage(&self) -> std::sync::MutexGuard<'_, Option<Storage>> {
        let mut guard = self.storage.lock().unwrap();
        if guard.is_none() {
            let path = self.config.state_dir.as_ref().map(|d| d.join("apps-storage.sqlite"));
            *guard = Storage::open(path.as_deref()).ok();
        }
        guard
    }

    /// Writes `apps.json` durably: temp file, fsync, rename.
    fn persist(&self, mirror: &Mirror) -> std::io::Result<()> {
        use std::io::Write as _;
        let Some(dir) = &self.config.state_dir else { return Ok(()) };
        // A fresh daemon may not have created its state directory yet.
        std::fs::create_dir_all(dir)?;
        let temp = dir.join("apps.json.tmp");
        let body = serde_json::to_vec_pretty(&json!({ "version": 1, "mirror": mirror }))
            .map_err(std::io::Error::other)?;
        let mut file = std::fs::File::create(&temp)?;
        file.write_all(&body)?;
        file.sync_all()?;
        std::fs::rename(&temp, dir.join("apps.json"))
    }

    /// The grant a host of `key` runs with.
    pub(super) fn grant_for(inner: &Inner, key: &HostKey) -> Grant {
        if key.preview {
            return Grant { preview: true, ..Grant::default() };
        }
        let record = inner.mirror.apps.get(&key.app);
        let requested = inner.catalog.packages.get(&key.app).map(Package::facts);
        let scopes = match (record, requested) {
            // Grants never exceed what the current manifest asks for.
            (Some(record), Some(facts)) => record
                .grants
                .iter()
                .filter(|s| facts.requested.contains(*s) || facts.optional.contains(*s))
                .cloned()
                .collect(),
            _ => BTreeSet::new(),
        };
        Grant { scopes, sandboxed: record.is_none_or(|r| r.sandboxed), ..Grant::default() }
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        self.timers.stop();
        let inner = self.inner.get_mut().unwrap();
        for host in inner.hosts.values() {
            if let Some(process) = &host.process {
                process.shutdown();
            }
        }
        // Servers are children of the daemon; none outlives the supervisor.
        for server in inner.servers.values() {
            server.process.kill();
        }
    }
}

fn load_mirror(state_dir: Option<&std::path::Path>) -> Mirror {
    let Some(dir) = state_dir else { return Mirror::default() };
    let path = dir.join("apps.json");
    let Ok(raw) = std::fs::read(&path) else { return Mirror::default() };
    match serde_json::from_slice::<Value>(&raw)
        .ok()
        .and_then(|v| serde_json::from_value::<Mirror>(v["mirror"].clone()).ok())
    {
        Some(mirror) => mirror,
        None => {
            // Keep the unreadable file for diagnosis; start from an empty mirror.
            let _ = std::fs::rename(&path, dir.join("apps.json.corrupt"));
            Mirror::default()
        }
    }
}

/// `{scope: class}` for the manifest's scopes and optionalScopes; a scope
/// the class table does not know is `unknown`.
fn scope_classes(facts: &mirror::Facts) -> serde_json::Map<String, Value> {
    use cmux_app_manifest::ScopeClass;
    facts
        .requested
        .iter()
        .chain(&facts.optional)
        .map(|scope| {
            let class = match cmux_app_manifest::scope_info(scope).map(|info| info.class) {
                Some(ScopeClass::Standard) => "standard",
                Some(ScopeClass::Sensitive) => "sensitive",
                Some(ScopeClass::Restricted) => "restricted",
                Some(ScopeClass::Elevated) => "elevated",
                None => "unknown",
            };
            (scope.clone(), json!(class))
        })
        .collect()
}

/// One `apps-list` entry.
pub(super) fn entry(id: &str, package: Option<&Package>, record: Option<&Record>) -> Value {
    let facts = package.map(Package::facts);
    let source =
        record.map(|r| r.source).or(package.map(|p| p.source)).unwrap_or(mirror::Source::User);
    let fallback = mirror::absent(source, facts.as_ref());
    let record = record.unwrap_or(&fallback);
    json!({
        "id": id,
        "version": package.map(|p| p.version.as_str()).unwrap_or(""),
        "tier": package.map(|p| p.tier).unwrap_or(mirror::Tier::Unverified),
        "installed": record.installed,
        "enabled": record.enabled,
        "hidden": record.hidden,
        "hidden_access": record.hidden_access,
        "source": record.source,
        "grants": record.grants,
        // The class of every scope the manifest asks for, so the
        // confirmation sheet can warn on sensitive, restricted and elevated.
        "scope_classes": facts.as_ref().map(scope_classes).unwrap_or_default(),
        "sandboxed": record.sandboxed,
        "available": package.is_some(),
        // Local connections only (apps commands refuse remote ones), so the
        // client may read icons and images straight from the package.
        "bundle_dir": package.map(|p| p.dir.to_string_lossy().into_owned()),
        // Palette entries (`apps-run {app, op}` runs them).
        "commands": package.map(Package::palette_commands).unwrap_or_default(),
        "manifest": package.map(|p| p.manifest.clone()).unwrap_or(Value::Null),
    })
}
