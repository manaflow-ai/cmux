use super::*;
use serde_json::json;

#[test]
fn the_advert_is_read_only_from_a_running_transport() {
    let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    let health = json!({"node": {
        "wgPublicKey": key,
        "wireguard": {"publicKey": key, "port": 51820, "address": "10.78.0.2:4100"},
    }});
    assert_eq!(
        advert_of(&health),
        Some((key.to_owned(), 51820, "10.78.0.2:4100".parse().unwrap()))
    );
    // A machine whose transport is off names its key only: nothing to learn.
    assert_eq!(advert_of(&json!({"node": {"wgPublicKey": key}})), None);
    assert_eq!(advert_of(&json!({})), None);
    let zero =
        json!({"node": {"wireguard": {"publicKey": key, "port": 0, "address": "10.78.0.2:4100"}}});
    assert_eq!(advert_of(&zero), None);
    let bad = json!({"node": {"wireguard": {"publicKey": key, "port": 1, "address": "nope"}}});
    assert_eq!(advert_of(&bad), None);
}

#[test]
fn an_endpoint_brackets_an_ipv6_host() {
    assert_eq!(endpoint_of("gcp-agent-lane-7", 51820), "gcp-agent-lane-7:51820");
    assert_eq!(endpoint_of("100.64.0.7", 51820), "100.64.0.7:51820");
    assert_eq!(endpoint_of("fd7a::7", 51820), "[fd7a::7]:51820");
    assert_eq!(endpoint_of("[fd7a::7]", 51820), "[fd7a::7]:51820");
}

#[test]
fn the_ssh_hostname_is_read_from_ssh_g() {
    let config = "user cmux\nhostname 100.64.0.7\nport 22\n";
    assert_eq!(crate::cli::ssh_join::hostname_of(config).as_deref(), Some("100.64.0.7"));
    assert_eq!(crate::cli::ssh_join::hostname_of("user cmux\n"), None);
}

#[tokio::test]
async fn a_learned_peer_keeps_learning_and_adopts_a_changed_service_address() {
    use crate::config::{Config, TransportConfig};
    use crate::wireguard::StaticConfig;
    let home = tempfile::tempdir().unwrap();
    let config = Config {
        transport: TransportConfig {
            wireguard: true,
            wireguard_static: Some(StaticConfig {
                listen: "127.0.0.1:0".parse().unwrap(),
                address: "10.78.0.1:4100".parse().unwrap(),
            }),
        },
        ..Default::default()
    };
    let transport =
        Transport::start_with_link(&config, home.path(), None, "127.0.0.1:1".parse().unwrap())
            .await
            .unwrap()
            .unwrap();
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = Peer::new("b", "ssh://localhost", None, None, tx);
    peer.set_wireguard_learner(transport.clone());
    assert!(peer.wg_learn_wanted());
    let first = "10.78.0.2:4100".parse().unwrap();
    assert!(peer.adopt_wireguard(transport.clone(), first));
    assert!(peer.wg_learn_wanted(), "a remembered route must not disable later health updates");
    let next = "10.78.0.3:4200".parse().unwrap();
    assert!(peer.adopt_wireguard(transport.clone(), next));
    assert_eq!(peer.wireguard_route().unwrap().1, next);
    peer.set_explicit_route(true);
    assert!(!peer.wg_learn_wanted(), "configured routes still take precedence");
    peer.stop();
    transport.shutdown(tokio::time::Instant::now()).await;
}
