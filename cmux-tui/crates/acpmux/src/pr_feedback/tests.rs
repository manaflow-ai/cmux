use super::*;

fn run(name: &str, workflow: i64, run: i64, conclusion: &str, job: u64) -> Value {
    json!({
        "__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion,
        "databaseId": job,
        "checkSuite": {"workflowRun": {"databaseId": run, "event": "pull_request",
                       "workflow": {"databaseId": workflow, "name": format!("wf{workflow}")}}},
    })
}

fn node(head: Value, base: Value, threads: Value) -> Value {
    json!({
        "url": "https://github.com/octo/app/pull/7", "number": 7, "state": "OPEN",
        "headRefOid": "abc123def4567890", "baseRefName": "main",
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": head}}}}]},
        "baseRef": {"target": {"statusCheckRollup": {"contexts": {"nodes": base}}}},
        "reviewThreads": {"nodes": threads},
    })
}

/// A `gh` that logs its args and answers a job, its log, or the GraphQL fixture.
#[cfg(unix)]
fn fake_gh(dir: &Path, graphql: &Value) -> (Ctx, PathBuf) {
    use std::os::unix::fs::PermissionsExt as _;
    let calls = dir.join("calls");
    let fixture = dir.join("graphql.json");
    std::fs::write(&fixture, json!({"data": {"repository": {"pullRequest": graphql}}}).to_string())
        .unwrap();
    let gh = dir.join("gh");
    std::fs::write(
        &gh,
        format!(
            "#!/bin/sh\necho \"$*\" >> '{calls}'\n\
             case \"$2\" in\n\
             graphql) cat '{fixture}';;\n\
             */logs) printf '2026-11-18T10:00:00.1234567Z ##[group]Run cargo test\\n\
2026-11-18T10:00:01.0000000Z test parse ... FAILED\\n\
2026-11-18T10:00:02.0000000Z ##[error]Process completed with exit code 101.\\n\
2026-11-18T10:00:03.0000000Z Post job cleanup.\\n';;\n\
             *) echo '{{\"status\":\"completed\",\"steps\":[{{\"name\":\"Set up\",\"conclusion\":\"success\"}},{{\"name\":\"Run tests\",\"conclusion\":\"failure\"}}]}}';;\n\
             esac\n",
            calls = calls.display(),
            fixture = fixture.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let state = dir.join("state");
    (Ctx { dir: state, gh: gh.into_os_string() }, calls)
}

#[test]
fn a_red_the_base_tip_shares_is_left_out_and_one_of_another_workflow_is_not() {
    // `test` fails in workflow 1 on both commits; `test` of workflow 2 fails only at the head.
    let head = vec![
        run("test", 1, 10, "FAILURE", 100),
        run("test", 2, 11, "FAILURE", 101),
        run("lint", 1, 10, "SUCCESS", 102),
    ];
    let base = vec![run("test", 1, 5, "FAILURE", 50), run("test", 2, 6, "SUCCESS", 51)];
    let split = classify::split(&head, &base);
    assert_eq!(split.own.len(), 1);
    assert_eq!(classify::workflow_name(split.own[0]).as_deref(), Some("wf2"));
    assert_eq!(split.on_base.len(), 1);
    assert_eq!(classify::workflow_name(split.on_base[0]).as_deref(), Some("wf1"));
}

#[test]
fn a_cancelled_or_superseded_base_run_excuses_nothing() {
    let head = vec![run("build", 1, 10, "FAILURE", 100)];
    // The newest base run of workflow 1 was cancelled: no evidence, so the red stays the head's.
    let cancelled = vec![run("build", 1, 5, "FAILURE", 50), run("build", 1, 6, "CANCELLED", 51)];
    assert_eq!(classify::split(&head, &cancelled).own.len(), 1);
    // A newer base run passed: the older red is superseded, so it excuses nothing either.
    let fixed = vec![run("build", 1, 5, "FAILURE", 50), run("build", 1, 6, "SUCCESS", 51)];
    assert_eq!(classify::split(&head, &fixed).own.len(), 1);
}

#[test]
fn the_head_counts_only_the_newest_run_of_one_check_and_no_skipped_one() {
    // A label event re-ran the workflow: the cancelled older run is not counted as a red.
    let head = vec![
        run("test", 1, 10, "CANCELLED", 100),
        run("test", 1, 12, "SUCCESS", 101),
        run("docs", 1, 12, "SKIPPED", 102),
    ];
    let split = classify::split(&head, &[]);
    assert!(split.own.is_empty() && split.on_base.is_empty() && split.pending == 0);
    let pending = vec![json!({"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS"})];
    assert_eq!(classify::split(&pending, &[]).pending, 1);
    // A commit status has no run: it identifies by its name and matches only another status.
    let status =
        vec![json!({"__typename": "StatusContext", "context": "ci/x", "state": "FAILURE"})];
    let base = vec![json!({"__typename": "StatusContext", "context": "ci/x", "state": "ERROR"})];
    assert_eq!(classify::split(&status, &base).on_base.len(), 1);
}

#[test]
fn a_log_tail_ends_at_the_last_error_without_timestamps_or_cleanup() {
    let log = "2026-11-18T10:00:00.1234567Z ##[group]Run cargo test\n\
               2026-11-18T10:00:01.0000000Z test parse ... FAILED\n\
               2026-11-18T10:00:02.0000000Z ##[error]Process completed with exit code 101.\n\
               2026-11-18T10:00:03.0000000Z Post job cleanup.\n";
    assert_eq!(
        draft::log_tail(log),
        "Run cargo test\ntest parse ... FAILED\n##[error]Process completed with exit code 101."
    );
    let long: String = (0..100).map(|i| format!("line {i}\n")).collect();
    let tail = draft::log_tail(&long);
    assert_eq!(tail.lines().count(), draft::TAIL_LINES);
    assert!(tail.ends_with("line 99"));
}

#[test]
fn the_checks_draft_names_the_left_out_reds_and_why() {
    let pr =
        Pr { repo: "octo/app".into(), number: 7, head: "abc123def456".into(), base: "main".into() };
    let red = Red {
        name: "test".into(),
        workflow: Some("CI".into()),
        url: Some("https://github.com/octo/app/actions/runs/1/job/2".into()),
        step: Some("Run tests".into()),
        log_tail: Some("boom ``` x".into()),
        log_note: None,
    };
    let text = draft::checks(&pr, &[red], &["lint".into(), "e2e".into()], 1).unwrap();
    assert!(text.starts_with("Fix the failing checks on octo/app#7 (head abc123de). This one fails on this branch only:"), "{text}");
    assert!(text.contains("### test (CI)\nFailing step: Run tests\n"), "{text}");
    // The fence is longer than any backtick run in the log.
    assert!(text.contains("````text\nboom ``` x\n````"), "{text}");
    assert!(text.contains("Left out: 2 failing checks that also fail on main's tip, so not this branch's (lint, e2e)."), "{text}");
    assert!(text.contains("1 check is still running."), "{text}");
    assert_eq!(draft::checks(&pr, &[], &["lint".into()], 0), None);
    assert_eq!(
        draft::no_reds(&pr, &["lint".into()], 0),
        "No failing check on octo/app#7 is this branch's own. Left out: 1 failing check that also fails on main's tip, so not this branch's (lint)."
    );
}

#[test]
fn the_comments_draft_quotes_each_unresolved_thread() {
    let pr =
        Pr { repo: "octo/app".into(), number: 7, head: "abc123def456".into(), base: "main".into() };
    let thread = Thread {
        path: Some("src/a.rs".into()),
        line: Some(12),
        url: Some("https://github.com/octo/app/pull/7#discussion_r1".into()),
        outdated: true,
        comments: vec![
            Comment { author: "rev".into(), body: "Rename this.\nIt reads badly.".into() },
            Comment { author: "me".into(), body: "Which name?".into() },
        ],
    };
    let text = draft::comments(&pr, &[thread], 3).unwrap();
    assert!(text.contains("1. `src/a.rs:12` (outdated: the code moved since) https://github.com/octo/app/pull/7#discussion_r1\n"), "{text}");
    assert!(
        text.contains(
            "   > **rev**: Rename this.\n   > It reads badly.\n   > **me**: Which name?\n"
        ),
        "{text}"
    );
    assert!(text.contains("Left out: 3 threads already resolved."), "{text}");
    assert_eq!(draft::no_comments(&pr, 0), "No review comments on octo/app#7.");
}

#[cfg(unix)]
#[test]
fn fetch_reads_once_for_both_kinds_and_keeps_a_finished_jobs_tail() {
    let tmp = tempfile::tempdir().unwrap();
    let threads = json!([
        {"isResolved": false, "isOutdated": false, "path": "a.rs", "line": 3,
         "comments": {"nodes": [{"author": {"login": "rev"}, "body": "Why?", "url": "https://github.com/octo/app/pull/7#r1"}]}},
        {"isResolved": true, "isOutdated": false, "path": "b.rs", "line": 1, "comments": {"nodes": []}},
    ]);
    let pull = node(
        json!([run("test", 1, 10, "FAILURE", 100), run("lint", 2, 11, "FAILURE", 101)]),
        json!([run("lint", 2, 5, "FAILURE", 50)]),
        threads,
    );
    let (ctx, calls) = fake_gh(tmp.path(), &pull);
    let checks =
        fetch(&ctx, None, "https://github.com/octo/app/pull/7", None, Kind::Checks).unwrap();
    assert_eq!(checks["empty"], json!(false));
    assert_eq!(checks["checks"]["onBase"], json!(["lint"]));
    assert_eq!(checks["checks"]["own"][0]["step"], json!("Run tests"));
    assert_eq!(
        checks["checks"]["own"][0]["url"],
        json!("https://github.com/octo/app/actions/runs/10/job/100")
    );
    assert!(checks["draft"].as_str().unwrap().contains("Failing step: Run tests"));
    let comments = fetch(&ctx, None, "7", Some("octo/app"), Kind::Comments).unwrap();
    assert_eq!(comments["comments"]["resolved"], json!(1));
    assert!(comments["draft"].as_str().unwrap().contains("**rev**: Why?"));
    // Again past the GraphQL answer's freshness: the job's tail is read from disk.
    let answer = ctx.dir.join(format!("{}.feedback.json", pr_wait::key("octo/app", "7")));
    std::fs::write(&answer, json!({"at": 0, "data": {}}).to_string()).unwrap();
    fetch(&ctx, None, "7", Some("octo/app"), Kind::Checks).unwrap();
    let made = std::fs::read_to_string(&calls).unwrap();
    let count = |what: &str| made.lines().filter(|l| l.contains(what)).count();
    assert_eq!(count("graphql"), 2, "{made}");
    assert_eq!(count("actions/jobs/100/logs"), 1, "{made}");
    assert_eq!(count("actions/jobs/101"), 0, "a base red's log is never read: {made}");
}

#[cfg(unix)]
#[test]
fn a_rate_limit_the_poller_hit_holds_the_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let (ctx, calls) = fake_gh(tmp.path(), &node(json!([]), json!([]), json!([])));
    std::fs::create_dir_all(&ctx.dir).unwrap();
    let state = ctx.dir.join(format!("{}.json", pr_wait::key("octo/app", "7")));
    let shared = pr_wait::Shared {
        retry_at: pr_wait::now_s() + 600,
        error: Some("GraphQL: API rate limit exceeded".into()),
        ..Default::default()
    };
    pr_wait::write_shared(&state, &shared).unwrap();
    let err = fetch(&ctx, None, "7", Some("octo/app"), Kind::Checks).unwrap_err();
    assert!(err.contains("rate limit"), "{err}");
    assert!(!calls.exists(), "no gh ran");
}
