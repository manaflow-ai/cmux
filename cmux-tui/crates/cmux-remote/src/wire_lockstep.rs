//! Exercise the carrier's actual client and daemon separately against the PR base's vocabulary.
//! TestEndpoint observes both writers after serialization, before either reader gets the bytes.
use super::*;
use cmux_wire_lockstep::{Dir, Manifest, OldPeer, Tap, base_manifest};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;

const SNAPSHOT: &str = include_str!("../../../spec/wire/cmux-remote.json");

pub(super) fn manifests() -> (Manifest, OldPeer) {
    (
        Manifest::from_json(SNAPSHOT).unwrap(),
        OldPeer::new(base_manifest("cmux-remote", SNAPSHOT).unwrap()),
    )
}

pub(super) fn pair(
    new_role: EndpointRole,
    head: &Manifest,
    old: &OldPeer,
) -> (Arc<ServiceMultiplexer>, Arc<ServiceMultiplexer>, Arc<Tap>) {
    let tap = Arc::new(Tap::new());
    let services = Arc::new(StdMutex::new(HashMap::new()));
    let probe = |role| FrameProbe {
        sender: if role == new_role { OldPeer::new(head.clone()) } else { old.clone() },
        dir: if role == new_role { Dir::Sent } else { Dir::Received },
        tap: tap.clone(),
        services: services.clone(),
        buffers: StdMutex::new(HashMap::new()),
    };
    let (client, daemon) =
        endpoints(Some(probe(EndpointRole::Client)), Some(probe(EndpointRole::Daemon)));
    (
        ServiceMultiplexer::new(client, EndpointRole::Client),
        ServiceMultiplexer::new(daemon, EndpointRole::Daemon),
        tap,
    )
}

pub(super) struct FrameProbe {
    sender: OldPeer,
    dir: Dir,
    tap: Arc<Tap>,
    services: Arc<StdMutex<HashMap<u64, String>>>,
    buffers: StdMutex<HashMap<u64, BytesMut>>,
}

impl FrameProbe {
    pub(super) fn observe(&self, lane: Lane, stream: u64, flags: FrameFlags, payload: &[u8]) {
        let record = |name: String| {
            if self.dir == Dir::Received {
                assert!(self.sender.knows(&name), "old fixture sent {name} outside its vocabulary");
            }
            self.tap.record(self.dir, name);
        };
        record(format!("frame:lane/{lane}={}", lane as u8));
        let mut bits = flags.bits();
        for &(name, flag) in FrameFlags::NAMED {
            if flags.contains(flag) {
                record(format!("frame:flag/{name}={}", flag.bits()));
                bits &= !flag.bits();
            }
        }
        assert_eq!(bits, 0, "unnamed frame flag");
        if payload.is_empty() {
            return;
        }
        // Service controls are bare JSON. RPC uses a big-endian length (at most 16 MiB),
        // and mux packets start with four ASCII magic bytes.
        let mut buffers = self.buffers.lock().unwrap();
        let buffer = buffers.entry(stream).or_default();
        if buffer.is_empty() && payload.first() == Some(&b'{') {
            let control: Value = serde_json::from_slice(payload).unwrap();
            record_tag(&control, "control:", "field:", &record);
            if let Some(features) = control.get("features") {
                self.check_advertisement(features);
            }
            if let Some(service) = control["service"].as_str() {
                record(format!("service:{service}"));
                if flags.contains(FrameFlags::OPEN) {
                    self.services.lock().unwrap().insert(stream, service.to_owned());
                    for key in control["metadata"].as_object().unwrap().keys() {
                        record(format!("param:{service}#{key}"));
                    }
                }
            }
            return;
        }
        match self.services.lock().unwrap().get(&stream).map(String::as_str) {
            Some("mux-control") => {
                record(format!("header:{}", std::str::from_utf8(&payload[..4]).unwrap()));
                return;
            }
            Some("workspace-rpc" | "process-stream") => {}
            service => panic!("unexpected payload on {service:?}"),
        }
        // MessageStream splits large messages at the frame limit. A partial JSON tag or
        // a continuation beginning with '{' must never be mistaken for a new message.
        buffer.extend_from_slice(payload);
        while buffer.len() >= 4 {
            let size = u32::from_be_bytes(buffer[..4].try_into().unwrap()) as usize;
            assert!(size <= MAX_RPC_MESSAGE);
            if buffer.len() < 4 + size {
                break;
            }
            buffer.advance(4);
            let rpc: Value = serde_json::from_slice(&buffer.split_to(size)).unwrap();
            if let Some(request) = rpc.get("request") {
                record_tag(request, "method:", "param:", &record);
            } else if let Some(response) = rpc.pointer("/result/Ok") {
                record_tag(response, "method:response/", "field:response.", &record);
                if response["type"] == "capabilities" {
                    self.check_advertisement(&response["capabilities"]);
                }
                if let Some(events) = response.get("events").and_then(Value::as_array) {
                    for event in events {
                        record_tag(&event["event"], "event:", "field:", &record);
                    }
                }
            } else if let Some(event) = rpc.get("event") {
                record_tag(event, "event:", "field:", &record);
            } else {
                assert!(rpc.pointer("/result/Err").is_some(), "unknown RPC envelope {rpc}");
            }
        }
    }

