use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn parsed(words: &[&str]) -> Result<Invocation, UsageError> {
    let all = args(words);
    let rest = split(&all).expect("a sandboxed run");
    parse(rest)
}

fn request(task: &str) -> Request {
    Request { task: task.to_owned(), agent: None, image: None, timeout_secs: 600 }
}

#[test]
fn only_a_sandboxed_run_routes_here_so_code_mode_scripts_keep_working() {
    assert!(split(&args(&["run", "script.ts"])).is_none());
    assert!(split(&args(&["run", "script.ts", "--", "--sandboxed"])).is_none());
    assert!(split(&args(&["workspace", "list"])).is_none());
    assert!(split(&args(&["run", "--sandboxed", "hi"])).is_some());
    assert!(split(&args(&["run", "hi", "--sandboxed"])).is_some());
}

#[test]
fn the_task_is_every_word_and_flags_take_both_forms() {
    assert_eq!(
        parsed(&["run", "--sandboxed", "list", "the", "TODOs"]).unwrap(),
        Invocation::Run(request("list the TODOs"))
    );
    assert_eq!(
        parsed(&[
            "run",
            "--sandboxed",
            "--agent",
            "claude",
            "--timeout=60",
            "--image",
            "sh-1",
            "go"
        ])
        .unwrap(),
        Invocation::Run(Request {
            task: "go".into(),
            agent: Some("claude".into()),
            image: Some("sh-1".into()),
            timeout_secs: 60,
        })
    );
    // After `--` everything is task text, flags included.
    assert_eq!(
        parsed(&["run", "--sandboxed", "--", "--agent", "x"]).unwrap(),
        Invocation::Run(request("--agent x"))
    );
    assert_eq!(parsed(&["run", "--sandboxed", "--help"]).unwrap(), Invocation::Help);
}

#[test]
fn a_missing_task_or_an_out_of_range_timeout_is_a_usage_error() {
    assert!(parsed(&["run", "--sandboxed"]).is_err());
    assert!(parsed(&["run", "--sandboxed", "   "]).is_err());
    assert!(parsed(&["run", "--sandboxed", "--timeout", "10", "x"]).is_err());
    assert!(parsed(&["run", "--sandboxed", "--timeout", "721", "x"]).is_err());
    assert!(parsed(&["run", "--sandboxed", "--timeout", "ten", "x"]).is_err());
    assert!(parsed(&["run", "--sandboxed", "--agent"]).is_err());
    assert!(parsed(&["run", "--sandboxed", "--persistent", "x"]).is_err());
    // The server's 16,000-character limit is checked here, with a localized message.
    let long = "x".repeat(16_001);
    assert!(parsed(&["run", "--sandboxed", &long]).is_err());
    assert!(parsed(&["run", "--sandboxed", &"x".repeat(16_000)]).is_ok());
    // Counted as the server counts: 8,001 emoji are 16,002 UTF-16 units.
    assert!(parsed(&["run", "--sandboxed", &"\u{1F600}".repeat(8_001)]).is_err());
}

#[test]
fn create_params_carry_the_task_timeout_key_and_only_the_options_given() {
    let params = create_params(&request("hi"), "key-1");
    assert_eq!(
        Value::Object(params),
        json!({ "task": "hi", "timeoutMs": 600_000, "idempotencyKey": "key-1" })
    );
    let mut with = request("hi");
    with.agent = Some("pi".into());
    with.image = Some("sh-1".into());
    let params = create_params(&with, "key-2");
    assert_eq!(params.get("agent"), Some(&json!("pi")));
    assert_eq!(params.get("image"), Some(&json!("sh-1")));
}

