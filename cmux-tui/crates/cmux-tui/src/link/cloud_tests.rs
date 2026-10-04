//! Cloud host dials: resolve through connect_info, check the record, use
//! each token once, refetch once on a failed handshake, map the errors.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::Mutex;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::connect_info::{ConnectInfo, ConnectInfoError};
use cmux_link::dial::PathState;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncBufReadExt, BufReader, DuplexStream};

use super::super::dial::{Overlay, serve_dial_line};
use super::*;

const HOST: &str = "host_vm1";

fn record(token: &str, state: &str, services: &[&str]) -> ConnectInfo {
    serde_json::from_value(serde_json::json!({
        "machine": "vm_1", "host": HOST, "epoch": 4, "state": state,
        "peer": {"wg_public_key": STANDARD.encode([9u8; 32]),
                 "overlay_address": overlay_address(HOST).to_string(),
                 "vpc_endpoint": "[fd00::9]:4101"},
        "gateway": null, "services": services,
        "link_token": {"token": token, "expires_at": "2026-10-05T00:05:00Z"},
        "revision": 1
    }))
    .unwrap()
}

#[derive(Default)]
struct FakeSource {
    answers: Mutex<VecDeque<Result<ConnectInfo, ConnectInfoError>>>,
    calls: Mutex<usize>,
}

impl FakeSource {
    fn with(answers: Vec<Result<ConnectInfo, ConnectInfoError>>) -> Self {
        Self { answers: Mutex::new(answers.into()), calls: Mutex::new(0) }
    }
}

impl ConnectInfoSource for FakeSource {
    async fn fetch(&self, _host: &str) -> Result<ConnectInfo, ConnectInfoError> {
        *self.calls.lock().unwrap() += 1;
        self.answers.lock().unwrap().pop_front().expect("no more connect_info answers")
    }
}

#[derive(Default)]
struct CloudOverlay {
    peers: Mutex<Vec<(String, [u8; 32])>>,
    connects: Mutex<Vec<SocketAddr>>,
    far_ends: Mutex<Vec<DuplexStream>>,
    fail: bool,
}

impl Overlay for CloudOverlay {
    type Stream = DuplexStream;

    async fn connect(&self, remote: SocketAddr) -> std::io::Result<DuplexStream> {
        self.connects.lock().unwrap().push(remote);
        if self.fail {
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "no handshake"));
        }
        let (near, far) = tokio::io::duplex(64 * 1024);
        self.far_ends.lock().unwrap().push(far);
        Ok(near)
    }

    async fn sync_peers(&self, _pairings: &Pairings) -> std::io::Result<()> {
        Ok(())
    }

    async fn set_cloud_peer(
        &self,
        host: &str,
        key: [u8; 32],
        _info: &ConnectInfo,
    ) -> std::io::Result<()> {
        self.peers.lock().unwrap().push((host.to_string(), key));
        Ok(())
    }

    async fn forget_cloud_peer(&self, _host: &str) -> std::io::Result<()> {
        Ok(())
    }

    async fn path_state(&self, _key: &[u8; 32]) -> PathState {
        PathState::Tunnel
    }
}

/// Dial `host` for `service` and return the reply line.
async fn dial(
    overlay: &CloudOverlay,
    resolver: &CloudResolver<FakeSource>,
    host: &str,
    service: &str,
) -> (String, DuplexStream) {
    let (caller, link_side) = tokio::io::duplex(64 * 1024);
    let request = format!(r#"{{"op":"link.dial","host":"{host}","service":"{service}"}}"#);
    let mut caller = BufReader::new(caller);
    let pairings = Pairings::default();
    let serve = serve_dial_line(link_side, &request, overlay, &pairings, resolver);
    // Read the reply, then hang up, so a dial that wrongly succeeds ends
    // and the assertions report it instead of a hang.
    let read = async move {
        let mut reply = String::new();
        caller.read_line(&mut reply).await.unwrap();
        reply
    };
    let ((), reply) = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        tokio::join!(serve, read)
    })
    .await
    .expect("the dial ends within 20 s");
    let (_, idle) = tokio::io::duplex(1);
    (reply, idle)
}

