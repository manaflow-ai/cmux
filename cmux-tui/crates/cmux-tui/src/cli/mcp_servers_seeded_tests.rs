//! Seeded secrets on the wire (cmux_egress::capture) through `cmux mcp-servers`' platform client: the
//! person's cmux credential rides only in `Authorization`, the team only in `x-cmux-team` and the `team`
//! query, and a server's API key only in the connect body.
//! tests/egress_seeded.json names this test for `cmux_tui::cli::mcp_servers`.

use super::*;

#[test]
fn seeded_secrets_ride_only_where_the_platform_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let credential = "SEEDmcpCredential-2f9d";
    let team = "SEEDmcpTeam-81aa";
    let key = "SEEDmcpServerKey-c403";
    let dir = tempfile::tempdir().unwrap();
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, credential).unwrap();
    let common = Common {
        platform: None,
        team: Some(team.to_owned()),
        token: TokenSource::File(token_file),
    };
    let verb = Verb::Connect { name: "linear".into(), owner: None, return_to: None, key: true };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(run(&common, &verb, Some(Zeroizing::new(key.to_owned()))));
    assert!(!cmux_egress::capture::requests().is_empty(), "the connect reached the capture server");
    let places = cmux_egress::capture::leaks(credential);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(
        places.iter().all(|p| p.ends_with(": header x-cmux-team") || p.ends_with(": target")),
        "{places:?}"
    );
    let places = cmux_egress::capture::leaks(key);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": body")), "{places:?}");
}
