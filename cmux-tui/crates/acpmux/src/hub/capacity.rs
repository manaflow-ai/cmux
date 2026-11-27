use super::{Hub, Session, now_ms};
use crate::config::{Config, HarnessKind};
use crate::store::SessionMeta;
use serde_json::json;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::Instant;

const DEFAULT_RETRY_MS: u64 = 60_000;
const PROBE_TIMEOUT: Duration = Duration::from_secs(15);

pub(super) fn exhausted(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    error.contains("503") && error.contains("no non-exhausted claude accounts")
}

#[derive(Clone)]
pub(super) struct Route {
    url: reqwest::Url,
    bearer: Option<String>,
    api_key: Option<String>,
}

impl Route {
    pub(super) fn of(config: &Config, meta: &SessionMeta) -> Option<Self> {
        let profile = config.profile(&meta.harness)?;
        if profile.kind != HarnessKind::ClaudeStdio {
            return None;
        }
        let defaults = config.defaults_for(&meta.harness);
        let preset = meta.preset.as_ref().and_then(|name| config.presets.get(name));
        let mut configured = profile.env.clone();
        for (key, value) in &defaults.env {
            configured.entry(key.clone()).or_insert_with(|| value.clone());
        }
        if let Some(preset) = preset {
            configured.extend(preset.env.clone());
        }
        let home = dirs::home_dir().unwrap_or_default();
        let model = meta.model_request.clone().unwrap_or_default();
        for value in configured.values_mut() {
            *value = crate::config::expand_env_value(value, &meta.cwd, &home, &model);
        }
        meta.apply_chat_store(&mut configured);
        configured.extend(meta.session_env.clone());
        let mut spawn = profile.clone();
        spawn.env = configured;
        let resolved = crate::agent::resolved_profile_env(&spawn).ok()?;
        let effective = crate::login_env::effective_for(Some("claude"), &resolved);
        Self::from_env(&profile.argv, &effective)
    }

    fn from_env(argv: &[String], env: &BTreeMap<String, String>) -> Option<Self> {
        // Fleet profiles can put the coordinator wrapper and its options before sr2.
        let sr2 = argv.windows(2).any(|pair| {
            let [program, subcommand] = pair else { return false };
            subcommand == "claude2"
                && Path::new(program).file_name().is_some_and(|name| name == "sr2" || name == "sr")
        });
        let base = if sr2 {
            env.get("SUBROUTER2_BASE_URL")
                .cloned()
                .or_else(|| crate::login_env::var("SUBROUTER2_BASE_URL"))
                .unwrap_or_else(|| "http://127.0.0.1:31416".to_owned())
        } else {
            env.get("ANTHROPIC_BASE_URL")
                .cloned()
                .or_else(|| crate::login_env::var("ANTHROPIC_BASE_URL"))?
        };
        let mut url = reqwest::Url::parse(base.trim()).ok()?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return None;
        }
        let path = url.path().trim_end_matches('/');
        let path = path.strip_suffix("/v1").unwrap_or(path);
        url.set_path(&format!("{path}/v1/messages"));
        let bearer = if sr2 {
            Some(
                env.get("SUBROUTER2_PROXY_TOKEN")
                    .cloned()
                    .or_else(|| crate::login_env::var("SUBROUTER2_PROXY_TOKEN"))
                    .unwrap_or_else(|| "subrouter2".to_owned()),
            )
        } else {
            env.get("ANTHROPIC_AUTH_TOKEN").cloned()
        };
        let api_key = if sr2 { None } else { env.get("ANTHROPIC_API_KEY").cloned() };
        Some(Self { url, bearer, api_key })
    }

    async fn probe(&self) -> Result<(), u64> {
        let fallback = || now_ms().saturating_add(DEFAULT_RETRY_MS);
        // The person set this gateway (ANTHROPIC_BASE_URL or SUBROUTER2_BASE_URL): the gate lets it through
        // (docs/privacy.md "hosts you name").
        cmux_egress::allow_named(self.url.as_str());
        let client = cmux_egress::client_builder("acpmux::capacity_probe")
            .redirect(reqwest::redirect::Policy::none())
            .timeout(PROBE_TIMEOUT)
            .build()
            .map_err(|_| fallback())?;
        let mut request = client
            .post(self.url.clone())
            .header("anthropic-version", "2023-06-01")
            .header("x-subrouter-agent", "claude")
            .json(&json!({
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "messages": [{"role": "user", "content": "OK"}]
            }));
        if let Some(bearer) = &self.bearer {
            request = request.bearer_auth(bearer);
        }
        if let Some(key) = &self.api_key {
            request = request.header("x-api-key", key);
        }
        let mut response = request.send().await.map_err(|_| fallback())?;
        if response.status().is_success() {
            return Ok(());
        }
        let header = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| retry_at(&format!("retry-after: {value}"), now_ms()));
        let body = response.chunk().await.ok().flatten();
        let hint = body
            .as_deref()
            .and_then(|bytes| std::str::from_utf8(bytes).ok())
            .and_then(|text| retry_at(text, now_ms()));
        Err(header.max(hint).unwrap_or_else(fallback))
    }
}

