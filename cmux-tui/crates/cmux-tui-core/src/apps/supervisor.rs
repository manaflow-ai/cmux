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
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::catalog::{self, Catalog, Package, Sources};
use super::egress::Fetcher;
use super::grants::{Gestures, Grant};
use super::host::HostProcess;
use super::mirror::{self, Effect, Mirror, Op, Origin, Record, SetOp};
use super::storage::Storage;
use super::timer::{TimerId, Timers};
use crate::backoff::Backoff;
use crate::panic_free::RecoverPoison;
use cmux_json::JsonSet as _;

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
/// How `OpRouter::start_events` hands a change to the supervisor: a stream name and its body.
pub type StreamPublish = Box<dyn Fn(&str, Value) + Send + Sync>;

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
    /// Places installed app sections through the sidebar document's transaction.
    /// Automatic placement preserves every previous placement decision.
    fn place_sidebar_sections(
        &self,
        sections: &[cmux_layout_reducer::sidebar_doc::Section],
        automatic: bool,
    ) -> Result<Value, ApiError> {
        let _ = (sections, automatic);
        Err(ApiError::new("apps.sidebar.unavailable", "no sidebar document"))
    }
    /// On upgrade, receipt existing installs without changing the layout.
    fn initialize_sidebar_placements(
        &self,
        sections: &[cmux_layout_reducer::sidebar_doc::Section],
    ) -> Result<(), ApiError> {
        let _ = sections;
        Err(ApiError::new("apps.sidebar.unavailable", "no sidebar document"))
    }
    /// Starts delivering daemon change events as stream names
    /// (`workspace.changed`, `agent.changed`, …) and their bodies (`{}`, or
    /// `{"live": bool}` for a stream with a push channel). Called once, on the
    /// first app subscription.
    fn start_events(&self, publish: StreamPublish);
    /// For a stream fed by a push channel outside this machine (`github.changed`, the Cloud's
    /// webhooks): whether that channel is live now. A new subscriber hears `{"live": bool}` first,
    /// so a watch knows whether to keep its slow re-read. `None` for every other stream.
    fn stream_live(&self, stream: &str) -> Option<bool> {
        let _ = stream;
        None
    }
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
    /// The effective value of the dotted cmux setting `key` (a setting-backed App Store entry's
    /// switch, `store.rs`); None when unset or without a settings owner.
    fn setting_get(&self, key: &str) -> Option<Value> {
        let _ = key;
        None
    }
    /// Writes the dotted cmux setting `key` as the person's own change (the store checked the
    /// request's origin is the user).
    fn setting_set(&self, key: &str, value: Value) -> Result<(), ApiError> {
        let _ = (key, value);
        Err(ApiError::new("apps.setting.unavailable", "no settings owner"))
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
    /// The safe mode flag file (`crate::safe_mode_flag`), read once here
    /// and written when safe mode changes; `None` keeps safe mode in memory.
    pub safe_mode_file: Option<PathBuf>,
    /// `CMUX_SAFE_MODE` asked for safe mode when the daemon started.
    pub safe_mode_env: bool,
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
    /// The interface it renders (`cmux.section/1`), to find its export again
    /// when the package is saved.
    pub interface: String,
    pub export: String,
    pub context: Value,
    /// The next scene batch starts a fresh tree (after a host restart).
    pub reset: bool,
    /// Its op-batch rate and coalescing (`budget.rs`).
    pub budget: super::budget::MountBudget,
    /// A widget mount's clock and meter (`widgets.rs`); `None` for every other interface.
    pub widget: Option<super::widgets::WidgetMount>,
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
    /// Unsent runs for the replacement, separate from the outgoing process's responders.
    pub queued_runs: Vec<super::runs::PendingRun>,
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
    /// A local app's folder fingerprint when this process loaded it: a
    /// mount without an error keeps those files as the last good version
    /// (`rollback.rs`). `None` for other apps.
    pub print: Option<u64>,
    /// Kept up by the manifest's `activation` (`activation.rs`): stopped
    /// when the app may no longer run in the background.
    pub background: bool,
    /// The last `state` the host sent (`cmux.state`), in memory only. A
    /// restart of this record (a local reload, a grant change) hands it to
    /// the next host's `init`; a crash drops it, and it goes with the record
    /// when the app stops, is removed or idles out.
    pub kept_state: Option<Value>,
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
    pub inventory_demand: super::subscriptions::InventoryDemand,
    /// Provider connection per family, and calls waiting for a provider
    /// (`provider.rs`).
    pub providers: HashMap<String, u64>,
    pub provider_calls: HashMap<u64, super::provider::ProviderCall>,
    pub next_provider_request: u64,
    /// Granted `system_calendar.events.list` answers (`system_calendar.rs`).
    pub system_calendar: super::system_calendar::Cache,
    /// `apps-run` replay by idempotency key (`runs.rs`).
    pub run_keys: HashMap<String, super::runs::RunKey>,
    pub run_key_order: VecDeque<String>,
    /// One server process per app with a manifest `server` (`servers.rs`).
    pub servers: HashMap<String, super::servers::Server>,
    /// Open tokens minted for user runs of server ops (`servers.rs`).
    pub open_tokens: HashMap<String, super::open_tokens::OpenToken>,
    pub server_crashes: HashMap<String, super::servers::Crashes>,
    /// The kept-server count ([`Supervisor::kept_servers`]) as the last
    /// emit read it: compared and stored under this lock, so it follows the
    /// lock order and no stale read is stored after a newer one.
    pub kept_servers_told: usize,
    /// Run callers and the ops they wait for (`cancel.rs`).
    pub calls: super::cancel::Calls,
    /// The customize app's read scopes offered so far (granted by a save that
    /// first declared them), seeded on the first reload from the catalog
    /// read at start. Only grows (except scopes whose grant failed to save),
    /// so within a daemon run a read the person turned off is never granted
    /// again by a broken save or one that drops and re-adds it.
    pub customize_reads_offered: Option<BTreeSet<String>>,
    /// Safe mode (`safe_mode.rs`): `Some` while it is on.
    pub safe_mode: Option<crate::safe_mode_flag::Flag>,
    /// The crash loop record (`safe_mode.rs`).
    pub launches: super::safe_mode::Launches,
    /// The safe mode bisect (`safe_mode_bisect.rs`), only while safe mode is on.
    pub bisect: Option<super::safe_mode_bisect::Bisect>,
    /// Apps whose host failed (an init error, repeated crashes), with why;
    /// cleared when a host of theirs is ready again.
    pub failed: HashMap<String, String>,
    /// The local apps' folder fingerprints the catalog was last read with.
    pub local_prints: HashMap<String, u64>,
    /// The watched folders the catalog refused at the last reload pass that
    /// logged, with why: a refusal is logged when it is new or its reason
    /// changed, not again on every other app's save.
    pub local_rejected_logged: HashMap<PathBuf, String>,
    /// The watched folders' fingerprints `catalog` was read with: a reload
    /// pass reuses the read of each folder whose fingerprint is unchanged.
    pub local_dir_prints: HashMap<PathBuf, u64>,
    /// The watched folders' fingerprints at the last reload pass, whether it
    /// applied anything or not: a pass that reads only the folders a save
    /// names (`local_reload::Scope::Folders`) keeps these for the others.
    pub local_seen: HashMap<PathBuf, u64>,
    /// Each local app's last good copy (`rollback.rs`), and the fingerprint
    /// last tried, so one version is copied once.
    pub last_good: HashMap<String, super::rollback::Good>,
    pub good_tried: HashMap<String, u64>,
    /// Each app's budget ladder (`budget.rs`): its VM kills and whether it
    /// is paused. Absent: Normal with nothing counted.
    pub ladders: HashMap<String, super::budget::AppLadder>,
    /// Open web panes' bridges and their calls waiting for a provider
    /// (`page_calls.rs`).
    pub pages: super::page_calls::Pages,
    /// The widget layout and its replayed edits (`widgets.rs`).
    pub widgets: super::widgets::WidgetState,
    /// Extension signal sources' last values and floors (`signal_sources.rs`).
    pub signal_sources: super::signal_sources::SignalSources,
    /// `cmux.pane/1` opens with arguments, waiting for the pane's result (`pane_flow.rs`).
    pub pane_opens: super::pane_flow::PaneOpens,
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
    /// Tell a new subscriber of a pushed stream whether its push channel is live
    /// (`OpRouter::stream_live`); the router is asked outside the lock.
    StreamLiveness {
        key: HostKey,
        sub: u64,
        stream: String,
    },
    /// Keep a local app's loaded files as its last good version
    /// (`rollback.rs`): a file copy, so it runs outside the lock.
    KeepGood {
        app: String,
        dir: PathBuf,
        version: String,
        print: u64,
    },
}

