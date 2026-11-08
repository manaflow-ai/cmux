use std::io::{BufRead, BufReader};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::UnixListener;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::dial::Service;
use cmux_link::token::{Expected, TokenRefused, TokenVerifier};
use serde_json::{Value, json};

use super::*;
use crate::cloud::receiver_read_tests::public_fixture;
use cmux_link::native_token::MAX_POLICY_LEASE_MS;

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
    development_token_for(None)
}

fn development_token_for(generation: Option<&str>) -> String {
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
    if let Some(generation) = generation {
        claims["receiver"] = json!({"version":2,"generation":generation});
    }
    let typ = if generation.is_some() { "cmux-native-link-v2+jwt" } else { "cmux-link+jwt" };
    let head = URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(&json!({"alg":"EdDSA","typ":typ,"kid":"test-k1"})).unwrap());
    let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let signed = format!("{head}.{body}");
    format!("{signed}.{}", URL_SAFE_NO_PAD.encode(key.sign(signed.as_bytes()).as_ref()))
}

#[test]
fn receiver_owner_agent_generation_is_pinned_and_changed_policy_drains_streams() {
    let (binding, keys, bytes) = public_fixture();
    let generation = "a".repeat(64);
    let receiver = AgentReceiver::for_receiver(binding.clone(), keys, generation.clone()).unwrap();
    let verifier = receiver.verifier();
    let expected = Expected {
        host: &binding.host,
        epoch: binding.epoch,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    let (_dir, path, task) = server([bytes.clone(), b"\n".to_vec()].concat());
    receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).unwrap();
    task.join().unwrap();
    assert!(verifier.verify(&development_token(), &expected).is_err());
    let token = development_token_for(Some(&generation));
    let lease = verifier.verify(&token, &expected).unwrap().lease.unwrap();
    let mut changed: Value = serde_json::from_slice(&bytes).unwrap();
    changed["value"]["policy"]["receiver_generation"] = "b".repeat(64).into();
    let (_dir, path, task) =
        server([serde_json::to_vec(&changed).unwrap(), b"\n".to_vec()].concat());
    assert!(receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).is_err());
    task.join().unwrap();
    assert!(lease.deadline().is_none(), "changed generation retained an admitted stream");
    assert!(verifier.verify(&token, &expected).is_err());
    assert!(receiver.is_retired());
    assert!(receiver.prepare_refresh().is_err(), "old generation retried after retirement");
}

#[test]
fn receiver_owner_agent_generation_refuses_closed_or_missing_policy_generation() {
    for missing in [false, true] {
        let (binding, keys, bytes) = public_fixture();
        let receiver = AgentReceiver::for_receiver(binding, keys, "a".repeat(64)).unwrap();
        let mut body: Value = serde_json::from_slice(&bytes).unwrap();
        body["value"]["policy"]["receiver_generation"] = Value::Null;
        if missing {
            body["value"]["policy"].as_object_mut().unwrap().remove("receiver_generation");
        }
        let (_dir, path, task) =
            server([serde_json::to_vec(&body).unwrap(), b"\n".to_vec()].concat());
        assert!(receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).is_err());
        task.join().unwrap();
        assert_eq!(receiver.is_retired(), !missing, "only a valid closed policy retires a pin");
    }
}

