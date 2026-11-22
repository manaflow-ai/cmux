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
/// key (`cmux link ensure` records the home first), and goes on serving on the Noise key.
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
    assert!(carrier.key_current(), "the carrier stopped when it gave the lock to the link");
    drop(serving);
}

/// Where the cmux link serves this home's node key, the carrier still serves: it takes no
/// lock (the link keeps its WireGuard session's one holder) and reads the key as a Noise
/// static key, so a Mac whose app runs the link stays reachable over Remote.
#[tokio::test]
async fn where_the_link_serves_the_node_key_the_carrier_serves_without_the_lock() {
    let home = tempfile::tempdir().unwrap();
    let link_dir = tempfile::tempdir().unwrap();
    let key = crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
    std::fs::write(link_dir.path().join("config.json"), "{}").unwrap();
    crate::cli::mesh_node_key::record_link_home(link_dir.path(), Some(home.path())).unwrap();
    assert!(link_serves(home.path()), "the fixture's link does not serve the key");
    let hub = joined_hub(home.path());
    let websocket = Some("127.0.0.1:1".parse().unwrap());
    let serving = start_configured(&hub, home.path(), websocket, None).await;
    assert!(serving.is_some(), "the carrier stayed off beside the cmux link");
    let carrier = hub.hub_carrier.get().expect("the carrier is on the hub");
    assert_eq!(carrier.public_key(), key.public_key_base64());
    assert!(carrier.key_current());
    let link = KeyHolder::acquire(home.path());
    assert!(link.is_ok(), "the carrier kept the lock from the link: {:?}", link.err());
    drop(link);
    drop(serving);
}

/// With the link serving a key that is not there (never created by the carrier), the
/// carrier stays off and makes none.
#[tokio::test]
async fn where_the_link_serves_a_missing_node_key_the_carrier_creates_none() {
    let home = tempfile::tempdir().unwrap();
    let link_dir = tempfile::tempdir().unwrap();
    std::fs::write(link_dir.path().join("config.json"), "{}").unwrap();
    crate::cli::mesh_node_key::record_link_home(link_dir.path(), Some(home.path())).unwrap();
    let hub = joined_hub(home.path());
    let websocket = Some("127.0.0.1:1".parse().unwrap());
    assert!(start_configured(&hub, home.path(), websocket, None).await.is_none());
    assert!(
        !home.path().join(cmux_link::key_holder::KeyFile::Node.file_name()).exists(),
        "a key was made"
    );
}

/// A relay's own words for an offline slot, and a wait that ran out, both end as one message
/// that names the far carrier and the fix, never a bare relay code.
#[test]
fn a_dial_to_a_carrier_that_is_not_serving_says_so() {
    let wait = Duration::from_secs(6);
    for relay_says in [
        "relay refused: slot-offline: no daemon is registered for the requested slot",
        "daemon registration lease has expired",
    ] {
        let said = relay_refusal(relay_says.to_owned(), wait);
        assert!(said.contains("hub carrier is off"), "{said}");
        assert!(said.contains("Update cmux") && said.contains("carrier.not_serving"), "{said}");
    }
    assert_eq!(relay_refusal("ticket expired".to_owned(), wait), "ticket expired");
    let said = ticket_refusal("the hub answered 404 machine.not_found".to_owned());
    assert!(said.contains("another of your teams") && said.contains("teamId"), "{said}");
    assert!(said.ends_with("(carrier.not_serving)"), "{said}");
    assert_eq!(ticket_refusal("the hub answered 503".to_owned()), "the hub answered 503");
    assert!(carrier_not_serving(Duration::from_millis(10)).contains("within 1s"));
}

/// `--via-machine NAME`: the address book's host name finds the machine's `daemonId`.
#[test]
fn a_hub_machine_is_found_by_the_name_machine_ls_shows() {
    let book = vec![
        ("key-air".to_owned(), "air-blue".to_owned()),
        ("key-big".to_owned(), "Big-Red".to_owned()),
    ];
    assert_eq!(
        crate::cmux_tui_service::book_machine(&book, "air-blue").as_deref(),
        Some("key-air")
    );
    assert_eq!(crate::cmux_tui_service::book_machine(&book, "big-red").as_deref(), Some("key-big"));
    assert_eq!(crate::cmux_tui_service::book_machine(&book, "nope"), None);
    let twins = vec![("k1".to_owned(), "mac".to_owned()), ("k2".to_owned(), "mac".to_owned())];
    assert_eq!(
        crate::cmux_tui_service::book_machine(&twins, "mac"),
        None,
        "two machines, one name"
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
