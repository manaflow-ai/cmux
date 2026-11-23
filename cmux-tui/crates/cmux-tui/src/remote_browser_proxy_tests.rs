use super::*;

#[test]
fn websocket_protocols_preserve_application_negotiation_without_proxy_secret() {
    assert_eq!(
        application_protocols("graphql-transport-ws, chat, cmux-proxy-secret", "cmux-proxy-secret"),
        "graphql-transport-ws, chat"
    );
    assert_eq!(application_protocols("cmux-proxy-secret", "cmux-proxy-secret"), "");
}

#[test]
fn websocket_binary_frames_follow_upgrade_without_utf8_decoding() {
    let headers = b"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Protocol: chat\r\n\r\n";
    let frame = [0x82, 0x03, 0xff, 0xfe, 0x00];
    let (parsed, remainder) = split_http_headers([headers.as_slice(), &frame].concat()).unwrap();
    assert_eq!(parsed.as_bytes(), headers);
    assert_eq!(remainder, frame);
    let large_frame = vec![0xff; 65536];
    let (_, remainder) = split_http_headers([headers.as_slice(), &large_frame].concat()).unwrap();
    assert_eq!(remainder, large_frame);
    assert!(split_http_headers(b"HTTP/1.1 101\r\n".to_vec()).is_err());
}

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use cmux_remote::service::{EndpointRole, ServiceError, ServiceMultiplexer, SessionEndpoint};
use cmux_remote::services::MessageStream;
use cmux_remote::session::ReceivedFrame;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{FrameFlags, Lane, RouteId, RpcRequest, WorkspaceId};
use tokio::sync::{Mutex, mpsc, watch};

// The public mux runs over in-memory frames; the workspace policy and TCP
// dials are real, so an accepted browser identity cannot fake route success.
struct TestEndpoint {
    outgoing: mpsc::Sender<ReceivedFrame>,
    incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
    sequence: AtomicU64,
    generation: watch::Sender<u64>,
}

#[async_trait::async_trait]
impl SessionEndpoint for TestEndpoint {
    async fn send_frame(
        &self,
        _: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        self.outgoing
            .send(ReceivedFrame { generation: 0, lane, stream, sequence, flags, payload })
            .await
            .map_err(|_| ServiceError::Closed)?;
        Ok(sequence)
    }

    async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
        Ok(self.incoming.lock().await.recv().await)
    }

    fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }
    async fn close_session(&self) -> Result<(), ServiceError> {
        Ok(())
    }
}

struct ProxyFixture {
    client: Arc<WorkspaceClient>,
    workspace: WorkspaceId,
    routes: Arc<AtomicUsize>,
    mux: Arc<ServiceMultiplexer>,
    daemon_mux: Arc<ServiceMultiplexer>,
    server: tokio::task::JoinHandle<()>,
    _root: tempfile::TempDir,
}

