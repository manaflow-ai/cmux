//! The session pool: hidden pre-created sessions, so a harness switch in
//! the agent pane takes a session that is already up instead of waiting 1 to
//! 15 s for an adapter cold start (plans/cmux-next/acp-usability.md 2b).
//!
//! A pooled entry is a warm agent host (`__agent-host`) with the harness
//! spawned, `initialize` answered and the harness session created (ACP
//! `session/new`, or Claude's own session at spawn), because a warm process
//! alone still pays each session's MCP server start. It runs under a
//! reserved session id, and its host keeps its record, lock and socket in
//! `hosts/pool/` (`agent_host::POOL_DIR_NAME`), so nothing that reads the
//! hosts directory or the session list sees it: it never shows in
//! `_acpmux/sessions`, the status counts or the quit census, and it writes
//! nothing to the session store. Its wire log is held in memory.
//!
//! `session/new` claims an entry whose key matches exactly (origin, cwd,
//! harness, preset, final argv, system prompt sha256, env and credential
//! fingerprint, account) and creates the session under the reserved id;
//! `ensure_child` then takes it right after its host-adoption block: the
//! record moves into `hosts/` (the session is durable from then on), the
//! held log reaches the session log in order, and live traffic follows.
//!
//! Policy (`policy.rs`): at most two entries per cwd, the harness used
//! before the current one and the one the pane hints at
//! (`_acpmux/prewarm`, debounced); a 1 GB RSS cap for the whole pool, oldest
//! first; idle exit on the injected clock (`pool.idleMinutes`, default 10).
//! The default for idle CPU is that exit; `pool.park` (off) SIGSTOPs a ready
//! harness instead. Never for a remote-origin chain (REMOTE-FLOOR v3).
//! Shutdown ends every entry; a crashed daemon's entries are ended by the
//! next daemon before it adopts hosts (`sweep_pool_hosts`).

use super::*;
use crate::agent::{Attached, Tap};
use crate::agent_host::{self, HostRecord, Liveness};
use crate::clock::Clock;
use std::collections::VecDeque;
use std::future::Future;
use std::hash::{Hash, Hasher};
use std::time::Duration;

mod auth;
pub(crate) mod policy;
use policy::{Origin, Pool, PoolKey, Role, Take};

/// Held log lines and inbound messages per entry, beyond which stderr is
/// dropped (anything else is kept).
const HELD_CAP: usize = 1024;
/// Most a pooled start may take before it counts as failed.
const START_BUDGET: Duration = Duration::from_secs(90);
/// How long an ended entry's host gets before it is ended by nonce proof.
const END_GRACE: Duration = Duration::from_secs(2);

/// Measures a pooled host's process tree RSS in bytes.
pub type RssProbe = Arc<dyn Fn(u32) -> u64 + Send + Sync>;

/// The pool on the hub.
pub(crate) struct PoolState {
    pool: StdMutex<Pool<Pooled>>,
    /// Claimed by `session/new`, taken by `ensure_child`, by session id.
    claimed: StdMutex<HashMap<String, Pooled>>,
    wake: Arc<Notify>,
    reaper: AtomicBool,
    stopping: AtomicBool,
    /// Ends the reaper (`stop_pool`).
    stop: Notify,
    /// The newest `_acpmux/prewarm`; an older debounced hint is dropped.
    hint_gen: AtomicU64,
    auth: auth::AuthCache,
    /// Per cwd: the (harness, preset) of the newest new session there and
    /// of the one before it (the last-used role).
    recent: StdMutex<HashMap<PathBuf, (Spec, Option<Spec>)>>,
    rss: StdMutex<RssProbe>,
}

type Spec = (String, Option<String>);

impl PoolState {
    pub(super) fn new() -> Self {
        Self {
            pool: StdMutex::new(Pool::new(crate::config::PoolConfig::default().idle())),
            claimed: StdMutex::new(HashMap::new()),
            wake: Arc::new(Notify::new()),
            reaper: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
            stop: Notify::new(),
            hint_gen: AtomicU64::new(0),
            auth: auth::AuthCache::default(),
            recent: StdMutex::new(HashMap::new()),
            rss: StdMutex::new(Arc::new(tree_rss_bytes)),
        }
    }
}

/// Log lines (with their host entry) held until a session takes the entry.
enum TapSlot {
    Held(Vec<(Direction, Message, Option<u64>)>),
    Live(Tap),
}