pub struct Supervisor {
    pub(super) config: Config,
    pub(super) inner: Mutex<Inner>,
    pub(super) router: Box<dyn OpRouter>,
    pub(super) fetcher: Box<dyn Fetcher>,
    /// `integration.request` for provider `github`, answered here
    /// (`github_gateway.rs`). Unset, the call goes to the provider.
    pub(super) github: OnceLock<Arc<super::github_gateway::GitHubGateway>>,
    /// `net.fetch {cache: "shared"}`: one cache per URL for every app
    /// (`http_cache.rs`, the `http.json` signal source).
    pub(super) http_cache: super::http_cache::HttpCache,
    /// `cmux.watch` sources the daemon reads, one entry per (source, params) for every app
    /// (`signals_cache.rs`, `supervisor_signals.rs`). Taken after `inner`, never before.
    pub(super) signals: Mutex<super::supervisor_signals::Cache>,
    /// The App Store's Community source (`community.rs`), made on first use.
    pub(super) community: OnceLock<Arc<super::community::Community>>,
    pub(super) storage: Mutex<Option<Storage>>,
    /// Synced app storage's cloud link and outbox sender (`synced.rs`).
    pub(super) synced: super::synced::SyncState,
    pub(super) timers: Timers,
    pub(super) me: Weak<Supervisor>,
    /// Connector links of the terminal interfaces (`terminal_ops.rs`).
    pub(super) terminals: super::terminal_links::Terminals,
    transactions: AtomicU64,
    /// `apps-set` commits take turns here, so the supervisor lock is free
    /// while one writes `apps.json` (`Supervisor::set`).
    pub(super) commits: Mutex<()>,
    /// One `apps.json` write at a time (`Supervisor::persist`).
    persisting: Mutex<()>,
    /// App host processes spawned (`safe_mode.rs` `host_spawns`).
    pub(super) host_spawns: AtomicU64,
    /// Keeping a last good copy and rolling back, serialized per app
    /// (`rollback.rs`).
    pub(super) rollback_locks: super::rollback::AppLocks,
    /// One local reload pass at a time (`local_reload.rs`): a pass the CLI
    /// asks for and the file watch's never both apply the same save.
    pub(super) local_reload_pass: Mutex<()>,
    /// `apps-link-changed` coalescing: (one runs, another came meanwhile).
    pub(super) link_changed: Mutex<(bool, bool)>,
    /// Deployed instances of apps with a `deploy` block (`deploy.rs`).
    pub(super) deployments: super::deploy::Deployments,
    /// Git installs: staged fetches and the transport (`git_install.rs`).
    pub(super) git: super::git_install::GitState,
    /// The owner's keepers observers (`AppsSlot::add_server_observer`),
    /// told outside the lock when [`Self::kept_servers`] changes.
    server_observers: OnceLock<super::ServerObservers>,
    /// Test hook: the emit on this thread runs this right after its locked
    /// read, before it tells the observers (a race of two emits).
    #[cfg(test)]
    pub(super) emit_pause: Mutex<Option<EmitPause>>,
}