impl ProxyFixture {
    async fn new() -> Self {
        let (left_tx, left_rx) = mpsc::channel(64);
        let (right_tx, right_rx) = mpsc::channel(64);
        let endpoint = |outgoing, incoming| {
            Arc::new(TestEndpoint {
                outgoing,
                incoming: Mutex::new(incoming),
                sequence: AtomicU64::new(0),
                generation: watch::channel(0).0,
            })
        };
        let mux = ServiceMultiplexer::new(endpoint(left_tx, right_rx), EndpointRole::Client);
        let daemon_mux = ServiceMultiplexer::new(endpoint(right_tx, left_rx), EndpointRole::Daemon);
        let routes = Arc::new(AtomicUsize::new(0));
        let service = WorkspaceService::new();
        let server = tokio::task::spawn_local({
            let daemon = daemon_mux.clone();
            let routes = routes.clone();
            async move {
                let mut tasks = tokio::task::JoinSet::new();
                while let Some(incoming) = daemon.accept().await.unwrap() {
                    let service = service.clone();
                    let routes = routes.clone();
                    tasks.spawn_local(async move {
                        let lane = match incoming.metadata.get("lane").map(String::as_str) {
                            Some("interactive") => Lane::Interactive,
                            Some("bulk") => Lane::Bulk,
                            _ => Lane::Control,
                        };
                        let stream = Arc::new(incoming.stream);
                        if incoming.service == Service::WorkspaceRpc {
                            stream
                                .send_on(
                                    lane,
                                    Bytes::from(
                                        serde_json::to_vec(&ServiceControl::Opened {
                                            service: Service::WorkspaceRpc,
                                        })
                                        .unwrap(),
                                    ),
                                )
                                .await
                                .unwrap();
                            let messages = MessageStream::with_lane(stream, lane);
                            while let Some(bytes) = messages.receive().await.unwrap() {
                                let request: RpcRequest = serde_json::from_slice(&bytes).unwrap();
                                if let WorkspaceRequest::CreateRoute { policy, .. } =
                                    &request.request
                                {
                                    assert_eq!(*policy, RoutePolicy::LoopbackOnly);
                                    routes.fetch_add(1, Ordering::SeqCst);
                                }
                                let response = service.handle_rpc(request).await;
                                messages
                                    .send(&serde_json::to_vec(&response).unwrap())
                                    .await
                                    .unwrap();
                            }
                        } else {
                            assert_eq!(incoming.service, Service::TcpTunnel);
                            let route = RouteId(incoming.metadata["route"].parse().unwrap());
                            let socket = service.dial_route(route).await.unwrap();
                            stream
                                .send(Bytes::from(
                                    serde_json::to_vec(&ServiceControl::Opened {
                                        service: Service::TcpTunnel,
                                    })
                                    .unwrap(),
                                ))
                                .await
                                .unwrap();
                            let (mut reader, mut writer) = socket.into_split();
                            let upload = async {
                                while let Some(chunk) = stream.receive().await.unwrap() {
                                    writer.write_all(&chunk.payload).await.unwrap();
                                    if chunk.finished {
                                        break;
                                    }
                                }
                                writer.shutdown().await.unwrap();
                            };
                            let download = async {
                                let mut buffer = [0; 2048];
                                loop {
                                    let size = reader.read(&mut buffer).await.unwrap();
                                    if size == 0 {
                                        break;
                                    }
                                    stream
                                        .send(Bytes::copy_from_slice(&buffer[..size]))
                                        .await
                                        .unwrap();
                                }
                                stream.close().await.unwrap();
                            };
                            tokio::join!(upload, download);
                        }
                    });
                }
            }
        });
        let client = WorkspaceClient::connect(mux.clone()).await.unwrap();
        let root = tempfile::tempdir().unwrap();
        let WorkspaceResponse::Workspace { id: workspace, .. } = client
            .request(WorkspaceRequest::OpenWorkspace {
                root: root.path().to_string_lossy().into_owned(),
            })
            .await
            .unwrap()
        else {
            panic!("workspace was not opened")
        };
        Self { client, workspace, routes, mux, daemon_mux, server, _root: root }
    }

    async fn request(&self, policy: BrowserProxyPolicy, request: String) -> (Vec<u8>, bool) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let mut browser = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        let (socket, _) = listener.accept().await.unwrap();
        let proxy = serve_browser_connection(
            socket,
            self.client.clone(),
            self.workspace.clone(),
            Arc::new(policy),
            "fixture:password".into(),
            "fixture-token".into(),
            port,
        );
        let exchange = async {
            browser.write_all(request.as_bytes()).await.unwrap();
            let mut response = Vec::new();
            browser.read_to_end(&mut response).await.unwrap();
            response
        };
        let (result, response) = tokio::join!(proxy, exchange);
        (response, result.is_ok())
    }

    async fn close(self) {
        self.server.abort();
        let _ = self.server.await;
        self.mux.shutdown().await;
        self.daemon_mux.shutdown().await;
    }
}

