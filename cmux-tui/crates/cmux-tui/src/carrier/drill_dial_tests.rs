use super::mux_open_failure;

/// A session whose resume gave up says why its last resume failed, as codes,
/// after the closed connection: the probe's row then names the step.
#[test]
fn a_closed_session_names_its_last_resume_failure() {
    let last = "transport provider failed: all reconnect route providers failed: \
                ssh://cmux@100.64.0.7: transport provider failed: SSH bootstrap failed for \
                reconnect route ssh://cmux@100.64.0.7: exit 255";
    let text =
        mux_open_failure("service transport failed: connection is closed", Some(last), Some("ssh"));
    assert_eq!(
        text,
        "the daemon did not open a mux control stream: service transport failed: connection is closed \
         (last resume: why=ssh_bootstrap)"
    );
    assert!(!text.contains("100.64"), "{text}");
}

/// No failed resume: the text is the open's own.
#[test]
fn a_session_without_a_failed_resume_says_the_open_only() {
    assert_eq!(
        mux_open_failure("service transport failed: connection is closed", None, Some("ssh")),
        "the daemon did not open a mux control stream: service transport failed: connection is closed"
    );
}
