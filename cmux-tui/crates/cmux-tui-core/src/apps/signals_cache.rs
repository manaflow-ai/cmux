//! The daemon's signals cache (DESIGN.md section 7, v1; js/ABI.md, Signals): one entry per
//! (source, canonical params) for every app, window and mount, read once upstream however many
//! watch it. The app runtime's `cmux.watch` joins an entry with `__cmuxAppNative.watch` and hears
//! its state (`{value, status, error?, updatedAt}`); the app-facing API does not change.
//!
//! Rules, from `generated/signals.json`:
//! - A source served here is read with one op (`read.op`). Sources read by a runtime reader
//!   (`read.reader`: `github.*`, `http.json`) stay in the runtime, whose upstream reads the daemon
//!   already shares (the GitHub gateway's ETag cache, the shared HTTP cache).
//! - Pushed sources re-read on their events, coalesced: one read in flight, at most one queued.
//!   Unpushed sources poll every `staleAfterSeconds` (or the shortest `everySeconds` a watcher
//!   asked for), never faster than `pollFloorSeconds`.
//! - Mount visibility: an entry reads by itself only while it is awake, that is some watcher's
//!   mount is shown (a watcher with no mount, an app's background code, counts as shown). A push
//!   that lands while every watcher is hidden marks the entry dirty; showing a mount reads a dirty
//!   or stale entry at once, and a fresh one when its poll comes due.
//! - Stale-while-revalidate: a re-read and a failed re-read keep the old value (status `stale`).
//!   Errors back off from the floor, doubling, to 15 minutes; final errors are not retried.
//!
//! This is the state machine only: it says which reads to run, which watchers to tell and which
//! timers to arm (`Effects`); `supervisor_signals.rs` runs them.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::hash::Hash;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// The longest a failing entry waits before it tries again.
pub(super) const MAX_BACKOFF: Duration = Duration::from_secs(15 * 60);
/// Entries nobody watches, kept for a quick remount; the oldest go first past this.
pub(super) const MAX_IDLE_ENTRIES: usize = 64;
/// Error codes a retry cannot fix (ABI.md, Signals, Backoff).
const FINAL: &[&str] = &[
    "scope.missing",
    "operation.unsupported",
    "signal.unknown",
    "signal.params",
    "validation.invalid",
];

/// One source the daemon reads with a single op.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Source {
    pub name: String,
    pub op: String,
    pub push: Vec<String>,
    pub floor: Duration,
    pub stale_after: Duration,
}

/// The sources of `generated/signals.json` read with `read.op` (the ones this cache serves).
pub(super) fn sources() -> &'static HashMap<String, Source> {
    static TABLE: OnceLock<HashMap<String, Source>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let table: Value =
            serde_json::from_str(include_str!("../../../cmux-app-host/generated/signals.json"))
                .unwrap_or_default();
        let Some(signals) = table.get("signals").and_then(Value::as_object) else {
            return HashMap::new();
        };
        signals
            .iter()
            .filter_map(|(name, def)| {
                let op = def.get("read")?.get("op")?.as_str()?.to_string();
                let secs = |k: &str| {
                    Duration::from_secs(def.get(k).and_then(Value::as_u64).unwrap_or(60).max(1))
                };
                let push = def
                    .get("push")
                    .and_then(Value::as_array)
                    .map(|p| p.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
                    .unwrap_or_default();
                let source = Source {
                    name: name.clone(),
                    op,
                    push,
                    floor: secs("pollFloorSeconds"),
                    stale_after: secs("staleAfterSeconds"),
                };
                Some((name.clone(), source))
            })
            .collect()
    })
}

/// Canonical JSON: object keys sorted at every level (serde_json's map is a BTreeMap without
/// `preserve_order`, but this does not depend on the feature), nulls in objects dropped.
pub(super) fn canonical(v: &Value) -> String {
    match v {
        Value::Array(items) => {
            format!("[{}]", items.iter().map(canonical).collect::<Vec<_>>().join(","))
        }
        Value::Object(map) => {
            let sorted: BTreeMap<&String, &Value> =
                map.iter().filter(|(_, v)| !v.is_null()).collect();
            let fields: Vec<String> = sorted
                .iter()
                .map(|(k, v)| format!("{}:{}", Value::String((*k).clone()), canonical(v)))
                .collect();
            format!("{{{}}}", fields.join(","))
        }
        other => other.to_string(),
    }
}