/// The test pause of one emit: the thread it is armed for, and what it runs.
#[cfg(test)]
pub(super) type EmitPause = (std::thread::ThreadId, Box<dyn FnOnce() + Send>);

pub(super) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or_default()
}

impl Supervisor {
    pub fn new(config: Config, router: Box<dyn OpRouter>, fetcher: Box<dyn Fetcher>) -> Arc<Self> {
        let config_state_dir = config.state_dir.clone();
        // Taken before the read (see `PrintsBefore`): a local app saved
        // during it is read again once the watch starts.
        let local_before = super::local_reload::PrintsBefore::take(&config.sources);
        let catalog = catalog::load(&config.sources);
        let local_prints = local_before.of(&config.sources, &catalog);
        let local_dir_prints = local_before.dirs().clone();
        let mut mirror = load_mirror(config.state_dir.as_deref());
        let safe_mode =
            super::safe_mode::initial(config.safe_mode_file.as_deref(), config.safe_mode_env);
        let launches = super::safe_mode::load_launches(config.state_dir.as_deref());
        let bisect =
            safe_mode.as_ref().and(super::safe_mode_bisect::load(config.state_dir.as_deref()));
        let last_good = super::rollback::load(config.state_dir.as_deref());
        // Snapshot before startup seeds: an existing install must not change the
        // person's layout on upgrade, but a newly appearing customize app may.
        let existing_sections = catalog
            .packages
            .values()
            .filter(|package| {
                // If initialization failed on an earlier start, installs
                // created since then still need their first placement.
                !mirror.sidebar_auto_place.contains(&package.id)
                    && mirror.apps.get(&package.id).is_some_and(|record| record.installed)
            })
            .flat_map(super::sidebar::sections)
            .collect::<Vec<_>>();
        if let Err(error) = router.initialize_sidebar_placements(&existing_sections) {
            // Automatic placement refuses to run without the durable migration
            // marker, so a failed initialization cannot mutate the old layout.
            eprintln!("cmux-tui: initialize app sidebar placement: {}", error.message);
        }
        let mut logs: HashMap<String, VecDeque<LogLine>> = HashMap::new();
        for (dir, issue) in &catalog.rejected {
            // A refused package is missing from the App Store: say so in the
            // daemon log too, not only in the apps log nobody opens.
            eprintln!("cmux-tui: app package {} refused: {issue}", dir.display());
            logs.entry("cmux/supervisor".into()).or_default().push_back(LogLine {
                level: "warn".into(),
                message: format!("{}: {issue}", dir.display()),
                ts_ms: now_ms(),
            });
        }
        let mut seeded = false;
        // First-party apps removed before the hide-only rule come back hidden.
        for (app, package) in &catalog.packages {
            if let Ok(outcome) =
                mirror::reduce(&mirror, &Op::Restore { app: app.clone() }, Some(&package.facts()))
                && outcome.changed
            {
                mirror = outcome.mirror;
                seeded = true;
            }
        }
        // The user's customization app installs itself the first time it
        // appears, and so does each setup's views layer (its card was the yes).
        let folder_apps = std::iter::once(catalog::CUSTOMIZE_APP)
            .chain(catalog.setup_layers.iter().map(String::as_str));
        for app in folder_apps {
            if let Some(next) = catalog
                .packages
                .get(app)
                .and_then(|package| super::local_reload::seed_customize(&mirror, package))
            {
                mirror = next;
                seeded = true;
            }
        }
        for app in &catalog.defaults {
            let Some(package) = catalog.packages.get(app) else { continue };
            let seed = Op::Seed { app: app.clone(), hidden: package.hidden_by_default() };
            if let Ok(outcome) = mirror::reduce(&mirror, &seed, Some(&package.facts()))
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
                inventory_demand: Default::default(),
                providers: HashMap::new(),
                provider_calls: HashMap::new(),
                next_provider_request: 0,
                system_calendar: Default::default(),
                run_keys: HashMap::new(),
                run_key_order: VecDeque::new(),
                servers: HashMap::new(),
                open_tokens: HashMap::new(),
                server_crashes: HashMap::new(),
                kept_servers_told: 0,
                calls: Default::default(),
                customize_reads_offered: None,
                safe_mode,
                launches,
                bisect,
                failed: HashMap::new(),
                local_prints,
                local_rejected_logged: HashMap::new(),
                local_seen: local_dir_prints.clone(),
                local_dir_prints,
                last_good,
                good_tried: HashMap::new(),
                ladders: HashMap::new(),
                pages: Default::default(),
                widgets: Default::default(),
                signal_sources: Default::default(),
                pane_opens: Default::default(),
            }),
            config,
            router,
            fetcher,
            github: OnceLock::new(),
            http_cache: super::http_cache::HttpCache::default(),
            signals: Mutex::default(),
            community: OnceLock::new(),
            storage: Mutex::new(None),
            synced: super::synced::SyncState::default(),
            timers: Timers::default(),
            me: me.clone(),
            terminals: Default::default(),
            transactions: AtomicU64::new(1),
            commits: Mutex::new(()),
            persisting: Mutex::new(()),
            host_spawns: AtomicU64::new(0),
            rollback_locks: Default::default(),
            local_reload_pass: Mutex::new(()),
            link_changed: Mutex::new((false, false)),
            deployments: super::deploy::Deployments::load(config_state_dir.as_deref()),
            git: Default::default(),
            server_observers: OnceLock::new(),
            #[cfg(test)]
            emit_pause: Mutex::new(None),
        });
        if seeded {
            let _ = supervisor.persist(&supervisor.inner.lock().unwrap().mirror);
        }
        supervisor.reconcile_sidebar();
        supervisor.start_always_servers();
        supervisor.activate_background(&BTreeSet::new());
        supervisor.start_local_watch();
        supervisor
    }

    /// Whether `app` is installed and enabled in the mirror.
    pub(crate) fn app_active(&self, app: &str) -> bool {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        inner.mirror.apps.get(app).is_some_and(|record| record.installed && record.enabled)
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
            inner.pages.client_gone(client);
            let mut provider_outs = self.provider_disconnect_locked(&mut inner, client);
            provider_outs.extend(self.external_disconnect_locked(&mut inner, client));
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
            outs.extend(Self::inventory_demand_locked(&mut inner));
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
            .map(|id| {
                let keys = self.page_key_overrides(&inner, id);
                let mut row = entry(
                    id,
                    inner.catalog.packages.get(id),
                    inner.mirror.apps.get(id),
                    keys.as_ref(),
                );
                row.set("instance", self.instance_json(id));
                let (run_state, can_rollback) = Self::run_facts(&inner, id);
                if let Some(run_state) = run_state {
                    row.set("run_state", json!(run_state));
                }
                row.set("can_rollback", json!(can_rollback));
                row.set("budget", json!(Self::budget_step_locked(&inner, id).as_str()));
                if let Some(ladder) = inner.ladders.get(id.as_str()) {
                    row.set("scene_batches", ladder.batches_json());
                }
                row
            })
            .collect();
        // `local_dir`: the local development folder this daemon watches
        // (`<state>/apps/local`, local_reload.rs), so `cmux ext dev` puts an
        // extension where this daemon loads it.
        let local_dir =
            self.config.sources.local.as_ref().map(|d| d.to_string_lossy().into_owned());
        json!({
            "revision": inner.mirror.revision,
            "apps": apps,
            "local_dir": local_dir,
            "safe_mode": super::safe_mode::flag_json(inner.safe_mode.as_ref()),
        })
    }

    /// `apps-set`: one validated commit of the install mirror. Every request
    /// ends with `request-settled`, rejects and no-ops included. The mirror
    /// is written to disk before it is applied; a failed write rejects.
    ///
    /// The write (an fsync, which a busy disk stretches to seconds) runs off
    /// the supervisor lock, so no other apps request waits for it. Commits
    /// take turns (`commits`); one whose mirror changed while it wrote (a
    /// local reload seeds the customization app under the lock) reduces and
    /// writes again, so no change is lost.
    pub fn set(&self, client: u64, op: SetOp) -> Result<Value, ApiError> {
        self.set_with_setting(client, op, None)
    }

    /// A setting-backed switch shares the install mirror's validation and replay boundary.
    /// Write the setting outside the supervisor lock, but inside the commit turn so an older
    /// switch cannot finish after a newer one. A refused setting write consumes no replay key.
    pub(super) fn set_with_setting(
        &self,
        client: u64,
        op: SetOp,
        mut setting: Option<(String, bool)>,
    ) -> Result<Value, ApiError> {
        let app = op.app.clone();
        let transaction = format!("apps-{}", self.transactions.fetch_add(1, Ordering::Relaxed));
        let turn = self.commits.lock().recover_poison();
        let (outs, result) = loop {
            let (base, staged) = {
                let inner = self.inner.lock().recover_poison();
                let facts = inner.catalog.packages.get(&app).map(Package::facts);
                let staged = mirror::reduce(&inner.mirror, &Op::Set(op.clone()), facts.as_ref())
                    .map_err(|r| ApiError::new(r.code(), r.message()));
                (inner.mirror.clone(), staged)
            };
            // A no-op still records its key, so the key cannot be reused later.
            let written = match &staged {
                Ok(outcome) if !outcome.replayed => {
                    let switched = match setting.take() {
                        Some((key, on)) => self.router.setting_set(&key, Value::Bool(on)),
                        None => Ok(()),
                    };
                    switched.and_then(|()| {
                        self.persist(&outcome.mirror)
                            .map_err(|e| ApiError::new("apps.persist", format!("apps.json: {e}")))
                    })
                }
                _ => Ok(()),
            };
            let mut inner = self.inner.lock().recover_poison();
            if written.is_ok() && staged.as_ref().is_ok_and(|o| !o.replayed) && inner.mirror != base
            {
                continue;
            }
            let mut outs = Vec::new();
            let result = written
                .and(staged)
                .map(|outcome| {
                    if !outcome.replayed {
                        self.apply_commit_locked(
                            &mut inner,
                            outcome,
                            &app,
                            &transaction,
                            &mut outs,
                        );
                    }
                })
                .map(|()| {
                    let keys = self.page_key_overrides(&inner, &app);
                    let mut record = entry(
                        &app,
                        inner.catalog.packages.get(&app),
                        inner.mirror.apps.get(&app),
                        keys.as_ref(),
                    );
                    // Lets a client drop list replies older than this commit.
                    record.set("revision", json!(inner.mirror.revision));
                    record
                });
            outs.push(Out::Client(client, json!({ "event": "request-settled", "transaction": transaction, "sequence": inner.mirror.revision })));
            break (outs, result);
        };
        // Before the emit: what it runs may commit again.
        drop(turn);
        self.emit(outs);
        result
    }

    /// Applies a commit already written to disk.
    pub(super) fn apply_commit_locked(
        &self,
        inner: &mut Inner,
        outcome: mirror::Outcome,
        app: &str,
        transaction: &str,
        outs: &mut Vec<Out>,
    ) {
        let app = app.to_string();
        inner.mirror = outcome.mirror;
        for effect in &outcome.effects {
            outs.extend(self.apply_effect(inner, effect));
        }
        if outcome.changed {
            outs.extend(self.sync_server_locked(inner, &app));
            // An app that starts syncing here reads the rows other devices wrote.
            self.appkv_refresh_locked(inner);
        }
        if outcome.changed {
            outs.push(Out::Broadcast(json!({ "event": "apps-changed", "revision": inner.mirror.revision, "transaction": transaction, "app": app })));
        }
        outs.extend(Self::inventory_demand_locked(inner));
    }

    fn apply_effect(&self, inner: &mut Inner, effect: &Effect) -> Vec<Out> {
        match effect {
            // Under the lock, so no call that runs after the commit sees the
            // old data (storage calls check the install under the same lock).
            Effect::ClearStorage(app) => {
                if let Some(storage) = self.storage().as_ref() {
                    let _ = storage.clear(app);
                }
                inner.signal_sources.forget_app(app);
                self.remove_server_dirs(app);
                self.remove_server_credential(app);
                vec![]
            }
            Effect::StopHost(app) => {
                // Off is the ladder's last step: on again starts Normal.
                inner.ladders.remove(app);
                // Turned on again, a background app gets a new try.
                inner.failed.remove(app);
                let mut outs = self.terminal_access_changed_locked(inner, app);
                outs.extend(self.stop_app_locked(inner, app, "disabled"));
                outs.extend(self.stop_server_locked(inner, app, "disabled"));
                outs
            }
            Effect::SettingsChanged(app) => {
                Self::push_settings_locked(inner, app);
                vec![]
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

    /// App servers that keep the daemon's owner (server/owner_keepers.rs):
    /// the running ones, and each `always` server that crashed and waits for
    /// its restart (`schedule_server_restart_locked`; it starts again with
    /// no request).
    pub(super) fn kept_servers(&self) -> usize {
        Self::kept_servers_locked(&self.inner.lock().recover_poison())
    }

    fn kept_servers_locked(inner: &Inner) -> usize {
        let restarting = inner
            .server_crashes
            .iter()
            .filter(|(app, crashes)| crashes.restart.is_some() && !inner.servers.contains_key(*app))
            .count();
        inner.servers.len().saturating_add(restarting)
    }

    /// Hands over the owner's keepers observers (`AppsSlot`), once.
    pub(super) fn observe_kept_servers(&self, observers: super::ServerObservers) {
        let _ = self.server_observers.set(observers);
    }

    /// Tells the observers that the kept count changed. Every change of the
    /// count (a start, an exit, a restart scheduled, fired or cancelled, a
    /// disable) is made under the lock by work that ends in [`Self::emit`],
    /// which compares it with the last one it read, under the same lock.
    fn notify_kept_servers(&self) {
        if let Some(observers) = self.server_observers.get() {
            for observer in observers.lock().recover_poison().iter() {
                observer();
            }
        }
    }

    /// Runs the test's pause when it is armed for this thread.
    #[cfg(test)]
    fn run_emit_pause(&self) {
        let pause = {
            let mut armed = self.emit_pause.lock().recover_poison();
            match armed.as_ref() {
                Some((thread, _)) if *thread == std::thread::current().id() => armed.take(),
                _ => None,
            }
        };
        if let Some((_, pause)) = pause {
            pause();
        }
    }

    pub(super) fn emit(&self, mut outs: Vec<Out>) {
        let (sinks, kept_changed) = {
            let mut inner = self.inner.lock().unwrap();
            outs.extend(Self::inventory_demand_locked(&mut inner));
            let kept = Self::kept_servers_locked(&inner);
            let changed = std::mem::replace(&mut inner.kept_servers_told, kept) != kept;
            (inner.sinks.clone(), changed)
        };
        #[cfg(test)]
        self.run_emit_pause();
        if kept_changed {
            self.notify_kept_servers();
        }
        if outs.is_empty() {
            return;
        }
        if outs
            .iter()
            .any(|out| matches!(out, Out::Broadcast(value) if value["event"] == "apps-changed"))
        {
            self.reconcile_sidebar();
        }
        let activate = background_triggers(&outs);
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
                // Up to 16 MiB of copying: never on the emitting thread.
                Out::KeepGood { app, dir, version, print } => {
                    if let Some(me) = self.me.upgrade() {
                        let _ = std::thread::Builder::new()
                            .name("cmux-apps-keep-good".into())
                            .spawn(move || me.keep_good(&app, &dir, &version, print));
                    }
                }
                Out::StartEvents => {
                    let me = self.me.clone();
                    self.router.start_events(Box::new(move |stream, body| {
                        if let Some(me) = me.upgrade() {
                            me.publish(stream, body);
                        }
                    }));
                }
                Out::StreamLiveness { key, sub, stream } => {
                    if let Some(live) = self.router.stream_live(&stream) {
                        self.send_liveness(&key, sub, &stream, live);
                    }
                }
            }
        }
        // After the outs above: a client hears `apps-changed` before the
        // `apps-host` of a background host it started.
        if let Some(retry) = activate {
            self.activate_background(&retry);
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

    /// Read an installed app's `cmux.keys` overrides only when its catalog
    /// actually declares page keys. Other apps never open storage on list.
    fn page_key_overrides(&self, inner: &Inner, app: &str) -> Option<Value> {
        let installed = inner.mirror.apps.get(app).is_some_and(|r| r.installed);
        if !installed || !inner.catalog.packages.get(app).is_some_and(Package::has_page_keys) {
            return None;
        }
        let storage = self.storage();
        let value = storage
            .as_ref()?
            .call(
                app,
                "app.storage.get",
                &json!({ "key": super::page_keys::OVERRIDES_KEY }),
                Self::synced_locked(inner, app),
            )
            .ok()?;
        value.is_object().then_some(value)
    }

    /// Refresh every client after an app changes its page-key overrides.
    pub(super) fn page_keys_changed(&self, app: &str) {
        let revision =
            self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner).mirror.revision;
        self.emit(vec![Out::Broadcast(json!({
            "event": "apps-changed",
            "revision": revision,
            "transaction": "page-keys",
            "app": app,
        }))]);
    }

    /// Writes `apps.json` durably: temp file, fsync, rename.
    pub(super) fn persist(&self, mirror: &Mirror) -> std::io::Result<()> {
        use std::io::Write as _;
        let Some(dir) = &self.config.state_dir else { return Ok(()) };
        // `apps-set` writes off the supervisor lock: two writers never share the temp file.
        let _one = self.persisting.lock().recover_poison();
        #[cfg(test)]
        persist_test_pause(dir);
        // A fresh daemon may not have created its state directory yet.
        std::fs::create_dir_all(dir)?;
        let temp = dir.join("apps.json.tmp");
        let mirror = mirror.to_stored().map_err(std::io::Error::other)?;
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

/// Whether `outs` may change which apps run in the background
/// (`activation.rs`): an `apps-changed` (install, enable, grant, safe mode,
/// local reload) or an `apps-budget` (pause, resume). `Some` holds the apps
/// a local reload saved, which get a new try after a failure.
fn background_triggers(outs: &[Out]) -> Option<BTreeSet<String>> {
    let mut triggered = false;
    let mut saved = BTreeSet::new();
    for out in outs {
        let Out::Broadcast(value) = out else { continue };
        match value["event"].as_str() {
            Some("apps-changed") => {
                triggered = true;
                if value["transaction"] == "local-reload"
                    && let Some(app) = value["app"].as_str()
                {
                    saved.insert(app.to_string());
                }
            }
            Some("apps-budget") => triggered = true,
            _ => {}
        }
    }
    triggered.then_some(saved)
}

/// A slow `apps.json` write on demand: an fsync on a busy disk takes seconds.
#[cfg(test)]
static PERSIST_PAUSES: Mutex<Vec<(PathBuf, Duration)>> = Mutex::new(Vec::new());

/// The next `apps.json` write into `dir` takes `pause` longer.
#[cfg(test)]
pub(super) fn pause_next_persist(dir: &std::path::Path, pause: Duration) {
    PERSIST_PAUSES.lock().recover_poison().push((dir.to_path_buf(), pause));
}

#[cfg(test)]
fn persist_test_pause(dir: &std::path::Path) {
    let pause = {
        let mut pauses = PERSIST_PAUSES.lock().recover_poison();
        let index = pauses.iter().position(|(d, _)| d == dir);
        index.map(|i| pauses.remove(i).1)
    };
    if let Some(pause) = pause {
        std::thread::sleep(pause);
    }
}

fn load_mirror(state_dir: Option<&std::path::Path>) -> Mirror {
    let Some(dir) = state_dir else { return Mirror::default() };
    let path = dir.join("apps.json");
    let Ok(raw) = std::fs::read(&path) else { return Mirror::default() };
    // A record or field of a newer build is kept, not a reason to set the file aside.
    match serde_json::from_slice::<Value>(&raw)
        .ok()
        .and_then(|mut v| Mirror::from_stored(v["mirror"].take()))
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
pub(super) fn entry(
    id: &str,
    package: Option<&Package>,
    record: Option<&Record>,
    key_overrides: Option<&Value>,
) -> Value {
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
        // First-party apps offer Hide and Show only, never Remove.
        "hide_only": package.is_some_and(|p| p.tier == mirror::Tier::FirstParty),
        "available": package.is_some(),
        // Local connections only (apps commands refuse remote ones), so the
        // client may read icons and images straight from the package.
        "bundle_dir": package.map(|p| p.dir.to_string_lossy().into_owned()),
        // Palette entries (`apps-run {app, op}` runs them).
        "commands": package.map(|p| p.palette_commands(key_overrides)).unwrap_or_default(),
        // `contributes.keybindings` in keybindings.json form, for the
        // client's app binding layer (an own op runs as `app.command.run`).
        "keybindings": package.map(Package::keybindings).unwrap_or_default(),
        "manifest": package.map(|p| p.manifest.clone()).unwrap_or(Value::Null),
        // The web panes the client may host (`render: web`): each page's
        // file root inside `bundle_dir` and its entry file, as the manifest
        // rules accepted them (cmux_app_manifest::web_pages).
        "web_pages": package.map(|p| web_pages_json(&p.manifest)).unwrap_or_default(),
    })
}

fn web_pages_json(manifest: &Value) -> Vec<Value> {
    cmux_app_manifest::web_pages(manifest)
        .into_iter()
        .map(|page| {
            json!({ "interface": page.interface, "root": page.root, "entry": page.entry, "symbol": page.symbol })
        })
        .collect()
}
