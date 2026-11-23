//! The hub carrier and the node key lock (split out of `hub_carrier.rs`).

use super::*;
use cmux_link::key_holder::KeyHolder;

fn joined_hub(home: &std::path::Path) -> Arc<crate::hub::Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    config.mesh_relay = Some(crate::mesh_http::MeshRelayConfig {
        url: "http://127.0.0.1:9".into(),
        token_command: vec!["must-not-run".into()],
        team_messaging: true,
        credential: Some("join".into()),
        control_from: Vec::new(),
    });
    let store = crate::store::open(&config.store, home).unwrap();
    crate::hub::Hub::new(config, store)
}

/// The carrier needs only the node key: with transport.wireguard off (no static endpoints, no
/// Labs switch) and no cmux link serving the key, a joined daemon's carrier takes the key lock
/// itself and comes up, and stopping it frees the lock.
#[tokio::test]
async fn with_only_the_node_key_the_carrier_comes_up() {
    let home = tempfile::tempdir().unwrap();
    let hub = joined_hub(home.path());
    let websocket = Some("127.0.0.1:1".parse().unwrap());
    let serving = start_configured(&hub, home.path(), websocket, None).await;
    assert!(serving.is_some(), "the carrier stayed off with only the node key");
    let carrier = hub.hub_carrier.get().expect("the carrier is on the hub");
    let public = crate::cli::mesh_node_key::public_key_at(home.path()).expect("a node key");
    assert_eq!(
        carrier.public_key(),
        base64::engine::general_purpose::STANDARD.encode(public),
        "the carrier runs on the node key"
    );
    assert!(carrier.key_current());
    assert!(KeyHolder::acquire(home.path()).is_err(), "the carrier runs without the key lock");
    drop(serving);
    assert!(KeyHolder::acquire(home.path()).is_ok(), "a stopped carrier kept the lock");
}

/// A carrier on its own lock hands it to the cmux link once the link serves this home's node
/// key (`cmux link ensure` records the home first), and from then its key check fails.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_carriers_own_lock_goes_to_the_link_once_it_serves_the_key() {
    let home = tempfile::tempdir().unwrap();
    let link_dir = tempfile::tempdir().unwrap();
    let hub = joined_hub(home.path());
    let websocket = Some("127.0.0.1:1".parse().unwrap());
    let serving = start_configured(&hub, home.path(), websocket, None).await.expect("on");
    let carrier = hub.hub_carrier.get().unwrap();
    std::fs::write(link_dir.path().join("config.json"), "{}").unwrap();
    crate::cli::mesh_node_key::record_link_home(link_dir.path(), Some(home.path())).unwrap();
    let deadline = Instant::now() + LINK_HANDOFF_EVERY * 5;
    while KeyHolder::acquire(home.path()).is_err() {
        assert!(Instant::now() < deadline, "the carrier kept the lock from the link");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!carrier.key_current(), "the carrier still serves without the lock");
    drop(serving);
}

/// Where the cmux link serves this home's node key, the carrier steps down: it takes no lock
/// and reads no key, so the link holds the key while the daemon runs.
#[tokio::test]
async fn where_the_link_serves_the_node_key_the_carrier_takes_none() {
    let home = tempfile::tempdir().unwrap();
    let link_dir = tempfile::tempdir().unwrap();
    std::fs::write(link_dir.path().join("config.json"), "{}").unwrap();
    crate::cli::mesh_node_key::record_link_home(link_dir.path(), Some(home.path())).unwrap();
    let hub = joined_hub(home.path());
    let websocket = Some("127.0.0.1:1".parse().unwrap());
    assert!(start_configured(&hub, home.path(), websocket, None).await.is_none());
    let link = KeyHolder::acquire(home.path());
    assert!(link.is_ok(), "the carrier kept the lock: {:?}", link.err());
    assert!(
        !home.path().join(cmux_link::key_holder::KeyFile::Node.file_name()).exists(),
        "a key was read"
    );
}

/// Given the transport's holder, the carrier reads the key under that same lock, and the lock
/// is free once both drop.
#[test]
fn with_the_transports_lock_the_carrier_reads_the_key() {
    let home = tempfile::tempdir().unwrap();
    let shared = Arc::new(KeyHolder::acquire(home.path()).unwrap());
    let (holder, private) = node_key(home.path(), shared.clone()).unwrap();
    assert!(Arc::ptr_eq(&holder, &shared));
    let public = crate::cli::mesh_node_key::public_key_at(home.path()).unwrap();
    assert_eq!(
        public,
        x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(*private)).to_bytes()
    );
    drop((holder, shared));
    assert!(KeyHolder::acquire(home.path()).is_ok(), "the lock outlived its holders");
}
