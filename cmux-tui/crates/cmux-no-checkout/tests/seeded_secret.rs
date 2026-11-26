//! Seeded secret through the no-checkout GitHub client (tests/egress_seeded.json, site
//! `cmux_no_checkout::github`): the person's GitHub token rides only in `authorization`.

use cmux_egress::capture;
use cmux_no_checkout::GitHub;
use zeroize::Zeroizing;

#[tokio::test(flavor = "multi_thread")]
async fn the_github_token_rides_only_in_authorization() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
    let token = "SEEDnoCheckoutGitHubToken-a7d4";
    let gh = GitHub::new(
        cmux_no_checkout::github::GITHUB_API,
        "seeded-owner/seeded-repo",
        Some(Zeroizing::new(token.to_owned())),
        None,
    )
    .unwrap();
    // The capture answers `200 {}`, which is not a repo; only what was sent matters here.
    let _ = gh.default_branch().await;
    let sent = capture::requests_to("api.github.com");
    assert!(!sent.is_empty(), "nothing was sent");
    let at = capture::leaks(token);
    assert!(
        !at.is_empty() && at.iter().all(|place| place.ends_with(": header authorization")),
        "{at:?}"
    );
}
