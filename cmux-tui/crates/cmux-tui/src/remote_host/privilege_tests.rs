#[test]
fn root_never_runs_remote_host_listener() {
    assert!(super::require_safe_host_user_for("enable", 0).is_err());
    assert!(super::require_safe_host_user_for("serve", 0).is_err());
    assert!(super::require_safe_host_user_for("serve-detached", 0).is_err());
    assert!(super::require_safe_host_user_for("status", 0).is_ok());
    assert!(super::require_safe_host_user_for("serve", 501).is_ok());
}