#[test]
fn receiver_owner_agent_stale_generation_mismatch_cannot_retire_newer_authority() {
    let (binding, keys, bytes) = public_fixture();
    let generation = "a".repeat(64);
    let receiver = AgentReceiver::for_receiver(binding.clone(), keys, generation.clone()).unwrap();
    let older = receiver.prepare_refresh().unwrap();
    let newer = receiver.prepare_refresh().unwrap();
    let (_dir, path, task) = server([bytes.clone(), b"\n".to_vec()].concat());
    receiver.refresh_at_prepared(&path, test_uid(), false, Duration::from_secs(2), newer).unwrap();
    task.join().unwrap();
    let mut changed: Value = serde_json::from_slice(&bytes).unwrap();
    changed["value"]["policy"]["receiver_generation"] = "b".repeat(64).into();
    let (_dir, path, task) =
        server([serde_json::to_vec(&changed).unwrap(), b"\n".to_vec()].concat());
    assert!(
        receiver
            .refresh_at_prepared(&path, test_uid(), false, Duration::from_secs(2), older)
            .is_err()
    );
    task.join().unwrap();
    assert!(!receiver.is_retired(), "stale response retired a newer read");
    let expected = Expected {
        host: &binding.host,
        epoch: binding.epoch,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    assert!(
        receiver.verifier().verify(&development_token_for(Some(&generation)), &expected).is_ok()
    );
    assert!(receiver.prepare_refresh().is_ok());
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
fn receiver_owner_queued_read_debits_suspend_before_connecting_to_the_agent() {
    use cmux_link::elapsed::Elapsed;
    use std::sync::{Arc, Mutex};
    let (binding, keys, bytes) = public_fixture();
    let value = Arc::new(Mutex::new(Some(Duration::from_secs(10))));
    let source = value.clone();
    let elapsed = Elapsed::capture(move || *source.lock().unwrap()).unwrap();
    let receiver = AgentReceiver {
        binding,
        owner: Owner::with_elapsed_clock(keys, || Some(Instant::now()), elapsed).unwrap(),
        generation: None,
    };
    let (_dir, path, task) = server([bytes, b"\n".to_vec()].concat());
    receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).unwrap();
    task.join().unwrap();
    let queued = receiver.prepare_refresh().unwrap();
    *value.lock().unwrap() = Some(Duration::from_secs(31));
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent.sock");
    let listener = UnixListener::bind(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o660)).unwrap();
    listener.set_nonblocking(true).unwrap();
    assert!(
        receiver.refresh_at_prepared(&path, test_uid(), false, REQUEST_BUDGET, queued).is_err()
    );
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock,
        "expired queued work reached the authenticated source"
    );
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

/// A token like the fixture's, with its own single-use id.
fn development_token_with_jti(jti: u8) -> String {
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
    claims["jti"] = URL_SAFE_NO_PAD.encode([jti; 16]).into();
    let head = URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&json!({"alg":"EdDSA","typ":"cmux-link+jwt","kid":"test-k1"})).unwrap(),
    );
    let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let signed = format!("{head}.{body}");
    format!("{signed}.{}", URL_SAFE_NO_PAD.encode(key.sign(signed.as_bytes()).as_ref()))
}

/// The public fixture reply with local admission granted for ten minutes.
fn admitting_reply() -> (ReceiverBinding, Keyset, Vec<u8>) {
    let (binding, keys, bytes) = public_fixture();
    let mut body: Value = serde_json::from_slice(&bytes).unwrap();
    let checked = body["value"]["policy"]["checked_at"].as_i64().unwrap();
    body["value"]["policy"]["admit_until"] = (checked + 600_000).into();
    (binding, keys, [serde_json::to_vec(&body).unwrap(), b"\n".to_vec()].concat())
}

fn admitted_stream(
    receiver: &AgentReceiver,
    binding: &ReceiverBinding,
    reply: Vec<u8>,
) -> cmux_link::stream_lease::StreamLease {
    let (_dir, path, task) = server(reply);
    receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2)).unwrap();
    task.join().unwrap();
    let expected = Expected {
        host: &binding.host,
        epoch: binding.epoch,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    receiver.verifier().verify(&development_token(), &expected).unwrap().lease.unwrap()
}

#[test]
fn receiver_owner_agent_refusal_clears_existing_authority() {
    for refused in [
        b"{\"ok\":false,\"error\":\"cloud.vm.network_policy.refused\"}\n".to_vec(),
        b"{\"ok\":false,\"error\":\"something else\"}\n".to_vec(),
        b"{\"ok\":true}\n".to_vec(),
        // An answered reply that is too large, or more than one line, is malformed.
        [vec![b' '; 1024 * 1024 + 2], b"\n".to_vec()].concat(),
        b"{}\n{}\n".to_vec(),
    ] {
        let (binding, keys, reply) = admitting_reply();
        let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
        let lease = admitted_stream(&receiver, &binding, reply);
        let (_dir, path, task) = server(refused.clone());
        let error = receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2));
        task.join().unwrap();
        assert!(
            error.is_err_and(|e| is_refusal(&e)),
            "{}",
            String::from_utf8_lossy(&refused[..refused.len().min(80)])
        );
        assert!(lease.deadline().is_none(), "a refusal kept an admitted stream");
    }
}

