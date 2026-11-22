//! `workspace_preview` through the C ABI: the workspace hover card sends the active screen's split
//! tree and each pane's tab count once per card show and draws the pane rects it gets back.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"workspace_preview".as_ptr(),
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
fn workspace_preview_answers_pane_rects() {
    let request = json!({
        "layout": {"type": "split", "dir": "right", "ratio": 0.5,
                   "a": {"type": "leaf", "pane": "chat"}, "b": {"type": "leaf", "pane": "term"}},
        "panes": [{"id": "chat", "tabs": 2, "active": 1}, {"id": "term", "tabs": 1, "active": 0}],
        "width": 244.0,
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    let panes = body["panes"].as_array().unwrap();
    assert_eq!(panes.len(), 2);
    assert_eq!(panes[0]["id"], "chat");
    assert_eq!(panes[0]["w"], 120.0);
    assert_eq!(panes[1]["x"], 124.0);
    assert_eq!(panes[0]["shown"], json!([0, 1]));
}

#[test]
fn workspace_preview_refuses_a_malformed_request() {
    assert_eq!(call(br#"{"layout": {"type": "nope"}}"#).0, ERR_INVALID);
}
