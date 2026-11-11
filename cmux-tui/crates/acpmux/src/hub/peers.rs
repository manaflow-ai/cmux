//! Part of `Hub`; see `hub/mod.rs`.

use super::*;
use crate::session_identity::SessionReceipt;
use cmux_json::JsonSet as _;

// Shared-lock rule: `peers` may be held while taking the rows writer lock (`remote_sessions`
// `write`/`fence`/`settled`; `peers` → rows), but never the reverse. A rows `read` takes no lock
// (`remote_table.rs`). Look up an Arc briefly before taking `peer_leases` or a per-peer writer gate,
// and no disk or JSON work runs under any shared lock.

#[cfg(test)]
pub(crate) struct PeerNoticeProjectionHook {
    reached: (StdMutex<bool>, std::sync::Condvar),
    released: (StdMutex<bool>, std::sync::Condvar),
}

#[cfg(test)]
impl PeerNoticeProjectionHook {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            reached: (StdMutex::new(false), std::sync::Condvar::new()),
            released: (StdMutex::new(false), std::sync::Condvar::new()),
        })
    }

    pub(crate) fn wait_reached(&self) {
        let mut reached = self.reached.0.lock().unwrap_or_else(|e| e.into_inner());
        while !*reached {
            reached = self.reached.1.wait(reached).unwrap_or_else(|e| e.into_inner());
        }
    }

    pub(crate) fn wait_reached_timeout(&self, timeout: std::time::Duration) -> bool {
        let reached = self.reached.0.lock().unwrap_or_else(|e| e.into_inner());
        let (reached, _) = self
            .reached
            .1
            .wait_timeout_while(reached, timeout, |reached| !*reached)
            .unwrap_or_else(|e| e.into_inner());
        *reached
    }

    pub(crate) fn release(&self) {
        *self.released.0.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.released.1.notify_all();
    }

    pub(crate) fn pause(&self) {
        *self.reached.0.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.reached.1.notify_all();
        let mut released = self.released.0.lock().unwrap_or_else(|e| e.into_inner());
        while !*released {
            released = self.released.1.wait(released).unwrap_or_else(|e| e.into_inner());
        }
    }
}

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
    /// A session the peer has not listed (yet) and that is not one of this
    /// daemon's: forged unless the peer lists it later (`held_asks.rs`).
    Unlisted,
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
    map.take_peer(name).into_iter().map(|(_, r)| Arc::unwrap_or_clone(r).summary).collect()
}

/// The mux ids of rows removed locally. A full-list projection that was already in progress
/// must skip these ids when it retries after the purge's row epoch changes.
fn removed_mux_ids(rows: &[Value]) -> impl Iterator<Item = String> + '_ {
    rows.iter().filter_map(|summary| {
        session_receipt(summary)
            .map(|receipt| receipt.mux_session_id)
            .or_else(|| summary.get("sessionId").and_then(Value::as_str).map(str::to_owned))
    })
}

impl Hub {
    #[cfg(test)]
    fn pause_after_peer_session_projection_for_test(&self) {
        let hook =
            self.peer_notice_projection_hook.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(hook) = hook {
            hook.pause();
        }
    }

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
        if let Some(transport) = &self.wireguard
            && let Some(configured) = &pc.wireguard
            && let Some(address) = transport.route_for(name, configured)
        {
            peer.set_wireguard(transport.clone(), address);
        }
        #[cfg(feature = "hub-carrier")]
        peer.set_hub_carrier(
            self.hub_carrier.clone(),
            pc.wireguard.as_ref().map(|configured| configured.public_key.clone()),
        );
        // The cmux link's `acpmux` service, when this peer is one of its paired installs.
        if let Some(host) = pc.link_host.clone().or_else(|| {
            pc.wireguard.as_ref().and_then(|wg| crate::peer::paired_install(&wg.public_key))
        }) {
            peer.set_link_host(host);
        }
        peer.set_last_good(self.peer_paths.clone());
        // A plain ssh machine found to be a paired install on an earlier run keeps the cmux
        // link as its backup path (`peer_overlay.rs`), before its first dial.
        peer.set_explicit_route(pc.names_route());
        peer.recall_overlay();
        peer.set_vm_boundary(pc.vm_boundary);
        peer.set_github_broker(pc.github_broker);
        peer.set_github_app(self.github_app.clone());
        let settled = peer.settled();
        // Register under the peer lock and the rows writer lock (lock order: `peers`, then
        // `remote_sessions`): a purge or notice of the instance this replaces, checked current
        // under them, is done before the new one is registered, never after.
        let old = {
            let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let _rows = self.remote_sessions.fence();
            let old = peers.get(name).cloned();
            if let Some(old) = &old {
                // Fence grace timers before the replacement becomes visible under this name.
                old.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
            }
            peers.insert(name.to_owned(), peer.clone());
            old
        };
        if let Some(old) = old {
            old.stop();
            // A reconnect keeps when the peer was last seen.
            peer.seed_last_seen(old.link().last_seen);
            // And the remote tokens it read, so its first connect is one ssh login.
            peer.carry_read_tokens(&old);
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
    /// most `PEER_SETTLE_BUDGET` later, so the caller's listing is real, with
    /// what the wait saw ([`Self::wait_for_peer`]); without it, Null.
    /// `peer_token`: the peer's peer token (`server/peer_auth.rs`) for a
    /// `ws://` peer; without it that peer serves this daemon as Web.
    pub async fn add_peer(
        &self,
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        wait: bool,
    ) -> Result<Value, RpcError> {
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
    ) -> Result<Value, RpcError> {
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
                link_host: None,
                wireguard: same.and_then(|old| old.wireguard.clone()),
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
            // name unleased first (lock order: `peer_leases`, then `peers`, then rows).
            let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            if leases.remove(name).is_some() {
                // The leased machine's peer goes before its rows: a late
                // notice of it then finds it gone, or lands before the purge
                // (`apply_peer_notice` checks while holding peers then rows). The saved
                // peer lists its own.
                let leased = self.peers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                if let Some(leased) = leased {
                    leased.stop();
                }
                // The lease lock is held here and this peer has no cache. Avoid taking the
                // per-peer writer, whose workers take the lease lock while saving.
                let gone = take_peer_rows(&mut self.remote_sessions.write(), name);
                for summary in gone {
                    self.announce_remote(name, summary, "purged");
                }
            }
            self.start_peer(name, &pc)
        };
        drop(cfg);
        if !wait {
            return Ok(Value::Null);
        }
        Ok(self.wait_for_peer(name, &mut settled, PEER_SETTLE_BUDGET).await)
    }

