//! Part of `Hub`; see `hub/mod.rs`.

use super::*;
use crate::session_identity::SessionReceipt;

pub(super) fn session_receipt(summary: &Value) -> Option<SessionReceipt> {
    summary.get("sessionReceipt").and_then(|value| serde_json::from_value(value.clone()).ok())
}

/// How long `peer_add` with `wait` waits for the first connect attempt: an
/// ssh peer may take its ssh connect, tunnel and WebSocket timeouts in turn.
pub(crate) const PEER_SETTLE_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

/// A record that asks a client to answer a prompt: a new one, or one the
/// next daemon adopted with a new decision nonce (`hub/hosts.rs`).
pub(crate) fn is_permission_ask(kind: &str) -> bool {
    matches!(kind, "permission_request" | "permission_reissued")
}

/// Which run of a peer asked an ask (`Hub::peer_ask_run`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PeerAskRun {
    Current,
    Older,
    Forged,
}

/// The record kind of a peer's `_acpmux/permission_pending`, relayed to
/// this daemon's watchers (`server/mod.rs` `deliver`); never stored.
pub(crate) const PEER_PERMISSION_PENDING: &str = "peer_permission_pending";
/// A peer left events out of this daemon's link (`_acpmux/lagged`, `Conn::send`): each client
/// reading one of that peer's chats here reads it again from its last record.
pub(crate) const PEER_LAGGED: &str = "peer_lagged";

