use super::*;
use std::time::Duration;

mod generation;

const HEADER: &str = r#"{"alg":"EdDSA","kid":"test-k1","typ":"cmux-link+jwt"}"#;

fn sign_bytes(claims: &[u8], header: &str) -> String {
    let v: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/vectors.json"))
            .unwrap();
    let k = &v["test_keys"]["test-k1"];
    let signer = ring::signature::Ed25519KeyPair::from_seed_and_public_key(
        &URL_SAFE_NO_PAD.decode(k["d"].as_str().unwrap()).unwrap(),
        &URL_SAFE_NO_PAD.decode(k["x"].as_str().unwrap()).unwrap(),
    )
    .unwrap();
    let message = format!("{}.{}", URL_SAFE_NO_PAD.encode(header), URL_SAFE_NO_PAD.encode(claims));
    format!("{message}.{}", URL_SAFE_NO_PAD.encode(signer.sign(message.as_bytes()).as_ref()))
}

fn signed(claims: &Value) -> String {
    sign_bytes(&serde_json::to_vec(claims).unwrap(), HEADER)
}

#[test]
fn native_token_receiver_refuses_every_mismatched_signed_authority_field() {
    let f = fixture();
    for field in [
        "version",
        "tenant",
        "mesh",
        "device",
        "host",
        "user",
        "wg_public_key",
        "authority_version",
        "acl_version",
    ] {
        let mut c = f["claims"].clone();
        c["network"][field] = match field {
            "version" | "acl_version" => serde_json::json!(2),
            "tenant" => serde_json::json!("team_other"),
            "mesh" => serde_json::json!("mesh_11111111111111111111111111"),
            "device" => serde_json::json!("dev_11111111111111111111111111"),
            "host" => serde_json::json!("host_00000000000000000003"),
            "user" => serde_json::json!("user_00000000000000000003"),
            "wg_public_key" => {
                serde_json::json!(base64::engine::general_purpose::STANDARD.encode([7; 32]))
            }
            "authority_version" => serde_json::json!("b".repeat(64)),
            _ => unreachable!(),
        };
        let verifier = receiver();
        assert!(verifier.verify(&signed(&c), &expected(Service::Daemon)).is_err(), "{field}");
        assert!(
            verifier.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)).is_ok(),
            "refusal must not spend jti: {field}"
        );
    }
    for (field, value) in [
        ("iss", serde_json::json!("cmux:cloud:other")),
        ("aud", serde_json::json!("host_00000000000000000003")),
        ("sub", serde_json::json!("inst_00000000000000000003")),
        ("team", serde_json::json!("team_00000000000000000003")),
        ("epoch", serde_json::json!(5)),
    ] {
        let mut c = f["claims"].clone();
        c[field] = value;
        assert!(receiver().verify(&signed(&c), &expected(Service::Daemon)).is_err(), "{field}");
    }
}

#[test]
fn native_token_receiver_refuses_invalid_time_services_and_jti() {
    let f = fixture();
    for (field, value) in [
        ("iat", serde_json::json!(0)),
        ("iat", serde_json::json!(1_792_000_011)),
        ("iat", serde_json::json!(1.5)),
        ("exp", serde_json::json!(1_792_000_301)),
        ("exp", serde_json::json!(1_792_000_000)),
        ("exp", serde_json::json!(9_007_199_254_740_992u64)),
        ("svc", serde_json::json!([])),
        ("svc", serde_json::json!(["daemon", "daemon"])),
        ("svc", serde_json::json!(["owner_session"])),
        ("jti", serde_json::json!("AAAAAAAAAAAAAAAAAAAAAB")),
        ("jti", serde_json::json!("")),
        ("jti", serde_json::json!("A".repeat(44))),
    ] {
        let mut c = f["claims"].clone();
        c[field] = value;
        assert!(
            receiver().verify(&signed(&c), &expected(Service::Daemon)).is_err(),
            "{field}: {}",
            c[field]
        );
    }
    let mut c = f["claims"].clone();
    c["iat"] = serde_json::json!(1_791_999_710);
    c["exp"] = serde_json::json!(1_792_000_010);
    assert_eq!(
        receiver().verify(&signed(&c), &expected(Service::Daemon)),
        Err(TokenRefused::Expired)
    );
}