/// The entry key of (source, params).
pub(super) fn entry_key(name: &str, params: &Value) -> String {
    let params = if params.is_null() { json!({}) } else { params.clone() };
    format!("{name} {}", canonical(&params))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Status {
    Loading,
    Fresh,
    Stale,
    Error,
}

impl Status {
    fn as_str(self) -> &'static str {
        match self {
            Status::Loading => "loading",
            Status::Fresh => "fresh",
            Status::Stale => "stale",
            Status::Error => "error",
        }
    }
}

/// A read the caller runs: `op` with `params`, as `app` (one of the entry's watchers).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Read {
    pub key: String,
    pub app: String,
    pub op: String,
    pub params: Value,
}

/// What one step asks of the caller.
#[derive(Debug)]
pub(super) struct Effects<W> {
    pub reads: Vec<Read>,
    /// A watcher and the entry's state to send it.
    pub tell: Vec<(W, Value)>,
    /// Arm a timer: after the delay, call [`SignalsCache::due`] with this key and epoch.
    pub arm: Vec<(String, u64, Duration)>,
}

impl<W> Default for Effects<W> {
    fn default() -> Self {
        Self { reads: vec![], tell: vec![], arm: vec![] }
    }
}

#[derive(Debug)]
struct Watcher<M> {
    key: String,
    app: String,
    mount: Option<M>,
    every: Option<Duration>,
}

#[derive(Debug)]
struct Entry<W> {
    source: Source,
    params: Value,
    value: Option<Value>,
    status: Status,
    error: Option<Value>,
    updated_at_ms: Option<u64>,
    updated: Option<Instant>,
    watchers: BTreeSet<W>,
    inflight: bool,
    again: bool,
    failures: u32,
    /// A final error: no retry until a refresh or a new watcher.
    stopped: bool,
    /// A push landed while nobody shown watched it.
    dirty: bool,
    /// The armed timer's epoch; a timer of an older epoch does nothing.
    epoch: u64,
    armed: bool,
    last_use: Instant,
}

impl<W> Entry<W> {
    fn state(&self) -> Value {
        let mut state = json!({
            "value": self.value.clone().unwrap_or(Value::Null),
            "status": self.status.as_str(),
            "updatedAt": self.updated_at_ms,
        });
        if let (Some(error), Some(map)) = (&self.error, state.as_object_mut()) {
            map.insert("error".into(), error.clone());
        }
        state
    }
}

/// The cache. `W` names a watcher (a host and its watch id), `M` a mount.
pub(super) struct SignalsCache<W, M> {
    entries: HashMap<String, Entry<W>>,
    watchers: HashMap<W, Watcher<M>>,
    hidden: HashSet<M>,
    /// Upstream reads started (tests and the meter).
    pub reads: u64,
}

impl<W, M> Default for SignalsCache<W, M> {
    fn default() -> Self {
        Self { entries: HashMap::new(), watchers: HashMap::new(), hidden: HashSet::new(), reads: 0 }
    }
}

impl<W: Clone + Eq + Hash + Ord, M: Clone + Eq + Hash> SignalsCache<W, M> {
    fn shown(&self, w: &W) -> bool {
        self.watchers
            .get(w)
            .is_some_and(|x| x.mount.as_ref().is_none_or(|m| !self.hidden.contains(m)))
    }

    fn awake(&self, key: &str) -> bool {
        self.entries.get(key).is_some_and(|e| e.watchers.iter().any(|w| self.shown(w)))
    }

    /// The poll interval of an unpushed entry: the shortest shown watcher's pace, else
    /// `staleAfterSeconds`, never under the floor.
    fn poll(&self, key: &str) -> Option<Duration> {
        let e = self.entries.get(key)?;
        if !e.source.push.is_empty() {
            return None;
        }
        let paced = e
            .watchers
            .iter()
            .filter(|w| self.shown(w))
            .filter_map(|w| self.watchers.get(w).and_then(|x| x.every))
            .min();
        Some(
            paced.map_or(e.source.stale_after, |p| p.min(e.source.stale_after)).max(e.source.floor),
        )
    }

