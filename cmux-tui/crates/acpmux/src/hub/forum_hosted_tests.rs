use super::*;

#[test]
fn debug_never_shows_the_key() {
    struct Never;
    impl Transport for Never {
        async fn send(&self, _: Request) -> Result<Response, TransportError> {
            Err(TransportError::new("never"))
        }
    }
    let forum = HostedForum::new(AnyTransport::new(Never), "team-a", "cfk_secret_value");
    let shown = format!("{forum:?}");
    assert!(!shown.contains("cfk_secret_value"), "{shown}");
    assert!(shown.contains("team-a"), "{shown}");
    let err = forum.refusal(&ForumError::Transport("echo cfk_secret_value".into()));
    assert!(!err.message.contains("cfk_secret_value"), "{}", err.message);
    assert!(!format!("{err:?}").contains("cfk_secret_value"));
}

/// Seeded secrets on the wire (cmux_egress::capture): the agent key rides only in the token
/// exchange's `Authorization`, the team only in `x-cmux-team`, and the post's text only in
/// bodies. tests/egress_seeded.json names this test for `acpmux::hub::forum_hosted`.
#[tokio::test]
async fn seeded_secrets_ride_only_where_the_forum_needs_them() {
    cmux_egress::capture::install().unwrap();
    let key = "cfk_SEEDforumHostedKey-4b1e";
    let team = "SEEDforumTeam-91ac";
    let forum = HostedForum::at(
        cmux_forum_hosted::DEVELOPMENT_BASE_URL.to_owned(),
        team.to_owned(),
        key.to_owned(),
    )
    .unwrap();
    let client = forum.client("seeded-session");
    // The capture server answers `200 {}`: the exchange decodes no token and the call ends.
    let _ = client.spaces().await;
    let host = "cmux-platform-development.debussy.workers.dev";
    let sent = cmux_egress::capture::requests_to(host);
    assert!(!sent.is_empty(), "the exchange reached the capture server");
    let places = cmux_egress::capture::leaks(key);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(
        places.iter().all(|p| p.ends_with(" /v1/forum/token: header authorization")),
        "{places:?}"
    );
    let places = cmux_egress::capture::leaks(team);
    assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
}
