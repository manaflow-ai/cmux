//! Script sessions end to end: the real `cmux-app-host` binary in the script
//! profile, driven by `cmux_app_host::script::Session` with a fake router.
#![cfg(unix)]

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_app_host::script::{LogSink, ScriptRouter, Session, codes};
use serde_json::{Value, json};

/// Module named `script` so `--filter script::` selects these tests.
mod script {
    use super::*;

    const BIN: &str = env!("CARGO_BIN_EXE_cmux-app-host");
    const SHORT: Duration = Duration::from_secs(20);

    type Publish = Arc<dyn Fn(&str) + Send + Sync>;

    /// Answers `test.echo` with its params, `workspace.list` with two rows, and
    /// refuses everything else the way the daemon does.
    #[derive(Default)]
    struct FakeRouter {
        calls: Mutex<Vec<(String, Value)>>,
        publish: Mutex<Option<Publish>>,
        watches: Mutex<u32>,
        counter: Mutex<u64>,
    }

    impl ScriptRouter for FakeRouter {
        fn call(&self, op: &str, params: Value, _options: Value) -> Result<Value, Value> {
            self.calls.lock().unwrap().push((op.to_string(), params.clone()));
            match op {
                "test.echo" => Ok(json!({ "value": params })),
                "test.counter" => Ok(json!({ "value": *self.counter.lock().unwrap() })),
                "workspace.list" => Ok(json!({ "value": [{ "id": "ws_1" }, { "id": "ws_2" }] })),
                "x.missing" => Err(
                    json!({ "code": "selector.not_found", "message": "no such thing", "details": { "op": op }, "retryable": false }),
                ),
                _ => Err(
                    json!({ "code": "operation.unsupported", "message": format!("{op} is not available to scripts"), "retryable": false }),
                ),
            }
        }

        fn watch(&self, publish: Publish) -> Box<dyn Send> {
            *self.watches.lock().unwrap() += 1;
            *self.publish.lock().unwrap() = Some(publish);
            Box::new(())
        }
    }

    impl FakeRouter {
        fn publish(&self, stream: &str) {
            let publish = self.publish.lock().unwrap().clone();
            publish.expect("a script subscribed")(stream);
        }

        fn bump(&self) {
            *self.counter.lock().unwrap() += 1;
        }

        fn calls(&self) -> Vec<(String, Value)> {
            self.calls.lock().unwrap().clone()
        }
    }

    struct Fixture {
        session: Session,
        router: Arc<FakeRouter>,
        logs: Arc<Mutex<Vec<(String, String)>>>,
    }

    fn start() -> Fixture {
        let router = Arc::new(FakeRouter::default());
        let logs = Arc::new(Mutex::new(Vec::new()));
        let sink_logs = logs.clone();
        let sink: LogSink = Arc::new(move |level: &str, message: &str| {
            sink_logs.lock().unwrap().push((level.to_string(), message.to_string()));
        });
        let session = Session::start(Path::new(BIN), router.clone(), sink).expect("session starts");
        Fixture { session, router, logs }
    }

    fn eval(f: &Fixture, code: &str) -> Result<Value, cmux_app_host::script::ScriptError> {
        f.session.eval(code, json!({}), SHORT)
    }

    #[test]
    fn the_result_is_the_last_expression_and_args_are_visible() {
        let f = start();
        assert_eq!(eval(&f, "1 + 1").unwrap(), json!(2));
        let value = f
            .session
            .eval(
                "({ name: cmux.args.name, n: Number(cmux.args.n) * 2 })",
                json!({ "name": "x", "n": "21" }),
                SHORT,
            )
            .unwrap();
        assert_eq!(value, json!({ "name": "x", "n": 42 }));
        assert_eq!(eval(&f, "const unused = 1").unwrap(), Value::Null);
    }

    #[test]
    fn top_level_bindings_survive_across_cells_with_await() {
        let f = start();
        eval(&f, "const rows = await cmux.workspace.list(); let count = rows.length").unwrap();
        eval(&f, "function twice(x) { return x * 2 }").unwrap();
        assert_eq!(eval(&f, "twice(count)").unwrap(), json!(4));
        assert_eq!(eval(&f, "rows.map((r) => r.id)").unwrap(), json!(["ws_1", "ws_2"]));
    }

    #[test]
    fn ops_go_through_the_router_and_keep_their_error_codes() {
        let f = start();
        assert_eq!(eval(&f, "await cmux.test.echo({ a: 1 })").unwrap(), json!({ "a": 1 }));
        assert_eq!(eval(&f, "await cmux.call('test.echo', { b: 2 })").unwrap(), json!({ "b": 2 }));
        let error = eval(&f, "await cmux.x.missing({})").unwrap_err();
        assert_eq!(error.code, "selector.not_found");
        assert_eq!(error.message, "no such thing");
        assert_eq!(error.details, json!({ "op": "x.missing" }));
        let names: Vec<String> = f.router.calls().into_iter().map(|(op, _)| op).collect();
        assert_eq!(names, ["test.echo", "test.echo", "x.missing"]);
        // A caught op error is an ordinary value for the script.
        let caught = eval(
            &f,
            "let code; try { await cmux.x.missing({}) } catch (e) { code = e.code }; code",
        )
        .unwrap();
        assert_eq!(caught, json!("selector.not_found"));
    }

