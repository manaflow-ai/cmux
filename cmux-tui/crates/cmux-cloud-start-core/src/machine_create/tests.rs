//! The create's retry rules (moved from the app's `CloudCreateRetryKeyTests` and
//! `CloudMachineCapTests`).

use super::*;
use serde_json::json;

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
fn a_create_whose_machine_was_gone_before_it_answered_is_asked_again_with_a_new_key() {
    let words = "no such machine in this team";
    assert!(create_machine_gone_retries("cmux.cloud.not_found", words, false, 1));
    assert!(create_machine_gone_retries("cloud.machine.not_found", "", true, 1));
    assert!(create_machine_gone_retries(
        "cmux.cloud.not_found",
        "No such machine in this team",
        false,
        2
    ));
    assert!(
        !create_machine_gone_retries("cmux.cloud.not_found", words, true, MACHINE_GONE_RETRIES + 1),
        "bounded"
    );
    assert!(
        !create_machine_gone_retries("cmux.cloud.not_found", "no such snapshot", false, 1),
        "a gone snapshot stays gone"
    );
    assert!(!create_machine_gone_retries("cloud.snapshot.not_found", words, true, 1));
    assert!(!create_machine_gone_retries("cloud.environment.not_found", words, true, 1));
    assert!(!create_machine_gone_retries("cmux.cloud.quota_exceeded", words, true, 1));
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

#[test]
fn a_create_that_passed_over_every_spare_says_why_by_reason_and_count() {
    let answer = json!({
        "machine": {"id": "vm_01HXYZabc9", "title": "box"},
        "spare_skips": {"restarting": 1, "image": 2},
        "spare_fallback": "all_skipped",
        "spare_skipped": [
            {"id": "vm_01HXYZspare1", "reason": "image"},
            {"id": "vm_01HXYZspare2", "reason": "image"},
            {"id": null, "reason": "restarting"},
        ],
        "spare_skipped_omitted": 4,
    });
    assert_eq!(
        spare_note(&answer),
        r#"spare_fallback=all_skipped spare_skips={"image":2,"restarting":1} spare_skipped=3 spare_skipped_omitted=4"#
    );
}

#[test]
fn a_create_that_took_a_spare_or_made_no_claim_attempt_says_so() {
    assert_eq!(
        spare_note(&json!({"machine": {}, "spare_skips": {}, "spare_fallback": null})),
        "spare_fallback=null spare_skips={}"
    );
    assert_eq!(
        spare_note(&json!({"machine": {}, "spare_fallback": "no_spare"})),
        "spare_fallback=no_spare"
    );
    assert_eq!(spare_note(&json!({"machine": {"id": "vm_1"}})), "spare=none");
    assert_eq!(spare_note(&json!("not an object")), "spare=none");
}

#[test]
fn the_note_carries_only_reason_codes_and_counts() {
    let answer = json!({
        "spare_fallback": "Bearer sk-secret",
        "spare_skips": {
            "image": 1, "vm_private id": 1, "vm_01HXYZabc9": 2, "user@example.com": 1,
            "stale": -1, "orphan": 1.5, "shape": "two", "state_paused": 3,
        },
        "spare_skipped": "free text",
        "spare_skipped_omitted": "many",
    });
    let note = spare_note(&answer);
    assert_eq!(note, r#"spare_fallback=? spare_skips={"image":1,"state_paused":3}"#);
    for leaked in ["Bearer", "sk-secret", "private", "vm_01", "example", "free text", "many"] {
        assert!(!note.contains(leaked), "{leaked} reached the note: {note}");
    }
    assert_eq!(spare_note(&json!({"spare_fallback": "vm_01HXYZabc9"})), "spare_fallback=?");
}
