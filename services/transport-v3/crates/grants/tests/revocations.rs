use cmux_v3_grants::*;
use ed25519_dalek::SigningKey;
use libp2p_identity::Keypair;

#[test]
fn signed_revocation_updates_are_monotonic_and_team_scoped() {
    let key = SigningKey::from_bytes(&[91; 32]);
    let signer = GrantSigner::new("authority".into(), &key).unwrap();
    let peer = Keypair::generate_ed25519().public().to_peer_id();
    let update = RevocationUpdate { key_id: String::new(), team_id: "team".into(), sequence: 1,
        policy_revision: 4, revoked_peers: vec![peer.to_string()], issued_at: 1000 };
    let token = signer.sign_revocation(update.clone(), 1000).unwrap();
    let mut keys = AuthorityKeys::default(); keys.insert("authority".into(), key.verifying_key());
    let verified = keys.admit_revocation(&token, "team", 1001).unwrap();
    assert_eq!(verified.key_id, "authority");
    let mut state = Revocations::default(); state.apply_update(&verified).unwrap();
    assert!(state.apply_update(&RevocationUpdate { policy_revision: 2, sequence: 2, ..verified.clone() }).is_ok());
    assert!(state.apply_update(&RevocationUpdate { policy_revision: 5, sequence: 4, ..verified }).is_err());
    assert!(keys.admit_revocation(&token, "other", 1001).is_err());
}

#[test]
fn forged_or_stale_revocation_updates_are_rejected() {
    let key = SigningKey::from_bytes(&[92; 32]);
    let signer = GrantSigner::new("authority".into(), &key).unwrap();
    let mut update = RevocationUpdate { key_id: String::new(), team_id: "team".into(), sequence: 1,
        policy_revision: 1, revoked_peers: vec![], issued_at: 1000 };
    let token = signer.sign_revocation(update.clone(), 1000).unwrap();
    let mut parts: Vec<_> = token.split('.').map(str::to_owned).collect();
    parts[1].replace_range(..1, if parts[1].starts_with('A') { "B" } else { "A" });
    let mut keys = AuthorityKeys::default(); keys.insert("authority".into(), key.verifying_key());
    assert!(keys.admit_revocation(&parts.join("."), "team", 1001).is_err());
    update.issued_at = 600; let stale = signer.sign_revocation(update, 1000).unwrap();
    assert!(keys.admit_revocation(&stale, "team", 1000).is_err());
}
