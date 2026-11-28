use super::*;

fn start(id: &str, command: &str) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute",
           "title": command, "rawInput": {"command": command}, "status": "in_progress"})
}

fn end(id: &str, exit: i64) -> Value {
    json!({"sessionUpdate": "tool_call_update", "toolCallId": id,
           "status": if exit == 0 { "completed" } else { "failed" },
           "rawOutput": {"exit_code": exit}})
}

fn turn(calls: &[(&str, &str, i64)]) -> ClaimRuns {
    let mut runs = ClaimRuns::default();
    for (id, command, exit) in calls {
        runs.observe(&start(id, command));
        // An output delta in between does no work.
        runs.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": id,
                             "content": [{"type": "content", "content": {"type": "text", "text": "..."}}]}));
        runs.observe(&end(id, *exit));
    }
    runs
}

fn verdicts(reply: &str, runs: &ClaimRuns) -> Vec<(String, &'static str, &'static str)> {
    check(reply, runs).into_iter().map(|c| (c.text, c.kind.as_str(), c.verdict)).collect()
}

#[test]
fn a_true_claim_is_backed_by_the_run_that_exited_zero() {
    let runs = turn(&[("t1", "cd cmux-tui && cargo test -p acpmux", 0)]);
    let checks = check("Done. All tests pass.", &runs);
    assert_eq!(checks.len(), 1);
    assert_eq!(checks[0].text, "All tests pass");
    assert_eq!(checks[0].verdict, "backed");
    assert_eq!(checks[0].tool_call_id.as_deref(), Some("t1"));
}

#[test]
fn a_false_claim_is_failed_by_the_run_that_did_not_exit_zero() {
    let runs = turn(&[("b1", "bun run build", 1)]);
    assert_eq!(
        verdicts("I fixed the import and the build succeeds.", &runs),
        vec![("the build succeeds".to_owned(), "build", "failed")]
    );
}

#[test]
fn a_claim_with_no_run_says_so() {
    let runs = turn(&[("r1", "rg TODO src", 0)]);
    assert_eq!(
        verdicts("Lint is clean and the tests pass.", &runs),
        vec![
            ("Lint is clean".to_owned(), "lint", "none"),
            ("the tests pass".to_owned(), "tests", "none"),
        ]
    );
}

#[test]
fn the_last_matching_run_decides_a_claim() {
    // Green first, then red: the claim rides on the red.
    let runs = turn(&[("t1", "pytest", 0), ("e1", "vim x.py", 0), ("t2", "pytest -x", 1)]);
    let checks = check("Tests pass.", &runs);
    assert_eq!(checks[0].verdict, "failed");
    assert_eq!(checks[0].tool_call_id.as_deref(), Some("t2"));
    // Red first, then green: backed by the green.
    let runs = turn(&[("t1", "npm test", 1), ("t2", "npm test", 0)]);
    assert_eq!(check("Tests pass.", &runs)[0].tool_call_id.as_deref(), Some("t2"));
}

#[test]
fn a_hedged_negated_or_planned_claim_gets_no_check() {
    let runs = turn(&[("t1", "cargo test", 1)]);
    for reply in [
        "Tests should pass now.",
        "The tests don't pass yet.",
        "Tests pass locally but CI failed.",
        "Once you merge, the build succeeds.",
        "Let me check that the tests pass.",
        "I'll make sure lint is clean.",
        "```\ntest result: ok. 12 tests passed\n```",
    ] {
        assert!(check(reply, &runs).is_empty(), "{reply}");
    }
}

#[test]
fn a_run_whose_exit_status_hides_the_command_backs_nothing() {
    // `| tail` exits 0 whatever the tests did: no badge, not a green one.
    for command in ["cargo test 2>&1 | tail -20", "cargo test; echo done", "npm test || true"] {
        let runs = turn(&[("t1", command, 0)]);
        assert!(check("All tests pass.", &runs).is_empty(), "{command}");
    }
    // `2>&1` alone and an `&&` chain still speak for the command.
    let runs = turn(&[("t1", "cd web && bun test 2>&1", 0)]);
    assert_eq!(check("All tests pass.", &runs)[0].verdict, "backed");
}

