//! `bookmarks_apply` through the C ABI: the app sends its confirmed bookmark
//! listing and its pending ops and shows the tree that comes back, so its
//! optimistic view follows the daemon's rules (layer-ownership.md V-11).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"bookmarks_apply".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

const FOLDER: &str = "bm_00000000000000000000000000000001";
const PAGE: &str = "bm_00000000000000000000000000000002";

#[test]
fn two_quick_edits_both_show_on_the_confirmed_tree() {
    let confirmed = json!([
        {"id": FOLDER, "browser_profile_id": "default", "parent": "bar", "kind": "folder", "index": 0,
         "title": "Work", "created_ms": 1},
        {"id": PAGE, "browser_profile_id": "default", "parent": "bar", "kind": "url", "index": 1,
         "title": "Page", "url": "https://example.com/", "created_ms": 2},
    ]);
    let (code, body) = call(&json!({
        "browser_profile_id": "default",
        "tree": confirmed,
        "ops": [
            {"op": "update", "bookmark": PAGE, "title": "Renamed"},
            {"op": "move", "bookmark": PAGE, "parent": FOLDER, "index": 0},
            {"op": "update", "bookmark": FOLDER, "url": "https://x.example"},
        ],
        "now_ms": 10,
    }));
    assert_eq!(code, OK);
    let tree = body["tree"].as_array().unwrap();
    assert_eq!(tree.len(), 2);
    assert_eq!(tree[1]["id"], PAGE);
    assert_eq!(tree[1]["parent"], FOLDER);
    assert_eq!(tree[1]["title"], "Renamed");
    assert_eq!(body["results"][0]["changed"], true);
    assert_eq!(body["results"][1]["result"]["bookmark"]["index"], 0);
    assert_eq!(
        body["results"][2],
        json!({"error_code": "invalid_params", "reason": "invalid_kind", "message": "a folder has no url"})
    );
}

#[test]
fn a_malformed_request_is_invalid() {
    let (code, _) = call(&json!({"tree": []}));
    assert_eq!(code, ERR_INVALID);
}