pub(super) fn retry_at(error: &str, at: u64) -> Option<u64> {
    super::auto_resume::reset_hint::reset_at(error, None, at)
}

pub(super) fn release_interval(rate: std::num::NonZeroU16) -> Duration {
    Duration::from_micros(60_000_000_u64.div_ceil(u64::from(rate.get())))
}

#[derive(Default)]
pub(crate) struct Gates {
    by_url: Mutex<HashMap<reqwest::Url, Arc<Gate>>>,
    path: Option<PathBuf>,
    pub(super) changed: Notify,
}

impl Gates {
    pub(super) fn open(home: Option<&Path>) -> Self {
        let path = home.map(|home| home.join("claude-capacity.json"));
        let deadlines = path.as_ref().and_then(|path| {
            let bytes = std::fs::read(path).ok()?;
            serde_json::from_slice::<BTreeMap<String, u64>>(&bytes).ok()
        });
        let by_url = deadlines
            .into_iter()
            .flatten()
            .filter_map(|(url, at)| {
                Some((reqwest::Url::parse(&url).ok()?, Arc::new(Gate::new(at))))
            })
            .collect();
        Self { path, by_url: Mutex::new(by_url), changed: Notify::new() }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<reqwest::Url, Arc<Gate>>> {
        self.by_url.lock().unwrap_or_else(|err| err.into_inner())
    }

    // Called under the map lock, after releasing the individual gate lock.
    fn save(&self, gates: &HashMap<reqwest::Url, Arc<Gate>>) {
        let Some(path) = &self.path else { return };
        let deadlines: BTreeMap<_, _> = gates
            .iter()
            .filter_map(|(url, gate)| {
                let at = match gate.state().phase {
                    Phase::Closed(at) => at,
                    Phase::Releasing(_) => now_ms(),
                    Phase::Open => return None,
                };
                Some((url.as_str(), at))
            })
            .collect();
        let result = serde_json::to_vec(&deadlines)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| crate::config::write_atomic(path, &bytes));
        if let Err(error) = result {
            tracing::warn!(%error, "could not save Claude capacity gate deadlines");
        }
    }
}

impl Gates {
    pub(super) fn get(&self, route: Option<&Route>) -> Option<Arc<Gate>> {
        self.lock().get(&route?.url).cloned()
    }
}

pub(super) struct Gate {
    state: Mutex<State>,
    changed: Notify,
}

struct State {
    phase: Phase,
    next_id: u64,
    generation: u64,
    worker_started: bool,
    backlog: usize,
    waiters: BTreeMap<(bool, u64), Arc<Notify>>,
}

enum Phase {
    Closed(u64),
    Releasing(Instant),
    Open,
}

impl Gate {
    fn new(deadline: u64) -> Self {
        Self {
            state: Mutex::new(State {
                phase: Phase::Closed(deadline),
                next_id: 0,
                generation: 0,
                worker_started: false,
                backlog: 0,
                waiters: BTreeMap::new(),
            }),
            changed: Notify::new(),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|err| err.into_inner())
    }

    pub(super) fn waiting(&self) -> bool {
        !matches!(self.state().phase, Phase::Open)
    }

