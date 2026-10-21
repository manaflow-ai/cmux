//! Part of `Hub`; see `hub/mod.rs`.

use super::*;
use crate::session_identity::SessionReceipt;

pub(super) fn session_receipt(summary: &Value) -> Option<SessionReceipt> {
    summary.get("sessionReceipt").and_then(|value| serde_json::from_value(value.clone()).ok())
}

/// How long `peer_add` with `wait` waits for the first connect attempt: an
/// ssh peer may take its ssh connect, tunnel and WebSocket timeouts in turn.
pub(crate) const PEER_SETTLE_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

/// The record kind of a peer's `_acpmux/permission_pending`, relayed to
/// this daemon's watchers (`server/mod.rs` `deliver`); never stored.
pub(crate) const PEER_PERMISSION_PENDING: &str = "peer_permission_pending";

impl Hub {
    // ------------------------------------------------------------- peers

    pub(super) fn start_peer(
        &self,
        name: &str,
        pc: &crate::config::PeerConfig,
    ) -> tokio::sync::watch::Receiver<u64> {
        let url = pc.url.as_str();
        // A saved ssh peer the validator refuses never runs: its URL may have
        // been set by a remote client before tokens stopped leaking to them.
        // The log names the peer, never the URL.
        if url.starts_with("ssh://")
            && let Err(why) = crate::peer::ssh_target(url)
        {
            tracing::warn!(peer = %name, "peer refused: its ssh URL is not valid ({why}); fix or remove it");
            if let Some(old) = self.peers.lock().unwrap_or_else(|e| e.into_inner()).remove(name) {
                old.stop();
            }
            return tokio::sync::watch::channel(1).1;
        }
        self.spawn_peer(name, pc, true).1
    }

    /// Run a peer under `name`, replacing any peer of that name; with
    /// `cached`, it first lists its saved last-known sessions
    /// (`peer_cache.rs`). Returns its generation and its settled receiver.
    pub(super) fn spawn_peer(
        &self,
        name: &str,
        pc: &crate::config::PeerConfig,
        cached: bool,
    ) -> (u64, tokio::sync::watch::Receiver<u64>) {
        let peer = crate::peer::Peer::new(
            name,
            &pc.url,
            pc.token.clone(),
            pc.peer_token.clone(),
            self.peer_notices.clone(),
        );
        let settled = peer.settled();
        if let Some(old) = self.peers.lock().unwrap().insert(name.to_owned(), peer.clone()) {
            old.stop();
            // A reconnect keeps when the peer was last seen.
            peer.seed_last_seen(old.link().last_seen);
        }
        if cached {
            self.load_peer_cache(&peer);
        }
        let generation = peer.generation;
        tokio::spawn(peer.run());
        (generation, settled)
    }

    /// Add (or replace) a peer. With `wait`, answer once its first connect
    /// attempt settled (connected with its sessions listed, or failed), at
    /// most `PEER_SETTLE_BUDGET` later, so the caller's listing is real.
    /// `peer_token`: the peer's peer token (`server/peer_auth.rs`) for a
    /// `ws://` peer; without it that peer serves this daemon as Web.
    pub async fn add_peer(
        &self,
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        wait: bool,
    ) -> Result<(), RpcError> {
        crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
        if !(url.starts_with("ws://") || url.starts_with("wss://") || url.starts_with("ssh://")) {
            return Err(RpcError::invalid_params(
                "peer url must start with ws://, wss://, or ssh://host",
            ));
        }
        if url.starts_with("ssh://")
            && let Err(why) = crate::peer::ssh_target(url)
        {
            return Err(RpcError::invalid_params(format!("refusing that ssh peer URL: {why}")));
        }
        let pc = crate::config::PeerConfig { url: url.to_owned(), token, peer_token };
        {
            let mut cfg = self.config.write().await;
            cfg.peers.insert(name.to_owned(), pc.clone());
            if let Err(e) = cfg.save() {
                tracing::warn!("save config failed: {e}");
            }
        }
        let mut settled = {
            // A saved peer takes the name over from a lease (`peer_lease.rs`),
            // under the lease lock so no notice of the leased peer finds the
            // name unleased first (lock order: `peer_leases`, then `peers`).
            let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            if leases.remove(name).is_some() {
                // The leased machine's rows go; the saved peer lists its own.
                self.purge_peer_rows(name);
            }
            self.start_peer(name, &pc)
        };
        if wait {
            let _ = tokio::time::timeout(PEER_SETTLE_BUDGET, settled.changed()).await;
        }
        Ok(())
    }

