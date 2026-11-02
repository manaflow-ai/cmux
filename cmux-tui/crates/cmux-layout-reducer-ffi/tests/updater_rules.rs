//! The `updater_*` operations through the C ABI: the app's updater sends its
//! rule inputs and reads the answer of `cmux-updater-core`.

// One module, so the fleet filter `updater_core` selects these with the crate's own tests.
mod updater_core_ffi {
    use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
    use serde_json::{Value, json};
    use std::ffi::CStr;

    fn call(operation: &CStr, request: &[u8]) -> (i32, Value) {
        let mut output = vec![0u8; 1 << 16];
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
    fn sparkle_order_answers_through_the_abi() {
        let request = serde_json::to_vec(&json!({"lhs": "1.0b1", "rhs": "1.0"})).unwrap();
        assert_eq!(call(c"updater_version_compare", &request), (OK, json!({"order": -1})));
    }

    #[test]
    fn the_pulled_list_is_the_raw_body() {
        let (code, body) = call(c"updater_pulled_decode", br#"[{"build":"5","reason":"r"}]"#);
        assert_eq!(code, OK);
        assert_eq!(body.pointer("/builds/0/build"), Some(&json!("5")));
    }

    #[test]
    fn an_unknown_operation_and_a_bad_request_are_invalid() {
        assert_eq!(call(c"updater_no_such_rule", b"{}").0, ERR_INVALID);
        assert_eq!(call(c"updater_version_compare", b"not json").0, ERR_INVALID);
    }
}
