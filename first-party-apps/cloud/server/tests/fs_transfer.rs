//! `cloud.file.push` and `cloud.file.pull`: a fresh in-memory key per
//! transfer, the host key pinned from the endpoint answer, and no key text in
//! argv, logs or errors. No network: the transfer is a fake, or the real one
//! with binaries that do not exist.

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::fs::{
    Direction, OpenSshTransfer, ScpEndpoint, Transfer, TransferJob, TransferKey, scp_args,
};
use cmux_cloud::{Origin, Request};
use edge_common::rig;
use serde_json::json;
use std::path::{Path, PathBuf};

const FIXTURES: &[&str] = &["vm-get", "attach_endpoint_alpha", "scp-endpoint"];

fn scratch_file(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-cloud-test-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("upload.txt");
    std::fs::write(&file, b"payload").unwrap();
    file
}

fn push(local: &Path, key: &str) -> Request {
    Request::new(
        "cloud.file.push",
        json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/upload.txt"}),
    )
    .key(key)
}

/// Every form of the private key that could leak.
fn secrets(key: &TransferKey) -> Vec<String> {
    let text = key.private_openssh();
    let body: String = text.lines().filter(|l| !l.starts_with("-----")).collect();
    let mut out = vec![text.to_string(), body];
    out.extend(text.lines().filter(|l| !l.starts_with("-----") && l.len() > 16).map(str::to_owned));
    out
}