    /// `_acpmux/peer_add {name, url, token?, peerToken?, wait?}`.
    pub async fn add_peer_from(&self, params: &Value) -> Result<(), RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str);
        let required =
            |k: &str| text(k).ok_or_else(|| RpcError::invalid_params(format!("{k} is required")));
        let (name, url) = (required("name")?, required("url")?);
        let token = text("token").map(str::to_owned);
        let peer_token = text("peerToken").map(str::to_owned);
        let wait = params.get("wait").and_then(Value::as_bool).unwrap_or(false);
        self.add_peer(name, url, token, peer_token, wait).await
    }

    /// Reconnect a configured peer now (its daemon was restarted), without
    /// waiting out the reconnect backoff; with `wait`, answer once the
    /// attempt settled.
    pub async fn reconnect_peer(&self, name: &str, wait: bool) -> Result<(), RpcError> {
        let peer = self.config.read().await.peers.get(name).cloned();
        let Some(peer) = peer else {
            return Err(RpcError::not_found(format!("no peer {name:?}")));
        };
        let mut settled = self.start_peer(name, &peer);
        if wait {
            let _ = tokio::time::timeout(PEER_SETTLE_BUDGET, settled.changed()).await;
        }
        Ok(())
    }

    pub async fn remove_peer(&self, name: &str) -> Result<(), RpcError> {
        let peer = self.peers.lock().unwrap().remove(name);
        let Some(peer) = peer else {
            return Err(RpcError::not_found(format!("no peer {name:?}")));
        };
        peer.stop();
        self.forget_lease(name);
        self.forget_peer_cache(name);
        self.purge_peer_rows(name);
        let mut cfg = self.config.write().await;
        cfg.peers.remove(name);
        if let Err(e) = cfg.save() {
            tracing::warn!("save config failed: {e}");
        }
        Ok(())
    }

    /// Drop every row of peer `name` and tell watching clients they left.
    pub(super) fn purge_peer_rows(&self, name: &str) {
        let gone: Vec<Value> = {
            let mut map = self.remote_sessions.lock().unwrap();
            let ids: Vec<String> =
                map.iter().filter(|(_, r)| r.peer == name).map(|(id, _)| id.clone()).collect();
            ids.into_iter().filter_map(|id| map.remove(&id).map(|r| r.summary)).collect()
        };
        // Clients watching the list drop these rows.
        for summary in gone {
            self.announce_remote(name, summary, "purged");
        }
    }

    pub fn peers(&self) -> Vec<Value> {
        // Read before `peers` is locked (lock order: `peer_leases`, then `peers`).
        let leased: std::collections::HashSet<String> =
            self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        let mut v: Vec<Value> = self
            .peers
            .lock()
            .unwrap()
            .values()
            .map(|p| {
                let mut s = p.summary();
                s["sessions"] = json!(
                    self.remote_sessions
                        .lock()
                        .unwrap()
                        .values()
                        .filter(|r| r.peer == p.name)
                        .count()
                );
                if leased.contains(&p.name) {
                    s["leased"] = Value::Bool(true);
                }
                s
            })
            .collect();
        v.sort_by_key(|p| p.get("name").and_then(Value::as_str).unwrap_or("").to_owned());
        v
    }

    pub fn peer_by_name(&self, name: &str) -> Option<Arc<crate::peer::Peer>> {
        self.peer(name)
    }

    pub fn connected_peers(&self) -> Vec<Arc<crate::peer::Peer>> {
        self.peers
            .lock()
            .unwrap()
            .values()
            .filter(|p| p.connected.load(std::sync::atomic::Ordering::SeqCst))
            .cloned()
            .collect()
    }

    pub(super) fn peer(&self, name: &str) -> Option<Arc<crate::peer::Peer>> {
        self.peers.lock().unwrap().get(name).cloned()
    }

    /// Prefix a peer session's summary so it reads as `<peer>/<name>`.
    pub(super) fn remote_summary(peer: &str, mut summary: Value) -> Value {
        let generation = summary
            .get("sessionReceipt")
            .and_then(|value| serde_json::from_value::<SessionReceipt>(value.clone()).ok())
            .map(|receipt| receipt.generation)
            .unwrap_or_default();
        if let Some(mux_id) = summary.get("sessionId").and_then(Value::as_str) {
            let receipt = SessionReceipt::new(
                peer,
                mux_id,
                summary.get("agentSessionId").and_then(Value::as_str).map(str::to_owned),
                generation,
            );
            summary["qualifiedSessionId"] = Value::String(receipt.qualified_id());
            summary["sessionReceipt"] = receipt.to_value();
        }
        if let Some(name) = summary.get("name").and_then(Value::as_str)
            && !name.starts_with(&format!("{peer}/"))
        {
            let full = format!("{peer}/{name}");
            summary["name"] = Value::String(full);
        }
        summary["peer"] = Value::String(peer.to_owned());
        // A peer from before `indicator`, `lane` or the lane's masked `step` and `title`
        // sends none: decide them here.
        let old_lane = summary["lane"].as_object().is_some_and(|lane| !lane.contains_key("title"));
        if summary.get("indicator").is_none() || summary.get("lane").is_none() || old_lane {
            super::views::decide(&mut summary);
        }
        summary
    }

    /// Tell watching clients that a peer session appeared, changed or left.
    fn announce_remote(&self, peer: &str, summary: Value, kind: &str) {
        let Some(id) = summary.get("sessionId").and_then(Value::as_str).map(str::to_owned) else {
            return;
        };
        let _ = self.events.send(HubEvent {
            session_id: id,
            record: EventRecord {
                seq: 0,
                at: now_ms(),
                dir: "peer".into(),
                kind: kind.into(),
                msg: Value::Null,
                host_seq: None,
            },
            remote: Some(RemoteRef { peer: peer.to_owned(), summary }),
        });
    }

    pub(super) async fn peer_notice_loop(self: Arc<Self>) {
        let Some(mut rx) = self.peer_notices_rx.lock().await.take() else { return };
        use crate::peer::PeerNotice;
        while let Some((peer, generation, notice)) = rx.recv().await {
            // Only the registered instance speaks for a name: a replaced or
            // removed peer's queued notices are stale.
            let Some(current) = self.peer(&peer).filter(|p| p.generation == generation) else {
                continue;
            };
            let settles = matches!(notice, PeerNotice::Connected | PeerNotice::Disconnected(_));
            self.apply_peer_notice(&peer, notice);
            if settles {
                current.mark_settled();
            }
        }
    }

    pub(super) fn apply_peer_notice(&self, peer: &str, notice: crate::peer::PeerNotice) {
        use crate::peer::PeerNotice;
        let peer = peer.to_owned();
        {
            match notice {
                PeerNotice::Connected => tracing::info!(peer = %peer, "peer ready"),
                PeerNotice::Disconnected(e) => {
                    let link = self.peer(&peer).map(|p| p.link()).unwrap_or_default();
                    // One line per drop, not per failed attempt while it is down.
                    if link.attempts <= 1 {
                        tracing::warn!(peer = %peer, "peer disconnected: {e}");
                    } else {
                        tracing::debug!(peer = %peer, attempts = link.attempts, "peer still unreachable: {e}");
                    }
                    // Keep the last known list, but flag it.
                    let changed: Vec<Value> = {
                        let mut map = self.remote_sessions.lock().unwrap();
                        map.values_mut()
                            .filter(|r| r.peer == peer)
                            .filter_map(|r| {
                                super::peer_cache::mark_stale(&mut r.summary, link.last_seen)
                                    .then(|| r.summary.clone())
                            })
                            .collect()
                    };
                    if !changed.is_empty() {
                        self.save_peer_cache(&peer, true);
                    }
                    for summary in changed {
                        self.announce_remote(&peer, summary, "status");
                    }
                }
                PeerNotice::Sessions(list) => {
                    // The list can land after clients took their snapshot (an
                    // ssh tunnel is slow to open), so tell watchers what changed.
                    let (changed, gone) = {
                        let mut map = self.remote_sessions.lock().unwrap();
                        let mut old: HashMap<String, Value> = map
                            .iter()
                            .filter(|(_, r)| r.peer == peer)
                            .map(|(id, r)| (id.clone(), r.summary.clone()))
                            .collect();
                        map.retain(|_, r| r.peer != peer);
                        let mut changed = Vec::new();
                        for s in list {
                            let summary = Self::remote_summary(&peer, s);
                            let Some(receipt) = session_receipt(&summary) else { continue };
                            let id = receipt.qualified_id();
                            if old.remove(&id).as_ref() != Some(&summary) {
                                changed.push(summary.clone());
                            }
                            map.insert(id, RemoteSession { peer: peer.clone(), summary, receipt });
                        }
                        (changed, old.into_values().collect::<Vec<_>>())
                    };
                    self.save_peer_cache(&peer, true);
                    for summary in changed {
                        self.announce_remote(&peer, summary, "status");
                    }
                    for summary in gone {
                        self.announce_remote(&peer, summary, "purged");
                    }
                }
                PeerNotice::SessionChanged { session, kind, seq } => {
                    let Some(mux_id) =
                        session.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        return;
                    };
                    if kind == "purged" {
                        let removed = {
                            let mut map = self.remote_sessions.lock().unwrap();
                            let key = map
                                .iter()
                                .find(|(_, r)| r.peer == peer && r.receipt.mux_session_id == mux_id)
                                .map(|(key, _)| key.clone());
                            key.and_then(|key| map.remove(&key).map(|r| r.summary))
                        };
                        self.save_peer_cache(&peer, false);
                        let _ = self.events.send(HubEvent {
                            session_id: mux_id.clone(),
                            record: EventRecord {
                                seq,
                                at: now_ms(),
                                dir: "peer".into(),
                                kind,
                                msg: Value::Null,
                                host_seq: None,
                            },
                            remote: Some(RemoteRef {
                                peer: peer.clone(),
                                summary: removed.unwrap_or_else(|| json!({"sessionId": mux_id})),
                            }),
                        });
                        return;
                    }
                    let summary = Self::remote_summary(&peer, session);
                    let Some(receipt) = session_receipt(&summary) else { return };
                    let id = receipt.qualified_id();
                    {
                        let mut map = self.remote_sessions.lock().unwrap();
                        let old_id = map
                            .iter()
                            .find(|(_, r)| r.peer == peer && r.receipt.mux_session_id == mux_id)
                            .map(|(key, _)| key.clone());
                        if let Some(old_id) = old_id {
                            map.remove(&old_id);
                        }
                        map.insert(
                            id.clone(),
                            RemoteSession { peer: peer.clone(), summary: summary.clone(), receipt },
                        );
                    }
                    self.save_peer_cache(&peer, false);
                    let _ = self.events.send(HubEvent {
                        session_id: mux_id,
                        record: EventRecord {
                            seq,
                            at: now_ms(),
                            dir: "peer".into(),
                            kind,
                            msg: Value::Null,
                            host_seq: None,
                        },
                        remote: Some(RemoteRef { peer: peer.clone(), summary }),
                    });
                }
                PeerNotice::Notification { method: m, params } => {
                    let Some(id) =
                        params.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        return;
                    };
                    let summary = self
                        .remote_sessions
                        .lock()
                        .unwrap()
                        .values()
                        .find(|r| r.peer == peer && r.receipt.mux_session_id == id)
                        .map(|r| r.summary.clone())
                        .unwrap_or(Value::Null);
                    let record = match m.as_str() {
                        method::SESSION_UPDATE => EventRecord {
                            seq: params
                                .pointer("/_meta/acpmux/seq")
                                .and_then(Value::as_u64)
                                .unwrap_or(0),
                            at: params
                                .pointer("/_meta/acpmux/at")
                                .and_then(Value::as_u64)
                                .unwrap_or_else(now_ms),
                            dir: "in".into(),
                            kind: params
                                .pointer("/update/sessionUpdate")
                                .and_then(Value::as_str)
                                .unwrap_or("session/update")
                                .to_owned(),
                            msg: json!({"jsonrpc": "2.0", "method": method::SESSION_UPDATE, "params": params}),
                            host_seq: None,
                        },
                        method::MUX_EVENT => EventRecord {
                            seq: params.get("seq").and_then(Value::as_u64).unwrap_or(0),
                            at: params.get("at").and_then(Value::as_u64).unwrap_or_else(now_ms),
                            dir: params
                                .get("dir")
                                .and_then(Value::as_str)
                                .unwrap_or("mux")
                                .to_owned(),
                            kind: params
                                .get("kind")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_owned(),
                            msg: params.get("msg").cloned().unwrap_or(Value::Null),
                            host_seq: None,
                        },
                        // A prompt the person must answer, to watchers of this
                        // daemon that did not attach the session (attached
                        // clients derive it from the permission_request event):
                        // the peer's decision nonce and run come with it, so the
                        // app that holds the peer's key can answer
                        // (`hub/person.rs` (c)). Only the peer's own session
                        // in its own run, never one of this daemon's.
                        method::MUX_PERMISSION_PENDING
                            if !self.peer_pending_counts(&peer, &id, &params) =>
                        {
                            tracing::warn!(peer = %peer, session = %id, "a peer's pending prompt for a session or run that is not its own: dropped");
                            return;
                        }
                        method::MUX_PERMISSION_PENDING => EventRecord {
                            seq: params.get("seq").and_then(Value::as_u64).unwrap_or(0),
                            at: now_ms(),
                            dir: "peer".into(),
                            kind: PEER_PERMISSION_PENDING.into(),
                            msg: params.clone(),
                            host_seq: None,
                        },
                        _ => return,
                    };
                    let _ = self.events.send(HubEvent {
                        session_id: id,
                        record,
                        remote: Some(RemoteRef { peer: peer.clone(), summary }),
                    });
                }
            }
        }
    }

    /// Whether peer `peer`'s `_acpmux/permission_pending` for session `id`
    /// may reach this daemon's watchers (`hub/person.rs` (c)): a session the
    /// peer listed as its own and that is not one of this daemon's, in the
    /// daemon run the peer named at its handshake, which is not this run and
    /// no other peer's. A prompt with this daemon's session or run would let
    /// the peer show the person other text for one of this daemon's real
    /// prompts, whose allow the app proves with this daemon's key.
    fn peer_pending_counts(&self, peer: &str, id: &str, params: &Value) -> bool {
        let Some(instance) = params.get("personInstance").and_then(Value::as_str) else {
            return false;
        };
        let listed = self
            .remote_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|r| r.peer == peer && r.receipt.mux_session_id == id);
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).contains_key(id);
        let peers: Vec<_> =
            self.peers.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let named = |p: &crate::peer::Peer| p.person_instance().as_deref() == Some(instance);
        let own_run = peers.iter().any(|p| p.name == peer && named(p));
        let others = peers.iter().any(|p| p.name != peer && named(p));
        listed && !local && own_run && !others && instance != self.person.instance()
    }

    /// Look a key up among peer sessions: exact id, `peer/name`, or a unique name.
    pub fn resolve_remote(&self, key: &str) -> Option<(Arc<crate::peer::Peer>, String, Value)> {
        let map = self.remote_sessions.lock().unwrap();
        let hit = if let Some(r) = map.get(key) {
            Some((r.peer.clone(), r.receipt.mux_session_id.clone(), r.summary.clone()))
        } else {
            let mut matches: Vec<_> = map
                .iter()
                .filter(|(id, r)| {
                    let name = r.summary.get("name").and_then(Value::as_str).unwrap_or("");
                    name == key
                        || r.receipt.mux_session_id.starts_with(key)
                        || id.starts_with(key)
                        || name.strip_prefix(&format!("{}/", r.peer)) == Some(key)
                })
                .map(|(_, r)| (r.peer.clone(), r.receipt.mux_session_id.clone(), r.summary.clone()))
                .collect();
            if matches.len() == 1 { matches.pop() } else { None }
        };
        drop(map);
        let (peer_name, id, summary) = hit?;
        let peer = self.peer(&peer_name)?;
        Some((peer, id, summary))
    }

    /// A remote session was deleted through us: drop it now rather than at
    /// the next reconnect.
    pub fn forget_remote(&self, id: &str) {
        let mut map = self.remote_sessions.lock().unwrap();
        if map.remove(id).is_some() {
            return;
        }
        let key =
            map.iter().find(|(_, r)| r.receipt.mux_session_id == id).map(|(key, _)| key.clone());
        if let Some(key) = key {
            map.remove(&key);
        }
    }

    /// Every peer's sessions, each with its peer's current `peerState` and
    /// whether the row is `stale` (last-known while the peer is down).
    pub fn remote_sessions(&self) -> Vec<Value> {
        let states: HashMap<String, &'static str> = self
            .peers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .map(|p| (p.name.clone(), p.state().as_str()))
            .collect();
        let map = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        map.values()
            .map(|r| {
                let mut summary = r.summary.clone();
                summary["stale"] = Value::Bool(summary["stale"] == true);
                if let Some(state) = states.get(&r.peer) {
                    summary["peerState"] = Value::String((*state).to_owned());
                }
                summary
            })
            .collect()
    }

    /// Every session, local and remote, newest first.
    pub fn all_session_summaries(&self) -> Vec<Value> {
        let mut v: Vec<Value> = self.sessions().iter().map(|s| self.session_summary(s)).collect();
        v.extend(self.remote_sessions());
        // Newest first, ties by sessionId: the order session list pages keep.
        super::session_pages::sort_session_summaries(&mut v);
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn remote_summary_qualifies_the_mux_id_without_changing_legacy_name() {
        let summary = Hub::remote_summary(
            "builder",
            json!({
                "sessionId": "mux-1",
                "agentSessionId": "agent-1",
                "name": "review",
                "sessionReceipt": {
                    "hostId": "local",
                    "muxSessionId": "mux-1",
                    "agentSessionId": "agent-1",
                    "generation": 23,
                },
            }),
        );
        assert_eq!(summary["name"], "builder/review");
        assert_eq!(summary["qualifiedSessionId"], "builder/mux-1");
        assert_eq!(summary["sessionReceipt"]["hostId"], "builder");
        assert_eq!(summary["sessionReceipt"]["generation"], 23);
    }

    /// hq#2509: a peer from before the lane's step and title sends a lane without them;
    /// this daemon decides the lane again so the peer's lanes show a masked step.
    #[test]
    fn a_lane_from_an_older_peer_is_decided_again_with_its_masked_step() {
        let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
        let summary = Hub::remote_summary(
            "builder",
            json!({
                "sessionId": "mux-1",
                "name": "review",
                "status": "running",
                "indicator": "working",
                "turnCount": 1,
                "updatedAt": 9,
                "turn": {"prompt": format!("push {token}"), "startedAt": 5},
                "lane": {"state": "working", "since": 5, "error": null},
            }),
        );
        assert_eq!(summary["lane"]["step"], "push [GitHub Personal Access Token]", "{summary}");
    }
}