/// Serve a dial in the background and return the caller's side.
fn spawn_dial(
    overlay: &'static CloudOverlay,
    resolver: &'static CloudResolver<FakeSource>,
) -> tokio::task::JoinHandle<String> {
    tokio::spawn(async move {
        let (caller, link_side) = tokio::io::duplex(64 * 1024);
        let request = format!(r#"{{"op":"link.dial","host":"{HOST}","service":"daemon"}}"#);
        tokio::spawn(async move {
            serve_dial_line(link_side, &request, overlay, &Pairings::default(), resolver).await;
        });
        let mut caller = BufReader::new(caller);
        let mut reply = String::new();
        caller.read_line(&mut reply).await.unwrap();
        reply
    })
}

async fn hello_on(overlay: &CloudOverlay, index: usize) -> String {
    let far = overlay.far_ends.lock().unwrap().remove(index);
    let mut hello = String::new();
    BufReader::new(far).read_line(&mut hello).await.unwrap();
    hello
}

#[tokio::test]
async fn a_cloud_dial_sends_a_fresh_single_use_token_and_reports_the_path() {
    let overlay: &'static CloudOverlay = Box::leak(Box::default());
    let resolver: &'static CloudResolver<FakeSource> = Box::leak(Box::new(CloudResolver::new(
        FakeSource::with(vec![
            Ok(record("t1", "running", &["daemon"])),
            Ok(record("t2", "running", &["daemon"])),
        ]),
    )));
    let reply = spawn_dial(overlay, resolver).await.unwrap();
    assert_eq!(reply, "{\"ok\":true,\"path_state\":\"tunnel\",\"relay_available\":false}\n");
    assert_eq!(hello_on(overlay, 0).await, "{\"service\":\"daemon\",\"link_token\":\"t1\",\"epoch\":4}\n");
    // The next dial asks again: a token is used for one hello only.
    spawn_dial(overlay, resolver).await.unwrap();
    assert_eq!(hello_on(overlay, 0).await, "{\"service\":\"daemon\",\"link_token\":\"t2\",\"epoch\":4}\n");
    assert_eq!(*resolver.source.calls.lock().unwrap(), 2);
    assert_eq!(overlay.peers.lock().unwrap()[0], (HOST.to_string(), [9u8; 32]));
    assert_eq!(overlay.connects.lock().unwrap()[0].ip(), overlay_address(HOST));
}

/// RED (security): a record whose overlay address is not our derivation of
/// the host id is never configured or dialed.
#[tokio::test]
async fn a_record_with_a_foreign_overlay_address_is_never_dialed() {
    let overlay = CloudOverlay::default();
    let mut foreign = record("t1", "running", &["daemon"]);
    foreign.peer.overlay_address = overlay_address("host_other");
    let resolver = CloudResolver::new(FakeSource::with(vec![Ok(foreign)]));
    let (reply, _) = dial(&overlay, &resolver, HOST, "daemon").await;
    assert!(reply.contains("\"error_code\":\"unreachable\""), "{reply}");
    assert!(overlay.peers.lock().unwrap().is_empty());
    assert!(overlay.connects.lock().unwrap().is_empty());
}

