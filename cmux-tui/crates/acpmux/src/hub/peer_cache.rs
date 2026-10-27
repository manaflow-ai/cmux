//! Part of `Hub`; see `hub/mod.rs`. Each peer's last-known sessions, kept
//! while the peer is down and saved to `peers/<name>.json`, so a daemon that
//! restarts while a peer is unreachable still lists them, marked stale, and
//! a request for one is refused as `peer_unreachable`, not `no_session`.

use super::*;

/// While a peer's sessions change, at most one save this often; a fresh
/// list and the first drop are saved at once.
const SAVE_EVERY_MS: u64 = 30_000;

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    last_seen: Option<u64>,
    sessions: Vec<Value>,
}

fn cache_path(dir: &std::path::Path, peer: &str) -> Option<std::path::PathBuf> {
    crate::session_name::validate(peer).ok()?;
    Some(dir.join(format!("{peer}.json")))
}

/// Mark a peer's session as last-known: `status` `unreachable` (what older
/// clients read), `stale`, and when the peer was last seen. Returns whether
/// the row changed.
pub(super) fn mark_stale(summary: &mut Value, last_seen: Option<u64>) -> bool {
    let before = summary.clone();
    summary["status"] = Value::String("unreachable".into());
    summary["stale"] = Value::Bool(true);
    summary["lastSeen"] = json!(last_seen);
    super::views::decide(summary);
    *summary != before
}

impl Hub {
    /// Save `peer`'s rows, while `generation` is the instance registered
    /// under that name; unless `now`, at most once per `SAVE_EVERY_MS`.
    pub(super) fn save_peer_cache(&self, peer: &str, generation: u64, now: bool) {
        // Held to the end: a lease, `add_peer` taking a leased name over and
        // `remove_peer` change who holds the name under this lock, so a save
        // of a replaced or removed instance never lands (lock order:
        // `peer_leases` first).
        let leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        // A leased peer leaves nothing on disk (`peer_lease.rs`).
        if leases.contains_key(peer) {
            return;
        }
        let p = self.peer(peer).filter(|p| p.generation == generation);
        let (Some(dir), Some(p)) = (self.store.peer_cache_dir(), p) else { return };
        let Some(path) = cache_path(&dir, peer) else { return };
        let at = now_ms();
        let last = p.cache_saved_at.load(std::sync::atomic::Ordering::SeqCst);
        if !now && at.saturating_sub(last) < SAVE_EVERY_MS {
            return;
        }
        p.cache_saved_at.store(at, std::sync::atomic::Ordering::SeqCst);
        let sessions: Vec<Value> = self
            .remote_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .filter(|r| r.peer == peer)
            .map(|r| r.summary.clone())
            .collect();
        let saved = Saved { last_seen: p.link().last_seen, sessions };
        let write = || -> anyhow::Result<()> {
            crate::config::private_state_dir(&dir)?;
            crate::config::write_atomic(&path, &serde_json::to_vec(&saved)?)
        };
        if let Err(e) = write() {
            tracing::warn!(peer = %peer, "saving the peer's last-known sessions failed: {e}");
        }
        drop(leases);
    }

    /// A peer that starts with no rows here (this daemon just started) lists
    /// its saved ones, stale, until its first handshake replaces them.
    pub(super) fn load_peer_cache(&self, peer: &crate::peer::Peer) {
        let Some(dir) = self.store.peer_cache_dir() else { return };
        let Some(path) = cache_path(&dir, &peer.name) else { return };
        let Ok(bytes) = std::fs::read(&path) else { return };
        let Ok(saved) = serde_json::from_slice::<Saved>(&bytes) else { return };
        peer.seed_last_seen(saved.last_seen);
        let mut map = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        if map.values().any(|r| r.peer == peer.name) {
            return;
        }
        for mut summary in saved.sessions {
            let Some(receipt) = super::peers::session_receipt(&summary) else { continue };
            mark_stale(&mut summary, saved.last_seen);
            // An older build saved rows with a peer's own display line.
            super::drop_display_lines(&mut summary);
            let remote = RemoteSession { peer: peer.name.clone(), summary, receipt };
            map.insert(remote.receipt.qualified_id(), remote);
        }
    }

    /// `forget_peer_files` under the rows lock (`remove_peer` holds it itself).
    #[cfg(test)]
    pub(super) fn forget_peer_cache(&self, peer: &str) {
        let _rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        self.forget_peer_files(peer);
    }

    /// `forget_peer_cache` with the rows lock held by the caller (`remove_peer`).
    pub(super) fn forget_peer_files(&self, peer: &str) {
        if let Some(path) = self.store.peer_cache_dir().and_then(|d| cache_path(&d, peer)) {
            let _ = std::fs::remove_file(path);
        }
        // And its sessions' event snapshots (`peer_snapshot.rs`), under the rows lock once the
        // peer has left the registry (`remove_peer`): a listing or capture of it that found it
        // current (under this lock) has sent its op already and none after it does, so no
        // listing that lets a page start a copy again comes after this.
        self.peer_snapshots.forget_peer(peer);
    }

