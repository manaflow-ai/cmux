//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

/// How long `peer_add` with `wait` waits for the first connect attempt: an
/// ssh peer may take its ssh connect, tunnel and WebSocket timeouts in turn.
const PEER_SETTLE_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

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
        let peer = crate::peer::Peer::new(
            name,
            url,
            pc.token.clone(),
            pc.peer_token.clone(),
            self.peer_notices.clone(),
        );
        let settled = peer.settled();
        if let Some(old) = self.peers.lock().unwrap().insert(name.to_owned(), peer.clone()) {
            old.stop();
        }
        tokio::spawn(peer.run());
        settled
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
        let mut settled = self.start_peer(name, &pc);
        if wait {
            let _ = tokio::time::timeout(PEER_SETTLE_BUDGET, settled.changed()).await;
        }
        Ok(())
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
        let gone: Vec<String> = {
            let mut map = self.remote_sessions.lock().unwrap();
            let ids: Vec<String> =
                map.iter().filter(|(_, r)| r.peer == name).map(|(id, _)| id.clone()).collect();
            for id in &ids {
                map.remove(id);
            }
            ids
        };
        // Clients watching the list drop these rows.
        for id in gone {
            self.announce_remote(name, json!({"sessionId": id}), "purged");
        }
        let mut cfg = self.config.write().await;
        cfg.peers.remove(name);
        if let Err(e) = cfg.save() {
            tracing::warn!("save config failed: {e}");
        }
        Ok(())
    }

    pub fn peers(&self) -> Vec<Value> {
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
        if let Some(name) = summary.get("name").and_then(Value::as_str)
            && !name.starts_with(&format!("{peer}/"))
        {
            let full = format!("{peer}/{name}");
            summary["name"] = Value::String(full);
        }
        summary["peer"] = Value::String(peer.to_owned());
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

    fn apply_peer_notice(&self, peer: &str, notice: crate::peer::PeerNotice) {
        use crate::peer::PeerNotice;
        let peer = peer.to_owned();
        {
            match notice {
                PeerNotice::Connected => tracing::info!(peer = %peer, "peer ready"),
                PeerNotice::Disconnected(e) => {
                    tracing::warn!(peer = %peer, "peer disconnected: {e}");
                    // Keep the last known list, but flag it.
                    let changed: Vec<Value> = {
                        let mut map = self.remote_sessions.lock().unwrap();
                        map.values_mut()
                            .filter(|r| r.peer == peer)
                            .map(|r| {
                                r.summary["status"] = Value::String("unreachable".into());
                                r.summary.clone()
                            })
                            .collect()
                    };
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
                            if let Some(id) =
                                s.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                            {
                                let summary = Self::remote_summary(&peer, s);
                                if old.remove(&id).as_ref() != Some(&summary) {
                                    changed.push(summary.clone());
                                }
                                map.insert(id, RemoteSession { peer: peer.clone(), summary });
                            }
                        }
                        (changed, old.into_keys().collect::<Vec<_>>())
                    };
                    for summary in changed {
                        self.announce_remote(&peer, summary, "status");
                    }
                    for id in gone {
                        self.announce_remote(&peer, json!({"sessionId": id}), "purged");
                    }
                }
                PeerNotice::SessionChanged { session, kind, seq } => {
                    let Some(id) =
                        session.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        return;
                    };
                    if kind == "purged" {
                        self.remote_sessions.lock().unwrap().remove(&id);
                        let _ = self.events.send(HubEvent {
                            session_id: id,
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
                                summary: json!({"sessionId": session.get("sessionId")}),
                            }),
                        });
                        return;
                    }
                    let summary = Self::remote_summary(&peer, session);
                    self.remote_sessions.lock().unwrap().insert(
                        id.clone(),
                        RemoteSession { peer: peer.clone(), summary: summary.clone() },
                    );
                    let _ = self.events.send(HubEvent {
                        session_id: id,
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
                        .get(&id)
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
                        // permission_pending is derived from the permission_request event locally.
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

    /// Look a key up among peer sessions: exact id, `peer/name`, or a unique name.
    pub fn resolve_remote(&self, key: &str) -> Option<(Arc<crate::peer::Peer>, String, Value)> {
        let map = self.remote_sessions.lock().unwrap();
        let hit = if let Some(r) = map.get(key) {
            Some((r.peer.clone(), key.to_owned(), r.summary.clone()))
        } else {
            let mut matches: Vec<_> = map
                .iter()
                .filter(|(id, r)| {
                    let name = r.summary.get("name").and_then(Value::as_str).unwrap_or("");
                    name == key
                        || id.starts_with(key)
                        || name.strip_prefix(&format!("{}/", r.peer)) == Some(key)
                })
                .map(|(id, r)| (r.peer.clone(), id.clone(), r.summary.clone()))
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
        self.remote_sessions.lock().unwrap().remove(id);
    }

    pub fn remote_sessions(&self) -> Vec<Value> {
        self.remote_sessions.lock().unwrap().values().map(|r| r.summary.clone()).collect()
    }

    /// Every session, local and remote, newest first.
    pub fn all_session_summaries(&self) -> Vec<Value> {
        let mut v: Vec<Value> = self.sessions().iter().map(|s| self.session_summary(s)).collect();
        v.extend(self.remote_sessions());
        v.sort_by(|a, b| {
            b.get("updatedAt")
                .and_then(Value::as_u64)
                .unwrap_or(0)
                .cmp(&a.get("updatedAt").and_then(Value::as_u64).unwrap_or(0))
        });
        v
    }
}
