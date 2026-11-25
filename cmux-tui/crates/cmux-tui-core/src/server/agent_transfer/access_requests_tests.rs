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