/// RED (security): a service the host's policy does not list is refused
/// before anything is dialed.
#[tokio::test]
async fn a_service_the_policy_does_not_allow_is_refused() {
    let overlay = CloudOverlay::default();
    let resolver =
        CloudResolver::new(FakeSource::with(vec![Ok(record("t1", "running", &["daemon"]))]));
    let (reply, _) = dial(&overlay, &resolver, HOST, "ssh").await;
    assert!(reply.contains("\"error_code\":\"not_authorized\""), "{reply}");
    assert!(overlay.connects.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_failed_handshake_refetches_once_then_reports_paused_or_unreachable() {
    for (state, code) in [("paused", "host_paused"), ("running", "unreachable")] {
        let overlay = CloudOverlay { fail: true, ..CloudOverlay::default() };
        let resolver = CloudResolver::new(FakeSource::with(vec![
            Ok(record("t1", state, &["daemon"])),
            Ok(record("t2", state, &["daemon"])),
        ]));
        let (reply, _) = dial(&overlay, &resolver, HOST, "daemon").await;
        assert!(reply.contains(&format!("\"error_code\":\"{code}\"")), "{state}: {reply}");
        assert_eq!(*resolver.source.calls.lock().unwrap(), 2, "{state}: one refetch");
        assert_eq!(overlay.connects.lock().unwrap().len(), 2, "{state}");
    }
}

#[tokio::test]
async fn backend_errors_and_unknown_ids_map_to_dial_errors() {
    let overlay = CloudOverlay::default();
    for (error, code) in [
        (ConnectInfoError::NotFound, "unknown_host"),
        (ConnectInfoError::Forbidden, "not_authorized"),
        (ConnectInfoError::NotBound, "unreachable"),
    ] {
        let resolver = CloudResolver::new(FakeSource::with(vec![Err(error)]));
        let (reply, _) = dial(&overlay, &resolver, HOST, "daemon").await;
        assert!(reply.contains(&format!("\"error_code\":\"{code}\"")), "{reply}");
    }
    // Neither paired nor a Cloud host id: connect_info is never asked.
    let resolver = CloudResolver::new(FakeSource::default());
    let (reply, _) = dial(&overlay, &resolver, "inst_unpaired", "daemon").await;
    assert!(reply.contains("\"error_code\":\"unknown_host\""), "{reply}");
    assert_eq!(*resolver.source.calls.lock().unwrap(), 0);
    assert!(overlay.connects.lock().unwrap().is_empty());
}

#[tokio::test]
async fn removed_and_newer_records_leave_the_cache() {
    let resolver =
        CloudResolver::new(FakeSource::with(vec![Ok(record("t1", "running", &["daemon"]))]));
    let resolved = resolver.resolve(HOST).await.unwrap();
    assert!(resolved.info.link_token.is_none());
    assert_eq!(resolved.token.unwrap().token, "t1");
    assert!(resolver.observe_revision(HOST, 2));
    assert!(!resolver.forget(HOST));
}

#[tokio::test]
async fn forwarded_cloud_events_drop_records_and_peers() {
    use cmux_link::dial::{CloudEvent, CloudEventOp, CloudEventRequest};
    let overlay = CloudOverlay::default();
    let resolver =
        CloudResolver::new(FakeSource::with(vec![Ok(record("t1", "running", &["daemon"]))]));
    resolver.resolve(HOST).await.unwrap();
    let event = |event, revision| CloudEventRequest {
        op: CloudEventOp::CloudEvent,
        event,
        host: HOST.into(),
        revision,
    };
    assert!(apply_cloud_event(&event(CloudEvent::Upsert, Some(1)), &overlay, &resolver).await);
    assert!(!apply_cloud_event(&event(CloudEvent::Upsert, None), &overlay, &resolver).await);
    assert!(apply_cloud_event(&event(CloudEvent::Removed, None), &overlay, &resolver).await);
    assert!(!resolver.forget(HOST), "removed dropped the record");
    let mut paired = event(CloudEvent::Removed, None);
    paired.host = "inst_x".into();
    assert!(!apply_cloud_event(&paired, &overlay, &resolver).await);
}

#[tokio::test]
async fn the_relay_source_is_off_until_the_relay_ships() {
    let resolver = CloudResolver::new(RelaySource);
    assert!(matches!(
        resolver.resolve(HOST).await,
        Err(ConnectInfoError::Unavailable(_))
    ));
}
