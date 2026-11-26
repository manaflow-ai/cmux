//! Seeded secrets on the wire (cmux_egress::capture) through the Forum page's hosted-forum client: the
//! team's agent key rides only in `Authorization` (the token exchange) and the team only in
//! `x-cmux-team`.
//! tests/egress_seeded.json names this test for `cmux_tui_core::server::forum_routed`.

use super::*;

#[test]
fn seeded_secrets_ride_only_where_the_forum_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let key = "SEEDroutedForumKey-0d6e";
    let team = "SEEDroutedForumTeam-b28f";
    let env = |k: &str| match k {
        TEAM_ENV => Some(team.to_owned()),
        KEY_ENV => Some(key.to_owned()),
        _ => None,
    };
    let owner = ForumOwner::from_vars(&env);
    let hosted = owner.forum.as_ref().expect("the seeded env sets the forum up");
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(hosted.client.search("SEEDroutedForumQuery", None));
    assert!(!cmux_egress::capture::requests().is_empty(), "the search reached the capture server");
    let places = cmux_egress::capture::leaks(key);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
}
