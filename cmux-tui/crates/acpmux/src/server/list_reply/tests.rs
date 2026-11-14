use super::*;

/// A session row larger than a page alone goes as a stub with its size, not as a page
/// too large to send.
#[test]
fn an_acp_row_larger_than_its_page_goes_as_a_stub() {
    let s = json!({"sessionId": "big", "cwd": "/w", "updatedAt": 5,
            "tools": [{"id": "t", "description": "x".repeat(1000)}]});
    assert_eq!(acp_row_within(&s, 1 << 20), acp_row(&s));
    let stub = acp_row_within(&s, 100);
    assert_eq!(stub["sessionId"], "big");
    assert_eq!(stub["_meta"]["acpmux"]["sessionId"], "big");
    assert_eq!(stub["_meta"]["acpmux"]["omitted"]["reason"], "too_large");
    assert!(stub["_meta"]["acpmux"]["omitted"]["bytes"].as_u64().unwrap() > 1000);
    assert!(stub.to_string().len() < 400, "{stub}");
    // A huge title or cwd is not kept either, and the stub has no title to mask.
    let s = json!({"sessionId": "big", "cwd": "/".repeat(1 << 20), "updatedAt": 5,
            "title": "secret ".repeat(1 << 18), "harness": "claude", "lastSeq": 1});
    let stub = acp_row_within(&s, 1 << 16);
    assert_eq!(stub["sessionId"], "big");
    assert!(stub["title"].is_null() && stub["cwd"].is_null(), "{stub}");
    assert!(stub.to_string().len() < 400, "{stub}");
}

#[tokio::test]
async fn a_serialized_reply_is_the_line_message_writes_and_parsed_back_outside_a_request() {
    let result = json!({"sessions": [{"sessionId": "a", "z": [1, "x\n"]}]});
    for id in [json!(7), json!("req-1")] {
        let line = Message::ok(id.clone(), result.clone()).to_line();
        assert_eq!(reply_line(&id, &result.to_string()), line);
    }
    assert!(whole(&json!({"limit": null, "peer": "", "enabled": true})));
    for p in [json!({"limit": 5}), json!({"cursor": "k1.2"}), json!({"status": 3})] {
        assert!(!whole(&p), "{p}");
    }
}

#[test]
fn a_page_becomes_its_reply_line_in_its_own_buffer() {
    use crate::hub::list_guard::page_text;
    let rows = [r#"{"sessionId":"a"}"#, r#"{"sessionId":"b","t":"x\n"}"#];
    for next in [None, Some(Value::String("h1.2".into()).to_string())] {
        let text = page_text(next.clone(), &rows);
        let parsed: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(parsed["sessions"][1]["sessionId"], "b");
        assert_eq!(parsed.get("nextCursor").is_some(), next.is_some());
        for id in [json!(7), json!("req-1")] {
            let page = Arc::new(page_text(next.clone(), &rows));
            let (at, room) = (page.as_ptr(), page.capacity());
            let line = reply_line_in(&id, page);
            assert_eq!(line, reply_line(&id, &text));
            assert_eq!((line.as_ptr(), line.capacity()), (at, room), "made in place");
            // A shared result (the cached whole list) is copied and stays as it was.
            let shared = Arc::new(text.clone());
            assert_eq!(reply_line_in(&id, shared.clone()), reply_line(&id, &text));
            assert_eq!(*shared, text);
        }
    }
    // An id too long for the spare room still gives the same line.
    let id = json!("i".repeat(4096));
    assert_eq!(
        reply_line_in(&id, Arc::new(page_text(None, &rows))),
        reply_line(&id, &page_text(None, &rows))
    );
}
