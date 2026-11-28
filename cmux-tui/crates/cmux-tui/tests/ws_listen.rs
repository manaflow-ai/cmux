//! `ws-listen` (`ws-listen-v1`, cx-hnmbt.5): a running owner that was
//! started without its page listener (by the CLI, an agent, or an app build
//! before slice 2) opens the loopback WebSocket listener and its credential
//! file on request, so the app's pages never wait forever on "connecting".
//!
//! A real owner started through `server ensure` with no `--ws-loopback`. The
//! app's request over the Unix socket opens the listener; the credential
//! reaches the app only through the 0600 file next to the socket (never in
//! the reply), the app's page origin connects with it, a second request
//! reports the same listener, a WebSocket client cannot open one, and the
//! file goes away with the owner.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest};

const PAGE_ORIGIN: &str = "cmux-page://cmux.home-channels";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-wsl-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("wsl-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    fn ensure(&self, args: &[&str]) {
        let output = self.command("ensure").args(args).output().unwrap();
        assert!(output.status.success(), "ensure: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn credential_file(&self) -> PathBuf {
        let mut name = self.socket.file_name().unwrap().to_os_string();
        name.push(".websocket.json");
        self.socket.with_file_name(name)
    }

    fn rpc(&self, request: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == request["id"] {
                return value;
            }
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Opens the WebSocket with `origin`, presents `token` and sends `request`.
fn over_websocket(addr: &str, origin: &str, token: &str, request: Value) -> Result<Value, String> {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut handshake = format!("ws://{addr}/").into_client_request().unwrap();
    handshake.headers_mut().insert("Origin", origin.parse().unwrap());
    let (mut socket, _) =
        tungstenite::client(handshake, stream).map_err(|error| error.to_string())?;
    socket.send(Message::Text(json!({"auth": {"token": token}}).to_string().into())).unwrap();
    socket.send(Message::Text(request.to_string().into())).unwrap();
    loop {
        match socket.read().map_err(|error| error.to_string())? {
            Message::Text(text) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value.get("event").is_none() && value["id"] == request["id"] {
                    return Ok(value);
                }
            }
            Message::Close(frame) => return Err(format!("closed: {frame:?}")),
            _ => {}
        }
    }
}

#[test]
fn a_running_owner_without_a_page_listener_opens_one_on_request() {
    let fixture = Fixture::new("open");
    // An owner the CLI started: no page listener, no credential file.
    fixture.ensure(&[]);
    let path = fixture.credential_file();
    assert!(!path.exists(), "an owner without --ws-loopback wrote a credential file");
    let identity = fixture.rpc(json!({"id": 1, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|v| v == "ws-listen-v1"), "{identity}");

    let opened = fixture.rpc(json!({"id": 2, "cmd": "ws-listen", "allow_origin": PAGE_ORIGIN}));
    assert_eq!(opened["ok"], true, "{opened}");
    assert_eq!(opened["data"]["opened"], true, "{opened}");
    let url = opened["data"]["url"].as_str().unwrap().to_owned();
    let addr = url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned();
    assert!(addr.starts_with("127.0.0.1:"), "{opened}");
    assert_eq!(opened["data"]["pages"], format!("http://{addr}/pages/"), "{opened}");

    // The credential: only in the 0600 file, never in the reply.
    let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "credential file mode {mode:o}");
    let credential: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let token = credential["token"].as_str().unwrap().to_owned();
    assert!(token.len() >= 32, "{credential}");
    assert_eq!(credential["url"], url, "{credential}");
    assert!(!opened.to_string().contains(&token), "the reply carried the credential");

    // The app's page origin connects with it; a foreign origin and a wrong token do not.
    let identify = json!({"id": 1, "cmd": "identify"});
    let page = over_websocket(&addr, PAGE_ORIGIN, &token, identify.clone()).unwrap();
    assert_eq!(page["ok"], true, "{page}");
    assert!(over_websocket(&addr, "http://evil.example", &token, identify.clone()).is_err());
    assert!(over_websocket(&addr, PAGE_ORIGIN, "wrong", identify).is_err());

    // A WebSocket client cannot open listeners (local admin).
    let refused =
        over_websocket(&addr, PAGE_ORIGIN, &token, json!({"id": 3, "cmd": "ws-listen"})).unwrap();
    assert_eq!(refused["ok"], false, "{refused}");

    // A second request reports the same listener and keeps the credential.
    let again = fixture.rpc(json!({"id": 4, "cmd": "ws-listen", "allow_origin": PAGE_ORIGIN}));
    assert_eq!(again["data"]["opened"], false, "{again}");
    assert_eq!(again["data"]["url"], url, "{again}");
    let still: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(still["token"], token);

    // The file goes away with the owner.
    let stopped = fixture.command("stop").output().unwrap();
    assert!(stopped.status.success(), "{stopped:?}");
    assert!(!path.exists(), "credential file outlived its daemon");
}

#[test]
fn an_owner_with_its_page_listener_reports_it() {
    let fixture = Fixture::new("have");
    fixture.ensure(&["--ws-loopback", "--ws-allow-origin", PAGE_ORIGIN]);
    let credential: Value =
        serde_json::from_slice(&fs::read(fixture.credential_file()).unwrap()).unwrap();
    let reply = fixture.rpc(json!({"id": 1, "cmd": "ws-listen", "allow_origin": PAGE_ORIGIN}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["opened"], false, "{reply}");
    assert_eq!(reply["data"]["url"], credential["url"], "{reply}");
}

/// cx-hnmbt.10: the app's page listener admits the set of the app's
/// first-party page origins (`cmux-page://cmux.<page>`), not only the
/// Channels page, and no other origin. Both doors: `server ensure
/// --ws-allow-origin <list>` (the app's launch) and `ws-listen
/// {allow_origins}` (an owner started without the listener). A page origin
/// connects as its page (page-router-v1): History reads history.
#[test]
fn the_page_listener_admits_every_app_page_origin_and_no_other() {
    const ORIGINS: [&str; 3] =
        ["cmux-page://cmux.home-channels", "cmux-page://cmux.history", "cmux-page://cmux.apps"];
    let identify = json!({"id": 1, "cmd": "identify"});
    let history_list = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "list",
        "operation": "history.entries.list",
        "params": {"machine": "current", "session": "current", "limit": 5},
    });
    let admits_exactly_the_app_pages = |addr: &str, token: &str| {
        for origin in ORIGINS {
            let reply = over_websocket(addr, origin, token, identify.clone()).unwrap();
            assert_eq!(reply["ok"], true, "{origin}: {reply}");
        }
        let read = over_websocket(addr, ORIGINS[1], token, history_list.clone()).unwrap();
        assert_eq!(read["ok"], true, "{read}");
        for foreign in ["cmux-page://cmux.unlisted", "cmux-page://evil", "http://evil.example"] {
            assert!(over_websocket(addr, foreign, token, identify.clone()).is_err(), "{foreign}");
        }
    };
    let endpoint = |fixture: &Fixture| {
        let credential: Value =
            serde_json::from_slice(&fs::read(fixture.credential_file()).unwrap()).unwrap();
        let url = credential["url"].as_str().unwrap();
        let addr = url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned();
        (addr, credential["token"].as_str().unwrap().to_owned())
    };

    // The app's launch: one comma-separated list.
    let launched = Fixture::new("origins");
    launched.ensure(&["--ws-loopback", "--ws-allow-origin", &ORIGINS.join(",")]);
    let (addr, token) = endpoint(&launched);
    admits_exactly_the_app_pages(&addr, &token);
    // A malformed member refuses the whole list.
    let bad = launched
        .command("ensure")
        .args(["--ws-loopback", "--ws-allow-origin", "cmux-page://cmux.history,null"])
        .output()
        .unwrap();
    assert!(!bad.status.success(), "a list with null was accepted");

    // An owner without the listener opens it for the same list.
    let opened = Fixture::new("listen-origins");
    opened.ensure(&[]);
    let identity = opened.rpc(json!({"id": 1, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|v| v == "ws-listen-origins-v1"), "{identity}");
    let reply = opened.rpc(json!({"id": 2, "cmd": "ws-listen", "allow_origins": ORIGINS}));
    assert_eq!(reply["ok"], true, "{reply}");
    let (addr, token) = endpoint(&opened);
    admits_exactly_the_app_pages(&addr, &token);
    // The listener is bound: a request for an origin it does not admit says so.
    let other = ["cmux-page://cmux.other"];
    let more = opened.rpc(json!({"id": 3, "cmd": "ws-listen", "allow_origins": other}));
    assert_eq!(more["ok"], false, "{more}");
    assert!(more["error"].as_str().unwrap_or_default().contains("does not admit"), "{more}");
    // One that names some admitted origins gets the endpoint and the admitted list.
    let some = [ORIGINS[1], "cmux-page://cmux.other"];
    let partial = opened.rpc(json!({"id": 4, "cmd": "ws-listen", "allow_origins": some}));
    assert_eq!(partial["ok"], true, "{partial}");
    assert_eq!(partial["data"]["origins"], json!(ORIGINS), "{partial}");
}
