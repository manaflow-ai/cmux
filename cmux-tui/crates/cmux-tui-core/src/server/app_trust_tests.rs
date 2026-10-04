use super::*;

const KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

#[test]
fn the_launcher_payload_round_trips_and_rejects_anything_else() {
    let key = FrontendKey::parse(&format!("cmuxik1 inst_a {KEY_HEX}\n")).unwrap();
    assert_eq!(key.install_id(), "inst_a");
    assert_eq!(FrontendKey::parse(&key.to_payload()).unwrap().key.as_slice(), key.key.as_slice());
    let zero = "0".repeat(64);
    for bad in [
        String::new(),
        format!("cmuxik2 inst_a {KEY_HEX}"),
        format!("cmuxik1 inst_a {KEY_HEX} extra"),
        format!("cmuxik1 inst/a {KEY_HEX}"),
        format!("cmuxik1 inst_a {}", &KEY_HEX[..62]),
        format!("cmuxik1 inst_a {zero}"),
        format!("cmuxik1  inst_a {KEY_HEX}"),
    ] {
        assert!(FrontendKey::parse(&bad).is_none(), "{bad:?}");
    }
}

#[test]
fn the_key_never_shows_in_debug_output() {
    let key = FrontendKey::parse(&format!("cmuxik1 inst_a {KEY_HEX}")).unwrap();
    let shown = format!("{key:?}");
    assert!(shown.contains("inst_a") && !shown.contains(&KEY_HEX[..16]), "{shown}");
}

#[test]
fn reading_the_pipe_is_bounded() {
    let payload = format!("cmuxik1 inst_a {KEY_HEX}\n");
    assert_eq!(read_frontend_key(payload.as_bytes()).unwrap().install_id(), "inst_a");
    let long = format!("cmuxik1 inst_a {KEY_HEX}{}", " ".repeat(600));
    assert!(read_frontend_key(long.as_bytes()).is_err());
    assert!(read_frontend_key(&b""[..]).is_err());
}

fn keyed(signed_build: bool) -> AppTrust {
    let trust = AppTrust { signed_build, ..AppTrust::default() };
    trust.install_key.set(FrontendKey::parse(&format!("cmuxik1 inst_a {KEY_HEX}")).unwrap()).unwrap();
    trust
}

fn proof_for(install_id: &str, nonce: &[u8; NONCE_LEN]) -> String {
    let key = frontend_proof::unhex::<INSTALL_KEY_LEN>(KEY_HEX).unwrap();
    frontend_proof::hello_proof(&key, install_id, nonce)
}

/// Prover B: the proof over this connection's nonce and the held install
/// id passes; any other id, nonce or proof fails, and so does a daemon
/// with no key.
#[test]
fn the_install_key_proof_needs_the_held_key_id_and_nonce() {
    let trust = keyed(false);
    let nonce = [7u8; NONCE_LEN];
    let proof = proof_for("inst_a", &nonce);
    assert!(trust.install_key_proves("inst_a", &nonce, "inst_a", &proof));
    assert!(!trust.install_key_proves("inst_a", &nonce, "inst_b", &proof));
    assert!(!trust.install_key_proves("inst_a", &[8u8; NONCE_LEN], "inst_a", &proof));
    let other = proof_for("inst_b", &nonce);
    assert!(!trust.install_key_proves("inst_b", &nonce, "inst_b", &other));
    assert!(!trust.install_key_proves("inst_a", &nonce, "inst_a", "00"));
    let keyless = AppTrust { signed_build: false, ..AppTrust::default() };
    assert!(!keyless.install_key_proves("inst_a", &nonce, "inst_a", &proof));
}

/// Security review P1: on a signed build a same-uid process could restart
/// the owner with a key it chose, so the install-key proof alone never
/// makes a connection the app there; only prover A (the audit token) does.
#[test]
fn a_signed_build_never_accepts_the_install_key_proof_alone() {
    let nonce = [7u8; NONCE_LEN];
    let proof = proof_for("inst_a", &nonce);
    assert!(!keyed(true).install_key_proves("inst_a", &nonce, "inst_a", &proof));
    assert!(keyed(false).install_key_proves("inst_a", &nonce, "inst_a", &proof));
}

/// Prover A needs a signed build and an audit token; an unsigned build or
/// a connection with no token never passes it.
#[test]
fn the_signature_prover_needs_a_signed_build_and_a_token() {
    assert!(!AppTrust { signed_build: false, ..AppTrust::default() }.signature_proves(None));
    assert!(!AppTrust { signed_build: true, ..AppTrust::default() }.signature_proves(None));
}
