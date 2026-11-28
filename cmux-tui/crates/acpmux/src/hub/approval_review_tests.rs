//! Tests of `approval_review.rs` (RFD 0158 §14).

use super::approval_review::*;
use crate::config::PermissionPolicy;
use serde_json::json;
use std::path::Path;

#[test]
fn approval_review_is_off_unless_switched_on() {
    assert!(!enabled_with(None, None));
    let on = json!({"agents": {"harnessMagic": {"approvalReview": {"enabled": true}}}});
    let off = json!({"agents": {"harnessMagic": {"approvalReview": {"enabled": false}}}});
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&off), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(Some(&off), Some("1")));
    assert!(!enabled_with(Some(&json!({})), Some("maybe")));
    assert_eq!(super::harness_magic::setting_key(FEATURE), SETTING_ENABLED);
    assert_eq!(super::harness_magic::env_key(FEATURE), KILL_ENV);
    assert!(super::harness_magic::FEATURES.iter().any(|f| f.name == FEATURE));
    assert!(super::harness_magic::FEATURES.iter().any(|f| f.name == "outputCaps"));
}

#[test]
fn approval_review_only_a_clear_allow_allows() {
    assert_eq!(parse("ALLOW"), Verdict::Allow);
    assert_eq!(parse("  allow.\n"), Verdict::Allow);
    assert_eq!(parse("Thinking it over.\n\n**ALLOW**\n"), Verdict::Allow);
    for text in ["ASK", "", "ALLOW?", "I would ALLOW this", "ALLOW\nASK", "DENY", "allowed"] {
        assert_eq!(parse(text), Verdict::Ask, "{text:?}");
    }
}

#[test]
fn approval_review_looks_only_at_what_the_policy_leaves_to_the_person() {
    use PermissionPolicy::*;
    assert!(eligible(Ask, false, false, false));
    assert!(eligible(ApproveReads, false, false, false));
    assert!(eligible(ApproveEdits, false, false, false));
    for p in [ApproveAll, DenyAll, Review] {
        assert!(!eligible(p, false, false, false), "{p:?}");
    }
    assert!(!eligible(Ask, true, false, false), "a rule decided");
    assert!(!eligible(Ask, false, true, false), "the policy answered");
    assert!(!eligible(Ask, false, false, true), "a question or external request");
    assert!(policy_answers(ApproveReads, "read"));
    assert!(!policy_answers(ApproveReads, "edit"));
    assert!(policy_answers(ApproveEdits, "edit"));
    assert!(!policy_answers(ApproveEdits, "execute"));
    assert!(!policy_answers(Ask, "read"));
}

fn request(command: &str) -> serde_json::Value {
    json!({
        "toolCall": {"kind": "execute", "title": command, "rawInput": {"command": command},
                     "_meta": {"claude": {"tool": "Bash"}}},
        "options": [
            {"optionId": "allow_once", "kind": "allow_once"},
            {"optionId": "reject_once", "kind": "reject_once"}
        ]
    })
}

#[test]
fn approval_review_brief_names_the_call_and_caps_its_input() {
    let b = brief(&request("cargo test -p acpmux"), Path::new("/w/repo"));
    assert!(b.contains("/w/repo") && b.contains("tool: Bash") && b.contains("kind: execute"));
    assert!(b.contains("cargo test -p acpmux") && b.contains("ALLOW or ASK"));
    let long = brief(&request(&"é".repeat(10_000)), Path::new("/w"));
    assert!(long.len() < 8000 && long.contains("…(cut)"));
    assert!(offers_allow_once(&request("ls")));
    assert!(!offers_allow_once(&json!({"options": [{"kind": "allow_always"}]})));
}

fn sh(script: &str) -> Vec<String> {
    vec!["sh".into(), "-c".into(), script.into()]
}

#[tokio::test]
async fn approval_review_runs_the_reviewer_and_counts_its_verdict() {
    let dir = tempfile::tempdir().unwrap();
    let req = request("cargo fmt");
    // The brief arrives on stdin.
    let allow =
        review_with(sh("grep -q 'cargo fmt' && echo ALLOW || echo ASK"), &req, dir.path()).await;
    assert_eq!(allow.verdict, Verdict::Allow);
    let ask = review_with(sh("cat >/dev/null; echo ASK"), &req, dir.path()).await;
    assert_eq!(ask.verdict, Verdict::Ask);
    // A reviewer that fails, or is missing, sends the prompt to the person.
    let failed = review_with(sh("echo ALLOW; exit 3"), &req, dir.path()).await;
    assert_eq!(failed.verdict, Verdict::Ask);
    let missing =
        review_with(vec!["/nonexistent/approval-reviewer".into()], &req, dir.path()).await;
    assert_eq!(missing.verdict, Verdict::Ask);
    // Its own prompts are never reviewed: the switch is off in its environment.
    let env = review_with(
        sh(&format!("cat >/dev/null; [ \"${KILL_ENV}\" = 0 ] && echo ALLOW")),
        &req,
        dir.path(),
    )
    .await;
    assert_eq!(env.verdict, Verdict::Allow);
    let c = counts();
    assert!(c["reviewed"].as_u64().unwrap() >= 5);
    assert!(c["allowed"].as_u64().unwrap() >= 2 && c["toPerson"].as_u64().unwrap() >= 3);
    assert_eq!(allow.record()["verdict"], "allow");
}

#[test]
fn approval_review_defaults_to_a_cheap_model() {
    let argv = command_with(None);
    assert_eq!(argv[..4], ["claude", "-p", "--model", "haiku"]);
    let doc =
        json!({"agents": {"harnessMagic": {"approvalReview": {"command": ["my-review", "-q"]}}}});
    assert_eq!(command_with(Some(&doc)), ["my-review", "-q"]);
}
