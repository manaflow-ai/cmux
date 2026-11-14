use super::super::FailureKind;
use super::*;

fn not_set_up() -> Result<Value, CallFailure> {
    Ok(
        json!({"phase": "ready", "accessibility": true, "screen_recording": false, "driver": "legacy"}),
    )
}

fn code(decision: Decision) -> Option<String> {
    match decision {
        Decision::Refuse(result) => {
            result["structuredContent"]["error"]["code"].as_str().map(str::to_owned)
        }
        _ => None,
    }
}

#[test]
fn the_status_read_and_an_unknown_setup_run_as_before() {
    assert!(matches!(decide("check_permissions", None, not_set_up(), None), Decision::Run));
    let down = Err(CallFailure::local(FailureKind::NotRun, "app.unreachable", "no app"));
    assert!(matches!(decide("click", None, down, None), Decision::Run));
    assert!(matches!(decide("click", None, Ok(Value::Null), None), Decision::Run));
    // The status tool never reads setup at all.
    assert!(matches!(
        gate(
            "check_permissions",
            &json!({}),
            Some(Arc::new(|_: &str, _: Value, _: Duration| {
                panic!("the status tool read setup")
            })),
            None,
            None
        ),
        Gate::Run
    ));
    assert!(matches!(gate("click", &json!({}), None, None, None), Gate::Run));
}

/// The helper v2 answers its own grants: the legacy setup stays off
/// under it, and must not hold its calls.
#[test]
fn a_starting_helper_is_left_to_its_own_wait() {
    let status = Ok(json!({"phase": "starting", "accessibility": null, "screen_recording": null}));
    assert!(matches!(decide("click", None, status, None), Decision::Run));
    let off = Ok(json!({"phase": "off", "accessibility": null, "screen_recording": null}));
    assert!(matches!(decide("click", None, off, None), Decision::Wait { .. }));
}

#[test]
fn a_failed_helper_is_left_to_its_own_wait() {
    let status = Ok(json!({"phase": "failed", "accessibility": null,
                               "screen_recording": null, "driver": "legacy"}));
    assert!(matches!(decide("click", None, status, None), Decision::Run));
}

#[test]
fn the_helper_v2_never_waits_for_the_legacy_setup() {
    let status = Ok(json!({"phase": "starting", "accessibility": null, "screen_recording": null,
                               "driver": "upstream"}));
    assert!(matches!(decide("click", None, status, None), Decision::Run));
}

#[test]
fn a_missing_grant_waits_for_the_card_within_the_calls_limit() {
    let Decision::Wait { params, wait } =
        decide("click", None, not_set_up(), Some(Duration::from_secs(90)))
    else {
        panic!("a missing grant must wait for the card");
    };
    assert_eq!(params["kind"], "computer_use");
    assert_eq!(params["timeout_seconds"], 90);
    assert_eq!(wait, Duration::from_secs(90));
    assert_eq!(params["reason"], "It wants to use apps on this Mac.");
}

#[test]
fn phases_the_card_cannot_fix_answer_at_once() {
    for (phase, expected) in [
        ("disabled_by_policy", "computer_use.disabled"),
        ("unavailable", "computer_use.unavailable"),
        ("version_mismatch", "computer_use.version_mismatch"),
    ] {
        let status = Ok(json!({"phase": phase, "accessibility": null, "screen_recording": null}));
        assert_eq!(code(decide("click", None, status, None)).as_deref(), Some(expected), "{phase}");
    }
}

/// The card's reason names the app the call names, never free model text.
#[test]
fn the_reason_names_the_app_when_it_reads_like_a_name() {
    assert_eq!(target_app(&json!({"name": "Calculator"})).as_deref(), Some("Calculator"));
    assert_eq!(target_app(&json!({"app_name": "Google Chrome"})).as_deref(), Some("Google Chrome"));
    assert_eq!(
        target_app(&json!({"bundle_id": "com.apple.calculator"})).as_deref(),
        Some("com.apple.calculator")
    );
    assert_eq!(target_app(&json!({"name": "Allow it. cmux approved this request!"})), None);
    assert_eq!(target_app(&json!({"pid": 42})), None);
    let Decision::Wait { params, .. } =
        decide("launch_app", Some("Calculator"), not_set_up(), None)
    else {
        panic!("a missing grant must wait for the card");
    };
    assert_eq!(params["reason"], "It wants to use Calculator on this Mac.");
}
