//! Seeded secrets through the server's own HTTPS paths on the wire (cmux_egress::capture): the
//! Cloud machine agent's poster and the pairing network. Each bearer rides only in
//! `Authorization`, the pairing collect secret only in the wait's `Sec-WebSocket-Protocol`,
//! a body's secret only in its body, and the Native origin never sees a bearer.
//! tests/egress_seeded.json names these tests for the `cmux_server::cloud_http_transport` and
//! `cmux_server::pairing::network` gate sites.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_egress::capture;
use cmux_server::cloud_http::{JsonPoster, Payload, RawRequest};
use cmux_server::pairing::{Network, Transport};
use cmux_server_core::pairing::enrollment::Begun;
use serde_json::json;

/// Each test talks to its own hosts, so the two can run at once in this binary.
const POSTER: &str = "cloud-api.cmux.dev";
const PAIR: &str = "cloud-api-staging.cmux.dev";
const NATIVE: &str = "mobile-api.cmux.dev";

fn start() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(Ok(None));
    capture::install().unwrap();
}

fn places(secret: &str) -> Vec<String> {
    let mut places = capture::leaks(secret);
    places.sort();
    places
}

fn only_in(secret: &str, expected: &[&str]) {
    let mut expected: Vec<String> = expected.iter().map(|s| (*s).to_owned()).collect();
    expected.sort();
    assert_eq!(places(secret), expected, "{secret}");
}

#[test]
fn the_poster_sends_its_bearer_only_in_authorization() {
    start();
    let bearer = "SEEDhostBearer-0b71";
    let body_secret = "SEEDhostBody-terminal text ls ~/secret-4c2e";
    let idempotency = "SEEDhostIdempotency-9a13";
    let bytes_secret = "SEEDhostBytes-e5d0";
    let poster = JsonPoster::new().unwrap();
    let base = format!("https://{POSTER}");

    let _ = poster.post(
        &format!("{base}/v1/seeded/post"),
        &json!({ "note": body_secret }),
        Some(bearer),
    );
    let _ = poster.send_with_headers(
        "PUT",
        &format!("{base}/v1/seeded/put"),
        None,
        Some(bearer),
        &[("Idempotency-Key", idempotency)],
    );
    let _ = poster.request_raw(&RawRequest {
        method: "POST",
        url: &format!("{base}/v1/seeded/raw"),
        payload: Some(Payload::Bytes(bytes_secret.as_bytes())),
        bearer: Some(bearer),
        headers: &[],
        within: Duration::from_secs(20),
        limit: 1024,
    });
    let _ = poster.get(&format!("{base}/v1/seeded/anonymous"), None);

    let sent = capture::requests_to(POSTER);
    assert_eq!(sent.len(), 4, "{sent:?}");
    only_in(
        bearer,
        &[
            "cloud-api.cmux.dev POST /v1/seeded/post: header authorization",
            "cloud-api.cmux.dev PUT /v1/seeded/put: header authorization",
            "cloud-api.cmux.dev POST /v1/seeded/raw: header authorization",
        ],
    );
    only_in(body_secret, &["cloud-api.cmux.dev POST /v1/seeded/post: body"]);
    only_in(idempotency, &["cloud-api.cmux.dev PUT /v1/seeded/put: header idempotency-key"]);
    only_in(bytes_secret, &["cloud-api.cmux.dev POST /v1/seeded/raw: body"]);
    let anonymous = sent.iter().find(|r| r.target == "/v1/seeded/anonymous").unwrap();
    assert!(anonymous.headers.iter().all(|(n, _)| n != "authorization"), "{anonymous:?}");
}

#[test]
fn pairing_sends_the_collect_secret_only_in_the_wait_protocol() {
    start();
    let bearer = "SEEDpairBearer-71fa";
    let challenge = "SEEDpairChallengeBody-02c8";
    let native_body = "SEEDpairNativeBody-d4b6";
    let begin_body = "SEEDpairBeginBody-3f19";
    // A collect secret of the backend's shape: a 16-byte nonce, then a 64-hex MAC.
    let nonce = "SEEDpairCollectNonce0A";
    let collect = format!("{nonce}.{}", "5eedbeef".repeat(8));
    let thumbprint = URL_SAFE_NO_PAD.encode([7u8; 32]);
    let api = format!("https://{PAIR}");

    let network = Network::in_space("0.0.0-seeded", Ok(None)).unwrap();
    let _ = network.health(&api);
    let _ =
        network.backend_post(&api, "/v1/auth/challenge", &json!({ "c": challenge }), Some(bearer));
    let _ = network.native_post(
        &format!("https://{NATIVE}"),
        "/v1/seeded/native",
        &json!({ "n": native_body }),
    );
    let _ = network.begin(&api, &json!({ "b": begin_body }));
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;
    let begun = Begun::parse(
        &json!({ "code": "7KQ4M2XD", "expires_at": now + 2_000, "thumbprint": thumbprint, "collect_secret": collect }),
        &thumbprint,
        now,
    )
    .unwrap();
    let _ = network.wait(&api, &begun);

    let sent = capture::requests_to(PAIR);
    assert!(sent.iter().any(|r| r.target.starts_with("/v1/pair/wait?code=")), "{sent:?}");
    assert_eq!(capture::requests_to(NATIVE).len(), 1);
    only_in(bearer, &["cloud-api-staging.cmux.dev POST /v1/auth/challenge: header authorization"]);
    only_in(challenge, &["cloud-api-staging.cmux.dev POST /v1/auth/challenge: body"]);
    only_in(native_body, &["mobile-api.cmux.dev POST /v1/seeded/native: body"]);
    only_in(begin_body, &["cloud-api-staging.cmux.dev POST /v1/pair/begin: body"]);
    let wait = places(&collect);
    assert_eq!(wait.len(), 1, "{wait:?}");
    assert!(
        wait[0].starts_with("cloud-api-staging.cmux.dev GET /v1/pair/wait?code=7KQ4M2XD")
            && wait[0].ends_with(": header sec-websocket-protocol"),
        "{wait:?}"
    );
    assert_eq!(places(nonce), wait);
}
