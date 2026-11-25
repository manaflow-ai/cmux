use super::*;

#[test]
fn display_names_the_next_step_and_retries_only_retryable_failures() {
    for error in [CloudError::SignedOut, CloudError::SessionExpired, CloudError::Unauthenticated] {
        assert!(error.to_string().contains("cmux login"));
    }
    for retryable in [false, true] {
        let error = CloudError::Rejected {
            code: "denied".into(),
            message: "scope is missing".into(),
            retryable,
        };
        let message = error.to_string();
        assert!(message.contains("scope is missing"));
        assert!(message.contains("cmux cloud diagnostics"));
        assert_eq!(message.contains("retry"), retryable, "{message}");
    }
    let rate_limited = CloudError::Rejected {
        code: "rate_limited".into(),
        message: "HTTP 429".into(),
        retryable: true,
    };
    assert!(rate_limited.to_string().contains("retry the request"));
    // The outcome of a mutation is unknown: never advise a blind resend.
    let unavailable = CloudError::Unavailable("timeout".into()).to_string();
    assert!(!unavailable.contains("retry"), "{unavailable}");
    assert!(unavailable.contains("check the conversation before resending"));
    assert!(unavailable.contains("cmux cloud diagnostics"));
    assert!(CloudError::BadRequest("missing id".into()).to_string().contains("cmux --help"));
}
