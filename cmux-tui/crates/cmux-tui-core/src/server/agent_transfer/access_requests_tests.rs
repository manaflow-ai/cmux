use super::*;

#[test]
fn requests_past_the_old_cap_of_64_are_kept_and_listed() {
    let requests = AccessRequests::default();
    let now = Instant::now();
    for index in 0..200 {
        let mut params = Map::new();
        params.insert("kind".into(), json!("secret"));
        params.insert("name".into(), json!(format!("SECRET_{index}")));
        let Ok(answer) = handle(&requests, "access-request", params, now) else {
            panic!("request {index} refused");
        };
        assert!(answer["request_id"].is_string(), "{answer}");
    }
    let Ok(listed) = handle(&requests, "access-request-list", Map::new(), now) else {
        panic!("list refused");
    };
    assert_eq!(listed["requests"].as_array().map(Vec::len), Some(200));
}

fn call(requests: &AccessRequests, cmd: &str, params: Value) -> Value {
    let Value::Object(params) = params else { panic!("params") };
    match handle(requests, cmd, params, Instant::now()) {
        Ok(value) => value,
        Err(refusal) => panic!("{cmd} refused: {}", refusal.code()),
    }
}

#[test]
fn a_shared_secret_is_answered_only_to_the_read_that_brings_the_askers_token() {
    let requests = AccessRequests::default();
    let made = call(
        &requests,
        "access-request",
        json!({"kind": "secret", "name": "NPM_TOKEN", "session": "chat-a"}),
    );
    let (id, token) = (made["request_id"].clone(), made["read_token"].clone());
    assert!(token.as_str().is_some_and(|token| token.len() == 32), "{made}");
    let listed = call(&requests, "access-request-list", json!({}));
    assert!(!listed.to_string().contains(token.as_str().unwrap()), "{listed}");
    call(
        &requests,
        "access-request-answer",
        json!({"request_id": id, "outcome": "delivered", "value": "fake-value"}),
    );
    // Another chat names the request, with no token or a guessed one.
    for params in [
        json!({"request_id": id}),
        json!({"request_id": id, "read_token": "0".repeat(32)}),
        json!({"request_id": id, "read_token": ""}),
    ] {
        let status = call(&requests, "access-request-status", params);
        assert_eq!(status, json!({"state": "delivered"}));
    }
    let status =
        call(&requests, "access-request-status", json!({"request_id": id, "read_token": token}));
    assert_eq!(status["value"], "fake-value", "{status}");
    let again =
        call(&requests, "access-request-status", json!({"request_id": id, "read_token": token}));
    assert_eq!(again, json!({"state": "delivered", "taken": true}));
}
