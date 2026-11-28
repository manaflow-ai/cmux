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

/// Every host in hosts.txt (the allowlist the gate compiles in and
/// docs/privacy.md is generated from), with each `*` filled in.
fn manifest_hosts() -> Vec<String> {
    include_str!("../hosts.txt")
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|host| host.to_ascii_lowercase().replace('*', "canary"))
        .collect()
}

/// The manifest drives the gate: a canary secret sent to each row's host goes
/// through the gated client in enforce mode and is captured at that host and
/// nowhere else, and a host no row lists is refused before any byte leaves.
/// A row the gate can't reach, or a host it lets through unlisted, fails here.
#[tokio::test]
async fn a_canary_reaches_every_manifest_row_and_no_unlisted_host()
-> Result<(), Box<dyn std::error::Error>> {
    capture::install()?;
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let client = cmux_egress::client(SITE)?;
    let hosts = manifest_hosts();
    assert!(hosts.len() > 50, "hosts.txt parsed to only {} hosts", hosts.len());
    for (row, host) in hosts.iter().enumerate() {
        let secret = format!("canary-{row}-manifest-row");
        assert_eq!(cmux_egress::verdict(host), cmux_egress::Verdict::Listed, "{host}");
        let answer = client
            .post(format!("https://{host}/canary"))
            .header("x-canary", &secret)
            .body(secret.clone())
            .send()
            .await?;
        assert_eq!(answer.status(), 200, "{host}");
        let leaks = capture::leaks(&secret);
        assert_eq!(leaks.len(), 2, "{host}: {leaks:?}");
        assert!(
            leaks.iter().all(|leak| leak.starts_with(&format!("{host} POST /canary: "))),
            "{host}: {leaks:?}"
        );
    }
    let unlisted = "canary-unlisted-host.org";
    assert_eq!(cmux_egress::verdict(unlisted), cmux_egress::Verdict::Unlisted);
    let refused = client
        .post(format!("https://{unlisted}/canary"))
        .body("canary-unlisted-secret")
        .send()
        .await;
    assert!(refused.is_err(), "an unlisted host was let through");
    assert!(capture::requests_to(unlisted).is_empty());
    assert!(capture::leaks("canary-unlisted-secret").is_empty());
    Ok(())
}
