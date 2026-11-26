mod common;

use cmux_forum_hosted::{
    AuthorKind, Credential, ForumClient, ForumError, Method, StateFilter, ThreadState,
};
use common::{FakeTransport, query};
use serde_json::json;

fn client(t: &FakeTransport) -> ForumClient<FakeTransport> {
    ForumClient::new(t.clone(), "team1", Credential::Session { access_token: "s".into() })
}

fn thread_json(number: u64) -> serde_json::Value {
    json!({
        "number": number, "title": "Deploy stuck", "body": "help", "state": "open",
        "labels": [{"name": "ci"}], "user": {"login": "bot"},
        "author": {"kind": "agent", "id": "a1", "name": "builder", "org": "team1",
                   "on_behalf_of": "u1", "session": "s-9", "host": "vm-3"},
        "space": "general", "comments": 2, "created_at": "2026-11-01T00:00:00Z",
        "updated_at": "2026-11-02T00:00:00Z", "closed_at": null, "html_url": "/forum/general/4",
        "some_future_field": {"x": 1}
    })
}

#[tokio::test]
async fn error_mapping() {
    let t = FakeTransport::default();
    let c = client(&t);
    let cases = [
        (
            404,
            json!({"code": "forum.not_found", "message": "the forum is not enabled for this team"}),
        ),
        (404, json!({"error": "no such thread"})),
        (401, json!({"code": "forum.unauthorized", "message": "missing or invalid bearer token"})),
        (403, json!({"code": "auth.sso_required", "message": "sso"})),
        (403, json!({"error": "not your thread"})),
        (400, json!({"code": "forum.invalid", "message": "bad"})),
        (409, json!({"error": "cursor past head"})),
        (503, json!({"code": "forum.unavailable", "message": "retry"})),
        (418, json!({"code": "x.teapot", "message": "no"})),
        (500, json!("not an object")),
    ];
    for (status, body) in &cases {
        t.push_json(*status, body.clone());
    }
    let mut got = Vec::new();
    for _ in &cases {
        got.push(c.thread(4).await.unwrap_err());
    }
    assert_eq!(
        got[0],
        ForumError::NotEnabled { message: "the forum is not enabled for this team".into() }
    );
    assert_eq!(got[1], ForumError::NotFound { message: "no such thread".into() });
    assert!(
        matches!(&got[2], ForumError::Unauthorized { code, .. } if code == "forum.unauthorized")
    );
    assert_eq!(
        got[3],
        ForumError::Forbidden { code: "auth.sso_required".into(), message: "sso".into() }
    );
    assert_eq!(
        got[4],
        ForumError::Forbidden { code: String::new(), message: "not your thread".into() }
    );
    assert!(matches!(&got[5], ForumError::Invalid { code, .. } if code == "forum.invalid"));
    assert_eq!(got[6], ForumError::Conflict { message: "cursor past head".into() });
    assert!(matches!(got[7], ForumError::Unavailable { status: 503, .. }));
    assert!(matches!(&got[8], ForumError::Api { status: 418, code, .. } if code == "x.teapot"));
    assert_eq!(got[9], ForumError::Unavailable { status: 500, message: String::new() });
}

#[tokio::test]
async fn decodes_threads_tolerating_extra_and_missing_fields() {
    let t = FakeTransport::default();
    let c = client(&t);
    t.push_json(200, json!([thread_json(4), {"number": 5, "title": "sparse", "state": "weird"}]));
    let threads = c.threads(Some("general"), StateFilter::All, 2).await.unwrap();
    assert_eq!(threads.len(), 2);
    assert_eq!(threads[0].author.kind, AuthorKind::Agent);
    assert_eq!(threads[0].author.on_behalf_of.as_deref(), Some("u1"));
    assert_eq!(threads[0].labels[0].name, "ci");
    assert_eq!(threads[1].state, ThreadState::Unknown);
    assert_eq!(threads[1].comments, 0);
    let r = &t.requests()[0];
    assert_eq!(r.method, Method::Get);
    assert!(r.path_and_query.starts_with("/v1/forum/threads?"));
    assert_eq!(query(r, "space").as_deref(), Some("general"));
    assert_eq!(query(r, "state").as_deref(), Some("all"));
    assert_eq!(query(r, "page").as_deref(), Some("2"));
    assert_eq!(r.header("x-cmux-team"), Some("team1"));
}

