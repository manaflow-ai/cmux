use super::*;
use std::sync::Mutex;

/// A minimal runtime with the 15570 entry points, so these tests cover the
/// VM plumbing without the real runtime JS.
const MINI_RUNTIME: &str = r#"
(() => {
  const n = globalThis.__cmuxNative;
  // The host removes __cmuxNative and the entry points before the first
  // cell; this stub keeps its own reference for the tests.
  globalThis.testNative = n;
  globalThis.results = [];
  const pending = new Map(); let nextCall = 1;
  const timers = new Map(); let nextTimer = 1;
  globalThis.__cmuxHostOnResult = (id, err, res) => {
    const p = pending.get(id); pending.delete(id);
    if (!p) { results.push([id, err, res]); return; }
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
    /// Cells whose fetches the VM cancelled.
    cancelled: Mutex<Vec<u64>>,
    calls: Mutex<Vec<(String, Value)>>,
    natives: Mutex<Vec<(String, Value)>>,
}

impl VmHost for FakeHost {
    fn driver_call(&self, method: &str, params: Value) -> Result<Value, DriverError> {
        self.calls.lock().unwrap().push((method.to_owned(), params.clone()));
        match method {
            "tab.info" => Ok(json!({"url": "https://a.test/", "title": "A"})),
            "tab.navigate" => {
                Err(DriverError::new(crate::protocol::ErrorCode::Forbidden, "blocked by policy"))
            }
            "net.fetch" => Ok(json!({"url": params["url"], "status": 200, "bodyBase64": "aGk="})),
            "frame.evaluate" => Ok(serde_json::from_str(ORDERED).unwrap()),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn driver_call_reply(
        &self,
        method: &str,
        params: Value,
    ) -> Result<crate::driver::Reply, DriverError> {
        if method == "frame.evaluate" {
            self.calls.lock().unwrap().push((method.to_owned(), params));
            let raw = serde_json::value::RawValue::from_string(ORDERED.to_owned()).unwrap();
            return Ok(crate::driver::Reply::Json(raw));
        }
        self.driver_call(method, params).map(crate::driver::Reply::Value)
    }

    fn cancel_fetches(&self, cell: u64) {
        self.cancelled.lock().unwrap().push(cell);
    }

    fn mask_bytes(&self, bytes: &[u8]) -> Vec<u8> {
        let text = String::from_utf8_lossy(bytes).replace("SECRET", "<s>");
        text.into_bytes()
    }

    fn native(&self, name: &str, args: Value) -> Result<Value, String> {
        self.natives.lock().unwrap().push((name.to_owned(), args.clone()));
        match name {
            "secrets" => Ok(json!({"name": args["args"]["name"], "domains": [], "totp": false})),
            "policy" => Err("the domain policy is locked for this session".into()),
            _ => Ok(json!([])),
        }
    }
}

/// A page value in the page's key order (scenario 32's search results, with
/// nested objects and arrays).
const ORDERED: &str = r#"{"title":"cmux","url":"https://example.com/cmux","snippet":"s","nested":{"z":1,"a":[{"y":2,"b":3}]}}"#;

fn session(memory_limit: usize) -> (VmSession, Arc<FakeHost>) {
    let host = Arc::new(FakeHost {
        cancelled: Mutex::new(Vec::new()),
        calls: Mutex::new(Vec::new()),
        natives: Mutex::new(Vec::new()),
    });
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
    // Main's synchronous ABI: {"ok": value} or {"error": {code, message}}.
    let set = vm.eval(
        "return JSON.parse(testNative.secrets('set', JSON.stringify({name: 'k', value: 'v', domains: ['a.test']})));",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&set), vec![r#"{"ok":{"domains":[],"name":"k","totp":false}}"#]);
    let refused = vm.eval(
        "return JSON.parse(testNative.policy('set', JSON.stringify({allowed: ['b.test']})));",
        Duration::from_secs(5),
    );
    assert_eq!(
        lines(&refused),
        vec![
            r#"{"error":{"code":"forbidden","message":"the domain policy is locked for this session"}}"#
        ]
    );
    assert_eq!(
        host.natives.lock().unwrap()[0].1,
        json!({"op": "set", "args": {"name": "k", "value": "v", "domains": ["a.test"]}})
    );
    let bad = vm
        .eval("return JSON.parse(testNative.secrets('list', 'not json'));", Duration::from_secs(5));
    assert_eq!(
        lines(&bad),
        vec![r#"{"error":{"code":"invalid","message":"secrets: the arguments must be JSON"}}"#]
    );
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
        "const n = testNative; return [n.readResource('guide.md'), n.readResource('../etc/passwd'), typeof n.homedir, typeof n.secrets, typeof n.policy, typeof n.secretSet];",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None, "{out:?}");
    assert_eq!(
        lines(&out),
        vec![r##"["# guide",null,"string","function","function","undefined"]"##]
    );
}

#[test]
fn fs_is_sandboxed_to_the_session_root() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "const n = testNative; const fs = (op, a) => JSON.parse(n.fs(op, JSON.stringify(a)));\n\
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

/// A file the driver reported through `download.finished` is readable
/// (driver-protocol.md, native fs contract); its neighbours and writes to it
/// stay outside the session's files.
#[test]
fn reported_downloads_are_readable_and_nothing_else_outside() {
    let dir = std::env::temp_dir().join(format!("vm-download-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("guid-1");
    let other = dir.join("guid-2");
    std::fs::write(&file, "report body").unwrap();
    std::fs::write(&other, "not reported").unwrap();
    let (vm, _) = session(0);
    let script = format!(
        "const n = testNative; const fs = (op, a) => JSON.parse(n.fs(op, JSON.stringify(a)));\n\
         return [fs('readFile', {{path: {file:?}}}).ok || fs('readFile', {{path: {file:?}}}).error.code,\n\
         fs('readFile', {{path: {other:?}}}).error.code,\n\
         fs('writeFile', {{path: {file:?}, base64: ''}}).error.code];",
        file = file.display().to_string(),
        other = other.display().to_string(),
    );
    let before = vm.eval(&script, Duration::from_secs(5));
    assert_eq!(lines(&before), vec![r#"["EACCES","EACCES","EACCES"]"#]);
    vm.event(
        "download.finished",
        json!({"targetId": "T", "downloadId": "guid-1", "path": file.display().to_string()}),
    );
    let after = vm.eval(&script, Duration::from_secs(5));
    assert_eq!(after.error, None, "{after:?}");
    assert_eq!(lines(&after), vec![r#"["cmVwb3J0IGJvZHk=","EACCES","EACCES"]"#]);
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "report body");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn native_fetch_is_the_gates_net_fetch() {
    let (vm, host) = session(0);
    let out = vm.eval(
        "testNative.fetch(99, JSON.stringify({url: 'https://a.test/', targetId: 'T'})); for (let i = 0; i < 100 && !results.length; i++) await new Promise((r) => setTimeout(r, 10)); return JSON.parse(results[0][2]).status;",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&out), vec!["200"], "{out:?}");
    let calls = host.calls.lock().unwrap();
    assert!(
        calls.iter().any(|(m, p)| m == "net.fetch"
            && p["url"] == "https://a.test/"
            && p["targetId"] == "T"),
        "{calls:?}"
    );
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
        vm.eval("testNative.setTimer(777, 0, true); return 'spinning';", Duration::from_secs(5));
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

#[test]
fn the_entry_points_and_natives_are_gone_before_the_first_cell() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "return ['__cmuxNative', '__cmuxReplEval', '__cmuxHostOnResult', '__cmuxHostOnTimer', '__cmuxHostOnEvent', '__cmuxFormatError'].map((k) => typeof globalThis[k]);",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None, "{out:?}");
    assert_eq!(
        lines(&out),
        vec![r#"["undefined","undefined","undefined","undefined","undefined","undefined"]"#]
    );
    // The host still reaches the runtime: results, timers and events arrive.
    let out = vm.eval(
        "const info = await driver('tab.info', {targetId: 'T'}); await new Promise((r) => setTimeout(r, 5)); return [info.title, typeof events];",
        Duration::from_secs(5),
    );
    assert_eq!(lines(&out), vec![r#"["A","object"]"#]);
    vm.event("tab.closed", json!({"targetId": "T"}));
    assert_eq!(lines(&vm.eval("return events.length;", Duration::from_secs(5))), vec!["1"]);
}

#[test]
fn secrets_load_reads_the_file_natively_and_passes_the_map() {
    let (vm, host) = session(0);
    let out = vm.eval(
        "const n = testNative; n.fs('writeFile', JSON.stringify({path: 's.json', base64: 'eyJhLnRlc3QiOnsiayI6InYtMSJ9fQ=='}));\n\
         return JSON.parse(n.secrets('load', JSON.stringify({path: 's.json'}))).ok !== undefined;",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None, "{out:?}");
    let natives = host.natives.lock().unwrap();
    let (name, args) = natives.last().unwrap();
    assert_eq!(name, "secrets");
    assert_eq!(args, &json!({"op": "load", "args": {"object": {"a.test": {"k": "v-1"}}}}));
}

#[test]
fn files_the_vm_writes_and_reads_are_masked() {
    let (vm, _) = session(0);
    // "x SECRET y" and "z SECRET" in base64.
    let out = vm.eval(
        "const n = testNative; const fs = (op, a) => JSON.parse(n.fs(op, JSON.stringify(a)));\n\
         fs('writeFile', {path: 'm.txt', base64: 'eCBTRUNSRVQgeQ=='});\n\
         return [fs('readFile', {path: 'm.txt'}).ok];",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None, "{out:?}");
    // "x <s> y" in base64: the value never reaches the file or the VM.
    assert_eq!(lines(&out), vec![r#"["eCA8cz4geQ=="]"#]);
}

/// a9 raw_value: a script value reaches agent code in the page's key order,
/// nested objects and arrays included (scenario 32's search results).
#[test]
fn script_values_keep_the_page_key_order() {
    let (vm, _) = session(0);
    let out = vm.eval(
        "const r = await driver('frame.evaluate', {targetId: 'T', source: '() => 1'}); \
         return [Object.keys(r), Object.keys(r.nested), Object.keys(r.nested.a[0])].map((k) => k.join(',')).join('|');",
        Duration::from_secs(5),
    );
    assert_eq!(out.error, None);
    assert_eq!(lines(&out), vec!["\"title,url,snippet,nested|z,a|y,b\""]);
}

/// Classic main: a cell's timeout cancels the fetches that cell started; the
/// VM names the cell on each fetch it sends.
#[test]
fn a_cell_timeout_cancels_the_fetches_it_started() {
    let (vm, host) = session(0);
    let out = vm.eval(
        "testNative.fetch(1, JSON.stringify({url: 'https://a.test/x'})); await new Promise(() => {});",
        Duration::from_millis(300),
    );
    assert!(out.error.as_deref().is_some_and(|e| e.contains("timed out")), "{:?}", out.error);
    let deadline = Instant::now() + Duration::from_secs(5);
    while host.cancelled.lock().unwrap().is_empty() {
        assert!(Instant::now() < deadline, "the cell's fetches were not cancelled");
        std::thread::yield_now();
    }
    let calls = host.calls.lock().unwrap();
    let fetch = calls.iter().find(|(m, _)| m == "net.fetch").expect("the fetch ran");
    let cell = fetch.1["cell"].as_u64().expect("the VM names the fetch's cell");
    assert!(cell > 0);
    assert_eq!(*host.cancelled.lock().unwrap(), vec![cell]);
}