#[test]
fn the_receipt_reads_reply_first_then_status_time_cost_and_cleanup() {
    // English whatever the process locale: the assertions below are the English text.
    let messages = &crate::localization::catalog_for_locale("en").sandbox_run;
    let receipt = json!({
        "status": "succeeded",
        "exitCode": 0,
        "timedOut": false,
        "reply": "3 TODOs found",
        "error": null,
        "artifacts": [{ "name": "report.md", "sizeBytes": 120 }],
        "timings": { "totalMs": 95_000, "bootMs": 30_000 },
        "cost": { "vmSeconds": 95, "estimateUsd": 0.0029 },
        "cleanup": "destroyed",
    });
    assert_eq!(
        receipt_text(&receipt, messages),
        "3 TODOs found\n\nstatus: succeeded (exit 0)\ntime: 95.0 s total, 30.0 s boot\ncost: about $0.0029 of VM time (95 s)\nartifacts:\n  report.md (120 B)\nVM: destroyed"
    );
    assert_eq!(exit_code(&receipt), 0);
    let failed = json!({ "status": "failed", "timedOut": true, "timings": {}, "cost": { "vmSeconds": null, "estimateUsd": null }, "cleanup": "pending", "error": "timed out" });
    assert_eq!(
        receipt_text(&failed, messages),
        "status: failed (timed out)\ntimed out\ntime: - total, - boot\nVM: destroy pending (the reaper finishes it)"
    );
    assert_eq!(exit_code(&failed), 1);
    // A cancelled receipt (the deadline cancel's answer) exits 1 like a failed one; 4 is only
    // for no receipt at all.
    assert_eq!(exit_code(&json!({ "status": "cancelled" })), 1);
}

#[test]
fn the_whole_command_line_keeps_globals_and_task_apart() {
    // `--sandboxed` takes no value, so a global `--json` after it stays global.
    let all = args(&["run", "--sandboxed", "--json", "list", "--", "--json"]);
    let (global, command) = super::super::parse_globals(&all).map_err(|(error, _)| error).unwrap();
    assert_eq!(global.output, OutputMode::Json);
    let rest = split(&command).expect("a sandboxed run");
    assert_eq!(parse(rest).unwrap(), Invocation::Run(request("list --json")));
}

#[test]
fn each_wait_fits_before_the_deadline_and_none_starts_after_it() {
    let now = Instant::now();
    // Plenty left: the server waits its full 10 s inside a 30 s socket budget.
    assert_eq!(
        wait_slice(now, now + Duration::from_secs(60), Duration::ZERO),
        Some((Duration::from_millis(10_000), Duration::from_secs(30)))
    );
    // 1.5 s left: server wait, socket budget and the call's margin all end by the deadline.
    let (server, budget) =
        wait_slice(now, now + Duration::from_millis(1_500), Duration::ZERO).unwrap();
    assert_eq!(budget, Duration::from_millis(500));
    // With a second or less left, the call's margin alone would pass the deadline: no call.
    assert_eq!(wait_slice(now, now + Duration::from_secs(1), Duration::ZERO), None);
    assert!(server <= budget);
    assert_eq!(wait_slice(now, now, Duration::ZERO), None);
    assert_eq!(wait_slice(now + Duration::from_secs(1), now, Duration::ZERO), None);
    // `--socket`'s probe comes off the slice: with 6 s left, a 5 s probe and the 1 s margin, no call starts.
    assert_eq!(wait_slice(now, now + Duration::from_secs(6), Duration::from_secs(5)), None);
    let (_, budget) =
        wait_slice(now, now + Duration::from_secs(8), Duration::from_secs(5)).unwrap();
    assert!(budget <= Duration::from_secs(2));
}

#[test]
fn the_retry_command_repeats_the_request_with_its_key() {
    let mut global = GlobalArgs::default();
    assert_eq!(
        retry_command(&request("list the TODOs"), "key-1", &global, None),
        "cmux run --sandboxed --idempotency-key=key-1 -- 'list the TODOs'"
    );
    global.app_socket = Some("/tmp/cmux app.sock".into());
    let mut with = request("it's done");
    with.agent = Some("claude".into());
    with.timeout_secs = 60;
    assert_eq!(
        retry_command(&with, "key-2", &global, Some(std::path::Path::new("/ignored.sock"))),
        "cmux '--app-socket=/tmp/cmux app.sock' run --sandboxed --idempotency-key=key-2 --agent claude --timeout 60 -- 'it'\\''s done'"
    );
}

#[test]
fn the_retry_command_reaches_the_same_app() {
    // The routing flags given are kept as given.
    let global = GlobalArgs {
        socket: Some("/tmp/daemon.sock".into()),
        session: Some("work".into()),
        machine: Some("mac 2".into()),
        ..Default::default()
    };
    assert_eq!(
        retry_command(&request("x"), "k", &global, None),
        "cmux --socket=/tmp/daemon.sock --session=work '--machine=mac 2' run --sandboxed --idempotency-key=k -- x"
    );
    // With none, the app this command discovered is pinned, so another shell's environment
    // can't send the retry to another app and account.
    assert_eq!(
        retry_command(
            &request("x"),
            "k",
            &GlobalArgs::default(),
            Some(std::path::Path::new("/run/cmux/app.sock"))
        ),
        "cmux --app-socket=/run/cmux/app.sock run --sandboxed --idempotency-key=k -- x"
    );
}