/// Control plane down or slow: the read gets no answer. The agent level keeps
/// current authority (its owner decides, see native_process), so an admitted
/// stream stays up and a new signed token is still admitted locally.
#[test]
fn receiver_owner_agent_no_answer_keeps_admitted_streams_and_admits_new_ones() {
    let (binding, keys, reply) = admitting_reply();
    let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
    let lease = admitted_stream(&receiver, &binding, reply);
    let deadline = lease.deadline();
    for unanswered in [
        b"{\"ok\":false,\"error\":\"cloud.vm.network_policy.unavailable\"}\n".to_vec(),
        // The agent closed without a word (it timed out its own Cloud read).
        Vec::new(),
    ] {
        let (_dir, path, task) = server(unanswered);
        let error = receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2));
        task.join().unwrap();
        assert!(error.is_err_and(|e| !is_refusal(&e)));
        assert_eq!(lease.deadline(), deadline, "no answer ended an admitted stream");
    }
    // The agent socket gone (the host agent restarting) is no answer too.
    let gone = tempfile::tempdir().unwrap();
    let error = receiver.refresh_at(
        &gone.path().join("agent.sock"),
        test_uid(),
        false,
        Duration::from_secs(2),
    );
    assert!(error.is_err_and(|e| !is_refusal(&e)));
    assert_eq!(lease.deadline(), deadline);
    let expected = Expected {
        host: &binding.host,
        epoch: binding.epoch,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    assert!(
        receiver.verifier().verify(&development_token_with_jti(9), &expected).is_ok(),
        "a new stream was not admitted locally while the control plane was down"
    );
}

/// Local admission runs the verifier's authority to admit_until, not to the
/// renewal lease; without the field (the kill switch) it ends at the lease.
#[test]
fn receiver_owner_agent_admission_window_comes_from_admit_until() {
    let (binding, keys, reply) = admitting_reply();
    let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
    let admitted = admitted_stream(&receiver, &binding, reply);
    let (binding, keys, mut plain) = public_fixture();
    plain.push(b'\n');
    let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
    let leased = admitted_stream(&receiver, &binding, plain);
    let (admitted, leased) = (admitted.deadline().unwrap(), leased.deadline().unwrap());
    assert!(admitted > leased + Duration::from_secs(400), "admit_until did not extend authority");
    assert!(leased < Instant::now() + Duration::from_secs(MAX_POLICY_LEASE_MS / 1000 + 1));
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

/// An answered policy whose keyset or budget is malformed refuses: it must
/// revoke a retained admission, never ride on it.
#[test]
fn receiver_owner_agent_malformed_keyset_or_budget_revokes_admission() {
    for (field, value) in [
        ("keyset", json!({"version":"bad","keys":{}})),
        ("remaining_ms", json!(0)),
        ("remaining_ms", json!(u64::MAX / 2)),
    ] {
        let (binding, keys, reply) = admitting_reply();
        let receiver = AgentReceiver::new(binding.clone(), keys).unwrap();
        let lease = admitted_stream(&receiver, &binding, reply.clone());
        let mut bad: Value = serde_json::from_slice(&reply[..reply.len() - 1]).unwrap();
        bad["value"][field] = value;
        let (_dir, path, task) =
            server([serde_json::to_vec(&bad).unwrap(), b"\n".to_vec()].concat());
        let error = receiver.refresh_at(&path, test_uid(), false, Duration::from_secs(2));
        task.join().unwrap();
        assert!(error.is_err_and(|e| is_refusal(&e)), "{field}");
        assert!(lease.deadline().is_none(), "a malformed {field} kept an admitted stream");
    }
}
