use super::*;
use std::sync::Mutex;

/// A minimal runtime with the 15570 entry points, so these tests cover the
/// VM plumbing without the real runtime JS.
const MINI_RUNTIME: &str = r#"
(() => {
  const n = globalThis.__cmuxNative;
  const pending = new Map(); let nextCall = 1;
  const timers = new Map(); let nextTimer = 1;
  globalThis.__cmuxHostOnResult = (id, err, res) => {
    const p = pending.get(id); pending.delete(id);
    if (!p) return;
    if (err !== null && err !== undefined) p.reject(Object.assign(new Error(JSON.parse(err).message), { code: JSON.parse(err).code }));
    else p.resolve(JSON.parse(res));
  };
  globalThis.__cmuxHostOnTimer = (id) => { const t = timers.get(id); if (!t) return; if (!t.repeat) timers.delete(id); t.fn(); };
  globalThis.setTimeout = (fn, ms) => { const id = nextTimer++; timers.set(id, { fn, repeat: false }); n.setTimer(id, ms || 0, false); return id; };
  globalThis.driver = (method, params) => new Promise((resolve, reject) => { const id = nextCall++; pending.set(id, { resolve, reject }); n.driverCall(id, method, JSON.stringify(params || {})); });
  globalThis.events = [];
  globalThis.__cmuxHostOnEvent = (name, payload) => { events.push([name, JSON.parse(payload)]); };
  globalThis.print = (...a) => n.print("log", a.map(String).join(" "));
  globalThis.lastOptions = null;
  globalThis.__cmuxReplEval = (code, options) => (globalThis.lastOptions = options ?? null, async () => { const r = await (0, eval)("(async () => {" + code + "})()"); if (r !== undefined) print(JSON.stringify(r)); })();
})();
"#;

struct FakeHost {
    calls: Mutex<Vec<(String, Value)>>,
    natives: Mutex<Vec<(String, Value)>>,
}

impl VmHost for FakeHost {
    fn driver_call(&self, method: &str, params: Value) -> Result<Value, DriverError> {
        self.calls.lock().unwrap().push((method.to_owned(), params));
        match method {
            "tab.info" => Ok(json!({"url": "https://a.test/", "title": "A"})),
            "tab.navigate" => {
                Err(DriverError::new(crate::protocol::ErrorCode::Forbidden, "blocked by policy"))
            }
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn native(&self, name: &str, args: Value) -> Result<Value, String> {
        self.natives.lock().unwrap().push((name.to_owned(), args.clone()));
        match name {
            "secretSet" => Ok(json!({"__secret": args[0]})),
            "policyNarrow" => Err("the domain policy is locked for this session".into()),
            "policyCheck" => Ok(Value::Null),
            _ => Ok(json!([])),
        }
    }
}

fn session(memory_limit: usize) -> (VmSession, Arc<FakeHost>) {
    let host =
        Arc::new(FakeHost { calls: Mutex::new(Vec::new()), natives: Mutex::new(Vec::new()) });
    let config = VmConfig {
        session_id: "t".into(),
        cwd: std::env::temp_dir()
            .join(format!("vm-test-{}", std::process::id()))
            .display()
            .to_string(),
        memory_limit,
        capabilities: vec!["cdp".into()],
        scripts: vec![("mini.js".into(), MINI_RUNTIME.into())],
        resources: vec![("guide.md".into(), "# guide".into())],
    };
    (VmSession::spawn(config, host.clone()).unwrap(), host)
}

fn lines(outcome: &EvalOutcome) -> Vec<String> {
    outcome.output.iter().map(|(_, text)| text.clone()).collect()
}

#[test]
fn state_persists_between_evaluations() {
    let (vm, _) = session(0);
    let first = vm.eval("globalThis.count = 41;", Duration::from_secs(5));
    assert_eq!(first.error, None);
    let second = vm.eval("return count + 1;", Duration::from_secs(5));
    assert_eq!(lines(&second), vec!["42"]);
}

#[test]
fn driver_calls_go_through_the_host_and_errors_keep_codes() {
    let (vm, host) = session(0);
    let info = vm
        .eval("return (await driver('tab.info', {targetId: 'T'})).title;", Duration::from_secs(5));
    assert_eq!(lines(&info), vec!["\"A\""]);
    let blocked = vm.eval("try { await driver('tab.navigate', {url: 'x'}); } catch (e) { return e.code + ': ' + e.message; }", Duration::from_secs(5));
    assert_eq!(lines(&blocked), vec!["\"forbidden: blocked by policy\""]);
    let calls = host.calls.lock().unwrap();
    assert_eq!(calls[0], ("tab.info".to_string(), json!({"targetId": "T"})));
}

#[test]
fn timers_fire_without_polling() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "await new Promise((r) => setTimeout(r, 30)); return 'woke';",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&out), vec!["\"woke\""]);
}