    /// Watcher `w` of `app` (on `mount`, if any) watches `source` with `params`.
    #[allow(clippy::too_many_arguments)]
    pub fn watch(
        &mut self,
        w: W,
        app: &str,
        source: &Source,
        params: Value,
        mount: Option<M>,
        every: Option<Duration>,
        now: Instant,
    ) -> Effects<W> {
        let mut fx = Effects::default();
        fx.tell.extend(self.unwatch(&w, now).tell);
        let params = if params.is_null() { json!({}) } else { params };
        let key = entry_key(&source.name, &params);
        let was_awake = self.awake(&key);
        let e = self.entries.entry(key.clone()).or_insert_with(|| Entry {
            source: source.clone(),
            params,
            value: None,
            status: Status::Loading,
            error: None,
            updated_at_ms: None,
            updated: None,
            watchers: BTreeSet::new(),
            inflight: false,
            again: false,
            failures: 0,
            stopped: false,
            dirty: false,
            epoch: 0,
            armed: false,
            last_use: now,
        });
        e.watchers.insert(w.clone());
        e.last_use = now;
        // A new watcher may fix what stopped the entry (a grant it now holds).
        e.stopped = false;
        let fresh_entry = e.value.is_none() && !e.inflight && e.error.is_none();
        self.watchers
            .insert(w.clone(), Watcher { key: key.clone(), app: app.to_string(), mount, every });
        if !fresh_entry && let Some(e) = self.entries.get(&key) {
            fx.tell.push((w, e.state()));
        }
        if fresh_entry || (!was_awake && self.awake(&key)) {
            self.wake(&key, now, &mut fx);
        } else {
            self.rearm(&key, now, &mut fx);
        }
        fx
    }

    /// Watcher `w` stops watching; an entry with no watcher keeps its value, unarmed.
    pub fn unwatch(&mut self, w: &W, now: Instant) -> Effects<W> {
        let Some(watcher) = self.watchers.remove(w) else { return Effects::default() };
        if let Some(e) = self.entries.get_mut(&watcher.key) {
            e.watchers.remove(w);
            e.last_use = now;
        }
        let mut fx = Effects::default();
        self.rearm(&watcher.key, now, &mut fx);
        self.prune();
        fx
    }

    /// Drops every watcher `gone` says (a host that exited).
    pub fn unwatch_where(&mut self, gone: impl Fn(&W) -> bool, now: Instant) {
        let ws: Vec<W> = self.watchers.keys().filter(|w| gone(w)).cloned().collect();
        for w in ws {
            self.unwatch(&w, now);
        }
    }

    /// The page shows or hides `mount`.
    pub fn mount_visible(&mut self, mount: &M, visible: bool, now: Instant) -> Effects<W> {
        let keys: BTreeSet<String> = self
            .watchers
            .values()
            .filter(|x| x.mount.as_ref() == Some(mount))
            .map(|x| x.key.clone())
            .collect();
        let before: HashMap<String, bool> =
            keys.iter().map(|k| (k.clone(), self.awake(k))).collect();
        if visible {
            self.hidden.remove(mount);
        } else {
            self.hidden.insert(mount.clone());
        }
        let mut fx = Effects::default();
        for key in keys {
            if !before.get(&key).copied().unwrap_or(false) && self.awake(&key) {
                self.wake(&key, now, &mut fx);
            } else {
                self.rearm(&key, now, &mut fx);
            }
        }
        fx
    }

    /// A mount is gone: forget whether it was hidden.
    pub fn mount_gone(&mut self, mount: &M) {
        self.hidden.remove(mount);
    }

