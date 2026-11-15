//! The create's retry rules (moved from the app's `CloudCreateRetryKeyTests` and
//! `CloudMachineCapTests`).

use super::*;

#[test]
fn a_refusal_that_made_no_machine_gives_the_retry_a_new_key() {
    for code in [
        "cmux.cloud.quota_exceeded",
        "cloud.quota.exceeded",
        "cloud.quota.vm_limit",
        "cmux.cloud.spend_cap_reached",
        "cloud.spend_cap.reached",
        "cmux.cloud.member_budget_reached",
        "cloud.member_budget.reached",
        "cmux.cloud.plan_required",
        "cmux.cloud.size_locked",
        "cmux.cloud.approval_denied",
        "cmux.cloud.approval_expired",
        "approval.expired",
        "cmux.cloud.secrets_unavailable",
        "cloud.environment.secrets_unavailable",
        "cmux.cloud.no_snapshot_configured",
        "cmux.cloud.not_found",
    ] {
        assert!(is_definitive_refusal(code), "{code}");
    }
    for code in [
        "cmux.cloud.approval_pending",
        "cmux.cloud.relay_unavailable",
        "cmux.cloud.bad_response",
        "cmux.cloud.failed",
        "cmux.cloud.rate_limited",
        INDETERMINATE,
    ] {
        assert!(!is_definitive_refusal(code), "an uncertain outcome lost its key: {code}");
    }
}

#[test]
fn a_retry_stays_with_the_first_sends_team_and_is_refused_in_another() {
    let unsent = TeamRequest { current: "team_b".into(), was_sent: false, first: None };
    assert_eq!(
        create_team(&unsent).as_deref(),
        Some("team_b"),
        "an unsent create takes the current team"
    );
    let named =
        TeamRequest { current: "team_b".into(), was_sent: false, first: Some("team_a".into()) };
    assert_eq!(
        create_team(&named).as_deref(),
        Some("team_b"),
        "a team that was never sent to binds nothing"
    );
    let same =
        TeamRequest { current: "team_a".into(), was_sent: true, first: Some("team_a".into()) };
    assert_eq!(create_team(&same).as_deref(), Some("team_a"));
    let other =
        TeamRequest { current: "team_b".into(), was_sent: true, first: Some("team_a".into()) };
    assert_eq!(create_team(&other), None);
    let no_team = TeamRequest { current: "team_b".into(), was_sent: true, first: None };
    assert_eq!(create_team(&no_team).as_deref(), Some("team_b"));
}

#[test]
fn a_pause_asks_again_only_while_indeterminate_and_within_its_attempts() {
    assert!(power_retries(INDETERMINATE, 1, 3) && power_retries(INDETERMINATE, 2, 3));
    assert!(!power_retries(INDETERMINATE, 3, 3), "three attempts in all");
    assert!(!power_retries("cmux.cloud.not_running", 1, 3), "any other error ends it at once");
    assert!(!power_retries(INDETERMINATE, 1, 0), "at least one attempt, never a retry past it");
}
