use super::*;

fn keys() -> LaunchKeys {
    LaunchKeys::new("k1", [7; 32])
}

fn terminal_claims() -> Claims {
    Claims {
        v: 1,
        host: "sess_abc".into(),
        terminal: Some("term_1".into()),
        acp_session: None,
        agent: None,
        iat: 1_791_000_000,
    }
}

#[test]
fn a_minted_credential_verifies_to_its_claims() {
    let keys = keys();
    let credential = keys.mint(&terminal_claims()).unwrap();
    assert!(credential.starts_with("cmuxlc1.k1."));
    assert_eq!(keys.verify(&credential), Ok(terminal_claims()));
}

#[test]
fn a_tampered_credential_is_a_bad_mac() {
    let keys = keys();
    let credential = keys.mint(&terminal_claims()).unwrap();
    let mut forged = terminal_claims();
    forged.terminal = Some("term_2".into());
    let forged_body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&forged).unwrap());
    let parts: Vec<&str> = credential.split('.').collect();
    let tampered = format!("{}.{}.{}.{}", parts[0], parts[1], forged_body, parts[3]);
    assert_eq!(keys.verify(&tampered), Err(VerifyError::BadMac));
    let other = LaunchKeys::new("k1", [8; 32]);
    assert_eq!(other.verify(&credential), Err(VerifyError::BadMac));
}

#[test]
fn malformed_credentials_are_refused() {
    let keys = keys();
    for credential in [
        "",
        "cmuxlc1",
        "cmuxlc2.k1.e30.AAAA",
        "cmuxlc1.k1.e30",
        "cmuxlc1.k1.e30.AAAA.extra",
        "cmuxlc1.bad kid.e30.AAAA",
        "cmuxlc1.k1.e30.!!!",
    ] {
        assert_eq!(keys.verify(credential), Err(VerifyError::Malformed), "{credential:?}");
    }
    assert_eq!(keys.verify(&"a".repeat(MAX_CREDENTIAL_BYTES + 1)), Err(VerifyError::Malformed));
}

#[test]
fn claims_need_exactly_one_subject() {
    let keys = keys();
    let mut both = terminal_claims();
    both.acp_session = Some("acp_1".into());
    assert_eq!(keys.mint(&both), None);
    let mut neither = terminal_claims();
    neither.terminal = None;
    assert_eq!(keys.mint(&neither), None);
    let mut acp = neither;
    acp.acp_session = Some("acp_1".into());
    acp.agent = Some("agent_mux".into());
    let credential = keys.mint(&acp).unwrap();
    assert_eq!(keys.verify(&credential).unwrap().agent.as_deref(), Some("agent_mux"));
}

#[test]
fn rotation_keeps_one_previous_key_and_then_forgets_it() {
    let mut keys = keys();
    let old = keys.mint(&terminal_claims()).unwrap();
    keys.rotate("k2", [9; 32]);
    assert!(keys.is_valid());
    assert_eq!(keys.verify(&old), Ok(terminal_claims()));
    assert!(keys.mint(&terminal_claims()).unwrap().starts_with("cmuxlc1.k2."));
    keys.rotate("k3", [10; 32]);
    assert_eq!(keys.verify(&old), Err(VerifyError::UnknownKey));
    assert_eq!(keys.keys.len(), 2);
}

#[test]
fn debug_output_never_shows_key_bytes() {
    let text = format!("{:?}", keys());
    assert!(!text.contains(&URL_SAFE_NO_PAD.encode([7u8; 32])));
}