#[test]
fn each_push_uses_a_fresh_key_and_sends_only_its_public_half() {
    let local = scratch_file("fresh");
    let mut rig = rig(FIXTURES);
    rig.server.handle(&push(&local, "p-1")).expect("first push");
    rig.server.handle(&push(&local, "p-2")).expect("second push");
    let log = rig.transfer.log();
    assert_eq!(log.public_keys.len(), 2);
    assert_ne!(log.public_keys[0], log.public_keys[1], "a new key per transfer");
    let bodies: Vec<String> = rig
        .server
        .control_plane()
        .calls
        .iter()
        .filter(|c| c.path == "/api/vm/vm-alpha01/scp-endpoint")
        .map(|c| c.body.as_ref().unwrap()["publicKey"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        bodies, log.public_keys,
        "the endpoint authorized exactly the key the transfer used"
    );
    for call in &rig.server.control_plane().calls {
        if call.path.ends_with("/scp-endpoint") {
            assert_eq!(call.idempotency_key, None, "a retry must authorize its own key");
            let body = call.body.as_ref().unwrap().as_object().unwrap();
            assert_eq!(body.keys().collect::<Vec<_>>(), ["publicKey"]);
        }
    }
    let job = &log.jobs[0];
    assert_eq!(job.direction, Direction::Push);
    assert_eq!(job.guest, "/home/cmux/upload.txt");
    assert_eq!(job.route.ip().to_string(), "127.0.0.1", "the guest SSH port rides the link");
    assert!(
        job.endpoint.host_public_key.starts_with("ssh-ed25519 "),
        "host key pinned from the answer"
    );
    let opened = rig.tunnel.log().opened.clone();
    assert!(opened.is_empty() || opened.iter().all(|o| o.port == 22 && o.host == "localhost"));
}

#[test]
fn the_key_is_never_in_argv_debug_or_errors() {
    let key = TransferKey::generate().unwrap();
    let debug = format!("{key:?}");
    let endpoint = ScpEndpoint {
        host: "10.200.0.2".into(),
        port: 22,
        username: "cmux".into(),
        host_public_key:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER"
                .into(),
        expires_at_unix: 4_102_444_800,
    };
    let job = TransferJob {
        machine: "vm-alpha01".into(),
        direction: Direction::Pull,
        local: "/tmp/cmux-test/out.txt".into(),
        guest: "/home/cmux/notes.txt".into(),
        endpoint,
        route: "127.0.0.1:40022".parse().unwrap(),
    };
    let argv =
        scp_args(&job, Path::new("/tmp/x/agent.sock"), Path::new("/tmp/x/known_hosts")).join(" ");
    assert!(argv.contains("StrictHostKeyChecking=yes") && argv.contains("HostKeyAlias=cmux-scp"));
    assert!(argv.contains("cmux@127.0.0.1:/home/cmux/notes.txt") && argv.contains(" -- "));
    assert!(!argv.contains(" -i "), "no identity file");
    // The real transfer with missing binaries fails on its real error path.
    let mut real = OpenSshTransfer {
        ssh_agent: "/nonexistent/ssh-agent".into(),
        ssh_add: "/nonexistent/ssh-add".into(),
        scp: "/nonexistent/scp".into(),
    };
    let error = real.run(&job, &key).unwrap_err();
    for secret in secrets(&key) {
        assert!(!argv.contains(&secret), "argv");
        assert!(!debug.contains(&secret), "Debug");
        assert!(!error.message.contains(&secret), "error");
    }
    assert!(debug.contains("<redacted>") && debug.contains(&key.public_openssh()));
}

#[test]
fn the_private_key_text_is_a_valid_openssh_container_for_its_public_key() {
    use base64::Engine as _;
    let key = TransferKey::generate().unwrap();
    let text = key.private_openssh();
    assert!(text.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----\n"));
    let body: String = text.lines().filter(|l| !l.starts_with("-----")).collect();
    let raw = base64::engine::general_purpose::STANDARD.decode(body).unwrap();
    assert!(raw.starts_with(b"openssh-key-v1\0"));
    let public = key.public_openssh();
    let blob =
        base64::engine::general_purpose::STANDARD.decode(&public["ssh-ed25519 ".len()..]).unwrap();
    assert!(raw.windows(blob.len()).any(|w| w == blob.as_slice()), "public blob inside");
    assert_ne!(TransferKey::generate().unwrap().public_openssh(), public);
}

#[test]
fn a_failed_transfer_is_a_typed_error_and_endpoint_answers_are_checked() {
    let local = scratch_file("fail");
    let mut rig = rig(FIXTURES);
    rig.transfer.log().fail_with = Some("scp failed: connection closed".into());
    let err = rig.server.handle(&push(&local, "p-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.transfer_failed");
    let mut bad = common::FakeControlPlane::fixture_body("scp-endpoint");
    bad["hostPublicKey"] = json!("ssh-rsa AAAAB3NzaC1yc2E");
    rig.server.control_plane_mut().respond("POST", "/api/vm/vm-alpha01/scp-endpoint", 200, bad);
    let err = rig.server.handle(&push(&local, "p-2")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.bad_response", "only one Ed25519 host key is accepted");
    let mut expired = common::FakeControlPlane::fixture_body("scp-endpoint");
    expired["expiresAtUnix"] = json!(1);
    assert!(ScpEndpoint::decode(expired, 1_791_100_000).is_err());
}

#[test]
fn local_paths_are_checked_and_pull_never_overwrites() {
    let local = scratch_file("local");
    let mut rig = rig(FIXTURES);
    let pull = |path: &str| {
        Request::new(
            "cloud.file.pull",
            json!({"machine": "vm-alpha01", "localPath": path, "path": "/home/cmux/notes.txt"}),
        )
        .key(&format!("l-{path:?}"))
        .origin(Origin::Cli)
    };
    let err = rig.server.handle(&pull(local.to_str().unwrap())).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.local_exists");
    for bad in ["relative.txt", "/tmp/../etc/passwd", "/tmp/a\0b", "/tmp/dir/"] {
        assert_eq!(
            rig.server.handle(&pull(bad)).unwrap_err().code,
            "cmux.cloud.invalid_args",
            "{bad:?}"
        );
    }
    let glob = Request::new(
        "cloud.file.push",
        json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/*.txt"}),
    )
    .key("g-1");
    assert_eq!(rig.server.handle(&glob).unwrap_err().code, "cmux.cloud.invalid_args");
    assert!(rig.transfer.log().jobs.is_empty());
    assert!(rig.server.control_plane().calls.is_empty(), "refused before any Cloud API call");
}
