use std::io::{BufRead, BufReader};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::UnixListener;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::dial::Service;
use cmux_link::token::{Expected, TokenRefused, TokenVerifier};
use serde_json::{Value, json};

use super::*;
use crate::cloud::receiver_read_tests::public_fixture;

fn test_uid() -> u32 {
    // SAFETY: geteuid has no parameters or memory preconditions.
    unsafe { libc::geteuid() }
}

fn server(
    response: Vec<u8>,
) -> (tempfile::TempDir, std::path::PathBuf, std::thread::JoinHandle<()>) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent.sock");
    let listener = UnixListener::bind(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o660)).unwrap();
    let task = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut stream = BufReader::new(stream);
        let mut request = String::new();
        stream.read_line(&mut request).unwrap();
        assert_eq!(request, "{\"op\":\"cloud.vm.network_policy\"}\n");
        let _ = stream.get_mut().write_all(&response);
    });
    (dir, path, task)
}

/// TEST ONLY key material already published in the shared contract vectors.
/// No deployment key or machine credential is used by this signer.
fn development_token() -> String {
    let f: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    let vectors: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/vectors.json"))
            .unwrap();
    let seed =
        URL_SAFE_NO_PAD.decode(vectors["test_keys"]["test-k1"]["d"].as_str().unwrap()).unwrap();
    let key = ring::signature::Ed25519KeyPair::from_seed_unchecked(&seed).unwrap();
    let mut claims = f["claims"].clone();
    claims["iss"] = "cmux:cloud:development".into();
    let head = URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&json!({"alg":"EdDSA","typ":"cmux-link+jwt","kid":"test-k1"})).unwrap(),
    );
    let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let signed = format!("{head}.{body}");
    format!("{signed}.{}", URL_SAFE_NO_PAD.encode(key.sign(signed.as_bytes()).as_ref()))
}

#[test]
fn receiver_owner_agent_socket_installs_pinned_policy_and_verifies_real_signature() {
    let (binding, keys, mut reply) = public_fixture();
    reply.push(b'\n');
    let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
    let verifier = receiver.verifier();
    let (_dir, path, task) = server(reply);
    receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).unwrap();
    task.join().unwrap();
    let expected = Expected {
        host: &binding.host,
        epoch: binding.epoch,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    let token = development_token();
    let verified = verifier.verify(&token, &expected).unwrap();
    assert_eq!(verified.issued_at_ms, 1_792_000_000_000);
    assert_eq!(verifier.verify(&token, &expected), Err(TokenRefused::Replayed));
    let lease = verified.lease.unwrap();
    drop(receiver);
    assert!(lease.deadline().is_none(), "retained readers survived their owner");
}

#[test]
fn receiver_owner_prepared_socket_read_cannot_reopen_after_cancellation_before_io_starts() {
    for cancelled in [true, false] {
        let (binding, keys, mut reply) = public_fixture();
        reply.push(b'\n');
        let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
        let prepared = receiver.prepare_refresh().unwrap();
        if cancelled {
            receiver.invalidate();
        }
        let (_dir, path, task) = server(reply);
        let result = receiver.refresh_at_prepared(
            &path,
            test_uid(),
            false,
            Duration::from_secs(2),
            prepared,
        );
        task.join().unwrap();
        assert_eq!(result.is_ok(), !cancelled);
        let expected = Expected {
            host: &binding.host,
            epoch: binding.epoch,
            service: Service::Daemon,
            peer_key: &[b'a'; 32],
        };
        assert_eq!(receiver.verifier().verify(&development_token(), &expected).is_ok(), !cancelled);
    }
}

#[test]
fn receiver_owner_agent_socket_checks_kernel_peer_uid() {
    let (a, b) = UnixStream::pair().unwrap();
    assert!(check_peer(&a, test_uid()).is_ok());
    assert!(check_peer(&b, test_uid().saturating_add(1)).is_err());
}

#[test]
fn receiver_owner_agent_socket_refuses_unprotected_directory_and_symlink() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent.sock");
    let _listener = UnixListener::bind(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o660)).unwrap();
    assert!(check_path(&path, test_uid(), false).is_ok());
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o777)).unwrap();
    assert!(check_path(&path, test_uid(), false).is_err());
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let link = dir.path().join("other.sock");
    symlink(&path, &link).unwrap();
    assert!(check_path(&link, test_uid(), false).is_err());
}

#[test]
fn receiver_owner_agent_refusal_clears_existing_authority() {
    let (binding, keys, mut reply) = public_fixture();
    reply.push(b'\n');
    let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
    let verifier = receiver.verifier();
    let (_dir, path, task) = server(reply);
    receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).unwrap();
    task.join().unwrap();
    let expected = Expected {
        host: &binding.host,
        epoch: binding.epoch,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    let lease = verifier.verify(&development_token(), &expected).unwrap().lease.unwrap();
    let (_dir, path, task) =
        server(b"{\"ok\":false,\"error\":\"cloud.vm.network_policy.unavailable\"}\n".to_vec());
    assert!(receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).is_err());
    task.join().unwrap();
    assert!(lease.deadline().is_none());
}

#[test]
fn receiver_owner_agent_response_body_and_deadline_are_bounded() {
    let (binding, keys, _) = public_fixture();
    let receiver = AgentReceiver::new(binding, keys).unwrap();
    let (_dir, path, task) = server(vec![b'x'; 1024 * 1024 + 1]);
    assert!(receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).is_err());
    task.join().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent.sock");
    let listener = UnixListener::bind(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o660)).unwrap();
    let (release, held) = std::sync::mpsc::channel::<()>();
    let task = std::thread::spawn(move || {
        let (_stream, _) = listener.accept().unwrap();
        let _ = held.recv_timeout(Duration::from_secs(2));
    });
    let started = Instant::now();
    assert!(receiver.refresh_at(&path, test_uid(), false, Duration::from_millis(100)).is_err());
    let _ = release.send(());
    task.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(1));
}
