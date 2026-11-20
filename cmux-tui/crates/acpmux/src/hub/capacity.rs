use super::{Hub, Session, now_ms};
use crate::config::{Config, HarnessKind};
use crate::store::SessionMeta;
use serde_json::json;
use std::collections::{BTreeMap, HashMap};
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
        let env = |key: &str| {
            meta.session_env
                .get(key)
                .or_else(|| preset.and_then(|p| p.env.get(key)))
                .or_else(|| profile.env.get(key))
                .or_else(|| defaults.env.get(key))
                .cloned()
        };
        let sr2 = profile.argv.get(1).is_some_and(|word| word == "claude2");
        let base = if sr2 {
            env("SUBROUTER2_BASE_URL")
                .or_else(|| crate::login_env::var("SUBROUTER2_BASE_URL"))
                .unwrap_or_else(|| "http://127.0.0.1:31416".to_owned())
        } else {
            env("ANTHROPIC_BASE_URL").or_else(|| crate::login_env::var("ANTHROPIC_BASE_URL"))?
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
                env("SUBROUTER2_PROXY_TOKEN")
                    .or_else(|| crate::login_env::var("SUBROUTER2_PROXY_TOKEN"))
                    .unwrap_or_else(|| "subrouter2".to_owned()),
            )
        } else {
            env("ANTHROPIC_AUTH_TOKEN")
        };
        let api_key = if sr2 { None } else { env("ANTHROPIC_API_KEY") };
        Some(Self { url, bearer, api_key })
    }

    async fn probe(&self) -> Result<(), u64> {
        let fallback = || now_ms().saturating_add(DEFAULT_RETRY_MS);
        let client = reqwest::Client::builder()
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
        let response = request.send().await.map_err(|_| fallback())?;
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
pub(super) struct Gates(Mutex<HashMap<reqwest::Url, Arc<Gate>>>);

impl Gates {
    pub(super) fn get(&self, route: Option<&Route>) -> Option<Arc<Gate>> {
        self.0.lock().unwrap_or_else(|err| err.into_inner()).get(&route?.url).cloned()
    }
}

pub(super) struct Gate {
    state: Mutex<State>,
    changed: Notify,
}

struct State {
    phase: Phase,
    next_id: u64,
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

pub(super) struct Ticket {
    gate: Arc<Gate>,
    key: (bool, u64),
    pub(super) ready: Arc<Notify>,
}

impl Ticket {
    pub(super) fn take(&self, interval: Duration) -> bool {
        let mut state = self.gate.state();
        match state.phase {
            Phase::Open => return true,
            Phase::Closed(_) => return false,
            Phase::Releasing(next)
                if Instant::now() < next || state.waiters.keys().next() != Some(&self.key) =>
            {
                return false;
            }
            Phase::Releasing(_) => {}
        }
        state.waiters.remove(&self.key);
        state.phase = Phase::Releasing(Instant::now() + interval);
        self.gate.changed.notify_one();
        true
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

    pub(super) fn capacity_close(self: &Arc<Self>, route: Route, retry_at: Option<u64>) {
        let deadline = retry_at.unwrap_or_else(|| now_ms() + DEFAULT_RETRY_MS);
        let mut gates = self.capacity.0.lock().unwrap_or_else(|err| err.into_inner());
        if let Some(gate) = gates.get(&route.url) {
            let mut state = gate.state();
            match &mut state.phase {
                Phase::Closed(until) => *until = (*until).max(deadline),
                _ => state.phase = Phase::Closed(deadline),
            }
            gate.changed.notify_one();
            return;
        }
        let gate = Arc::new(Gate::new(deadline));
        gates.insert(route.url.clone(), gate.clone());
        drop(gates);
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
                            None => Action::Finish,
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
                        let mut state = gate.state();
                        if matches!(state.phase, Phase::Closed(at) if at == probed_at) {
                            state.phase = match result {
                                Ok(()) => Phase::Releasing(Instant::now()),
                                Err(at) => Phase::Closed(at),
                            };
                        }
                    }
                    Action::Finish => {
                        let Some(hub) = hub.upgrade() else { return };
                        let mut gates =
                            hub.capacity.0.lock().unwrap_or_else(|err| err.into_inner());
                        let mut state = gate.state();
                        if matches!(state.phase, Phase::Releasing(_)) && state.waiters.is_empty() {
                            state.phase = Phase::Open;
                            gates.remove(&route.url);
                            return;
                        }
                    }
                }
            }
        });
    }
}

pub(super) fn priority(session: &Session) -> bool {
    let meta = session.meta();
    let name = meta.name.rsplit('/').next().unwrap_or_default().to_ascii_lowercase();
    let tag = |key: &str| {
        meta.tags
            .get(key)
            .filter(|tag| tag.expires_at.is_none_or(|expires| expires > now_ms()))
            .map(|tag| tag.value.as_str())
    };
    name.starts_with("ask-")
        || name.starts_with("dep-")
        || name.starts_with("desktop-")
        || name.split(['-', '_']).any(|part| matches!(part, "coord" | "coordinator"))
        || tag("priority") == Some("1")
        || tag("ask-trace").is_some_and(|value| !value.is_empty())
        || tag("Leo-Ask-Trace").is_some_and(|value| !value.is_empty())
}