#[test]
fn native_token_receiver_requires_both_signed_and_current_service_grants() {
    let f = fixture();
    let mut c = f["claims"].clone();
    c["svc"] = serde_json::json!(["ssh"]);
    assert_eq!(
        receiver().verify(&signed(&c), &expected(Service::Daemon)),
        Err(TokenRefused::ServiceNotAllowed)
    );
    let (v, t) = configured();
    {
        let mut now = t.lock().unwrap();
        now.unix_ms += 1;
        now.monotonic += Duration::from_millis(1);
    }
    let mut p = policy(&f, snapshot(&t));
    p.peers[0].services = vec![Service::Ssh];
    v.replace_authority(p).unwrap();
    assert_eq!(
        v.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)),
        Err(TokenRefused::ServiceNotAllowed)
    );
    assert!(v.verify(f["token"].as_str().unwrap(), &expected(Service::Ssh)).is_ok());
    assert!(
        receiver().verify(f["token"].as_str().unwrap(), &expected(Service::OwnerSession)).is_err()
    );
}

#[test]
fn native_token_receiver_refuses_altered_signatures_headers_padding_and_oversize() {
    let f = fixture();
    let token = f["token"].as_str().unwrap();
    for header in [
        r#"{"alg":"none","kid":"test-k1","typ":"cmux-link+jwt"}"#,
        r#"{"alg":"EdDSA","kid":"test-k1","typ":"JWT"}"#,
        r#"{"alg":"EdDSA","kid":"test-k1","typ":"cmux-link+jwt","crit":["other"]}"#,
        r#"{"alg":"EdDSA","kid":"test-k1","kid":"test-k1","typ":"cmux-link+jwt"}"#,
    ] {
        assert!(
            receiver()
                .verify(
                    &sign_bytes(&serde_json::to_vec(&f["claims"]).unwrap(), header),
                    &expected(Service::Daemon)
                )
                .is_err()
        );
    }
    let unknown = sign_bytes(
        &serde_json::to_vec(&f["claims"]).unwrap(),
        r#"{"alg":"EdDSA","kid":"test-other","typ":"cmux-link+jwt"}"#,
    );
    assert_eq!(
        receiver().verify(&unknown, &expected(Service::Daemon)),
        Err(TokenRefused::UnknownKey)
    );
    let mut parts: Vec<String> = token.split('.').map(String::from).collect();
    let mut sig = URL_SAFE_NO_PAD.decode(&parts[2]).unwrap();
    sig[0] ^= 1;
    parts[2] = URL_SAFE_NO_PAD.encode(sig);
    assert!(receiver().verify(&parts.join("."), &expected(Service::Daemon)).is_err());
    for index in 0..3 {
        let mut parts: Vec<String> = token.split('.').map(String::from).collect();
        parts[index].push('=');
        assert!(receiver().verify(&parts.join("."), &expected(Service::Daemon)).is_err());
    }
    for bad in ["x".repeat(8193), format!("{token}.extra"), "e30.e30.".into()] {
        assert!(receiver().verify(&bad, &expected(Service::Daemon)).is_err());
    }
}

#[test]
fn native_token_receiver_rejects_missing_extra_and_duplicate_signed_fields() {
    let f = fixture();
    for mode in ["missing", "extra", "duplicate_root", "duplicate_network"] {
        let mut c = f["claims"].clone();
        match mode {
            "missing" => {
                c.as_object_mut().unwrap().remove("network");
            }
            "extra" => {
                c["network"]["grant_id"] = serde_json::json!("untrusted");
            }
            _ => {}
        }
        let mut raw = serde_json::to_string(&c).unwrap();
        if mode == "duplicate_root" {
            raw = raw.replacen('{', "{\"sub\":\"inst_00000000000000000001\",", 1);
        }
        if mode == "duplicate_network" {
            raw = raw.replace("\"network\":{", "\"network\":{\"version\":1,");
        }
        assert!(
            receiver()
                .verify(&sign_bytes(raw.as_bytes(), HEADER), &expected(Service::Daemon))
                .is_err(),
            "{mode}"
        );
    }
}