#[test]
fn uncaught_errors_are_formatted_and_output_is_kept() {
    let (vm, _) = session(0);
    let out = vm.eval("print('before'); throw new TypeError('bad thing');", Duration::from_secs(5));
    assert_eq!(lines(&out), vec!["before"]);
    let error = out.error.unwrap();
    assert!(error.contains("bad thing"), "{error}");
}

#[test]
fn runaway_loops_are_interrupted_at_the_deadline() {
    let (vm, _) = session(0);
    let started = Instant::now();
    let out = vm.eval("for (;;) {}", Duration::from_millis(300));
    assert!(out.error.is_some());
    assert!(started.elapsed() < Duration::from_secs(5));
    let after = vm.eval("return 1;", Duration::from_secs(5));
    assert_eq!(lines(&after), vec!["1"], "the session survives an interrupted evaluation");
}

#[test]
fn memory_limits_fail_the_evaluation_not_the_host() {
    let (vm, _) = session(32 << 20);
    let out =
        vm.eval("const a = []; for (;;) a.push(new Array(1e5).fill(1));", Duration::from_secs(20));
    assert!(out.error.is_some());
}

#[test]
fn host_natives_return_json_and_throw_on_refusal() {
    let (vm, host) = session(0);
    let set = vm.eval(
        "return __cmuxNative.secretSet('k', 'v', JSON.stringify({domains: ['a.test']}));",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&set), vec![r#""{\"__secret\":\"k\"}""#]);
    let refused = vm.eval("try { __cmuxNative.policyNarrow(JSON.stringify(['b.test'])); } catch (e) { return String(e.message); }", Duration::from_secs(5));
    assert_eq!(lines(&refused), vec!["\"the domain policy is locked for this session\""]);
    assert_eq!(host.natives.lock().unwrap()[0].1, json!(["k", "v", {"domains": ["a.test"]}]));
}

#[test]
fn events_reach_the_runtime() {
    let (vm, _) = session(0);
    vm.event("tab.closed", json!({"targetId": "T"}));
    let out = vm.eval("return events;", Duration::from_secs(5));
    assert_eq!(lines(&out), vec![r#"[["tab.closed",{"targetId":"T"}]]"#]);
}

#[test]
fn natives_cover_resources_home_and_policy_reports() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "const n = __cmuxNative; return [n.readResource('guide.md'), n.readResource('../etc/passwd'), typeof n.homedir, JSON.parse(n.policyLog()), n.policyCheck('T')];",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None, "{out:?}");
    assert_eq!(lines(&out), vec![r##"["# guide",null,"string",[],null]"##]);
}

#[test]
fn fs_is_sandboxed_to_the_session_root() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "const n = __cmuxNative; const fs = (op, a) => JSON.parse(n.fs(op, JSON.stringify(a)));\n\
         fs('mkdir', {path: 'd', recursive: true});\n\
         fs('writeFile', {path: 'd/a.txt', base64: 'aGk='});\n\
         const read = fs('readFile', {path: 'd/a.txt'}).ok;\n\
         const list = fs('readdir', {path: 'd'}).ok.map((e) => e.name + ':' + e.type);\n\
         const outside = fs('readFile', {path: '/etc/hosts'}).error.code;\n\
         const up = fs('writeFile', {path: '../../../../../../../../etc/escape.txt', base64: ''}).error.code;\n\
         return [read, list, fs('exists', {path: 'd/a.txt'}).ok, outside, up];",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None, "{out:?}");
    assert_eq!(lines(&out), vec![r#"["aGk=",["a.txt:file"],true,"EACCES","EACCES"]"#]);
}

#[test]
fn fetch_answers_through_the_result_callback() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "return await new Promise((resolve) => { const prev = globalThis.__cmuxHostOnResult; globalThis.__cmuxHostOnResult = (id, err, res) => { globalThis.__cmuxHostOnResult = prev; resolve(JSON.parse(err).code); }; __cmuxNative.fetch(99, JSON.stringify({url: 'https://a.test/'})); });",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&out), vec!["\"unsupported\""]);
}

