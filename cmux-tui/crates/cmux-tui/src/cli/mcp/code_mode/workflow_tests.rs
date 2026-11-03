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
            Request::ActivityWait { id } => {
                // All callbacks have launched before the first wait blocks.
                assert_eq!(started.len(), 3);
                waits.push(id.clone());
                json!({"ok":true,"value":id})
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
    for script in ["return Date.now();", "return Math.random();", "return new Date();"] {
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
            Request::ActivityWait { id } => {
                assert_eq!(id, "build");
                json!({"ok":false,"message":"compile failed","error":{"code":"machine.exit"}})
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
