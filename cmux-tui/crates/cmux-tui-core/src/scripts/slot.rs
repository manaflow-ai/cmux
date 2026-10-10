//! The script sessions of one daemon, by control connection.
//!
//! Every request that starts or runs a cell is in `running` from before its
//! host starts until it answers, so `cancel-request` and a closed connection
//! reach it in every state: a start that finishes after its connection closed
//! or its cancel arrived ends the new session at once.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_app_host::script::{LogSink, ScriptError, Session, codes};
use serde_json::Value;

use super::router::DaemonRouter;
use crate::mux::Mux;

/// A REPL session's id on the wire (`scr_<n>`).
pub(crate) type SessionId = String;

/// REPL sessions one connection may hold open (starting ones count).
const MAX_SESSIONS_PER_CLIENT: usize = 8;
/// One-shot scripts one connection may run at once.
const MAX_RUNS_PER_CLIENT: usize = 8;
/// Sessions (REPL and one-shot, starting ones count) this daemon runs at once.
const MAX_SESSIONS: usize = 32;
/// Console lines one cell may send to its connection; the rest are counted
/// and dropped, so a chatty script never fills the connection's queue.
pub(crate) const MAX_LOG_LINES: usize = 200;

/// Error codes after which a session is gone.
const SESSION_ENDED: [&str; 5] =
    [codes::TIMEOUT, codes::MEMORY, codes::CPU, codes::CANCELLED, codes::HOST];

/// The console line budget of one cell.
#[derive(Default)]
pub(crate) struct LogBudget {
    sent: AtomicUsize,
    dropped: AtomicUsize,
}

impl LogBudget {
    /// True when one more line may go out.
    pub(crate) fn admit(&self) -> bool {
        if self.sent.fetch_add(1, Ordering::AcqRel) < MAX_LOG_LINES {
            return true;
        }
        self.dropped.fetch_add(1, Ordering::AcqRel);
        false
    }

    /// Starts a new cell's budget.
    fn reset(&self) {
        self.sent.store(0, Ordering::Release);
        self.dropped.store(0, Ordering::Release);
    }

    fn dropped(&self) -> usize {
        self.dropped.load(Ordering::Acquire)
    }
}

/// A cell's answer: its value and the console lines it dropped.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Answer {
    pub value: Value,
    pub dropped_log_lines: usize,
}

enum Running {
    /// The host is starting; `cancelled` once a cancel arrived meanwhile.
    Starting {
        cancelled: bool,
    },
    Live(Arc<Session>),
}

struct Entry {
    client: u64,
    session: Arc<Session>,
    budget: Arc<LogBudget>,
}

#[derive(Default)]
struct Inner {
    next: u64,
    /// REPL sessions by id.
    sessions: HashMap<SessionId, Entry>,
    /// Requests that start or run a cell, by `(client, request id)`.
    running: HashMap<(u64, String), Running>,
    /// One-shot runs (until they end) and REPL opens (until they start), by client.
    starts: HashMap<u64, usize>,
}

impl Inner {
    fn total(&self) -> usize {
        self.sessions.len() + self.starts.values().sum::<usize>()
    }

    fn release_start(&mut self, client: u64) {
        if let Some(count) = self.starts.get_mut(&client) {
            *count -= 1;
            if *count == 0 {
                self.starts.remove(&client);
            }
        }
    }
}

#[derive(Default)]
pub(crate) struct ScriptsSlot {
    inner: Mutex<Inner>,
    /// Random per daemon, so script idempotency keys never repeat across
    /// daemon restarts (session ids do).
    nonce: std::sync::OnceLock<String>,
}

fn limit(message: &str) -> ScriptError {
    ScriptError::new("script.limit", message)
}

fn cancelled() -> ScriptError {
    ScriptError::new(codes::CANCELLED, "the script was cancelled")
}

/// Releases a start reservation however the start ends (also on a panic).
struct StartGuard<'a> {
    slot: &'a ScriptsSlot,
    client: u64,
}

impl Drop for StartGuard<'_> {
    fn drop(&mut self) {
        self.slot.lock().release_start(self.client);
    }
}

