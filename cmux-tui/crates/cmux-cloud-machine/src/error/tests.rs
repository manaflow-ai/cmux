//! The API's failures (moved from the app's CloudErrorTextTests and
//! CloudAPIClientPlanRequiredTests; the app keeps its localized wording's).

use serde_json::json;

use super::*;

const TRACE: &str = "(trace %@)";

fn body(value: Value) -> Vec<u8> {
    serde_json::to_vec(&value).unwrap()
}

fn http(status: i64, code: &str, message: &str) -> ApiError {
    ApiError::Http {
        status,
        code: Some(code.into()),
        message: Some(message.into()),
        action: None,
        trace_id: None,
    }
}

#[test]
fn the_server_action_and_trace_id_follow_the_message() {
    let error = from_response(
        409,
        &body(json!({
            "error": "vm_resize_in_progress", "message": "raw", "action": "Wait for the current resize to finish, then retry.",
            "traceId": "abc123", "ui": {"message": "Cloud VM vm-1 is already resizing.", "traceId": "abc123"},
        })),
        None,
    );
    assert_eq!(
        error,
        ApiError::Http {
            status: 409,
            code: Some("vm_resize_in_progress".into()),
            message: Some("Cloud VM vm-1 is already resizing.".into()),
            action: Some("Wait for the current resize to finish, then retry.".into()),
            trace_id: Some("abc123".into()),
        }
    );
    assert_eq!(
        text(&error, TRACE),
        "Cloud VM vm-1 is already resizing. Wait for the current resize to finish, then retry. (trace abc123)"
    );
}

#[test]
fn the_header_code_wins_and_a_blank_action_is_none() {
    let error = from_response(
        409,
        &body(json!({"error": "busy", "message": "Resize in progress.", "action": "  "})),
        Some("vm_resize_in_progress"),
    );
    assert_eq!(error, http(409, "vm_resize_in_progress", "Resize in progress."));
    assert_eq!(text(&error, TRACE), "Resize in progress.");
    assert_eq!(text(&from_response(502, b"<html>", None), TRACE), "HTTP 502");
}

#[test]
fn the_ui_trace_id_is_kept_when_the_top_level_one_is_missing() {
    let error = from_response(
        500,
        &body(json!({"error": "internal", "ui": {"message": "Try again.", "traceId": "t-9"}})),
        None,
    );
    assert_eq!(text(&error, "[%@]"), "Try again. [t-9]");
}

#[test]
fn the_workers_nested_refusal_reads_too() {
    let error = from_response(
        403,
        &body(json!({"ok": false, "error": {"code": "auth.forbidden", "message": "No."}})),
        None,
    );
    assert_eq!(error, http(403, "auth.forbidden", "No."));
    assert_eq!(code(&error), "auth.forbidden");
}

#[test]
fn a_free_accounts_create_is_the_plan_refusal() {
    let error = from_response(
        402,
        &body(json!({
            "error": "vm_active_limit_exceeded", "message": "Cloud VMs require a cmux Pro subscription.",
            "limit": 0, "upgradeRequired": true, "upgradeUrl": "https://cmux.com/pricing", "details": {"limit": 0, "upgradeRequired": true},
        })),
        None,
    );
    assert_eq!(
        error,
        ApiError::PlanRequired {
            message: Some("Cloud VMs require a cmux Pro subscription.".into()),
            upgrade_url: Some("https://cmux.com/pricing".into()),
            plan: "pro".into(),
        }
    );
    assert_eq!(code(&error), "plan_required");
}

#[test]
fn a_pro_budget_that_names_max_is_a_max_plan_refusal() {
    let error = from_response(
        402,
        &body(json!({
            "error": "vm_compute_budget_reached", "message": "This month's compute budget is used up.",
            "upgradeRequired": true, "upgradePlanId": "max", "upgradeUrl": "https://cmux.com/api/billing/checkout?plan=max",
        })),
        None,
    );
    assert_eq!(
        error,
        ApiError::PlanRequired {
            message: Some("This month's compute budget is used up.".into()),
            upgrade_url: Some("https://cmux.com/api/billing/checkout?plan=max".into()),
            plan: "max".into(),
        }
    );
}

