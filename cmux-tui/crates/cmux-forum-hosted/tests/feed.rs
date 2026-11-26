mod common;

use cmux_forum_hosted::{
    Credential, FeedFollower, ForumClient, ForumError, PullStatus, ThreadCache, TransportError,
};
use common::{FakeTransport, event, feed_page, json, not_modified, query, with_etag};

fn client(t: &FakeTransport) -> ForumClient<FakeTransport> {
    ForumClient::new(t.clone(), "team1", Credential::Session { access_token: "s3cret".into() })
}

#[tokio::test]
async fn advances_to_next_then_sends_etag_and_holds_on_304() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team1", Some("general".into()));

    t.push(Ok(with_etag(
        json(
            200,
            feed_page(
                vec![event(1, "thread.created", 7, "Hi", "open", "2026-11-01T00:00:00Z")],
                1,
                1,
            ),
        ),
        "\"h1\"",
    )));
    let pull = f.pull(&c).await.unwrap();
    assert_eq!(pull.status, PullStatus::CaughtUp { head: 1 });
    assert_eq!(pull.events.len(), 1);
    assert_eq!(f.after(), 1);
    assert_eq!(f.etag(), Some("\"h1\""));
    let first = &t.requests()[0];
    assert_eq!(query(first, "after").as_deref(), Some("0"));
    assert_eq!(query(first, "space").as_deref(), Some("general"));
    assert_eq!(first.header("if-none-match"), None);

    t.push(Ok(not_modified()));
    let pull = f.pull(&c).await.unwrap();
    assert_eq!(pull.status, PullStatus::Unchanged);
    assert!(pull.events.is_empty());
    assert_eq!(f.after(), 1);
    assert_eq!(f.etag(), Some("\"h1\""));
    let second = &t.requests()[1];
    assert_eq!(second.header("if-none-match"), Some("\"h1\""));
    assert_eq!(query(second, "after").as_deref(), Some("1"));
}

#[tokio::test]
async fn failed_request_leaves_cursor_and_etag() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team1", None);
    t.push(Ok(with_etag(json(200, feed_page(vec![], 5, 5)), "\"e5\"")));
    f.pull(&c).await.unwrap();
    assert_eq!(f.after(), 5);

    t.push(Err(TransportError::new("connection reset")));
    let err = f.pull(&c).await.unwrap_err();
    assert!(matches!(err, ForumError::Transport(_)));
    assert_eq!(f.after(), 5);
    assert_eq!(f.etag(), Some("\"e5\""));

    t.push_json(503, serde_json::json!({"code": "forum.unavailable", "message": "retry"}));
    assert!(matches!(f.pull(&c).await, Err(ForumError::Unavailable { status: 503, .. })));
    assert_eq!(f.after(), 5);
}

#[tokio::test]
async fn error_on_a_later_page_discards_the_whole_pull() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team1", None).with_limits(1, 8);
    t.push_json(200, feed_page(vec![event(1, "thread.created", 1, "a", "open", "t1")], 1, 3));
    t.push(Err(TransportError::new("timeout")));
    assert!(f.pull(&c).await.is_err());
    assert_eq!(f.after(), 0);
    assert_eq!(f.etag(), None);
}

#[tokio::test]
async fn reports_behind_after_the_page_cap() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team1", None).with_limits(2, 3);
    for p in 0..3u64 {
        let a = p * 2 + 1;
        t.push(Ok(with_etag(
            json(
                200,
                feed_page(
                    vec![
                        event(a, "thread.created", a, "t", "open", "t1"),
                        event(a + 1, "thread.created", a + 1, "t", "open", "t1"),
                    ],
                    a + 1,
                    10,
                ),
            ),
            "\"e10\"",
        )));
    }
    let pull = f.pull(&c).await.unwrap();
    assert_eq!(pull.status, PullStatus::Behind { next: 6, head: 10 });
    assert_eq!(pull.events.len(), 6);
    assert_eq!(t.requests().len(), 3);
    assert_eq!(f.after(), 6);
    // Behind, the etag would name the head, not this cursor: it is not kept.
    assert_eq!(f.etag(), None);
    assert_eq!(query(&t.requests()[2], "after").as_deref(), Some("4"));
    assert_eq!(query(&t.requests()[2], "limit").as_deref(), Some("2"));

    t.push(Ok(with_etag(json(200, feed_page(vec![], 10, 10)), "\"e10\"")));
    let pull = f.pull(&c).await.unwrap();
    assert_eq!(pull.status, PullStatus::CaughtUp { head: 10 });
    assert_eq!(t.requests()[3].header("if-none-match"), None);
    assert_eq!(f.etag(), Some("\"e10\""));
}

#[tokio::test]
async fn gone_cursor_is_typed_and_reset_moves_it() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team1", None);
    t.push_json(410, serde_json::json!({"error": "cursor is older than the log"}));
    let err = f.pull(&c).await.unwrap_err();
    assert_eq!(err, ForumError::Gone { message: "cursor is older than the log".into() });
    f.reset(42);
    assert_eq!(f.after(), 42);
}

#[tokio::test]
async fn pull_into_feeds_the_cache_and_follower_round_trips() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team1", None);
    let mut cache = ThreadCache::new();
    t.push_json(
        200,
        feed_page(
            vec![
                event(1, "thread.created", 3, "Build broke", "open", "2026-11-01T00:00:00Z"),
                event(2, "thread.closed", 3, "Build broke", "closed", "2026-11-02T00:00:00Z"),
            ],
            2,
            2,
        ),
    );
    assert_eq!(f.pull_into(&c, &mut cache).await.unwrap(), PullStatus::CaughtUp { head: 2 });
    assert_eq!(cache.get(3).unwrap().state, cmux_forum_hosted::ThreadState::Closed);

    let saved = serde_json::to_string(&f).unwrap();
    let back: FeedFollower = serde_json::from_str(&saved).unwrap();
    assert_eq!(back, f);
}

#[tokio::test]
async fn refuses_a_client_for_another_team() {
    let t = FakeTransport::default();
    let c = client(&t);
    let mut f = FeedFollower::new("team2", None);
    assert!(matches!(f.pull(&c).await, Err(ForumError::Invalid { .. })));
    assert!(t.requests().is_empty());
}