    /// What a `wait` saw of peer `name`'s connect attempt (`peer_add`, `peer_reconnect`,
    /// `peer_lease`): whether it settled within `budget`, how long it waited, and the peer as
    /// it is then, its state and last error with it. Before, a wait that ran out answered a
    /// plain OK, the peer read `error: null` while its handshake went on, and the handshake's
    /// failure came after nobody was asking (a peer link's 90 s handshake, 2026-10-30).
    pub(crate) async fn wait_for_peer(
        &self,
        name: &str,
        settled: &mut tokio::sync::watch::Receiver<u64>,
        budget: std::time::Duration,
    ) -> Value {
        let started = tokio::time::Instant::now();
        // A peer that never ran (refused at its start) or was removed meanwhile dropped its
        // sender: no attempt settled, and the wait did not run out either (`stopped`).
        let (done, stopped) = match tokio::time::timeout(budget, settled.changed()).await {
            Ok(Ok(())) => (true, false),
            Ok(Err(_)) => (false, true),
            Err(_) => (false, false),
        };
        let peer = self.peer(name).map(|p| p.summary()).unwrap_or(Value::Null);
        if stopped {
            tracing::warn!(peer = %name, "it stopped before its connect attempt settled");
        } else if !done {
            tracing::warn!(peer = %name, state = %peer.get("state").unwrap_or(&serde_json::Value::Null), "its connect attempt had not settled after {}s; answering with how it is now", budget.as_secs());
        }
        let waited = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        let mut wait = json!({"settled": done, "waitedMs": waited, "peer": peer});
        if stopped {
            wait.set("stopped", Value::Bool(true));
        }
        wait
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
    pub async fn add_peer_from(&self, params: &Value) -> Result<Value, RpcError> {
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
    /// attempt settled, with what the wait saw ([`Self::wait_for_peer`]).
    pub async fn reconnect_peer(&self, name: &str, wait: bool) -> Result<Value, RpcError> {
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
    ) -> Result<Value, RpcError> {
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
                if !wait {
                    return Ok(Value::Null);
                }
                if link.is_ready() {
                    return Ok(json!({"settled": true, "waitedMs": 0, "peer": running.summary()}));
                }
                return Ok(self.wait_for_peer(name, &mut settled, PEER_SETTLE_BUDGET).await);
            }
        }
        let mut settled = self.start_peer(name, &peer);
        drop(cfg);
        if !wait {
            return Ok(Value::Null);
        }
        Ok(self.wait_for_peer(name, &mut settled, PEER_SETTLE_BUDGET).await)
    }

    /// Remove a saved peer. Refused for a leased one: a lease never touches
    /// config.json, and it ends with the connection that holds it
    /// (`peer_lease.rs`).
    pub async fn remove_peer(&self, name: &str) -> Result<(), RpcError> {
        // The config lock first, held through the save: a reconnect (which holds it through its
        // start) never starts the peer again between its stop and its removal from the config.
        // The peer lookup is brief and released before the writer gate; the removal then follows
        // `peer_leases`, `peers`, `remote_sessions`.
        let mut cfg = self.config.write().await;
        let gone = {
            if self.peer(name).is_none() {
                return Err(RpcError::not_found(format!("no peer {name:?}")));
            }
            let writer = self.peer_cache_writer(name);
            let _writer = writer.lock().unwrap_or_else(|e| e.into_inner());
            // Under the lease lock, so no save of the removed peer's sessions
            // lands after its cache is gone (`save_peer_cache`).
            let leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            if leases.contains_key(name) {
                self.peer_cache_writers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                return Err(RpcError::invalid_params(format!(
                    "{name:?} is a leased peer; it ends when the connection that leased it closes"
                )));
            }
            // Its rows, its cache and its snapshots go under the registry lock it leaves before
            // the rows writer lock (lock order: `peer_leases`, `peers`, `remote_sessions`): a peer added
            // again under the name registers after (`spawn_peer`), and keeps what it lists.
            let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let mut rows = self.remote_sessions.write();
            let peer = peers.remove(name);
            let Some(peer) = peer else {
                drop(rows);
                drop(peers);
                drop(leases);
                self.peer_cache_writers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
                return Err(RpcError::not_found(format!("no peer {name:?}")));
            };
            peer.stop();
            self.note_peer_removed(&peer);
            self.forget_peer_files(name);
            take_peer_rows(&mut rows, name)
        };
        self.peer_cache_writers.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
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
        // Serialize a purge with an in-flight cache snapshot. Otherwise its pre-purge snapshot
        // could be the last file written before a restart restores the deleted row.
        let writer = self.peer_cache_writer(name);
        let (gone, generation) = {
            let _writer = writer.lock().unwrap_or_else(|e| e.into_inner());
            let leased =
                self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).contains_key(name);
            let peer = self.peer(name);
            let mut rows = self.remote_sessions.write();
            let gone = take_peer_rows(&mut rows, name);
            let generation = (!leased).then(|| peer.as_ref().map(|p| p.generation)).flatten();
            if !gone.is_empty()
                && let Some(p) = peer.as_ref().filter(|p| Some(p.generation) == generation)
            {
                p.remote_purge_fences
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .extend(removed_mux_ids(&gone));
                p.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
                p.cache_dirty_seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
            (gone, generation)
        };
        // Clients watching the list drop these rows.
        for summary in &gone {
            self.announce_remote(name, summary.clone(), "purged");
        }
        if !gone.is_empty()
            && let Some(generation) = generation
        {
            self.save_peer_cache(name, generation, false);
        }
    }