    #[test]
    fn thrown_errors_and_syntax_errors_are_script_errors() {
        let f = start();
        let thrown = eval(&f, "throw new Error('boom')").unwrap_err();
        assert_eq!(thrown.code, codes::ERROR);
        assert!(thrown.message.contains("boom"), "{thrown}");
        let syntax = eval(&f, "let = = 1").unwrap_err();
        assert_eq!(syntax.code, codes::ERROR);
        assert!(syntax.message.contains("SyntaxError"), "{syntax}");
        // The session still works after a failed cell.
        assert_eq!(eval(&f, "'ok'").unwrap(), json!("ok"));
    }

    #[test]
    fn scripts_have_no_ambient_network_filesystem_or_process() {
        let f = start();
        let kinds = eval(
            &f,
            "[typeof fetch, typeof require, typeof process, typeof XMLHttpRequest, typeof Deno, typeof Bun, typeof std, typeof os]",
        )
        .unwrap();
        assert_eq!(kinds, json!(vec!["undefined"; 8]));
        // The runtime's own fetch helper is an op the daemon refuses.
        let error = eval(&f, "await cmux.net.fetch('https://example.com')").unwrap_err();
        assert_eq!(error.code, "operation.unsupported");
        // The REPL namespace is gone before any cell runs.
        assert_eq!(eval(&f, "typeof CmuxBrowserRepl").unwrap(), json!("undefined"));
    }

    #[test]
    fn console_output_reaches_the_log_sink_in_order() {
        let f = start();
        eval(&f, "console.log('one', { two: 2 }); console.error('three')").unwrap();
        let logs = f.logs.lock().unwrap().clone();
        assert!(logs.contains(&("info".into(), "one {\"two\":2}".into())), "{logs:?}");
        assert!(logs.contains(&("error".into(), "three".into())), "{logs:?}");
        let one = logs.iter().position(|l| l.1.starts_with("one")).unwrap();
        let three = logs.iter().position(|l| l.1 == "three").unwrap();
        assert!(one < three);
    }

    #[test]
    fn wait_resolves_on_a_matching_event_and_times_out_otherwise() {
        let f = Arc::new(start());
        let waiter = {
            let f = f.clone();
            std::thread::spawn(move || {
                eval(
                    &f,
                    "await cmux.wait('resource.changed', async () => { const n = await cmux.test.counter(); return n >= 2 && { n } }, { timeoutMs: 15000 })",
                )
            })
        };
        let deadline = Instant::now() + SHORT;
        while f.router.publish.lock().unwrap().is_none() {
            assert!(Instant::now() < deadline, "the script never subscribed");
            std::thread::sleep(Duration::from_millis(10));
        }
        // The cell is running, so a second cell is refused (one cell at a time).
        assert_eq!(eval(&f, "1").unwrap_err().code, codes::BUSY);
        f.router.bump();
        f.router.publish("terminal.output");
        f.router.publish("resource.changed");
        f.router.bump();
        f.router.publish("resource.changed");
        assert_eq!(waiter.join().unwrap().unwrap(), json!({ "n": 2 }));
        assert_eq!(*f.router.watches.lock().unwrap(), 1);

        let timeout =
            eval(&f, "await cmux.wait('resource.changed', () => false, { timeoutMs: 100 })")
                .unwrap_err();
        assert_eq!(timeout.code, codes::TIMEOUT);
        // A wait timeout is the script's own error: the session lives on.
        assert_eq!(eval(&f, "await cmux.test.counter()").unwrap(), json!(2));
    }

    #[test]
    fn a_busy_loop_ends_the_session_with_a_cpu_error() {
        let f = start();
        let started = Instant::now();
        let error = eval(&f, "while (true) {}").unwrap_err();
        assert_eq!(error.code, codes::CPU, "{error}");
        assert!(started.elapsed() < Duration::from_secs(10));
        assert!(eval(&f, "1").is_err());
    }

    #[test]
    fn a_cell_past_its_wall_time_ends_with_a_timeout() {
        let f = start();
        let error = f
            .session
            .eval("await new Promise(() => {})", json!({}), Duration::from_millis(300))
            .unwrap_err();
        assert_eq!(error.code, codes::TIMEOUT);
        assert_eq!(eval(&f, "1").unwrap_err().code, codes::TIMEOUT);
    }

    #[test]
    fn a_memory_blowup_ends_the_session_with_a_memory_error() {
        let f = start();
        let error =
            eval(&f, "const parts = []; for (;;) parts.push('x'.repeat(1 << 20))").unwrap_err();
        assert_eq!(error.code, codes::MEMORY, "{error}");
    }

    #[test]
    fn cancel_from_another_thread_ends_the_running_cell() {
        let f = Arc::new(start());
        let runner = {
            let f = f.clone();
            std::thread::spawn(move || eval(&f, "await new Promise(() => {})"))
        };
        std::thread::sleep(Duration::from_millis(200));
        f.session.cancel();
        assert_eq!(runner.join().unwrap().unwrap_err().code, codes::CANCELLED);
        assert!(f.session.is_dead());
    }
}