/// One hidden session, ready for a `session/new` to take.
pub(super) struct Pooled {
    session_id: String,
    child: Arc<ChildAgent>,
    record: HostRecord,
    claude: bool,
    /// The harness's `initialize` answer.
    init: Value,
    /// The harness's `session/new` answer (ACP harnesses).
    new_result: Option<Value>,
    tap: Arc<StdMutex<TapSlot>>,
    target: Option<oneshot::Sender<mpsc::Sender<Inbound>>>,
    rss: u64,
    parked: bool,
}

/// What a pooled session is started from, and the key it is served under.
struct PoolSpec {
    key: PoolKey,
    spawn: HarnessProfile,
    draft: SessionMeta,
}

/// `_acpmux/prewarm`: the harness (and preset) the pane is about to use.
#[derive(Debug, Clone, Default)]
pub struct PrewarmRequest {
    pub harness: Option<String>,
    pub preset: Option<String>,
    pub cwd: Option<PathBuf>,
    /// Answer once the hinted entry is ready or failed (tests, benchmarks).
    pub wait: bool,
    /// Asked over a remote-origin connection: refused.
    pub remote: bool,
}

fn pool_dir() -> PathBuf {
    agent_host::pool_dir(&agent_host::hosts_dir())
}

fn internal(e: impl std::fmt::Display) -> RpcError {
    RpcError::internal(e.to_string())
}

/// The `initialize` request acpmux sends every harness it runs.
fn initialize_params() -> Value {
    json!({
        "protocolVersion": 1,
        "clientCapabilities": {
            "fs": {"readTextFile": true, "writeTextFile": true},
            "terminal": false
        },
        "clientInfo": {"name": "acpmux", "version": VERSION}
    })
}

fn is_stderr_note(msg: &Message) -> bool {
    matches!(msg, Message::Notification { method, .. } if method == crate::agent::HOST_STDERR)
}

/// A tap that holds every line until the entry is taken. Held lines count
/// as stored: they reach the session log, in order, when it is taken.
fn holding_tap() -> (Tap, Arc<StdMutex<TapSlot>>) {
    let slot = Arc::new(StdMutex::new(TapSlot::Held(Vec::new())));
    let s = slot.clone();
    let tap: Tap = Arc::new(move |dir, msg, host_seq| {
        let mut guard = s.lock().unwrap();
        match &mut *guard {
            TapSlot::Held(held) => {
                if held.len() < HELD_CAP || !is_stderr_note(msg) {
                    held.push((dir, msg.clone(), host_seq));
                }
                true
            }
            TapSlot::Live(live) => {
                let live = live.clone();
                drop(guard);
                live(dir, msg, host_seq)
            }
        }
    });
    (tap, slot)
}

/// Inbound traffic of an entry: held until a session's channel arrives,
/// then forwarded in order.
fn holding_inbound() -> (mpsc::Sender<Inbound>, oneshot::Sender<mpsc::Sender<Inbound>>) {
    let (tx, mut rx) = mpsc::channel::<Inbound>(1024);
    let (target_tx, mut target_rx) = oneshot::channel::<mpsc::Sender<Inbound>>();
    tokio::spawn(async move {
        let mut held = VecDeque::new();
        let target = loop {
            tokio::select! {
                t = &mut target_rx => match t {
                    Ok(t) => break t,
                    Err(_) => return, // ended untaken
                },
                m = rx.recv() => match m {
                    Some(m) => {
                        if held.len() < HELD_CAP || !matches!(m, Inbound::Stderr(..)) {
                            held.push_back(m);
                        }
                    }
                    None => return,
                },
            }
        };
        for m in held {
            if target.send(m).await.is_err() {
                return;
            }
        }
        while let Some(m) = rx.recv().await {
            if target.send(m).await.is_err() {
                return;
            }
        }
    });
    (tx, target_tx)
}

/// `killpg` on the harness group of a pooled host (park and resume).
fn signal_harness(record: &HostRecord, signal: i32) {
    if let Some(pid) = record.harness_pid.and_then(|p| i32::try_from(p).ok()) {
        // SAFETY: the harness leads its own process group under its host.
        unsafe { libc::killpg(pid, signal) };
    }
}

/// Resident memory of `root` and every descendant, in bytes (one `ps`).
pub fn tree_rss_bytes(root: u32) -> u64 {
    let Ok(out) = std::process::Command::new("ps").args(["-A", "-o", "pid=,ppid=,rss="]).output()
    else {
        return 0;
    };
    let rows: Vec<(u32, u32, u64)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace().map(|x| x.parse::<u64>().ok());
            Some((f.next()?? as u32, f.next()?? as u32, f.next()??))
        })
        .collect();
    let mut tree = vec![root];
    let mut i = 0;
    while i < tree.len() {
        let parent = tree[i];
        tree.extend(rows.iter().filter(|r| r.1 == parent && r.0 != parent).map(|r| r.0));
        i += 1;
    }
    rows.iter().filter(|r| tree.contains(&r.0)).map(|r| r.2 * 1024).sum()
}