    /// Whether a turn may start now: the gate is open, or it is pacing and `permit` is this
    /// gate's paced slot for the current generation (`wait_retry_capacity`).
    fn admits(&self, state: &State, permit: Option<&Permit>) -> bool {
        match state.phase {
            Phase::Open => true,
            Phase::Closed(_) => false,
            Phase::Releasing(_) => permit.is_some_and(|permit| {
                std::ptr::eq(self, Arc::as_ptr(&permit.gate))
                    && state.generation == permit.generation
            }),
        }
    }

    /// Hold the gate state while a caller commits a turn claim. A capacity close that races the
    /// final admission check then waits until the claim is visible, so it cannot let one more turn
    /// start after the gateway reported exhaustion. A cut-turn retry's paced `permit` admits it
    /// while the gate releases, as [`Hub::capacity_waits_unless_permitted`] does.
    pub(super) fn admit(&self, permit: Option<&Permit>) -> Option<GateAdmission<'_>> {
        let state = self.state();
        self.admits(&state, permit).then_some(GateAdmission { _state: state })
    }

    pub(super) fn watch_backlog(self: &Arc<Self>) -> Option<Backlog> {
        let mut state = self.state();
        if matches!(state.phase, Phase::Open) {
            return None;
        }
        state.backlog += 1;
        Some(Backlog(self.clone()))
    }

    pub(super) fn join(self: &Arc<Self>, priority: bool) -> Ticket {
        let mut state = self.state();
        let key = (!priority, state.next_id);
        state.next_id += 1;
        let ready = Arc::new(Notify::new());
        state.waiters.insert(key, ready.clone());
        self.changed.notify_one();
        Ticket { gate: self.clone(), key, ready }
    }
}

pub(super) struct GateAdmission<'a> {
    _state: std::sync::MutexGuard<'a, State>,
}

pub(super) struct Backlog(Arc<Gate>);

impl Drop for Backlog {
    fn drop(&mut self) {
        let mut state = self.0.state();
        state.backlog -= 1;
        if state.backlog == 0 {
            self.0.changed.notify_one();
        }
    }
}

pub(super) struct Ticket {
    gate: Arc<Gate>,
    key: (bool, u64),
    pub(super) ready: Arc<Notify>,
}

pub(super) struct Permit {
    gate: Arc<Gate>,
    generation: u64,
}

impl Ticket {
    pub(super) fn belongs_to(&self, gate: &Arc<Gate>) -> bool {
        Arc::ptr_eq(&self.gate, gate)
    }

    fn permit(&self, interval: Duration) -> Option<Permit> {
        self.take(interval).map(|generation| Permit { gate: self.gate.clone(), generation })
    }

    pub(super) fn take(&self, interval: Duration) -> Option<u64> {
        let mut state = self.gate.state();
        match state.phase {
            Phase::Open => return Some(state.generation),
            Phase::Closed(_) => return None,
            Phase::Releasing(next)
                if Instant::now() < next || state.waiters.keys().next() != Some(&self.key) =>
            {
                return None;
            }
            Phase::Releasing(_) => {}
        }
        state.waiters.remove(&self.key);
        state.phase = Phase::Releasing(Instant::now() + interval);
        self.gate.changed.notify_one();
        Some(state.generation)
    }
}

impl Drop for Ticket {
    fn drop(&mut self) {
        if self.gate.state().waiters.remove(&self.key).is_some() {
            self.gate.changed.notify_one();
        }
    }
}

impl Hub {
    pub(super) fn capacity_waits(&self, route: Option<&Route>) -> bool {
        self.capacity.get(route).is_some_and(|gate| gate.waiting())
    }

    pub(super) fn capacity_waits_unless_permitted(
        &self,
        route: Option<&Route>,
        permit: Option<&Permit>,
    ) -> bool {
        self.capacity.get(route).is_some_and(|gate| !gate.admits(&gate.state(), permit))
    }