    // A peer can ignore new IDs in an advertisement. The side advertising one
    // must still declare its contract in its own manifest.
    fn check_advertisement(&self, ids: &Value) {
        for id in ids.as_array().unwrap() {
            let id = id.as_str().unwrap();
            assert!(self.sender.lists(id), "{:?} advertised undeclared capability {id}", self.dir);
        }
    }
}

fn record_tag(body: &Value, message_prefix: &str, field_prefix: &str, record: &impl Fn(String)) {
    let tag = body["type"].as_str().expect("tagged RPC body");
    record(format!("{message_prefix}{tag}"));
    for key in body.as_object().unwrap().keys().filter(|key| *key != "type") {
        record(format!("{field_prefix}{tag}#{key}"));
    }
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(std::time::Duration::from_secs(5), future)
        .await
        .expect("carrier lockstep exchange stalled")
}

// WorkspaceClient opens five RPC channels. Accept opens as they arrive rather than
// depending on the order or count. A decode error drops just that service stream.
async fn old_daemon(daemon: Arc<ServiceMultiplexer>, old: &OldPeer, tap: &Tap) {
    let mut handlers = futures_util::stream::FuturesUnordered::new();
    use futures_util::StreamExt;
    loop {
        tokio::select! {
            incoming = daemon.accept() => {
                let Some(incoming) = incoming.unwrap() else { break };
                assert_eq!(incoming.service, Service::WorkspaceRpc);
                let (lane, _) = workspace_rpc_metadata(&incoming.metadata).unwrap();
                handlers.push(old_rpc_stream(incoming.stream, lane, old, tap));
            }
            Some(()) = handlers.next(), if !handlers.is_empty() => {}
        }
    }
}