/// End idle entries at their deadline. Waits only on `clock`, the pool's
/// wake signal and `stopped`, so an idle pool costs no CPU; returns when
/// `stopped` resolves or `clock` reports the owner gone (None).
pub(crate) async fn run_reaper<T>(
    pool: &StdMutex<Pool<T>>,
    wake: &Notify,
    stopped: impl Future<Output = ()>,
    mut clock: impl FnMut() -> Option<Arc<dyn Clock>>,
    mut expired: impl FnMut(Vec<T>),
) {
    tokio::pin!(stopped);
    loop {
        let Some(clock) = clock() else { return };
        let next = pool.lock().unwrap().next_deadline();
        let woke = async {
            match next {
                Some(at) => {
                    tokio::select! {
                        _ = clock.sleep_until(at) => {}
                        _ = wake.notified() => {}
                    }
                }
                None => wake.notified().await,
            }
        };
        tokio::select! {
            _ = &mut stopped => return,
            _ = woke => {}
        }
        let out = pool.lock().unwrap().expire(clock.now());
        if !out.is_empty() {
            expired(out);
        }
    }
}

impl Hub {
    async fn pool_enabled(&self) -> bool {
        !self.pool.stopping.load(Ordering::SeqCst)
            && !self.stopping.load(Ordering::SeqCst)
            && self.agent_hosts_enabled()
            && self.config.read().await.pool.enabled
    }

    /// Measure pooled hosts with `probe` instead of `ps` (tests).
    pub fn set_pool_rss_probe(&self, probe: RssProbe) {
        *self.pool.rss.lock().unwrap() = probe;
    }

    /// The pool as it is now (`_acpmux/status` `pool`). Never lists ids.
    pub fn pool_view_json(&self) -> Value {
        let pool = self.pool.pool.lock().unwrap();
        let entries: Vec<Value> = pool
            .view()
            .into_iter()
            .map(|v| {
                let mut roles = Vec::new();
                if v.last_used {
                    roles.push("lastUsed");
                }
                if v.hinted {
                    roles.push("hinted");
                }
                json!({"harness": v.key.harness, "preset": v.key.preset, "cwd": v.key.cwd,
                    "roles": roles, "state": v.state})
            })
            .collect();
        drop(pool);
        let rss: u64 = self.pool.pool.lock().unwrap().ready_mut().map(|p| p.rss).sum();
        json!({"entries": entries, "rssBytes": rss})
    }

