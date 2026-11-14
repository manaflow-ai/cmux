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

/// With transport.wireguard off, a joined daemon's carrier takes no lock and reads no key, so
/// the link can take the lock while the daemon runs.
#[tokio::test]
async fn without_the_transports_lock_the_carrier_takes_none() {
    let home = tempfile::tempdir().unwrap();
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
