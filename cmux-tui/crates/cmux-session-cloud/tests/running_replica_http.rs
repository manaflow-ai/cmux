//! Wire contracts for the existing authenticated sync API used by running replicas.

use cmux_session_cloud::{
    Cloud, replica, seal, sha256_hex,
    store::{BlobStore, FsStore, HttpStore, tree_bytes},
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const CREDENTIAL: &str = "test-replica-original-bearer";

#[derive(Debug)]
struct Request {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

struct Reply {
    status: u16,
    body: Vec<u8>,
}

impl Reply {
    fn json(value: Value) -> Self {
        Self { status: 200, body: serde_json::to_vec(&value).unwrap() }
    }

    fn bytes(body: Vec<u8>) -> Self {
        Self { status: 200, body }
    }
}

/// Each response closes its connection. Drop wakes accept even when a client assertion fails,
/// and bounded socket reads prevent a broken HTTP exchange from leaving a fixture thread behind.
struct Server {
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<Vec<Request>>>,
}

impl Server {
    fn start(replies: Vec<Reply>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = thread::spawn(move || {
            let mut requests = Vec::new();
            for reply in replies {
                let (mut socket, _) = listener.accept().unwrap();
                if stopping.load(Ordering::Relaxed) {
                    break;
                }
                socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                socket.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
                let request = read_request(&mut socket);
                write!(socket,
                    "HTTP/1.1 {} Fixture\r\nContent-Length: {}\r\nConnection: close\r\nContent-Type: application/octet-stream\r\n\r\n",
                    reply.status, reply.body.len(),
                ).unwrap();
                socket.write_all(&reply.body).unwrap();
                socket.flush().unwrap();
                requests.push(request);
            }
            requests
        });
        Self { address, stop, thread: Some(thread) }
    }

    fn store(&self) -> HttpStore {
        HttpStore::new(&format!("http://{}", self.address), CREDENTIAL).unwrap()
    }

    fn finish(mut self) -> Vec<Request> {
        // The synchronous client has finished. Wake an unused expected exchange so a missing
        // request fails its count assertion instead of hanging the test in accept/join.
        self.stop.store(true, Ordering::Relaxed);
        let _ = TcpStream::connect_timeout(&self.address, Duration::from_secs(1));
        self.thread.take().unwrap().join().expect("HTTP fixture failed")
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take() {
            self.stop.store(true, Ordering::Relaxed);
            let _ = TcpStream::connect_timeout(&self.address, Duration::from_secs(1));
            let _ = thread.join();
        }
    }
}

fn read_request(socket: &mut TcpStream) -> Request {
    let mut reader = BufReader::new(socket);
    let mut first = String::new();
    reader.read_line(&mut first).unwrap();
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap().to_string();
    let path = parts.next().unwrap().to_string();
    let mut headers = BTreeMap::new();
    loop {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0, "truncated HTTP headers");
        if line == "\r\n" {
            break;
        }
        let (name, value) = line.trim_end().split_once(':').unwrap();
        headers.insert(name.to_ascii_lowercase(), value.trim().to_string());
    }
    let length: usize =
        headers.get("content-length").map(|value| value.parse().unwrap()).unwrap_or(0);
    assert!(length <= 128 * 1024, "unexpected fixture request size");
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    Request { method, path, headers, body }
}

fn assert_auth(requests: &[Request]) {
    assert!(!requests.is_empty());
    for request in requests {
        assert_eq!(request.headers.get("authorization"), Some(&format!("Bearer {CREDENTIAL}")));
        assert!(!request.path.contains(CREDENTIAL));
        assert!(
            !request.body.windows(CREDENTIAL.len()).any(|bytes| bytes == CREDENTIAL.as_bytes())
        );
    }
}

#[test]
fn running_replica_http_recovers_from_authenticated_root_tree_and_blobs() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    std::fs::create_dir_all(source.join("native")).unwrap();
    let journal = b"{\"sequence\":1001,\"kind\":\"tool-start\"}\n";
    let native = b"native-running-session-state";
    std::fs::write(source.join("journal"), journal).unwrap();
    std::fs::write(source.join("native/state"), native).unwrap();
    let writer = Cloud {
        store: Box::new(FsStore::new(temp.path().join("store")).unwrap()),
        key: seal::Key::from_bytes([43; 32]),
        root_prefix: "m.original.".to_string(),
    };
    let receipt = replica::publish(&source, "session-original", &writer).unwrap();
    let hashes = writer.store.get_root(&receipt.pair).unwrap();
    let tree = tree_bytes(&hashes);
    let tree_hash = sha256_hex(&tree);
    let mut replies = vec![
        Reply::json(
            json!({ "pair": receipt.pair, "tree": tree_hash, "registeredAt": 1_762_100_000_000u64 }),
        ),
        Reply::bytes(tree),
    ];
    for hash in &hashes {
        replies.push(Reply::bytes(writer.store.get(hash).unwrap()));
    }
    let server = Server::start(replies);
    let reader =
        Cloud { store: Box::new(server.store()), key: writer.key, root_prefix: String::new() };
    std::fs::remove_dir_all(source).unwrap();
    let dest = temp.path().join("recovered");
    let recovered = replica::recover(&receipt.pair, &dest, &reader).unwrap();
    assert_eq!(recovered.manifest, receipt.manifest);
    assert_eq!(std::fs::read(dest.join("journal")).unwrap(), journal);
    assert_eq!(std::fs::read(dest.join("native/state")).unwrap(), native);
    let requests = server.finish();
    assert_auth(&requests);
    assert_eq!(requests.len(), 2 + hashes.len());
    assert_eq!(requests[0].path, format!("/v1/sync/roots/{}", receipt.pair));
    assert_eq!(requests[1].path, format!("/v1/sync/blobs/{tree_hash}"));
    for (request, hash) in requests[2..].iter().zip(&hashes) {
        assert_eq!(request.path, format!("/v1/sync/blobs/{hash}"));
    }
    assert!(requests.iter().all(|request| request.method == "GET" && request.body.is_empty()));
}

