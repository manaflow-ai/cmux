//! Seeded secrets through the projection's blob chain (tests/egress_seeded.json, sites
//! `cmux_projection::peers` and `cmux_projection::s3`): a seed's bearer rides only in
//! `authorization`, and an S3 secret key never leaves the process (only its signature does).

use cmux_egress::capture;
use cmux_projection::peers::{self, Answer, Beat, BeatPolicy, Get as _, Http};
use cmux_projection::s3::{Bucket, Config, Keys, Pushed, Store};
use std::time::{Duration, Instant};

fn install() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
}

#[test]
fn the_seed_token_rides_only_in_authorization() {
    install();
    let http = Http::new().unwrap();
    let token = "SEEDprojectionPeerToken-4e19";
    let url =
        "https://api.github.com/seeded-peers/objects/0123456789abcdef0123456789abcdef01234567";
    let answer = http.get(url, Some(token), Duration::from_secs(20));
    assert!(matches!(answer, Answer::Found(_)), "{answer:?}");

    // The heartbeat to the controller's seed index carries its own token the same way.
    let beat_token = "SEEDprojectionBeatToken-7a02";
    let client = cmux_egress::blocking_client_builder("cmux_projection::peers").build().unwrap();
    let beat = Beat {
        host: "seeded-seed-host".into(),
        seed_url: "http://100.64.0.9:7777".into(),
        zone: "seeded-zone".into(),
        repos: Vec::new(),
    };
    let body = serde_json::to_vec(&beat).unwrap();
    let policy = BeatPolicy {
        attempt: Duration::from_secs(20),
        period: Duration::from_secs(30),
        backoff: Duration::from_secs(1),
    };
    let tries = peers::post_beat(
        &client,
        "https://cloud-api.cmux.dev/v1/seeds/heartbeat",
        Some(beat_token),
        &body,
        policy,
        Instant::now(),
    )
    .unwrap();
    assert_eq!(tries, 1);

    assert_eq!(
        capture::leaks(token),
        ["api.github.com GET /seeded-peers/objects/0123456789abcdef0123456789abcdef01234567: header authorization".to_string()]
    );
    assert_eq!(
        capture::leaks(beat_token),
        ["cloud-api.cmux.dev POST /v1/seeds/heartbeat: header authorization".to_owned()]
    );
}

#[test]
fn the_s3_secret_key_never_leaves_only_its_signature_does() {
    install();
    let secret = "SEEDprojectionS3SecretKey-b85c/QwErTy";
    let session = "SEEDprojectionS3Session-2d6f";
    let config = Config::bucket(
        "s3",
        Bucket {
            endpoint: "https://s3.us-west-2.amazonaws.com".into(),
            bucket: "seededblobs".into(),
            region: "us-west-2".into(),
            prefix: "objects".into(),
            keys: Some(Keys {
                access_key_id: "AKIASEEDPROJECTION01".into(),
                secret_access_key: secret.into(),
                session_token: Some(session.into()),
            }),
            tenant: "t1".into(),
            ..Bucket::default()
        },
    )
    .unwrap();
    let host = config.host.clone();
    let store = Store::new(config).unwrap();
    let bytes = b"SEEDprojectionBlobBytes-93aa";
    let oid = peers::blob_id(bytes, 40);
    let _ = store.get(&oid, Duration::from_secs(20));
    // The capture answers the HEAD 200, so the bucket "has" it and no PUT follows.
    assert_eq!(store.push(&oid, bytes).unwrap(), Pushed::Had);

    let sent = capture::requests_to(&host);
    assert_eq!(sent.len(), 2, "{sent:?}");
    assert!(capture::leaks(secret).is_empty(), "{:?}", capture::leaks(secret));
    let mut session_at = capture::leaks(session);
    session_at.sort();
    assert_eq!(
        session_at,
        [
            format!("{host} GET /objects/t1/{oid}: header x-amz-security-token"),
            format!("{host} HEAD /objects/t1/{oid}: header x-amz-security-token"),
        ]
    );
}