    pub(super) async fn wait_retry_capacity(
        &self,
        session: &Session,
        cut: &str,
        route: Option<&Route>,
        interval: Duration,
    ) -> Result<Option<Permit>, crate::rpc::RpcError> {
        let mut ticket = None::<Ticket>;
        while let Some(gate) = self.capacity.get(route) {
            let moved = session.queue_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            super::auto_resume::check_capacity_cut(session, cut)?;
            if !gate.waiting() {
                return Ok(None);
            }
            if ticket.as_ref().is_some_and(|ticket| !ticket.belongs_to(&gate)) {
                ticket.take();
            }
            let ticket = ticket.get_or_insert_with(|| gate.join(priority(session, None)));
            if let Some(permit) = ticket.permit(interval) {
                return Ok(Some(permit));
            }
            tokio::select! {
                () = ticket.ready.notified() => {}
                () = moved => {}
            }
        }
        Ok(None)
    }

    pub(super) fn capacity_wait_count(
        &self,
        session: &Session,
        meta: &SessionMeta,
        retry: bool,
    ) -> u64 {
        if !self.capacity.lock().values().any(|gate| gate.waiting()) {
            return 0;
        }
        let Ok(config) = self.config.try_read() else { return 0 };
        let route = Route::of(&config, meta);
        if !self.capacity_waits(route.as_ref()) {
            return 0;
        }
        session.queue().iter().filter(|prompt| !prompt.aside()).count() as u64 + u64::from(retry)
    }

    pub(super) fn capacity_close(self: &Arc<Self>, route: Route, retry_at: Option<u64>) {
        let deadline = retry_at.unwrap_or_else(|| now_ms().saturating_add(DEFAULT_RETRY_MS));
        let mut gates = self.capacity.lock();
        let new = !gates.contains_key(&route.url);
        let gate =
            gates.entry(route.url.clone()).or_insert_with(|| Arc::new(Gate::new(deadline))).clone();
        let (closing, changed) = {
            let mut state = gate.state();
            match &mut state.phase {
                Phase::Closed(until) if deadline > *until => {
                    *until = deadline;
                    (false, true)
                }
                Phase::Closed(_) => (new, new),
                _ => {
                    state.generation += 1;
                    state.phase = Phase::Closed(deadline);
                    (true, true)
                }
            }
        };
        if changed {
            self.capacity.save(&gates);
        }
        drop(gates);
        if closing {
            tracing::info!(
                retry_at_ms = deadline,
                "Claude gateway capacity exhausted; holding turns"
            );
            self.capacity.changed.notify_waiters();
        }
        if changed {
            gate.changed.notify_one();
        }
        self.capacity_worker(route, gate);
    }

    pub(super) async fn retry_waits_for_capacity(
        self: &Arc<Self>,
        session: &Session,
        error: &str,
    ) -> bool {
        if !exhausted(error) {
            return false;
        }
        let route = Route::of(&*self.config.read().await, &session.meta());
        self.capacity_activate(route.as_ref());
        self.capacity_waits(route.as_ref())
    }

    pub(super) async fn restore_capacity_retry(
        self: &Arc<Self>,
        session: &Session,
        error: &str,
        failed_at: u64,
        not_before: Option<u64>,
    ) {
        let route = Route::of(&*self.config.read().await, &session.meta());
        let until = retry_at(error, failed_at)
            .max(not_before)
            .unwrap_or_else(|| failed_at.saturating_add(DEFAULT_RETRY_MS));
        if let Some(route) = route
            && self.capacity.get(Some(&route)).is_none()
        {
            self.capacity_close(route, Some(until));
        }
    }

    pub(super) fn capacity_activate(self: &Arc<Self>, route: Option<&Route>) {
        if let Some(gate) = self.capacity.get(route)
            && let Some(route) = route
        {
            self.capacity_worker(route.clone(), gate);
        }
    }

