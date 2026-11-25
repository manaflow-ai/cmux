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
