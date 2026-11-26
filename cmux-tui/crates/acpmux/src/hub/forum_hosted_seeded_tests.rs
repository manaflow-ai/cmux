//! Seeded secrets on the wire (cmux_egress::capture) through the hub's hosted-forum client: the team's
//! agent key rides only in `Authorization` (the token exchange) and the team only in `x-cmux-team`.
//! tests/egress_seeded.json names this test for `acpmux::hub::forum_hosted`.

use super::*;

#[test]
fn seeded_secrets_ride_only_where_the_forum_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let key = "SEEDhubForumKey-6a13";
    let team = "SEEDhubForumTeam-e950";
    let env = |k: &str| match k {
        TEAM_ENV => Some(team.to_owned()),
        KEY_ENV => Some(key.to_owned()),
        _ => None,
    };
    let forum = HostedForum::from_vars(&env).expect("the seeded env sets the forum up");
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(forum.client("seeded-session").search("SEEDhubForumQuery", None));
    assert!(!cmux_egress::capture::requests().is_empty(), "the search reached the capture server");
    let places = cmux_egress::capture::leaks(key);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
}
