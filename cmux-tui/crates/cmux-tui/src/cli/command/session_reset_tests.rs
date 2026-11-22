use super::*;

#[test]
fn reset_failure_advice_classifies_fingerprint_race_as_state_changed() {
    let advice = reset_failure_advice(&anyhow::anyhow!(
        "reset path changed during fingerprint: /tmp/cmux-state/registry"
    ));
    assert_eq!(advice.code, "session.reset_state.state_changed");
    assert!(advice.recovery.contains("rerun the preview"), "{}", advice.recovery);
}

#[test]
fn reset_failure_advice_classifies_confirmation_scan_limit() {
    let advice = reset_failure_advice(&anyhow::anyhow!(
        "reset confirmation scan exceeds 64 paths; scoped state is too large"
    ));
    assert_eq!(advice.code, "session.reset_state.state_too_large");
    assert!(advice.recovery.contains("reduce the scoped saved state"), "{}", advice.recovery);
}

#[test]
fn reset_failure_advice_classifies_unsupported_checked_deletion() {
    let advice = reset_failure_advice(&anyhow::anyhow!(
        "safe saved-state reset is not supported on this platform because cmux cannot verify saved state during deletion"
    ));
    assert_eq!(advice.code, "session.reset_state.unsupported");
    assert!(advice.recovery.contains("supported platform build"), "{}", advice.recovery);
}

#[test]
fn reset_failure_advice_ignores_marker_text_inside_paths() {
    let advice = reset_failure_advice(&anyhow::anyhow!(
        "workspace state root is not a directory: /tmp/already owned by another daemon"
    ));
    assert_eq!(advice.code, "session.reset_state.invalid_state_path");
}
