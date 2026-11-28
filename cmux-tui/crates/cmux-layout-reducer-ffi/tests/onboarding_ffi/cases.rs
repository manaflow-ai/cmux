//! `onboarding_*` through the C ABI: the app sends its facts and acts on the
//! answer (cmux-window-rules `onboarding` holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 12];
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
fn footer_import_kinds_and_edge_first() {
    let (code, body) = call(
        c"onboarding_footer",
        &json!({"step": "importData", "import": {"phase": "ready", "hasPlan": true}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["primaryTitle"], json!("import"));
    assert_eq!(body["primary"], json!("startImport"));
    let (_, body) = call(
        c"onboarding_import",
        &json!({"phase": "confirmingPasswords", "authorizationDenied": true}),
    );
    assert_eq!(
        body,
        json!({"canEditSelection": false, "canStart": true, "offersPasswordCsv": true, "explainerProgress": 0.75})
    );
    let (_, body) = call(
        c"onboarding_kinds",
        &json!({"passwordStore": false, "preset": ["passwords", "cookies"]}),
    );
    assert_eq!(body["defaults"], json!(["bookmarks", "history", "cookies"]));
    assert_eq!(body["preset"], json!(["cookies"]));
    let (_, body) =
        call(c"onboarding_edge_first", &json!({"browsers": ["chrome", "edgeBeta", "edge"]}));
    assert_eq!(body, json!({"order": [2, 1, 0]}));
    let (code, _) = call(c"onboarding_footer", &json!({"step": "nowhere"}));
    assert_eq!(code, ERR_INVALID);
}

#[test]
fn walk_bundle_and_outcome() {
    let (code, body) = call(c"onboarding_walk_bundle", &json!({"installKey": "install-1"}));
    assert_eq!(code, OK);
    assert_eq!(body["id"], json!("wb1-000000"));
    assert_eq!(body["arms"]["screen"], json!("preview"));
    let (code, body) = call(
        c"onboarding_walk_outcome",
        &json!({"bundle": "wb1-000000", "ending": "skipped", "screen": 2}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"version": 1, "bundle": "wb1-000000", "ending": "skipped", "screen": 2})
    );
    let (code, _) = call(c"onboarding_walk_outcome", &json!({"bundle": "x", "ending": "nope"}));
    assert_eq!(code, ERR_INVALID);
}