#[test]
fn native_token_receiver_replay_survives_policy_key_refresh_and_revocation() {
    let f = fixture();
    let token = f["token"].as_str().unwrap();
    let (v, t) = configured();
    v.verify(token, &expected(Service::Daemon)).unwrap();
    let mut rotated = keys();
    let key = rotated.keys.remove("test-k1").unwrap();
    rotated.keys.insert("test-k2".into(), key);
    v.replace_keys(rotated).unwrap();
    assert_eq!(v.verify(token, &expected(Service::Daemon)), Err(TokenRefused::UnknownKey));
    v.replace_keys(keys()).unwrap();
    assert_eq!(v.verify(token, &expected(Service::Daemon)), Err(TokenRefused::Replayed));
    v.clear_authority();
    assert_eq!(v.verify(token, &expected(Service::Daemon)), Err(TokenRefused::NoVerifier));
    v.replace_keys(keys()).unwrap();
    {
        let mut now = t.lock().unwrap();
        now.unix_ms += 1;
        now.monotonic += Duration::from_millis(1);
    }
    v.replace_authority(policy(&f, snapshot(&t))).unwrap();
    assert_eq!(v.verify(token, &expected(Service::Ssh)), Err(TokenRefused::Replayed));
}

#[test]
fn native_token_receiver_concurrent_replay_has_exactly_one_winner() {
    let verifier = std::sync::Arc::new(configured().0);
    let token = fixture()["token"].as_str().unwrap().to_string();
    let threads: Vec<_> = (0..16)
        .map(|_| {
            let v = verifier.clone();
            let t = token.clone();
            std::thread::spawn(move || v.verify(&t, &expected(Service::Daemon)))
        })
        .collect();
    let results: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(results.iter().filter(|r| **r == Err(TokenRefused::Replayed)).count(), 15);
}

#[test]
fn native_token_receiver_lease_expires_on_either_clock_and_refuses_rollback() {
    let f = fixture();
    let token = f["token"].as_str().unwrap();
    for monotonic in [false, true] {
        let (v, t) = configured();
        {
            let mut now = t.lock().unwrap();
            if monotonic {
                now.monotonic += Duration::from_secs(30);
            } else {
                now.unix_ms += 30_000;
            }
        }
        assert_eq!(v.verify(token, &expected(Service::Daemon)), Err(TokenRefused::Expired));
    }
    let (v, t) = configured();
    t.lock().unwrap().unix_ms -= 1;
    assert_eq!(v.verify(token, &expected(Service::Daemon)), Err(TokenRefused::Invalid));
}

#[test]
fn native_token_receiver_refuses_ambiguous_stale_and_cross_mesh_snapshots() {
    let f = fixture();
    for mode in [
        "duplicate",
        "mesh",
        "acl",
        "same_host",
        "same_device",
        "same_key",
        "long_lease",
        "delayed",
        "future",
        "device",
        "key",
        "services",
    ] {
        let (v, t) = configured();
        {
            let mut now = t.lock().unwrap();
            now.unix_ms += 1;
            now.monotonic += Duration::from_millis(1);
        }
        let mut p = policy(&f, snapshot(&t));
        match mode {
            "duplicate" => p.peers.push(p.peers[0].clone()),
            "mesh" | "acl" | "same_host" | "same_device" | "same_key" => {
                let mut other = p.peers[0].clone();
                other.install = "inst_00000000000000000003".into();
                other.binding.host = "host_00000000000000000003".into();
                other.binding.device = "dev_11111111111111111111111111".into();
                other.binding.wg_public_key =
                    base64::engine::general_purpose::STANDARD.encode([2; 32]);
                match mode {
                    "mesh" => other.binding.mesh = "mesh_11111111111111111111111111".into(),
                    "acl" => other.binding.acl_version += 1,
                    "same_host" => other.binding.host = p.peers[0].binding.host.clone(),
                    "same_device" => other.binding.device = p.peers[0].binding.device.clone(),
                    "same_key" => {
                        other.binding.wg_public_key = p.peers[0].binding.wg_public_key.clone();
                    }
                    _ => unreachable!(),
                }
                p.peers.push(other);
            }
            "long_lease" => {
                p.expires_at_ms = p.checked_at_ms + cmux_link::native_token::MAX_ADMIT_MS + 1;
            }
            "delayed" => p.request_started -= Duration::from_secs(30),
            "future" => p.checked_at_ms += 1,
            "device" => p.peers[0].binding.device = "dev_invalid".into(),
            "key" => p.peers[0].binding.wg_public_key = "invalid".into(),
            "services" => p.peers[0].services = vec![Service::OwnerSession],
            _ => unreachable!(),
        }
        assert!(v.replace_authority(p).is_err(), "{mode}");
    }
}

