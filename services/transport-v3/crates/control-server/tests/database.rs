//! Explicit opt-in database test; CI always supplies a disposable PostgreSQL service.
use cmux_v3_authority::DEFAULT_POLICY;
use cmux_v3_control_server::{
    auth::Identity, now, proof::Proof, store::Store, Authorization, DeviceUpdate, Enrollment,
    Error, PolicyUpdate, RelayRegistration, Revocation, Signed,
};
use cmux_v3_grants::{GrantSigner, LeasePolicy, OfflineAccess};
use ed25519_dalek::SigningKey;
use libp2p_identity::{Keypair, PeerId};
use sqlx::postgres::PgPoolOptions;
use uuid::Uuid;

fn peer() -> PeerId {
    Keypair::generate_ed25519().public().to_peer_id()
}
fn proof() -> Proof {
    Proof {
        public_key: String::new(),
        nonce: Uuid::new_v4(),
        issued_at: now(),
        signature: String::new(),
    }
}
fn identity(team: &str, user: &str, admin: bool) -> Identity {
    Identity {
        team: team.into(),
        user: user.into(),
        admin,
        verified_at: now(),
    }
}
fn enrollment(team: &str) -> Signed<Enrollment> {
    Signed {
        request: Enrollment {
            team: team.into(),
            device_id: Uuid::new_v4(),
        },
        proof: proof(),
    }
}
fn authorization(team: &str, destination: PeerId) -> Signed<Authorization> {
    Signed {
        request: Authorization {
            team: team.into(),
            destination: destination.to_string(),
            action: "connect".into(),
        },
        proof: proof(),
    }
}

#[tokio::test]
#[ignore = "requires CMUX_V3_TEST_DATABASE_URL, run explicitly in CI"]
async fn postgres_authorization_and_revocation_are_atomic_and_tenant_scoped() {
    let url = std::env::var("CMUX_V3_TEST_DATABASE_URL")
        .expect("explicit disposable database URL required");
    let db = PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&db).await.unwrap();
    sqlx::migrate!("./migrations").run(&db).await.unwrap();
    let store = Store(db.clone());
    let team = Uuid::new_v4().to_string();
    let other = Uuid::new_v4().to_string();
    let alice = identity(&team, "alice", false);
    let admin = identity(&team, "admin", true);
    let bob = identity(&team, "bob", false);
    let a = peer();
    let b = peer();
    let outsider = peer();
    let enroll = enrollment(&team);
    assert_eq!(store.enroll(&alice, &enroll, a).await.unwrap(), 1);
    assert!(matches!(
        store.enroll(&alice, &enroll, a).await,
        Err(Error::Conflict)
    ));
    let takeover = Signed {
        request: Enrollment {
            team: team.clone(),
            device_id: enroll.request.device_id,
        },
        proof: proof(),
    };
    assert!(store.enroll(&bob, &takeover, a).await.is_err());
    store.enroll(&bob, &enrollment(&team), b).await.unwrap();
    store
        .enroll(
            &identity(&other, "eve", false),
            &enrollment(&other),
            outsider,
        )
        .await
        .unwrap();
    let signer = GrantSigner::new("test".into(), &SigningKey::from_bytes(&[23; 32])).unwrap();
    let request = authorization(&team, b);
    assert!(store.authorize(&alice, &request, a, &signer).await.is_ok());
    assert!(matches!(
        store.authorize(&alice, &request, a, &signer).await,
        Err(Error::Conflict)
    ));
    assert!(store
        .authorize(&bob, &authorization(&team, b), a, &signer)
        .await
        .is_err());
    assert!(store
        .authorize(&alice, &authorization(&team, outsider), a, &signer)
        .await
        .is_err());
    let denied = PolicyUpdate {
        team: team.clone(),
        expected_revision: 1,
        cedar: "".into(),
    };
    assert!(store.set_policy(&alice, denied).await.is_err());
    let p1 = PolicyUpdate {
        team: team.clone(),
        expected_revision: 1,
        cedar: DEFAULT_POLICY.into(),
    };
    let p2 = PolicyUpdate {
        team: team.clone(),
        expected_revision: 1,
        cedar: DEFAULT_POLICY.into(),
    };
    let (x, y) = tokio::join!(store.set_policy(&admin, p1), store.set_policy(&admin, p2));
    assert_eq!(usize::from(x.is_ok()) + usize::from(y.is_ok()), 1);
    let infinite = LeasePolicy {
        offline: OfflineAccess::UntilRevoked {},
        renew_every_seconds: 30,
    };
    assert_eq!(
        store
            .set_device_policy(
                &admin,
                DeviceUpdate {
                    team: team.clone(),
                    peer: a.to_string(),
                    expected_revision: 2,
                    tags: vec![],
                    lease: infinite
                }
            )
            .await
            .unwrap(),
        3
    );
    assert!(store
        .authorize(&alice, &authorization(&team, b), a, &signer)
        .await
        .is_err());
    let cedar=format!("{DEFAULT_POLICY}\npermit(principal, action == Action::\"offline_unlimited\", resource) when {{ principal.owner == \"alice\" }};");
    assert_eq!(
        store
            .set_policy(
                &admin,
                PolicyUpdate {
                    team: team.clone(),
                    expected_revision: 3,
                    cedar
                }
            )
            .await
            .unwrap(),
        4
    );
    assert!(store
        .authorize(&alice, &authorization(&team, b), a, &signer)
        .await
        .is_ok());
    let revoke = Revocation {
        team: team.clone(),
        peer: b.to_string(),
        expected_revision: 4,
    };
    let race = authorization(&team, b);
    let (revoked, _grant) = tokio::join!(
        store.revoke(&admin, revoke),
        store.authorize(&alice, &race, a, &signer)
    );
    assert_eq!(revoked.unwrap(), 5);
    assert!(store
        .authorize(&alice, &authorization(&team, b), a, &signer)
        .await
        .is_err());
    assert!(store.enroll(&bob, &enrollment(&team), b).await.is_err());
    let directory = store.directory(&admin).await.unwrap();
    assert_eq!(directory["revision"], 5);
    assert_eq!(directory["devices"].as_array().unwrap().len(), 2);
    let events: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM transport_v3_events WHERE team_id=$1 AND action='revoke'",
    )
    .bind(&team)
    .fetch_one(&db)
    .await
    .unwrap();
    assert_eq!(events, 1);
    let relay = peer();
    let feed_token = "r".repeat(64);
    store
        .register_relay(
            &admin,
            RelayRegistration {
                team: team.clone(),
                peer_id: relay.to_string(),
                region: "westus2".into(),
                addresses: vec![format!("/ip4/127.0.0.1/tcp/4001/p2p/{relay}")],
                feed_token: feed_token.clone(),
            },
        )
        .await
        .unwrap();
    assert!(store
        .relay_token_valid(&relay.to_string(), feed_token)
        .await
        .unwrap());
    assert!(!store
        .relay_token_valid(&relay.to_string(), "wrong")
        .await
        .unwrap());
    assert!(!store.relay_events(&team, 0, 256).await.unwrap().is_empty());
}
