//! Mux input and compressed lines are negotiated independently on each open.

#![cfg(unix)]

use super::wire_lockstep::{manifests, pair};
use super::*;
use crate::acpmux_bridge::tests::within;
use crate::bridge::OpenedMuxControl;
use cmux_wire_lockstep::{Dir, OldPeer};

/// Exercise the base as shipped and a peer that omits the optional features
/// from this open, even when the test runs with today's manifest on both ends.
fn old_mux_peers(base: OldPeer) -> [OldPeer; 2] {
    let mut legacy = base.manifest().clone();
    legacy.capabilities.remove(MUX_INPUT_V1_FEATURE);
    legacy.capabilities.remove(MUX_LINE_ZLIB_V1_FEATURE);
    [base, OldPeer::new(legacy)]
}

#[tokio::test]
async fn wire_lockstep_new_mux_client_uses_only_advertised_input_encoding() {
    let (head, base) = manifests();
    for old in old_mux_peers(base) {
        let (client, daemon, tap) = pair(EndpointRole::Client, &head, &old);
        let input = old.lists(MUX_INPUT_V1_FEATURE);
        let packet = within(async {
            let accept = async {
                let incoming = daemon.accept().await.unwrap().unwrap();
                assert_eq!(incoming.service, Service::MuxControl);
                let mut features = Vec::new();
                if input {
                    features.push(MUX_INPUT_V1_FEATURE);
                }
                if old.lists(MUX_LINE_ZLIB_V1_FEATURE) && mux_line_zlib_requested(&incoming.metadata)
                {
                    features.push(MUX_LINE_ZLIB_V1_FEATURE);
                }
                let opened = serde_json::json!({
                    "type": "opened", "service": "mux-control", "features": features
                });
                let bytes = Bytes::from(serde_json::to_vec(&opened).unwrap());
                for lane in [Lane::Interactive, Lane::Control, Lane::Bulk] {
                    incoming.stream.send_on(lane, bytes.clone()).await.unwrap();
                }
                incoming.stream
            };
            let (opened, old_stream) = tokio::join!(OpenedMuxControl::open(&client), accept);
            let (mut app, local) = tokio::io::duplex(1024);
            let (reader, writer) = tokio::io::split(local);
            let send = br#"{"id":1,"cmd":"send","no_reply":true,"surface":1,"bytes":"eA=="}"#;
            app.write_all(send).await.unwrap();
            app.write_all(b"\n").await.unwrap();
            tokio::select! {
                result = opened.unwrap().bridge(reader, writer) => panic!("bridge ended early: {result:?}"),
                chunk = old_stream.receive() => chunk.unwrap().unwrap().payload,
            }
        }).await;
        let magic = if input { "CMXI" } else { "CMXL" };
        assert!(packet.starts_with(magic.as_bytes()), "expected {magic}");
        assert!(tap.seen().contains(&(Dir::Sent, format!("header:{magic}"))));
        tap.assert_lockstep(&head, &old);
        client.shutdown().await;
        daemon.shutdown().await;
    }
}

#[tokio::test]
async fn wire_lockstep_new_mux_daemon_compresses_only_for_a_client_that_lists_zlib() {
    let (head, base) = manifests();
    let line = crate::mux_codec::tests::chat_attach_line();
    for old in old_mux_peers(base) {
        let (client, daemon, tap) = pair(EndpointRole::Daemon, &head, &old);
        let zlib = old.lists(MUX_LINE_ZLIB_V1_FEATURE);
        let directory = tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let services = DaemonServices::new(WorkspaceService::new(), Some(path));
        let metadata = if zlib {
            BTreeMap::from([(MUX_CONTROL_LINE_CODECS.to_owned(), MUX_LINE_CODEC_ZLIB.to_owned())])
        } else {
            BTreeMap::new()
        };
        let (features, packets) = within(async {
            let stream = client.open(Service::MuxControl, metadata).await.unwrap();
            let incoming = daemon.accept().await.unwrap().unwrap();
            let serve = services.serve_stream(
                ClientScope::new("old-mux-client", cmux_remote_protocol::SessionId([7; 16])),
                RequestAdmission::new(),
                None,
                None,
                incoming,
            );
            let read = async {
                let (mut socket, _) = listener.accept().await.unwrap();
                socket.write_all(&line).await.unwrap();
                opened_features_and_packets(&stream).await
            };
            tokio::select! {
                result = serve => panic!("daemon ended early: {result:?}"),
                received = read => received,
            }
        })
        .await;
        let magic = if zlib { "CMXZ" } else { "CMXL" };
        assert_eq!(features.iter().any(|f| f == MUX_LINE_ZLIB_V1_FEATURE), zlib);
        assert!(!packets.is_empty() && packets.iter().all(|p| p.starts_with(magic.as_bytes())));
        assert!(tap.seen().contains(&(Dir::Sent, format!("header:{magic}"))));
        tap.assert_lockstep(&head, &old);
        client.shutdown().await;
        daemon.shutdown().await;
    }
}
