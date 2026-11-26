//! Seeded secrets on the wire (cmux_egress::capture) through `cmux link`'s platform client: the person's
//! cmux credential rides only in `Authorization` and the team only in the `team` query.
//! tests/egress_seeded.json names this test for `cmux_tui::cli::runnable_link`.

use super::*;

#[test]
fn seeded_secrets_ride_only_where_the_platform_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let credential = "SEEDlinkCredential-77e0";
    let team = "SEEDlinkTeam-3c5b";
    let dir = tempfile::tempdir().unwrap();
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, credential).unwrap();
    let common = Common {
        platform: None,
        team: Some(team.to_owned()),
        token: TokenSource::File(token_file),
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(async {
        let mut http = match http_for(&common).await {
            Ok(http) => http,
            Err(answer) => panic!("{answer}"),
        };
        mint(&mut http, "vm_seeded", None, None, &mut |_| true).await
    });
    assert!(!cmux_egress::capture::requests().is_empty(), "the mint reached the capture server");
    let places = cmux_egress::capture::leaks(credential);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(places.iter().all(|p| p.ends_with(": target")), "{places:?}");
}
