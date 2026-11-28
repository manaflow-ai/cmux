use super::run_hook;

#[test]
fn hook_gets_the_url_and_callers_and_may_print_a_target() {
    let printed = run_hook(
        r#"read -r line; [ "$line" = "$CMUX_LINK_URL" ] || exit 9; case "$CMUX_LINK_CALLERS" in *aws*) echo "chrome@Work" ;; *) echo system ;; esac"#,
        "https://signin.aws.amazon.com/?state=x",
        "python3,aws,zsh",
    );
    assert_eq!(printed, Ok(Some("chrome@Work".to_owned())));
    assert_eq!(run_hook("echo system", "https://a.example/", "gh"), Ok(Some("system".to_owned())));
}

#[test]
fn hook_that_opens_the_url_itself_prints_nothing() {
    assert_eq!(run_hook("true", "https://a.example/", ""), Ok(None));
    assert_eq!(run_hook("printf '\\n  \\n'", "https://a.example/", ""), Ok(None));
}

#[test]
fn failing_or_looping_hooks_fail_without_echoing_the_url() {
    let failed = run_hook("exit 3", "https://a.example/?token=SECRET", "").unwrap_err();
    assert!(!failed.contains("SECRET"), "{failed}");
    assert!(run_hook("echo command:other", "https://a.example/", "").is_err());
}