#[test]
fn dropping_the_session_stops_its_thread() {
    let (vm, host) = session(0);
    assert_eq!(lines(&vm.eval("return 1;", Duration::from_secs(5))), vec!["1"]);
    drop(vm);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Arc::strong_count(&host) > 1 {
        assert!(Instant::now() < deadline, "the VM thread still holds the host");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn timers_that_spin_after_an_evaluation_are_interrupted() {
    let (vm, _) = session(0);
    let first = vm
        .eval("setTimeout(() => { for (;;) {} }, 10); return 'scheduled';", Duration::from_secs(5));
    assert_eq!(lines(&first), vec!["\"scheduled\""]);
    let started = Instant::now();
    let next = vm.eval(
        "await new Promise((r) => setTimeout(r, 50)); return 'alive';",
        Duration::from_secs(20),
    );
    assert_eq!(lines(&next), vec!["\"alive\""], "{next:?}");
    assert!(started.elapsed() < Duration::from_secs(20));
}

#[test]
fn zero_delay_repeating_timers_do_not_starve_input() {
    let (vm, _) = session(0);
    let first =
        vm.eval("__cmuxNative.setTimer(777, 0, true); return 'spinning';", Duration::from_secs(5));
    assert_eq!(lines(&first), vec!["\"spinning\""]);
    let next = vm.eval("return 'answered';", Duration::from_secs(5));
    assert_eq!(lines(&next), vec!["\"answered\""]);
}

#[test]
fn huge_timer_delays_do_not_crash_the_session() {
    let (vm, _) = session(0);
    vm.eval("setTimeout(() => {}, 1e15); return 1;", Duration::from_secs(5));
    assert_eq!(lines(&vm.eval("return 2;", Duration::from_secs(5))), vec!["2"]);
}

#[test]
fn eval_options_reach_the_runtime() {
    let (vm, _) = session(0);
    let out = vm.eval_with(
        "return globalThis.lastOptions;",
        Duration::from_secs(5),
        &json!({"maxOutput": 0}),
    );
    assert_eq!(lines(&out), vec![r#""{\"maxOutput\":0}""#]);
}

#[test]
fn async_continuations_after_an_evaluation_are_interrupted() {
    let (vm, _) = session(0);
    let first = vm.eval(
        "(async () => { await driver('tab.info', {targetId: 'T'}); for (;;) {} })(); return 'left running';",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&first), vec!["\"left running\""]);
    let next = vm.eval("return 'alive';", Duration::from_secs(20));
    assert_eq!(lines(&next), vec!["\"alive\""], "{next:?}");
}

#[test]
fn enormous_eval_timeouts_do_not_crash_the_session() {
    let (vm, _) = session(0);
    assert_eq!(lines(&vm.eval("return 1;", Duration::MAX)), vec!["1"]);
    assert_eq!(lines(&vm.eval("return 2;", Duration::from_secs(5))), vec!["2"]);
}
