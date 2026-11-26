//! Seeded secrets on the wire (cmux_egress::capture) through `cmux autocloud`'s platform client: the
//! person's cmux credential rides only in `Authorization` and the team only in the `team` query.
//! tests/egress_seeded.json names this test for `cmux_tui::cli::autocloud`.

use super::*;

#[test]
fn seeded_secrets_ride_only_where_the_platform_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let credential = "SEEDautocloudCredential-5b1c";
    let team = "SEEDautocloudTeam-0e7a";
    let dir = tempfile::tempdir().unwrap();
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, credential).unwrap();
    let common = Common {
        platform: None,
        team: Some(team.to_owned()),
        token: TokenSource::File(token_file),
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(run(&common, &Verb::Overview, None));
    assert!(
        !cmux_egress::capture::requests().is_empty(),
        "the overview reached the capture server"
    );
    let places = cmux_egress::capture::leaks(credential);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(places.iter().all(|p| p.ends_with(": target")), "{places:?}");
}