#[test]
fn a_background_command_backs_nothing() {
    let mut runs = ClaimRuns::default();
    runs.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "bg", "kind": "execute",
                         "rawInput": {"command": "cargo test", "run_in_background": true}}));
    runs.observe(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "bg", "status": "completed"}),
    );
    assert_eq!(check("Tests pass.", &runs)[0].verdict, "none");
}

#[test]
fn ran_names_the_command_it_ran() {
    let runs = turn(&[("s1", "python3 scripts/verify-local.py --fast", 0)]);
    let checks = check("I ran `scripts/verify-local.py` and it is green.", &runs);
    assert_eq!(checks.len(), 1);
    assert_eq!((checks[0].kind, checks[0].verdict), (ClaimKind::Ran, "backed"));
    assert_eq!(check("I ran `make doctor`.", &runs)[0].verdict, "none");
}

#[test]
fn every_kind_knows_its_commands() {
    let cases: &[(&str, &str, &str)] = &[
        ("cargo clippy --all-targets -- -D warnings", "Clippy is clean.", "lint"),
        ("bunx tsc --noEmit", "Typecheck passes.", "typecheck"),
        ("bun run typecheck", "No type errors.", "typecheck"),
        ("xcodebuild -scheme cmux build", "It compiles cleanly.", "build"),
        ("go test ./...", "All 42 tests passed.", "tests"),
        ("cmux-ci test -- cargo test -p acpmux", "Tests are green.", "tests"),
        ("./scripts/web-lint.sh", "Lint passes.", "lint"),
        ("FOO=1 timeout 600 make test", "The test suite passes.", "tests"),
    ];
    for (command, reply, kind) in cases {
        let runs = turn(&[("x", command, 0)]);
        assert_eq!(
            verdicts(reply, &runs).into_iter().map(|(_, k, v)| (k, v)).collect::<Vec<_>>(),
            vec![(*kind, "backed")],
            "{command} / {reply}"
        );
    }
}

#[test]
fn codex_argv_reads_its_script() {
    let mut runs = ClaimRuns::default();
    runs.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "kind": "execute",
                         "rawInput": {"command": ["/bin/bash", "-lc", "cargo test"]}}));
    runs.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1",
                         "status": "completed", "rawOutput": {"exit_code": 101}}));
    assert_eq!(check("Tests pass.", &runs)[0].verdict, "failed");
}

#[test]
fn runs_and_claims_stay_bounded() {
    let mut runs = ClaimRuns::default();
    for n in 0..(RUNS * 3) {
        runs.observe(&start(&format!("p{n}"), "cargo test"));
    }
    for n in 0..(RUNS * 3) {
        runs.observe(&end(&format!("p{n}"), 0));
    }
    assert!(runs.pending.len() <= PENDING);
    assert!(runs.runs.len() <= RUNS);
    let reply = (0..40).map(|n| format!("Suite {n} tests pass.")).collect::<Vec<_>>().join(" ");
    assert!(check(&reply, &runs).len() <= MAX_CLAIMS);
}

