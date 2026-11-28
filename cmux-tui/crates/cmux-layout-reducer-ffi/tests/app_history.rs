//! `app_history_*` through the C ABI: the app sends its facts and acts on the
//! answer (cmux-app-history holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn search_words_lines_order_and_rows() {
    assert_eq!(
        call(c"app_history_search_words", &json!({"query": "  Foo\tBAR "})),
        (OK, json!({"words": ["foo", "bar"]}))
    );
    let (code, body) = call(c"app_history_search_lines", &json!({"lines": ["a", "  ", "b"]}));
    assert_eq!(code, OK);
    assert_eq!(body["lines"], json!(["a", "b"]));
    let (code, body) = call(
        c"app_history_search_read_order",
        &json!({"sources": [{"readable": true, "local": false}, {"readable": false}, {"readable": true}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["order"], json!([2, 0]));
    let (code, body) = call(
        c"app_history_search_rows",
        &json!({"words": ["hit"], "rows": [{"line": "a hit here"}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["rows"][0]["snippet"], json!("a hit here"));
    assert_eq!(body["rows"][0]["needle"], json!("hit"));
}

#[test]
fn file_rows_git_relative_and_may_read() {
    let (code, body) = call(
        c"app_history_file_rows",
        &json!({"root": "/r", "resolvedRoot": "/r",
                "children": {"/r": [{"path": "/r/a", "name": "a", "isFolder": true}], "/r/a": [{"path": "/r/a/x", "name": "x"}]},
                "expanded": ["/r/a"], "states": {"/r/a/x": "modified"}, "folders": ["/r/a"]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["rows"][0]["git"], json!("containsChanges"));
    assert_eq!(body["rows"][1]["depth"], json!(1));
    assert_eq!(body["rows"][1]["git"], json!("modified"));
    let (code, body) = call(
        c"app_history_file_git",
        &json!({"top": "/r", "entries": [{"path": "a/x", "state": "added"}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["folders"], json!(["/r/a"]));
    assert_eq!(body["states"]["/r/a/x"], json!("added"));
    assert_eq!(
        call(c"app_history_file_relative", &json!({"root": "/r", "path": "/r/a"})),
        (OK, json!({"path": "a"}))
    );
    assert_eq!(
        call(c"app_history_file_relative", &json!({"path": "/r/a"})),
        (OK, json!({"path": "/r/a"}))
    );
    assert_eq!(
        call(
            c"app_history_file_may_read",
            &json!({"protected": true, "folder": "/d/x", "asked": ["/d"]})
        ),
        (OK, json!({"mayRead": true}))
    );
}

#[test]
fn closed_check_command_sync_and_find() {
    let (code, body) = call(c"app_history_closed_check", &json!({"overLimit": true, "nowMs": 0}));
    assert_eq!(code, OK);
    assert_eq!(body["prune"], json!(true));
    assert_eq!(body["retryMs"], json!(3_600_000));
    let (code, body) =
        call(c"app_history_command_sync", &json!({"enabled": true, "retentionDays": 7}));
    assert_eq!(code, OK);
    assert_eq!(body["send"], json!([]));
    assert_eq!(
        call(c"app_history_find_query", &json!({"text": " x ", "hasRoot": true})),
        (OK, json!({"query": "x"}))
    );
    assert_eq!(
        call(c"app_history_find_query", &json!({"text": "x"})),
        (OK, json!({"query": null}))
    );
    assert_eq!(
        call(c"app_history_find_state", &json!({"outcome": {"kind": "missing"}})),
        (OK, json!({"state": "ripgrepMissing"}))
    );
}

#[test]
fn hint_rects_and_page() {
    let (code, body) = call(
        c"app_history_hint_rects",
        &json!({"frames": [[0, 0, 10, 10], [0, 0, 10, 10], [0, 0, 2, 2]], "bounds": [0, 0, 100, 100], "limit": 196}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["kept"], json!([{"index": 0, "rect": [0.0, 0.0, 10.0, 10.0]}]));
    let (code, body) = call(
        c"app_history_hint_page",
        &json!({"answer": r#"[{"x":20,"y":10,"left":10,"top":5}]"#, "view": {"zoom": 1, "flipped": true, "height": 50}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["links"][0]["far"], json!([30.0, 15.0]));
    assert_eq!(
        call(
            c"app_history_hint_page_rect",
            &json!({"near": [0, 0], "far": [2, 2], "clip": [0, 0, 9, 9]})
        ),
        (OK, json!({"rect": null}))
    );
}

#[test]
fn unknown_and_malformed_requests_are_invalid() {
    assert_eq!(call(c"app_history_nope", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"app_history_file_relative", &json!({})).0, ERR_INVALID);
}
