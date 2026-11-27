//! Seeded secrets on the wire (cmux_egress::capture) through the no-checkout GitHub client: the
//! person's GitHub token rides only in `Authorization`, to the API that checks it.
//! tests/egress_seeded.json names this test for `cmux_no_checkout::github`.

use super::*;

#[test]
fn the_token_rides_only_in_authorization() {
    cmux_egress::capture::install().unwrap();
    let token = "ghp_SEEDEDnoCheckoutToken71d4e0b2";
    let gh = GitHub::new(
        GITHUB_API,
        "seeded-owner/seeded-repo",
        Some(Zeroizing::new(token.into())),
        None,
    )
    .unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(gh.default_branch());
    assert!(!cmux_egress::capture::requests().is_empty(), "the call reached the capture server");
    let places = cmux_egress::capture::leaks(token);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
}
