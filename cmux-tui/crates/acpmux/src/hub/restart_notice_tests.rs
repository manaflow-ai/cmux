use super::*;
use crate::peer::{Peer, PeerNotice};

#[tokio::test(start_paused = true)]
async fn restart_settles_without_stale_rows_or_delayed_flap_notices() {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let peer = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    hub.peers.lock().unwrap().insert(peer.name.clone(), peer.clone());
    let rows = vec![
        json!({"sessionId":"live", "name":"live", "status":"ready"}),
        json!({"sessionId":"done", "name":"done", "status":"closed"}),
    ];
    hub.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Sessions(rows.clone()));
    let before = hub.remote_sessions();
    assert_eq!(before.len(), 2);
    let mut events = hub.events.subscribe();
    let mut settled = peer.settled();
    hub.peer_notices
        .send((peer.name.clone(), peer.generation, PeerNotice::Restarting))
        .await
        .unwrap();
    settled.changed().await.unwrap();
    tokio::time::advance(std::time::Duration::from_secs(11)).await;
    tokio::task::yield_now().await;
    assert_eq!(hub.remote_sessions(), before);
    assert!(events.try_recv().is_err(), "restart never schedules a flap deadline");
    hub.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Sessions(rows));
    hub.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Connected);
    assert!(events.try_recv().is_err(), "unchanged reconnect rows do not flap");
}

/// A machine with a cmux link serving (it holds the machine's WireGuard key lock in the
/// acpmux home for its whole life) and one WireGuard peer `b`, `linked` through the link or
/// not. `same_key`: the link serves this node's own key (one key); otherwise a key of its own,
/// as every link does before the one-key migration.
struct LinkServing {
    home: tempfile::TempDir,
    link_dir: tempfile::TempDir,
    _lock: cmux_link::key_holder::KeyHolder,
    cfg: crate::config::Config,
}

fn link_serving(same_key: bool, linked: bool) -> LinkServing {
    use base64::Engine as _;
    use cmux_link::key_holder::{KeyFile, KeyHolder};
    let home = tempfile::tempdir().unwrap();
    let link_dir = tempfile::tempdir().unwrap();
    crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
    let node = std::fs::read(KeyFile::Node.path_in(home.path())).unwrap();
    let link_key = if same_key { node } else { vec![9; 32] };
    let b64 = base64::engine::general_purpose::STANDARD;
    std::fs::write(KeyFile::Link.path_in(link_dir.path()), b64.encode(&link_key)).unwrap();
    let lock = KeyHolder::acquire(home.path()).unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    cfg.transport.wireguard = true;
    cfg.transport.wireguard_static = Some(crate::wireguard::StaticConfig {
        listen: "127.0.0.1:0".parse().unwrap(),
        address: "10.77.0.1:4100".parse().unwrap(),
    });
    cfg.peers.insert(
        "b".into(),
        crate::config::PeerConfig {
            link_host: linked.then(|| "inst_b".to_owned()),
            wireguard: Some(crate::wireguard::StaticPeer {
                public_key: b64.encode([5; 32]),
                endpoint: "127.0.0.1:9".into(),
                address: "10.77.0.2:4100".parse().unwrap(),
            }),
            url: "ws://127.0.0.1:9/b".into(),
            token: None,
            peer_token: None,
            vm_boundary: false,
            github_broker: false,
        },
    );
    LinkServing { home, link_dir, _lock: lock, cfg }
}

impl LinkServing {
    /// acpmux starts: its WireGuard transport, and the hub's paths for `b`.
    async fn start(self) -> (Option<Arc<crate::wireguard::Transport>>, Vec<String>, LinkServing) {
        let wireguard = crate::wireguard::Transport::start_with_link(
            &self.cfg,
            self.home.path(),
            Some(self.link_dir.path()),
            "127.0.0.1:1".parse().unwrap(),
        )
        .await
        .unwrap();
        let store =
            crate::store::open(&self.cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub =
            Hub::build(self.cfg.clone(), store, Mailbox::memory(), false, false, wireguard.clone());
        let peer = hub.peers.lock().unwrap().get("b").cloned().unwrap();
        let paths = peer.summary()["paths"].clone();
        let vias = paths
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|p| p["via"].as_str().map(str::to_owned))
            .collect();
        peer.stop();
        (wireguard, vias, self)
    }
}

/// Review of #38357 at 506641de (F1): an upgraded config (no `linkHost`) whose link serves
/// a key of its own keeps acpmux's WireGuard next to the serving link, as before the upgrade.
#[tokio::test]
async fn a_link_with_its_own_key_leaves_a_wireguard_peer_on_acpmux_wireguard() {
    let (wireguard, vias, _machine) = link_serving(false, false).start().await;
    let wireguard = wireguard.expect("acpmux's WireGuard stepped down for another key's link");
    assert_eq!(vias, ["wireguard", "url"]);
    wireguard.shutdown(tokio::time::Instant::now()).await;
}

/// The hub path is listed only where the hub carrier may run: a joined daemon whose
/// WireGuard transport holds the key lock (the carrier never takes the lock itself).
#[cfg(feature = "hub-carrier")]
#[tokio::test]
async fn a_joined_daemon_with_the_transports_lock_lists_the_hub_path() {
    let mut machine = link_serving(false, false);
    machine.cfg.mesh_relay = Some(crate::mesh_http::MeshRelayConfig {
        url: "http://127.0.0.1:9".into(),
        token_command: Vec::new(),
        team_messaging: true,
        credential: Some("join".into()),
        control_from: Vec::new(),
    });
    let (wireguard, vias, _machine) = machine.start().await;
    let wireguard = wireguard.expect("acpmux's WireGuard stepped down for another key's link");
    assert_eq!(vias, ["wireguard", "url", "hub"]);
    wireguard.shutdown(tokio::time::Instant::now()).await;
}

/// Review of #38357 at 95620842: a link that serves this node's own key holds it, so acpmux
/// opens no WireGuard of its own, and a peer with a link route dials through the link first.
#[tokio::test]
async fn a_link_serving_the_same_key_carries_a_linked_peer_and_acpmux_opens_no_wireguard() {
    let (wireguard, vias, _machine) = link_serving(true, true).start().await;
    assert!(wireguard.is_none(), "acpmux opened its own WireGuard on the link's key");
    assert_eq!(vias, ["link", "url"]);
}

/// Review of #38357 at 506641de (F1): with the link on the same key, a peer it has no route
/// to is not stranded: it keeps its URL (or ssh) path, and the step-down names it in the log.
#[tokio::test]
async fn a_link_serving_the_same_key_leaves_an_unlinked_peer_its_url() {
    let (wireguard, vias, _machine) = link_serving(true, false).start().await;
    assert!(wireguard.is_none());
    assert_eq!(vias, ["url"]);
}