    pub fn peers(&self) -> Vec<Value> {
        // Read before `peers` is locked (lock order: `peer_leases`, then `peers`).
        let leased: std::collections::HashSet<String> =
            self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        // Released before the rows are counted, so this read takes `peers` and
        // `remote_sessions` separately and never in the reverse nested order.
        let (listed, brokers): (Vec<(String, Value)>, std::collections::HashSet<String>) = {
            let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let listed = peers.values().map(|p| (p.name.clone(), p.summary())).collect();
            (listed, peers.values().filter(|p| p.github_broker()).map(|p| p.name.clone()).collect())
        };
        let counts = self.remote_sessions.read().peer_counts();
        let mut v: Vec<Value> = listed
            .into_iter()
            .map(|(name, mut s)| {
                s.set("sessions", json!(counts.get(&name).copied().unwrap_or(0)));
                if leased.contains(&name) {
                    s.set("leased", Value::Bool(true));
                }
                if brokers.contains(&name) {
                    s.set("githubBroker", Value::Bool(true));
                }
                s
            })
            .collect();
        // The machines only the mesh hub reaches (`mesh_book.rs`): never an ssh peer's name.
        v.extend(self.mesh_book_hosts());
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

    /// Integration-test stand-in for an older peer (`Peer::forget_session_messages_for_tests`).
    #[doc(hidden)]
    pub fn forget_peer_session_messages_for_tests(&self, name: &str) -> bool {
        self.peer(name).map(|p| p.forget_session_messages_for_tests()).is_some()
    }

    pub(super) fn peer(&self, name: &str) -> Option<Arc<crate::peer::Peer>> {
        self.peers.lock().unwrap().get(name).cloned()
    }

    /// Prefix a peer session's summary so it reads as `<peer>/<name>`. A display line the peer
    /// put on a pending ask never reaches a client (`drop_display_lines`): every row a peer's
    /// list or `session_changed` adds goes through here.
    /// A row that is not an object (a buggy or hostile peer) comes back unchanged: it has no
    /// receipt, so every caller skips it.
    pub(crate) fn remote_summary(peer: &str, mut summary: Value) -> Value {
        if !summary.is_object() {
            return summary;
        }
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
            summary.set("qualifiedSessionId", Value::String(receipt.qualified_id()));
            summary.set("sessionReceipt", receipt.to_value());
        }
        if let Some(name) = summary.get("name").and_then(Value::as_str)
            && !name.starts_with(&format!("{peer}/"))
        {
            let full = format!("{peer}/{name}");
            summary.set("name", Value::String(full));
            // Its warnings' commands name the peer's session (`usage_warnings.rs`).
            super::usage_warnings::for_name(&mut summary);
        }
        summary.set("peer", Value::String(peer.to_owned()));
        // A peer from before `indicator`, `lane` or the lane's masked `step` and `title`
        // sends none: decide them here.
        let old_lane = summary
            .get("lane")
            .and_then(Value::as_object)
            .is_some_and(|lane| !lane.contains_key("title") || !lane.contains_key("requiresOpen"));
        if summary.get("indicator").is_none() || summary.get("lane").is_none() || old_lane {
            super::views::decide(&mut summary);
        }
        summary
    }

    /// Census notices intentionally omit tools. Keep an already captured inventory in the
    /// remote cache so `_acpmux/wait` and other per-session reads do not lose it on a change.
    fn retain_summary_tools(mut summary: Value, previous: Option<&Value>) -> Value {
        if summary.get("tools").is_none()
            && let Some(previous) = previous
        {
            for key in ["tools", "toolsMutable"] {
                if let Some(value) = previous.get(key) {
                    summary[key] = value.clone();
                }
            }
        }
        summary
    }

    /// Tell watching clients that a peer session appeared, changed or left.
    pub(super) fn announce_remote(&self, peer: &str, summary: Value, kind: &str) {
        let Some(id) = summary.get("sessionId").and_then(Value::as_str).map(str::to_owned) else {
            return;
        };
        let _ = self.events.send_remote(HubEvent {
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
            update_line: Default::default(),
            row: Default::default(),
        });
    }

    /// The row transition after a continuous outage's grace has elapsed.
    pub(super) fn mark_peer_unreachable(&self, peer: &str, generation: u64) {
        let changed = {
            let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let Some(current) = peers.get(peer).filter(|p| p.generation == generation).cloned()
            else {
                return;
            };
            let fence = current.remote_rows_epoch.load(std::sync::atomic::Ordering::Acquire);
            let mut map = self.remote_sessions.write();
            if current.remote_rows_epoch.load(std::sync::atomic::Ordering::Acquire) != fence {
                return;
            }
            let last_seen = current.link().last_seen;
            let changed = map.mark_peer_stale(peer, last_seen);
            if !changed.is_empty() {
                current.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
            }
            changed
        };
        if !changed.is_empty() {
            self.save_peer_cache(peer, generation, true);
        }
        for summary in changed {
            self.announce_remote(peer, summary, "status");
        }
    }

    #[cfg(test)]
    fn mark_peer_unreachable_at_fence(
        &self,
        current: &Arc<crate::peer::Peer>,
        peer: &str,
        generation: u64,
        fence: u64,
    ) {
        let changed = {
            let mut map = self.remote_sessions.write();
            if current.remote_rows_epoch.load(std::sync::atomic::Ordering::Acquire) != fence {
                return;
            }
            let last_seen = current.link().last_seen;
            let changed = map.mark_peer_stale(peer, last_seen);
            if !changed.is_empty() {
                current.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
            }
            changed
        };
        if !changed.is_empty() {
            self.save_peer_cache(peer, generation, true);
        }
        for summary in changed {
            self.announce_remote(peer, summary, "status");
        }
    }