    /// The key and spawn line a new session drafted as `draft` would get.
    async fn pool_spec_for(
        &self,
        draft: &SessionMeta,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Result<PoolSpec, RpcError> {
        let spawn = self.spawn_profile_for(draft, profile, defaults_env).await?;
        let sha = match &draft.preset {
            Some(name) => self
                .config
                .read()
                .await
                .presets
                .get(name)
                .and_then(|p| p.system_prompt_sha256.clone()),
            None => None,
        };
        let family = draft.family.clone().unwrap_or_default();
        let (credentials, account) = self.pool.auth.fingerprint(&family, &spawn.env);
        let mut h = std::collections::hash_map::DefaultHasher::new();
        spawn.env.hash(&mut h);
        credentials.hash(&mut h);
        let key = PoolKey {
            origin: if draft.remote_origin { Origin::Remote } else { Origin::Local },
            cwd: draft.cwd.clone(),
            harness: draft.harness.clone(),
            preset: draft.preset.clone(),
            args: spawn.argv.clone(),
            system_prompt_sha256: sha,
            auth: format!("{:016x}", h.finish()),
            account,
        };
        Ok(PoolSpec { key, spawn, draft: draft.clone() })
    }

    /// The spec for a new local session of `harness`/`preset` in `cwd`.
    async fn pool_spec(
        &self,
        harness: Option<String>,
        preset: Option<String>,
        cwd: PathBuf,
    ) -> Result<PoolSpec, RpcError> {
        let r = {
            let cfg = self.config.read().await;
            self.resolve_new(&cfg, harness, &preset, None, false)?
        };
        let family = crate::config::derive_family(&r.agent, &r.profile);
        let cwd = super::adoption::session_cwd(Some(cwd), None, &family)?;
        let spawn_model = profile_takes_model_at_spawn(&r.profile)
            || r.defaults.env.values().any(|v| v.contains("${model}"));
        let draft = super::lifecycle::draft_meta(super::lifecycle::Draft {
            id: String::new(),
            agent: &r.agent,
            profile: &r.profile,
            family: &family,
            preset: r.preset_name.clone(),
            model_request: if spawn_model { r.defaults.model.clone() } else { None },
            cwd,
            agent_session_id: None,
            policy: r.defaults.policy,
            remote: false,
        });
        self.pool_spec_for(&draft, &r.profile, &r.defaults.env).await
    }

    /// `_acpmux/prewarm`: accepted at once; after the debounce, the newest
    /// hint (and nothing older) starts warming in the background.
    pub async fn prewarm(self: &Arc<Self>, req: PrewarmRequest) -> Result<Value, RpcError> {
        if req.remote {
            return Err(RpcError::invalid_params(
                "a remote-origin connection never uses the session pool",
            ));
        }
        if !self.pool_enabled().await {
            return Ok(json!({"accepted": false, "reason": "the session pool is off"}));
        }
        let cwd = match req.cwd.clone() {
            Some(c) => c,
            None => self
                .sessions()
                .into_iter()
                .find(|s| !s.meta().remote_origin)
                .map(|s| s.meta().cwd)
                .or_else(dirs::home_dir)
                .unwrap_or_else(|| PathBuf::from("/")),
        };
        let generation = self.pool.hint_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let debounce = Duration::from_millis(self.config.read().await.pool.debounce_ms);
        let hub = self.clone();
        let PrewarmRequest { harness, preset, wait, .. } = req;
        let task = tokio::spawn(async move {
            if !debounce.is_zero() {
                let clock = hub.clock.lock().unwrap().clone();
                let at = clock.now() + debounce;
                clock.sleep_until(at).await;
            }
            if hub.pool.hint_gen.load(Ordering::SeqCst) != generation {
                return Ok(None);
            }
            hub.wait_startup().await;
            let spec = hub.pool_spec(harness, preset, cwd).await?;
            let key = spec.key.clone();
            hub.pool_want(Role::Hinted, spec).await;
            Ok::<_, RpcError>(Some(key))
        });
        if !wait {
            return Ok(json!({"accepted": true}));
        }
        let key = task.await.map_err(internal)??;
        if let Some(key) = &key {
            self.pool_settled(key).await;
        }
        Ok(json!({"accepted": true, "superseded": key.is_none(), "pool": self.pool_view_json()}))
    }

    /// Wait until `key` is not warming.
    async fn pool_settled(&self, key: &PoolKey) {
        loop {
            let rx = self.pool.pool.lock().unwrap().watch_warming(key);
            let Some(mut rx) = rx else { return };
            if rx.changed().await.is_err() {
                return;
            }
        }
    }

    /// Point `role` at `spec` and start it when nothing holds it.
    async fn pool_want(self: &Arc<Self>, role: Role, spec: PoolSpec) {
        if !self.pool_enabled().await {
            return;
        }
        let idle = self.config.read().await.pool.idle();
        let now = self.clock.lock().unwrap().now();
        let wanted = {
            let mut pool = self.pool.pool.lock().unwrap();
            pool.set_idle(idle);
            pool.want(role, spec.key.clone(), now)
        };
        self.pool_discard(wanted.evicted);
        self.start_pool_reaper();
        let Some(generation) = wanted.start else { return };
        let hub = self.clone();
        tokio::spawn(async move {
            let started = tokio::time::timeout(START_BUDGET, hub.spawn_pooled(&spec)).await;
            match started {
                Ok(Ok(p)) => {
                    let back = if hub.pool.stopping.load(Ordering::SeqCst) {
                        Some(p)
                    } else {
                        let now = hub.clock.lock().unwrap().now();
                        hub.pool.pool.lock().unwrap().complete(&spec.key, generation, p, now)
                    };
                    let returned = back.is_some();
                    hub.pool_discard(back.into_iter().collect());
                    if !returned {
                        hub.pool_after_ready().await;
                    }
                }
                Ok(Err(e)) => {
                    tracing::warn!(harness = %spec.key.harness, "pooled session failed to start: {e:#}");
                    hub.pool.pool.lock().unwrap().failed(&spec.key, generation);
                }
                Err(_) => {
                    tracing::warn!(harness = %spec.key.harness, "pooled session did not start in {START_BUDGET:?}");
                    hub.pool.pool.lock().unwrap().failed(&spec.key, generation);
                }
            }
        });
    }

    /// An entry became ready: measure the pool, keep it under the RSS cap
    /// (oldest first), and park ready harnesses when `pool.park` is on.
    async fn pool_after_ready(&self) {
        let (cap, park) = {
            let cfg = self.config.read().await;
            (cfg.pool.max_rss_mb.saturating_mul(1024 * 1024), cfg.pool.park)
        };
        let pids: Vec<u32> =
            self.pool.pool.lock().unwrap().ready_mut().map(|p| p.record.host_pid).collect();
        let probe = self.pool.rss.lock().unwrap().clone();
        let measured: HashMap<u32, u64> =
            tokio::task::spawn_blocking(move || pids.into_iter().map(|p| (p, probe(p))).collect())
                .await
                .unwrap_or_default();
        let evicted = {
            let mut pool = self.pool.pool.lock().unwrap();
            for p in pool.ready_mut() {
                if let Some(rss) = measured.get(&p.record.host_pid) {
                    p.rss = *rss;
                }
                if park && !p.parked {
                    signal_harness(&p.record, libc::SIGSTOP);
                    p.parked = true;
                }
            }
            pool.enforce_cap(cap, |p| p.rss)
        };
        if !evicted.is_empty() {
            tracing::info!(
                count = evicted.len(),
                "session pool over its RSS cap; oldest entries end"
            );
        }
        self.pool_discard(evicted);
    }

    /// Start one hidden session for `spec` under a fresh reserved id: its
    /// host in the pool directory, `initialize`, then the harness session.
    async fn spawn_pooled(&self, spec: &PoolSpec) -> anyhow::Result<Pooled> {
        let session_id = uuid::Uuid::now_v7().to_string();
        let draft = &spec.draft;
        let name = self.unique_name(&draft.harness);
        let profile = &spec.spawn;
        let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let (command_line, translator) = if claude {
            // As `ensure_child` starts a fresh Claude session.
            let fresh_id = uuid::Uuid::now_v7().to_string();
            let effort = current_option(draft, "effort").unwrap_or_else(|| "default".into());
            let mode = "default".to_owned();
            let model = current_model(draft).unwrap_or_else(|| "default".into());
            let plan = crate::claude_stdio::spawn_plan(
                profile,
                None,
                false,
                Some(&fresh_id),
                Some(&effort),
                &mode,
                Some(&model),
            );
            (
                Some((plan.program, plan.args)),
                Some(agent_host::TranslatorSpec {
                    acp_session_id: session_id.clone(),
                    mode,
                    model,
                    effort,
                    claude_session_id: Some(fresh_id),
                }),
            )
        } else {
            (None, None)
        };
        let cmd = crate::agent::harness_command(
            &draft.harness,
            profile,
            &draft.cwd,
            command_line,
            Some((&session_id, &name)),
        )?;
        let std_cmd = cmd.as_std();
        let dir = pool_dir();
        let host_spec = agent_host::SpawnSpec {
            session_id: session_id.clone(),
            program: std_cmd.get_program().to_string_lossy().into_owned(),
            args: std_cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect(),
            env: crate::agent::command_env(&cmd),
            cwd: draft.cwd.clone(),
            translator,
            socket: agent_host::socket_path(&dir, &session_id),
            hosts_dir: dir,
            buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        };
        let launcher = agent_host::link::HostLauncher::current()?;
        let record = agent_host::link::spawn(&launcher, &host_spec).await?;
        let (tap, slot) = holding_tap();
        let (inbound, target) = holding_inbound();
        let attached =
            ChildAgent::attach_hosted(&draft.harness, record.clone(), 0, Vec::new(), inbound, tap)
                .await;
        let child = match attached {
            Ok(Attached::Ready(child, _, _)) => child,
            Ok(Attached::Incompatible { .. }) => {
                end_pooled_host(&record).await;
                anyhow::bail!("a host of this build refused its controller")
            }
            Err(e) => {
                end_pooled_host(&record).await;
                return Err(e);
            }
        };
        let started = async {
            let init = child.request(method::INITIALIZE, initialize_params()).await?;
            let new_result = if claude {
                None
            } else {
                Some(
                    child
                        .request(method::SESSION_NEW, json!({"cwd": draft.cwd, "mcpServers": []}))
                        .await?,
                )
            };
            Ok::<_, RpcError>((init, new_result))
        }
        .await;
        let (init, new_result) = match started {
            Ok(v) => v,
            Err(e) => {
                child.kill().await;
                end_pooled_host(&record).await;
                anyhow::bail!("{}", e.message);
            }
        };
        Ok(Pooled {
            session_id,
            child,
            record,
            claude,
            init,
            new_result,
            tap: slot,
            target: Some(target),
            rss: 0,
            parked: false,
        })
    }

    /// End entries nobody will take (in the background).
    fn pool_discard(&self, entries: Vec<Pooled>) {
        for p in entries {
            tokio::spawn(end_pooled(p));
        }
    }

    /// `session/new` for `meta`: claim the pooled session of exactly this
    /// shape, waiting for one that is starting. Returns its reserved id,
    /// which the new session takes; None starts cold.
    pub(super) async fn pool_claim(
        &self,
        meta: &SessionMeta,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Option<String> {
        // REMOTE-FLOOR v3: a remote-origin chain is never served.
        if meta.remote_origin || !self.pool_enabled().await {
            return None;
        }
        let spec = self.pool_spec_for(meta, profile, defaults_env).await.ok()?;
        loop {
            let took = self.pool.pool.lock().unwrap().take(&spec.key);
            match took {
                Take::Ready(p) => {
                    if !p.child.is_alive().await {
                        self.pool_discard(vec![p]);
                        return None;
                    }
                    if p.parked {
                        signal_harness(&p.record, libc::SIGCONT);
                    }
                    let id = p.session_id.clone();
                    self.pool.claimed.lock().unwrap().insert(id.clone(), p);
                    return Some(id);
                }
                Take::Discard(old) => {
                    tracing::info!(harness = %spec.key.harness, "pooled session discarded: its key changed");
                    self.pool_discard(old.into_iter().collect());
                    return None;
                }
                Take::Miss => return None,
                Take::Warming(mut settled) => {
                    if settled.changed().await.is_err() {
                        return None;
                    }
                }
            }
        }
    }

    /// The claimed pooled session for `id`, if `session/new` claimed one.
    pub(super) fn pool_take_claimed(&self, id: &str) -> Option<Pooled> {
        self.pool.claimed.lock().unwrap().remove(id)
    }

    /// End a claimed pooled session that was not taken.
    pub(super) fn pool_drop_claimed(&self, id: &str) {
        if let Some(p) = self.pool_take_claimed(id) {
            self.pool_discard(vec![p]);
        }
    }

    /// `ensure_child` takes a claimed pooled session for `session`: move its
    /// record into the hosts directory, log its host start and held lines,
    /// switch it live, and record what its harness answered. An entry that
    /// cannot be promoted is ended and the caller starts cold.
    pub(super) async fn adopt_pooled(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut p: Pooled,
    ) -> anyhow::Result<Arc<ChildAgent>> {
        if let Err(e) = agent_host::promote(&pool_dir(), &agent_host::hosts_dir(), &p.record) {
            tokio::spawn(end_pooled(p));
            return Err(e);
        }
        let tap = self.session_tap(session);
        self.append(
            session,
            "mux",
            "host_started",
            json!({"incarnation": p.record.incarnation, "hostPid": p.record.host_pid, "hostBuild": p.record.host_build}),
        );
        {
            let mut slot = p.tap.lock().unwrap();
            if let TapSlot::Held(held) = &mut *slot {
                for (dir, msg, host_seq) in held.drain(..) {
                    tap(dir, &msg, host_seq);
                }
            }
            *slot = TapSlot::Live(tap);
        }
        if let Some(target) = p.target.take() {
            let _ = target.send(session.inbound_tx.clone());
        }
        let child = p.child.clone();
        *session.child.lock().await = Some(child.clone());
        self.wake_idle_reaper();
        if let Some(rx) = session.inbound_rx.lock().await.take() {
            let hub = self.clone();
            let s = session.clone();
            tokio::spawn(async move { hub.inbound_loop(s, rx).await });
        }
        let init = &p.init;
        let steering =
            init.pointer("/_meta/steering/supported").and_then(Value::as_bool).unwrap_or(false);
        session.steering.store(steering, Ordering::SeqCst);
        {
            let mut m = session.meta.lock().unwrap();
            m.agent_info = init.get("agentInfo").cloned();
            m.agent_capabilities = init.get("agentCapabilities").cloned();
        }
        if p.claude {
            let state = child.claude_state().await.unwrap_or_default();
            let mut m = session.meta.lock().unwrap();
            m.agent_session_id = state.session_id;
            m.modes = Some(state.modes);
            m.config_options = Some(state.config_options);
        } else if let Some(res) = &p.new_result {
            let sid = res.get("sessionId").and_then(Value::as_str).map(str::to_owned);
            session.meta.lock().unwrap().agent_session_id = sid;
            self.absorb_session_response(session, res);
        }
        self.append(session, "mux", "pool_taken", json!({"rssBytes": p.rss}));
        self.set_status(session, SessionStatus::Ready);
        self.save_meta(session);
        let meta_now = session.meta();
        self.remember_models(&meta_now.harness, &meta_now);
        Ok(child)
    }

    /// A local session was created: the harness used before it in that cwd
    /// takes the last-used role (the common back-and-forth is a hit).
    pub(super) fn pool_note_used(self: &Arc<Self>, session: &Session) {
        let m = session.meta();
        if m.remote_origin {
            return;
        }
        let spec: Spec = (m.harness.clone(), m.preset.clone());
        let previous = {
            let mut recent = self.pool.recent.lock().unwrap();
            let e = recent.entry(m.cwd.clone()).or_insert_with(|| (spec.clone(), None));
            if e.0 != spec {
                e.1 = Some(std::mem::replace(&mut e.0, spec));
            }
            e.1.clone()
        };
        let Some((harness, preset)) = previous else { return };
        let hub = self.clone();
        let cwd = m.cwd;
        tokio::spawn(async move {
            match hub.pool_spec(Some(harness), preset, cwd).await {
                Ok(spec) => hub.pool_want(Role::LastUsed, spec).await,
                Err(e) => tracing::debug!("last-used harness not poolable: {}", e.message),
            }
        });
    }

    /// Config reload: every entry ends; none started under the old catalog
    /// is served.
    pub(super) fn drain_pool(&self) {
        let all = self.pool.pool.lock().unwrap().clear();
        self.pool_discard(all);
    }

    /// Daemon shutdown: no entry starts again and every entry ends (they are
    /// hidden sessions, never handed to the next daemon). Bounded.
    pub(super) async fn stop_pool(&self) {
        self.pool.stopping.store(true, Ordering::SeqCst);
        // One reaper waits on it; a stored permit ends a reaper that is not
        // waiting yet.
        self.pool.stop.notify_one();
        let mut all = self.pool.pool.lock().unwrap().clear();
        all.extend(self.pool.claimed.lock().unwrap().drain().map(|(_, p)| p));
        let ends = futures::future::join_all(all.into_iter().map(end_pooled));
        if tokio::time::timeout(END_GRACE * 3, ends).await.is_err() {
            tracing::warn!("pooled sessions did not end in time; the next daemon ends them");
        }
    }

    /// At daemon start, before adoption: end every host a previous daemon
    /// left in the pool directory (its pooled sessions were never taken).
    pub(super) async fn sweep_pool_hosts(&self) {
        let dir = pool_dir();
        let Ok((good, bad)) = agent_host::load_records(&dir) else { return };
        for (_, record) in good {
            end_pooled_host(&record).await;
        }
        for b in bad {
            let ended = super::hosts::end_host_blocking(
                dir.clone(),
                b.session_id.clone(),
                b.start_nonce.clone(),
                b.host_pid,
            )
            .await;
            if ended {
                let _ = std::fs::remove_file(&b.path);
            }
        }
    }

    /// One reaper task per hub while the pool holds entries; it stops when
    /// the pool empties, on `stop_pool`, or when `hub.shutdown` is notified.
    fn start_pool_reaper(self: &Arc<Self>) {
        if self.pool.reaper.swap(true, Ordering::SeqCst) {
            self.pool.wake.notify_one();
            return;
        }
        let hub = self.clone();
        tokio::spawn(async move {
            loop {
                let stopped = async {
                    tokio::select! {
                        _ = hub.shutdown.notified() => {}
                        _ = hub.pool.stop.notified() => {}
                    }
                };
                let state = hub.pool.clone();
                run_reaper(
                    &state.pool,
                    &state.wake,
                    stopped,
                    || {
                        let empty = state.pool.lock().unwrap().is_empty();
                        (!empty && !state.stopping.load(Ordering::SeqCst))
                            .then(|| hub.clock.lock().unwrap().clone())
                    },
                    |expired| {
                        tracing::info!(count = expired.len(), "idle pooled sessions exit");
                        for p in expired {
                            tokio::spawn(end_pooled(p));
                        }
                    },
                )
                .await;
                hub.pool.reaper.store(false, Ordering::SeqCst);
                // An entry added while the reaper was leaving restarts it.
                let again = !hub.pool.pool.lock().unwrap().is_empty()
                    && !hub.pool.stopping.load(Ordering::SeqCst)
                    && !hub.stopping.load(Ordering::SeqCst)
                    && !hub.pool.reaper.swap(true, Ordering::SeqCst);
                if !again {
                    return;
                }
            }
        });
    }
}

/// End one pooled session: continue a parked harness, end it through its
/// host, then by nonce proof if the host still runs.
async fn end_pooled(p: Pooled) {
    if p.parked {
        signal_harness(&p.record, libc::SIGCONT);
    }
    let _ = tokio::time::timeout(END_GRACE, p.child.terminate(END_GRACE)).await;
    end_pooled_host(&p.record).await;
}

/// End a pooled host by nonce proof (when it still runs) and remove its
/// pool-directory files.
async fn end_pooled_host(record: &HostRecord) {
    let dir = pool_dir();
    if agent_host::liveness(&dir, &record.session_id, &record.start_nonce) != Liveness::Dead {
        super::hosts::end_host_blocking(
            dir.clone(),
            record.session_id.clone(),
            Some(record.start_nonce.clone()),
            Some(record.host_pid),
        )
        .await;
    }
    agent_host::remove_artifacts(&dir, record);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;

    fn key(h: &str) -> PoolKey {
        PoolKey {
            origin: Origin::Local,
            cwd: "/w".into(),
            harness: h.into(),
            preset: None,
            args: vec![],
            system_prompt_sha256: None,
            auth: "a".into(),
            account: None,
        }
    }

    /// Lets every task that can run, run.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test]
    async fn an_idle_entry_exits_on_the_fake_clock_and_a_hint_moves_its_deadline() {
        let pool = Arc::new(StdMutex::new(Pool::<&'static str>::new(Duration::from_secs(600))));
        let wake = Arc::new(Notify::new());
        let clock = ManualClock::new();
        let (stop_tx, stop_rx) = oneshot::channel::<()>();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel();
        {
            let mut p = pool.lock().unwrap();
            let g = p.want(Role::Hinted, key("codex"), Duration::ZERO).start.unwrap();
            assert!(p.complete(&key("codex"), g, "codex#1", Duration::ZERO).is_none());
        }
        let (pool2, wake2, clock2) = (pool.clone(), wake.clone(), clock.clone());
        let reaper = tokio::spawn(async move {
            run_reaper(
                &pool2,
                &wake2,
                async {
                    let _ = stop_rx.await;
                },
                || Some(clock2.clone() as Arc<dyn Clock>),
                |v| v.into_iter().for_each(|t| out_tx.send(t).unwrap()),
            )
            .await;
        });
        settle().await;
        clock.advance(Duration::from_secs(599));
        settle().await;
        assert!(out_rx.try_recv().is_err(), "not idle long enough");
        // A hint at 599 s moves the deadline to 1199 s.
        pool.lock().unwrap().want(Role::Hinted, key("codex"), Duration::from_secs(599));
        wake.notify_one();
        settle().await;
        clock.advance(Duration::from_secs(1));
        settle().await;
        assert!(out_rx.try_recv().is_err(), "the hint pushed the deadline");
        clock.advance(Duration::from_secs(599));
        settle().await;
        assert_eq!(out_rx.try_recv().ok(), Some("codex#1"));
        assert!(pool.lock().unwrap().is_empty());
        // The reaper stops when told to (hub.shutdown or stop_pool).
        stop_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(5), reaper).await.unwrap().unwrap();
    }

    fn test_profile() -> HarnessProfile {
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["claude".into()],
            env: Default::default(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        }
    }

    #[tokio::test]
    async fn a_remote_origin_chain_is_never_pooled_or_served() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let refused = hub
            .prewarm(PrewarmRequest {
                harness: Some("claude".into()),
                remote: true,
                ..Default::default()
            })
            .await;
        assert!(refused.is_err(), "a remote-origin hint is refused");
        assert!(hub.pool.pool.lock().unwrap().is_empty());
        let profile = test_profile();
        let mut meta = super::super::lifecycle::draft_meta(super::super::lifecycle::Draft {
            id: String::new(),
            agent: "claude",
            profile: &profile,
            family: "claude",
            preset: None,
            model_request: None,
            cwd: "/w".into(),
            agent_session_id: None,
            policy: None,
            remote: true,
        });
        assert_eq!(hub.pool_claim(&meta, &profile, &Default::default()).await, None);
        meta.remote_origin = false;
        // A memory store runs no agent hosts, so nothing is pooled here either.
        assert_eq!(hub.pool_claim(&meta, &profile, &Default::default()).await, None);
    }

    #[test]
    fn tree_rss_counts_this_process() {
        assert!(tree_rss_bytes(std::process::id()) > 0);
    }
}
