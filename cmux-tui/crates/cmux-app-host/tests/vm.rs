//! Host-side expectations of the runtime ABI, ported from the bun tests
//! (`js/test/*.test.ts`) to the native QuickJS host.

mod common;

use std::time::{Duration, Instant};

use cmux_app_host::{FatalReason, Limits, VmError};
use common::{Harness, app};
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    #[test]
    fn initial_mount_emits_create_children_and_root_in_one_batch() {
        let mut h = Harness::new(&app(
            r#"return { render: () => VStack({ spacing: 4 }, [Text("Hello").bold(), Divider()]) }"#,
        ));
        assert_eq!(h.mount("m1", "render", json!({})), None);
        let batches = h.batches("m1");
        assert_eq!(batches.len(), 1);
        let ops = &batches[0];
        let created: Vec<&str> =
            ops.iter().filter(|o| o["op"] == "create").filter_map(|o| o["type"].as_str()).collect();
        assert_eq!(created, ["VStack", "Text", "Divider"]);
        let text = ops.iter().find(|o| o["type"] == "Text").expect("text");
        assert_eq!(text["props"], json!({ "text": "Hello", "weight": "bold" }));
        assert_eq!(ops.last().expect("ops")["op"], "root");
    }

    #[test]
    fn render_errors_and_missing_exports_are_error_strings() {
        let mut h = Harness::new(&app(r#"return { render: () => { throw new Error("boom") } }"#));
        assert!(h.mount("m1", "render", json!({})).expect("error").contains("boom"));
        assert!(h.batches("m1").is_empty());
        assert!(h.mount("m2", "nope", json!({})).expect("error").contains("nope"));
    }

    #[test]
    fn a_signal_write_emits_one_update_after_the_job_queue_drains() {
        let mut h = Harness::new(&app(r#"const [count, setCount] = signal(0)
        globalThis.bump = () => Promise.resolve().then(() => setCount((c) => c + 1))
        return { render: () => VStack([Text(() => "n=" + count()), Text("static")]) }"#));
        h.mount("m1", "render", json!({}));
        h.eval("bump()");
        let last = h.batches("m1").last().expect("batch").clone();
        assert_eq!(last.len(), 1, "{last:?}");
        assert_eq!(last[0]["op"], "update");
        assert_eq!(last[0]["props"], json!({ "text": "n=1" }));
    }

    #[test]
    fn dispatch_runs_the_handler_and_resolve_feeds_the_scene() {
        let mut h = Harness::new(&app(r#"const [name, setName] = signal("…")
        return { render: () => VStack([
          Text(() => name()),
          Button("load", async () => { const ws = await cmux.workspace.list({}); setName(ws[0].name) })
        ]) }"#));
        h.handle("workspace.list", |_, _| (true, json!({ "value": [{ "name": "alpha" }] })));
        h.mount("m", "render", json!({}));
        let button = h.find("m", |n| n.props.get("title") == Some(&json!("load"))).expect("button");
        h.dispatch("m", &button, "tap", json!({ "gesture": "g1" }));
        assert_eq!(h.calls[0].name, "workspace.list");
        assert_eq!(h.calls[0].options["gesture"], "g1");
        assert!(h.texts("m").contains(&"alpha".to_string()), "{:?}", h.texts("m"));
    }

    #[test]
    fn unknown_op_is_operation_unsupported_and_ungranted_is_scope_missing() {
        let mut h = Harness::with(
            "",
            json!({ "knownOps": ["workspace.list", "tab.close"], "ops": ["workspace.list"] }),
            Limits::default(),
        );
        h.eval(r#"(cmux.made.up({}).catch((e) => globalThis.a = e.code), cmux.tab.close({}).catch((e) => globalThis.b = e.code), 0)"#);
        assert_eq!(
            h.eval("[globalThis.a, globalThis.b]"),
            json!(["operation.unsupported", "scope.missing"])
        );
        assert!(h.calls.is_empty());
    }

    #[test]
    fn errors_from_the_host_reject_with_their_code() {
        let mut h = Harness::new("");
        h.eval(r#"(cmux.tab.focus({ tab: "tab_1" }).catch((e) => globalThis.code = e.code), 0)"#);
        assert_eq!(h.eval("globalThis.code"), json!("operation.unsupported"));
    }

    #[test]
    fn gesture_tokens_follow_the_synchronous_handler_only() {
        let mut h = Harness::new(&app(r#"return { render: () => VStack([
          Button("async", async () => {
            const g = cmux.gesture()
            await cmux.terminal.get({ terminal: "term_1" })
            await cmux.tab.focus({ tab: "tab_2" })
            await cmux.tab.focus({ tab: "tab_3" }, { gesture: g })
          })
        ]) }"#));
        h.handle("tab.focus", |_, _| (true, json!({ "value": null })));
        h.handle("terminal.get", |_, _| (true, json!({ "value": { "id": "term_1" } })));
        h.mount("m", "render", json!({}));
        let button =
            h.find("m", |n| n.props.get("title") == Some(&json!("async"))).expect("button");
        h.dispatch("m", &button, "tap", json!({ "gesture": "g2" }));
        let focus: Vec<(Value, Value)> = h
            .calls
            .iter()
            .filter(|c| c.name == "tab.focus")
            .map(|c| {
                (c.params["tab"].clone(), c.options.get("gesture").cloned().unwrap_or(Value::Null))
            })
            .collect();
        assert_eq!(focus, vec![(json!("tab_2"), Value::Null), (json!("tab_3"), json!("g2"))]);
        assert_eq!(
            h.calls[0].options["gesture"], "g2",
            "the first call is synchronous in the handler"
        );
    }

    #[test]
    fn timers_fire_from_the_host_and_rearm_when_repeating() {
        let mut h = Harness::new(&app(r#"const [n, setN] = signal(0)
        return { render: () => { cmux.timer.every(5, () => setN((v) => v + 1)); return Text(() => "t" + n()) } }"#));
        h.mount("m", "render", json!({}));
        let due = h.vm.next_timer_due().expect("armed");
        assert!(
            due >= Instant::now() + Duration::from_millis(900),
            "repeating timers are floored to 1 s"
        );
        h.vm.fire_due_timers(due).expect("fire");
        h.pump().expect("pump");
        assert!(h.texts("m").contains(&"t1".to_string()), "{:?}", h.texts("m"));
        assert!(h.vm.next_timer_due().expect("re-armed") > due);
        h.vm.unmount("m").expect("unmount");
        assert_eq!(h.vm.next_timer_due(), None, "unmount clears the app's timers");
    }

    #[test]
    fn unmount_releases_subscriptions_and_live_rereads_on_events() {
        let mut h = Harness::new(&app(
            r#"return { render: () => { const ws = cmux.live("workspace.list"); return Text(() => String((ws() ?? []).length)) } }"#,
        ));
        let count = std::rc::Rc::new(std::cell::Cell::new(1));
        let c = count.clone();
        h.handle("workspace.list", move |_, _| {
            (true, json!({ "value": vec![json!({}); c.get()] }))
        });
        h.mount("m", "render", json!({}));
        assert!(h.texts("m").contains(&"1".to_string()), "{:?}", h.texts("m"));
        assert_eq!(h.subscriptions.len(), 1);
        count.set(3);
        let stream = h.subscriptions.values().next().expect("sub").0.clone();
        h.emit(&stream, json!({}));
        assert!(h.texts("m").contains(&"3".to_string()), "{:?}", h.texts("m"));
        h.vm.unmount("m").expect("unmount");
        h.pump().expect("pump");
        assert!(h.subscriptions.is_empty());
    }

    #[test]
    fn commands_report_through_done() {
        let mut h = Harness::new(&app(r#"return { refresh: async (args) => ({ got: args.n }) }"#));
        h.vm.run_command(7, "refresh", &json!({ "n": 2 }), None).expect("run");
        h.pump().expect("pump");
        assert_eq!(h.done.get(&7), Some(&(true, json!({ "value": { "got": 2 } }))));
        h.vm.run_command(8, "missing", &json!({}), None).expect("run");
        h.pump().expect("pump");
        assert_eq!(h.done[&8].1["code"], "export.missing");
    }

    #[test]
    fn the_pending_call_cap_rejects_calls_past_it_with_app_limit() {
        let mut h = Harness::with(
            &app("return {}"),
            json!({}),
            Limits { max_pending_calls: 4, ..Limits::default() },
        );
        h.auto_answer = false;
        h.eval(r#"(globalThis.codes = [], [1,2,3,4,5,6].forEach((i) => cmux.workspace.list({ i }).catch((e) => codes.push(e.code))), 0)"#);
        assert_eq!(h.unanswered.len(), 4);
        assert_eq!(h.eval("codes"), json!(["app.limit", "app.limit"]));
        assert_eq!(h.vm.pending_calls(), 4);
        let cb = h.unanswered[0].cb;
        h.answer(cb, true, json!({ "value": [] })).expect("answer");
        assert_eq!(h.vm.pending_calls(), 3);
    }

    #[test]
    fn a_runaway_entry_is_interrupted_and_kills_only_its_vm() {
        let mut runaway = Harness::new(&app(r#"return { render: () => { for (;;) {} } }"#));
        let healthy_src = app(r#"return { render: () => Text("ok") }"#);
        let mut healthy = Harness::new(&healthy_src);
        let started = Instant::now();
        let error = runaway.vm.mount("m", "render", &json!({})).expect_err("interrupted");
        assert!(started.elapsed() < Duration::from_secs(2), "deadline is 250 ms");
        assert!(
            matches!(error, VmError::Fatal { reason: FatalReason::Interrupt, .. }),
            "{error:?}"
        );
        assert_eq!(runaway.vm.dead(), Some(FatalReason::Interrupt));
        assert!(runaway.vm.unmount("m").is_err(), "a dead VM refuses every entry");
        assert_eq!(healthy.mount("m", "render", json!({})), None);
        assert_eq!(healthy.texts("m"), ["ok"]);
    }

    #[test]
    fn a_runaway_promise_chain_is_interrupted_during_the_job_drain() {
        let mut h = Harness::new(&app(
            r#"const spin = () => Promise.resolve().then(spin); return { go: () => { spin() } }"#,
        ));
        // Each step nests one more promise, so the chain also grows; whichever
        // limit trips first, the drain stops it and the VM dies.
        let error = h.vm.run_command(1, "go", &json!({}), None).expect_err("stopped");
        assert!(
            matches!(
                error,
                VmError::Fatal { reason: FatalReason::Interrupt | FatalReason::Memory, .. }
            ),
            "{error:?}"
        );
    }

    #[test]
    fn memory_past_the_limit_kills_only_its_vm() {
        let limits = Limits { memory_bytes: 8 * 1024 * 1024, ..Limits::default() };
        let mut hog = Harness::with(
            &app(
                r#"globalThis.keep = []; return { grow: () => { for (;;) keep.push("x".repeat(65536) + keep.length) } }"#,
            ),
            json!({}),
            limits,
        );
        let mut other = Harness::with(
            &app(r#"return { render: () => Text("still here") }"#),
            json!({}),
            limits,
        );
        let error = hog.vm.run_command(1, "grow", &json!({}), None).expect_err("memory");
        assert!(matches!(error, VmError::Fatal { reason: FatalReason::Memory, .. }), "{error:?}");
        hog.pump().ok();
        assert!(matches!(
            hog.fatal,
            Some(cmux_app_host::FromHost::Fatal { reason: FatalReason::Memory, .. })
        ));
        assert!(other.vm.memory_used() < limits.memory_bytes);
        assert_eq!(other.mount("m", "render", json!({})), None);
        assert_eq!(other.texts("m"), ["still here"]);
    }

    #[test]
    fn settings_and_strings_reach_the_app() {
        let mut h = Harness::with(
            "",
            json!({ "settings": { "login": "octo" }, "locale": "ja", "strings": { "greeting": "こんにちは {name}" } }),
            Limits::default(),
        );
        assert_eq!(
            h.eval(r#"[cmux.t("greeting", { name: "Ada" }), cmux.app.locale]"#),
            json!(["こんにちは Ada", "ja"])
        );
        h.vm.set_settings(&json!({ "login": "hubot" })).expect("settings");
        h.pump().expect("pump");
        assert_eq!(h.eval("cmux.app.settings().login"), json!("hubot"));
    }

    #[test]
    fn flooding_messages_timers_or_subscriptions_kills_the_vm() {
        let mut logs = Harness::new(&app(
            r#"return { go: () => { for (let i = 0; i < 1e6; i++) cmux.log("x".repeat(1000)) } }"#,
        ));
        let error = logs.vm.run_command(1, "go", &json!({}), None).expect_err("flood");
        assert!(matches!(error, VmError::Fatal { reason: FatalReason::Memory, .. }), "{error:?}");
        let mut timers = Harness::new(&app(
            r#"return { go: () => { for (let i = 0; i < 1000; i++) cmux.timer.after(60000, () => {}) } }"#,
        ));
        assert!(timers.vm.run_command(1, "go", &json!({}), None).is_err());
        let mut subs = Harness::new(&app(
            r#"return { go: () => { for (let i = 0; i < 1000; i++) cmux.events.on("x.changed", () => {}) } }"#,
        ));
        assert!(subs.vm.run_command(1, "go", &json!({}), None).is_err());
    }

    #[test]
    fn a_repeated_callback_id_never_reaches_the_supervisor_twice() {
        let mut h = Harness::new("");
        h.auto_answer = false;
        h.eval(r#"(__cmuxAppNative.call("workspace.list", "{}", "{}", 9), __cmuxAppNative.call("workspace.list", "{}", "{}", 9), 0)"#);
        assert_eq!(h.unanswered.len(), 1);
        assert_eq!(h.vm.pending_calls(), 1);
    }

    #[test]
    fn a_run_with_a_gesture_carries_it_through_ctx_cmux_until_it_settles() {
        let mut h = Harness::new(&app(r#"return { focusTab: async (args, ctx) => {
                globalThis.seen = ctx.gesture
                await ctx.cmux.tab.focus({ tab: args.tab })
                await ctx.cmux.tab.focus({ tab: "later" })
                await cmux.tab.focus({ tab: "global" })
            } }"#));
        h.handle("tab.focus", |_, _| (true, json!({ "value": null })));
        h.vm.run_command(3, "focusTab", &json!({ "tab": "tab_1" }), Some("g9")).expect("run");
        h.pump().expect("pump");
        let gestures: Vec<Value> = h
            .calls
            .iter()
            .map(|c| c.options.get("gesture").cloned().unwrap_or(Value::Null))
            .collect();
        assert_eq!(gestures, vec![json!("g9"), json!("g9"), Value::Null]);
        assert_eq!(h.eval("globalThis.seen"), json!("g9"));
        assert!(h.done[&3].0);
    }
}