#[tokio::test]
async fn writes_send_json_bodies() {
    let t = FakeTransport::default();
    let c = client(&t).with_reported("sess-1", "vm-1");
    t.push_json(201, thread_json(9));
    t.push_json(201, json!({"id": 77, "body": "on it", "thread": 9, "author": {"kind": "person", "id": "u", "name": "n"}}));
    t.push_json(200, json!({"number": 9, "state": "closed"}));
    let th = c.post_thread("general", "Deploy stuck", "help", &["ci".into()]).await.unwrap();
    assert_eq!(th.number, 9);
    let cm = c.reply(9, "on it").await.unwrap();
    assert_eq!(cm.id, 77);
    let closed = c.close(9).await.unwrap();
    assert_eq!(closed.state, ThreadState::Closed);

    let reqs = t.requests();
    assert_eq!(
        (reqs[0].method, reqs[0].path_and_query.as_str()),
        (Method::Post, "/v1/forum/threads")
    );
    let body: serde_json::Value = serde_json::from_slice(reqs[0].body.as_ref().unwrap()).unwrap();
    assert_eq!(
        body,
        json!({"space": "general", "title": "Deploy stuck", "body": "help", "labels": ["ci"]})
    );
    assert_eq!(reqs[0].header("content-type"), Some("application/json"));
    assert_eq!(reqs[0].header("x-forum-session"), Some("sess-1"));
    assert_eq!(reqs[0].header("x-forum-host"), Some("vm-1"));
    assert_eq!(reqs[1].path_and_query, "/v1/forum/threads/9/comments");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(reqs[1].body.as_ref().unwrap()).unwrap(),
        json!({"body": "on it"})
    );
    assert_eq!(reqs[2].path_and_query, "/v1/forum/threads/9/close");
    assert_eq!(reqs[2].body.as_deref(), Some(&b"{}"[..]));
}

#[tokio::test]
async fn comments_follow_pages_until_a_short_one() {
    let t = FakeTransport::default();
    let c = client(&t);
    let full: Vec<_> = (0..100).map(|i| json!({"id": i, "body": "x", "thread": 3})).collect();
    t.push_json(200, json!(full));
    t.push_json(200, json!([{"id": 100, "body": "last", "thread": 3}]));
    let all = c.comments(3).await.unwrap();
    assert_eq!(all.len(), 101);
    assert_eq!(query(&t.requests()[1], "page").as_deref(), Some("2"));
}

#[tokio::test]
async fn search_and_spaces() {
    let t = FakeTransport::default();
    let c = client(&t);
    t.push_json(
        200,
        json!({"hits": [
            {"number": 1, "title": "a", "snippet": "<b>a</b>", "state": "open", "space": "general",
             "labels": [], "updated_at": "2026-11-01T00:00:00Z", "score": 1.5},
            {"number": 2, "title": "b", "snippet": "", "state": "closed", "space": "general",
             "labels": [], "updated_at": "2026-11-01T00:00:00Z", "score": "Infinity"}
        ]}),
    );
    let hits = c.search("deploy & ci", Some("general")).await.unwrap();
    assert_eq!(hits.len(), 2);
    assert!((hits[0].score - 1.5).abs() < f64::EPSILON);
    assert!(hits[1].score.is_infinite());
    assert_eq!(query(&t.requests()[0], "q").as_deref(), Some("deploy & ci"));

    t.push_json(200, json!([{"name": "general", "visibility": "shared", "threads": 3, "orgs": ["team1", "team2"]}]));
    let spaces = c.spaces().await.unwrap();
    assert_eq!(spaces[0].orgs, vec!["team1", "team2"]);
}

#[tokio::test]
async fn a_bad_success_body_is_a_decode_error() {
    let t = FakeTransport::default();
    let c = client(&t);
    t.push_json(200, json!({"not": "a list"}));
    assert!(matches!(c.spaces().await, Err(ForumError::Decode(_))));
}
