//! The rb client C ABI replays the shared client vectors as JSON.

use serde_json::{Value, json};

use crate::{
    CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_OK, cmux_rb_client_apply, cmux_rb_client_free,
    cmux_rb_client_new,
};

const CLIENT: &str = include_str!("../../../../schemas/remote-tab/client.json");

/// Applies `input` and returns (code, outcome JSON).
fn apply(client: *mut crate::CmuxRbClient, input: &str) -> (i32, Value) {
    let mut ptr: *const u8 = std::ptr::null();
    let mut len = 0usize;
    // SAFETY: a live client, a readable input and writable out params.
    let code =
        unsafe { cmux_rb_client_apply(client, input.as_ptr(), input.len(), &mut ptr, &mut len) };
    if code != CMUX_RD_OK {
        return (code, Value::Null);
    }
    // SAFETY: the outcome stays valid until the next call on this client.
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    (code, serde_json::from_slice(bytes).expect("outcome is JSON"))
}

#[test]
fn the_vectors_replay_through_the_c_abi() {
    let file: Value = serde_json::from_str(CLIENT).expect("client.json parses");
    for case in file["cases"].as_array().expect("cases") {
        let client = cmux_rb_client_new();
        assert!(!client.is_null());
        for (i, step) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let at = format!("{} step {i}", case["name"]);
            let (code, outcome) = apply(client, &step["input"].to_string());
            assert_eq!(code, CMUX_RD_OK, "{at}");
            let expect = &step["expect"];
            assert_eq!(outcome["effects"], expect["effects"], "{at}: effects");
            assert_eq!(outcome["note"], expect["note"], "{at}: note");
            assert_eq!(outcome["reject"], expect["reject"], "{at}: reject");
        }
        // SAFETY: from cmux_rb_client_new, not used again.
        unsafe { cmux_rb_client_free(client) };
    }
}

#[test]
fn input_that_is_not_a_client_input_is_invalid_and_changes_nothing() {
    let client = cmux_rb_client_new();
    let show = json!({"op": "host", "message": {"t": "rb.menu.cancel", "token": 1}}).to_string();
    assert_eq!(apply(client, "{\"op\":\"nope\"}").0, CMUX_RD_ERR_INVALID);
    assert_eq!(apply(client, "not json").0, CMUX_RD_ERR_INVALID);
    let (code, outcome) = apply(client, &show);
    assert_eq!(code, CMUX_RD_OK);
    assert_eq!(outcome, json!({"effects": [], "note": "stale_cancel", "reject": null}));
    // SAFETY: as above.
    unsafe { cmux_rb_client_free(client) };
}

#[test]
fn null_pointers_are_refused() {
    let mut ptr: *const u8 = std::ptr::null();
    let mut len = 0usize;
    let input = b"{}";
    // SAFETY: NULL client and NULL out params are what this test passes.
    unsafe {
        assert_eq!(
            cmux_rb_client_apply(std::ptr::null_mut(), input.as_ptr(), 2, &mut ptr, &mut len),
            CMUX_RD_ERR_NULL
        );
        let client = cmux_rb_client_new();
        assert_eq!(
            cmux_rb_client_apply(client, std::ptr::null(), 2, &mut ptr, &mut len),
            CMUX_RD_ERR_NULL
        );
        assert_eq!(
            cmux_rb_client_apply(client, input.as_ptr(), 2, std::ptr::null_mut(), &mut len),
            CMUX_RD_ERR_NULL
        );
        cmux_rb_client_free(client);
        cmux_rb_client_free(std::ptr::null_mut());
    }
}
