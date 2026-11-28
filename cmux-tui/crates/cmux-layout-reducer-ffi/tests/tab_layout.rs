//! The tab strip geometry ops over the C ABI.

use std::ffi::CString;

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(op: &str, request: &Value) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    // SAFETY: every pointer is live for the call, with its length.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn metrics() -> Value {
    json!({
        "maxTabWidth": 240.0, "minInactiveTabWidth": 74.0, "minActiveTabWidth": 74.0, "pinnedTabWidth": 36.0,
        "compactTabWidth": 180.0, "pinnedGroupGap": 10.0, "chromeMinInactiveWidth": 32.0,
        "closeMinContentsWidth": 56.0, "titleMinVisibleWidth": 20.0, "contentLeadingInset": 8.0,
        "contentTrailingInset": 6.0, "iconSize": 16.0, "closeButtonSize": 14.0, "iconTitleSpacing": 6.0,
        "titleCloseSpacing": 8.0
    })
}

#[test]
fn layout_then_resize_round_trips() {
    let items = json!([{ "id": "p", "pinned": true }, { "id": "a" }, { "id": "b" }]);
    let (code, result) = call(
        "tab_layout_layout",
        &json!({ "items": items, "availableWidth": 300.0, "metrics": metrics() }),
    );
    assert_eq!(code, OK);
    assert_eq!(result["share"], json!({ "kind": "split", "base": 127.0, "extra": 0 }));
    assert_eq!(result["slots"][1]["x"], 46.0);
    let (code, wide) = call(
        "tab_layout_resized",
        &json!({ "result": result, "availableWidth": 2000.0, "metrics": metrics() }),
    );
    assert_eq!(code, OK);
    assert_eq!(wide["contentWidth"], 526.0);
    let (code, closing) =
        call("tab_layout_closing_mode_width", &json!({ "closing": "p", "result": wide }));
    assert_eq!((code, closing), (OK, json!({ "width": 480.0 })));
}

#[test]
fn chrome_and_vertical_answer() {
    let (code, form) = call(
        "tab_layout_chrome_resolve",
        &json!({ "width": 200.0, "tab": { "hovered": true }, "metrics": metrics() }),
    );
    assert_eq!(code, OK);
    assert_eq!(form["showsClose"], true);
    let (code, origin) = call(
        "tab_layout_close_origin",
        &json!({ "visibility": form, "pillWidth": 200.0, "metrics": metrics() }),
    );
    assert_eq!((code, origin), (OK, json!({ "x": 180.0 })));
    let (code, list) = call(
        "tab_layout_vertical_slot",
        &json!({ "tabs": [{ "id": "a" }, { "id": "b" }], "width": 240.0, "y": 1000.0, "showsNewTab": true }),
    );
    assert_eq!(code, OK);
    assert_eq!(list["index"], 2);
}

#[test]
fn bad_requests_are_invalid() {
    assert_eq!(call("tab_layout_layout", &json!({ "items": 3 })).0, ERR_INVALID);
    assert_eq!(call("tab_layout_nope", &json!({})).0, ERR_INVALID);
}
