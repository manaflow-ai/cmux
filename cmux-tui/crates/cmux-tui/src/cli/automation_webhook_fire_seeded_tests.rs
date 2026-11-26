//! Seeded secrets on the wire (cmux_egress::capture) through `cmux automation webhook fire`'s client: the
//! trigger's signing secret is never sent (only its HMAC rides, in `x-cmux-webhook-signature`), and the
//! event payload rides only in the body.
//! tests/egress_seeded.json names this test for `cmux_tui::cli::automation_webhook_fire`.

use super::*;

#[test]
fn the_signing_secret_never_rides_and_the_payload_only_in_the_body() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let secret = "SEEDwebhookSecret-a91f";
    let payload = "SEEDwebhookPayload-46c2";
    let body = serde_json::to_vec(&json!({"event": payload})).unwrap();
    let headers = signed_headers(secret, 1_795_000_000, "cli-seeded", &body);
    let url = format!(
        "{}{TRIGGERS_PATH}/trg_seeded/webhook",
        cmux_cloud_environment::PRODUCTION_PLATFORM.trim_end_matches('/')
    );
    let _ = post(&url, &headers, body);
    assert!(!cmux_egress::capture::requests().is_empty(), "the fire reached the capture server");
    assert!(
        cmux_egress::capture::leaks(secret).is_empty(),
        "{:?}",
        cmux_egress::capture::leaks(secret)
    );
    let places = cmux_egress::capture::leaks(payload);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": body")), "{places:?}");
}