#[tokio::test]
async fn a_turn_end_logs_its_checks_once_before_turn_end() {
    let cfg = crate::config::Config::default();
    let store = Box::new(crate::store::MemoryStore::default());
    let hub = Hub::new(cfg, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "claims", "name": "claims",
        "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    // Records land in the log of a saved chat only.
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.note_claim_run(&session, &start("t1", "cargo test"));
    hub.note_claim_run(&session, &end("t1", 0));
    session.stream.lock().unwrap().trailing_text = "All tests pass.".into();
    hub.append_claim_checks(&session, "turn-1");
    let page = hub.store.events(&session.id, 0, usize::MAX).unwrap();
    let checks: Vec<_> = page.iter().filter(|e| e.kind == "claim_checks").collect();
    assert_eq!(checks.len(), 1);
    assert_eq!(checks[0].msg["turnId"], "turn-1");
    assert_eq!(checks[0].msg["claims"][0]["verdict"], "backed");
    assert_eq!(checks[0].msg["claims"][0]["toolCallId"], "t1");
    // A new turn forgets the last one's runs.
    hub.reset_claim_runs(&session);
    hub.append_claim_checks(&session, "turn-2");
    let page = hub.store.events(&session.id, 0, usize::MAX).unwrap();
    let last = page.iter().rev().find(|e| e.kind == "claim_checks").unwrap();
    assert_eq!(last.msg["claims"][0]["verdict"], "none");
    hub.shutdown_all().await;
}

#[test]
fn a_chain_with_a_hiding_step_backs_nothing() {
    // Review F2: `|| true` after `&&` still hides the tests' status.
    for command in ["cargo test && echo done || true", "cargo test && cargo build | tee log"] {
        let runs = turn(&[("t1", command, 0)]);
        assert!(check("All tests pass.", &runs).is_empty(), "{command}");
    }
}

#[test]
fn a_failed_chain_does_not_say_which_step_failed() {
    let runs = turn(&[("c1", "cargo test && cargo build", 1)]);
    assert!(check("Tests pass and the build succeeds.", &runs).is_empty());
    // Green, every step of the chain passed.
    let runs = turn(&[("c1", "cargo test && cargo build", 0)]);
    let checks = check("Tests pass and the build succeeds.", &runs);
    assert_eq!(checks.iter().map(|c| c.verdict).collect::<Vec<_>>(), vec!["backed", "backed"]);
}

#[test]
fn every_adapter_reports_its_exit_code() {
    // Review F1: OpenCode's `rawOutput.metadata.exit` and pi's `_meta.terminal_exit`.
    let mut runs = ClaimRuns::default();
    runs.observe(&start("o1", "bun test"));
    runs.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "o1",
                         "status": "completed", "rawOutput": {"metadata": {"exit": 1}}}));
    assert_eq!(check("Tests pass.", &runs)[0].verdict, "failed");
    // pi names its command only in its title.
    let mut runs = ClaimRuns::default();
    runs.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "p1", "kind": "execute",
                         "title": "cargo test", "_meta": {"terminal_info": {"cwd": "/w"}}}));
    runs.observe(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "p1", "status": "completed",
                         "_meta": {"terminal_exit": {"exit_code": 0}}}),
    );
    assert_eq!(check("Tests pass.", &runs)[0].verdict, "backed");
}

#[test]
fn pnpm_run_runs_a_package_script() {
    // Review F5.
    let runs = turn(&[("b1", "pnpm run build", 0)]);
    assert_eq!(check("The build succeeds.", &runs)[0].verdict, "backed");
}

#[test]
fn a_background_step_or_a_build_only_test_run_backs_nothing() {
    // Review of #39244 at 972cdc775d4: `&` mid-chain and `cargo test --no-run`.
    for command in ["cargo test & echo queued", "cargo test --no-run", "cargo test -- --list"] {
        let runs = turn(&[("t1", command, 0)]);
        assert!(check("All tests pass.", &runs).iter().all(|c| c.verdict == "none"), "{command}");
    }
}

#[test]
fn a_failed_chain_blames_its_check_only_past_a_cd() {
    // Review of #39244 at b067810ba44: the failure may be another step's.
    for command in ["cargo test && false", "false && cargo test", "npm ci && npm test"] {
        let runs = turn(&[("c1", command, 1)]);
        assert!(check("All tests pass.", &runs).is_empty(), "{command}");
    }
    let runs = turn(&[("c1", "cd web && bun test", 1)]);
    assert_eq!(check("All tests pass.", &runs)[0].verdict, "failed");
}
