use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use cmux_remote_protocol::{FrameFlags, Lane};
use tokio::io::AsyncReadExt;
use tokio::sync::{Mutex, mpsc, oneshot, watch};

use super::*;
use crate::service::{EndpointRole, SessionEndpoint};
use crate::session::ReceivedFrame;

struct TestEndpoint {
    outgoing: mpsc::Sender<ReceivedFrame>,
    incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
    sequence: AtomicU64,
    generation: watch::Sender<u64>,
    sent: Mutex<Vec<ReceivedFrame>>,
}

impl TestEndpoint {}

#[async_trait]
impl SessionEndpoint for TestEndpoint {
    async fn send_frame(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ServiceError> {
        let generation = *self.generation.borrow();
        if let Some(expected) = expected_generation
            && expected != generation
        {
            return Err(ServiceError::GenerationChanged { expected, actual: generation });
        }
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        let frame = ReceivedFrame { generation, lane, stream, sequence, flags, payload };
        self.sent.lock().await.push(frame.clone());
        self.outgoing
            .send(frame)
            .await
            .map_err(|_| ServiceError::Transport("test endpoint closed".into()))?;
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

fn endpoint_pair() -> (Arc<TestEndpoint>, Arc<TestEndpoint>) {
    let (left_tx, left_rx) = mpsc::channel(32);
    let (right_tx, right_rx) = mpsc::channel(32);
    let (left_generation, _) = watch::channel(0);
    let (right_generation, _) = watch::channel(0);
    (
        Arc::new(TestEndpoint {
            outgoing: left_tx,
            incoming: Mutex::new(right_rx),
            sequence: AtomicU64::new(0),
            generation: left_generation,
            sent: Mutex::new(Vec::new()),
        }),
        Arc::new(TestEndpoint {
            outgoing: right_tx,
            incoming: Mutex::new(left_rx),
            sequence: AtomicU64::new(0),
            generation: right_generation,
            sent: Mutex::new(Vec::new()),
        }),
    )
}

#[cfg(unix)]
#[tokio::test]
async fn mux_bridge_shutdown_aborts_and_joins_blocked_socket_tasks() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let (client_endpoint, _daemon_endpoint) = endpoint_pair();
    let multiplexer = ServiceMultiplexer::new(client_endpoint.clone(), EndpointRole::Client);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server = tokio::spawn(async move {
        serve_mux_bridge(multiplexer, &listener, shutdown_rx).await;
    });
    let mut socket = tokio::net::UnixStream::connect(path).await.unwrap();

    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        loop {
            if client_endpoint
                .sent
                .lock()
                .await
                .iter()
                .any(|frame| frame.flags.contains(FrameFlags::OPEN))
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    shutdown_tx.send(()).unwrap();
    server.await.unwrap();

    let mut byte = [0_u8; 1];
    assert_eq!(socket.read(&mut byte).await.unwrap(), 0);
}

#[tokio::test]
async fn forward_connection_limit_defers_additional_tunnel_opens() {
    let (client_endpoint, daemon_endpoint) = endpoint_pair();
    let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
    let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
    let forward =
        LocalPortForward::bind_with_limit(client, RouteId(11), "127.0.0.1:0".parse().unwrap(), 1)
            .await
            .unwrap();

    let first_socket = tokio::net::TcpStream::connect(forward.local_addr()).await.unwrap();
    let first = tokio::time::timeout(std::time::Duration::from_secs(1), daemon.accept())
        .await
        .expect("first tunnel was not admitted")
        .unwrap()
        .unwrap();
    assert_eq!(first.service, Service::TcpTunnel);

    let second_socket = tokio::net::TcpStream::connect(forward.local_addr()).await.unwrap();
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(50), daemon.accept()).await.is_err(),
        "second tunnel exceeded its forward's connection limit"
    );

    first.stream.reject("test".into(), "release admission permit".into()).await.unwrap();
    let second = tokio::time::timeout(std::time::Duration::from_secs(1), daemon.accept())
        .await
        .expect("second tunnel was not admitted after permit release")
        .unwrap()
        .unwrap();
    second.stream.reject("test".into(), "done".into()).await.unwrap();

    drop(first_socket);
    drop(second_socket);
    forward.shutdown().await;
}

#[tokio::test]
async fn accepted_forward_socket_disables_nagle() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let client = tokio::spawn(tokio::net::TcpStream::connect(listener.local_addr().unwrap()));
    let (server, _) = listener.accept().await.unwrap();
    configure_forward_socket(&server).unwrap();
    assert!(server.nodelay().unwrap());
    client.await.unwrap().unwrap();
}
