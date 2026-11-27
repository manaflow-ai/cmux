use super::*;
use axum::{Json, Router, http::StatusCode, routing::post};
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;

async fn fixture() -> (Arc<Service>, Client, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let openrouter = format!("http://{}", listener.local_addr().unwrap());
    let router = Router::new().route(
        "/api/v1/auth/keys",
        post(|Json(body): Json<Value>| async move {
            let Some(verifier) = body["code_verifier"].as_str() else {
                return (StatusCode::BAD_REQUEST, Json(json!({})));
            };
            if body["code_challenge_method"] != "S256" || body["code"] != challenge(verifier) {
                return (StatusCode::UNAUTHORIZED, Json(json!({})));
            }
            (StatusCode::OK, Json(json!({"key": "fixture-key"})))
        }),
    );
    let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let service =
        Arc::new(Service::new(super::super::oauth::Endpoints { openrouter, ..Default::default() }));
    let client = service.oauth.http().unwrap().clone();
    (service, client, task)
}

fn authorize(begun: &Begun, good_code: bool) -> Url {
    let authorize = Url::parse(&begun.url).unwrap();
    assert_eq!(authorize.path(), "/auth");
    assert!(begun.user_code.is_empty());
    let query: std::collections::HashMap<_, _> = authorize.query_pairs().into_owned().collect();
    assert_eq!(query["key_label"], "cmux");
    assert_eq!(query["code_challenge_method"], "S256");
    let mut callback = Url::parse(&query["callback_url"]).unwrap();
    assert_eq!(callback.host_str(), Some("127.0.0.1"));
    assert!(callback.path().strip_prefix("/callback/").is_some_and(|state| !state.is_empty()));
    assert!(!query.contains_key("state"));
    callback
        .query_pairs_mut()
        .append_pair("code", if good_code { &query["code_challenge"] } else { "bad" });
    callback
}

#[tokio::test]
async fn openrouter_pkce_start_and_success() {
    let (service, client, task) = fixture().await;
    let begun = service
        .begin_openrouter(
            |key| {
                assert_eq!(key, "fixture-key");
                Ok("openrouter-key".into())
            },
            || {},
        )
        .await
        .unwrap();
    let callback = authorize(&begun, true);
    let mut stray = callback.clone();
    stray.set_path("/callback/wrong");
    assert_eq!(client.get(stray).send().await.unwrap().status(), StatusCode::NOT_FOUND);
    assert!(matches!(service.wait(&begun.attempt, Duration::ZERO).await, Ok(Status::Pending)));
    assert!(client.get(callback).send().await.unwrap().status().is_success());
    assert!(matches!(service.wait(&begun.attempt, Duration::from_secs(3)).await,
        Ok(Status::Done(id)) if id == "openrouter-key"));
    task.abort();
}

#[tokio::test]
async fn openrouter_pkce_incomplete_request_does_not_delay_the_callback() {
    let (service, client, task) = fixture().await;
    let begun = service.begin_openrouter(|_| Ok("openrouter-key".into()), || {}).await.unwrap();
    let callback = authorize(&begun, true);
    let mut slow = TcpStream::connect(("127.0.0.1", callback.port().unwrap())).await.unwrap();
    slow.write_all(b"GET / HTTP/1.1\r\n").await.unwrap();

    let response = tokio::time::timeout(REQUEST_TIMEOUT / 2, client.get(callback).send())
        .await
        .expect("the callback must finish before the other connection times out")
        .unwrap();
    assert!(response.status().is_success());
    assert!(matches!(
        service.wait(&begun.attempt, Duration::from_secs(3)).await,
        Ok(Status::Done(_))
    ));
    task.abort();
}

#[tokio::test]
async fn openrouter_pkce_bad_code_does_not_save() {
    let (service, client, task) = fixture().await;
    let begun = service.begin_openrouter(|_| panic!("must not save"), || {}).await.unwrap();
    let _ = client.get(authorize(&begun, false)).send().await.unwrap();
    assert!(matches!(
        service.wait(&begun.attempt, Duration::from_secs(3)).await,
        Ok(Status::Failed("bad_code"))
    ));
    task.abort();
}

#[tokio::test]
async fn openrouter_pkce_replaces_and_cancels_attempt() {
    let (service, client, task) = fixture().await;
    let start = || service.begin_openrouter(|_| panic!("must not save"), || {});
    let first = start().await.unwrap();
    let second = start().await.unwrap();
    assert!(matches!(service.wait(&first.attempt, Duration::ZERO).await, Ok(Status::Cancelled)));
    assert!(matches!(service.cancel(&second.attempt).await, Ok(Status::Cancelled)));
    assert!(client.get(authorize(&second, true)).send().await.is_err());
    task.abort();
}

#[tokio::test]
async fn openrouter_pkce_timeout_does_not_save() {
    let (service, _client, task) = fixture().await;
    let begun = service
        .start_openrouter(Duration::from_millis(5), |_| panic!("must not save"), || {})
        .await
        .unwrap();
    assert!(matches!(
        service.wait(&begun.attempt, Duration::from_secs(3)).await,
        Ok(Status::Failed("expired_token"))
    ));
    task.abort();
}
