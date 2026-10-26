use std::cell::{Cell, RefCell};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn parsed(list: &[&str]) -> Result<Invocation, UsageError> {
    parse(&words(list))
}

fn record_plan(list: &[&str]) -> RecordPlan {
    match parsed(list).expect("a record command") {
        Invocation::Verb(Verb::Record(plan)) => plan,
        other => panic!("not a record: {other:?}"),
    }
}

/// Waits nothing; remembers what it was asked to wait.
struct FakeWait {
    asked: Cell<Option<Duration>>,
    answer: Waited,
}

impl FakeWait {
    fn new(answer: Waited) -> Self {
        Self { asked: Cell::new(None), answer }
    }
}

impl RecordWait for FakeWait {
    fn wait(&self, duration: Duration) -> Waited {
        self.asked.set(Some(duration));
        self.answer
    }
}

/// Writes a marker file as the Perfetto trace and keeps the bundle it was given.
#[derive(Default)]
struct FakeExporter {
    seen: RefCell<Option<Bundle>>,
}

impl TraceExporter for FakeExporter {
    fn available(&self) -> bool {
        true
    }

    fn export(&self, bundle: &Bundle, to: &Path) -> Result<(), String> {
        std::fs::write(to, b"perfetto").map_err(|error| error.to_string())?;
        *self.seen.borrow_mut() = Some(bundle.clone());
        Ok(())
    }
}

/// An in-memory app: answers each call with `reply`, records the calls.
struct ScriptedApp {
    calls: Vec<(String, Value)>,
    reply: Box<dyn FnMut(&str) -> AppReply>,
}

impl TraceApp for ScriptedApp {
    fn call(&mut self, method: &str, params: Value, _: Duration) -> AppReply {
        self.calls.push((method.to_owned(), params));
        (self.reply)(method)
    }
}

fn no_notes() -> impl FnMut(String) {
    |_| {}
}

/// The stop reply of task 020's contract over rings written under `dir`.
fn stop_reply(dir: &Path) -> Value {
    let ring = |name: &str, bytes: &[u8]| {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path.display().to_string()
    };
    let chromium = ring("cef-trace.json", b"{\"traceEvents\":[]}");
    json!({
        "recording": false,
        "processes": [
            {"role": "app", "pid": 10, "state": "idle",
             "recording_path": ring("app-10.recording.cmxtrace", b"app ring"), "recording_bytes": 8},
        ],
        "daemon": {
            "op": "stop",
            "recording": false,
            "processes": [
                {"role": "daemon", "pid": 20, "state": "idle",
                 "recording_path": ring("daemon-20.recording.cmxtrace", b"daemon ring"), "recording_bytes": 11},
                {"role": "terminal-host", "pid": 30, "state": "idle",
                 "recording_path": ring("terminal-host-30.recording.cmxtrace", b"host ring"), "recording_bytes": 9},
                {"role": "holder", "state": "untraced", "reason": "holder_untraced"},
            ],
        },
        "chromium_trace": {"path": chromium},
    })
}

/// A fake app control socket: one request per connection, answered in order.
fn fake_app_socket(
    dir: &Path,
    replies: Vec<Value>,
) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut requests = Vec::new();
        for reply in replies {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            requests.push(serde_json::from_str::<Value>(&line).unwrap());
            let mut stream = stream;
            let answer = json!({"id": 1, "ok": true, "result": reply});
            stream.write_all(format!("{answer}\n").as_bytes()).unwrap();
        }
        requests
    });
    (socket, server)
}

#[test]
fn cli_trace_help_lists_every_option() {
    for help in [&["--help"][..], &["help"], &[], &["record", "--help"], &["start", "-h"]] {
        assert_eq!(parsed(help), Ok(Invocation::Help), "{help:?}");
    }
    let usage = crate::localization::catalog().trace.usage;
    for option in [
        "record",
        "start",
        "stop",
        "status",
        "--seconds",
        "--out",
        "--categories",
        "--keys",
        "--chromium",
        "--seconds-cap",
        "--json",
    ] {
        assert!(usage.contains(option), "usage names {option}");
    }
}

#[test]
fn cli_trace_record_parses_its_options_and_caps_past_its_wait() {
    let plan = record_plan(&[
        "record",
        "--seconds",
        "5",
        "--out=/tmp/t",
        "--categories",
        "motion,frame",
        "--categories=frame,key",
        "--keys",
        "--chromium",
    ]);
    assert_eq!(plan.seconds, 5);
    assert_eq!(plan.out, PathBuf::from("/tmp/t"));
    let expected: Vec<String> = words(&["motion", "frame", "key"]);
    assert_eq!(plan.start.categories.as_ref(), Some(&expected));
    assert!(plan.start.keys && plan.start.chromium);
    assert_eq!(plan.start.seconds_cap, Some(5 + STOP_SLACK_SECONDS));
    assert_eq!(
        plan.start.params(),
        json!({"categories": ["motion", "frame", "key"], "keys": true, "chromium": true, "seconds_cap": 15})
    );
    // Keys and Chromium are off unless asked; no categories means the daemon's default.
    let plain = record_plan(&["record", "--seconds", "1", "--out", "d"]);
    assert_eq!(plain.start.params(), json!({"keys": false, "chromium": false, "seconds_cap": 11}));
}

