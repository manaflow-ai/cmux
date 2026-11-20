//! A forward over an in-process stand-in for the hub carrier: what it pumps, what it closes,
//! what it refuses, and that a changed config rebinds it.

use super::*;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Each dial is a duplex whose far end runs `far` (an echo, a closer); `refuse` refuses instead.
struct FakeCarrier {
    refuse: Mutex<Option<Value>>,
    dials: Mutex<Vec<(String, String)>>,
    far: fn(tokio::io::DuplexStream) -> futures_util::future::BoxFuture<'static, ()>,
}

#[async_trait]
impl ForwardDialer for FakeCarrier {
    async fn dial(&self, from: &str, name: &str) -> Result<Box<dyn Circuit>, Value> {
        self.dials.lock().unwrap().push((from.to_owned(), name.to_owned()));
        if let Some(refusal) = self.refuse.lock().unwrap().clone() {
            return Err(refusal);
        }
        // A small buffer, so a test's bulk write runs into backpressure.
        let (ours, theirs) = tokio::io::duplex(4 * 1024);
        tokio::spawn((self.far)(theirs));
        Ok(Box::new(ours))
    }
}

fn echo(mut far: tokio::io::DuplexStream) -> futures_util::future::BoxFuture<'static, ()> {
    Box::pin(async move {
        let mut buf = vec![0u8; 1024];
        while let Ok(n) = far.read(&mut buf).await {
            if n == 0 || far.write_all(&buf[..n]).await.is_err() {
                return;
            }
        }
    })
}

fn greet_and_close(
    mut far: tokio::io::DuplexStream,
) -> futures_util::future::BoxFuture<'static, ()> {
    Box::pin(async move {
        let _ = far.write_all(b"bye\n").await;
    })
}

fn fake(
    far: fn(tokio::io::DuplexStream) -> futures_util::future::BoxFuture<'static, ()>,
) -> Arc<FakeCarrier> {
    Arc::new(FakeCarrier { refuse: Mutex::new(None), dials: Mutex::default(), far })
}

fn unix_forward(path: &Path) -> MachineForward {
    MachineForward {
        from: "broker-host".into(),
        listen_unix: Some(path.to_string_lossy().into_owned()),
        listen_tcp: None,
    }
}

