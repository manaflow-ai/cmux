//! The capture harness the seeded-secret tests stand on: a gated client's
//! request to a listed host lands in `capture::requests`, and `capture::leaks`
//! finds a planted secret wherever in the request it went.

use cmux_egress::capture;

const SITE: &str = "cmux_egress::seeded_secret";

#[tokio::test]
async fn a_planted_secret_is_found_in_target_header_and_body() {
    capture::install().unwrap();
    let secret = "seeded-7f3a-target-header-body";
    let client = cmux_egress::client(SITE).unwrap();
    let answer = client
        .post(format!("https://cloud-api.cmux.dev/v1/seeded?token={secret}"))
        .header("x-seeded", format!("Bearer {secret}"))
        .body(format!("{{\"value\":\"{secret}\"}}"))
        .send()
        .await
        .unwrap();
    assert_eq!(answer.status(), 200);
    let leaks = capture::leaks(secret);
    assert_eq!(leaks.len(), 3, "{leaks:?}");
    assert!(leaks.iter().any(|leak| leak.ends_with(": target")), "{leaks:?}");
    assert!(leaks.iter().any(|leak| leak.ends_with(": header x-seeded")), "{leaks:?}");
    assert!(leaks.iter().any(|leak| leak.ends_with(": body")), "{leaks:?}");
    assert!(capture::leaks("seeded-never-sent").is_empty());
    let sent = capture::requests_to("cloud-api.cmux.dev");
    assert!(
        sent.iter()
            .any(|request| request.method == "POST" && request.target.starts_with("/v1/seeded"))
    );
}

#[tokio::test]
async fn an_encoded_secret_is_found_too() {
    capture::install().unwrap();
    let secret = "seeded/9c2e encoded";
    let client = cmux_egress::client(SITE).unwrap();
    client
        .post("https://cloud-api.cmux.dev/v1/form")
        .header("content-type", "application/x-www-form-urlencoded")
        // How a form encoder writes `secret` (reqwest's `form` feature is off here).
        .body("value=seeded%2F9c2e+encoded")
        .send()
        .await
        .unwrap();
    let leaks = capture::leaks(secret);
    assert!(leaks.iter().any(|leak| leak.ends_with(": body")), "{leaks:?}");
}

#[tokio::test]
async fn capture_never_lets_an_unlisted_host_through() {
    capture::install().unwrap();
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let client = cmux_egress::client(SITE).unwrap();
    let refused = client.get("https://evil-seeded-test.org/x").send().await;
    assert!(refused.is_err());
    assert!(capture::requests_to("evil-seeded-test.org").is_empty());
}
