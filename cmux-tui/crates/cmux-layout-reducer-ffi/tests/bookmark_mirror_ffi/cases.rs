use cmux_layout_reducer_ffi::bookmark_mirror::{
    BookmarkMirror, cmux_bookmark_mirror_call, cmux_bookmark_mirror_free, cmux_bookmark_mirror_new,
    cmux_bookmark_mirror_string_free,
};
use serde_json::{Value, json};
use std::ffi::{CStr, CString};

fn call(mirror: *mut BookmarkMirror, name: &str, input: &Value) -> Value {
    let name = CString::new(name).unwrap();
    let bytes = serde_json::to_vec(input).unwrap();
    let out =
        unsafe { cmux_bookmark_mirror_call(mirror, name.as_ptr(), bytes.as_ptr(), bytes.len()) };
    assert!(!out.is_null());
    let value = serde_json::from_str(unsafe { CStr::from_ptr(out) }.to_str().unwrap()).unwrap();
    unsafe { cmux_bookmark_mirror_string_free(out) };
    value
}

const PAGE: &str = "bm_00000000000000000000000000000002";

#[test]
fn an_edit_answers_its_delta_and_shows_until_settled() {
    let mirror = cmux_bookmark_mirror_new(1);
    call(mirror, "load", &json!({"browser_profile_id": "default", "bookmarks": []}));
    let reply = call(
        mirror,
        "apply",
        &json!({"browser_profile_id": "default", "key": "k1", "now_ms": 1, "op":
        {"op": "create", "id": PAGE, "browser_profile_id": "default", "parent": "bar", "kind": "url",
         "title": "Page", "url": "https://example.com/", "created_ms": 1}}),
    );
    assert_eq!(reply["changed"], true);
    assert_eq!(reply["delta"]["upserted"][0]["id"], PAGE);
    assert_eq!(reply["delta"]["order"], json!([{"parent": "bar", "insert": PAGE, "at": 0}]));
    // An echo without the edit (it was not stored yet) keeps showing it.
    let loaded = call(mirror, "load", &json!({"browser_profile_id": "default", "bookmarks": []}));
    assert_eq!(loaded["tree"][0]["id"], PAGE);
    assert_eq!(
        call(mirror, "settle", &json!({"browser_profile_id": "default", "key": "k1"}))["ok"],
        true
    );
    let settled = call(mirror, "load", &json!({"browser_profile_id": "default", "bookmarks": []}));
    assert_eq!(settled["dropped"], json!(["k1"]));
    unsafe { cmux_bookmark_mirror_free(mirror) };
}

#[test]
fn null_and_malformed_inputs_answer_without_crashing() {
    let name = CString::new("view").unwrap();
    assert!(
        unsafe {
            cmux_bookmark_mirror_call(std::ptr::null_mut(), name.as_ptr(), std::ptr::null(), 0)
        }
        .is_null()
    );
    let mirror = cmux_bookmark_mirror_new(1);
    assert!(
        unsafe { cmux_bookmark_mirror_call(mirror, std::ptr::null(), std::ptr::null(), 0) }
            .is_null()
    );
    assert!(call(mirror, "apply", &json!({"nope": 1}))["error"].is_string());
    unsafe { cmux_bookmark_mirror_free(mirror) };
    unsafe { cmux_bookmark_mirror_free(std::ptr::null_mut()) };
}
