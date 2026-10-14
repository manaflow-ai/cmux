//! The local router with no default keychain (cx-f4thx): it runs on a random
//! in-memory install secret, says so in `status` (`install_secret:
//! ephemeral`), and the keys it mints work for that run only. Driven through
//! `acpmux router serve`, its admin socket and its loopback data plane. On
//! Linux the router always runs this way; on macOS the debug-only
//! `CMUX_CODEROUTER_TEST_NO_KEYCHAIN` takes the same path as a Mac without a
//! login keychain.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn scratch() -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-rsec-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// `acpmux router serve` on `home` (no owner FIFO: it runs until `shutdown`).
fn start_router(home: &Path, stderr: &Path) -> Child {
    let _ = std::fs::remove_file(home.join("router").join("router.sock"));
    let child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["router", "serve"])
        .env("ACPMUX_HOME", home)
        .env("CMUX_CODEROUTER_TEST_NO_KEYCHAIN", "1")
        .env("RUST_LOG", "warn")
        .env_remove("CMUX_ROUTER_OWNER_FIFO")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(std::fs::OpenOptions::new().create(true).append(true).open(stderr).unwrap())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while UnixStream::connect(home.join("router").join("router.sock")).is_err() {
        assert!(Instant::now() < deadline, "the router never opened its admin socket");
        std::thread::sleep(Duration::from_millis(50));
    }
    child
}

/// One admin request; the reply line as JSON.
fn ask(home: &Path, request: Value) -> Value {
    let mut stream = UnixStream::connect(home.join("router").join("router.sock")).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|e| panic!("{request}: no reply ({e}): {line:?}"))
}

/// The HTTP status of one chat completion through the data plane with `key`.
fn relay_status(port: u64, key: &str) -> u16 {
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port as u16)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let body = r#"{"model":"m","messages":[]}"#;
    let request = format!(
        "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).unwrap();
    let mut reply = String::new();
    let _ = stream.read_to_string(&mut reply);
    reply.split_whitespace().nth(1).and_then(|code| code.parse().ok()).unwrap_or(0)
}

fn stop(home: &Path, mut router: Child) {
    assert_eq!(ask(home, json!({"op": "shutdown"}))["stopping"], json!(true));
    let deadline = Instant::now() + Duration::from_secs(10);
    while router.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the router did not stop");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Every file under `dir` (the router's home), for a secret scan.
fn files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            files(&path, out);
        } else if kind.is_file() {
            out.push(path);
        }
    }
}

#[test]
fn with_no_keychain_keys_work_for_one_router_run_and_the_status_says_ephemeral() {
    let home = scratch();
    let log = home.join("router-stderr.log");
    let router = start_router(&home, &log);
    let status = ask(&home, json!({"op": "status"}));
    assert_eq!(status["install_secret"], "ephemeral", "{status}");
    let port = status["port"].as_u64().unwrap();
    let minted = ask(
        &home,
        json!({"op": "mint_key", "scope": {"harness": "fake", "session": "s1", "surfaces": [], "families": ["open_ai_chat"], "expires_at": 0}}),
    );
    let key = minted["key"].as_str().unwrap_or_else(|| panic!("no key minted: {minted}")).to_owned();
    // Within the run the key is accepted: the relay answers that no hosted
    // upstream is signed in (503), never that the key is unknown (401).
    assert_eq!(relay_status(port, &key), 503);
    assert_eq!(relay_status(port, &format!("{key}x")), 401);
    stop(&home, router);

    // A new run has a new secret: the old key is unknown there.
    let router = start_router(&home, &log);
    let status = ask(&home, json!({"op": "status"}));
    assert_eq!(status["install_secret"], "ephemeral", "{status}");
    let port = status["port"].as_u64().unwrap();
    assert_eq!(relay_status(port, &key), 401, "a key outlived its router run");
    stop(&home, router);

    // The secret part of the key reached no file under the home and no log.
    let secret = key.rsplit('_').next().unwrap().to_owned();
    let mut all = Vec::new();
    files(&home, &mut all);
    for path in all {
        let bytes = std::fs::read(&path).unwrap();
        assert!(
            !String::from_utf8_lossy(&bytes).contains(&secret),
            "the key's secret is in {}",
            path.display()
        );
    }
    let _ = std::fs::remove_dir_all(&home);
}