#[test]
fn native_token_receiver_old_policy_response_cannot_restore_a_revoked_peer() {
    let f = fixture();
    let (v, t) = configured();
    let old = policy(&f, snapshot(&t));
    {
        let mut now = t.lock().unwrap();
        now.unix_ms += 1;
        now.monotonic += Duration::from_millis(1);
    }
    let mut revoked = policy(&f, snapshot(&t));
    revoked.peers.clear();
    v.replace_authority(revoked).unwrap();
    assert!(v.replace_authority(old).is_err());
    assert!(v.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)).is_err());
}

#[test]
fn native_token_receiver_full_replay_owner_never_evicts_a_live_id() {
    let f = fixture();
    let (v, t) = configured();
    let token = f["token"].as_str().unwrap();
    v.verify(token, &expected(Service::Daemon)).unwrap();
    let mut c = f["claims"].clone();
    c["jti"] = serde_json::json!(URL_SAFE_NO_PAD.encode([1; 16]));
    v.verify(&signed(&c), &expected(Service::Daemon)).unwrap();
    c["jti"] = serde_json::json!(URL_SAFE_NO_PAD.encode([2; 16]));
    assert_eq!(
        v.verify(&signed(&c), &expected(Service::Daemon)),
        Err(TokenRefused::ReplayCapacity)
    );
    assert_eq!(v.verify(token, &expected(Service::Daemon)), Err(TokenRefused::Replayed));
    {
        let mut now = t.lock().unwrap();
        now.unix_ms += 301_000;
        now.monotonic += Duration::from_secs(301);
    }
    v.replace_authority(policy(&f, snapshot(&t))).unwrap();
    c["iat"] = serde_json::json!(1_792_000_311);
    c["exp"] = serde_json::json!(1_792_000_611);
    assert!(v.verify(&signed(&c), &expected(Service::Daemon)).is_ok());
    t.lock().unwrap().unix_ms -= 301_000;
    assert!(
        v.verify(token, &expected(Service::Daemon)).is_err(),
        "clock rollback cannot revive a pruned jti"
    );
}

/// Local admission: a stream admitted under a policy whose authority runs to
/// its admission horizon keeps its lease to that horizon, not to a renewal
/// lease edge, and a newer policy without its peer still ends it at once.
#[test]
fn native_token_receiver_admission_window_holds_a_stream_until_revoked() {
    use cmux_link::native_token::MAX_ADMIT_MS;
    let f = fixture();
    let time = std::sync::Arc::new(std::sync::Mutex::new(cmux_link::native_token::ReceiverTime {
        unix_ms: 1_792_000_010_000,
        monotonic: std::time::Instant::now(),
    }));
    let clock = time.clone();
    let v = cmux_link::native_token::NativeTokenVerifier::new(
        keys(),
        move || Some(*clock.lock().unwrap()),
        2,
    )
    .unwrap();
    let mut long = policy(&f, snapshot(&time));
    long.expires_at_ms = long.checked_at_ms + MAX_ADMIT_MS;
    let started = long.request_started;
    v.replace_authority(long).unwrap();
    let lease =
        v.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)).unwrap().lease.unwrap();
    assert_eq!(lease.deadline(), Some(started + Duration::from_millis(MAX_ADMIT_MS)));
    {
        // Ten minutes on, well past any renewal lease: the stream is still admitted.
        let mut now = time.lock().unwrap();
        now.unix_ms += 600_000;
        now.monotonic += Duration::from_secs(600);
    }
    let mut revoked = policy(&f, snapshot(&time));
    revoked.expires_at_ms = revoked.checked_at_ms + MAX_ADMIT_MS;
    assert!(lease.deadline().is_some(), "the admission window ended at a lease edge");
    revoked.peers.clear();
    v.replace_authority(revoked).unwrap();
    assert_eq!(lease.deadline(), None, "a read without the peer did not revoke its stream");
}