fn deadline_cancel_for(cancelled: &Result<Value, CallError>) -> DeadlineCancel<'_> {
    deadline_cancel(cancelled, "run-1")
}

#[test]
fn a_retry_value_that_starts_with_dashes_stays_a_value() {
    let global = GlobalArgs { session: Some("--odd".into()), ..Default::default() };
    let retry = retry_command(&request("x"), "--key", &global, None);
    assert_eq!(retry, "cmux --session=--odd run --sandboxed --idempotency-key=--key -- x");
    // The global parser reads each pair back as one flag and its value.
    let words: Vec<String> = retry.split(' ').skip(1).map(str::to_owned).collect();
    let (parsed, _) = super::super::parse_globals(&words).map_err(|(error, _)| error).unwrap();
    assert_eq!(parsed.session.as_deref(), Some("--odd"));
}

#[test]
fn a_relative_socket_is_pinned_absolute_in_the_retry() {
    let global = GlobalArgs {
        app_socket: Some("app.sock".into()),
        socket: Some("./daemon.sock".into()),
        ..Default::default()
    };
    let retry = retry_command(&request("x"), "k", &global, None);
    let cwd = std::env::current_dir().unwrap();
    assert!(retry.contains(&format!("--app-socket={}", cwd.join("app.sock").display())), "{retry}");
    assert!(
        retry.contains(&format!("--socket={}", cwd.join("daemon.sock").display()))
            || retry.contains(&format!("--socket={}", cwd.join("./daemon.sock").display())),
        "{retry}"
    );
}

#[test]
fn the_deadline_cancel_says_what_happened() {
    let failed = |code: &str| -> Result<Value, CallError> {
        Err(CallError { error: json!({ "code": code, "message": "m" }), exit_code: 1 })
    };
    let receipt = json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed", "status": "cancelled", "cleanup": "destroyed" } });
    assert_eq!(
        deadline_cancel_for(&Ok(receipt.clone())),
        DeadlineCancel::Receipt(&receipt["receipt"])
    );
    let ending = json!({ "run": { "id": "run-1", "status": "cancelling" }, "receipt": null });
    assert_eq!(deadline_cancel_for(&Ok(ending)), DeadlineCancel::Pending);
    // An answer that isn't this Run's snapshot, still ending, confirms nothing.
    for answer in [
        json!({}),
        json!({ "receipt": null }),
        json!({ "receipt": "x" }),
        json!({ "receipt": {} }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "status": "running" } }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-2", "status": "succeeded" } }),
        json!({ "receipt": { "runId": "run-1", "status": "succeeded" } }),
        // A skeleton without the sandboxed environment or a cleanup state is no receipt.
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "status": "succeeded" } }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed", "status": "succeeded" } }),
        // A run still queued or running did not take the cancel.
        json!({ "run": { "id": "run-1", "status": "running" } }),
        json!({ "run": { "id": "run-1", "status": "queued" } }),
        json!({ "run": { "id": "run-2", "status": "cancelling" } }),
        json!({ "run": { "id": "run-1", "status": "succeeded" } }),
    ] {
        assert_eq!(
            deadline_cancel_for(&Ok(answer.clone())),
            DeadlineCancel::Unanswered,
            "{answer}"
        );
    }
    // A signed-out app or a preview turned off refuses the cancel: exit 3 with its reason.
    for code in ["not_signed_in", "labs_off", "feature.disabled", "run_sandbox_unavailable"] {
        assert_eq!(deadline_cancel_for(&failed(code)), DeadlineCancel::Refused, "{code}");
    }
    // No answer is exit 4: the run may still be running.
    for code in [
        "timeout",
        "app.transport",
        "app.unreachable",
        "app.not_found",
        "socket.no_app",
        "unavailable",
        "bad_response",
    ] {
        assert_eq!(deadline_cancel_for(&failed(code)), DeadlineCancel::Unanswered, "{code}");
    }
    // A definite answer keeps its own code and exit: the run is not reported as still running.
    for code in ["run_not_found", "http_409", "rate_limited"] {
        assert_eq!(deadline_cancel_for(&failed(code)), DeadlineCancel::Refused, "{code}");
    }
}

