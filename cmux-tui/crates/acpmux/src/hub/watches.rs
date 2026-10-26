//! Durable wake subscriptions. Watch checkpoints and owed messages commit together;
//! outbox retries use the same prompt id, including across daemon restart.
use super::watch_events;
pub(crate) use super::watch_events::seed;
use super::{Hub, HubEvent};
use crate::hub::outbox::{Delivery, State};
use crate::rpc::RpcError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
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
    #[serde(default)]
    pub retry_count: u8,
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
pub struct Watches {
    inner: Mutex<Inner>,
    wake: Notify,
}
impl Watches {
    pub(super) fn peer_settled(&self) {
        self.wake.notify_one();
    }
    pub fn open(&self, path: &Path) -> anyhow::Result<()> {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.saved = match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Saved::default(),
            Err(e) => return Err(e.into()),
        };
        inner.path = Some(path.into());
        Ok(())
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
        let mut events = hub.subscribe(); // Subscribe before startup/reconciliation.
        let weak = Arc::downgrade(hub);
        tokio::spawn(async move {
            let Some(hub) = weak.upgrade() else { return };
            hub.wait_logs().await;
            hub.wait_startup().await;
            let mut refresh = true;
            loop {
                if refresh {
                    if let Err(e) = reconcile(&hub).await {
                        tracing::error!("watch: {e}");
                    }
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
async fn reconcile(hub: &Arc<Hub>) -> Result<(), RpcError> {
    let watches = hub.watches.inner.lock().unwrap_or_else(|e| e.into_inner()).saved.watches.clone();
    let mut ordered: Vec<_> = watches.into_values().filter(|w| w.active).collect();
    // Watches with local sources are reconciled before peer-only watches, so a
    // slow remote cannot postpone an unrelated local wake.
    ordered.sort_by_key(|w| w.sessions.iter().all(|key| key.contains('/')));
    let mut retry_needed = false;
    for mut w in ordered {
        let old = json!(w);
        let mut lines = Vec::new();
        let mut resolved = false;
        let mut keys = w.sessions.clone();
        // Local journals are cheap and must wake promptly even when a peer is slow.
        keys.sort_by_key(|key| key.contains('/'));
        for key in keys {
            let s = summary(hub, &key);
            if s["stale"] == true || s["status"] == "unreachable" {
                let peer = key.split('/').next().unwrap_or(&key);
                if hub.peer(peer).is_some_and(|p| p.link().down_since.is_none()) {
                    continue;
                }
                if w.offline.insert(peer.to_owned()) {
                    lines.push(format!("Peer {peer} is offline; this does not resolve the watch. Run acpmux host doctor {peer} --json."));
                }
                continue;
            }
            if let Some((peer, _)) = key.split_once('/') {
                w.offline.remove(peer);
            }
            let checkpoint = w.cursors.get(&key).cloned();
            let collected = if key.contains('/') {
                match tokio::time::timeout(
                    std::time::Duration::from_millis(250),
                    watch_events::collect(hub, &mut w, &key),
                )
                .await
                {
                    Ok(result) => result,
                    Err(_) => Err(RpcError::internal("peer watch read timed out")),
                }
            } else {
                watch_events::collect(hub, &mut w, &key).await
            };
            match collected {
                Ok(rows) => {
                    // A successful read, including a no-op page, proves the source is
                    // reachable again. Do not let an earlier burst of timeouts strand
                    // this watch's future retries.
                    w.retry_count = 0;
                    resolved |= !rows.is_empty();
                    lines.extend(rows);
                }
                Err(e) => {
                    // A failed peer read must neither consume its cursor nor block local wakes.
                    if let Some(c) = checkpoint {
                        w.cursors.insert(key.clone(), c);
                    }
                    w.retry_count = w.retry_count.saturating_add(1);
                    retry_needed = true;
                    tracing::warn!("watch {} source {key}: {e}", w.id);
                }
            }
        }
        if w.once && resolved {
            w.active = false;
        }
        if old == json!(w) {
            continue;
        }
        hub.watches.change(|saved| {
            // rm while a peer reply was in flight must not resurrect the watch.
            if !saved.watches.contains_key(&w.id) { return; }
            if !lines.is_empty() {
                let id = uuid::Uuid::now_v7().to_string();
                let now = crate::store::now_ms();
                let request = json!({"sessionId": w.to, "prompt": [{"type": "text", "text": format!("acpmux watch {}:\n{}", w.id, lines.join("\n\n"))}],
                    "_meta": {"acpmux": {"promptId": id, "resend": true, "steer": true}}});
                saved.pending.insert(id.clone(), Delivery { id, target: w.to.clone(), request,
                    caller: w.caller.clone(), state: State::Queued, attempts: 0, error: None,
                    accepted: None, created_at: now, updated_at: now });
            }
            saved.watches.insert(w.id.clone(), w);
        })?;
    }
    drain(hub, true);
    if retry_needed {
        let retry_hub = Arc::clone(hub);
        tokio::spawn(async move {
            // A retry is armed only after an actual read error; normal watches are
            // driven solely by hub events, with no polling timer. Back off repeated
            // failures so a down peer cannot create a tight loop, while a later
            // successful no-op read resets the counter above.
            let failures = retry_hub
                .watches
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .saved
                .watches
                .values()
                .map(|w| w.retry_count)
                .max()
                .unwrap_or(1)
                .min(6);
            let delay_ms = 250u64 << failures.saturating_sub(1);
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
            retry_hub.watches.wake.notify_one();
        });
    }
    Ok(())
}
fn drain(hub: &Arc<Hub>, retry: bool) {
    let pending = hub.watches.inner.lock().unwrap_or_else(|e| e.into_inner()).saved.pending.clone();
    for d in pending.into_values() {
        match hub.outbox.get(&d.id) {
            Some(sent) if matches!(sent.state, State::Delivered | State::Held) => {
                if let Err(e) = hub.watches.change(|s| s.pending.remove(&d.id)) {
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
