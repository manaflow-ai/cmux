//! Pairing snapshots and their watch subscriptions are acquired separately.
//! Exercise those interleavings against a private Unix brain, without sleeps.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::owner_session::{OwnerRefused, OwnerSession};
use cmux_link::pairing::{PairingRecord, Pairings};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::inbound::{InboundRefused, Revocations, serve_inbound_watched};

const KEY: [u8; 32] = [2; 32];
const IDENTIFY: &str = "{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"capabilities\":[\"workspace-registry-v1\",\"agent-session-tabs-v1\"]}}\n";
const REQUEST: &str = "{\"id\":7,\"cmd\":\"list-workspaces\"}\n";

fn record() -> PairingRecord {
    PairingRecord {
        install: "inst_b".into(),
        user: "42".into(),
        team: "team_a".into(),
        public_key: STANDARD.encode(KEY),
        endpoint: None,
    }
}

fn pairings(record: Option<PairingRecord>) -> Pairings {
    let mut pairings = Pairings::default();
    if let Some(record) = record {
        pairings.upsert(record).unwrap();
    }
    pairings
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(3), future).await.expect("bounded owner admission")
}

/// The accepted transport captured the old record, then subscribed after the
/// pairing view had already changed. No further watch notification will arrive.
async fn initial_view(fresh: Pairings, allowed: bool) {
    let directory = cmux_unix_socket::short_test_dir("ownadm");
    let home = directory.path().join("brain");
    std::fs::create_dir_all(home.join("daemon")).unwrap();
    let socket = home.join("daemon/s.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let brain = tokio::spawn(async move {
        let (probe, _) = listener.accept().await.unwrap();
        let mut probe = BufReader::new(probe);
        let mut line = String::new();
        probe.read_line(&mut line).await.unwrap();
        probe.get_mut().write_all(IDENTIFY.as_bytes()).await.unwrap();
        drop(probe);
        let (session, _) = listener.accept().await.unwrap();
        let mut session = BufReader::new(session);
        let mut request = String::new();
        session.read_line(&mut request).await.unwrap();
        request
    });
    let owner = OwnerSession {
        owner_user: "42".into(),
        owner_team: "team_a".into(),
        socket,
        brain_home: home,
    };
    let (_sender, view) = tokio::sync::watch::channel(Arc::new(fresh));
    let dummy_session = directory.path().join("unused.sock");
    let (mut peer, inbound) = tokio::io::duplex(64 * 1024);
    let handler = tokio::spawn(async move {
        serve_inbound_watched(
            inbound,
            KEY,
            SocketAddr::new(IpAddr::V6(overlay_address("inst_b")), 1234),
            &pairings(Some(record())),
            &dummy_session,
            Some(&owner),
            Some(Revocations { view, open: Arc::default() }),
        )
        .await
    });
    peer.write_all(format!("{{\"service\":\"owner_session\"}}\n{REQUEST}").as_bytes())
        .await
        .unwrap();
    let _ = peer.shutdown().await;
    let served = within(handler).await.unwrap();
    brain.abort();
    let forwarded = brain.await.ok();
    drop(peer);
    if allowed {
        assert_eq!(served, Ok(()));
        assert_eq!(forwarded.as_deref(), Some(REQUEST));
    } else {
        assert_eq!(
            served,
            Err(InboundRefused::Owner(OwnerRefused::NotOwner)),
            "the current pairing view is authoritative"
        );
        assert_eq!(forwarded, None, "a stale pairing cannot forward a client request");
    }
}

#[tokio::test]
async fn owner_session_refuses_a_key_removed_before_watch_subscription() {
    initial_view(pairings(None), false).await;
}

#[tokio::test]
async fn owner_session_refuses_a_key_reassigned_to_another_user_before_subscription() {
    let mut fresh = record();
    fresh.user = "another_user".into();
    initial_view(pairings(Some(fresh)), false).await;
}

#[tokio::test]
async fn owner_session_refuses_a_key_reassigned_to_another_team_before_subscription() {
    let mut fresh = record();
    fresh.team = "another_team".into();
    initial_view(pairings(Some(fresh)), false).await;
}

#[tokio::test]
async fn owner_session_refuses_a_key_reassigned_to_another_install_before_subscription() {
    let mut fresh = record();
    fresh.install = "inst_replaced".into();
    initial_view(pairings(Some(fresh)), false).await;
}

#[tokio::test]
async fn owner_session_keeps_a_current_pairing_usable() {
    initial_view(pairings(Some(record())), true).await;
}

#[tokio::test]
async fn owner_session_rechecks_revocation_after_the_brain_probe() {
    let directory = cmux_unix_socket::short_test_dir("ownprobe");
    let home = directory.path().join("brain");
    std::fs::create_dir_all(home.join("daemon")).unwrap();
    let socket = home.join("daemon/s.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let (probed, probe_entered) = tokio::sync::oneshot::channel();
    let (release, released) = tokio::sync::oneshot::channel();
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let brain = tokio::spawn(async move {
        let (probe, _) = listener.accept().await.unwrap();
        let mut probe = BufReader::new(probe);
        let mut line = String::new();
        probe.read_line(&mut line).await.unwrap();
        probed.send(()).unwrap();
        released.await.unwrap();
        probe.get_mut().write_all(IDENTIFY.as_bytes()).await.unwrap();
        drop(probe);
        // Accept a queued session before the stop signal, even when both are
        // ready: the oracle measures whether a new trusted socket was opened.
        tokio::select! {
            biased;
            session = listener.accept() => {
                let (session, _) = session.unwrap();
                let mut session = BufReader::new(session);
                let mut request = String::new();
                session.read_line(&mut request).await.unwrap();
                Some(request)
            }
            _ = stopped => None,
        }
    });
    let owner = OwnerSession {
        owner_user: "42".into(),
        owner_team: "team_a".into(),
        socket,
        brain_home: home,
    };
    let (sender, view) = tokio::sync::watch::channel(Arc::new(pairings(Some(record()))));
    let dummy_session = directory.path().join("unused.sock");
    let (mut peer, inbound) = tokio::io::duplex(64 * 1024);
    let handler = tokio::spawn(async move {
        serve_inbound_watched(
            inbound,
            KEY,
            SocketAddr::new(IpAddr::V6(overlay_address("inst_b")), 1234),
            &pairings(Some(record())),
            &dummy_session,
            Some(&owner),
            Some(Revocations { view, open: Arc::default() }),
        )
        .await
    });
    peer.write_all(format!("{{\"service\":\"owner_session\"}}\n{REQUEST}").as_bytes())
        .await
        .unwrap();
    let _ = peer.shutdown().await;
    within(probe_entered).await.unwrap();
    sender.send_replace(Arc::new(Pairings::default()));
    release.send(()).unwrap();
    let served = within(handler).await.unwrap();
    let _ = stop.send(());
    let accepted = within(brain).await.unwrap();
    drop(peer);
    assert_eq!(served, Err(InboundRefused::Owner(OwnerRefused::NotOwner)));
    assert_eq!(accepted, None, "revocation during identify must fence the trusted session connect");
}
