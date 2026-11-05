use super::{Limits, Request, workflow_exec};
use serde_json::json;

#[test]
fn native_workflow_engine_runs_claude_meta_phase_parallel_and_pipeline() {
    let mut started = Vec::new();
    let mut waits = Vec::new();
    let result = workflow_exec(
        r#"export const meta = {name: 'checks', phases: [{title: 'Review'}]};
        const values = await phase('Review', () => parallel(args.map(prompt => () => agent(prompt))));
        return await pipeline(values, value => value + '!');"#,
        json!(["first", "second", "third"]),
        Limits::default(),
        &mut |request| match request {
            Request::ActivityStart { kind, prompt, options } => {
                assert_eq!(kind, "agent");
                assert!(options.is_empty());
                started.push(prompt.clone());
                json!({"ok":true,"value":{"id":prompt}})
            }
            Request::ActivityWait { ids } => {
                // All callbacks have launched before the first wait blocks.
                assert_eq!(started.len(), 3);
                let id = ids.first().expect("pending id");
                waits.push(id.clone());
                json!({"ok":true,"value":{"id":id,"outcome":{"Ok":id}}})
            }
            _ => panic!("unexpected workflow request"),
        },
    ).unwrap();
    assert_eq!(result.get("isError"), Some(&json!(false)), "{result}");
    assert_eq!(
        result.pointer("/structuredContent/result"),
        Some(&json!(["first!", "second!", "third!"]))
    );
    assert_eq!(started, waits);
}

#[test]
fn native_workflow_engine_forbids_clock_and_randomness_before_effects() {
    for script in [
        "return Date();",
        "return Date.now();",
        "return Date.parse('2026-01-01');",
        "return Date.UTC(2026, 0, 1);",
        "return new Date();",
        "return Math.random();",
        "return performance.now();",
        "return performance.timeOrigin;",
        "return crypto.getRandomValues(new Uint8Array(1));",
        "return crypto.randomUUID();",
        "return Temporal.Now.instant();",
        "return new WeakRef({}).deref();",
        "return new FinalizationRegistry(() => {});",
    ] {
        let result = workflow_exec(script, json!([]), Limits::default(), &mut |_| {
            panic!("a nondeterministic script dispatched a host call")
        })
        .unwrap();
        assert_eq!(result.get("isError"), Some(&json!(true)), "{script}: {result}");
    }
}

#[test]
fn native_workflow_engine_machine_errors_keep_js_catch_behavior() {
    let result = workflow_exec(
        "return await machine('compile', {on: 'ci'}).catch(error => error.cmux.code);",
        json!([]),
        Limits::default(),
        &mut |request| match request {
            Request::ActivityStart { kind, prompt, options } => {
                assert_eq!((kind.as_str(), prompt.as_str()), ("machine", "compile"));
                assert_eq!(options.get("on"), Some(&json!("ci")));
                json!({"ok":true,"value":{"id":"build"}})
            }
            Request::ActivityWait { ids } => {
                assert_eq!(ids, ["build"]);
                json!({"ok":true,"value":{"id":"build","outcome":{"Err":{
                    "code":"machine.exit", "message":"compile failed"
                }}}})
            }
            _ => panic!("unexpected workflow request"),
        },
    )
    .unwrap();
    assert_eq!(
        result.pointer("/structuredContent/result"),
        Some(&json!("machine.exit")),
        "{result}"
    );
}

#[test]
fn native_workflow_engine_ready_branch_can_unblock_an_earlier_branch() {
    let mut starts = Vec::new();
    let mut completed = Vec::new();
    let result = workflow_exec(
        r#"return await parallel([
          async () => await agent('needs signal'),
          async () => { await agent('ready'); return await machine('signal'); }
        ]);"#,
        json!([]),
        Limits::default(),
        &mut |request| match request {
            Request::ActivityStart { prompt, .. } => {
                starts.push(prompt.clone());
                json!({"ok":true,"value":{"id":prompt}})
            }
            Request::ActivityWait { ids } => {
                let id = if !completed.contains(&"ready") {
                    assert_eq!(ids, ["needs signal", "ready"]);
                    "ready"
                } else if !completed.contains(&"signal") {
                    assert!(starts.iter().any(|id| id == "signal"));
                    assert_eq!(ids, ["needs signal", "signal"]);
                    "signal"
                } else {
                    assert_eq!(ids, ["needs signal"]);
                    "needs signal"
                };
                completed.push(id);
                json!({"ok":true,"value":{"id":id,"outcome":{"Ok":id}}})
            }
            _ => panic!("unexpected workflow request"),
        },
    )
    .unwrap();
    assert_eq!(result.get("isError"), Some(&json!(false)), "{result}");
    assert_eq!(
        result.pointer("/structuredContent/result"),
        Some(&json!(["needs signal", "signal"]))
    );
    assert_eq!(completed, ["ready", "signal", "needs signal"]);
}

#[test]
fn native_workflow_engine_unawaited_activity_is_unfinished_without_waiting() {
    let result = workflow_exec(
        "agent('still running'); return 'done';",
        json!([]),
        Limits::default(),
        &mut |request| match request {
            Request::ActivityStart { .. } => json!({"ok":true,"value":{"id":"child"}}),
            _ => panic!("a settled root must not block on its dangling child"),
        },
    )
    .unwrap();
    assert_eq!(result.get("isError"), Some(&json!(true)), "{result}");
    assert_eq!(
        result.pointer("/structuredContent/error/code"),
        Some(&json!("script.unfinished")),
        "{result}"
    );
}

#[test]
fn native_workflow_engine_parallel_rejection_does_not_hide_running_sibling() {
    let mut waits = 0;
    let result = workflow_exec(
        "return await parallel([() => agent('fails'), () => agent('still running')]);",
        json!([]),
        Limits::default(),
        &mut |request| match request {
            Request::ActivityStart { prompt, .. } => json!({"ok":true,"value":{"id":prompt}}),
            Request::ActivityWait { ids } => {
                waits += 1;
                assert_eq!(waits, 1, "must return unfinished rather than wait for the sibling");
                assert_eq!(ids, ["fails", "still running"]);
                json!({"ok":true,"value":{"id":"fails","outcome":{"Err":{
                    "code":"agent.failed", "message":"failed"
                }}}})
            }
            _ => panic!("unexpected workflow request"),
        },
    )
    .unwrap();
    assert_eq!(
        result.pointer("/structuredContent/error/code"),
        Some(&json!("script.unfinished")),
        "{result}"
    );
    assert_eq!(waits, 1);
}

#[test]
fn native_workflow_engine_invalid_start_rejects_locally_without_wait() {
    let result = workflow_exec(
        "return await agent('invalid', {on: 'missing'}).catch(error => error.cmux.code);",
        json!([]),
        Limits::default(),
        &mut |request| match request {
            Request::ActivityStart { .. } => json!({
                "ok":false, "message":"target unavailable", "error":{"code":"target.missing"}
            }),
            _ => panic!("a failed start has no activity to wait for"),
        },
    )
    .unwrap();
    assert_eq!(
        result.pointer("/structuredContent/result"),
        Some(&json!("target.missing")),
        "{result}"
    );
}

#[test]
fn native_workflow_engine_preserves_large_durable_results() {
    let output =
        workflow_exec("return 'x'.repeat(300000);", json!([]), Limits::default(), &mut |_| {
            panic!("no host call")
        })
        .unwrap();
    assert_eq!(output["isError"], false, "{output}");
    assert_eq!(output["structuredContent"]["result"].as_str().unwrap().len(), 300000);
}