#[test]
fn a_receipt_counts_only_when_it_is_this_runs_finished_sandbox_receipt() {
    let full = json!({ "receipt": {
        "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed",
        "status": "succeeded", "cleanup": "destroyed",
    } });
    assert_eq!(run_receipt(&full, "run-1"), Some(&full["receipt"]));
    for snapshot in [
        json!({}),
        json!({ "receipt": null }),
        json!({ "receipt": "x" }),
        json!({ "receipt": {} }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed", "status": "running", "cleanup": "pending" } }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-2", "environment": "sandboxed", "status": "succeeded", "cleanup": "destroyed" } }),
        json!({ "receipt": { "runId": "run-1", "environment": "sandboxed", "status": "succeeded", "cleanup": "destroyed" } }),
        // A skeleton without the sandboxed environment or a cleanup state is no receipt.
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "status": "succeeded" } }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed", "status": "succeeded" } }),
    ] {
        assert_eq!(run_receipt(&snapshot, "run-1"), None, "{snapshot}");
    }
}

#[test]
fn an_unknown_agent_is_a_usage_error_and_server_input_refusals_exit_2() {
    assert!(parsed(&["run", "--sandboxed", "--agent", "bogus", "go"]).is_err());
    for agent in ["claude", "codex", "opencode", "pi"] {
        assert!(parsed(&["run", "--sandboxed", "--agent", agent, "go"]).is_ok(), "{agent}");
    }
    for code in
        ["run_task_required", "run_agent_invalid", "run_image_invalid", "run_timeout_invalid"]
    {
        assert!(is_input_refusal(&json!({ "code": code })), "{code}");
    }
    assert!(!is_input_refusal(&json!({ "code": "run_sandbox_unavailable" })));
    // No Cloud backend in the app is "act first", like a signed-out app: exit 3.
    assert!(is_gate_refusal(&json!({ "code": "no_backend" })));
    // Cloud not callable here (a managed team missing, a local-only backend): act first, exit 3.
    assert!(is_gate_refusal(&json!({ "code": "cloud_disabled" })));
    assert!(!create_may_have_committed(&json!({ "code": "cloud_disabled" })));
}

#[test]
fn a_finished_run_without_a_receipt_is_a_lost_answer_not_a_running_one() {
    for status in ["succeeded", "failed", "cancelled"] {
        assert!(
            run_finished(&json!({ "run": { "id": "run-1", "status": status }, "receipt": null })),
            "{status}"
        );
    }
    for status in ["queued", "running", "cancelling"] {
        assert!(!run_finished(&json!({ "run": { "id": "run-1", "status": status } })), "{status}");
    }
    assert!(!run_finished(&json!({})));
}

#[test]
fn only_a_timeout_or_a_lost_transport_keeps_waiting() {
    assert!(is_transient(&json!({ "code": "timeout" })));
    assert!(is_transient(&json!({ "code": "app.transport" })));
    assert!(is_transient(&json!({ "code": "unavailable" })));
    assert!(!is_transient(&json!({ "code": "run_not_found" })));
    assert!(!is_transient(&json!({ "code": "not_signed_in" })));
    // The app restarting or its socket going away mid-wait is no answer about the run: keep
    // waiting until the deadline, which cancels the run, instead of leaving it running.
    assert!(is_transient(&json!({ "code": "app.unreachable" })));
    assert!(is_transient(&json!({ "code": "socket.unreachable" })));
    // A server failure, a rate limit or an unreadable answer during a wait says nothing either.
    assert!(is_transient(&json!({ "code": "bad_response" })));
    assert!(is_transient(&json!({ "code": "rate_limited" })));
    assert!(!is_transient(&json!({ "code": "run_not_found" })));
    // `--socket`'s probe failing after the run was created is a stall, not another socket.
    assert!(is_wait_transient(&json!({ "code": "socket.wrong_kind" })));
    assert!(!is_transient(&json!({ "code": "socket.wrong_kind" })));
}

#[test]
fn only_a_create_that_may_have_committed_prints_the_retry() {
    for code in ["timeout", "app.transport", "unavailable", "bad_response"] {
        assert!(create_may_have_committed(&json!({ "code": code })), "{code}");
    }
    for code in [
        "not_signed_in",
        "labs_off",
        "feature.disabled",
        "run_sandbox_unavailable",
        "run_image_invalid",
        "run_agent_invalid",
        "run_task_required",
        "app.unreachable",
        "app.not_found",
        "rate_limited",
        "no_backend",
    ] {
        assert!(!create_may_have_committed(&json!({ "code": code })), "{code}");
    }
}