#[test]
fn running_replica_http_missing_batches_1001_hashes_with_original_bearer() {
    let hashes: Vec<_> =
        (0..1001).map(|index| sha256_hex(format!("chunk-{index}").as_bytes())).collect();
    let server = Server::start(vec![
        Reply::json(json!({ "missing": [&hashes[0], &hashes[999]] })),
        Reply::json(json!({ "missing": [&hashes[1000]] })),
    ]);
    let store = server.store();
    assert_eq!(
        store.missing(&hashes).unwrap(),
        vec![hashes[0].clone(), hashes[999].clone(), hashes[1000].clone()]
    );
    assert!(store.missing(&[]).unwrap().is_empty(), "empty batches send no request");
    let requests = server.finish();
    assert_auth(&requests);
    assert_eq!(requests.len(), 2);
    for (request, expected) in requests.iter().zip(hashes.chunks(1000)) {
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/v1/sync/blobs/missing");
        let body: Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body, json!({ "sha256": expected }));
    }
}

#[test]
fn running_replica_http_rejects_wrong_root_pair_before_fetching_tree() {
    let server = Server::start(vec![Reply::json(json!({
        "pair": "different-root", "tree": sha256_hex(b"tree"), "registeredAt": 42,
    }))]);
    let store = server.store();
    let error = store.get_root("requested-root").unwrap_err();
    assert!(error.to_string().contains("another pair"), "{error:#}");
    let requests = server.finish();
    assert_auth(&requests);
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].path, "/v1/sync/roots/requested-root");
}

#[test]
fn running_replica_http_rejects_tampered_root_tree_bytes() {
    let expected = tree_bytes(&[sha256_hex(b"manifest")]);
    let tree_hash = sha256_hex(&expected);
    let server = Server::start(vec![
        Reply::json(json!({ "pair": "root", "tree": tree_hash, "registeredAt": 42 })),
        Reply::bytes(tree_bytes(&[sha256_hex(b"different-manifest")])),
    ]);
    let store = server.store();
    let error = store.get_root("root").unwrap_err();
    assert!(error.to_string().contains("digest mismatch"), "{error:#}");
    let requests = server.finish();
    assert_auth(&requests);
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].path, format!("/v1/sync/blobs/{tree_hash}"));
}

#[test]
fn running_replica_http_rejects_unrequested_missing_hashes() {
    let requested = sha256_hex(b"requested");
    let server = Server::start(vec![Reply::json(json!({ "missing": [sha256_hex(b"other")] }))]);
    let store = server.store();
    let error = store.missing(&[requested]).unwrap_err();
    assert!(error.to_string().contains("unexpected missing hash"), "{error:#}");
    assert_auth(&server.finish());
}

#[test]
fn running_replica_http_root_authorization_refusal_does_not_fetch_or_retry() {
    let server =
        Server::start(vec![Reply { status: 403, body: br#"{"code":"sync.forbidden"}"#.to_vec() }]);
    let store = server.store();
    let error = store.get_root("root").unwrap_err();
    assert!(error.to_string().contains("403"), "{error:#}");
    let requests = server.finish();
    assert_auth(&requests);
    assert_eq!(requests.len(), 1);
}
