//! Version skew across the workspace RPC channel: a peer built from a newer
//! commit sends shapes this build does not know. Each costs that one message,
//! never the channel (which, before, meant a reconnect and a full snapshot).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::tests::endpoint_pair;
use super::*;
use crate::client::WorkspaceClient;
use cmux_remote_protocol::RequestId;

const SKEWED: usize = 3;

fn lane_of(metadata: &BTreeMap<String, String>) -> Lane {
    match metadata.get("lane").map(String::as_str) {
        Some("interactive") => Lane::Interactive,
        Some("bulk") => Lane::Bulk,
        _ => Lane::Control,
    }
}

#[tokio::test(flavor = "current_thread")]
async fn a_newer_clients_unknown_requests_leave_the_daemon_channel_open() {
    tokio::task::LocalSet::new().run_until(newer_client_requests()).await;
}

async fn newer_client_requests() {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let services = DaemonServices::new(WorkspaceService::new(), None);
    let server = tokio::task::spawn_local({
        let daemon_multiplexer = daemon_multiplexer.clone();
        async move {
            let incoming = daemon_multiplexer.accept().await.unwrap().unwrap();
            let scope = ClientScope::new("skew-request", cmux_remote_protocol::SessionId([3; 16]));
            services.serve_stream(scope, RequestAdmission::new(), None, None, incoming).await
        }
    });

    let stream = client_multiplexer
        .open(Service::WorkspaceRpc, BTreeMap::from([("lane".into(), "control".into())]))
        .await
        .unwrap();
    let opened = stream.receive().await.unwrap().unwrap();
    assert!(matches!(
        serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
        ServiceControl::Opened { .. }
    ));
    let messages = MessageStream::with_lane(Arc::new(stream), Lane::Control);

    let before = skew::SKEW.tally();
    for index in 0..SKEWED {
        let id = RequestId::from_u128(0x5e00 + index as u128);
        let newer = format!(r#"{{"id":"{id}","request":{{"type":"from-the-future","x":1}}}}"#);
        messages.send(newer.as_bytes()).await.unwrap();
        let reply: RpcResponse =
            serde_json::from_slice(&messages.receive().await.unwrap().unwrap()).unwrap();
        assert_eq!(reply.id, id);
        assert_eq!(reply.result.unwrap_err().code, skew::UNSUPPORTED_REQUEST);
    }
    // The same channel still serves a request this daemon knows.
    let id = RequestId::from_u128(0x5eff);
    let known = RpcRequest { id, timeout_ms: None, request: WorkspaceRequest::Capabilities };
    messages.send(&serde_json::to_vec(&known).unwrap()).await.unwrap();
    let reply: RpcResponse =
        serde_json::from_slice(&messages.receive().await.unwrap().unwrap()).unwrap();
    assert_eq!(reply.id, id);
    assert!(matches!(reply.result, Ok(WorkspaceResponse::Capabilities { .. })));
    let after = skew::SKEW.tally();
    assert!(after.unsupported_requests >= before.unsupported_requests + SKEWED as u64);

    drop(messages);
    client_multiplexer.shutdown().await;
    daemon_multiplexer.shutdown().await;
    let _ = server.await;
}

#[tokio::test]
async fn a_newer_daemons_unknown_responses_fail_only_their_own_request() {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client_multiplexer = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon_multiplexer = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let replies = Arc::new(AtomicUsize::new(0));
    let opens = Arc::new(AtomicUsize::new(0));
    let server = tokio::spawn({
        let daemon_multiplexer = daemon_multiplexer.clone();
        let replies = replies.clone();
        let opens = opens.clone();
        async move {
            // A fake newer daemon: its first replies carry a response shape
            // this client has never seen.
            while let Ok(Some(incoming)) = daemon_multiplexer.accept().await {
                opens.fetch_add(1, Ordering::Relaxed);
                let lane = lane_of(&incoming.metadata);
                let stream = Arc::new(incoming.stream);
                send_opened(&stream, lane).await.unwrap();
                let replies = replies.clone();
                tokio::spawn(async move {
                    let messages = MessageStream::with_lane(stream, lane);
                    while let Ok(Some(encoded)) = messages.receive().await {
                        let request: RpcRequest = serde_json::from_slice(&encoded).unwrap();
                        let reply = if replies.fetch_add(1, Ordering::Relaxed) < SKEWED {
                            format!(
                                r#"{{"id":"{}","result":{{"Ok":{{"type":"from-the-future"}}}}}}"#,
                                request.id
                            )
                            .into_bytes()
                        } else {
                            serde_json::to_vec(&RpcResponse {
                                id: request.id,
                                result: Ok(WorkspaceResponse::Capabilities {
                                    capabilities: Vec::new(),
                                }),
                            })
                            .unwrap()
                        };
                        if messages.send(&reply).await.is_err() {
                            break;
                        }
                    }
                });
            }
        }
    });

    let client = WorkspaceClient::connect(client_multiplexer.clone()).await.unwrap();
    let opened = opens.load(Ordering::Relaxed);
    let before = skew::SKEW.tally();
    for _ in 0..SKEWED {
        let error = client.request(WorkspaceRequest::Capabilities).await.unwrap_err();
        assert_eq!(error.code, skew::UNSUPPORTED_RESPONSE, "{error:?}");
    }
    // The channel that carried the skewed replies still works, and no
    // channel was reopened (no reconnect, so no snapshot reload).
    let known = client.request(WorkspaceRequest::Capabilities).await.unwrap();
    assert!(matches!(known, WorkspaceResponse::Capabilities { .. }));
    assert_eq!(opens.load(Ordering::Relaxed), opened);
    let after = skew::SKEW.tally();
    assert!(after.unsupported_responses >= before.unsupported_responses + SKEWED as u64);

    drop(client);
    client_multiplexer.shutdown().await;
    daemon_multiplexer.shutdown().await;
    server.abort();
}