#[test]
fn cli_trace_parse_refuses_bad_input_before_anything_runs() {
    for bad in [
        &["record", "--out", "d"][..],
        &["record", "--seconds", "3"],
        &["record", "--seconds", "0", "--out", "d"],
        &["record", "--seconds", "591", "--out", "d"],
        &["record", "--seconds", "two", "--out", "d"],
        &["record", "--seconds", "3", "--out", "d", "--seconds-cap", "9"],
        &["record", "--seconds", "3", "--out", "d", "--categories", "motoin"],
        &["record", "--seconds", "3", "--out", "d", "--categories", "key"],
        &["record", "--seconds"],
        &["start", "--seconds-cap", "601"],
        &["start", "--out", "d"],
        &["stop", "--keys"],
        &["status", "extra"],
        &["replay"],
    ] {
        assert!(parsed(bad).is_err(), "{bad:?} parsed");
    }
    assert_eq!(
        parsed(&["start", "--seconds-cap", "600", "--keys"]),
        Ok(Invocation::Verb(Verb::Start(StartPlan {
            categories: None,
            keys: true,
            chromium: false,
            seconds_cap: Some(600),
        })))
    );
    assert_eq!(parsed(&["stop"]), Ok(Invocation::Verb(Verb::Stop)));
    assert_eq!(parsed(&["status"]), Ok(Invocation::Verb(Verb::Status)));
}

/// Acceptance (task 021): over a real socket, `record` calls `trace.start` then `trace.stop`
/// (no read barrier, a connection each), waits its seconds, and leaves every ring, the
/// Chromium JSON, the manifest and the Perfetto trace in `--out`.
#[test]
fn cli_trace_record_over_a_fake_socket_calls_in_order_and_writes_the_bundle() {
    let temp = tempfile::tempdir().unwrap();
    let rings = temp.path().join("live");
    std::fs::create_dir(&rings).unwrap();
    let stop = stop_reply(&rings);
    let start = json!({"recording": true, "categories": ["motion"], "keys": false});
    let (socket, server) = fake_app_socket(temp.path(), vec![start.clone(), stop.clone()]);
    let global = GlobalArgs { app_socket: Some(socket), ..GlobalArgs::default() };
    let out = temp.path().join("out");
    let plan = record_plan(&[
        "record",
        "--seconds",
        "7",
        "--out",
        out.to_str().unwrap(),
        "--categories",
        "motion",
    ]);
    let wait = FakeWait::new(Waited::Elapsed);
    let exporter = FakeExporter::default();

    let result =
        record(&plan, &mut AppTrace { global: &global }, &wait, &exporter, &mut no_notes())
            .unwrap();

    let requests = server.join().unwrap();
    let methods: Vec<&str> =
        requests.iter().map(|request| request["method"].as_str().unwrap()).collect();
    assert_eq!(methods, ["trace.start", "trace.stop"]);
    assert_eq!(
        requests[0]["params"],
        json!({"categories": ["motion"], "keys": false, "chromium": false, "seconds_cap": 17})
    );
    assert_eq!(requests[1]["params"], json!({}));
    assert_eq!(wait.asked.get(), Some(Duration::from_secs(7)));

    for (name, bytes) in [
        ("app-10.recording.cmxtrace", &b"app ring"[..]),
        ("daemon-20.recording.cmxtrace", b"daemon ring"),
        ("terminal-host-30.recording.cmxtrace", b"host ring"),
    ] {
        assert_eq!(std::fs::read(out.join(RINGS_DIR).join(name)).unwrap(), bytes, "{name}");
    }
    assert_eq!(std::fs::read(out.join(CHROMIUM_FILE)).unwrap(), b"{\"traceEvents\":[]}");
    assert_eq!(std::fs::read(out.join(PERFETTO_FILE)).unwrap(), b"perfetto");

    let manifest: Value =
        serde_json::from_slice(&std::fs::read(out.join(MANIFEST_FILE)).unwrap()).unwrap();
    assert_eq!(manifest["start"], start);
    assert_eq!(manifest["stop"], stop);
    assert_eq!(manifest["interrupted"], json!(false));
    let roles: Vec<&str> = manifest["rings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|ring| ring["role"].as_str().unwrap())
        .collect();
    assert_eq!(roles, ["app", "daemon", "terminal-host"]);
    assert_eq!(manifest["rings"][1]["file"], json!("rings/daemon-20.recording.cmxtrace"));
    assert_eq!(manifest["chromium"], json!(CHROMIUM_FILE));
    assert_eq!(
        manifest["not_copied"],
        json!([{"role": "holder", "pid": null, "reason": "holder_untraced"}])
    );

    assert_eq!(result["perfetto"], json!(out.join(PERFETTO_FILE).display().to_string()));
    let bundle = exporter.seen.borrow_mut().take().expect("the exporter ran");
    assert_eq!(bundle.dir, out);
    assert_eq!(bundle.rings.len(), 3);
    assert_eq!(bundle.chromium, Some(out.join(CHROMIUM_FILE)));
}

#[test]
fn cli_trace_record_refuses_a_used_out_dir_before_starting() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("old"), b"x").unwrap();
    let plan = record_plan(&["record", "--seconds", "1", "--out", temp.path().to_str().unwrap()]);
    let mut app = ScriptedApp { calls: Vec::new(), reply: Box::new(|_| panic!("no call")) };
    let failure = record(
        &plan,
        &mut app,
        &FakeWait::new(Waited::Elapsed),
        &FakeExporter::default(),
        &mut no_notes(),
    )
    .unwrap_err();
    assert_eq!(failure.exit_code, 2);
    assert_eq!(failure.error["code"], json!("usage.invalid"));
    assert!(app.calls.is_empty());
}