    fn capacity_worker(self: &Arc<Self>, route: Route, gate: Arc<Gate>) {
        {
            let mut state = gate.state();
            if state.worker_started || matches!(state.phase, Phase::Open) {
                return;
            }
            state.worker_started = true;
        }
        let hub = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("gateway-capacity", async move {
            enum Action {
                Wait(Option<Duration>),
                Probe(u64),
                Finish,
            }
            loop {
                let action = {
                    let state = gate.state();
                    match state.phase {
                        Phase::Closed(at) if at <= now_ms() => Action::Probe(at),
                        Phase::Closed(at) => {
                            Action::Wait(Some(Duration::from_millis(at.saturating_sub(now_ms()))))
                        }
                        Phase::Releasing(at) if at > Instant::now() => {
                            Action::Wait(Some(at.saturating_duration_since(Instant::now())))
                        }
                        Phase::Releasing(_) => match state.waiters.values().next() {
                            Some(ready) => {
                                ready.notify_one();
                                Action::Wait(None)
                            }
                            None if state.backlog == 0 => Action::Finish,
                            None => Action::Wait(None),
                        },
                        Phase::Open => return,
                    }
                };
                match action {
                    Action::Wait(Some(delay)) => {
                        tokio::select! {
                            () = tokio::time::sleep(delay) => {}
                            () = gate.changed.notified() => {}
                        }
                    }
                    Action::Wait(None) => gate.changed.notified().await,
                    Action::Probe(probed_at) => {
                        if hub.upgrade().is_none_or(|hub| hub.shutting_down()) {
                            return;
                        }
                        let result = route.probe().await;
                        let Some(hub) = hub.upgrade() else { return };
                        let gates = hub.capacity.lock();
                        {
                            let mut state = gate.state();
                            if !matches!(state.phase, Phase::Closed(at) if at == probed_at) {
                                continue;
                            }
                            state.phase = match result {
                                Ok(()) => {
                                    tracing::info!(
                                        "Claude gateway capacity returned; pacing queued turns"
                                    );
                                    Phase::Releasing(Instant::now())
                                }
                                Err(at) => Phase::Closed(at),
                            };
                        }
                        hub.capacity.save(&gates);
                    }
                    Action::Finish => {
                        let Some(hub) = hub.upgrade() else { return };
                        let gates = hub.capacity.lock();
                        let mut state = gate.state();
                        if matches!(state.phase, Phase::Releasing(_))
                            && state.waiters.is_empty()
                            && state.backlog == 0
                        {
                            state.phase = Phase::Open;
                            state.worker_started = false;
                            drop(state);
                            hub.capacity.save(&gates);
                            return;
                        }
                    }
                }
            }
        });
    }
}

pub(super) fn priority(session: &Session, prompt: Option<&str>) -> bool {
    let meta = session.meta.lock().unwrap_or_else(|err| err.into_inner());
    let name = meta.name.rsplit('/').next().unwrap_or_default().to_ascii_lowercase();
    let tag = |key: &str| {
        meta.tags
            .get(key)
            .filter(|tag| tag.expires_at.is_none_or(|expires| expires > now_ms()))
            .map(|tag| tag.value.as_str())
    };
    let trace = prompt.is_some_and(|text| {
        text.lines().any(|line| {
            line.trim_start()
                .strip_prefix("Leo-Ask-Trace:")
                .is_some_and(|id| id.trim_start().starts_with("ask-"))
        })
    });
    trace
        || name.starts_with("ask-")
        || name.starts_with("dep-")
        || name.starts_with("desktop-")
        || name.split(['-', '_']).any(|part| matches!(part, "coord" | "coordinator"))
        || tag("cmux.chief.role") == Some("coordinator")
        || tag("priority") == Some("1")
        || tag("ask-trace").is_some_and(|value| !value.is_empty())
        || tag("Leo-Ask-Trace").is_some_and(|value| !value.is_empty())
}

#[cfg(test)]
mod capacity_gate_tests {
    use super::*;

    #[test]
    fn capacity_gate_paces_priority_and_skips_cancelled_waiters() {
        let gate = Arc::new(Gate::new(10));
        let ordinary = gate.join(false);
        let cancelled = gate.join(true);
        let urgent = gate.join(true);
        let interval = release_interval(std::num::NonZeroU16::new(5).unwrap());
        assert_eq!(interval, Duration::from_secs(12));
        assert!(urgent.take(interval).is_none());
        assert!(ordinary.take(interval).is_none());
        drop(cancelled);
        gate.state().phase = Phase::Releasing(Instant::now());
        assert!(ordinary.take(interval).is_none());
        assert!(urgent.take(interval).is_some());
        assert!(ordinary.take(interval).is_none());
        gate.state().phase = Phase::Releasing(Instant::now());
        assert!(ordinary.take(interval).is_some());
        let backlog = gate.watch_backlog().unwrap();
        assert_eq!(gate.state().backlog, 1);
        drop(backlog);
        assert_eq!(gate.state().backlog, 0);
    }

