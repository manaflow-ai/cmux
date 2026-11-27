use super::*;

fn pr() -> Value {
    json!({"url":"https://github.com/o/r/pull/7", "number":7,
        "headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "state":"OPEN",
        "isDraft":false, "statusCheckRollup":[]})
}

#[test]
fn changed_head_or_repository_never_gets_context_for_the_old_target() {
    let v = pr();
    assert!(verify(&v, text(&v, "url"), Some(text(&v, "headRefOid"))).is_ok());
    for head in ["", "aaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] {
        assert!(verify(&v, text(&v, "url"), Some(head)).is_err());
    }
    assert!(verify(&v, "https://github.com/other/repo/pull/7", None).is_err());
}

#[test]
fn a_job_url_cannot_redirect_the_read_to_another_repo_or_host() {
    assert_eq!(job_id("https://github.com/o/r/actions/runs/2/job/3?pr=7", "o/r"), Some(3));
    for url in [
        "https://github.com/other/r/actions/runs/2/job/3",
        "https://evil.example/o/r/actions/runs/2/job/3",
        "https://github.com/o/r/actions/runs/2/job/3/extra",
        "https://github.com/o/r/actions/runs/2/job/--help",
    ] {
        assert_eq!(job_id(url, "o/r"), None);
    }
    assert!(target("https://evil.example/o/r/pull/7").is_err());
    assert!(target("https://github.com/o/r/pull/7/extra").is_err());
}

#[test]
fn incomplete_checks_do_not_appear_green() {
    for check in [
        json!({"context":"ci","state":"UNKNOWN"}),
        json!({"name":"ci","status":"COMPLETED","conclusion":""}),
        json!({"name":"ci","status":"IN_PROGRESS","conclusion":"SUCCESS"}),
    ] {
        assert_eq!(check_state(&check), "pending");
    }
    let mut v = pr();
    v["statusCheckRollup"] = json!([{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]);
    assert_eq!(header(&v)["checks"]["state"], "failing");
    assert_eq!(header(&v)["headSha"], v["headRefOid"]);
}

#[test]
fn unresolved_outdated_threads_are_kept_and_resolved_threads_are_excluded() {
    let threads = json!([
        {"isResolved":false,"isOutdated":true,"path":"old.rs","comments":{
            "pageInfo":{"hasNextPage":false},"nodes":[{"author":{"login":"reviewer"},"body":"still needs fixing","url":"https://github.com/o/r/pull/7#r1"}]}},
        {"isResolved":true,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"already resolved"}]}}
    ]);
    let mut prompt = String::new();
    assert_eq!(append_threads(&mut prompt, rows(&threads)).unwrap(), 1);
    assert!(prompt.contains("still needs fixing"));
    assert!(prompt.contains("outdated, unresolved"));
    assert!(!prompt.contains("already resolved"));
}

#[test]
fn partial_review_context_is_refused_instead_of_silently_dropped() {
    let threads = json!([{"isResolved":false,"comments":{"pageInfo":{"hasNextPage":true}}}]);
    assert!(append_threads(&mut String::new(), rows(&threads)).is_err());
    let mut prompt = "a".repeat(PROMPT_LIMIT);
    assert!(append(&mut prompt, "b").is_err());
}

#[test]
fn missing_thread_state_or_comment_body_refuses_partial_context() {
    for thread in [
        json!({"comments":{"nodes":[]}}),
        json!({"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}),
        json!({"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"url":"https://github.com/o/r/pull/7#r1"}]}}),
    ] {
        assert!(append_threads(&mut String::new(), &[thread]).is_err());
    }
}
