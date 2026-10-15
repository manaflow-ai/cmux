//! `server ensure --ws-loopback`: the app's daemon opens its loopback
//! WebSocket listener with a credential it mints itself, and serves the page
//! bundle on the same listener (cx-hnmbt.2; spec/transports.md "App listener
//! and page files").
//!
//! A real owner started through the app's own ensure path. The credential
//! reaches the app only through a 0600 file next to the socket (never argv),
//! a page served by the listener has the listener's own origin, and the
//! Host/Origin rule holds for page files as it does for the WebSocket.

#![cfg(unix)]

use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest};

const PAGE_ORIGIN: &str = "cmux-page://cmux.home-channels";
const PAGE_HTML: &str = "<!doctype html><title>channels</title>";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    pages: PathBuf,
    session: String,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-apl-{name}-{}-{stamp}", std::process::id()));
        let pages = dir.join("pages");
        fs::create_dir_all(pages.join("home-channels")).unwrap();
        fs::write(pages.join("home-channels/index.html"), PAGE_HTML).unwrap();
        fs::write(dir.join("secret.txt"), "not a page").unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("apl-{name}"), pages, dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_PAGES_DIR", &self.pages);
        command
    }

    fn credential_file(&self) -> PathBuf {
        let mut name = self.socket.file_name().unwrap().to_os_string();
        name.push(".websocket.json");
        self.socket.with_file_name(name)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn parse_success(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "server ensure failed: {:?}\nstdout: {}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn owner_command_line(pid: u64) -> String {
    let output =
        Command::new("ps").args(["-o", "command=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// One HTTP/1.1 request; the whole reply (the listener closes after it).
fn http_get(addr: &str, path: &str, host: &str) -> String {
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    write!(stream, "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").unwrap();
    let mut reply = String::new();
    stream.read_to_string(&mut reply).unwrap();
    reply
}

fn status(reply: &str) -> &str {
    reply.split(' ').nth(1).unwrap_or("")
}

/// Opens the WebSocket with `origin`, presents `token` and calls `identify`.
fn identify_over_websocket(addr: &str, origin: &str, token: &str) -> Result<Value, String> {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut request = format!("ws://{addr}/").into_client_request().unwrap();
    request.headers_mut().insert("Origin", origin.parse().unwrap());
    let (mut socket, _) =
        tungstenite::client(request, stream).map_err(|error| error.to_string())?;
    socket.send(Message::Text(json!({"auth": {"token": token}}).to_string().into())).unwrap();
    socket.send(Message::Text(json!({"id": 1, "cmd": "identify"}).to_string().into())).unwrap();
    loop {
        match socket.read().map_err(|error| error.to_string())? {
            Message::Text(text) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["id"] == 1 {
                    return Ok(value);
                }
            }
            Message::Close(frame) => return Err(format!("closed: {frame:?}")),
            _ => {}
        }
    }
}

#[test]
fn the_apps_daemon_mints_its_websocket_credential_and_serves_its_pages() {
    let fixture = Fixture::new("listener");
    let output = fixture
        .command("ensure")
        .args(["--ws-loopback", "--ws-allow-origin", PAGE_ORIGIN])
        .output()
        .unwrap();
    let started = parse_success(&output);
    assert_eq!(started["status"], "started", "{started}");
    let pid = started["pid"].as_u64().unwrap();

    // The credential: a 0600 file next to the socket, never on the owner's argv.
    let path = fixture.credential_file();
    let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "credential file mode {mode:o}");
    let credential: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let token = credential["token"].as_str().unwrap().to_owned();
    assert!(token.len() >= 32, "{credential}");
    assert_eq!(credential["pid"].as_u64(), Some(pid), "{credential}");
    let url = credential["url"].as_str().unwrap();
    let addr = url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned();
    assert!(addr.starts_with("127.0.0.1:"), "{credential}");
    assert_eq!(credential["pages"], format!("http://{addr}/pages/"), "{credential}");
    assert!(!owner_command_line(pid).contains(&token), "the token is on the owner's argv");

    // The app's page origin and the listener's own origin connect with it.
    let identity = identify_over_websocket(&addr, PAGE_ORIGIN, &token).unwrap();
    assert_eq!(identity["ok"], true, "{identity}");
    let identity = identify_over_websocket(&addr, &format!("http://{addr}"), &token).unwrap();
    assert_eq!(identity["ok"], true, "{identity}");
    // A foreign page never reaches the auth step.
    assert!(identify_over_websocket(&addr, "http://evil.example", &token).is_err());
    // A wrong token is refused.
    assert!(identify_over_websocket(&addr, PAGE_ORIGIN, "wrong").is_err());

    // Page files on the same listener, with a policy that allows only it.
    let page = http_get(&addr, "/pages/home-channels/", &addr);
    assert_eq!(status(&page), "200", "{page}");
    assert!(page.ends_with(PAGE_HTML), "{page}");
    let lower = page.to_ascii_lowercase();
    assert!(lower.contains("content-type: text/html"), "{page}");
    assert!(lower.contains(&format!("connect-src 'self' ws://{addr}")), "{page}");
    assert!(lower.contains("x-content-type-options: nosniff"), "{page}");
    assert_eq!(status(&http_get(&addr, "/pages/home-channels/index.html", &addr)), "200");
    // The Host rule (DNS rebinding) holds for files too.
    assert_eq!(status(&http_get(&addr, "/pages/home-channels/", "evil.example")), "403");
    // Nothing outside the page bundle.
    assert_eq!(status(&http_get(&addr, "/pages/../secret.txt", &addr)), "404");
    assert_eq!(status(&http_get(&addr, "/pages/%2e%2e/secret.txt", &addr)), "404");
    assert_eq!(status(&http_get(&addr, "/pages/missing/", &addr)), "404");
    assert_eq!(status(&http_get(&addr, "/secret.txt", &addr)), "404");

    // A second ensure reports the same owner and keeps its credential.
    let again = parse_success(&fixture.command("ensure").args(["--ws-loopback"]).output().unwrap());
    assert_eq!(again["status"], "running", "{again}");
    let still: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(still["token"], token);

    // The file goes away with the owner.
    let stopped = fixture.command("stop").output().unwrap();
    assert!(stopped.status.success(), "{stopped:?}");
    assert!(!path.exists(), "credential file outlived its daemon");
}

/// An owner that the CLI or an agent starts from the app's bundled binary has
/// no `CMUX_TUI_PAGES_DIR` (only the app sets it), and must still serve the
/// pages the app bundles (cx-hnmbt.7): the binary is
/// `<app>/Contents/Resources/bin/cmux-tui`, the pages are in
/// `<app>/Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages`.
#[test]
fn an_owner_started_from_the_app_bundle_serves_its_pages_without_the_pages_env() {
    let fixture = Fixture::new("bundle");
    let resources = fixture.dir.join("cmux DEV.app/Contents/Resources");
    let pages = resources.join("CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages");
    fs::create_dir_all(pages.join("home-channels")).unwrap();
    fs::write(pages.join("home-channels/index.html"), PAGE_HTML).unwrap();
    fs::create_dir_all(resources.join("bin")).unwrap();
    let binary = resources.join("bin/cmux-tui");
    fs::copy(env!("CARGO_BIN_EXE_cmux-tui"), &binary).unwrap();

    let mut command = Command::new(&binary);
    command
        .args(["server", "ensure", "--json", "--ws-loopback", "--session", &fixture.session])
        .arg("--socket")
        .arg(&fixture.socket)
        .env("CMUX_TUI_STATE_DIR", fixture.dir.join("state"))
        .env("CMUX_TUI_CONFIG", fixture.dir.join("config.json"))
        .env_remove("CMUX_TUI_PAGES_DIR");
    let started = parse_success(&command.output().unwrap());
    assert_eq!(started["status"], "started", "{started}");

    let credential: Value =
        serde_json::from_slice(&fs::read(fixture.credential_file()).unwrap()).unwrap();
    let url = credential["url"].as_str().unwrap();
    let addr = url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned();
    let page = http_get(&addr, "/pages/home-channels/", &addr);
    assert_eq!(status(&page), "200", "{page}");
    assert!(page.ends_with(PAGE_HTML), "{page}");
}