    /// An event of `stream` landed: every entry it pushes re-reads, or is marked dirty while hidden.
    pub fn pushed(&mut self, stream: &str) -> Effects<W> {
        let keys: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| !e.watchers.is_empty() && e.source.push.iter().any(|p| p == stream))
            .map(|(k, _)| k.clone())
            .collect();
        let mut fx = Effects::default();
        for key in keys {
            if self.awake(&key) {
                self.read(&key, &mut fx);
            } else if let Some(e) = self.entries.get_mut(&key) {
                e.dirty = true;
            }
        }
        fx
    }

    /// Watcher `w` asks for a read now (`refresh()`).
    pub fn refresh(&mut self, w: &W) -> Effects<W> {
        let mut fx = Effects::default();
        let Some(key) = self.watchers.get(w).map(|x| x.key.clone()) else { return fx };
        if let Some(e) = self.entries.get_mut(&key) {
            e.stopped = false;
        }
        self.read(&key, &mut fx);
        fx
    }

    /// The timer armed with `epoch` for `key` fired.
    pub fn due(&mut self, key: &str, epoch: u64) -> Effects<W> {
        let mut fx = Effects::default();
        let Some(e) = self.entries.get_mut(key) else { return fx };
        if e.epoch != epoch || !e.armed {
            return fx;
        }
        e.armed = false;
        if self.awake(key) {
            self.read(key, &mut fx);
        }
        fx
    }

    /// A read of `key` answered: `Ok(value)` or `Err(ABI error body)`.
    pub fn landed(
        &mut self,
        key: &str,
        result: Result<Value, Value>,
        now: Instant,
        now_ms: u64,
    ) -> Effects<W> {
        let mut fx = Effects::default();
        let Some(e) = self.entries.get_mut(key) else { return fx };
        e.inflight = false;
        match result {
            Ok(value) => {
                e.value = Some(value);
                e.status = Status::Fresh;
                e.error = None;
                e.updated_at_ms = Some(now_ms);
                e.updated = Some(now);
                e.failures = 0;
            }
            Err(error) => {
                e.failures += 1;
                let code = error.get("code").and_then(Value::as_str).unwrap_or("");
                let not_retryable = code == "upstream.failed"
                    && error.get("retryable") == Some(&Value::Bool(false));
                e.stopped = FINAL.contains(&code) || not_retryable;
                e.status = if e.value.is_some() { Status::Stale } else { Status::Error };
                e.error = Some(error);
            }
        }
        let state = e.state();
        fx.tell.extend(e.watchers.iter().map(|w| (w.clone(), state.clone())));
        if std::mem::take(&mut e.again) {
            self.read(key, &mut fx);
        } else {
            self.rearm(key, now, &mut fx);
        }
        self.prune();
        fx
    }

    /// An entry woke (a new watcher, a shown mount): read now when it is empty, dirty or stale,
    /// else arm its poll for when it comes due.
    fn wake(&mut self, key: &str, now: Instant, fx: &mut Effects<W>) {
        let Some(e) = self.entries.get(key) else { return };
        let age = e.updated.map(|u| now.saturating_duration_since(u));
        let due = e.value.is_none()
            || e.dirty
            || e.status != Status::Fresh
            || age.is_none_or(|a| a >= e.source.stale_after);
        if due && !e.stopped {
            self.read(key, fx);
        } else {
            self.rearm(key, now, fx);
        }
    }

    fn read(&mut self, key: &str, fx: &mut Effects<W>) {
        let app = {
            let Some(e) = self.entries.get(key) else { return };
            let Some(w) = e.watchers.iter().find(|w| self.shown(w)).or(e.watchers.iter().next())
            else {
                return;
            };
            let Some(watcher) = self.watchers.get(w) else { return };
            watcher.app.clone()
        };
        let Some(e) = self.entries.get_mut(key) else { return };
        if e.inflight {
            e.again = true;
            return;
        }
        e.inflight = true;
        e.dirty = false;
        e.armed = false;
        e.epoch += 1;
        if e.value.is_some() && e.status == Status::Fresh {
            e.status = Status::Stale;
            let state = e.state();
            fx.tell.extend(e.watchers.iter().map(|w| (w.clone(), state.clone())));
        }
        self.reads += 1;
        fx.reads.push(Read {
            key: key.to_string(),
            app,
            op: e.source.op.clone(),
            params: e.params.clone(),
        });
    }

    /// Arms the entry's next read by itself, or disarms it: none while asleep, in flight, stopped,
    /// or pushed and fine.
    fn rearm(&mut self, key: &str, now: Instant, fx: &mut Effects<W>) {
        let awake = self.awake(key);
        let poll = self.poll(key);
        let Some(e) = self.entries.get_mut(key) else { return };
        e.epoch += 1;
        e.armed = false;
        if !awake || e.inflight || e.stopped {
            return;
        }
        let after = if e.failures > 0 {
            let doubled =
                e.source.floor.saturating_mul(1u32 << e.failures.saturating_sub(1).min(20));
            doubled.min(MAX_BACKOFF)
        } else if let Some(poll) = poll {
            let age = e.updated.map_or(poll, |u| now.saturating_duration_since(u));
            poll.saturating_sub(age).max(Duration::from_millis(1))
        } else {
            return;
        };
        e.armed = true;
        fx.arm.push((key.to_string(), e.epoch, after));
    }

    fn prune(&mut self) {
        let mut idle: Vec<(Instant, String)> = self
            .entries
            .iter()
            .filter(|(_, e)| e.watchers.is_empty() && !e.inflight)
            .map(|(k, e)| (e.last_use, k.clone()))
            .collect();
        if idle.len() <= MAX_IDLE_ENTRIES {
            return;
        }
        idle.sort();
        let extra = idle.len() - MAX_IDLE_ENTRIES;
        for (_, key) in idle.into_iter().take(extra) {
            self.entries.remove(&key);
        }
    }

    /// Entries kept (tests).
    #[cfg(test)]
    pub fn entries(&self) -> usize {
        self.entries.len()
    }
}

#[cfg(test)]
#[path = "signals_cache_tests.rs"]
mod tests;
