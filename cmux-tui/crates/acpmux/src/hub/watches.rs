//! Durable wake subscriptions. Watch checkpoints and owed messages commit together;
//! outbox retries use the same prompt id, including across daemon restart.
use super::watch_events;
pub(crate) use super::watch_events::seed;
use super::{Hub, HubEvent};
use crate::hub::outbox::{Delivery, State};
use crate::rpc::RpcError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::{Notify, broadcast};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Watch {
    pub id: String,
    pub to: String,
    pub sessions: Vec<String>,
    pub until: Vec<String>,
    pub match_text: Option<String>,
    pub once: bool,
    pub caller: Option<String>,
    pub active: bool,
    pub cursors: BTreeMap<String, watch_events::Cursor>,
    pub offline: BTreeSet<String>,
}

impl Watch {
    fn status(&self) -> Value {
        json!({"id": self.id, "to": self.to, "sessions": self.sessions, "until": self.until,
            "match": self.match_text, "once": self.once, "active": self.active, "offline": self.offline})
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct Saved {
    watches: BTreeMap<String, Watch>,
    pending: BTreeMap<String, Delivery>,
}
#[derive(Default)]
struct Inner {
    saved: Saved,
    path: Option<PathBuf>,
}
#[derive(Default)]
struct Jobs {
    ready: VecDeque<String>,
    // Dirty while running, plus consecutive failures; one entry per peer/session.
    pending: BTreeMap<String, (bool, u8)>,
}
#[derive(Default)]
pub struct Watches {
    inner: Mutex<Inner>,
    wake: Notify,
    jobs: Mutex<Jobs>,
    available: Notify,
}
impl Watches {
    pub(super) fn peer_settled(&self) {
        self.wake.notify_one();
    }
    pub fn open(&self, path: &Path) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.saved = match std::fs::read(path)
            .and_then(|b| serde_json::from_slice(&b).map_err(std::io::Error::other))
        {
            Ok(saved) => saved,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Saved::default(),
            Err(e) => {
                let bad = path.with_extension(format!("json.bad-{}", crate::store::now_ms()));
                tracing::warn!(
                    "watch state {} unavailable: {e}; preserving at {}",
                    path.display(),
                    bad.display()
                );
                if let Err(e) = std::fs::rename(path, bad) {
                    tracing::warn!("cannot preserve watch state: {e}");
                }
                Saved::default()
            }
        };
        inner.path = Some(path.into());
    }
    // Do not acknowledge a mutation that could not be saved; keep the previous
    // checkpoint so a later event/restart can retry without losing the wake.
    fn change<T>(&self, f: impl FnOnce(&mut Saved) -> T) -> Result<T, RpcError> {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = inner.saved.clone();
        let result = f(&mut next);
        if let Some(path) = &inner.path {
            let bytes = serde_json::to_vec(&next).map_err(|e| RpcError::internal(e.to_string()))?;
            crate::config::write_atomic(path, &bytes)
                .map_err(|e| RpcError::internal(format!("cannot save watches: {e}")))?;
        }
        inner.saved = next;
        Ok(result)
    }
    pub fn add(&self, watch: Watch) -> Result<Value, RpcError> {
        let result = watch.status();
        self.change(|s| s.watches.insert(watch.id.clone(), watch))?;
        self.wake.notify_one();
        Ok(result)
    }
    pub fn list(&self, hub: &Hub) -> Value {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        json!({"watches": inner.saved.watches.values().map(Watch::status).collect::<Vec<_>>(),
            "deliveries": inner.saved.pending.values().map(|d| hub.outbox.get(&d.id).unwrap_or_else(|| d.clone()).status()).collect::<Vec<_>>()})
    }
    pub fn remove(&self, id: &str) -> Result<bool, RpcError> {
        self.change(|s| s.watches.remove(id).is_some())
    }
    pub fn start(hub: &Arc<Hub>) {
        for _ in 0..8 {
            tokio::spawn(remote_worker(Arc::clone(hub)));
        }
        let mut events = hub.subscribe(); // Subscribe before startup/reconciliation.
        let weak = Arc::downgrade(hub);
        tokio::spawn(async move {
            let Some(hub) = weak.upgrade() else { return };
            hub.wait_logs().await;
            hub.wait_startup().await;
            let mut refresh = true;
            loop {
                if refresh && let Err(e) = reconcile(&hub).await {
                    tracing::error!("watch: {e}");
                }
                refresh = tokio::select! {
                    () = hub.shutdown.notified() => break,
                    () = hub.watches.wake.notified() => true,
                    () = hub.outbox.changed.notified() => { drain(&hub, false); false },
                    e = events.recv() => match e {
                        Ok(e) => concerns(&hub, &e),
                        Err(broadcast::error::RecvError::Lagged(_)) => true,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                };
                // Coalesce already queued changes; no timer and no periodic reads.
                loop {
                    match events.try_recv() {
                        Ok(e) => refresh |= concerns(&hub, &e),
                        Err(broadcast::error::TryRecvError::Lagged(_)) => refresh = true,
                        Err(_) => break,
                    }
                }
            }
        });
    }
}
fn concerns(hub: &Hub, e: &HubEvent) -> bool {
    // Stream chunks do not resolve watches. Read their journal only on a state change.
    if !matches!(e.record.dir.as_str(), "mux" | "peer") {
        return false;
    }
    let key = match &e.remote {
        Some(r) => format!("{}/{}", r.peer, e.session_id),
        None => e.session_id.clone(),
    };
    let inner = hub.watches.inner.lock().unwrap_or_else(|e| e.into_inner());
    inner.saved.watches.values().any(|w| w.active && w.sessions.contains(&key))
        || inner.saved.pending.values().any(|d| d.target == key)
}
/// Bind a name once. A rename or a new session reusing it cannot retarget a watch.
pub fn resolve(hub: &Hub, key: &str) -> Result<String, RpcError> {
    if let Ok(s) = hub.resolve(key) {
        return Ok(s.id.clone());
    }
    hub.resolve_remote(key)
        .map(|(p, id, _)| format!("{}/{id}", p.name))
        .ok_or_else(|| RpcError::not_found(format!("no session matches {key:?}; run acpmux ls")))
}
pub(super) fn summary(hub: &Hub, key: &str) -> Value {
    if let Ok(s) = hub.resolve(key) {
        return hub.session_summary(&s);
    }
    if let Some((_, _, s)) = hub.resolve_remote(key) {
        return s;
    }
    if let Some((peer, _)) = key.split_once('/') {
        if hub.peer(peer).is_some_and(|p| {
            p.connected.load(std::sync::atomic::Ordering::SeqCst) && *p.settled().borrow() > 0
        }) {
            return json!({"status": "closed", "missing": true});
        }
        json!({"status": "unreachable", "stale": true})
    } else {
        json!({"status": "closed", "missing": true})
    }
}
// Checkpoint each successful page together with its wakes. Concurrent sources merge
// only their own cursor; a stale reader cannot resurrect a removed/resolved watch.
fn commit(
    hub: &Hub,
    old: &Watch,
    next: &Watch,
    key: &str,
    lines: Vec<String>,
    resolved: bool,
) -> Result<(), RpcError> {
    if old.cursors == next.cursors && old.offline == next.offline && lines.is_empty() {
        return Ok(());
    }
    hub.watches.change(|saved| {
        let Some(w) = saved.watches.get_mut(&old.id) else { return };
        if !w.active || w.cursors.get(key) != old.cursors.get(key) { return; }
        if !resolved && key.split_once('/').is_some_and(|(p, _)| next.offline.contains(p) && w.offline.contains(p)) { return; }
        w.cursors.insert(key.into(), next.cursors[key].clone());
        if let Some((peer, _)) = key.split_once('/') {
            if next.offline.contains(peer) { w.offline.insert(peer.into()); }
            else { w.offline.remove(peer); }
        }
        if resolved { w.active = false; }
        if !lines.is_empty() {
            let id = uuid::Uuid::now_v7().to_string();
            let now = crate::store::now_ms();
            let request = json!({"sessionId": w.to, "prompt": [{"type": "text", "text": format!("acpmux watch {}:\n{}", w.id, lines.join("\n\n"))}],
                "_meta": {"acpmux": {"promptId": id, "resend": true, "steer": true,
                    "watchId": w.id, "watchDone": resolved}}});
            saved.pending.insert(id.clone(), Delivery { id, target: w.to.clone(), request,
                caller: w.caller.clone(), state: State::Queued, attempts: 0, error: None,
                accepted: None, created_at: now, updated_at: now });
        }
    })
}
fn snapshot(hub: &Hub) -> Vec<Watch> {
    let inner = hub.watches.inner.lock().unwrap_or_else(|e| e.into_inner());
    inner.saved.watches.values().filter(|w| w.active).cloned().collect()
}
async fn page(hub: &Hub, id: &str, key: &str) -> Result<bool, RpcError> {
    let Some(old) = snapshot(hub).into_iter().find(|w| w.id == id) else { return Ok(false) };
    let mut next = old.clone();
    let s = summary(hub, key);
    if s["stale"] == true || s["status"] == "unreachable" {
        let peer = key.split('/').next().unwrap_or(key);
        if hub.peer(peer).is_some_and(|p| p.link().down_since.is_some())
            && next.offline.insert(peer.into())
        {
            commit(
                hub,
                &old,
                &next,
                key,
                vec![format!(
                    "Peer {peer} is offline; this does not resolve the watch. Run acpmux host doctor {peer} --json."
                )],
                false,
            )?;
        }
        return Ok(false);
    }
    if let Some((peer, _)) = key.split_once('/') {
        next.offline.remove(peer);
    }
    let (rows, more) = watch_events::collect(hub, &mut next, key).await?;
    let resolved = !rows.is_empty();
    commit(hub, &old, &next, key, rows, resolved)?;
    Ok(more && !resolved)
}
// Called before local deletion too: no peer I/O can delay saving an owed wake.
pub(super) async fn before_purge(hub: &Hub, key: &str) -> Result<(), RpcError> {
    for w in snapshot(hub).into_iter().filter(|w| w.sessions.iter().any(|s| s == key)) {
        while page(hub, &w.id, key).await? {}
    }
    hub.watches.wake.notify_one();
    Ok(())
}
async fn reconcile(hub: &Arc<Hub>) -> Result<(), RpcError> {
    let watches = snapshot(hub);
    for w in &watches {
        for key in w.sessions.iter().filter(|k| !k.contains('/')) {
            while page(hub, &w.id, key).await? {}
        }
    }
    drain(hub, true); // Dispatch local wakes before starting any remote read.
    let mut jobs = hub.watches.jobs.lock().unwrap_or_else(|e| e.into_inner());
    for key in watches.into_iter().flat_map(|w| w.sessions).filter(|k| k.contains('/')) {
        if let Some((dirty, _)) = jobs.pending.get_mut(&key) {
            *dirty = true;
        } else {
            jobs.pending.insert(key.clone(), (false, 0));
            jobs.ready.push_back(key);
        }
    }
    hub.watches.available.notify_one();
    Ok(())
}
async fn remote_worker(hub: Arc<Hub>) {
    loop {
        let available = hub.watches.available.notified();
        let key = {
            let mut jobs = hub.watches.jobs.lock().unwrap_or_else(|e| e.into_inner());
            let key = jobs.ready.pop_front();
            if let Some(key) = &key {
                jobs.pending.get_mut(key).unwrap().0 = false;
            }
            key
        };
        let Some(key) = key else {
            tokio::select! { () = hub.shutdown.notified() => return, () = available => {} }
            continue;
        };
        hub.watches.available.notify_one(); // Let another worker take the next source.
        let (mut more, mut failed) = (false, false);
        for w in snapshot(&hub).into_iter().filter(|w| w.sessions.contains(&key)) {
            let result = tokio::select! {
                () = hub.shutdown.notified() => return,
                result = page(&hub, &w.id, &key) => result,
            };
            match result {
                Ok(next) => more |= next,
                Err(e) => {
                    failed = true;
                    tracing::warn!("watch {} source {key}: {e}", w.id);
                }
            }
        }
        drain(&hub, false);
        let failures = {
            let mut jobs = hub.watches.jobs.lock().unwrap_or_else(|e| e.into_inner());
            let state = jobs.pending.get_mut(&key).unwrap();
            state.1 = if failed { (state.1 + 1).min(6) } else { 0 };
            state.1
        };
        if failed {
            tokio::select! {
                () = hub.shutdown.notified() => return,
                () = tokio::time::sleep(std::time::Duration::from_millis(250 << (failures - 1))) => {}
            }
        }
        let mut jobs = hub.watches.jobs.lock().unwrap_or_else(|e| e.into_inner());
        if more || failed || jobs.pending[&key].0 {
            jobs.ready.push_back(key);
            hub.watches.available.notify_one();
        } else {
            jobs.pending.remove(&key);
        }
    }
}
fn drain(hub: &Arc<Hub>, retry: bool) {
    let pending = hub.watches.inner.lock().unwrap_or_else(|e| e.into_inner()).saved.pending.clone();
    for d in pending.into_values() {
        match hub.outbox.get(&d.id) {
            Some(sent) if matches!(sent.state, State::Delivered | State::Held) => {
                if let Err(e) = hub.watches.change(|s| {
                    s.pending.remove(&d.id);
                    if d.request.pointer("/_meta/acpmux/watchDone") == Some(&json!(true))
                        && let Some(id) =
                            d.request.pointer("/_meta/acpmux/watchId").and_then(Value::as_str)
                    {
                        s.watches.remove(id);
                    }
                }) {
                    tracing::error!("watch: {e}");
                }
            }
            Some(sent) if retry && sent.state == State::Failed => {
                hub.outbox.update(&d.id, |d| {
                    d.state = State::Queued;
                    d.error = None;
                });
                crate::server::outbox::resume(hub, vec![d]);
            }
            Some(_) => {}
            None => {
                hub.outbox.add(d.clone());
                crate::server::outbox::resume(hub, vec![d]);
            }
        }
    }
}
