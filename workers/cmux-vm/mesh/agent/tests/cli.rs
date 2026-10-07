//! The binary: key file handling, enrollment, and peers against a one-shot
//! HTTP stub on 127.0.0.1. Every output is checked for the private key.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread::JoinHandle;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use cmux_mesh_agent::key;

const BIN: &str = env!("CARGO_BIN_EXE_cmux-mesh-agent");
const SERVER_KEY: &str = "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=";

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static COUNT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "cmux-mesh-agent-test-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

fn agent(args: &[&str], envs: &[(&str, &str)]) -> Output {
    let mut command = Command::new(BIN);
    command.args(args).env_remove("CMUX_VM_API_URL").env_remove("CMUX_VM_API_KEY");
    for (key, value) in envs {
        command.env(key, value);
    }
    command.output().unwrap()
}

/// Every encoding of the private key that could leak: the file text, the
/// raw bytes as hex, and the base64 itself.
fn assert_no_private_key(key_file: &Path, outputs: &[&[u8]]) {
    let text = std::fs::read_to_string(key_file).unwrap();
    let private_b64 = text.trim().to_string();
    let bytes = STANDARD.decode(&private_b64).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    for output in outputs {
        let output = String::from_utf8_lossy(output);
        assert!(!output.contains(&private_b64), "private key in output: {output}");
        assert!(!output.contains(&hex), "private key (hex) in output: {output}");
    }
}

#[test]
fn keygen_writes_a_0600_key_and_prints_only_the_public_key() {
    let dir = TempDir::new();
    let key_file = dir.path("device.key");
    let output = agent(&["keygen", "--key-file", key_file.to_str().unwrap()], &[]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(mode(&key_file), 0o600);
    let public = String::from_utf8(output.stdout.clone()).unwrap();
    let public = public.trim();
    assert_eq!(STANDARD.decode(public).unwrap().len(), 32);
    let stored = key::read_key_file(&key_file).unwrap();
    assert_eq!(stored.public_key_base64(), public);
    assert_no_private_key(&key_file, &[&output.stdout, &output.stderr]);
}

#[test]
fn keygen_refuses_to_overwrite() {
    let dir = TempDir::new();
    let key_file = dir.path("device.key");
    std::fs::write(&key_file, "keep me\n").unwrap();
    let output = agent(&["keygen", "--key-file", key_file.to_str().unwrap()], &[]);
    assert!(!output.status.success());
    assert_eq!(std::fs::read_to_string(&key_file).unwrap(), "keep me\n");
    assert!(key::keygen(&key_file).is_err());
}

#[test]
fn private_key_debug_is_redacted() {
    let key = key::PrivateKey::generate().unwrap();
    assert_eq!(format!("{key:?}"), "PrivateKey(<redacted>)");
}

struct Request {
    line: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl Request {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
    }
}

/// Answer one HTTP request with `status` and `body`; return what was asked.
fn stub(status: u16, body: &'static str) -> (String, JoinHandle<Request>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let mut headers = Vec::new();
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).unwrap();
            let header = header.trim_end();
            if header.is_empty() {
                break;
            }
            let (key, value) = header.split_once(':').unwrap();
            headers.push((key.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
        let length = headers
            .iter()
            .find(|(key, _)| key == "content-length")
            .map_or(0, |(_, value)| value.parse::<usize>().unwrap());
        let mut request_body = vec![0u8; length];
        reader.read_exact(&mut request_body).unwrap();
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
        stream.flush().unwrap();
        Request {
            line: line.trim_end().to_string(),
            headers,
            body: String::from_utf8(request_body).unwrap(),
        }
    });
    (base, thread)
}

const ENROLLED: &str = r#"{"device":{"id":"dev_1","meshId":"mesh_abc","name":"laptop","wgPublicKey":"PUBLIC","tunnelId":"tun_1","createdAt":"2026-10-06T00:00:00Z"},"tunnel":{"id":"tun_1","meshId":"mesh_abc","deviceId":"dev_1","endpointHost":"tun-xyz.beta-vpn.freestyle.sh","endpointPort":51820,"serverPublicKey":"HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=","interfaceAddress":"100.64.0.1","meshAddress":null,"allowedIps":["10.128.16.0/20"]}}"#;

