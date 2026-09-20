use cmux_v3_grants::*;
use ed25519_dalek::SigningKey;
use libp2p_identity::{Keypair, PeerId};

fn peer() -> PeerId {
    Keypair::generate_ed25519().public().to_peer_id()
}

struct Fixture {
    keys: AuthorityKeys,
    signer: GrantSigner,
    source: PeerId,
    destination: PeerId,
}

impl Fixture {
    fn new() -> Self {
        let key = SigningKey::from_bytes(&[42; 32]);
        let mut keys = AuthorityKeys::default();
        keys.insert("test-region".into(), key.verifying_key());
        Self {
            keys,
            signer: GrantSigner::new("test-region".into(), &key).unwrap(),
            source: peer(),
            destination: peer(),
        }
    }
    fn scope(&self) -> Scope<'_> {
        Scope {
            team: "team-a",
            source: self.source,
            destination: self.destination,
            action: "connect",
        }
    }
    fn grant(&self, lease: LeasePolicy) -> Grant {
        Grant::new(self.scope(), 7, lease, 1000, 1000).unwrap()
    }
    fn admit(&self, token: &str, now: u64, revocations: &Revocations) -> Result<Admission, Error> {
        self.keys.admit(token, self.scope(), now, revocations)
    }
}

#[test]
fn finite_grant_expires_even_when_connection_remains_open() {
    let f = Fixture::new();
    let grant = f.grant(LeasePolicy::default());
    let token = f.signer.sign(&grant, 1000).unwrap();
    let revocations = Revocations::default();
    let session = f.admit(&token, 1001, &revocations).unwrap();
    assert_eq!(session.expires_at(), Some(1300));
    assert!(session.check(1299, &revocations).is_ok());
    assert_eq!(session.check(1300, &revocations), Err(Error::Expired));
    assert!(matches!(
        f.admit(&token, 1300, &revocations),
        Err(Error::Expired)
    ));
}

#[test]
fn explicit_infinite_access_survives_offline_time_but_not_known_revocation() {
    let f = Fixture::new();
    let grant = f.grant(LeasePolicy {
        offline: OfflineAccess::UntilRevoked {},
        renew_every_seconds: 30,
    });
    let token = f.signer.sign(&grant, 1000).unwrap();
    let mut revocations = Revocations::default();
    let session = f.admit(&token, 1000, &revocations).unwrap();
    assert_eq!(session.expires_at(), None);
    assert!(session.check(1_000_000_000, &revocations).is_ok());
    revocations.revoke_device("team-b".into(), f.source);
    assert!(session.check(1001, &revocations).is_ok());
    revocations.revoke_device("team-a".into(), f.source);
    assert_eq!(session.check(1001, &revocations), Err(Error::Revoked));
}

#[test]
fn policy_revision_never_rolls_back_and_invalidates_infinite_grants() {
    let f = Fixture::new();
    let token = f
        .signer
        .sign(
            &f.grant(LeasePolicy {
                offline: OfflineAccess::UntilRevoked {},
                renew_every_seconds: 30,
            }),
            1000,
        )
        .unwrap();
    let mut revocations = Revocations::default();
    revocations.advance_policy("team-a".into(), 8);
    revocations.advance_policy("team-a".into(), 2);
    assert!(matches!(
        f.admit(&token, 1001, &revocations),
        Err(Error::Revoked)
    ));
}

#[test]
fn trusted_signature_does_not_allow_wrong_team_peer_direction_or_action() {
    let f = Fixture::new();
    let token = f
        .signer
        .sign(&f.grant(LeasePolicy::default()), 1000)
        .unwrap();
    let r = Revocations::default();
    assert!(f
        .keys
        .admit(
            &token,
            Scope {
                team: "team-b",
                ..f.scope()
            },
            1001,
            &r
        )
        .is_err());
    assert!(f
        .keys
        .admit(
            &token,
            Scope {
                source: peer(),
                ..f.scope()
            },
            1001,
            &r
        )
        .is_err());
    assert!(f
        .keys
        .admit(
            &token,
            Scope {
                source: f.destination,
                destination: f.source,
                ..f.scope()
            },
            1001,
            &r
        )
        .is_err());
    assert!(f
        .keys
        .admit(
            &token,
            Scope {
                action: "terminal_write",
                ..f.scope()
            },
            1001,
            &r
        )
        .is_err());
}

#[test]
fn tampered_and_unknown_signer_tokens_are_rejected() {
    let f = Fixture::new();
    let token = f
        .signer
        .sign(&f.grant(LeasePolicy::default()), 1000)
        .unwrap();
    let mut parts: Vec<_> = token.split('.').map(str::to_owned).collect();
    let byte = if parts[1].starts_with('A') { "B" } else { "A" };
    parts[1].replace_range(..1, byte);
    assert!(f
        .admit(&parts.join("."), 1001, &Revocations::default())
        .is_err());
    assert!(AuthorityKeys::default()
        .admit(&token, f.scope(), 1001, &Revocations::default())
        .is_err());
}

#[test]
fn finite_policy_cannot_be_encoded_as_infinite_by_omitting_expiry() {
    let f = Fixture::new();
    let mut grant = f.grant(LeasePolicy::default());
    grant.exp = None;
    assert!(f.signer.sign(&grant, 1000).is_err());
    assert!(serde_json::from_str::<LeasePolicy>(r#"{"renew_every_seconds":30}"#).is_err());
    assert!(
        serde_json::from_str::<OfflineAccess>(r#"{"mode":"until_revoked","seconds":300}"#).is_err()
    );
}

#[test]
fn validation_and_deadlines_do_not_extend_stale_authorization() {
    let policy = LeasePolicy::default();
    assert_eq!(policy.deadline(1000, 1290).unwrap(), Some(1300));
    assert_eq!(policy.deadline(1000, 1300), Err(Error::Expired));
    assert!(policy.deadline(1100, 1000).is_err());
    assert!(policy.deadline(u64::MAX - 10, u64::MAX - 5).is_err());
    assert!(LeasePolicy {
        offline: OfflineAccess::Bounded { seconds: 0 },
        renew_every_seconds: 1
    }
    .validate()
    .is_err());
    assert!(LeasePolicy {
        renew_every_seconds: 300,
        ..policy
    }
    .validate()
    .is_err());
    assert!(LeasePolicy {
        offline: OfflineAccess::UntilRevoked {},
        renew_every_seconds: 0
    }
    .validate()
    .is_err());
}