#[tokio::test(flavor = "current_thread")]
async fn browser_proxy_dials_guest_loopback_for_cloud_and_retains_ssh_ipv6() {
    tokio::task::LocalSet::new().run_until(async {
        tokio::time::timeout(Duration::from_secs(10), async {
            let fixture = ProxyFixture::new().await;
            for (host, bind, allow_loopback) in [
                ("10.42.0.7", "127.0.0.1:0", false),
                ("fd12::7", "127.0.0.1:0", false),
                ("::1", "[::1]:0", true),
            ] {
                for websocket in [false, true] {
                    let listener = TcpListener::bind(bind).await.unwrap();
                    let port = listener.local_addr().unwrap().port();
                    let authority = if host.contains(':') { format!("[{host}]:{port}") }
                        else { format!("{host}:{port}") };
                    let target = async {
                        let (mut socket, _) = listener.accept().await.unwrap();
                        if websocket {
                            let (headers, _) = read_http_headers(&mut socket,
                                tokio::time::Instant::now() + Duration::from_secs(5), Vec::new())
                                .await.unwrap();
                            assert!(headers.contains(&format!("Host: {host}:{port}\r\n")));
                            assert!(!headers.contains("fixture-token"));
                            socket.write_all(b"HTTP/1.1 101 Switching Protocols\r\n\r\n").await.unwrap();
                        }
                        socket.write_all(b"guest-payload").await.unwrap();
                        socket.shutdown().await.unwrap();
                    };
                    let request = if websocket {
                        format!("GET /__cmux_ws__/{authority}/socket HTTP/1.1\r\nSec-WebSocket-Protocol: cmux-proxy-fixture-token\r\n\r\n")
                    } else {
                        let auth = base64::engine::general_purpose::STANDARD.encode("fixture:password");
                        format!("CONNECT {authority} HTTP/1.1\r\nProxy-Authorization: Basic {auth}\r\n\r\n")
                    };
                    let policy = BrowserProxyPolicy { allowed_hosts: vec![host.into()], allow_loopback, allow_remote_network: false };
                    let ((), (response, ok)) = tokio::join!(target, fixture.request(policy, request));
                    assert!(ok, "proxy rejected {authority}");
                    let expected = if websocket { "HTTP/1.1 101" } else { "HTTP/1.1 200" };
                    assert!(response.starts_with(expected.as_bytes()));
                    assert!(response.ends_with(b"guest-payload"));
                }
            }
            assert_eq!(fixture.routes.load(Ordering::SeqCst), 6);
            fixture.close().await;
        }).await.expect("browser proxy loopback round trip timed out");
    }).await;
}

#[tokio::test(flavor = "current_thread")]
async fn browser_proxy_denies_untrusted_requests_before_creating_routes() {
    tokio::task::LocalSet::new().run_until(async {
        tokio::time::timeout(Duration::from_secs(5), async {
            let fixture = ProxyFixture::new().await;
            let auth = base64::engine::general_purpose::STANDARD.encode("fixture:password");
            for (authority, credentials, status) in [
                ("10.42.0.7:3000", "", "407"),
                ("10.42.0.7:3000", "invalid", "407"),
                ("10.42.0.8:3000", auth.as_str(), "403"),
                ("10.42.0.7:1337", auth.as_str(), "403"),
            ] {
                let policy = BrowserProxyPolicy { allowed_hosts: vec!["10.42.0.7".into()], allow_loopback: false, allow_remote_network: false };
                let request = format!("CONNECT {authority} HTTP/1.1\r\nProxy-Authorization: Basic {credentials}\r\n\r\n");
                let (response, ok) = fixture.request(policy, request).await;
                assert!(ok);
                assert!(response.starts_with(format!("HTTP/1.1 {status}").as_bytes()));
            }
            for (authority, token) in [
                ("10.42.0.7:3000", "wrong-token"),
                ("10.42.0.8:3000", "fixture-token"),
                ("10.42.0.7:1337", "fixture-token"),
            ] {
                let policy = BrowserProxyPolicy { allowed_hosts: vec!["10.42.0.7".into()], allow_loopback: false, allow_remote_network: false };
                let request = format!("GET /__cmux_ws__/{authority}/socket HTTP/1.1\r\nSec-WebSocket-Protocol: cmux-proxy-{token}\r\n\r\n");
                let (response, ok) = fixture.request(policy, request).await;
                assert!(!ok);
                assert!(response.is_empty());
            }
            assert_eq!(fixture.routes.load(Ordering::SeqCst), 0);
            fixture.close().await;
        }).await.expect("browser proxy refusal timed out");
    }).await;
}