    #[test]
    fn capacity_gate_admission_holds_state_until_claim() {
        let gate = Arc::new(Gate::new(10));
        gate.state().phase = Phase::Open;
        let admission = gate.admit(None).expect("open gate admits");
        assert!(gate.state.try_lock().is_err());
        drop(admission);
        assert!(gate.state.try_lock().is_ok());
        gate.state().phase = Phase::Closed(20);
        assert!(gate.admit(None).is_none());
    }

    /// Review F1 on #47897: a cut-turn retry's paced permit admits it while the gate releases;
    /// a permit of an older generation (the gate closed again since) or of another gate does not.
    #[test]
    fn capacity_gate_admission_honours_retry_permit() {
        let gate = Arc::new(Gate::new(10));
        let other = Arc::new(Gate::new(10));
        gate.state().phase = Phase::Releasing(Instant::now());
        let generation = gate.state().generation;
        let permit = Permit { gate: Arc::clone(&gate), generation };
        assert!(gate.admit(None).is_none(), "pacing admits no unpermitted turn");
        assert!(gate.admit(Some(&permit)).is_some(), "the paced permit admits its retry");
        let foreign = Permit { gate: Arc::clone(&other), generation };
        assert!(gate.admit(Some(&foreign)).is_none(), "another gate's permit does not");
        gate.state().generation += 1;
        assert!(gate.admit(Some(&permit)).is_none(), "a stale generation does not");
        gate.state().phase = Phase::Closed(20);
        assert!(gate.admit(Some(&permit)).is_none(), "a closed gate admits nothing");
    }

    #[test]
    fn capacity_gate_recognizes_only_gateway_exhaustion() {
        let error = "API Error: 503 no non-exhausted claude accounts; retry-after: 2400";
        assert!(exhausted(error));
        assert_eq!(retry_at(error, 1000), Some(2_401_000));
        assert!(!exhausted("API Error: 503 service unavailable"));
        assert!(!exhausted("API Error: 400 no non-exhausted claude accounts"));
    }

    #[tokio::test]
    async fn capacity_gate_probe_uses_gateway_auth_and_retry_after() {
        use axum::extract::State;
        use axum::http::{HeaderMap, StatusCode};
        use axum::response::IntoResponse;
        use std::sync::atomic::{AtomicBool, Ordering};

        let exhausted = Arc::new(AtomicBool::new(true));
        let app = axum::Router::new()
            .route(
                "/v1/messages",
                axum::routing::post(
                    async |State(exhausted): State<Arc<AtomicBool>>, headers: HeaderMap| {
                        if headers.get("authorization").and_then(|value| value.to_str().ok())
                            != Some("Bearer probe-token")
                        {
                            return StatusCode::UNAUTHORIZED.into_response();
                        }
                        if exhausted.load(Ordering::Relaxed) {
                            (StatusCode::SERVICE_UNAVAILABLE, [("retry-after", "2400")])
                                .into_response()
                        } else {
                            StatusCode::OK.into_response()
                        }
                    },
                ),
            )
            .with_state(exhausted.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v1/messages", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let route = Route {
            url: reqwest::Url::parse(&url).unwrap(),
            bearer: Some("probe-token".to_owned()),
            api_key: None,
        };

        let earliest = now_ms() + 2_400_000;
        let deadline = route.probe().await.unwrap_err();
        assert!((earliest..=now_ms() + 2_400_000).contains(&deadline));
        exhausted.store(false, Ordering::Relaxed);
        assert_eq!(route.probe().await, Ok(()));
        server.abort();
    }

