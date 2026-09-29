//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // ------------------------------------------------------------- peers

    pub(super) fn start_peer(&self, name: &str, url: &str, token: Option<String>) {
        let peer = crate::peer::Peer::new(name, url, token, self.peer_notices.clone());
        if let Some(old) = self.peers.lock().unwrap().insert(name.to_owned(), peer.clone()) {
            old.stop();
        }
        tokio::spawn(peer.run());
    }

    pub async fn add_peer(
        &self,
        name: &str,
        url: &str,
        token: Option<String>,
    ) -> Result<(), RpcError> {
        crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
        if !(url.starts_with("ws://") || url.starts_with("wss://") || url.starts_with("ssh://")) {
            return Err(RpcError::invalid_params(
                "peer url must start with ws://, wss://, or ssh://host",
            ));
        }
        {
            let mut cfg = self.config.write().await;
            cfg.peers.insert(
                name.to_owned(),
                crate::config::PeerConfig { url: url.to_owned(), token: token.clone() },
            );
            if let Err(e) = cfg.save() {
                tracing::warn!("save config failed: {e}");
            }
        }
        self.start_peer(name, url, token);
        Ok(())
    }

    pub async fn remove_peer(&self, name: &str) -> Result<(), RpcError> {
        let peer = self.peers.lock().unwrap().remove(name);
        let Some(peer) = peer else {
            return Err(RpcError::not_found(format!("no peer {name:?}")));
        };
        peer.stop();
        self.remote_sessions.lock().unwrap().retain(|_, r| r.peer != name);
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

    pub(super) async fn peer_notice_loop(self: Arc<Self>) {
        let Some(mut rx) = self.peer_notices_rx.lock().await.take() else { return };
        use crate::peer::PeerNotice;
        while let Some((peer, notice)) = rx.recv().await {
            match notice {
                PeerNotice::Connected => tracing::info!(peer = %peer, "peer ready"),
                PeerNotice::Disconnected(e) => {
                    tracing::warn!(peer = %peer, "peer disconnected: {e}");
                    // Keep the last known list, but flag it.
                    let mut map = self.remote_sessions.lock().unwrap();
                    for r in map.values_mut().filter(|r| r.peer == peer) {
                        r.summary["status"] = Value::String("unreachable".into());
                    }
                }
                PeerNotice::Sessions(list) => {
                    let mut map = self.remote_sessions.lock().unwrap();
                    map.retain(|_, r| r.peer != peer);
                    for s in list {
                        if let Some(id) = s.get("sessionId").and_then(Value::as_str) {
                            map.insert(
                                id.to_owned(),
                                RemoteSession {
                                    peer: peer.clone(),
                                    summary: Self::remote_summary(&peer, s.clone()),
                                },
                            );
                        }
                    }
                }
                PeerNotice::SessionChanged { session, kind, seq } => {
                    let Some(id) =
                        session.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        continue;
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
                            },
                            remote: Some(RemoteRef {
                                peer: peer.clone(),
                                summary: json!({"sessionId": session.get("sessionId")}),
                            }),
                        });
                        continue;
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
                        },
                        remote: Some(RemoteRef { peer: peer.clone(), summary }),
                    });
                }
                PeerNotice::Notification { method: m, params } => {
                    let Some(id) =
                        params.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        continue;
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
                        },
                        // permission_pending is derived from the permission_request event locally.
                        _ => continue,
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
