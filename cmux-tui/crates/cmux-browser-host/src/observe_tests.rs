use super::*;

#[test]
fn an_allowlisted_read_becomes_the_host_written_agent_call() {
    let params = json!({
        "targetId": "T", "frameId": "F", "method": "snapshot", "args": [{"base": 3}],
        "source": "attacker()", "world": "page", "handles": ["h1"],
    });
    let evaluate = evaluate_params(&params).unwrap();
    assert_eq!(evaluate["world"], "agent");
    assert_eq!(evaluate["source"], OBSERVE_SOURCE, "the caller cannot send code");
    assert_eq!(evaluate["args"], json!(["snapshot", {"base": 3}]));
    assert_eq!(evaluate["targetId"], "T");
    assert_eq!(evaluate["frameId"], "F");
    assert!(evaluate.get("handles").is_none());
}

#[test]
fn a_function_outside_the_allowlist_is_refused() {
    for method in ["fill", "focus", "dispatchEvent", "scrollIntoViewIfNeeded", "hitTarget"] {
        let error = evaluate_params(&json!({"targetId": "T", "method": method})).unwrap_err();
        assert_eq!(error.code, ErrorCode::Forbidden, "{method}");
        assert_eq!(error.error_name.as_deref(), Some(NOT_ALLOWED), "{method}");
    }
    for method in ["constructor", "__proto__", "toString", ""] {
        assert!(evaluate_params(&json!({"method": method})).is_err(), "{method:?}");
    }
}

#[test]
fn selectors_that_test_values_and_huge_numbers_are_refused() {
    for selector in [
        "input[type=password][value^=\"a\"]",
        "internal:attr=[value=\"x\"i]",
        "css=input[value='a']",
        "xpath=//input[@value=\"a\"]",
        "input[*|value^=a]",
        "input[\\76 alue^=a]",
    ] {
        let error =
            evaluate_params(&json!({"method": "queryAll", "args": [selector]})).unwrap_err();
        assert_eq!(error.error_name.as_deref(), Some(NOT_ALLOWED), "{selector}");
    }
    assert!(evaluate_params(&json!({"method": "queryAll", "args": ["input#pw"]})).is_ok());
    for allowed in
        ["[data-x]", "[data-value=a]", "internal:role=button[name=\"Go\"i]", "input[value]"]
    {
        assert!(
            evaluate_params(&json!({"method": "queryAll", "args": [allowed]})).is_ok(),
            "{allowed}"
        );
    }
    let huge = json!({"method": "snapshot", "args": [{"base": 9_007_199_254_740_991u64}]});
    assert_eq!(evaluate_params(&huge).unwrap_err().code, ErrorCode::Invalid);
    assert!(evaluate_params(&json!({"method": "snapshot", "args": [{"base": 40}]})).is_ok());
}

#[test]
fn malformed_observe_params_are_invalid() {
    for params in [
        json!({"targetId": "T"}),
        json!({"method": 3}),
        json!({"method": "read", "args": "x"}),
        json!({"method": "read", "args": [0, 1, 2, 3, 4, 5, 6, 7, 8]}),
        json!({"method": "read", "args": ["x".repeat(70 * 1024)]}),
    ] {
        let error = evaluate_params(&params).unwrap_err();
        assert_eq!(error.code, ErrorCode::Invalid, "{params}");
    }
}