/// A private folder for sockets, short enough for sockaddr_un.
fn socket_dir() -> tempfile::TempDir {
    let dir = tempfile::Builder::new().prefix("fwd").tempdir_in("/tmp").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

async fn within<T>(what: &str, f: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(10), f).await.unwrap_or_else(|_| panic!("{what} hung"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_unix_forward_pumps_bytes_both_ways_with_backpressure() {
    let dir = socket_dir();
    let socket = dir.path().join("broker.sock");
    let carrier = fake(echo);
    let forwards = Forwards::default();
    let wanted = BTreeMap::from([("lane-gh-broker".to_owned(), unix_forward(&socket))]);
    forwards.reconcile(&wanted, None, carrier.clone()).await;
    let listed = forwards.list();
    assert_eq!(listed[0]["state"], "listening", "{listed:?}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777, 0o600);

    // 1 MiB through a 4 KiB circuit: the writer is held back, and every byte comes back in order.
    let client = tokio::net::UnixStream::connect(&socket).await.unwrap();
    let (mut read, mut write) = client.into_split();
    let total = 1 << 20;
    let sent: Vec<u8> = (0..total).map(|i| (i % 251) as u8).collect();
    let writer = {
        let sent = sent.clone();
        tokio::spawn(async move {
            write.write_all(&sent).await.unwrap();
            write
        })
    };
    let mut back = vec![0u8; total];
    within("the echo", read.read_exact(&mut back)).await.unwrap();
    assert!(back == sent, "the bytes came back changed");
    let _write = writer.await.unwrap();
    assert_eq!(
        *carrier.dials.lock().unwrap(),
        vec![("broker-host".to_owned(), "lane-gh-broker".to_owned())],
        "one circuit per connection, naming the service and the machine"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_far_side_closing_closes_the_local_connection() {
    let dir = socket_dir();
    let socket = dir.path().join("b.sock");
    let forwards = Forwards::default();
    let wanted = BTreeMap::from([("svc".to_owned(), unix_forward(&socket))]);
    forwards.reconcile(&wanted, None, fake(greet_and_close)).await;
    let mut client = tokio::net::UnixStream::connect(&socket).await.unwrap();
    let mut got = Vec::new();
    within("the close", client.read_to_end(&mut got)).await.unwrap();
    assert_eq!(got, b"bye\n");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_circuit_closes_the_connection_and_says_why() {
    let dir = socket_dir();
    let socket = dir.path().join("r.sock");
    let carrier = fake(echo);
    *carrier.refuse.lock().unwrap() = Some(json!({
        "reason": "service.not_exposed", "error": "this machine's owner has not exposed it",
    }));
    let forwards = Forwards::default();
    let wanted = BTreeMap::from([("svc".to_owned(), unix_forward(&socket))]);
    forwards.reconcile(&wanted, None, carrier.clone()).await;
    let mut client = tokio::net::UnixStream::connect(&socket).await.unwrap();
    let mut got = Vec::new();
    within("the refusal", client.read_to_end(&mut got)).await.unwrap();
    assert!(got.is_empty());
    let listed = forwards.list();
    assert_eq!(listed[0]["state"], "refused");
    assert_eq!(listed[0]["refusal"]["reason"], "service.not_exposed");
    // The next circuit that opens clears it.
    *carrier.refuse.lock().unwrap() = None;
    let mut client = tokio::net::UnixStream::connect(&socket).await.unwrap();
    client.write_all(b"x").await.unwrap();
    let mut one = [0u8; 1];
    within("the echo", client.read_exact(&mut one)).await.unwrap();
    assert_eq!(forwards.list()[0]["state"], "listening");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tcp_forward_listens_on_loopback_and_pumps() {
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let forwards = Forwards::default();
    let forward = MachineForward {
        from: "broker-host".into(),
        listen_unix: None,
        listen_tcp: Some(format!("127.0.0.1:{port}")),
    };
    forwards
        .reconcile(&BTreeMap::from([("sr2-gateway".to_owned(), forward)]), None, fake(echo))
        .await;
    let mut client = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    client.write_all(b"POST /v1/messages\r\n").await.unwrap();
    let mut back = vec![0u8; "POST /v1/messages\r\n".len()];
    within("the echo", client.read_exact(&mut back)).await.unwrap();
    assert_eq!(back, b"POST /v1/messages\r\n");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_socket_is_never_taken_and_a_removed_forward_unbinds() {
    let dir = socket_dir();
    let socket = dir.path().join("live.sock");
    // An ssh forward already serves the path: the forward refuses it and leaves it alone.
    let held = tokio::net::UnixListener::bind(&socket).unwrap();
    let forwards = Forwards::default();
    let wanted = BTreeMap::from([("svc".to_owned(), unix_forward(&socket))]);
    forwards.reconcile(&wanted, None, fake(echo)).await;
    let listed = forwards.list();
    assert_eq!(listed[0]["state"], "unavailable", "{listed:?}");
    assert!(listed[0]["error"].as_str().unwrap().contains("already listens"));
    drop(held);
    // Its holder gone (the socket file stays, dead): the next reconcile replaces it.
    forwards.reconcile(&wanted, None, fake(echo)).await;
    assert_eq!(forwards.list()[0]["state"], "listening");
    // Removed from the config: unbound and its socket file gone.
    forwards.reconcile(&BTreeMap::new(), None, fake(echo)).await;
    assert!(forwards.list().is_empty());
    assert!(!socket.exists(), "the removed forward left its socket");
}

#[tokio::test]
async fn an_invalid_forward_is_listed_with_why_and_binds_nothing() {
    let forwards = Forwards::default();
    let wanted = BTreeMap::from([(
        "svc".to_owned(),
        MachineForward {
            from: "m".into(),
            listen_unix: None,
            listen_tcp: Some("0.0.0.0:4016".into()),
        },
    )]);
    forwards.reconcile(&wanted, None, fake(echo)).await;
    let listed = forwards.list();
    assert_eq!(listed[0]["state"], "unavailable");
    assert!(listed[0]["error"].as_str().unwrap().contains("loopback"), "{listed:?}");
}