async fn old_rpc_stream(stream: ServiceStream, lane: Lane, old: &OldPeer, tap: &Tap) {
    // Freeze the simulated peer's wire shapes. Encoding today's RpcResponse here
    // could silently teach yesterday's daemon a new field or serde tag.
    stream
        .send_on(lane, Bytes::from_static(br#"{"type":"opened","service":"workspace-rpc"}"#))
        .await
        .unwrap();
    let messages = MessageStream::with_lane(Arc::new(stream), lane);
    while let Ok(Some(bytes)) = messages.receive().await {
        let rpc: Value = serde_json::from_slice(&bytes).unwrap();
        let tag = rpc["request"]["type"].as_str().unwrap();
        let name = format!("method:{tag}");
        if !old.knows(&name) {
            // serve_workspace_rpc propagates the serde error. ServiceStream::drop
            // sends RESET; the daemon never sends a per-request unknown-method reply.
            tap.refused(Dir::Sent, name);
            return;
        }
        let result = match tag {
            "capabilities" => {
                let capabilities: Vec<_> = old
                    .advertises()
                    .into_iter()
                    .filter(|id| {
                        !matches!(
                            *id,
                            MUX_INPUT_V1_FEATURE | MUX_LINE_ZLIB_V1_FEATURE | "accepts_parked"
                        )
                    })
                    .collect();
                json!({"type":"capabilities","capabilities":capabilities})
            }
            "list-workspaces" => json!({"type":"workspaces","workspaces":[]}),
            "list-processes" => json!({"type":"processes","processes":[]}),
            other => panic!("add an old peer fixture for {other}"),
        };
        let response = json!({"id":rpc["id"],"result":{"Ok":result}});
        messages.send(&serde_json::to_vec(&response).unwrap()).await.unwrap();
    }
}

async fn client_exchange(
    head: &Manifest,
    old: &OldPeer,
    request: WorkspaceRequest,
) -> (Arc<Tap>, Result<WorkspaceResponse, RpcError>) {
    let (client, daemon, tap) = pair(EndpointRole::Client, head, old);
    let result = within(async {
        let exchange = async {
            let rpc = WorkspaceClient::connect(client.clone()).await.unwrap();
            let reply = rpc.request(WorkspaceRequest::Capabilities).await.unwrap();
            let WorkspaceResponse::Capabilities { capabilities } = reply else {
                panic!("expected capabilities")
            };
            for capability in capabilities {
                let id = serde_json::to_value(capability).unwrap();
                assert!(old.lists(id.as_str().unwrap()));
            }
            rpc.request(request).await
        };
        tokio::select! {
            result = exchange => result,
            () = old_daemon(daemon.clone(), old, &tap) => panic!("old daemon stopped"),
        }
    })
    .await;
    client.shutdown().await;
    daemon.shutdown().await;
    (tap, result)
}

#[tokio::test]
async fn wire_lockstep_new_workspace_client_against_base_daemon() {
    let (head, old) = manifests();
    let (tap, result) = client_exchange(&head, &old, WorkspaceRequest::ListWorkspaces).await;
    tap.assert_lockstep(&head, &old);
    assert!(
        matches!(result.unwrap(), WorkspaceResponse::Workspaces { workspaces } if workspaces.is_empty())
    );
    assert!(tap.seen().contains(&(Dir::Sent, "method:list-workspaces".into())));
    assert!(tap.seen().contains(&(Dir::Received, "method:response/workspaces".into())));
}

#[tokio::test]
#[ignore = "WorkspaceClient sends list-processes to a daemon that omitted process-catalog-v1"]
async fn wire_lockstep_client_honors_missing_process_catalog() {
    let (head, base) = manifests();
    let mut legacy = base.manifest().clone();
    legacy.capabilities.remove("process-catalog-v1");
    let old = OldPeer::new(legacy);
    let (tap, _) = client_exchange(&head, &old, WorkspaceRequest::ListProcesses).await;
    tap.assert_lockstep(&head, &old);
}

async fn old_client_rpc(
    messages: &MessageStream,
    old: &OldPeer,
    tap: &Tap,
    sequence: u128,
    tag: &str,
) -> Value {
    assert!(old.knows(&format!("method:{tag}")));
    let id = uuid::Uuid::from_u128(sequence).to_string();
    let request = json!({"id":id,"request":{"type":tag}});
    messages.send(&serde_json::to_vec(&request).unwrap()).await.unwrap();
    let bytes = messages.receive().await.unwrap().unwrap();
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(response["id"], id);
    let body = &response["result"]["Ok"];
    let name = format!("method:response/{}", body["type"].as_str().unwrap());
    if !old.knows(&name) {
        tap.refused(Dir::Sent, name);
    }
    body.clone()
}

#[tokio::test]
async fn wire_lockstep_new_workspace_daemon_against_base_client() {
    let (head, old) = manifests();
    let (client, daemon, tap) = pair(EndpointRole::Daemon, &head, &old);
    tokio::task::LocalSet::new()
        .run_until(within(async {
            let stream =
                Arc::new(client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap());
            let incoming = daemon.accept().await.unwrap().unwrap();
            let serve = DaemonServices::serve_workspace_rpc(
                WorkspaceService::new(),
                ClientScope::new("old-client", cmux_remote_protocol::SessionId([1; 16])),
                RequestAdmission::new(),
                incoming.stream,
                incoming.metadata,
            );
            let exchange = async {
                let opened = stream.receive().await.unwrap().unwrap();
                let ack: Value = serde_json::from_slice(&opened.payload).unwrap();
                assert_eq!(ack["type"], "opened");
                let messages = MessageStream::with_lane(stream, Lane::Control);
                let capabilities = old_client_rpc(&messages, &old, &tap, 1, "capabilities").await;
                let advertised = capabilities["capabilities"].as_array().unwrap();
                if old.lists("workspace-files-v1")
                    && advertised.contains(&json!("workspace-files-v1"))
                {
                    let body = old_client_rpc(&messages, &old, &tap, 2, "list-workspaces").await;
                    assert_eq!(body["workspaces"], json!([]));
                }
                messages.close().await.unwrap();
            };
            let (result, ()) = tokio::join!(serve, exchange);
            result.unwrap();
        }))
        .await;
    tap.assert_lockstep(&head, &old);
    assert!(tap.seen().contains(&(Dir::Sent, "method:response/capabilities".into())));
    client.shutdown().await;
    daemon.shutdown().await;
}

// Pin the refusal modeled by old_rpc_stream to the production daemon: an unknown
// tag gets RESET on this stream, without an RpcResponse or a session disconnect.
#[tokio::test]
async fn wire_lockstep_unknown_request_resets_only_its_stream() {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    within(async {
        let stream = Arc::new(client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap());
        let incoming = daemon.accept().await.unwrap().unwrap();
        let (result, refused) = tokio::join!(
            DaemonServices::serve_workspace_rpc(
                WorkspaceService::new(), ClientScope::new("unknown-tag", cmux_remote_protocol::SessionId([2; 16])),
                RequestAdmission::new(), incoming.stream, incoming.metadata,
            ),
            async {
                stream.receive().await.unwrap().unwrap();
                let messages = MessageStream::new(stream);
                let request = br#"{"id":"00000000-0000-4000-8000-000000000001","request":{"type":"unknown-lockstep-probe"}}"#;
                messages.send(request).await.unwrap();
                messages.receive().await
            }
        );
        assert!(matches!(result, Err(ServicesError::Json(_))), "{result:?}");
        assert!(
            matches!(refused, Err(ServicesError::Service(ServiceError::Reset(_)))),
            "expected stream reset, got {refused:?}"
        );
        let _next = client.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        assert_eq!(daemon.accept().await.unwrap().unwrap().service, Service::WorkspaceRpc);
    }).await;
    client.shutdown().await;
    daemon.shutdown().await;
}

#[cfg(unix)]
#[tokio::test]
async fn wire_lockstep_base_client_opens_acpmux_bridge() {
    use crate::acpmux_bridge::tests::{fake, grant};
    use cmux_link::token::VmKind;

    let (head, old) = manifests();
    // A base that predates this service never attempts the open.
    if !old.knows("service:acpmux") {
        return;
    }
    let (client, daemon, tap) = pair(EndpointRole::Daemon, &head, &old);
    let socket = fake::start();
    let owner = grant(Some(VmKind::Owner), None);
    within(async {
        let stream = client.open(Service::Acpmux, BTreeMap::new()).await.unwrap();
        let incoming = daemon.accept().await.unwrap().unwrap();
        let serve = DaemonServices::serve_acpmux(Some(&socket.path), Some(&owner), incoming.stream);
        let exchange = async {
            let opened = stream.receive().await.unwrap().unwrap();
            let control: Value = serde_json::from_slice(&opened.payload).unwrap();
            assert_eq!(control, json!({"type":"opened","service":"acpmux"}));
            socket.close.send(()).await.unwrap();
            while let Some(chunk) = stream.receive().await.unwrap() {
                if chunk.finished {
                    break;
                }
            }
            stream.close().await.unwrap();
        };
        let (result, ()) = tokio::join!(serve, exchange);
        result.unwrap();
    })
    .await;
    assert!(tap.seen().contains(&(Dir::Sent, "service:acpmux".into())));
    tap.assert_lockstep(&head, &old);
    client.shutdown().await;
    daemon.shutdown().await;
}
