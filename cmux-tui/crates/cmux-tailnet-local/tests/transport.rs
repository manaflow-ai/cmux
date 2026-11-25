//! The HTTP transport against a fake LocalAPI on a Unix socket.
#![cfg(unix)]

use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use cmux_tailnet_local::http::Endpoint;
use cmux_tailnet_local::transport::{self, Target, macsys_target, parse_app_store_proof};
use cmux_tailnet_local::{Error, Limits, LocalApi, PeerPath};

/// A fresh directory under /tmp: Unix socket paths must stay short
/// (SUN_LEN), and `$TMPDIR` can be long.
fn temp_dir(tag: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let base = if cfg!(target_os = "macos") || PathBuf::from("/tmp").is_dir() {
        PathBuf::from("/tmp")
    } else {
        std::env::temp_dir()
    };
    let n = NEXT.fetch_add(1, Ordering::SeqCst);
    let dir = base.join(format!("tl-{tag}-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Serves one connection with `respond(request) -> bytes`, written in
/// pieces `delay` apart.
fn serve_once(
    tag: &str,
    delay: Duration,
    respond: impl FnOnce(String) -> Vec<u8> + Send + 'static,
) -> (PathBuf, std::thread::JoinHandle<String>) {
    let dir = temp_dir(tag);
    let path = dir.join("tailscaled.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let handle = std::thread::spawn(move || {
        let (mut conn, _) = listener.accept().unwrap();
        let mut req = Vec::new();
        let mut buf = [0u8; 1024];
        while !req.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = conn.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            req.extend_from_slice(&buf[..n]);
        }
        let req = String::from_utf8(req).unwrap();
        let resp = respond(req.clone());
        for piece in resp.chunks(if delay.is_zero() { usize::MAX } else { 8 }) {
            if conn.write_all(piece).is_err() {
                break;
            }
            std::thread::sleep(delay);
        }
        req
    });
    (path, handle)
}

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

#[test]
fn status_over_unix_socket_chunked() {
    let body = fixture("status_mixed.json");
    let (path, server) = serve_once("ok", Duration::ZERO, move |_| {
        let mut out = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
        for chunk in body.chunks(1000) {
            out.extend_from_slice(format!("{:x}\r\n", chunk.len()).as_bytes());
            out.extend_from_slice(chunk);
            out.extend_from_slice(b"\r\n");
        }
        out.extend_from_slice(b"0\r\n\r\n");
        out
    });
    let api = LocalApi::new(Target::Unix(path), Limits::default());
    let view = api.status().unwrap();
    let req = server.join().unwrap();
    assert!(req.starts_with("GET /localapi/v0/status HTTP/1.1\r\n"));
    assert!(req.contains("Sec-Tailscale: localapi"));
    assert!(req.contains("Host: local-tailscaled.sock"));
    assert!(matches!(view.path_hint("100.64.0.2".parse().unwrap()), Some(PeerPath::Direct { .. })));
}

#[test]
fn slow_server_hits_the_whole_call_deadline() {
    // Trickles 8 bytes every 100 ms: each read succeeds, the call must not.
    let (path, _server) = serve_once("slow", Duration::from_millis(100), |_| {
        let mut out = b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n".to_vec();
        out.extend(std::iter::repeat_n(b' ', 2000));
        out
    });
    let limits = Limits { timeout: Duration::from_millis(400), ..Limits::default() };
    let start = Instant::now();
    let err = transport::get(&Target::Unix(path), &Endpoint::Status, &limits).unwrap_err();
    assert_eq!(err, Error::Timeout);
    assert!(start.elapsed() < Duration::from_millis(1500), "took {:?}", start.elapsed());
}

#[test]
fn oversized_body_is_refused() {
    let (path, _server) = serve_once("big", Duration::ZERO, |_| {
        let mut out = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
        out.extend(std::iter::repeat_n(b'x', 64 * 1024));
        out
    });
    let limits = Limits { max_body: 4096, ..Limits::default() };
    let err = transport::get(&Target::Unix(path), &Endpoint::Status, &limits).unwrap_err();
    assert_eq!(err, Error::TooLarge);
}

#[test]
fn forbidden_is_denied_and_body_not_echoed() {
    let (path, _server) = serve_once("403", Duration::ZERO, |_| {
        b"HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\n\r\nsecret".to_vec()
    });
    let err = transport::get(&Target::Unix(path), &Endpoint::ProfileCurrent, &Limits::default())
        .unwrap_err();
    assert_eq!(err, Error::Denied);
    assert!(!err.to_string().contains("secret"));
}

#[test]
fn missing_socket_is_an_io_error() {
    let path = temp_dir("none").join("absent.sock");
    let err =
        transport::get(&Target::Unix(path), &Endpoint::Status, &Limits::default()).unwrap_err();
    assert!(matches!(err, Error::Io(_)), "{err:?}");
}

#[test]
fn loopback_target_sends_basic_token() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let (mut conn, _) = listener.accept().unwrap();
        let mut req = Vec::new();
        let mut buf = [0u8; 1024];
        while !req.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = conn.read(&mut buf).unwrap();
            req.extend_from_slice(&buf[..n]);
        }
        conn.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 39\r\n\r\n{\"ControlURL\":\"https://hs.example.org\"}").unwrap();
        String::from_utf8(req).unwrap()
    });
    let target = Target::Loopback { port, token: "0123456789abcdef0123".into() };
    assert!(!format!("{target:?}").contains("0123456789abcdef"), "Debug redacts the token");
    let api = LocalApi::new(target, Limits::default());
    assert_eq!(
        api.control(),
        cmux_tailnet_local::ControlKind::SelfHosted { url: "https://hs.example.org".into() }
    );
    let req = server.join().unwrap();
    assert!(req.starts_with("GET /localapi/v0/prefs "));
    // base64(":0123456789abcdef0123")
    assert!(req.contains("Authorization: Basic OjAxMjM0NTY3ODlhYmNkZWYwMTIz\r\n"), "{req}");
}

#[test]
fn macos_proof_files() {
    assert_eq!(
        parse_app_store_proof("sameuserproof-54321-a1b2c3d4e5f6a7b8c9d0"),
        Some(Target::Loopback { port: 54321, token: "a1b2c3d4e5f6a7b8c9d0".into() })
    );
    assert_eq!(parse_app_store_proof("sameuserproof-54321"), None);
    assert_eq!(parse_app_store_proof("sameuserproof-0-abc"), None);
    assert_eq!(parse_app_store_proof("other-1-abc"), None);

    let containers = temp_dir("gc");
    let group = containers.join("W5364U7YZB.io.tailscale.ipn.macos");
    std::fs::create_dir_all(&group).unwrap();
    std::fs::write(group.join("sameuserproof-40000-deadbeef00"), b"").unwrap();
    std::fs::create_dir_all(containers.join("other.app")).unwrap();
    assert_eq!(
        transport::app_store_targets(&containers),
        vec![Target::Loopback { port: 40000, token: "deadbeef00".into() }]
    );

    let lib = temp_dir("macsys");
    std::os::unix::fs::symlink("41112", lib.join("ipnport")).unwrap();
    std::fs::write(lib.join("sameuserproof-41112"), b"cafebabe11\n").unwrap();
    assert_eq!(
        macsys_target(&lib),
        Some(Target::Loopback { port: 41112, token: "cafebabe11".into() })
    );
    assert_eq!(macsys_target(&temp_dir("empty")), None);
}