#[test]
fn enroll_posts_the_public_key_and_saves_a_0600_config() {
    let dir = TempDir::new();
    let key_file = dir.path("device.key");
    let config_file = dir.path("config.json");
    let public = key::keygen(&key_file).unwrap();
    let (base, server) = stub(201, ENROLLED);
    let output = agent(
        &[
            "enroll",
            "--key-file",
            key_file.to_str().unwrap(),
            "--mesh",
            "mesh_abc",
            "--name",
            "laptop",
            "--out",
            config_file.to_str().unwrap(),
        ],
        &[("CMUX_VM_API_URL", &base), ("CMUX_VM_API_KEY", "cmux_test_key")],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/meshes/mesh_abc/devices HTTP/1.1");
    assert_eq!(request.header("authorization"), Some("Bearer cmux_test_key"));
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(sent, serde_json::json!({ "name": "laptop", "wgPublicKey": public }));
    assert_eq!(mode(&config_file), 0o600);
    let saved = cmux_mesh_agent::config::load(&config_file).unwrap();
    assert_eq!(saved.device_id, "dev_1");
    assert_eq!(saved.tunnel.persistent_keepalive_seconds, 25);
    let printed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(printed["deviceId"], "dev_1");
    assert_eq!(printed["tunnelId"], "tun_1");
    let config_text = std::fs::read(&config_file).unwrap();
    assert_no_private_key(
        &key_file,
        &[&output.stdout, &output.stderr, request.body.as_bytes(), &config_text],
    );
}

#[test]
fn enroll_error_prints_tag_and_message() {
    let dir = TempDir::new();
    let key_file = dir.path("device.key");
    let config_file = dir.path("config.json");
    key::keygen(&key_file).unwrap();
    let (base, server) = stub(403, r#"{"_tag":"Forbidden","message":"mesh:write scope required"}"#);
    let output = agent(
        &[
            "enroll",
            "--key-file",
            key_file.to_str().unwrap(),
            "--mesh",
            "mesh_abc",
            "--name",
            "laptop",
            "--out",
            config_file.to_str().unwrap(),
        ],
        &[("CMUX_VM_API_URL", &base), ("CMUX_VM_API_KEY", "cmux_test_key")],
    );
    server.join().unwrap();
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "Forbidden");
    assert_eq!(error["message"], "mesh:write scope required");
    assert_eq!(error["status"], 403);
    assert!(!config_file.exists());
    assert_no_private_key(&key_file, &[&output.stdout, &output.stderr]);
}

#[test]
fn enroll_refuses_plain_http_to_a_remote_host() {
    let dir = TempDir::new();
    let key_file = dir.path("device.key");
    key::keygen(&key_file).unwrap();
    let output = agent(
        &[
            "enroll",
            "--key-file",
            key_file.to_str().unwrap(),
            "--mesh",
            "mesh_abc",
            "--name",
            "laptop",
            "--out",
            dir.path("config.json").to_str().unwrap(),
        ],
        &[("CMUX_VM_API_URL", "http://vm.cmux.dev"), ("CMUX_VM_API_KEY", "k")],
    );
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "InvalidApiUrl");
}

#[test]
fn peers_fetches_the_device_peer_map() {
    let dir = TempDir::new();
    let config_file = dir.path("config.json");
    std::fs::write(&config_file, ENROLLED).unwrap();
    let (base, server) = stub(
        200,
        r#"{"deviceId":"dev_1","meshId":"mesh_abc","aclVersion":2,"peers":[{"kind":"vm","id":"vm_a","address":"10.128.16.5","allow":[{"protocol":"icmp"}]}]}"#,
    );
    let output = agent(
        &["peers", "--config", config_file.to_str().unwrap()],
        &[("CMUX_VM_API_URL", &base), ("CMUX_VM_API_KEY", "cmux_test_key")],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "GET /v1/devices/dev_1/peers HTTP/1.1");
    assert_eq!(request.header("authorization"), Some("Bearer cmux_test_key"));
    let printed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(printed["aclVersion"], 2);
    assert_eq!(printed["peers"][0]["id"], "vm_a");
}

#[test]
fn server_key_constant_is_valid() {
    assert_eq!(STANDARD.decode(SERVER_KEY).unwrap().len(), 32);
}
