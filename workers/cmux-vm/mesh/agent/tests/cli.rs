//! The binary: key file handling, enrollment, rotation, and peers against a
//! one-shot HTTP stub on 127.0.0.1. Every output is checked for the private
//! keys, and enrollment by code for the code.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread::JoinHandle;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use cmux_mesh_agent::{install, key};
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};

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
    command
        .args(args)
        .env_remove("CMUX_VM_API_URL")
        .env_remove("CMUX_VM_API_KEY")
        .env_remove("CMUX_MESH_ENROLL_CODE");
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
    let install_file = dir.path("install.key");
    let public = key::keygen(&key_file).unwrap();
    let install_public = install::install_keygen(&install_file).unwrap();
    let (base, server) = stub(201, ENROLLED);
    let output = agent(
        &[
            "enroll",
            "--key-file",
            key_file.to_str().unwrap(),
            "--install-key",
            install_file.to_str().unwrap(),
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
    assert_eq!(sent["name"], "laptop");
    assert_eq!(sent["wgPublicKey"], public);
    assert_eq!(sent["installPublicKey"], install_public);
    assert!(sent.get("code").is_none());
    assert_signed(&sent, "enroll", "mesh_abc", &public, &install_public, "laptop");
    assert_eq!(mode(&config_file), 0o600);
    let saved = cmux_mesh_agent::config::load(&config_file).unwrap();
    assert_eq!(saved.device_id, "dev_1");
    assert_eq!(saved.tunnel.persistent_keepalive_seconds, 25);
    let printed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(printed["deviceId"], "dev_1");
    assert_eq!(printed["tunnelId"], "tun_1");
    let config_text = std::fs::read(&config_file).unwrap();
    let outputs: [&[u8]; 4] =
        [&output.stdout, &output.stderr, request.body.as_bytes(), &config_text];
    assert_no_private_key(&key_file, &outputs);
    assert_no_private_key(&install_file, &outputs);
}

#[test]
fn enroll_error_prints_tag_and_message() {
    let dir = TempDir::new();
    let key_file = dir.path("device.key");
    let config_file = dir.path("config.json");
    key::keygen(&key_file).unwrap();
    let install_file = dir.path("install.key");
    install::install_keygen(&install_file).unwrap();
    let (base, server) = stub(403, r#"{"_tag":"Forbidden","message":"mesh:write scope required"}"#);
    let output = agent(
        &[
            "enroll",
            "--key-file",
            key_file.to_str().unwrap(),
            "--install-key",
            install_file.to_str().unwrap(),
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
    let install_file = dir.path("install.key");
    install::install_keygen(&install_file).unwrap();
    let output = agent(
        &[
            "enroll",
            "--key-file",
            key_file.to_str().unwrap(),
            "--install-key",
            install_file.to_str().unwrap(),
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

/// Check a request body's `signedAt`, `nonce`, and `signature` against the
/// wire format: the signature verifies (p256, P1363 r||s) over the eight-line
/// message rebuilt here from the body and the expected fields.
fn assert_signed(
    sent: &serde_json::Value,
    purpose: &str,
    target: &str,
    wg_key: &str,
    install_public: &str,
    name: &str,
) {
    let signed_at = sent["signedAt"].as_u64().expect("signedAt is a number");
    let now = cmux_mesh_agent::ops::wall_ms();
    assert!(signed_at <= now && now - signed_at < 60_000, "signedAt {signed_at} vs {now}");
    let nonce = sent["nonce"].as_str().unwrap();
    assert_eq!(nonce.len(), 22);
    assert_eq!(base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(nonce).unwrap().len(), 16);
    let message = format!(
        "cmux-mesh-v1\n{purpose}\n{target}\n{wg_key}\n{install_public}\n{name}\n{signed_at}\n{nonce}"
    );
    let public = STANDARD.decode(install_public).unwrap();
    assert_eq!(public.len(), 65);
    let verifying = VerifyingKey::from_sec1_bytes(&public).unwrap();
    let signature = STANDARD.decode(sent["signature"].as_str().unwrap()).unwrap();
    assert_eq!(signature.len(), 64);
    let signature = Signature::from_slice(&signature).unwrap();
    verifying.verify(message.as_bytes(), &signature).expect("signature verifies");
}

#[test]
fn install_keygen_writes_a_0600_key_and_prints_the_public_point() {
    let dir = TempDir::new();
    let install_file = dir.path("install.key");
    let output = agent(&["install-keygen", "--out", install_file.to_str().unwrap()], &[]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(mode(&install_file), 0o600);
    let public = String::from_utf8(output.stdout.clone()).unwrap();
    let public = public.trim();
    let point = STANDARD.decode(public).unwrap();
    assert_eq!((point.len(), point[0]), (65, 0x04));
    let stored = install::read_install_key_file(&install_file).unwrap();
    assert_eq!(stored.public_key_base64(), public);
    assert_no_private_key(&install_file, &[&output.stdout, &output.stderr]);
}

#[test]
fn install_keygen_refuses_to_overwrite() {
    let dir = TempDir::new();
    let install_file = dir.path("install.key");
    std::fs::write(&install_file, "keep me\n").unwrap();
    let output = agent(&["install-keygen", "--out", install_file.to_str().unwrap()], &[]);
    assert!(!output.status.success());
    assert_eq!(std::fs::read_to_string(&install_file).unwrap(), "keep me\n");
}

#[test]
fn enroll_requires_an_install_key() {
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
        &[("CMUX_VM_API_URL", "http://127.0.0.1:1"), ("CMUX_VM_API_KEY", "k")],
    );
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("--install-key"));
}

const CODE: &str = "mec_0123456789abcdefghjkmnpqrs";

fn enroll_args<'a>(paths: &'a [String; 3], extra: &[&'a str]) -> Vec<&'a str> {
    let mut args = vec![
        "enroll",
        "--key-file",
        paths[0].as_str(),
        "--install-key",
        paths[1].as_str(),
        "--mesh",
        "mesh_abc",
        "--name",
        "laptop",
        "--out",
        paths[2].as_str(),
    ];
    args.extend_from_slice(extra);
    args
}

struct EnrollFiles {
    paths: [String; 3],
    key_file: PathBuf,
    install_file: PathBuf,
    config_file: PathBuf,
    public: String,
    install_public: String,
}

fn enroll_files(dir: &TempDir) -> EnrollFiles {
    let key_file = dir.path("device.key");
    let install_file = dir.path("install.key");
    let config_file = dir.path("config.json");
    let public = key::keygen(&key_file).unwrap();
    let install_public = install::install_keygen(&install_file).unwrap();
    let paths = [&key_file, &install_file, &config_file].map(|p| p.to_str().unwrap().to_string());
    EnrollFiles { paths, key_file, install_file, config_file, public, install_public }
}

#[test]
fn enroll_with_a_code_from_the_environment_sends_no_authorization() {
    let dir = TempDir::new();
    let files = enroll_files(&dir);
    let (base, server) = stub(201, ENROLLED);
    // An API key in the environment must still not be sent with a code.
    let output = agent(
        &enroll_args(&files.paths, &[]),
        &[
            ("CMUX_VM_API_URL", &base),
            ("CMUX_VM_API_KEY", "cmux_test_key"),
            ("CMUX_MESH_ENROLL_CODE", CODE),
        ],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/meshes/mesh_abc/device-enrollments HTTP/1.1");
    assert_eq!(request.header("authorization"), None);
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(sent["code"], CODE);
    assert_eq!(sent["name"], "laptop");
    assert_eq!(sent["wgPublicKey"], files.public);
    assert_eq!(sent["installPublicKey"], files.install_public);
    assert_signed(&sent, "enroll", "mesh_abc", &files.public, &files.install_public, "laptop");
    let saved = cmux_mesh_agent::config::load(&files.config_file).unwrap();
    assert_eq!(saved.device_id, "dev_1");
    assert_eq!(mode(&files.config_file), 0o600);
    for stream in [&output.stdout, &output.stderr] {
        assert!(!String::from_utf8_lossy(stream).contains(CODE), "code printed");
    }
    let outputs: [&[u8]; 3] = [&output.stdout, &output.stderr, request.body.as_bytes()];
    assert_no_private_key(&files.key_file, &outputs);
    assert_no_private_key(&files.install_file, &outputs);
}

#[test]
fn enroll_with_a_code_flag_needs_no_api_key() {
    let dir = TempDir::new();
    let files = enroll_files(&dir);
    let (base, server) = stub(201, ENROLLED);
    let output =
        agent(&enroll_args(&files.paths, &["--code", CODE]), &[("CMUX_VM_API_URL", &base)]);
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/meshes/mesh_abc/device-enrollments HTTP/1.1");
    assert_eq!(request.header("authorization"), None);
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(sent["code"], CODE);
}

#[test]
fn enroll_rejects_a_malformed_code_without_printing_it() {
    for bad in [
        "mec_0123456789ABCDEFGHJKMNPQRS",
        "mec_0123456789abcdefghjkmnpqr",
        "mec_0123456789abcdefghjkmnpqrsi",
        "mec_0123456789abcdefghiklmnopq",
        "mek_0123456789abcdefghjkmnpqrs",
        "",
    ] {
        let dir = TempDir::new();
        let files = enroll_files(&dir);
        // Nothing listens on port 1: a request would fail as Transport.
        let output = agent(
            &enroll_args(&files.paths, &[]),
            &[("CMUX_VM_API_URL", "http://127.0.0.1:1"), ("CMUX_MESH_ENROLL_CODE", bad)],
        );
        assert!(!output.status.success(), "{bad:?} accepted");
        let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["error"], "InvalidEnrollCode", "{bad:?}");
        if !bad.is_empty() {
            assert!(!String::from_utf8_lossy(&output.stderr).contains(bad));
        }
        assert!(!files.config_file.exists());
    }
}

#[test]
fn enroll_rejects_a_multiline_name() {
    let dir = TempDir::new();
    let files = enroll_files(&dir);
    let mut args = enroll_args(&files.paths, &[]);
    args[8] = "lap\ntop";
    let output =
        agent(&args, &[("CMUX_VM_API_URL", "http://127.0.0.1:1"), ("CMUX_VM_API_KEY", "k")]);
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "InvalidName");
}

const NEW_SERVER_KEY: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";

/// A saved enrollment whose device record carries `public`.
fn enrolled_config(public: &str) -> String {
    ENROLLED.replace(r#""wgPublicKey":"PUBLIC""#, &format!(r#""wgPublicKey":"{public}""#))
}

fn rotated_tunnel() -> String {
    r#"{"id":"tun_1","meshId":"mesh_abc","deviceId":"dev_1","endpointHost":"tun-xyz.beta-vpn.freestyle.sh","endpointPort":51820,"serverPublicKey":"NEWKEY","interfaceAddress":"100.64.0.1","meshAddress":null,"allowedIps":["10.128.16.0/20"]}"#
        .replace("NEWKEY", NEW_SERVER_KEY)
}

struct RotateFiles {
    config_file: PathBuf,
    key_file: PathBuf,
    install_file: PathBuf,
    new_key_file: PathBuf,
    old_public: String,
    install_public: String,
    old_key_text: String,
}

fn rotate_files(dir: &TempDir) -> RotateFiles {
    let config_file = dir.path("config.json");
    let key_file = dir.path("device.key");
    let install_file = dir.path("install.key");
    let old_public = key::keygen(&key_file).unwrap();
    let install_public = install::install_keygen(&install_file).unwrap();
    std::fs::write(&config_file, enrolled_config(&old_public)).unwrap();
    std::fs::set_permissions(&config_file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let old_key_text = std::fs::read_to_string(&key_file).unwrap();
    RotateFiles {
        config_file,
        key_file,
        install_file,
        new_key_file: dir.path("device.next.key"),
        old_public,
        install_public,
        old_key_text,
    }
}

fn rotate_args(files: &RotateFiles, api: &str) -> Vec<String> {
    [
        "rotate",
        "--config",
        files.config_file.to_str().unwrap(),
        "--key-file",
        files.key_file.to_str().unwrap(),
        "--install-key",
        files.install_file.to_str().unwrap(),
        "--new-key-file",
        files.new_key_file.to_str().unwrap(),
        "--api",
        api,
    ]
    .map(String::from)
    .to_vec()
}

fn run_rotate(files: &RotateFiles, api: &str, envs: &[(&str, &str)]) -> Output {
    let args = rotate_args(files, api);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    agent(&args, envs)
}

#[test]
fn rotate_signs_posts_and_rewrites_the_config_keeping_the_old_key() {
    let dir = TempDir::new();
    let files = rotate_files(&dir);
    let tunnel = rotated_tunnel();
    let (base, server) = stub(200, Box::leak(tunnel.into_boxed_str()));
    let before = cmux_mesh_agent::ops::wall_ms();
    let output = run_rotate(&files, &base, &[("CMUX_VM_API_KEY", "cmux_test_key")]);
    let after = cmux_mesh_agent::ops::wall_ms();
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/devices/dev_1/rotate-key HTTP/1.1");
    assert_eq!(request.header("authorization"), Some("Bearer cmux_test_key"));

    // The new key: 0600, and it is the one the request registers.
    assert_eq!(mode(&files.new_key_file), 0o600);
    let new_public = key::read_key_file(&files.new_key_file).unwrap().public_key_base64();
    assert_ne!(new_public, files.old_public);
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(sent["newPublicKey"], new_public);
    assert!(sent.get("installPublicKey").is_none() && sent.get("code").is_none());
    assert_signed(&sent, "rotate-key", "dev_1", &new_public, &files.install_public, "");

    // The old key file stays exactly as it was.
    assert_eq!(std::fs::read_to_string(&files.key_file).unwrap(), files.old_key_text);

    // The config now has the new server key and records the new device key.
    assert_eq!(mode(&files.config_file), 0o600);
    let saved = cmux_mesh_agent::config::load(&files.config_file).unwrap();
    assert_eq!(saved.device_id, "dev_1");
    assert_eq!(STANDARD.encode(saved.tunnel.server_public_key), NEW_SERVER_KEY);
    assert_eq!(saved.wg_public_key.as_deref(), Some(new_public.as_str()));
    let leftovers: Vec<_> = std::fs::read_dir(&dir.0)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| {
            !["config.json", "device.key", "install.key", "device.next.key"]
                .contains(&name.as_str())
        })
        .collect();
    assert!(leftovers.is_empty(), "temp files left: {leftovers:?}");

    let printed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(printed["deviceId"], "dev_1");
    assert_eq!(printed["serverPublicKey"], NEW_SERVER_KEY);
    assert_eq!(printed["wgPublicKey"], new_public);
    let sent_at = printed["sentAtMs"].as_u64().unwrap();
    let responded_at = printed["respondedAtMs"].as_u64().unwrap();
    assert!(before <= sent_at && sent_at <= responded_at && responded_at <= after);

    let config_text = std::fs::read(&files.config_file).unwrap();
    let outputs: [&[u8]; 4] =
        [&output.stdout, &output.stderr, request.body.as_bytes(), &config_text];
    assert_no_private_key(&files.key_file, &outputs);
    assert_no_private_key(&files.new_key_file, &outputs);
    assert_no_private_key(&files.install_file, &outputs);
}

#[test]
fn rotate_refuses_an_existing_new_key_file_before_any_request() {
    let dir = TempDir::new();
    let files = rotate_files(&dir);
    std::fs::write(&files.new_key_file, "keep me\n").unwrap();
    let config_before = std::fs::read_to_string(&files.config_file).unwrap();
    // Nothing listens on port 1: a request would fail as Transport.
    let output = run_rotate(&files, "http://127.0.0.1:1", &[("CMUX_VM_API_KEY", "k")]);
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "KeyExists");
    assert_eq!(std::fs::read_to_string(&files.new_key_file).unwrap(), "keep me\n");
    assert_eq!(std::fs::read_to_string(&files.config_file).unwrap(), config_before);
}

#[test]
fn rotate_error_leaves_the_config_alone() {
    let dir = TempDir::new();
    let files = rotate_files(&dir);
    let config_before = std::fs::read_to_string(&files.config_file).unwrap();
    let (base, server) = stub(409, r#"{"_tag":"Conflict","message":"nonce already used"}"#);
    let output = run_rotate(&files, &base, &[("CMUX_VM_API_KEY", "k")]);
    server.join().unwrap();
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "Conflict");
    assert_eq!(error["status"], 409);
    assert_eq!(std::fs::read_to_string(&files.config_file).unwrap(), config_before);
    assert_eq!(std::fs::read_to_string(&files.key_file).unwrap(), files.old_key_text);
}

#[test]
fn rotate_requires_its_arguments() {
    let dir = TempDir::new();
    let files = rotate_files(&dir);
    let args = rotate_args(&files, "http://127.0.0.1:1");
    for flag in ["--config", "--key-file", "--install-key", "--new-key-file"] {
        let index = args.iter().position(|arg| arg == flag).unwrap();
        let mut without: Vec<&str> = args.iter().map(String::as_str).collect();
        without.drain(index..index + 2);
        let output = agent(&without, &[("CMUX_VM_API_KEY", "k")]);
        assert_eq!(output.status.code(), Some(2), "{flag}: {output:?}");
        assert!(String::from_utf8_lossy(&output.stderr).contains(flag), "{flag}");
    }
    assert!(!files.new_key_file.exists());
}

#[test]
fn rotate_refuses_a_key_file_that_is_not_the_enrolled_key() {
    let dir = TempDir::new();
    let files = rotate_files(&dir);
    std::fs::write(&files.config_file, enrolled_config(SERVER_KEY)).unwrap();
    let output = run_rotate(&files, "http://127.0.0.1:1", &[("CMUX_VM_API_KEY", "k")]);
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "KeyMismatch");
    assert!(!files.new_key_file.exists());
}

// --- M3 (cx-0op.5): device-signed requests, no credential ---

const PEERS: &str = r#"{"deviceId":"dev_1","meshId":"mesh_abc","aclVersion":2,"peers":[{"kind":"vm","id":"vm_a","address":"10.128.16.5","allow":[{"protocol":"icmp"}]}]}"#;

/// A saved enrollment plus an install key, as a code-enrolled device has.
fn signed_files(dir: &TempDir) -> (PathBuf, PathBuf, String) {
    let config_file = dir.path("config.json");
    let install_file = dir.path("install.key");
    std::fs::write(&config_file, ENROLLED).unwrap();
    let install_public = install::install_keygen(&install_file).unwrap();
    (config_file, install_file, install_public)
}

/// The body carries only the signature fields: no key, no code, no name.
fn assert_only_signature_fields(sent: &serde_json::Value) {
    let mut keys: Vec<&str> = sent.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["nonce", "signature", "signedAt"]);
}

#[test]
fn peers_without_an_api_key_signs_with_the_install_key() {
    let dir = TempDir::new();
    let (config_file, install_file, install_public) = signed_files(&dir);
    let (base, server) = stub(200, PEERS);
    let output = agent(
        &[
            "peers",
            "--config",
            config_file.to_str().unwrap(),
            "--install-key",
            install_file.to_str().unwrap(),
        ],
        &[("CMUX_VM_API_URL", &base)],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/devices/dev_1/signed/peers HTTP/1.1");
    assert_eq!(request.header("authorization"), None);
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_only_signature_fields(&sent);
    assert_signed(&sent, "peers", "dev_1", "", &install_public, "");
    let printed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(printed["peers"][0]["id"], "vm_a");
    assert_no_private_key(
        &install_file,
        &[&output.stdout, &output.stderr, request.body.as_bytes()],
    );
}

#[test]
fn peers_with_an_api_key_still_uses_the_key() {
    let dir = TempDir::new();
    let (config_file, install_file, _) = signed_files(&dir);
    let (base, server) = stub(200, PEERS);
    let output = agent(
        &[
            "peers",
            "--config",
            config_file.to_str().unwrap(),
            "--install-key",
            install_file.to_str().unwrap(),
        ],
        &[("CMUX_VM_API_URL", &base), ("CMUX_VM_API_KEY", "cmux_test_key")],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "GET /v1/devices/dev_1/peers HTTP/1.1");
    assert_eq!(request.header("authorization"), Some("Bearer cmux_test_key"));
}

#[test]
fn peers_without_any_credential_fails_before_any_request() {
    let dir = TempDir::new();
    let (config_file, _, _) = signed_files(&dir);
    // Nothing listens on port 1: a request would fail as Transport.
    let output = agent(
        &["peers", "--config", config_file.to_str().unwrap(), "--api", "http://127.0.0.1:1"],
        &[],
    );
    assert!(!output.status.success());
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"], "MissingCredential");
}

#[test]
fn tunnel_without_an_api_key_signs_and_prints_the_config() {
    let dir = TempDir::new();
    let (config_file, install_file, install_public) = signed_files(&dir);
    let tunnel = rotated_tunnel();
    let (base, server) = stub(200, Box::leak(tunnel.into_boxed_str()));
    let output = agent(
        &[
            "tunnel",
            "--config",
            config_file.to_str().unwrap(),
            "--install-key",
            install_file.to_str().unwrap(),
            "--api",
            &base,
        ],
        &[],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/devices/dev_1/signed/tunnel HTTP/1.1");
    assert_eq!(request.header("authorization"), None);
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_only_signature_fields(&sent);
    assert_signed(&sent, "tunnel", "dev_1", "", &install_public, "");
    let printed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(printed["id"], "tun_1");
    assert_eq!(printed["serverPublicKey"], NEW_SERVER_KEY);
    // A read changes nothing on disk.
    assert_eq!(std::fs::read_to_string(&config_file).unwrap(), ENROLLED);
}

#[test]
fn tunnel_with_an_api_key_gets_the_tunnel_by_id() {
    let dir = TempDir::new();
    let (config_file, _, _) = signed_files(&dir);
    let tunnel = rotated_tunnel();
    let (base, server) = stub(200, Box::leak(tunnel.into_boxed_str()));
    let output = agent(
        &["tunnel", "--config", config_file.to_str().unwrap(), "--api", &base],
        &[("CMUX_VM_API_KEY", "cmux_test_key")],
    );
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "GET /v1/tunnels/tun_1 HTTP/1.1");
    assert_eq!(request.header("authorization"), Some("Bearer cmux_test_key"));
}

#[test]
fn rotate_without_an_api_key_posts_the_signed_route() {
    let dir = TempDir::new();
    let files = rotate_files(&dir);
    let tunnel = rotated_tunnel();
    let (base, server) = stub(200, Box::leak(tunnel.into_boxed_str()));
    let output = run_rotate(&files, &base, &[]);
    let request = server.join().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(request.line, "POST /v1/devices/dev_1/signed/rotate-key HTTP/1.1");
    assert_eq!(request.header("authorization"), None);
    let new_public = key::read_key_file(&files.new_key_file).unwrap().public_key_base64();
    let sent: serde_json::Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(sent["newPublicKey"], new_public);
    assert_signed(&sent, "rotate-key", "dev_1", &new_public, &files.install_public, "");
    let saved = cmux_mesh_agent::config::load(&files.config_file).unwrap();
    assert_eq!(STANDARD.encode(saved.tunnel.server_public_key), NEW_SERVER_KEY);
    assert_eq!(saved.wg_public_key.as_deref(), Some(new_public.as_str()));
}