    /// The refusal for `PEER/name` when PEER is a peer that is down and
    /// lists no such session: the session may well be there, so say the
    /// peer is unreachable rather than that the session does not exist.
    pub fn peer_down_for(&self, key: &str) -> Option<RpcError> {
        let (name, rest) = key.split_once('/')?;
        let peer = self.peer(name).filter(|_| !rest.is_empty())?;
        (!peer.connected.load(std::sync::atomic::Ordering::SeqCst))
            .then(|| peer.unreachable_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::PeerNotice;

    fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir).unwrap();
        Hub::new(cfg, store)
    }

    fn test_hub() -> (Arc<Hub>, cmux_unix_socket::TestDir) {
        let dir = cmux_unix_socket::short_test_dir("acpmux-pc");
        (hub_at(dir.path()), dir)
    }

    /// A peer that is registered but never runs: its link stays down.
    fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
        peer
    }

    fn remote(id: &str, name: &str) -> Value {
        json!({"sessionId": id, "name": name, "status": "idle", "turnCount": 1, "updatedAt": 5})
    }

    #[test]
    fn a_down_peer_keeps_its_sessions_listed_as_stale_and_restarts_list_them_again() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "huge-blue");
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        let fresh = hub.remote_sessions();
        assert_eq!(fresh.len(), 1);
        assert_eq!(fresh[0]["stale"], false, "{fresh:?}");
        assert_eq!(fresh[0]["peer"], "huge-blue");

        peer.seed_last_seen(Some(now_ms() - 40_000));
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Disconnected("connect timed out".into()),
        );
        let stale = hub.remote_sessions();
        assert_eq!(stale.len(), 1, "kept, not dropped");
        assert_eq!(stale[0]["status"], "unreachable", "what older clients read");
        assert_eq!(stale[0]["stale"], true);
        assert!(stale[0]["lastSeen"].is_u64(), "{stale:?}");
        assert_eq!(stale[0]["peerState"], "reconnecting");
        assert_eq!(hub.peers()[0]["sessions"], 1);
        assert_eq!(hub.peers()[0]["state"], "reconnecting");
        assert!(dir.path().join("peers/huge-blue.json").is_file());

        // This daemon restarts while the peer is still down.
        let again = hub_at(dir.path());
        let peer = add_idle_peer(&again, "huge-blue");
        again.load_peer_cache(&peer);
        let listed = again.remote_sessions();
        assert_eq!(listed.len(), 1, "{listed:?}");
        assert_eq!(listed[0]["name"], "huge-blue/lane");
        assert_eq!(listed[0]["stale"], true);
        assert_eq!(peer.state(), crate::peer_link::PeerState::Reconnecting);

        // Its first handshake replaces the saved rows with fresh ones.
        again.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        let back = again.remote_sessions();
        assert_eq!(back[0]["stale"], false, "{back:?}");
        assert_eq!(back[0]["status"], "idle");

        again.forget_peer_cache("huge-blue");
        assert!(!dir.path().join("peers/huge-blue.json").exists());
    }

    /// A cache an older build saved can hold a peer's own display line on a pending ask: the
    /// row a restart lists carries none (`drop_display_lines`), the tool's own input kept.
    #[test]
    fn a_saved_rows_display_line_is_dropped_when_loaded() {
        let (hub, dir) = test_hub();
        let mut row = Hub::remote_summary("huge-blue", remote("m1", "lane"));
        row["pending"] = json!([{"permissionId": "p1", "request": {"toolCall": {
            "rawInput": {"_meta": {"acpmux": {"display": {"headline": "the tool's own input"}}}},
            "_meta": {"acpmux": {"display": {"headline": "Leo wants to say hi"}}}}}}]);
        std::fs::create_dir_all(dir.path().join("peers")).unwrap();
        let saved = json!({"lastSeen": now_ms() - 40_000, "sessions": [row]});
        std::fs::write(dir.path().join("peers/huge-blue.json"), saved.to_string()).unwrap();
        let peer = add_idle_peer(&hub, "huge-blue");
        hub.load_peer_cache(&peer);
        let listed = Value::from(hub.remote_sessions());
        assert_eq!(listed[0]["name"], "huge-blue/lane", "{listed}");
        assert!(!listed.to_string().contains("Leo wants to say hi"), "{listed}");
        assert!(listed.to_string().contains("the tool's own input"), "{listed}");
    }

    #[tokio::test]
    async fn a_request_for_a_down_peers_session_is_peer_unreachable_not_no_session() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "huge-blue");
        *peer.last_error.lock().unwrap() = Some("connect timed out".into());
        peer.seed_last_seen(Some(now_ms() - 40_000));
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Disconnected("connect timed out".into()),
        );

        let (found, id, _) = hub.resolve_remote("huge-blue/lane").expect("still listed");
        let e = found.request(method::SESSION_PROMPT, json!({"sessionId": id})).await.unwrap_err();
        assert!(
            e.message.starts_with("peer_unreachable: huge-blue (reconnecting, last seen 4"),
            "{}",
            e.message
        );
        assert!(
            e.message.contains(": connect timed out); the request was not sent"),
            "{}",
            e.message
        );
        assert_eq!(e.data.as_ref().unwrap()["reason"], "peer_unreachable");

        // A name the peer never listed here: still the peer, not no_session.
        let e = hub.peer_down_for("huge-blue/other").expect("peer is down");
        assert!(e.message.starts_with("peer_unreachable: huge-blue"), "{}", e.message);
        assert!(hub.peer_down_for("nopeer/lane").is_none());
        assert!(hub.peer_down_for("lane").is_none());
    }
}
