use super::*;

#[test]
fn a_prune_keeps_a_pull_request_noted_after_the_snapshot() {
    let index = Index::default();
    index.note_pr("s1", "https://github.com/o/r/pull/1", 0);
    // A read's snapshot saw only the expired one; a new one is noted before its prune.
    let now = PR_WINDOW_MS + 10;
    index.note_pr("s1", "https://github.com/o/r/pull/2", now);
    index.prune_prs("s1", now, false);
    assert_eq!(index.sizes().1, 1);
    assert_eq!(index.lock().prs["s1"].len(), 1);
    assert_eq!(index.lock().prs["s1"][0].url, "https://github.com/o/r/pull/2");
    index.prune_prs("s1", now + PR_WINDOW_MS + 1, false);
    assert_eq!(index.sizes().1, 0);
}

#[test]
fn kinds_are_plan_question_or_approval() {
    let plan =
        json!({"toolCall": {"kind": "other", "_meta": {"claude": {"tool": "ExitPlanMode"}}}});
    assert_eq!(Kind::of(&plan), Kind::Plan);
    let gemini =
        json!({"toolCall": {"kind": "other", "title": "Requesting plan approval for: plans/p.md"}});
    assert_eq!(Kind::of(&gemini), Kind::Plan);
    let question = json!({"toolCall": {"kind": "other", "_meta": {"claude": {"tool": "AskUserQuestion"}},
            "rawInput": {"questions": [{"question": "Which?", "options": [{"label": "a"}]}]}}});
    assert_eq!(Kind::of(&question), Kind::Question);
    assert_eq!(ask_text(Kind::Question, &question), "Which?");
    let tool = json!({"toolCall": {"kind": "execute", "title": "Run ls",
            "rawInput": {"command": "ls -la"}}, "options": [{"optionId": "a", "name": "Allow", "kind": "allow_once"}]});
    assert_eq!(Kind::of(&tool), Kind::Approval);
    assert_eq!(ask_text(Kind::Approval, &tool), "Run ls");
    assert_eq!(detail(&tool).as_deref(), Some("ls -la"));
}

#[test]
fn an_ask_is_one_masked_line() {
    let secret = "ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k";
    let tool =
        json!({"toolCall": {"kind": "execute", "title": format!("Run\n  curl -H {secret}")}});
    let ask = ask_text(Kind::Approval, &tool);
    assert!(!ask.contains('\n'), "{ask}");
    assert!(!ask.contains(secret), "{ask}");
    assert!(ask.chars().count() <= ASK_CHARS + 1);
}

#[test]
fn impact_and_score_follow_the_documented_formula() {
    let (i, r) = impact(true, Weight::default());
    assert_eq!((i, r), (BASE_ASK, vec!["blocksTurn".to_owned()]));
    let w = Weight { queued: 7, cost_usd: 3.5, subsessions: 2 };
    let (i, r) = impact(true, w);
    assert_eq!(i, BASE_ASK + PER_QUEUED * MAX_COUNTED + PER_DOLLAR * 3 + PER_SUBSESSION * 2);
    assert_eq!(r, vec!["blocksTurn", "queuedPrompts:7", "costUsd:3.50", "subsessions:2"]);
    assert_eq!(impact(false, Weight::default()).0, BASE_PR);
    assert_eq!(score(50, 0), 50.0);
    assert_eq!(score(50, 3_600_000), 100.0);
    assert_eq!(score(50, 10 * AGE_CAP_MS), score(50, AGE_CAP_MS));
}

#[test]
fn the_queue_sorts_by_score_then_age() {
    let mut items = vec![
        json!({"id": "new-low", "score": 20.0, "at": 5}),
        json!({"id": "high", "score": 90.0, "at": 9}),
        json!({"id": "old-low", "score": 20.0, "at": 1}),
    ];
    sort_items(&mut items, 2);
    let ids: Vec<_> = items.iter().map(|i| i["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["high", "old-low"]);
}

#[test]
fn vendors_follow_the_family_or_the_models_provider() {
    assert_eq!(vendor(Some("claude"), "claude", None), "anthropic");
    assert_eq!(vendor(Some("codex"), "codex", None), "openai");
    assert_eq!(vendor(None, "gemini", None), "google");
    assert_eq!(vendor(Some("opencode"), "opencode", Some("openrouter/x")), "openrouter");
    assert_eq!(vendor(Some("pi"), "pi", None), "pi");
    assert_eq!(vendor(Some("grok"), "grok", None), "grok");
}

#[test]
fn pr_labels_name_the_repository_and_number() {
    assert_eq!(pr_label("https://github.com/o/r/pull/12"), "o/r#12");
    assert_eq!(pr_label("weird"), "weird");
}