    #[test]
    fn capacity_gate_restores_the_same_gateway_and_deadline() {
        let home = tempfile::tempdir().unwrap();
        let route = Route {
            url: reqwest::Url::parse("http://127.0.0.1:4016/v1/messages").unwrap(),
            bearer: Some("synthetic-probe-credential".to_owned()),
            api_key: None,
        };
        let other = Route {
            url: reqwest::Url::parse("http://127.0.0.2:4016/v1/messages").unwrap(),
            ..route.clone()
        };
        let gates = Gates::open(Some(home.path()));
        let at = now_ms() + 2_400_000;
        {
            let mut map = gates.lock();
            map.insert(route.url.clone(), Arc::new(Gate::new(at)));
            gates.save(&map);
        }
        let restored = Gates::open(Some(home.path()));
        let gate = restored.get(Some(&route)).unwrap();
        assert!(matches!(gate.state().phase, Phase::Closed(deadline) if deadline == at));
        assert!(restored.get(Some(&other)).is_none());
        let file = std::fs::read_to_string(restored.path.as_ref().unwrap()).unwrap();
        assert!(!file.contains("synthetic-probe-credential"));
    }

    #[test]
    fn capacity_route_uses_the_same_gateway_for_direct_and_wrapped_sr2() {
        let env = BTreeMap::from([
            ("SUBROUTER2_BASE_URL".to_owned(), "https://gateway.test".to_owned()),
            ("SUBROUTER2_PROXY_TOKEN".to_owned(), "proxy-token".to_owned()),
            ("ANTHROPIC_BASE_URL".to_owned(), "https://other.test".to_owned()),
        ]);
        let direct = ["sr2", "claude2"].map(str::to_owned);
        let wrapped = [
            "/home/test/.local/bin/claude-coord-cap",
            "600000",
            "",
            "/home/test/bin/sr2",
            "claude2",
            "--autocompact",
            "100000",
        ]
        .map(str::to_owned);
        let direct = Route::from_env(&direct, &env).unwrap();
        let wrapped = Route::from_env(&wrapped, &env).unwrap();
        assert_eq!(wrapped.url, direct.url);
        assert_eq!(wrapped.url.as_str(), "https://gateway.test/v1/messages");
        assert_eq!(wrapped.bearer.as_deref(), Some("proxy-token"));
    }

    #[test]
    fn capacity_route_uses_inherited_anthropic_credentials() {
        let env = BTreeMap::from([
            ("ANTHROPIC_BASE_URL".to_owned(), "https://gateway.test".to_owned()),
            ("ANTHROPIC_API_KEY".to_owned(), "inherited-key".to_owned()),
        ]);
        let route = Route::from_env(&[], &env).unwrap();
        assert_eq!(route.api_key.as_deref(), Some("inherited-key"));
    }

    #[test]
    fn capacity_route_uses_an_env_referenced_credential() {
        let mut env = BTreeMap::from([
            ("ANTHROPIC_BASE_URL".to_owned(), "https://gateway.test".to_owned()),
            ("ANTHROPIC_AUTH_TOKEN".to_owned(), "${env:CAPACITY_PROBE_TOKEN}".to_owned()),
        ]);
        crate::config::profiles::resolve_env_refs(
            &mut env,
            &|key| (key == "CAPACITY_PROBE_TOKEN").then(|| "referenced-token".to_owned()),
            &|_, _| Err("unexpected keychain lookup".to_owned()),
        )
        .unwrap();
        let route = Route::from_env(&[], &env).unwrap();
        assert_eq!(route.bearer.as_deref(), Some("referenced-token"));
    }

    #[cfg(unix)]
    #[test]
    fn capacity_route_uses_a_file_referenced_credential() {
        use std::os::unix::fs::PermissionsExt;

        let home = tempfile::tempdir().unwrap();
        let secret = home.path().join("probe-token");
        std::fs::write(&secret, "file-token\n").unwrap();
        std::fs::set_permissions(&secret, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut env = BTreeMap::from([
            ("ANTHROPIC_BASE_URL".to_owned(), "https://gateway.test".to_owned()),
            ("ANTHROPIC_API_KEY".to_owned(), format!("${{file:{}}}", secret.display())),
        ]);
        crate::config::profiles::resolve_env_refs(&mut env, &|_| None, &|_, _| {
            Err("unexpected keychain lookup".to_owned())
        })
        .unwrap();
        let route = Route::from_env(&[], &env).unwrap();
        assert_eq!(route.api_key.as_deref(), Some("file-token"));
    }
}
