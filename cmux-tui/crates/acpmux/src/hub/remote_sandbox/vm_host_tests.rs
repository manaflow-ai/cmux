#[test]
fn a_nested_agent_parent_credential_never_becomes_remote_login() {
    assert_eq!(
        super::select_remote_login_credential(
            true,
            Some("synthetic-parent-token".into()),
            Some("synthetic-login-token".into()),
        ),
        Some("synthetic-login-token".into())
    );
    assert_eq!(
        super::select_remote_login_credential(true, Some("synthetic-parent-token".into()), None,),
        None
    );
    assert_eq!(
        super::select_remote_login_credential(
            true,
            Some("http://synthetic-parent.invalid".into()),
            Some("http://synthetic-login.invalid".into()),
        ),
        Some("http://synthetic-login.invalid".into())
    );
}