impl ScriptsSlot {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// True when this build has a script host here.
    pub(crate) fn available() -> bool {
        crate::apps::host_binary().is_some()
    }

    fn nonce(&self) -> &str {
        self.nonce.get_or_init(|| {
            let mut bytes = [0u8; 8];
            let _ = getrandom::fill(&mut bytes);
            bytes.iter().map(|b| format!("{b:02x}")).collect()
        })
    }

    /// Reserves a start for `client` and registers `request`; the limits
    /// count starts in progress too.
    fn reserve(
        &self,
        client: u64,
        request: &str,
        per_client: usize,
        repl: bool,
    ) -> Result<(SessionId, StartGuard<'_>), ScriptError> {
        let mut inner = self.lock();
        let key = (client, request.to_string());
        if inner.running.contains_key(&key) {
            return Err(ScriptError::new(codes::BUSY, "a request with this id is running"));
        }
        if repl {
            inner.sessions.retain(|_, e| !e.session.is_dead());
        }
        if inner.total() >= MAX_SESSIONS {
            return Err(limit("too many scripts are running on this daemon"));
        }
        let starting = inner.starts.get(&client).copied().unwrap_or(0);
        let open =
            if repl { inner.sessions.values().filter(|e| e.client == client).count() } else { 0 };
        if starting + open >= per_client {
            return Err(limit("this connection runs too many scripts"));
        }
        *inner.starts.entry(client).or_insert(0) += 1;
        inner.running.insert(key, Running::Starting { cancelled: false });
        inner.next += 1;
        let id = format!("scr_{}", inner.next);
        Ok((id, StartGuard { slot: self, client }))
    }

    fn start(&self, mux: &Arc<Mux>, id: &str, log: LogSink) -> Result<Session, ScriptError> {
        let binary = crate::apps::host_binary().ok_or_else(|| {
            ScriptError::new(super::UNAVAILABLE, "this daemon has no script host")
        })?;
        let router = DaemonRouter::new(mux, &format!("{}:{id}", self.nonce()));
        Session::start(&binary, Arc::new(router), log)
    }

    /// After a start: the session goes live unless the request was cancelled
    /// or its connection closed meanwhile (then the session ends at once).
    fn go_live(
        &self,
        key: &(u64, String),
        started: Result<Session, ScriptError>,
        keep_running: bool,
    ) -> Result<Arc<Session>, ScriptError> {
        let mut inner = self.lock();
        let wanted = matches!(inner.running.get(key), Some(Running::Starting { cancelled: false }));
        let session = match started {
            Ok(session) => Arc::new(session),
            Err(error) => {
                inner.running.remove(key);
                return Err(error);
            }
        };
        if !wanted {
            inner.running.remove(key);
            drop(inner);
            session.cancel();
            return Err(cancelled());
        }
        if keep_running {
            inner.running.insert(key.clone(), Running::Live(session.clone()));
        } else {
            inner.running.remove(key);
        }
        Ok(session)
    }

    /// Removes `key` if it still names `session`.
    fn finish(&self, key: &(u64, String), session: &Arc<Session>) {
        let mut inner = self.lock();
        if matches!(inner.running.get(key), Some(Running::Live(s)) if Arc::ptr_eq(s, session)) {
            inner.running.remove(key);
        }
    }

