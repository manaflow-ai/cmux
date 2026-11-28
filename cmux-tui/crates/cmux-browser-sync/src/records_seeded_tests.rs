//! Seeded-secret test for the browser sync records path (tests/egress_seeded.json, site
//! `cmux_browser_sync::records`): the access token rides only in `authorization` and a profile's name only in
//! the body.

use super::*;

#[tokio::test]
async fn seeded_secrets_ride_only_in_authorization_and_the_body() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let token = "SEEDbrowserSyncToken-7c41";
    let profile_name = "SEEDprofileName Work-2e9a";
    let transport =
        HttpTransport::new("https://cmux-platform-production.debussy.workers.dev", token).unwrap();
    let record = Record {
        kind: Kind::Profile,
        id: "default".to_owned(),
        updated_at_ms: 1,
        device: "seeded-device".to_owned(),
        deleted: false,
        value: Some(json!({"name": profile_name, "color": "blue", "icon": "globe"})),
    };
    // The capture server answers `200 {}`, which is no PullResult; the request is what this test reads.
    let _ = transport.exchange(0, &[record]).await;

    let host = "cmux-platform-production.debussy.workers.dev";
    let sent = cmux_egress::capture::requests_to(host);
    assert!(sent.iter().any(|r| r.target == "/v1/sync/browser/records"), "{sent:?}");
    let at = |place: &str| format!("{host} POST /v1/sync/browser/records: {place}");
    assert_eq!(cmux_egress::capture::leaks(token), [at("header authorization")]);
    assert_eq!(cmux_egress::capture::leaks(profile_name), [at("body")]);
}
