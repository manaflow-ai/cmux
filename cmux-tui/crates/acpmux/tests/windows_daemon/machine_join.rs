//! The Windows machine join, through acpmux's CLI only: `host join` redeems a token read from
//! stdin against a stand-in hub and proposes `platform: "windows"`, `host join --status` then
//! reads the join back, `daemon service install|status|uninstall` registers and removes the
//! per-user logon task in Task Scheduler, and `cmux-tui/scripts/machine-join.ps1` parses.

use super::{acpmux, exe, scratch, spawns, text};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const TOKEN: &str = "cmj_windows_test_secret_never_print";

/// The account-wide consent files a join writes under the OS profile (`machine_consent.rs`):
/// on drop, only those that were absent at entry are removed again.
struct AccountConsentRestored(Vec<PathBuf>);

impl AccountConsentRestored {
    fn new() -> Self {
        let root =
            dirs::home_dir().expect("profile folder").join(".acpmux").join("machine-consent");
        let mut paths: Vec<PathBuf> =
            ["enrolled.json", "refusal.json", "consent.json", "write.lock"]
                .iter()
                .map(|name| root.join(name))
                .collect();
        let parent = root.parent().map(Path::to_owned);
        paths.push(root);
        paths.extend(parent);
        Self(paths.into_iter().filter(|p| std::fs::symlink_metadata(p).is_err()).collect())
    }
}

impl Drop for AccountConsentRestored {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ =
                if path.is_dir() { std::fs::remove_dir(path) } else { std::fs::remove_file(path) };
        }
    }
}

/// One HTTP request: its request line and its JSON body.
fn read_request(socket: &std::net::TcpStream) -> (String, String, Value) {
    let mut reader = BufReader::new(socket.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let (mut length, mut bearer) = (0usize, String::new());
    loop {
        let mut header = String::new();
        assert!(reader.read_line(&mut header).unwrap() > 0, "truncated HTTP headers");
        if header == "\r\n" {
            break;
        }
        assert!(!header.contains("cmj_"), "the join token in a header");
        if let Some((key, value)) = header.split_once(':') {
            if key.eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().unwrap();
            }
            if key.eq_ignore_ascii_case("authorization") {
                bearer = value.trim().to_owned();
            }
        }
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes).unwrap();
    let body = if bytes.is_empty() { Value::Null } else { serde_json::from_slice(&bytes).unwrap() };
    (line, bearer, body)
}

fn respond(mut socket: std::net::TcpStream, body: Value) {
    let body = body.to_string();
    write!(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
}

/// The hub's two calls of a join: the redeem, then the credential's own read. Hands back the
/// redeem's body.
fn hub() -> (String, std::thread::JoinHandle<Value>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let thread = std::thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let (line, bearer, redeem) = read_request(&socket);
        assert!(line.starts_with("POST /v1/machines/join-tokens/redeem "), "{line}");
        assert!(bearer.is_empty());
        assert!(!line.contains("cmj_"));
        respond(
            socket,
            json!({"machineId":"machine_test", "teamId":"team_test", "joinTokenId":"join_test",
                   "wgPublicKey":redeem["wgPublicKey"], "expiresAt":"2099-01-01T00:00:00.000Z"}),
        );
        let (socket, _) = listener.accept().unwrap();
        let (line, bearer, _) = read_request(&socket);
        assert!(line.starts_with("GET /v1/machines/credentials/self "), "{line}");
        assert_eq!(bearer, format!("Bearer {}", redeem["proposedCredential"].as_str().unwrap()));
        respond(
            socket,
            json!({"machineId":"machine_test", "teamId":"team_test", "joinTokenId":"join_test",
                   "wgPublicKey":redeem["wgPublicKey"], "platform":redeem["platform"],
                   "hostname":redeem["hostname"], "name":redeem["name"], "credentialGeneration":1,
                   "expiresAt":"2099-01-01T00:00:00.000Z"}),
        );
        redeem
    });
    (origin, thread)
}

