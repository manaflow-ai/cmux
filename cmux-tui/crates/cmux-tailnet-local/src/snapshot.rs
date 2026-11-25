//! A cached view for hot paths. `snapshot()` returns the last view at once
//! and, when it is older than `min_interval`, asks a background thread to
//! read tailscaled again. A race never waits on tailscaled: the first call
//! before any read returns `None` (no hint), the next ones see the view.

use std::net::IpAddr;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::model::{PeerPath, TailnetView};
use crate::{Error, Limits};

/// Reads one view; `previous` lets it skip unchanged prefs and profile.
pub type Fetcher = Arc<dyn Fn(Option<&TailnetView>) -> Result<TailnetView, Error> + Send + Sync>;

#[derive(Clone, Debug)]
pub struct SnapshotConfig {
    /// A view younger than this is served without asking for a refresh.
    pub min_interval: Duration,
    /// After a failed read, wait this long before the next try.
    pub retry_after_error: Duration,
    /// A view older than this (tailscaled stopped answering) is no longer
    /// served: an old path is worse than no hint.
    pub max_age: Duration,
    pub limits: Limits,
}

impl Default for SnapshotConfig {
    fn default() -> Self {
        Self {
            min_interval: Duration::from_secs(5),
            retry_after_error: Duration::from_secs(15),
            max_age: Duration::from_secs(60),
            limits: Limits::default(),
        }
    }
}

#[derive(Default)]
struct State {
    view: Option<Arc<TailnetView>>,
    fetched_at: Option<Instant>,
    last_attempt: Option<Instant>,
    last_error: Option<Error>,
    wanted: bool,
    in_flight: bool,
    worker: bool,
    shutdown: bool,
    generation: u64,
}

struct Shared {
    state: Mutex<State>,
    wake: Condvar,
    done: Condvar,
    config: SnapshotConfig,
    fetch: Fetcher,
}

pub struct TailnetLocal {
    shared: Arc<Shared>,
}

impl TailnetLocal {
    /// Reads the system tailscaled (LocalAPI, else the CLI).
    pub fn new(config: SnapshotConfig) -> Self {
        let limits = config.limits.clone();
        let fetch: Fetcher =
            Arc::new(move |prev| crate::fetch_view_with(&limits, prev).map(|(v, _)| v));
        Self::with_fetcher(config, fetch)
    }

    pub fn with_fetcher(config: SnapshotConfig, fetch: Fetcher) -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::new(State::default()),
                wake: Condvar::new(),
                done: Condvar::new(),
                config,
                fetch,
            }),
        }
    }

    /// One process-wide instance with the default config.
    pub fn global() -> &'static TailnetLocal {
        static GLOBAL: OnceLock<TailnetLocal> = OnceLock::new();
        GLOBAL.get_or_init(|| TailnetLocal::new(SnapshotConfig::default()))
    }

    /// The last view, without waiting. Asks for a background refresh when
    /// the view is stale (and the last failure is not too recent).
    pub fn snapshot(&self) -> Option<Arc<TailnetView>> {
        let mut st = self.lock();
        let now = Instant::now();
        let fresh =
            st.fetched_at.is_some_and(|t| now.duration_since(t) < self.shared.config.min_interval);
        let backing_off = st.last_error.is_some()
            && st
                .last_attempt
                .is_some_and(|t| now.duration_since(t) < self.shared.config.retry_after_error);
        if !fresh && !backing_off {
            self.request(&mut st);
        }
        let current =
            st.fetched_at.is_some_and(|t| now.duration_since(t) < self.shared.config.max_age);
        if current { st.view.clone() } else { None }
    }

    /// How a connection to `ip` would travel now, from the cached view.
    pub fn path_hint(&self, ip: IpAddr) -> Option<PeerPath> {
        self.snapshot()?.path_hint(ip)
    }

    /// Asks for a refresh now (a route or network change), without waiting.
    pub fn refresh(&self) {
        let mut st = self.lock();
        self.request(&mut st);
    }

    /// Refreshes and waits up to `wait` for the result: for CLI commands and
    /// tests, never for a race.
    pub fn refresh_blocking(&self, wait: Duration) -> Result<Arc<TailnetView>, Error> {
        let now = Instant::now();
        let deadline = now.checked_add(wait).unwrap_or(now);
        let mut st = self.lock();
        let target = st.generation.saturating_add(if st.in_flight { 2 } else { 1 });
        self.request(&mut st);
        while st.generation < target {
            let left = deadline.checked_duration_since(Instant::now()).ok_or(Error::Timeout)?;
            st = self.shared.done.wait_timeout(st, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        match (&st.last_error, &st.view) {
            (None, Some(v)) => Ok(v.clone()),
            (Some(e), _) => Err(e.clone()),
            (None, None) => Err(Error::Unavailable("no view")),
        }
    }

    /// The last read's error, if it failed.
    pub fn last_error(&self) -> Option<Error> {
        self.lock().last_error.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn request(&self, st: &mut State) {
        st.wanted = true;
        if !st.worker {
            st.worker = true;
            let shared = self.shared.clone();
            let spawned = std::thread::Builder::new()
                .name("tailnet-local".into())
                .spawn(move || worker(shared));
            if spawned.is_err() {
                st.worker = false;
                return;
            }
        }
        self.shared.wake.notify_one();
    }
}

impl Drop for TailnetLocal {
    fn drop(&mut self) {
        self.lock().shutdown = true;
        self.shared.wake.notify_all();
    }
}

fn worker(shared: Arc<Shared>) {
    loop {
        let previous = {
            let mut st = shared.state.lock().unwrap_or_else(|e| e.into_inner());
            while !st.wanted && !st.shutdown {
                st = shared.wake.wait(st).unwrap_or_else(|e| e.into_inner());
            }
            if st.shutdown {
                return;
            }
            st.wanted = false;
            st.in_flight = true;
            st.view.clone()
        };
        let result = (shared.fetch)(previous.as_deref());
        let mut st = shared.state.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        st.last_attempt = Some(now);
        match result {
            Ok(view) => {
                st.view = Some(Arc::new(view));
                st.fetched_at = Some(now);
                st.last_error = None;
            }
            // Keep the last good view: a stale hint beats none, and a peer's
            // path changes slowly next to a 5 s refresh.
            Err(e) => st.last_error = Some(e),
        }
        st.in_flight = false;
        st.generation = st.generation.saturating_add(1);
        shared.done.notify_all();
    }
}