/// Removes peer `name`'s rows from `map`, answering their summaries (for the purge notices).
fn take_peer_rows(map: &mut super::remote_rows::RemoteRows, name: &str) -> Vec<Value> {
    let ids: Vec<String> =
        map.iter().filter(|(_, r)| r.peer == name).map(|(id, _)| id.clone()).collect();
    ids.into_iter().filter_map(|id| map.remove(&id).map(|r| r.summary)).collect()
}

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
            let old = self.peers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
            if let Some(old) = old {
                old.stop();
                self.note_peer_removed(&old);
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
        peer.set_vm_boundary(pc.vm_boundary);
        peer.set_github_broker(pc.github_broker);
        let settled = peer.settled();
        // Under the rows lock (lock order: `remote_sessions`, then `peers`): a purge or notice of
        // the instance this replaces, checked current under it (`is_current`), is done before the
        // new one is registered, never after, so it never removes the new one's rows or copies.
        let old = {
            let _rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
            self.peers.lock().unwrap().insert(name.to_owned(), peer.clone())
        };
        if let Some(old) = old {
            old.stop();
            // A reconnect keeps when the peer was last seen.
            peer.seed_last_seen(old.link().last_seen);
        }
        if cached {
            self.load_peer_cache(&peer);
        }
        // Its first state now, and each change after it (`_acpmux/peer_state_changed`).
        peer.report_states(self.peer_states().clone());
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
        self.add_peer_lending(name, url, token, peer_token, None, wait).await
    }

    /// `add_peer`, saying whether this Mac lends the peer its GitHub login (`github_broker.rs`);
    /// None keeps what a re-add of the same machine had. A re-add of the same machine that says
    /// it (Add Machine on a peer added before) keeps the saved tokens it does not name.
    pub async fn add_peer_lending(
        &self,
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        github_broker: Option<bool>,
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
        // The config lock is held through starting the peer: a reload never lands between the
        // save and the start (`reload_saved_peers`).
        let mut cfg = self.config.write().await;
        self.peer_config_gen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let pc = {
            // A re-add of the same machine keeps the VM boundary its config gave it
            // (`vm_boundary.rs`); `peer_add` itself never turns it on.
            let vm_boundary =
                cfg.peers.get(name).is_some_and(|old| old.url == url && old.vm_boundary);
            let same = cfg.peers.get(name).filter(|old| old.url == url);
            let (token, peer_token) = match same {
                Some(old) if github_broker.is_some() => (
                    token.or_else(|| old.token.clone()),
                    peer_token.or_else(|| old.peer_token.clone()),
                ),
                _ => (token, peer_token),
            };
            let github_broker =
                github_broker.unwrap_or_else(|| same.is_some_and(|old| old.github_broker));
            let pc = crate::config::PeerConfig {
                url: url.to_owned(),
                token,
                peer_token,
                vm_boundary,
                github_broker,
            };
            cfg.peers.insert(name.to_owned(), pc.clone());
            if let Err(e) = cfg.save() {
                tracing::warn!("save config failed: {e}");
            }
            pc
        };
        let mut settled = {
            // A saved peer takes the name over from a lease (`peer_lease.rs`),
            // under the lease lock so no notice of the leased peer finds the
            // name unleased first (lock order: `peer_leases`, then `peers`).
            let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            if leases.remove(name).is_some() {
                // The leased machine's peer goes before its rows: a late
                // notice of it then finds it gone, or lands before the purge
                // (`apply_peer_notice` checks under the rows lock). The saved
                // peer lists its own.
                let leased = self.peers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                if let Some(leased) = leased {
                    leased.stop();
                }
                self.purge_peer_rows(name);
            }
            self.start_peer(name, &pc)
        };
        drop(cfg);
        if wait {
            let _ = tokio::time::timeout(PEER_SETTLE_BUDGET, settled.changed()).await;
        }
        Ok(())
    }

    /// A config reload's saved peers' VM boundaries and GitHub lending (`catalog_reload.rs`),
    /// from the file it read (`next`), into the saved config and onto the running peers of
    /// those names at that url; a leased peer keeps its lease's. Called under the config write
    /// lock, which `peer_add` holds through starting its peer, so the two never interleave; a
    /// `peer_add` after the reload began its read (`read_gen`) wins, since the file read may be
    /// from before its save. Lock order: config, `peer_leases`, then `peers`.
    /// The `peer_add` generation a reload starts from, read under the config lock: a
    /// `peer_add` holds the write lock from its count through its save, so this is from wholly
    /// before one (which then counts past it) or after its save (which the file read then sees).
    pub(super) async fn peer_read_gen(&self) -> u64 {
        let _cfg = self.config.read().await;
        self.peer_config_gen.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub(super) fn reload_saved_peers(
        &self,
        current: &mut crate::config::Config,
        next: &std::collections::BTreeMap<String, crate::config::PeerConfig>,
        read_gen: u64,
    ) {
        if self.peer_config_gen.load(std::sync::atomic::Ordering::SeqCst) != read_gen {
            return;
        }
        let leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        for (name, pc) in current.peers.iter_mut() {
            let same = next.get(name).filter(|n| n.url == pc.url);
            pc.vm_boundary = same.is_some_and(|n| n.vm_boundary);
            pc.github_broker = same.is_some_and(|n| n.github_broker);
            if !leases.contains_key(name)
                && let Some(peer) = peers.get(name)
                && peer.url == pc.url
            {
                peer.set_vm_boundary(pc.vm_boundary);
                peer.set_github_broker(pc.github_broker);
            }
        }
    }

    /// `_acpmux/peer_add {name, url, token?, peerToken?, githubBroker?, wait?}`: the unix socket
    /// only (`remote_guard.rs`).
    pub async fn add_peer_from(&self, params: &Value) -> Result<(), RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str);
        let required =
            |k: &str| text(k).ok_or_else(|| RpcError::invalid_params(format!("{k} is required")));
        let (name, url) = (required("name")?, required("url")?);
        let token = text("token").map(str::to_owned);
        let peer_token = text("peerToken").map(str::to_owned);
        let wait = params.get("wait").and_then(Value::as_bool).unwrap_or(false);
        let github_broker = params.get("githubBroker").and_then(Value::as_bool);
        self.add_peer_lending(name, url, token, peer_token, github_broker, wait).await
    }

    /// Reconnect a configured peer now (its daemon was restarted), without
    /// waiting out the reconnect backoff; with `wait`, answer once the
    /// attempt settled.
    pub async fn reconnect_peer(&self, name: &str, wait: bool) -> Result<(), RpcError> {
        self.reconnect_peer_with(name, wait, true).await
    }

    /// ``reconnect_peer``; without `force`, a peer whose link is ready (connected, or `degraded`
    /// because a ping went unanswered) or still in a handshake younger than the handshake deadline
    /// is left alone, so a client that only saw it down, or a send to a slow machine, never cuts
    /// a working link and the requests on it (`peer_disconnected`). A link past that deadline is
    /// replaced (its own deadline drops it then too). The app's picks and sends ask this way; `host reconnect` forces.
    pub async fn reconnect_peer_with(
        &self,
        name: &str,
        wait: bool,
        force: bool,
    ) -> Result<(), RpcError> {
        // Read under the config lock and held through the start: a `peer_add` or reload that
        // changes the peer (its GitHub lending) lands wholly before or after, never between.
        let cfg = self.config.read().await;
        let Some(peer) = cfg.peers.get(name).cloned() else {
            return Err(RpcError::not_found(format!("no peer {name:?}")));
        };
        // A ready link, or a handshake younger than the handshake deadline, is left to finish; with
        // `wait`, an unfinished handshake is waited for as a new attempt would be. Subscribed before
        // the link is read, so a handshake that settles in between is still heard.
        if !force && let Some(running) = self.peer(name) {
            let mut settled = running.settled();
            let link = running.link();
            let young = crate::peer_link::LinkTimings::from_env().handshake;
            if link.keeps_on_reconnect(crate::store::now_ms(), young) {
                drop(cfg);
                if wait && !link.is_ready() {
                    let _ = tokio::time::timeout(PEER_SETTLE_BUDGET, settled.changed()).await;
                }
                return Ok(());
            }
        }
        let mut settled = self.start_peer(name, &peer);
        drop(cfg);
        if wait {
            let _ = tokio::time::timeout(PEER_SETTLE_BUDGET, settled.changed()).await;
        }
        Ok(())
    }

    /// Remove a saved peer. Refused for a leased one: a lease never touches
    /// config.json, and it ends with the connection that holds it
    /// (`peer_lease.rs`).
    pub async fn remove_peer(&self, name: &str) -> Result<(), RpcError> {
        // The config lock first, held through the save: a reconnect (which holds it through its
        // start) never starts the peer again between its stop and its removal from the config,
        // so no peer that still lends GitHub outlives its removal (lock order: config,
        // `peer_leases`, `remote_sessions`, then `peers`).
        let mut cfg = self.config.write().await;
        let gone = {
            // Under the lease lock, so no save of the removed peer's sessions
            // lands after its cache is gone (`save_peer_cache`).
            let leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            if leases.contains_key(name) {
                return Err(RpcError::invalid_params(format!(
                    "{name:?} is a leased peer; it ends when the connection that leased it closes"
                )));
            }
            // Its rows, its cache and its snapshots go under the rows lock it leaves the
            // registry under (lock order: `peer_leases`, `remote_sessions`, then `peers`): a peer
            // added again under the name registers after (`spawn_peer`), and keeps what it lists.
            let mut rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
            let peer = self.peers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
            let Some(peer) = peer else {
                return Err(RpcError::not_found(format!("no peer {name:?}")));
            };
            peer.stop();
            self.note_peer_removed(&peer);
            self.forget_peer_files(name);
            take_peer_rows(&mut rows, name)
        };
        // A late notice of it finds it gone. Clients watching the list drop its rows.
        for summary in gone {
            self.announce_remote(name, summary, "purged");
        }
        cfg.peers.remove(name);
        if let Err(e) = cfg.save() {
            tracing::warn!("save config failed: {e}");
        }
        Ok(())
    }

    /// A peer left for good: watchers hear its last state, `offline` with error `removed`,
    /// unless another instance took its name meanwhile (`peer_states.rs`).
    pub(super) fn note_peer_removed(&self, peer: &crate::peer::Peer) {
        self.peer_states().removed(&peer.name, peer.generation, peer.link().last_seen);
    }

    /// Drop every row of peer `name` and tell watching clients they left.
    pub(super) fn purge_peer_rows(&self, name: &str) {
        let gone = take_peer_rows(&mut self.remote_sessions.lock().unwrap(), name);
        // Clients watching the list drop these rows.
        for summary in gone {
            self.announce_remote(name, summary, "purged");
        }
    }

    pub fn peers(&self) -> Vec<Value> {
        // Read before `peers` is locked (lock order: `peer_leases`, then `peers`).
        let leased: std::collections::HashSet<String> =
            self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        // Released before the rows are counted (lock order: `remote_sessions`,
        // then `peers`; `apply_peer_notice`).
        let (listed, brokers): (Vec<(String, Value)>, std::collections::HashSet<String>) = {
            let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let listed = peers.values().map(|p| (p.name.clone(), p.summary())).collect();
            (listed, peers.values().filter(|p| p.github_broker()).map(|p| p.name.clone()).collect())
        };
        let mut counts: HashMap<String, usize> = HashMap::new();
        for r in self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner()).values() {
            *counts.entry(r.peer.clone()).or_default() += 1;
        }
        let mut v: Vec<Value> = listed
            .into_iter()
            .map(|(name, mut s)| {
                s["sessions"] = json!(counts.get(&name).copied().unwrap_or(0));
                if leased.contains(&name) {
                    s["leased"] = Value::Bool(true);
                }
                if brokers.contains(&name) {
                    s["githubBroker"] = Value::Bool(true);
                }
                s
            })
            .collect();
        v.sort_by_key(|p| p.get("name").and_then(Value::as_str).unwrap_or("").to_owned());
        v
    }

    /// This host's sessions whose agent runs (ready, running or waiting on a
    /// permission); a peer's are not counted (`acpmux peer status`).
    pub fn live_session_count(&self) -> usize {
        self.sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .filter(|s| {
                matches!(
                    s.status(),
                    SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting
                )
            })
            .count()
    }

    /// Whether `generation` is the peer instance registered under `name`.
    /// Called with the rows lock held (lock order: `remote_sessions`, then
    /// `peers`).
    fn is_current(&self, name: &str, generation: u64) -> bool {
        self.peers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(name)
            .is_some_and(|p| p.generation == generation)
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

    /// Prefix a peer session's summary so it reads as `<peer>/<name>`. A display line the peer
    /// put on a pending ask never reaches a client (`drop_display_lines`): every row a peer's
    /// list or `session_changed` adds goes through here.
    pub(super) fn remote_summary(peer: &str, mut summary: Value) -> Value {
        super::drop_display_lines(&mut summary);
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
            record: Arc::new(EventRecord {
                seq: 0,
                at: now_ms(),
                dir: "peer".into(),
                kind: kind.into(),
                msg: Value::Null,
                host_seq: None,
            }),
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
            self.apply_peer_notice(&peer, generation, notice);
            if settles {
                current.mark_settled();
                self.watches.peer_settled();
            }
        }
    }

    pub(super) fn apply_peer_notice(
        &self,
        peer: &str,
        generation: u64,
        notice: crate::peer::PeerNotice,
    ) {
        // `peer_notice_loop` checked the instance without the rows lock: a
        // peer replaced or removed since (`add_peer`, `remove_peer`,
        // `end_peer_lease`, each of which unregisters the peer before it
        // drops its rows) must not add rows back or save them. So every path
        // that changes rows checks again under the rows lock.
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
                        if !self.is_current(&peer, generation) {
                            return;
                        }
                        self.with_tombstones(&peer, generation, |t| t.link_ended());
                        map.mark_peer_stale(&peer, link.last_seen)
                    };
                    if !changed.is_empty() {
                        self.save_peer_cache(&peer, generation, true);
                    }
                    // What its chats streamed in the last seconds is kept now (`peer_snapshot.rs`).
                    self.peer_snapshots.flush(Some(&peer));
                    for summary in changed {
                        self.announce_remote(&peer, summary, "status");
                    }
                }
                PeerNotice::Sessions(list) => {
                    // The list can land after clients took their snapshot (an
                    // ssh tunnel is slow to open), so tell watchers what changed.
                    let (changed, gone) = {
                        let mut map = self.remote_sessions.lock().unwrap();
                        if !self.is_current(&peer, generation) {
                            return;
                        }
                        // Read before a purge this link already brought (`purge_tombstones.rs`).
                        let purged = self.with_tombstones(&peer, generation, |t| t.take());
                        let purged = purged.unwrap_or_default();
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
                            if purged.contains(&receipt.mux_session_id) {
                                continue;
                            }
                            let id = receipt.qualified_id();
                            if old.remove(&id).as_ref() != Some(&summary) {
                                changed.push(summary.clone());
                            }
                            map.insert(id, RemoteSession { peer: peer.clone(), summary, receipt });
                        }
                        // Which generation of each session is current (`peer_snapshot.rs`), sent
                        // before the lock goes: a page asked of a row read after it comes after it.
                        let created =
                            |r: &RemoteSession| r.summary.get("createdAt").and_then(Value::as_u64);
                        let listed = map.values().filter(|r| r.peer == peer);
                        let listed = listed.map(|r| (r.receipt.mux_session_id.clone(), created(r)));
                        self.peer_snapshots.listed(&peer, listed.collect(), true);
                        (changed, old.into_values().collect::<Vec<_>>())
                    };
                    self.save_peer_cache(&peer, generation, true);
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
                            if !self.is_current(&peer, generation) {
                                return;
                            }
                            // An older list of this link must not bring it back.
                            self.with_tombstones(&peer, generation, |t| t.purged(&mux_id));
                            let key = map
                                .iter()
                                .find(|(_, r)| r.peer == peer && r.receipt.mux_session_id == mux_id)
                                .map(|(key, _)| key.clone());
                            let removed = key.and_then(|key| map.remove(&key).map(|r| r.summary));
                            // The generation the purge names (else the row's) goes from the
                            // snapshots too (`peer_snapshot.rs`), before the lock does.
                            let created = |s: &Value| s.get("createdAt").and_then(Value::as_u64);
                            let purged = created(&session).or(removed.as_ref().and_then(created));
                            self.peer_snapshots.gone(&peer, &mux_id, purged);
                            removed
                        };
                        self.save_peer_cache(&peer, generation, false);
                        let _ = self.events.send(HubEvent {
                            session_id: mux_id.clone(),
                            record: Arc::new(EventRecord {
                                seq,
                                at: now_ms(),
                                dir: "peer".into(),
                                kind,
                                msg: Value::Null,
                                host_seq: None,
                            }),
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
                        if !self.is_current(&peer, generation) {
                            return;
                        }
                        self.with_tombstones(&peer, generation, |t| t.changed(&mux_id));
                        let old_id = map
                            .iter()
                            .find(|(_, r)| r.peer == peer && r.receipt.mux_session_id == mux_id)
                            .map(|(key, _)| key.clone());
                        if let Some(old_id) = old_id {
                            map.take(&old_id);
                        }
                        map.insert(
                            id.clone(),
                            RemoteSession { peer: peer.clone(), summary: summary.clone(), receipt },
                        );
                        let created = summary.get("createdAt").and_then(Value::as_u64);
                        self.peer_snapshots.listed(&peer, vec![(mux_id.clone(), created)], false);
                    }
                    self.save_peer_cache(&peer, generation, false);
                    let _ = self.events.send(HubEvent {
                        session_id: mux_id,
                        record: Arc::new(EventRecord {
                            seq,
                            at: now_ms(),
                            dir: "peer".into(),
                            kind,
                            msg: Value::Null,
                            host_seq: None,
                        }),
                        remote: Some(RemoteRef { peer: peer.clone(), summary }),
                    });
                }
                // A prompt this daemon forwarded was taken (`outbox.rs` `PeerAccepts`).
                PeerNotice::Notification { method: m, params, .. }
                    if m == method::MUX_PROMPT_ACCEPTED =>
                {
                    self.peer_accepts.accepted(&peer, &params);
                }
                PeerNotice::Notification { method: m, params, link } if m == "_acpmux/lagged" => {
                    // This link's live records have a hole now: none of it is kept until a page
                    // (`peer_snapshot.rs`). A copy a later link's page joined is not this link's.
                    self.peer_snapshots.lagged(&peer, (generation, link));
                    let ids: Vec<String> = self
                        .remote_sessions
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .values()
                        .filter(|r| r.peer == peer)
                        .map(|r| r.receipt.mux_session_id.clone())
                        .collect();
                    for id in ids {
                        let _ = self.events.send(HubEvent {
                            session_id: id,
                            record: Arc::new(EventRecord {
                                seq: 0,
                                at: now_ms(),
                                dir: "peer".into(),
                                kind: PEER_LAGGED.into(),
                                msg: params.clone(),
                                host_seq: None,
                            }),
                            remote: Some(RemoteRef { peer: peer.clone(), summary: Value::Null }),
                        });
                    }
                }
                PeerNotice::Notification { method: m, mut params, link } => {
                    let Some(id) =
                        params.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        return;
                    };
                    // No display line of the peer's own reaches a client (`drop_display_lines`).
                    super::drop_display_lines(&mut params);
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
                        // A record of the peer's session; an ask in it reaches
                        // an attached client as `_acpmux/permission_pending`
                        // (`server/mod.rs` `deliver`), so the same rule.
                        method::MUX_EVENT => {
                            let record = EventRecord {
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
                            };
                            if !self.peer_record_counts(&peer, &id, &record.kind, &record.msg) {
                                tracing::warn!(peer = %peer, session = %id, "a peer's ask for a session or run that is not its own: dropped");
                                return;
                            }
                            record
                        }
                        // A prompt the person must answer, to watchers of this
                        // daemon that did not attach the session (attached
                        // clients derive it from the permission_request event):
                        // the peer's decision nonce and run come with it, so the
                        // app that holds the peer's key can answer
                        // (`hub/person.rs` (c)). Only the peer's own session
                        // in its own run, never one of this daemon's.
                        method::MUX_PERMISSION_PENDING
                            if !self.peer_ask_counts(&peer, &id, &params) =>
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
                    self.capture_peer_record((&peer, generation, link), &id, &summary, &record);
                    let _ = self.events.send(HubEvent {
                        session_id: id,
                        record: Arc::new(record),
                        remote: Some(RemoteRef { peer: peer.clone(), summary }),
                    });
                }
            }
        }
    }

    /// Whether peer `peer` may put `ask`, a pending ask for session `id`,
    /// before this daemon's clients (`hub/person.rs` (c)): a session the peer
    /// listed as its own and that is not one of this daemon's, in the daemon
    /// run the ask names (`personInstance`), which is the run the peer named
    /// at its handshake, not this run and no other peer's. A prompt with this
    /// daemon's session or run would let the peer show the person other text
    /// for one of this daemon's real prompts, whose allow the app proves with
    /// this daemon's key. The one rule for every path a peer's asks take: its
    /// `_acpmux/permission_pending` to watchers and its live `_acpmux/event`
    /// records (above, through `peer_record_counts`), and the pending entries
    /// and records of a forwarded reply (`server/peer_forward.rs`
    /// `strip_asks`). An ask that fails is dropped; the session stays
    /// readable.
    pub fn peer_ask_counts(&self, peer: &str, id: &str, ask: &Value) -> bool {
        self.peer_ask_run(peer, id, ask) == PeerAskRun::Current
    }

    /// Which run of peer `peer` asked `ask` for its session `id`: the one it
    /// named at its handshake (`Current`, what `peer_ask_counts` lets
    /// through), an older one of its own (`Older`: a run before the peer
    /// restarted, or none named), or not its own to show (`Forged`: a
    /// session it never listed or one of this daemon's, this daemon's run,
    /// or the run another connected peer named).
    fn peer_ask_run(&self, peer: &str, id: &str, ask: &Value) -> PeerAskRun {
        let instance = ask.get("personInstance").and_then(Value::as_str);
        let listed = self
            .remote_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|r| r.peer == peer && r.receipt.mux_session_id == id);
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).contains_key(id);
        if !listed || local {
            return PeerAskRun::Forged;
        }
        let Some(instance) = instance else { return PeerAskRun::Older };
        if instance == self.person.instance() {
            return PeerAskRun::Forged;
        }
        let peers: Vec<_> =
            self.peers.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let named = |p: &crate::peer::Peer| p.person_instance().as_deref() == Some(instance);
        if peers.iter().any(|p| p.name != peer && named(p)) {
            return PeerAskRun::Forged;
        }
        if peers.iter().any(|p| p.name == peer && named(p)) {
            PeerAskRun::Current
        } else {
            PeerAskRun::Older
        }
    }

    /// Whether an ask record's `msg` that peer `peer` sends in the history of
    /// its session `id` (the `events` of a forwarded `_acpmux/attach` or
    /// `_acpmux/events`) may stay. An ask in the run the peer named at its
    /// handshake stays whole. Its own ask from an older run (it restarted
    /// since: each run has its own `personInstance`, `permissions.rs`) stays
    /// as history without its `decisionNonce`, so the chat still draws what
    /// was asked and answered, while no app keeps a decision context for it
    /// (`AcpmuxDecisionContexts` needs the nonce) and no allow can be proven
    /// over it; that run's daemon is gone and answers nothing. A forged one
    /// (`peer_ask_run`) is dropped. Pending lists and live records keep the
    /// strict rule (`peer_ask_counts`).
    pub fn peer_history_ask_counts(&self, peer: &str, id: &str, ask: &mut Value) -> bool {
        match self.peer_ask_run(peer, id, ask) {
            PeerAskRun::Current => true,
            PeerAskRun::Forged => false,
            PeerAskRun::Older => {
                if let Some(ask) = ask.as_object_mut() {
                    ask.remove("decisionNonce");
                }
                true
            }
        }
    }

    /// Whether a record of kind `kind` with `msg` that peer `peer` sends for
    /// its session `id` may reach this daemon's clients: any record but an
    /// ask (`is_permission_ask`, in any `dir`) that fails `peer_ask_counts`.
    pub fn peer_record_counts(&self, peer: &str, id: &str, kind: &str, msg: &Value) -> bool {
        !is_permission_ask(kind) || self.peer_ask_counts(peer, id, msg)
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

    /// Peer `peer`'s session `mux` was deleted through us: drop it now rather than at the next
    /// reconnect. `generation` is the one the row named when the purge was asked: a session
    /// recreated since keeps its row, and only that generation's event snapshot goes. None (a row
    /// that names no generation) removes only such a row, never one of a generation. `instance`
    /// is the peer the purge went to: one replaced since (another machine under the name) keeps
    /// its rows and copies.
    pub fn forget_remote(&self, (peer, instance): (&str, u64), mux: &str, generation: Option<u64>) {
        let mut map = self.remote_sessions.lock().unwrap();
        if !self.is_current(peer, instance) {
            return;
        }
        let created = |r: &RemoteSession| r.summary.get("createdAt").and_then(Value::as_u64);
        let key = map
            .iter()
            .find(|(_, r)| r.peer == peer && r.receipt.mux_session_id == mux)
            .filter(|(_, r)| created(r) == generation)
            .map(|(key, _)| key.clone());
        let removed = key.and_then(|key| map.take(&key));
        // Its event snapshot goes with it (`peer_snapshot.rs`), before the lock does. A purge that
        // names no generation and found no such row removes no copy of another.
        if generation.is_some() || removed.is_some() {
            self.peer_snapshots.gone(peer, mux, generation);
        }
    }

    /// Every peer's sessions, each with its peer's current `peerState` and
    /// whether the row is `stale` (last-known while the peer is down).
    pub fn remote_sessions(&self) -> Vec<Value> {
        self.remote_rows(|_| true)
    }

    /// [`Self::remote_sessions`] of the rows `keep` takes, cloning no other.
    fn remote_rows(&self, keep: impl Fn(&Value) -> bool) -> Vec<Value> {
        let mut rows = Vec::new();
        self.visit_remote_rows(keep, |row| rows.push(row));
        rows
    }

    /// Capture immutable row handles under the lock, then normalize and visit outside it.
    fn visit_remote_rows(&self, keep: impl Fn(&Value) -> bool, mut visit: impl FnMut(Value)) {
        let states: HashMap<String, &'static str> = self
            .peers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .map(|p| (p.name.clone(), p.state().as_str()))
            .collect();
        let rows: Vec<_> = self
            .remote_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .filter(|r| keep(&r.summary))
            .cloned()
            .collect();
        for r in rows {
            let mut summary = r.summary.clone();
            summary["stale"] = Value::Bool(summary["stale"] == true);
            if let Some(state) = states.get(&r.peer) {
                summary["peerState"] = Value::String((*state).to_owned());
            }
            visit(summary);
        }
    }

    /// Each summary once, local before remote, without retaining the JSON trees.
    pub(super) fn visit_session_summaries(&self, mut visit: impl FnMut(Value)) {
        for session in self.sessions() {
            visit(self.session_summary(&session));
        }
        self.visit_remote_rows(|_| true, visit);
    }

    /// Every session, local and remote, newest first.
    pub fn all_session_summaries(&self) -> Vec<Value> {
        let mut v: Vec<Value> = self.sessions().iter().map(|s| self.session_summary(s)).collect();
        v.extend(self.remote_sessions());
        // Newest first, ties by sessionId: the order session list pages keep.
        super::session_pages::sort_session_summaries(&mut v);
        v
    }

    /// For each of `ids`, the row [`Self::all_session_summaries`] puts first for that
    /// `sessionId` (the newest; at one time, a local chat's before a peer's), without
    /// summarizing any other chat: a wait reads them on every record (`server/wait.rs`),
    /// and summarizing all 460 chats there kept huge-blue's daemon at 6 to 8 cores and
    /// 4.5 GB (2026-10-22), and cosmic-gray's at 2 to 3 cores (2026-10-25).
    pub fn session_summaries_of(&self, ids: &[String]) -> HashMap<String, Value> {
        let local: Vec<Arc<Session>> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            ids.iter().filter_map(|id| sessions.get(id).cloned()).collect()
        };
        let mut rows: Vec<Value> = local.iter().map(|s| self.session_summary(s)).collect();
        rows.extend(self.remote_rows(|v| {
            v.get("sessionId").and_then(Value::as_str).is_some_and(|id| ids.iter().any(|w| w == id))
        }));
        // The same stable sort over the same relative order as the full list, so a local
        // chat and a peer's (or two peers') that share a bare id resolve to the same row.
        super::session_pages::sort_session_summaries(&mut rows);
        let mut out = HashMap::new();
        for row in rows {
            if let Some(id) = row.get("sessionId").and_then(Value::as_str) {
                out.entry(id.to_owned()).or_insert(row);
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Reviews of #24797 at d703168 and 828f855: a reload applied the lending it read to
    /// whatever peer had the name by then, and a reload whose file read came before a
    /// `peer_add` brought back what that add took away.
    #[tokio::test]
    async fn a_reload_lends_only_to_the_machine_and_the_add_it_read() {
        use crate::config::PeerConfig;
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let url = "ws://127.0.0.1:9/m";
        let lent = |url: &str| PeerConfig {
            url: url.into(),
            token: None,
            peer_token: None,
            vm_boundary: true,
            github_broker: true,
        };
        let file = |pc: PeerConfig| std::collections::BTreeMap::from([("m".to_owned(), pc)]);
        let peer = || hub.peers.lock().unwrap().get("m").cloned().unwrap();
        let reload = |next: std::collections::BTreeMap<String, PeerConfig>, read: u64| {
            let hub = &hub;
            async move {
                let mut current = hub.config.write().await;
                hub.reload_saved_peers(&mut current, &next, read);
            }
        };
        hub.add_peer_lending("m", url, None, None, Some(false), false).await.unwrap();

        // The file names `m` at another url: neither the saved peer nor the running one lends.
        let read = hub.peer_read_gen().await;
        reload(file(lent("ws://127.0.0.1:9/other")), read).await;
        assert!(!peer().github_broker() && !peer().vm_boundary(), "read for another machine");

        // The reload read the file, then `peer_add` took lending away (same url): it holds.
        let read = hub.peer_read_gen().await;
        hub.add_peer_lending("m", url, None, None, Some(false), false).await.unwrap();
        reload(file(lent(url)), read).await;
        assert!(!peer().github_broker(), "a later add takes it away for good");
        assert!(!hub.config.read().await.peers["m"].github_broker);

        // A reload with nothing between its read and its apply turns it on.
        let read = hub.peer_read_gen().await;
        reload(file(lent(url)), read).await;
        assert!(peer().github_broker() && peer().vm_boundary(), "read for this machine");
        assert!(hub.config.read().await.peers["m"].github_broker);
        peer().stop();
    }

    /// Review of #24797 at b93f3a3: a reload read the add count outside the config lock (so
    /// mid-add, before its save), and a reconnect started a peer from a config read it had let
    /// go. Both now wait for a change in progress and see what it saved.
    #[tokio::test]
    async fn a_reload_or_reconnect_waits_for_a_peer_change_in_progress() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let url = "ws://127.0.0.1:9/m";
        hub.add_peer_lending("m", url, None, None, Some(true), false).await.unwrap();
        let wait = std::time::Duration::from_millis(200);

        // A change in progress: counted, not yet saved (what `peer_add` does under the lock).
        let mut held = hub.config.write().await;
        hub.peer_config_gen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let read = tokio::time::timeout(wait, hub.peer_read_gen()).await;
        assert!(read.is_err(), "the count is not read mid-change");
        let reconnect = tokio::time::timeout(wait, hub.reconnect_peer("m", false)).await;
        assert!(reconnect.is_err(), "no peer starts from a config mid-change");
        held.peers.get_mut("m").unwrap().github_broker = false;
        drop(held);

        hub.reconnect_peer("m", false).await.unwrap();
        let peer = hub.peers.lock().unwrap().get("m").cloned().unwrap();
        assert!(!peer.github_broker(), "the reconnect started what the change saved");
        peer.stop();
    }

    /// Review of #24797 at 30e24d1: a removal stopped the live peer before it took the config
    /// lock, so a reconnect holding that lock started it again, still lending GitHub, after the
    /// removal said it was gone. The removal now waits for the reconnect, and its stop is last.
    #[tokio::test]
    async fn a_removed_peer_is_never_started_again_by_a_reconnect_in_progress() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        hub.add_peer_lending("m", "ws://127.0.0.1:9/m", None, None, Some(true), false)
            .await
            .unwrap();

        // A reconnect in progress: it read the config and holds it through its start.
        let held = hub.config.read().await;
        let removing = {
            let hub = hub.clone();
            tokio::spawn(async move { hub.remove_peer("m").await })
        };
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(!removing.is_finished(), "the removal waits for the reconnect");
        assert!(hub.peers.lock().unwrap().contains_key("m"), "and stops nothing before it");
        let restarted = hub.start_peer("m", &held.peers["m"]);
        drop((held, restarted));

        removing.await.unwrap().unwrap();
        assert!(!hub.peers.lock().unwrap().contains_key("m"), "no peer outlives its removal");
        assert!(!hub.config.read().await.peers.contains_key("m"));
    }

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

    #[test]
    fn streamed_remote_rows_release_the_lock_and_keep_the_captured_versions() {
        let hub = Hub::new(
            crate::config::Config::default(),
            Box::new(crate::store::MemoryStore::default()),
        );
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("builder", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("builder".into(), peer.clone());
        let rows = (0..3).map(|i| json!({"sessionId": format!("r{i}"), "status": "closed", "updatedAt": i, "tools": [{"id": "kept"}]})).collect();
        hub.apply_peer_notice("builder", peer.generation, crate::peer::PeerNotice::Sessions(rows));
        let expected = hub.all_session_summaries();
        let mut actual = Vec::new();
        hub.visit_session_summaries(|row| {
            // A writer can remove rows during serialization without changing this snapshot.
            let mut rows = hub.remote_sessions.try_lock().expect("visitor must not hold row lock");
            let captured: Vec<_> = rows.iter().map(|(id, row)| (id.clone(), row.clone())).collect();
            for (id, captured) in captured {
                let writes = rows.writes;
                let removed = rows.take(&id).unwrap();
                assert!(Arc::ptr_eq(&removed, &captured), "discard must not deep-clone a row");
                assert_eq!(rows.writes, writes + 1);
                assert!(rows.get(&id).is_none());
            }
            actual.push(row);
        });
        super::super::session_pages::sort_session_summaries(&mut actual);
        assert_eq!(actual, expected);
        assert_eq!(actual.len(), 3);
        assert!(hub.remote_sessions.lock().unwrap().is_empty());
    }

    /// A wait reads the row the full list puts first for each id: a peer's newer chat
    /// over a local one with the same bare id, and the newer of two peers' rows.
    #[test]
    fn summaries_of_some_ids_are_the_rows_the_full_list_puts_first() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        for (id, at) in [("x", 10u64), ("solo", 30)] {
            let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": id, "harness": "claude",
                              "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": at});
            store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        }
        let hub = Hub::new(cfg, store);
        let row = |id: &str, status: &str, at: u64| json!({"sessionId": id, "name": format!("lane-{id}"), "status": status, "turnCount": 1, "updatedAt": at});
        for (peer, rows) in [
            ("builder", vec![row("x", "running", 20), row("y", "waiting", 7)]),
            ("other", vec![row("x", "idle", 5), row("y", "idle", 9)]),
        ] {
            let (tx, _rx) = tokio::sync::mpsc::channel(8);
            let p = crate::peer::Peer::new(peer, "ws://127.0.0.1:9", None, None, tx);
            hub.peers.lock().unwrap().insert(peer.to_owned(), p.clone());
            hub.apply_peer_notice(peer, p.generation, crate::peer::PeerNotice::Sessions(rows));
        }
        let ids: Vec<String> = ["x", "y", "solo", "none", "x"].map(str::to_owned).to_vec();
        let all = hub.all_session_summaries();
        let mut streamed = Vec::new();
        hub.visit_session_summaries(|row| streamed.push(row));
        super::super::session_pages::sort_session_summaries(&mut streamed);
        assert_eq!(streamed, all, "local and normalized remote summaries agree");
        let some = hub.session_summaries_of(&ids);
        for id in &ids {
            let first = all.iter().find(|s| s["sessionId"] == id.as_str());
            assert_eq!(some.get(id), first, "{id}: {some:?}");
        }
        assert_eq!(some["x"]["peer"], "builder", "the newer peer row, not the local chat");
        assert_eq!(some["x"]["status"], "running");
        assert_eq!(some["y"]["peer"], "other", "the newer of two peer rows");
        assert!(some["solo"].get("peer").is_none(), "{:?}", some["solo"]);
        assert_eq!(some.len(), 3, "{some:?}");
    }
}