/// `child` within `limit`, or killed.
fn wait_output(mut child: std::process::Child, limit: Duration) -> std::process::Output {
    let start = Instant::now();
    while child.try_wait().unwrap().is_none() {
        if start.elapsed() > limit {
            let _ = child.kill();
            panic!("acpmux did not finish within {limit:?}");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    child.wait_with_output().unwrap()
}

#[test]
fn host_join_on_windows_redeems_the_token_from_stdin_as_a_windows_machine() {
    let _spawns = spawns();
    let _consent = AccountConsentRestored::new();
    let home = scratch("join");
    std::fs::create_dir_all(&home).unwrap();
    let (origin, server) = hub();
    let mut child = acpmux(&exe(), &home)
        .args(["host", "join", "--hub", &origin, "--name", "winbox", "--json"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(format!("{TOKEN}\n").as_bytes()).unwrap();
    let out = wait_output(child, Duration::from_secs(60));
    assert_eq!(out.status.code(), Some(0), "{}", text(&out));
    let printed = text(&out);
    assert!(!printed.contains("cmj_") && !printed.contains("cmm_"), "a secret in the output");
    let redeem = server.join().unwrap();
    assert_eq!(redeem["token"], TOKEN);
    assert_eq!(redeem["platform"], "windows");
    assert_eq!(redeem["name"], "winbox");

    // Nothing on disk holds the join token; the credential is in place and the relay set.
    for entry in walk(&home) {
        let bytes = std::fs::read(&entry).unwrap();
        assert!(!bytes.windows(TOKEN.len()).any(|w| w == TOKEN.as_bytes()), "{}", entry.display());
    }
    assert!(home.join("machine-credential.json").is_file());
    assert!(!home.join("machine-join.pending.json").exists());
    let config: Value =
        serde_json::from_slice(&std::fs::read(home.join("config.json")).unwrap()).unwrap();
    assert_eq!(config["meshRelay"]["credential"], "join");
    assert_eq!(config["meshRelay"]["url"], origin);

    let status =
        acpmux(&exe(), &home).args(["host", "join", "--status", "--json"]).output().unwrap();
    assert!(status.status.success(), "{}", text(&status));
    let status: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["credentialPresent"], true, "{status}");
    assert_eq!(status["revoked"], false, "{status}");
    let _ = std::fs::remove_dir_all(&home);
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() { files.extend(walk(&path)) } else { files.push(path) }
    }
    files
}

fn schtasks(args: &[&str]) -> std::process::Output {
    Command::new("schtasks").args(args).stdin(Stdio::null()).output().unwrap()
}

#[test]
fn daemon_service_installs_and_removes_the_logon_task() {
    let _spawns = spawns();
    if schtasks(&["/Query", "/TN", "acpmux"]).status.success() {
        // This account's own logon task: never this test's to replace.
        eprintln!("skipped: this account already has an acpmux logon task");
        return;
    }
    let home = scratch("service");
    std::fs::create_dir_all(&home).unwrap();
    let service = |action: &str| {
        let out =
            acpmux(&exe(), &home).args(["--json", "daemon", "service", action]).output().unwrap();
        assert!(out.status.success(), "daemon service {action}: {}", text(&out));
        serde_json::from_slice::<Value>(&out.stdout).unwrap()
    };
    let installed = service("install");
    let cleanup = scopeguard(|| {
        let _ = schtasks(&["/Delete", "/TN", "acpmux", "/F"]);
    });
    assert_eq!(installed["manager"], "task", "{installed}");
    assert_eq!(installed["installed"], true);
    let registered = schtasks(&["/Query", "/TN", "acpmux", "/XML"]);
    assert!(registered.status.success());
    let xml = String::from_utf8_lossy(&registered.stdout).to_string();
    assert!(xml.contains("<LogonTrigger>"), "{xml}");
    assert!(xml.contains("<Arguments>daemon start</Arguments>"), "{xml}");
    assert!(xml.contains("<RunLevel>LeastPrivilege</RunLevel>"), "{xml}");
    assert_eq!(service("status")["installed"], true);
    // Again: the same XML, nothing re-registered.
    assert_eq!(service("install")["changed"], false);
    let removed = service("uninstall");
    assert_eq!(removed["state"], "notInstalled", "{removed}");
    assert!(!schtasks(&["/Query", "/TN", "acpmux"]).status.success());
    assert_eq!(service("status")["installed"], false);
    drop(cleanup);
    let _ = std::fs::remove_dir_all(&home);
}

struct Guard<F: FnMut()>(F);
impl<F: FnMut()> Drop for Guard<F> {
    fn drop(&mut self) {
        (self.0)()
    }
}
fn scopeguard<F: FnMut()>(f: F) -> Guard<F> {
    Guard(f)
}

#[test]
fn the_windows_join_script_parses() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/machine-join.ps1");
    let check = format!(
        "$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('{}', [ref]$null, [ref]$e); \
         if ($e) {{ $e | ForEach-Object {{ $_.ToString() }}; exit 1 }}",
        script.display().to_string().replace('\'', "''")
    );
    let out = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &check])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "machine-join.ps1 does not parse: {}", text(&out));
}