    /// Runs `code` as one cell in a fresh session that ends with it.
    /// Blocking: call it off the connection thread.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn run(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        request: String,
        code: &str,
        args: Value,
        timeout: Duration,
        log: LogSink,
        budget: Arc<LogBudget>,
    ) -> Result<Answer, ScriptError> {
        // The reservation counts this run against the limits until it ends.
        let (id, _guard) = self.reserve(client, &request, MAX_RUNS_PER_CLIENT, false)?;
        let key = (client, request);
        let started = self.start(mux, &id, log);
        let session = self.go_live(&key, started, true)?;
        budget.reset();
        let result = session.eval(code, args, timeout);
        self.finish(&key, &session);
        session.cancel();
        result.map(|value| Answer { value, dropped_log_lines: budget.dropped() })
    }

    /// Opens a REPL session owned by `client`; `log` gets every cell's
    /// console output within `budget`.
    pub(crate) fn open(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        request: String,
        log: LogSink,
        budget: Arc<LogBudget>,
    ) -> Result<SessionId, ScriptError> {
        let (id, guard) = self.reserve(client, &request, MAX_SESSIONS_PER_CLIENT, true)?;
        let key = (client, request);
        let started = self.start(mux, &id, log);
        let session = self.go_live(&key, started, false)?;
        // Insert before the reservation goes, so the limits never see a gap.
        self.lock().sessions.insert(id.clone(), Entry { client, session, budget });
        drop(guard);
        Ok(id)
    }

    /// Runs one cell in `client`'s REPL session `id`. A session that ended
    /// (timeout, limit, cancel) is removed when it answers.
    pub(crate) fn eval(
        &self,
        client: u64,
        request: String,
        id: &str,
        code: &str,
        args: Value,
        timeout: Duration,
    ) -> Result<Answer, ScriptError> {
        let key = (client, request);
        let (session, budget) = {
            let mut inner = self.lock();
            let (session, budget) = inner
                .sessions
                .get(id)
                .filter(|e| e.client == client)
                .map(|e| (e.session.clone(), e.budget.clone()))
                .ok_or_else(|| {
                    ScriptError::new(
                        "script.not_found",
                        format!("no script session {id} on this connection"),
                    )
                })?;
            if inner.running.contains_key(&key) {
                return Err(ScriptError::new(codes::BUSY, "a request with this id is running"));
            }
            inner.running.insert(key.clone(), Running::Live(session.clone()));
            (session, budget)
        };
        budget.reset();
        let result = session.eval(code, args, timeout);
        self.finish(&key, &session);
        let ended = session.is_dead()
            || result.as_ref().is_err_and(|e| SESSION_ENDED.contains(&e.code.as_str()));
        if ended {
            let mut inner = self.lock();
            if inner.sessions.get(id).is_some_and(|e| Arc::ptr_eq(&e.session, &session)) {
                inner.sessions.remove(id);
            }
            drop(inner);
            session.cancel();
        }
        result.map(|value| Answer { value, dropped_log_lines: budget.dropped() })
    }

    /// Ends `client`'s REPL session `id`; false when it has none.
    pub(crate) fn close(&self, client: u64, id: &str) -> bool {
        let mut inner = self.lock();
        let owned = inner.sessions.get(id).is_some_and(|e| e.client == client);
        let removed = owned.then(|| inner.sessions.remove(id)).flatten();
        drop(inner);
        if let Some(entry) = removed {
            entry.session.cancel();
            return true;
        }
        false
    }

    /// `cancel-request`: ends the cell `client` started with request id
    /// `target` (and its session), also while its host is starting.
    pub(crate) fn cancel_request(&self, client: u64, target: &Value) {
        let mut inner = self.lock();
        let live = match inner.running.get_mut(&(client, target.to_string())) {
            Some(Running::Starting { cancelled }) => {
                *cancelled = true;
                None
            }
            Some(Running::Live(session)) => Some(session.clone()),
            None => None,
        };
        drop(inner);
        if let Some(session) = live {
            session.cancel();
        }
    }

    /// The connection closed: end its cells and sessions, and every start
    /// still in progress (it ends its session when it finishes).
    pub(crate) fn disconnect(&self, client: u64) {
        let mut ended: Vec<Arc<Session>> = Vec::new();
        {
            let mut inner = self.lock();
            inner.running.retain(|(owner, _), running| {
                if *owner != client {
                    return true;
                }
                if let Running::Live(session) = running {
                    ended.push(session.clone());
                }
                false
            });
            inner.sessions.retain(|_, entry| {
                if entry.client == client {
                    ended.push(entry.session.clone());
                    false
                } else {
                    true
                }
            });
        }
        for session in ended {
            session.cancel();
        }
    }
}

/// A cell's wall time from the wire, clamped to the session limits.
pub(crate) fn timeout_from(ms: Option<u64>) -> Duration {
    ms.map_or(cmux_app_host::script::DEFAULT_TIMEOUT, Duration::from_millis)
        .clamp(Duration::from_millis(1), cmux_app_host::script::MAX_TIMEOUT)
}
