//! A whole tailnet on loopback: one coordinator, two relays, real clients
//! whose WireGuard datagrams ride the relays. Checks the ACL end to end:
//! allowed traffic flows, denied traffic is cut by the receiver, and policy
//! changes, revocation, approval and key rotation reach the data plane.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use cmux_weft::admin::{AdminClient, MintAuthKey};
use cmux_weft::client::{JoinOptions, Service, WeftNode};
use cmux_weft::coord::{CoordConfig, serve_coord};
use cmux_weft::keys::SigningKey;
use cmux_weft::relay::{RelayConfig, serve_relay};
use cmux_weft::types::{NodeState, RelayInfo};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const ADMIN: &str = "test-admin-token-0123456789";
const STEP: Duration = Duration::from_secs(20);

struct Net {
    coord: String,
    admin: AdminClient,
    dir: PathBuf,
}

fn scratch_dir() -> PathBuf {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!("weft-e2e-{}", hex::encode(bytes)));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn start_net() -> Net {
    let dir = scratch_dir();
    let authority = SigningKey::generate();
    let mut relays = Vec::new();
    for region in ["r1", "r2"] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let config = RelayConfig { ticket_public_key: authority.public(), region: region.into() };
        tokio::spawn(serve_relay(listener, config));
        relays.push(RelayInfo { region: region.into(), url: format!("ws://{address}/v1/relay") });
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = CoordConfig {
        database: dir.join("coord.sqlite"),
        admin_token: ADMIN.into(),
        ticket_key: authority,
        relays,
    };
    tokio::spawn(serve_coord(listener, config));
    let coord = format!("http://{address}");
    let admin = AdminClient::new(&coord, ADMIN);
    Net { coord, admin, dir }
}

const POLICY: &str = r#"{
  "tagOwners": { "tag:server": [], "tag:client": [] },
  "acls": [ { "action": "accept", "src": ["tag:client"], "dst": ["tag:server:7"] } ]
}"#;

async fn tagged_node(
    net: &Net,
    tailnet: &str,
    tag: &str,
    name: &str,
    preapproved: bool,
) -> WeftNode {
    let key = net
        .admin
        .mint_auth_key(
            tailnet,
            &MintAuthKey {
                tags: vec![tag.into()],
                user: None,
                reusable: false,
                preapproved,
                ttl_seconds: 600,
            },
        )
        .await
        .unwrap();
    let options = JoinOptions {
        coord: net.coord.clone(),
        tailnet: tailnet.into(),
        auth_key: key,
        name: name.into(),
    };
    WeftNode::join(&net.dir.join(format!("{name}.json")), Some(options)).await.unwrap()
}

async fn echo_once(node: &WeftNode, target: SocketAddr) -> Result<(), String> {
    let mut stream = tokio::time::timeout(Duration::from_secs(5), node.connect(target))
        .await
        .map_err(|_| "connect timeout".to_string())?
        .map_err(|error| error.to_string())?;
    stream.write_all(b"weft-ping").await.map_err(|error| error.to_string())?;
    let mut buffer = [0u8; 9];
    tokio::time::timeout(Duration::from_secs(5), stream.read_exact(&mut buffer))
        .await
        .map_err(|_| "timeout".to_string())?
        .map_err(|error| error.to_string())?;
    if &buffer == b"weft-ping" { Ok(()) } else { Err("wrong bytes".into()) }
}