    pub(super) fn apply_peer_notice(
        &self,
        peer: &str,
        generation: u64,
        notice: crate::peer::PeerNotice,
    ) {
        // `peer_notice_loop` checked the instance without the rows writer lock: a
        // peer replaced or removed since (`add_peer`, `remove_peer`,
        // `end_peer_lease`, each of which unregisters the peer before it
        // drops its rows) must not add rows back or save them. So every path
        // that changes rows checks again while holding `peers` then the rows writer lock.
        use crate::peer::PeerNotice;
        let peer = peer.to_owned();
        {
            match notice {
                PeerNotice::Connected => {
                    tracing::info!(peer = %peer, "peer ready");
                    // Its list came before this notice and is applied: a name it lacks is no
                    // session there (`hub/no_session.rs`).
                    if let Some(p) = self.peer(&peer).filter(|p| p.generation == generation) {
                        p.rows_ready.store(true, std::sync::atomic::Ordering::SeqCst);
                        p.note_rows_applied();
                    }
                    // The link takes requests again: messages waiting for a peer go now, not
                    // after the rest of their retry delay (`server/outbox.rs` `deliver`).
                    self.outbox.peer_ready.notify_waiters();
                    // Sessions can be saved before the handshake marks the link ready.
                    // Persist its cleared outage once, without rewriting an already-clear cache.
                    if self.peer(&peer).is_some_and(|p| {
                        p.generation == generation
                            && p.cache_saved_outage.load(std::sync::atomic::Ordering::SeqCst)
                    }) {
                        self.save_peer_cache(&peer, generation, true);
                    }
                }
                PeerNotice::Restarting => {
                    // A planned restart never enters the disconnect/flap-grace path. Keep
                    // every row unchanged, but retire the old link's purge tombstones.
                    let Some(current) = self.peer(&peer).filter(|p| p.generation == generation)
                    else {
                        return;
                    };
                    let _rows = self.remote_sessions.fence();
                    current.purge_tombstones.link_ended();
                    drop(_rows);
                    self.peer_snapshots.flush(Some(&peer));
                    tracing::info!(peer = %peer, "peer restarting");
                }
                PeerNotice::Disconnected(e) => {
                    if let Some(p) = self.peer(&peer).filter(|p| p.generation == generation) {
                        p.rows_ready.store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    // Called directly, with no grace: this drop is its outage's first
                    // when the link counts one failed attempt.
                    self.note_peer_drop(&peer, generation, &e);
                    let first = self.peer(&peer).is_some_and(|p| p.link().attempts == 1);
                    self.save_after_drop(&peer, generation, first);
                    self.mark_peer_unreachable(&peer, generation);
                }
                PeerNotice::Sessions(list) => {
                    // The list can land after clients took their snapshot (an
                    // ssh tunnel is slow to open), so tell watchers what changed.
                    // Read the old summaries once writers settled, then do all JSON projection and
                    // comparison work without it. The single-consumer notice loop keeps another
                    // notice for this peer from changing the baseline while this one is built.
                    let (changed, gone) = loop {
                        let (mut old, epoch, purged) = {
                            let Some(current) =
                                self.peer(&peer).filter(|p| p.generation == generation)
                            else {
                                return;
                            };
                            let epoch = current
                                .remote_rows_epoch
                                .load(std::sync::atomic::Ordering::Acquire);
                            let mut purged = current.purge_tombstones.peek();
                            purged.extend(
                                current
                                    .remote_purge_fences
                                    .lock()
                                    .unwrap_or_else(|e| e.into_inner())
                                    .iter()
                                    .cloned(),
                            );
                            let map = self.remote_sessions.settled();
                            (
                                map.of_peer(&peer)
                                    .map(|(id, r)| (id.clone(), r.summary.clone()))
                                    .collect::<HashMap<_, _>>(),
                                epoch,
                                purged,
                            )
                        };
                        let mut listed_rows = Vec::new();
                        let mut updates = Vec::new();
                        let mut changed = Vec::new();
                        for s in &list {
                            let summary = Self::remote_summary(&peer, s.clone());
                            let Some(receipt) = session_receipt(&summary) else { continue };
                            if purged.contains(&receipt.mux_session_id) {
                                continue;
                            }
                            let id = receipt.qualified_id();
                            let previous = old.remove(&id);
                            let summary = Self::retain_summary_tools(summary, previous.as_ref());
                            if previous.as_ref() != Some(&summary) {
                                changed.push(summary.clone());
                                updates.push((
                                    id.clone(),
                                    RemoteSession {
                                        peer: peer.clone(),
                                        summary: summary.clone(),
                                        receipt: receipt.clone(),
                                    },
                                ));
                            }
                            listed_rows
                                .push((id, RemoteSession { peer: peer.clone(), summary, receipt }));
                        }
                        let gone_ids = old.keys().cloned().collect::<Vec<_>>();
                        let gone = old.into_values().collect::<Vec<_>>();
                        let listed = listed_rows
                            .iter()
                            .map(|(_, r)| {
                                (
                                    r.receipt.mux_session_id.clone(),
                                    r.summary.get("createdAt").and_then(Value::as_u64),
                                )
                            })
                            .collect::<Vec<_>>();
                        #[cfg(test)]
                        self.pause_after_peer_session_projection_for_test();
                        let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
                        let Some(current) =
                            peers.get(&peer).filter(|p| p.generation == generation).cloned()
                        else {
                            return;
                        };
                        let mut map = self.remote_sessions.write();
                        if current.remote_rows_epoch.load(std::sync::atomic::Ordering::Acquire)
                            != epoch
                        {
                            continue;
                        }
                        for id in gone_ids {
                            map.remove(&id);
                        }
                        for (id, row) in updates {
                            map.insert(id, row);
                        }
                        if !changed.is_empty() || !gone.is_empty() {
                            current
                                .remote_rows_epoch
                                .fetch_add(1, std::sync::atomic::Ordering::Release);
                        }
                        // Which generation of each session is current (`peer_snapshot.rs`), sent
                        // while the row swap is still held, so a page cannot observe a row before
                        // its listing record.
                        if self.peer_snapshots.allows(generation) {
                            self.peer_snapshots.listed(&peer, listed, true);
                        }
                        // The tombstones are consumed only after the version fence wins, so a
                        // retry cannot accidentally revive a purge seen during projection.
                        let _ = current.purge_tombstones.take();
                        current
                            .remote_purge_fences
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .clear();
                        break (changed, gone);
                    };
                    // A burst of lists is dirty state, not an immediate disk write for every
                    // notice. The throttle admits one snapshot per interval; disconnect/drop
                    // paths still call with `now = true` for the final state.
                    self.save_peer_cache(&peer, generation, false);
                    for summary in changed {
                        self.announce_remote(&peer, summary, "status");
                    }
                    for summary in gone {
                        self.announce_remote(&peer, summary, "purged");
                    }
                    // Its live asks that came before this list.
                    self.release_held_peer_asks(&peer, generation);
                }
                PeerNotice::SessionChanged { session, kind, seq } => {
                    let Some(mux_id) =
                        session.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    else {
                        return;
                    };
                    if kind == "purged" {
                        let removed = {
                            #[cfg(test)]
                            self.pause_after_peer_session_projection_for_test();
                            let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
                            let Some(current) =
                                peers.get(&peer).filter(|p| p.generation == generation).cloned()
                            else {
                                return;
                            };
                            let mut map = self.remote_sessions.write();
                            // An older list of this link must not bring it back.
                            current.purge_tombstones.purged(&mux_id);
                            let key = map.find_mux(&peer, &mux_id).map(|(key, _)| key.clone());
                            let removed = key.and_then(|key| map.remove(&key).map(|r| r.summary));
                            // The generation the purge names (else the row's) goes from the
                            // snapshots too (`peer_snapshot.rs`), before the lock does.
                            let created = |s: &Value| s.get("createdAt").and_then(Value::as_u64);
                            let purged = created(&session).or(removed.as_ref().and_then(created));
                            self.peer_snapshots.gone(&peer, &mux_id, purged);
                            current
                                .remote_rows_epoch
                                .fetch_add(1, std::sync::atomic::Ordering::Release);
                            removed
                        };
                        self.save_peer_cache(&peer, generation, false);
                        let _ = self.events.send_remote(HubEvent {
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
                            update_line: Default::default(),
                            row: Default::default(),
                        });
                        return;
                    }
                    let mut summary = Self::remote_summary(&peer, session);
                    let Some(receipt) = session_receipt(&summary) else { return };
                    let id = receipt.qualified_id();
                    {
                        #[cfg(test)]
                        self.pause_after_peer_session_projection_for_test();
                        let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
                        let Some(current) =
                            peers.get(&peer).filter(|p| p.generation == generation).cloned()
                        else {
                            return;
                        };
                        let mut map = self.remote_sessions.write();
                        current.purge_tombstones.changed(&mux_id);
                        let old_id = map.find_mux(&peer, &mux_id).map(|(key, _)| key.clone());
                        let previous = old_id.as_ref().and_then(|key| map.take(key));
                        summary = Self::retain_summary_tools(
                            summary,
                            previous.as_ref().map(|r| &r.summary),
                        );
                        map.insert(
                            id.clone(),
                            RemoteSession { peer: peer.clone(), summary: summary.clone(), receipt },
                        );
                        let created = summary.get("createdAt").and_then(Value::as_u64);
                        if self.peer_snapshots.allows(generation) {
                            self.peer_snapshots.listed(
                                &peer,
                                vec![(mux_id.clone(), created)],
                                false,
                            );
                        }
                        current
                            .remote_purge_fences
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .remove(&mux_id);
                        current
                            .remote_rows_epoch
                            .fetch_add(1, std::sync::atomic::Ordering::Release);
                    }
                    // An ask decided there before the session was listed here never comes back.
                    if matches!(kind.as_str(), "permission_decision" | "permission_resolved") {
                        self.held_peer_asks.forget(&peer, &mux_id, None);
                    }
                    self.save_peer_cache(&peer, generation, false);
                    let _ = self.events.send_remote(HubEvent {
                        session_id: mux_id,
                        record: Arc::new(EventRecord {
                            seq,
                            at: now_ms(),
                            dir: "peer".into(),
                            kind,
                            msg: Value::Null,
                            host_seq: None,
                        }),
                        remote: Some(RemoteRef { peer: peer.clone(), summary: summary.clone() }),
                        update_line: Default::default(),
                        row: Default::default(),
                    });
                    // The rest of its live asks that came before the session was listed, after
                    // the row.
                    self.release_held_peer_asks(&peer, generation);
                }
                // A prompt this daemon forwarded was taken (`outbox.rs` `PeerAccepts`).
                PeerNotice::Notification { method: m, params, .. }
                    if m == method::MUX_PROMPT_ACCEPTED =>
                {
                    self.peer_accepts.accepted(&peer, &params);
                }
                // The link attached one of its chats again without history (a reconnect that had
                // no replay cursor for it): its clients here read on from their own last record.
                // Only that chat's: the link dropped nothing else, and the copy (`peer_snapshot.rs`)
                // takes none of the new link's records until a page joins it anyway.
                PeerNotice::Notification { method: m, params, .. }
                    if m == crate::peer::REATTACHED_NOTICE =>
                {
                    let Some(id) = params.get("sessionId").and_then(Value::as_str) else { return };
                    let _ = self.events.send_remote(HubEvent {
                        session_id: id.to_owned(),
                        record: Arc::new(EventRecord {
                            seq: 0,
                            at: now_ms(),
                            dir: "peer".into(),
                            kind: PEER_LAGGED.into(),
                            msg: json!({"sessionIds": [id], "reason": "peer_reattached"}),
                            host_seq: None,
                        }),
                        remote: Some(RemoteRef { peer: peer.clone(), summary: Value::Null }),
                        update_line: Default::default(),
                        row: Default::default(),
                    });
                }
                PeerNotice::Notification { method: m, params, link } if m == "_acpmux/lagged" => {
                    // This link's live records have a hole now: none of it is kept until a page
                    // (`peer_snapshot.rs`). A copy a later link's page joined is not this link's.
                    self.peer_snapshots.lagged(&peer, (generation, link));
                    let ids: Vec<String> = self
                        .remote_sessions
                        .read()
                        .of_peer(&peer)
                        .map(|(_, r)| r.receipt.mux_session_id.clone())
                        .collect();
                    for id in ids {
                        let _ = self.events.send_remote(HubEvent {
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
                            update_line: Default::default(),
                            row: Default::default(),
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
                        .read()
                        .find_mux(&peer, &id)
                        .map(|(_, r)| r.summary.clone())
                        .unwrap_or(Value::Null);
                    let mut record = match m.as_str() {
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
                            // An ask held for this session that was answered meanwhile is not
                            // shown again once the session is listed.
                            if matches!(
                                record.kind.as_str(),
                                "permission_decision" | "permission_auto" | "permission_withdrawn"
                            ) {
                                let permission =
                                    record.msg.get("permissionId").and_then(Value::as_str);
                                self.held_peer_asks.forget(&peer, &id, permission);
                            }
                            if is_permission_ask(&record.kind) {
                                match self.peer_ask_run(&peer, &id, &record.msg) {
                                    PeerAskRun::Current => {}
                                    PeerAskRun::Unlisted => {
                                        let notice = PeerNotice::Notification {
                                            method: m.clone(),
                                            params,
                                            link,
                                        };
                                        self.hold_peer_ask(&peer, generation, &id, notice);
                                        return;
                                    }
                                    PeerAskRun::Older | PeerAskRun::Forged => {
                                        tracing::warn!(peer = %peer, session = %id, "a peer's ask for a session or run that is not its own: dropped");
                                        return;
                                    }
                                }
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
                            if self.peer_ask_run(&peer, &id, &params) == PeerAskRun::Unlisted {
                                let notice =
                                    PeerNotice::Notification { method: m.clone(), params, link };
                                self.hold_peer_ask(&peer, generation, &id, notice);
                                return;
                            }
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
                    // A suggestion of the peer's chat reaches the person through their own
                    // tally and switch, not the peer's (`suggestion_gate::regate_relayed`).
                    if record.dir == "in"
                        && record.kind == "prompt_suggestion"
                        && let Some(update) = record.msg.pointer_mut("/params/update")
                    {
                        let harness = summary.get("harness").and_then(Value::as_str).unwrap_or("");
                        crate::suggestion_gate::regate_relayed(
                            &self.suggestion_gate,
                            &peer,
                            &id,
                            harness,
                            update,
                            crate::claude_stdio::prompt_suggestions::enabled_in_settings(),
                        );
                    }
                    self.capture_peer_record((&peer, generation, link), &id, &summary, &record);
                    let _ = self.events.send_remote(HubEvent {
                        session_id: id,
                        record: Arc::new(record),
                        remote: Some(RemoteRef { peer: peer.clone(), summary }),
                        update_line: Default::default(),
                        row: Default::default(),
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
        let listed = self.remote_sessions.read().find_mux(peer, id).is_some();
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).contains_key(id);
        if local {
            return PeerAskRun::Forged;
        }
        if !listed {
            return PeerAskRun::Unlisted;
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
            PeerAskRun::Forged | PeerAskRun::Unlisted => false,
            PeerAskRun::Older => {
                if let Some(ask) = ask.as_object_mut() {
                    ask.remove("decisionNonce");
                }
                true
            }
        }
    }

    /// Holds peer `peer`'s live ask `notice` for session `id`, which the peer
    /// has not listed yet (`held_asks.rs`): applied again once it does.
    fn hold_peer_ask(
        &self,
        peer: &str,
        generation: u64,
        id: &str,
        notice: crate::peer::PeerNotice,
    ) {
        tracing::info!(peer = %peer, session = %id, "a peer's ask for a session it has not listed yet: held until it does");
        self.held_peer_asks.hold(peer, generation, id, notice);
    }

    /// Applies again peer `peer`'s held asks whose session it lists now.
    fn release_held_peer_asks(&self, peer: &str, generation: u64) {
        let listed = |id: &str| self.remote_sessions.read().find_mux(peer, id).is_some();
        for notice in self.held_peer_asks.take_listed(peer, generation, listed) {
            self.apply_peer_notice(peer, generation, notice);
        }
    }

    /// Whether a record of kind `kind` with `msg` that peer `peer` sends for
    /// its session `id` may reach this daemon's clients: any record but an
    /// ask (`is_permission_ask`, in any `dir`) that fails `peer_ask_counts`.
    pub fn peer_record_counts(&self, peer: &str, id: &str, kind: &str, msg: &Value) -> bool {
        !is_permission_ask(kind) || self.peer_ask_counts(peer, id, msg)
    }

    /// How many sessions the peers list that `key` names, as [`Hub::resolve_remote`] matches
    /// them: 0 none, 1 the one it resolves, more when it is ambiguous.
    pub fn remote_matches(&self, key: &str) -> usize {
        let map = self.remote_sessions.read();
        if map.get(key).is_some() {
            return 1;
        }
        // One pass: whole names and prefixes, else short names (closed ones only when no live
        // one has it, as `resolve_remote` matches them).
        let (mut strict, mut live, mut closed) = (0, 0, 0);
        for (id, r) in map.iter() {
            if names_remote(id, r, key) {
                strict += 1;
            } else if strict == 0 && remote_segment(r, key) {
                if remote_closed(r) { closed += 1 } else { live += 1 }
            }
        }
        match (strict, live) {
            (0, 0) => closed,
            (0, live) => live,
            (strict, _) => strict,
        }
    }

    /// [`Self::remote_matches`] without short names: how many peer sessions `key` names by id,
    /// id prefix, whole name or `PEER/NAME`. A local short name gives way to any of them
    /// (`Hub::resolve_here`).
    pub(super) fn remote_strict_matches(&self, key: &str) -> usize {
        let map = self.remote_sessions.read();
        if map.get(key).is_some() {
            return 1;
        }
        map.iter().filter(|(id, r)| names_remote(id, r, key)).count()
    }

    /// The names (with their ids) of the peer sessions whose short name is `key`
    /// ([`remote_segment`]), each with whether it is closed, for `Hub::resolve_here`'s tie.
    pub(super) fn remote_segment_names(&self, key: &str) -> Vec<(String, bool)> {
        let map = self.remote_sessions.read();
        map.values()
            .filter(|r| remote_segment(r, key))
            .map(|r| {
                let name = r.summary.get("name").and_then(Value::as_str).unwrap_or("");
                (format!("{name} ({}/{})", r.peer, r.receipt.mux_session_id), remote_closed(r))
            })
            .collect()
    }

    /// Look a key up among peer sessions: exact id, `peer/name`, or a unique name or id prefix;
    /// failing those, the one peer session whose short name `key` is ([`remote_segment`]):
    /// `mac-ci-3` for `claude-sr2/mac-ci-3` when `key` names no session here in any way
    /// (`Hub::local_match_counts`), or `PEER/mac-ci-3` on that peer only.
    pub fn resolve_remote(&self, key: &str) -> Option<(Arc<crate::peer::Peer>, String, Value)> {
        let map = self.remote_sessions.read();
        let row = |r: &RemoteSession| {
            (r.peer.clone(), r.receipt.mux_session_id.clone(), r.summary.clone())
        };
        let (hit, by_short_name) = if let Some(r) = map.get(key) {
            (Some(row(r)), false)
        } else {
            // One pass over the rows, as before short names: whole names and prefixes, and the
            // short-name candidates beside them as references (kept only while no whole name or
            // prefix matched). Only the one row picked is cloned, never a candidate dropped later.
            let (mut strict, mut shorts) = (Vec::new(), Vec::new());
            for (id, r) in map.iter() {
                if names_remote(id, r, key) {
                    strict.push(&**r);
                } else if strict.is_empty() && remote_segment(r, key) {
                    shorts.push(&**r);
                }
            }
            let short = strict.is_empty();
            let mut matches: Vec<&RemoteSession> = if short {
                // Closed ones count only when no live one has the short name (`hub/key_route.rs`).
                let live = shorts.iter().any(|r| !remote_closed(r));
                shorts.into_iter().filter(|r| !live || !remote_closed(r)).collect()
            } else {
                strict
            };
            (if matches.len() == 1 { matches.pop().map(row) } else { None }, short)
        };
        drop(map);
        let (peer_name, id, summary) = hit?;
        // A bare short name gives way to any session here `key` names by id, name or prefix, to
        // a live one here with the short name, and, when this one is closed, to a closed one
        // here too (`Hub::resolve_here` refuses those ties). Read only now, with the peers' rows
        // unlocked and a candidate in hand, so no other lookup scans this daemon's sessions a
        // second time.
        if by_short_name && !key.contains('/') {
            let [other, live_here, closed_here] = self.local_match_counts(key);
            let closed = summary.get("status").and_then(Value::as_str) == Some("closed");
            if other > 0 || live_here > 0 || (closed && closed_here > 0) {
                return None;
            }
        }
        let peer = self.peer(&peer_name)?;
        Some((peer, id, summary))
    }

    /// The names of the peer sessions whose name contains `lower` (any case), for a refusal's
    /// list (`Hub::unknown_session`).
    pub(super) fn remote_names_containing(&self, lower: &str) -> Vec<String> {
        let map = self.remote_sessions.read();
        map.values()
            .filter_map(|r| r.summary.get("name").and_then(Value::as_str))
            .filter(|n| crate::session_name::contains_ignore_case(n, lower))
            .map(str::to_owned)
            .collect()
    }

    /// Peer `peer`'s session `mux` was deleted through us: drop it now rather than at the next
    /// reconnect. `generation` is the one the row named when the purge was asked: a session
    /// recreated since keeps its row, and only that generation's event snapshot goes. None (a row
    /// that names no generation) removes only such a row, never one of a generation. `instance`
    /// is the peer the purge went to: one replaced since (another machine under the name) keeps
    /// its rows and copies.
    pub fn forget_remote(&self, (peer, instance): (&str, u64), mux: &str, generation: Option<u64>) {
        // Serialize a remote purge with cache snapshots. A worker that already captured the row
        // must finish before this mutation, and the mutation must dirty the next cache snapshot.
        let writer = self.peer_cache_writer(peer);
        let removed = {
            let _writer = writer.lock().unwrap_or_else(|e| e.into_inner());
            let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let Some(current) = peers.get(peer).filter(|p| p.generation == instance).cloned()
            else {
                return;
            };
            let mut map = self.remote_sessions.write();
            let created = |r: &RemoteSession| r.summary.get("createdAt").and_then(Value::as_u64);
            let key = map
                .find_mux(peer, mux)
                .filter(|(_, r)| created(r) == generation)
                .map(|(key, _)| key.clone());
            let removed = key.and_then(|key| map.take(&key));
            if removed.is_some() {
                current
                    .remote_purge_fences
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(mux.to_owned());
                current.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
                current.cache_dirty_seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
            // Its event snapshot goes with it (`peer_snapshot.rs`), before the lock does. A purge
            // that names no generation and found no such row removes no copy of another.
            if generation.is_some() || removed.is_some() {
                self.peer_snapshots.gone(peer, mux, generation);
            }
            removed
        };
        if removed.is_some() {
            // A purge is a final row mutation for this generation: persist it after the writer
            // gate makes any older in-flight snapshot finish, even inside the throttle interval.
            self.save_peer_cache(peer, instance, true);
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

    /// Visit the rows of one published snapshot (`remote_table.rs`), normalized; no lock is
    /// held, so a visitor as slow as it likes never holds up a peer notice.
    pub(super) fn visit_remote_rows(
        &self,
        keep: impl Fn(&Value) -> bool,
        visit: impl FnMut(Value),
    ) {
        self.visit_remote_sessions(|r| keep(&r.summary), visit);
    }

    /// [`Self::visit_remote_rows`] of the rows `keep` takes, judged on the whole row (its peer
    /// and receipt as well as its summary).
    pub(super) fn visit_remote_sessions(
        &self,
        keep: impl Fn(&RemoteSession) -> bool,
        mut visit: impl FnMut(Value),
    ) {
        let states: HashMap<String, &'static str> = self
            .peers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .map(|p| (p.name.clone(), p.state().as_str()))
            .collect();
        let mut emit = |r: &RemoteSession| {
            let mut summary = r.summary.clone();
            summary.set("stale", Value::Bool(summary["stale"] == true));
            if let Some(state) = states.get(&r.peer) {
                summary.set("peerState", Value::String((*state).to_owned()));
            }
            visit(summary);
        };
        // One snapshot, held through the walk: no row is copied first, and a write meanwhile
        // (even one the visitor makes) leaves what this walk sees unchanged.
        let rows = self.remote_sessions.snapshot();
        for r in rows.values().filter(|r| keep(r)) {
            emit(r);
        }
        drop(rows);
        // The hub's rows of this person's other machines (`mesh_book.rs`), after the peers'.
        for r in self.mesh_book_rows(&keep) {
            emit(&r);
        }
    }

    /// This daemon's own sessions' summaries, without retaining the JSON trees: each closed row
    /// parsed back from its bytes. Tests compare with it; a list copies the bytes in their kept
    /// order instead (`Hub::own_rows_in_order`).
    #[cfg(test)]
    pub(super) fn visit_own_session_summaries(
        &self,
        with_tools: bool,
        mut visit: impl FnMut(Value),
    ) {
        for session in self.sessions() {
            visit(self.cached_closed_summary(&session, with_tools));
        }
    }

    /// Each summary once, local before remote, without retaining the JSON trees (tests).
    #[cfg(test)]
    pub(super) fn visit_session_summaries(&self, with_tools: bool, mut visit: impl FnMut(Value)) {
        self.visit_own_session_summaries(with_tools, &mut visit);
        self.visit_remote_rows(
            |_| true,
            |row| {
                visit(if with_tools { row } else { super::views::without_summary_tools(row) });
            },
        );
    }

    /// The live-only projection used by census requests that explicitly exclude closed rows.
    pub(super) fn visit_live_session_summaries(
        &self,
        with_tools: bool,
        mut visit: impl FnMut(Value),
    ) {
        for session in self.indexed_live_sessions() {
            visit(if with_tools {
                self.session_summary(&session)
            } else {
                self.session_list_summary(&session)
            });
        }
        self.visit_remote_rows(
            |row| row.get("status").and_then(Value::as_str) != Some("closed"),
            |row| {
                visit(if with_tools { row } else { super::views::without_summary_tools(row) });
            },
        );
    }

    /// The sessions with a pending permission or question, local and remote, newest first and
    /// without tools, summarizing no other chat: `_acpmux/sessions {pendingOnly}`
    /// (`server/list_reply.rs`). A local one is a live chat with an ask; a peer's is a row whose
    /// `pendingPermissions` is above zero. It reads no list snapshot, so no list pace holds it:
    /// a host mirroring 8,500 chats paced its list pages 4-9 s each, and the app's dialog list
    /// (`cmux agents dialog list`) read every page before it found one ask.
    pub(crate) fn pending_session_summaries(&self) -> Vec<Value> {
        let mut rows: Vec<Value> = self
            .indexed_live_sessions()
            .iter()
            .filter(|session| session.has_pending_permissions())
            .map(|session| self.session_list_summary(session))
            .collect();
        self.visit_remote_rows(
            |row| row.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0,
            |row| rows.push(super::views::without_summary_tools(row)),
        );
        super::session_pages::sort_session_summaries(&mut rows);
        rows
    }

    /// Every session, local and remote, newest first.
    pub fn all_session_summaries(&self) -> Vec<Value> {
        let mut v: Vec<Value> =
            self.sessions().iter().map(|s| self.cached_closed_summary(s, true)).collect();
        v.extend(self.remote_sessions());
        // Newest first, ties by sessionId: the order session list pages keep.
        super::session_pages::sort_session_summaries(&mut v);
        v
    }

    /// The index-backed projection for lookups that usually target an active chat. A miss falls
    /// back to the closed rows in `locate` (`located_summaries`) so closed history is
    /// still discoverable by an explicit request.
    pub(crate) fn live_session_summaries(&self) -> Vec<Value> {
        let mut v = Vec::new();
        self.visit_live_session_summaries(true, |row| v.push(row));
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

/// Whether peer session `r` is closed (its row's `status`).
pub(super) fn remote_closed(r: &RemoteSession) -> bool {
    r.summary.get("status").and_then(Value::as_str) == Some("closed")
}

/// Whether `key` is peer session `r`'s short name, its name's last segment: a bare
/// `mac-ci-3` for `PEER/claude-sr2/mac-ci-3` on any peer, or `PEER/mac-ci-3` on that peer only.
fn remote_segment(r: &RemoteSession, key: &str) -> bool {
    let name = r.summary.get("name").and_then(Value::as_str).unwrap_or("");
    if !key.contains('/') {
        return crate::session_name::ends_with_segments(name, key);
    }
    let peer = format!("{}/", r.peer);
    key.strip_prefix(&peer).is_some_and(|rest| {
        !rest.contains('/')
            && crate::session_name::ends_with_segments(
                name.strip_prefix(&peer).unwrap_or(name),
                rest,
            )
    })
}

/// Whether `key` names the peer's session `r` (listed under `id`): its name, a prefix of its id,
/// or `PEER/NAME`.
fn names_remote(id: &str, r: &RemoteSession, key: &str) -> bool {
    let name = r.summary.get("name").and_then(Value::as_str).unwrap_or("");
    name == key
        || r.receipt.mux_session_id.starts_with(key)
        || id.starts_with(key)
        || name.strip_prefix(&format!("{}/", r.peer)) == Some(key)
}

#[cfg(test)]
#[path = "peers_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "restart_notice_tests.rs"]
mod restart_notice_tests;
