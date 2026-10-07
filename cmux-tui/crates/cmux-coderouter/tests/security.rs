use bytes::Bytes;
use cmux_coderouter::{BODY_LIMIT, KeyRing, KeyScope, LoopbackAddr, Secret, handle_request};
use http::{Request, StatusCode};
use http_body_util::Full;

fn scope() -> KeyScope {
    KeyScope { harness: "claude".into(), session: "session-1".into(), surfaces: vec!["surface-1".into()], expires_at: u64::MAX }
}
fn fixture() -> (KeyRing, Secret<String>) {
    let mut keys = KeyRing::new(Secret::new(vec![7; 32])).unwrap();
    let key = keys.mint(scope()).unwrap();
    (keys, key)
}
fn request(key: &str) -> http::request::Builder {
    Request::builder().method("POST").uri("/v1/messages").header("host", "127.0.0.1:31415").header("authorization", format!("Bearer {key}"))
}
#[tokio::test]
async fn any_origin_refused() {
    let (keys, key) = fixture();
    for origin in ["http://127.0.0.1:31415", "http://localhost:31415", "null", "", "https://evil.example"] {
        let req = request(key.expose()).header("origin", origin).body(Full::new(Bytes::new())).unwrap();
        assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::FORBIDDEN);
    }
}
#[tokio::test]
async fn rebinding_host_refused() {
    let (keys, key) = fixture();
    for host in ["evil.example:31415", "127.0.0.1:1", "localhost", "localhost.:31415", "[::1]:31415"] {
        let req = Request::builder().method("POST").uri("/v1/messages").header("host", host).header("authorization", format!("Bearer {}", key.expose())).body(Full::new(Bytes::new())).unwrap();
        assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::MISDIRECTED_REQUEST);
    }
}
#[tokio::test]
async fn foreign_install_key_refused() {
    let (keys, key) = fixture();
    let parts: Vec<_> = key.expose().split('_').collect();
    let foreign = format!("crl_{}_{}_{}", "f".repeat(32), parts[2], parts[3]);
    let req = request(&foreign).body(Full::new(Bytes::new())).unwrap();
    assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn wrong_hmac_key_refused() {
    let (keys, key) = fixture();
    let mut wrong = key.expose().clone();
    wrong.pop();
    wrong.push(if key.expose().ends_with('0') { '1' } else { '0' });
    let req = request(&wrong).body(Full::new(Bytes::new())).unwrap();
    assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::UNAUTHORIZED);
}
#[test]
fn loopback_refuses_unspecified_and_public_addresses() {
    for address in ["0.0.0.0:0", "[::]:0", "192.168.1.2:80", "[2001:db8::1]:80"] {
        assert!(LoopbackAddr::try_from(address.parse::<std::net::SocketAddr>().unwrap()).is_err());
    }
    for address in ["127.0.0.1:0", "[::1]:0"] {
        assert!(LoopbackAddr::try_from(address.parse::<std::net::SocketAddr>().unwrap()).is_ok());
    }
}
#[tokio::test]
async fn options_refused() {
    let (keys, key) = fixture();
    let req = request(key.expose()).method("OPTIONS").body(Full::new(Bytes::new())).unwrap();
    assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::FORBIDDEN);
}
#[tokio::test]
async fn oversized_body_refused() {
    let (keys, key) = fixture();
    let req = request(key.expose()).body(Full::new(Bytes::from(vec![0; BODY_LIMIT + 1]))).unwrap();
    assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::PAYLOAD_TOO_LARGE);
}
#[test]
fn secret_debug_is_redacted() {
    assert_eq!(format!("{:?}", Secret::new("test-secret-canary".to_owned())), "<redacted>");
}
#[test]
fn panic_payload_is_discarded() {
    if std::env::var_os("CODEROUTER_PANIC_CHILD").is_some() {
        cmux_coderouter::install_panic_hook();
        panic!("test-secret-canary");
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "panic_payload_is_discarded", "--nocapture"])
        .env("CODEROUTER_PANIC_CHILD", "1").output().unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stderr.contains("test-secret-canary"));
    assert!(stderr.contains("security.rs:"));
}
#[tokio::test]
async fn valid_key_reaches_unimplemented_route() {
    let (keys, key) = fixture();
    let req = request(key.expose()).body(Full::new(Bytes::new())).unwrap();
    assert_eq!(handle_request(req, 31415, &keys).await, StatusCode::NOT_IMPLEMENTED);
}