/// Retry until `check` holds; the netmap reaches clients by long-poll.
async fn eventually<F, Fut>(what: &str, mut check: F)
where
    F: FnMut() -> Fut,
    Fut: Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + STEP;
    while tokio::time::Instant::now() < deadline {
        if check().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("never happened: {what}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn allowed_traffic_flows_and_denied_traffic_is_cut() {
    let net = start_net().await;
    net.admin.create_tailnet("acme", false).await.unwrap();
    net.admin.set_policy("acme", POLICY, None).await.unwrap();

    let server = tagged_node(&net, "acme", "tag:server", "server", true).await;
    let client = tagged_node(&net, "acme", "tag:client", "client", true).await;
    server.serve(7, Service::Echo).await.unwrap();
    client.serve(7, Service::Echo).await.unwrap();
    let server_echo = SocketAddr::new(server.address().into(), 7);
    let client_echo = SocketAddr::new(client.address().into(), 7);

    eventually("client reaches server:7 through the relay", || async {
        echo_once(&client, server_echo).await.is_ok()
    })
    .await;

    // The server knows the client (the client may reach it), but the
    // client's filter allows nothing from the server: refused at the receiver.
    for _ in 0..3 {
        assert!(echo_once(&server, client_echo).await.is_err(), "server must not reach client:7");
    }
    // A port the rule does not name is refused too.
    server.serve(8, Service::Echo).await.unwrap();
    assert!(echo_once(&client, SocketAddr::new(server.address().into(), 8)).await.is_err());

    // Remove the rule: the server leaves the client's netmap.
    net.admin
        .set_policy("acme", r#"{"tagOwners":{"tag:server":[],"tag:client":[]}}"#, None)
        .await
        .unwrap();
    eventually("policy removal cuts the client off", || async {
        echo_once(&client, server_echo).await.is_err()
    })
    .await;

    // Restore, then revoke the client.
    net.admin.set_policy("acme", POLICY, None).await.unwrap();
    eventually("restored policy lets the client back", || async {
        echo_once(&client, server_echo).await.is_ok()
    })
    .await;
    net.admin.revoke_node("acme", client.node_id()).await.unwrap();
    eventually("revocation cuts the client off", || async {
        echo_once(&client, server_echo).await.is_err()
    })
    .await;

    let audit = net.admin.audit("acme").await.unwrap();
    let actions: Vec<_> = audit.iter().map(|entry| entry.action.as_str()).collect();
    for expected in ["tailnet.create", "policy.set", "authkey.mint", "node.register", "node.revoke"]
    {
        assert!(actions.contains(&expected), "audit lacks {expected}: {actions:?}");
    }
    server.shutdown().await;
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pending_device_sees_nobody_until_approved() {
    let net = start_net().await;
    net.admin.create_tailnet("approve", true).await.unwrap();
    net.admin.set_policy("approve", POLICY, None).await.unwrap();
    let server = tagged_node(&net, "approve", "tag:server", "server", true).await;
    server.serve(7, Service::Echo).await.unwrap();
    let client = tagged_node(&net, "approve", "tag:client", "client", false).await;
    assert_eq!(client.state(), NodeState::Pending);
    assert!(client.netmap().peers.is_empty());
    let target = SocketAddr::new(server.address().into(), 7);
    assert!(echo_once(&client, target).await.is_err());

    net.admin.approve_node("approve", client.node_id()).await.unwrap();
    eventually("approved client reaches the server", || async {
        echo_once(&client, target).await.is_ok()
    })
    .await;
    assert_eq!(client.state(), NodeState::Approved);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rotation_keeps_the_address_and_replaces_the_key() {
    let net = start_net().await;
    net.admin.create_tailnet("rot", false).await.unwrap();
    net.admin.set_policy("rot", POLICY, None).await.unwrap();
    let server = tagged_node(&net, "rot", "tag:server", "server", true).await;
    server.serve(7, Service::Echo).await.unwrap();
    let client = tagged_node(&net, "rot", "tag:client", "client", true).await;
    let target = SocketAddr::new(server.address().into(), 7);
    eventually("first contact", || async { echo_once(&client, target).await.is_ok() }).await;

    let before = client.node_key();
    let address = client.address();
    client.rotate().await.unwrap();
    assert_ne!(client.node_key(), before);
    assert_eq!(client.address(), address);
    eventually("traffic after rotation", || async { echo_once(&client, target).await.is_ok() })
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_control_plane_refuses_bad_credentials() {
    let net = start_net().await;
    let stranger = AdminClient::new(&net.coord, "wrong-token");
    assert!(stranger.create_tailnet("x", false).await.is_err());
    net.admin.create_tailnet("keys", false).await.unwrap();
    net.admin.set_policy("keys", POLICY, None).await.unwrap();

    // A made-up auth key does not register.
    let options = JoinOptions {
        coord: net.coord.clone(),
        tailnet: "keys".into(),
        auth_key: "weftkey-00000000000000000000000000000000".into(),
        name: "intruder".into(),
    };
    assert!(WeftNode::join(&net.dir.join("intruder.json"), Some(options)).await.is_err());

    // A single-use key works once.
    let key = net
        .admin
        .mint_auth_key(
            "keys",
            &MintAuthKey {
                tags: vec!["tag:client".into()],
                user: None,
                reusable: false,
                preapproved: true,
                ttl_seconds: 600,
            },
        )
        .await
        .unwrap();
    let first = JoinOptions {
        coord: net.coord.clone(),
        tailnet: "keys".into(),
        auth_key: key.clone(),
        name: "first".into(),
    };
    WeftNode::join(&net.dir.join("first.json"), Some(first)).await.unwrap();
    let second = JoinOptions {
        coord: net.coord.clone(),
        tailnet: "keys".into(),
        auth_key: key,
        name: "second".into(),
    };
    assert!(WeftNode::join(&net.dir.join("second.json"), Some(second)).await.is_err());

    // An unknown tag cannot be minted, and a stale policy version is refused.
    let error = net
        .admin
        .mint_auth_key(
            "keys",
            &MintAuthKey {
                tags: vec!["tag:nope".into()],
                user: None,
                reusable: false,
                preapproved: true,
                ttl_seconds: 600,
            },
        )
        .await;
    assert!(error.is_err());
    assert!(net.admin.set_policy("keys", POLICY, Some(0)).await.is_err());
}