#[test]
fn native_token_receiver_reports_a_newer_peer_binding_as_policy_behind_and_still_refuses() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let f = fixture();
    let (verifier, _clock) = configured();
    let behind = std::sync::Arc::new(AtomicUsize::new(0));
    let seen = behind.clone();
    verifier.on_policy_behind(move || {
        seen.fetch_add(1, Ordering::SeqCst);
    });
    // Minted against newer peer authority (an ACL bump or a renewed grant):
    // refused, and the owner is told its policy is behind.
    for (field, value) in [
        ("acl_version", serde_json::json!(2)),
        ("authority_version", serde_json::json!("b".repeat(64))),
    ] {
        let mut c = f["claims"].clone();
        c["network"][field] = value;
        assert_eq!(
            verifier.verify(&signed(&c), &expected(Service::Daemon)).err(),
            Some(TokenRefused::Invalid),
            "{field}"
        );
    }
    assert_eq!(behind.load(Ordering::SeqCst), 2);
    // Anything not signed for this receiver, host, epoch and team never says so.
    let mut c = f["claims"].clone();
    c["network"]["acl_version"] = serde_json::json!(2);
    let mut forged = signed(&c);
    forged.pop();
    forged.push('A');
    let mut other = f["claims"].clone();
    other["aud"] = serde_json::json!("host_00000000000000000003");
    other["network"]["acl_version"] = serde_json::json!(2);
    for token in [forged, signed(&other)] {
        assert!(verifier.verify(&token, &expected(Service::Daemon)).is_err());
    }
    // A newer token for this peer, sent over another WireGuard session: no hint.
    let wrong = Expected { peer_key: &[7; 32], ..expected(Service::Daemon) };
    assert!(verifier.verify(&signed(&c), &wrong).is_err());
    assert_eq!(behind.load(Ordering::SeqCst), 2, "only a signed, current token hints");
    // The current token still verifies: the hint admits nothing and spends nothing.
    assert!(verifier.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)).is_ok());
}

/// RED before reasons: every check below refused as the same bare `Invalid`,
/// so a production issuer mismatch (`cmux:cloud:prod` minted against a
/// receiver expecting `cmux:cloud:production`) read like any other refusal.
#[test]
fn native_token_receiver_names_the_check_that_refused() {
    let f = fixture();
    for (field, value, reason) in [
        ("iss", serde_json::json!("cmux:cloud:prod"), "issuer"),
        ("aud", serde_json::json!("host_00000000000000000003"), "audience"),
        ("epoch", serde_json::json!(5), "epoch"),
        ("team", serde_json::json!("team_00000000000000000003"), "team"),
        ("sub", serde_json::json!("install_1"), "subject"),
        ("sub", serde_json::json!("inst_00000000000000000003"), "peer_not_in_policy"),
        ("iat", serde_json::json!(1_792_000_100), "iat_in_future"),
        ("exp", serde_json::json!(1_792_000_400), "lifetime"),
        ("jti", serde_json::json!("short"), "jti"),
        ("svc", serde_json::json!([]), "services"),
    ] {
        let mut c = f["claims"].clone();
        c[field] = value;
        let token = signed(&c);
        let (verifier, _) = configured();
        let refusal = verifier.verify_explained(&token, &expected(Service::Daemon)).unwrap_err();
        assert_eq!(refusal.reason, reason, "{field}");
        let (verifier, _) = configured();
        assert_eq!(
            verifier.verify(&token, &expected(Service::Daemon)).err(),
            Some(refusal.kind),
            "the reason changed what {field} refuses"
        );
    }
    let mut c = f["claims"].clone();
    c["iss"] = serde_json::json!("cmux:cloud:prod");
    let (verifier, _) = configured();
    let refusal = verifier.verify_explained(&signed(&c), &expected(Service::Daemon)).unwrap_err();
    let text = refusal.to_string();
    assert!(text.contains("\"cmux:cloud:test\"") && text.contains("\"cmux:cloud:prod\""), "{text}");
    let altered = format!("{}x", f["token"].as_str().unwrap());
    let refusal = verifier.verify_explained(&altered, &expected(Service::Daemon)).unwrap_err();
    assert!(!refusal.to_string().contains(f["token"].as_str().unwrap()), "never the token");
    // A refused token is not spent, and the accepted one is unchanged.
    assert!(
        verifier.verify_explained(f["token"].as_str().unwrap(), &expected(Service::Daemon)).is_ok()
    );
}
