//! Seeded secrets on the wire (cmux_egress::capture) for the relay's pairing and session
//! connects. tests/egress_seeded.json names these tests for the `chatmux_relay`,
//! `chatmux_relay::pairing` and `chatmux_relay::session` gate sites. The capture server answers
//! a WebSocket upgrade with `200 {}`, so for the two sockets what it sees is the upgrade request:
//! the secrets the relay sends as frames after the upgrade must not ride in its URL or headers.

use std::time::Duration;

use cmux_egress::capture;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::pairing::{CeremonyMode, await_ceremony, start_pairing};
use crate::session::{SessionState, stay_online};

const HOST: &str = "api.chatmux.dev";
const BACKEND: &str = "https://api.chatmux.dev";

fn install() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
}

/// The pairing start through main.rs's client (`cmux_egress::client("chatmux_relay")`): the
/// machine's name rides only in the body, and the pairing secret (the QR/link secret that
/// proves the ceremony) never leaves the machine, only its hash.
#[tokio::test]
async fn pairing_start_sends_the_name_in_the_body_and_never_the_secret() {
    install();
    let http = cmux_egress::client("chatmux_relay").unwrap();
    let name = "SEEDrelayMachineName-a41f";
    let started = start_pairing(&http, BACKEND, name, "linux").await.unwrap();
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target == "/v2/pairing/start"), "{sent:?}");
    assert_eq!(
        capture::leaks(name),
        [format!("{HOST} POST /v2/pairing/start: body")],
        "the name rides only in the start body"
    );
    assert!(capture::leaks(&started.secret).is_empty(), "{:?}", capture::leaks(&started.secret));
}

/// The ceremony socket (`chatmux_relay::pairing`): the secret goes in the `authenticate` frame
/// after the upgrade, so the upgrade request carries neither it nor the machine's name.
#[tokio::test]
async fn ceremony_upgrade_carries_neither_the_secret_nor_the_name() {
    install();
    let http = cmux_egress::client("chatmux_relay").unwrap();
    let name = "SEEDceremonyMachineName-7b03";
    let started = start_pairing(&http, BACKEND, "seeded-ceremony", "linux").await.unwrap();
    let outcome = await_ceremony(BACKEND, &started, CeremonyMode::Url, name, "linux").await;
    assert!(outcome.is_err(), "the capture server never upgrades");
    let socket = format!("/v2/pairing/{}/socket", started.pair_id);
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target == socket), "the upgrade reached capture: {sent:?}");
    assert!(capture::leaks(&started.secret).is_empty(), "{:?}", capture::leaks(&started.secret));
    assert!(capture::leaks(name).is_empty(), "{:?}", capture::leaks(name));
}

/// The relay socket (`chatmux_relay::session`): the relay token, the owner and the allowed roots
/// go in the `hello` frame after the upgrade, so the upgrade request carries none of them.
#[tokio::test]
async fn session_upgrade_carries_no_token_owner_or_root() {
    install();
    let token = "SEEDrelayToken-0c5e";
    let owner = "SEEDownerUserId-d2a9";
    let root = "/home/SEEDpersonRoot-6f18/code";
    let name = "SEEDsessionMachineName-913b";
    let config = Config {
        version: Some(2),
        backend: BACKEND.to_owned(),
        device_id: "seeded-session-device".to_owned(),
        token: token.to_owned(),
        name: Some(name.to_owned()),
        owner_user_id: Some(owner.to_owned()),
        allowed_roots: Some(vec![root.to_owned()]),
        ..Config::default()
    };
    let dir = std::env::temp_dir().join(format!("chatmux-relay-seeded-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let cancellation = CancellationToken::new();
    let state = SessionState { first_connect: true, first_run: false, managed: false };
    let socket = "/v2/relays/seeded-session-device/socket";
    let upgraded = async {
        while !capture::requests_to(HOST).iter().any(|r| r.target == socket) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    let online = stay_online(config, &path, state, cancellation.clone());
    tokio::select! {
        ended = online => panic!("stay_online ended before the upgrade reached capture: {ended:?}"),
        seen = tokio::time::timeout(Duration::from_secs(20), upgraded) => {
            seen.expect("no upgrade reached capture");
        }
    }
    cancellation.cancel();
    let _ = std::fs::remove_dir_all(&dir);
    for secret in [token, owner, root, name] {
        assert!(capture::leaks(secret).is_empty(), "{secret}: {:?}", capture::leaks(secret));
    }
}
