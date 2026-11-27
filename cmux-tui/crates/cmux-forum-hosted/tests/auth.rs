mod common;

use cmux_forum_hosted::{Credential, ForumClient, ForumError, Method, Request};
use common::{FakeClock, FakeTransport};
use serde_json::json;

const KEY: &str = "cfk_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

fn token(tok: &str) -> serde_json::Value {
    json!({"token": tok, "token_type": "Bearer", "expires_in": 600,
           "expires_at": "2026-11-22T00:10:00Z", "team": "team1", "grants": ["forum:read"]})
}

fn agent(t: &FakeTransport, clock: std::sync::Arc<FakeClock>) -> ForumClient<FakeTransport> {
    ForumClient::new(t.clone(), "team1", Credential::AgentKey { key: KEY.into() }).with_clock(clock)
}

#[tokio::test]
async fn exchanges_once_then_reuses_until_near_expiry() {
    let t = FakeTransport::default();
    let clock = FakeClock::at(1_000);
    let c = agent(&t, clock.clone());

    t.push_json(200, token("cft_one.sig"));
    t.push_json(200, json!([]));
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    clock.set(1_000 + 500);
    c.spaces().await.unwrap();

    let reqs = t.requests();
    assert_eq!(reqs.len(), 3);
    assert_eq!(reqs[0].method, Method::Post);
    assert_eq!(reqs[0].path_and_query, "/v1/forum/token");
    assert_eq!(reqs[0].header("authorization"), Some(format!("Bearer {KEY}").as_str()));
    assert_eq!(reqs[0].header("x-cmux-team"), Some("team1"));
    assert_eq!(reqs[0].body, None);
    assert_eq!(reqs[1].header("authorization"), Some("Bearer cft_one.sig"));
    assert_eq!(reqs[2].header("authorization"), Some("Bearer cft_one.sig"));

    // Within the refresh margin of expiry (600 s): exchanged again.
    clock.set(1_000 + 545);
    t.push_json(200, token("cft_two.sig"));
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    let reqs = t.requests();
    assert_eq!(reqs[3].path_and_query, "/v1/forum/token");
    assert_eq!(reqs[4].header("authorization"), Some("Bearer cft_two.sig"));
}

#[tokio::test]
async fn a_refused_token_is_exchanged_again_once() {
    let t = FakeTransport::default();
    let c = agent(&t, FakeClock::at(0));
    t.push_json(200, token("cft_old.sig"));
    t.push_json(401, json!({"code": "forum.unauthorized", "message": "expired"}));
    t.push_json(200, token("cft_new.sig"));
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    let reqs = t.requests();
    assert_eq!(reqs.len(), 4);
    assert_eq!(reqs[3].header("authorization"), Some("Bearer cft_new.sig"));

    // A second 401 is returned, not retried forever.
    t.push_json(401, json!({"code": "forum.unauthorized", "message": "revoked"}));
    t.push_json(200, token("cft_3.sig"));
    t.push_json(401, json!({"code": "forum.unauthorized", "message": "revoked"}));
    assert!(matches!(c.spaces().await, Err(ForumError::Unauthorized { .. })));
    assert_eq!(t.remaining(), 0);
}

#[tokio::test]
async fn failed_exchange_maps_the_error_and_caches_nothing() {
    let t = FakeTransport::default();
    let c = agent(&t, FakeClock::at(0));
    t.push_json(401, json!({"code": "forum.unauthorized", "message": "an agent key (Bearer cfk_...) is required"}));
    assert!(matches!(c.spaces().await, Err(ForumError::Unauthorized { .. })));
    t.push_json(200, token("cft_ok.sig"));
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    assert_eq!(t.requests()[1].path_and_query, "/v1/forum/token");
}

#[tokio::test]
async fn session_credential_is_sent_as_is_and_can_be_swapped() {
    let t = FakeTransport::default();
    let c =
        ForumClient::new(t.clone(), "team1", Credential::Session { access_token: "sess1".into() })
            .with_host_team("team9");
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    c.set_credential(Credential::Session { access_token: "sess2".into() });
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    let reqs = t.requests();
    assert_eq!(reqs[0].header("authorization"), Some("Bearer sess1"));
    assert_eq!(reqs[0].header("x-forum-host-team"), Some("team9"));
    assert_eq!(reqs[1].header("authorization"), Some("Bearer sess2"));
}

#[tokio::test]
async fn debug_never_prints_secrets() {
    let key = Credential::AgentKey { key: KEY.into() };
    let session = Credential::Session { access_token: "sess-very-secret".into() };
    assert!(!format!("{key:?}").contains("cfk_"));
    assert!(!format!("{session:?}").contains("sess-very-secret"));

    let t = FakeTransport::default();
    let c = agent(&t, FakeClock::at(0));
    t.push_json(200, token("cft_tok.sig"));
    t.push_json(200, json!([]));
    c.spaces().await.unwrap();
    let client_dbg = format!("{c:?}");
    assert!(!client_dbg.contains("cfk_") && !client_dbg.contains("cft_tok"), "{client_dbg}");
    for r in t.requests() {
        let d = format!("{r:?}");
        assert!(!d.contains("cfk_") && !d.contains("cft_tok"), "{d}");
        assert!(d.contains("<redacted>"));
    }

    let r = Request {
        method: Method::Get,
        path_and_query: "/v1/forum/spaces".into(),
        headers: vec![("Authorization".into(), "Bearer xyz-secret".into())],
        body: None,
    };
    assert!(!format!("{r:?}").contains("xyz-secret"));
}
