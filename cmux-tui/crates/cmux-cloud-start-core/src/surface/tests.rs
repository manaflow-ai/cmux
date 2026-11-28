use super::*;

fn of(code: &str, message: &str) -> Option<(What, Next)> {
    surface(code, message).map(|shown| (shown.what, shown.next))
}

/// Austin's four: the machine did not start, the repo did not clone, the agent has no more usage, and the sign-ins.
#[test]
fn each_of_the_asked_failures_names_what_failed_and_the_next_step() {
    for (code, message, want) in [
        ("cloud.machine_stuck", "", (What::MachineDidNotStart, Next::Retry)),
        ("cloud.start_failed", "create failed", (What::MachineDidNotStart, Next::Retry)),
        (
            "cloud.clone_failed",
            "The repository did not clone on the Cloud machine, so /w/r is not there: fatal: x",
            (What::RepoDidNotClone, Next::RepoAccess),
        ),
        ("agent.limit_reached", "", (What::AgentOutOfUsage, Next::WaitForUsage)),
        ("auth.expired", "", (What::AgentNotSignedIn, Next::AgentSignIn)),
        ("auth.signed_out", "", (What::AgentNotSignedIn, Next::AgentSignIn)),
        ("auth.required", "", (What::CloudSignedOut, Next::CloudSignIn)),
        ("cloud.signed_out", "", (What::CloudSignedOut, Next::CloudSignIn)),
        ("not_signed_in", "", (What::CloudSignedOut, Next::CloudSignIn)),
    ] {
        assert_eq!(of(code, message), Some(want), "{code}");
    }
}

/// The rest of the start's codes that name a cause.
#[test]
fn the_other_named_codes() {
    assert_eq!(of("cloud.folder_missing", ""), Some((What::FolderMissing, Next::PickFolder)));
    assert_eq!(of("cloud.app_not_connected", ""), Some((What::AppNotConnected, Next::OpenApp)));
    assert_eq!(of("cloud.account_changed", ""), Some((What::AccountChanged, Next::CloudSignIn)));
    assert_eq!(of("cloud.machine_cap", ""), Some((What::MachineCap, Next::FreeMachine)));
    assert_eq!(of("cloud.spend_cap", ""), Some((What::SpendCap, Next::Billing)));
    assert_eq!(of("seed.clone_failed", ""), Some((What::RepoDidNotClone, Next::RepoAccess)));
}

/// An agent chat that did not start says why when its words do (usage, sign-in), else that it did not start.
#[test]
fn an_agent_that_did_not_start_says_why_when_its_words_do() {
    let code = "cloud.agent_start_failed";
    assert_eq!(
        of(
            code,
            "the claude chat did not start on machine m: Claude usage limit reached; resets at 5pm"
        ),
        Some((What::AgentOutOfUsage, Next::WaitForUsage))
    );
    assert_eq!(
        of(code, "the codex chat did not start on machine m: Not logged in. Run codex login"),
        Some((What::AgentNotSignedIn, Next::AgentSignIn))
    );
    assert_eq!(
        of(code, "the claude chat did not start on machine m: exited 1"),
        Some((What::AgentDidNotStart, Next::Retry))
    );
}

/// A code with no cause of its own (the pane's catch-all, an unknown one) is read from its words.
#[test]
fn a_generic_failure_is_read_from_its_words() {
    for code in ["", "cloud_start_failed", "chat.turn_failed", "unavailable"] {
        assert_eq!(
            of(code, "You've hit your limit · resets 3am"),
            Some((What::AgentOutOfUsage, Next::WaitForUsage)),
            "{code}"
        );
        assert_eq!(
            of(code, "API Error: 429 rate_limit_error"),
            Some((What::AgentRateLimited, Next::WaitThenRetry)),
            "{code}"
        );
        assert_eq!(
            of(code, "Invalid API key · Please run /login"),
            Some((What::AgentNotSignedIn, Next::AgentSignIn)),
            "{code}"
        );
        assert_eq!(
            of(code, "remote: Repository not found."),
            Some((What::RepoDidNotClone, Next::RepoAccess)),
            "{code}"
        );
        assert_eq!(of(code, "something else broke"), None, "{code}");
    }
}

/// The app reads it as JSON (op `cloud_start_pane_surface`).
#[test]
fn surfaced_json() {
    let shown = serde_json::to_value(surface("cloud.clone_failed", "")).unwrap();
    assert_eq!(shown, serde_json::json!({"what": "repoDidNotClone", "next": "repoAccess"}));
    assert_eq!(serde_json::to_value(surface("x", "y")).unwrap(), serde_json::Value::Null);
}