#[test]
fn a_credits_top_up_or_an_unsold_plan_stays_an_http_refusal() {
    let credits = from_response(
        402,
        &body(json!({
            "error": "vm_create_credits_insufficient", "message": "You are out of Cloud credits.",
            "upgradeRequired": true, "upgradePlanId": "max", "upgradeUrl": "https://cmux.com/api/billing/checkout?plan=max",
        })),
        None,
    );
    assert_eq!(
        credits,
        http(402, "vm_create_credits_insufficient", "You are out of Cloud credits.")
    );
    let limit = from_response(
        402,
        &body(
            json!({"error": "vm_active_limit_exceeded", "message": "This plan allows 3 active Cloud VMs at a time.", "limit": 3}),
        ),
        None,
    );
    assert_eq!(
        limit,
        http(402, "vm_active_limit_exceeded", "This plan allows 3 active Cloud VMs at a time.")
    );
    let team = from_response(
        402,
        &body(
            json!({"error": "x", "message": "m", "upgradeRequired": true, "upgradePlanId": "team"}),
        ),
        None,
    );
    assert!(matches!(team, ApiError::Http { .. }));
}

#[test]
fn only_an_https_cmux_link_is_an_upgrade_url() {
    let url = |link: &str| match from_response(
        402,
        &body(json!({"error": "x", "upgradeRequired": true, "upgradeUrl": link})),
        None,
    ) {
        ApiError::PlanRequired { upgrade_url, .. } => upgrade_url,
        other => panic!("{other:?}"),
    };
    assert_eq!(
        url("https://www.cmux.com/pricing").as_deref(),
        Some("https://www.cmux.com/pricing")
    );
    assert_eq!(
        url("https://CMUX.com:443/pricing").as_deref(),
        Some("https://CMUX.com:443/pricing")
    );
    for other in [
        "http://cmux.com/pricing",
        "https://cmux.com.evil.invalid/",
        "https://evilcmux.com/",
        "https://evil.invalid/?cmux.com",
        "https://evil.invalid\\@cmux.com/pricing",
        "https://evil.invalid\\.cmux.com/pricing",
        "https://user@cmux.com/pricing",
        "https://evil.invalid@cmux.com/pricing",
        "https://cmux.com:/pricing",
        "https://cmux.com:443x/pricing",
        "https://cmux.com%2eevil.invalid/",
    ] {
        assert_eq!(url(other), None, "{other}");
    }
}

#[test]
fn every_failure_reads_and_codes() {
    let cases = [
        (ApiError::NotSignedIn {}, "not signed in", "not_signed_in"),
        (
            ApiError::NoBackend { url: "http://127.0.0.1:1".into() },
            "no Cloud backend at http://127.0.0.1:1",
            "unavailable",
        ),
        (ApiError::TimedOut { path: "/api/vm".into() }, "/api/vm timed out", "timeout"),
        (ApiError::Transport { text: "offline".into() }, "offline", "unavailable"),
        (
            ApiError::Decoding { text: "keyNotFound".into() },
            "unexpected response: keyNotFound",
            "bad_response",
        ),
        (
            ApiError::Http { status: 500, code: None, message: None, action: None, trace_id: None },
            "HTTP 500",
            "http_500",
        ),
        (
            ApiError::PlanRequired { message: None, upgrade_url: None, plan: "pro".into() },
            "Cloud machines need cmux Pro.",
            "plan_required",
        ),
        (
            ApiError::PlanRequired { message: None, upgrade_url: None, plan: "max".into() },
            "This needs cmux Max.",
            "plan_required",
        ),
    ];
    for (error, expected_text, expected_code) in cases {
        assert_eq!(text(&error, TRACE), expected_text);
        assert_eq!(code(&error), expected_code);
    }
}

#[test]
fn the_json_is_the_apps_enum_encoding() {
    assert_eq!(serde_json::to_value(ApiError::NotSignedIn {}).unwrap(), json!({"notSignedIn": {}}));
    assert_eq!(
        serde_json::to_value(ApiError::TimedOut { path: "/x".into() }).unwrap(),
        json!({"timedOut": {"_0": "/x"}})
    );
    let plan = ApiError::PlanRequired {
        message: None,
        upgrade_url: Some("https://cmux.com/p".into()),
        plan: "pro".into(),
    };
    assert_eq!(
        serde_json::to_value(&plan).unwrap(),
        json!({"planRequired": {"message": null, "upgradeURL": "https://cmux.com/p", "plan": "pro"}})
    );
    let decoded: ApiError =
        serde_json::from_value(json!({"http": {"status": 409, "code": "c"}})).unwrap();
    assert_eq!(
        decoded,
        ApiError::Http {
            status: 409,
            code: Some("c".into()),
            message: None,
            action: None,
            trace_id: None
        }
    );
}