#[test]
fn cli_trace_record_stops_early_on_a_signal_and_still_collects() {
    let temp = tempfile::tempdir().unwrap();
    let stop = stop_reply(temp.path());
    let out = temp.path().join("out");
    let plan = record_plan(&["record", "--seconds", "300", "--out", out.to_str().unwrap()]);
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(move |method| {
            Ok(Ok(if method == "trace.stop" { stop.clone() } else { json!({}) }))
        }),
    };
    let mut notes = Vec::new();
    let result = record(
        &plan,
        &mut app,
        &FakeWait::new(Waited::Interrupted),
        &PerfettoExport,
        &mut |note| notes.push(note),
    )
    .unwrap();
    let methods: Vec<&str> = app.calls.iter().map(|(method, _)| method.as_str()).collect();
    assert_eq!(methods, ["trace.start", "trace.stop"]);
    assert_eq!(result["interrupted"], json!(true));
    assert_eq!(result["export"], json!("unavailable"));
    assert_eq!(result["rings"].as_array().map(Vec::len), Some(3));
    assert_eq!(notes.len(), 2, "the recording note and the early stop");
}

#[test]
fn cli_trace_record_names_the_cap_when_the_stop_fails() {
    let temp = tempfile::tempdir().unwrap();
    let out = temp.path().join("out");
    let plan = record_plan(&["record", "--seconds", "20", "--out", out.to_str().unwrap()]);
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(|method| match method {
            "trace.stop" => {
                Ok(Err(json!({"code": "timeout", "message": "the daemon did not answer"})))
            }
            _ => Ok(Ok(json!({"recording": true}))),
        }),
    };
    let failure =
        record(&plan, &mut app, &FakeWait::new(Waited::Elapsed), &PerfettoExport, &mut no_notes())
            .unwrap_err();
    assert_eq!(failure.exit_code, 1);
    assert_eq!(failure.error["code"], json!("trace.stop_failed"));
    let message = failure.error["message"].as_str().unwrap();
    assert!(message.contains("30") && message.contains("the daemon did not answer"), "{message}");
}

#[test]
fn cli_trace_start_on_an_app_without_trace_methods_exits_5() {
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(|_| {
            Ok(Err(json!({"code": "method_not_found", "message": "unknown method"})))
        }),
    };
    let failure = execute(
        Verb::Start(StartPlan::default()),
        &mut app,
        &FakeWait::new(Waited::Elapsed),
        &PerfettoExport,
        &mut no_notes(),
    )
    .unwrap_err();
    assert_eq!(failure.exit_code, 5);
    let mut transport = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(|_| Err(json!({"code": "app.unreachable", "message": "no app"}))),
    };
    let failure = execute(
        Verb::Status,
        &mut transport,
        &FakeWait::new(Waited::Elapsed),
        &PerfettoExport,
        &mut no_notes(),
    )
    .unwrap_err();
    assert_eq!(failure.exit_code, 3);
    assert_eq!(transport.calls[0], ("trace.status".to_owned(), json!({})));
}

#[test]
fn cli_trace_status_text_lists_the_app_and_daemon_processes() {
    let temp = tempfile::tempdir().unwrap();
    let mut reply = stop_reply(temp.path());
    reply["recording"] = json!(true);
    reply["daemon"]["total_bytes"] = json!(100);
    reply["daemon"]["total_cap_bytes"] = json!(1000);
    let text = status_text(&reply, &crate::localization::catalog().trace);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 5, "{text}");
    assert!(lines[0].contains("100") && lines[0].contains("1000"), "{text}");
    assert!(lines[1].starts_with("app 10: idle "), "{text}");
    assert!(lines[2].starts_with("daemon 20: idle "), "{text}");
    assert_eq!(lines[4], "holder -: untraced holder_untraced");
}
