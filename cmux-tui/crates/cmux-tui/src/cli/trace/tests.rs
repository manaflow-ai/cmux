use std::cell::{Cell, RefCell};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::bundle::{ChromiumFile, RemoteMachine, RingFile, RingMachine};
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

/// Waits nothing; remembers what it was asked to wait. Its clock moves by each wait.
struct FakeWait {
    asked: Cell<Option<Duration>>,
    answer: Waited,
    origin: Instant,
    elapsed: Cell<Duration>,
}

impl FakeWait {
    fn new(answer: Waited) -> Self {
        Self {
            asked: Cell::new(None),
            answer,
            origin: Instant::now(),
            elapsed: Cell::new(Duration::ZERO),
        }
    }
}

impl RecordWait for FakeWait {
    fn wait(&self, duration: Duration) -> Waited {
        self.asked.set(Some(duration));
        self.elapsed.set(self.elapsed.get() + duration);
        self.answer
    }

    fn now(&self) -> Instant {
        self.origin + self.elapsed.get()
    }
}

/// Writes a marker file as the Perfetto trace and keeps the bundle it was given.
#[derive(Default)]
struct FakeExporter {
    seen: RefCell<Option<(Bundle, PathBuf)>>,
}

impl TraceExporter for FakeExporter {
    fn available(&self) -> bool {
        true
    }

    fn export(&self, bundle: &Bundle, to: &Path) -> Result<(), String> {
        std::fs::write(to, b"perfetto").map_err(|error| error.to_string())?;
        *self.seen.borrow_mut() = Some((bundle.clone(), to.to_owned()));
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

impl ScriptedApp {
    fn methods(&self) -> Vec<&str> {
        self.calls.iter().map(|(method, _)| method.as_str()).collect()
    }
}

fn no_notes() -> impl FnMut(String) {
    |_| {}
}

/// Task 020's stop reply (`ControlRouter+Trace.swift` `finish`): `app` is the app ring's
/// `json(_:)` (`state`, `path`, `recording_bytes`), `daemon` the daemon's `trace-stop` reply
/// (`server/trace_control.rs` `reply_json`), `chromium` the Chromium part's reply (task 051: the
/// JSON file and its clock offset). The files are written under `dir`.
fn stop_reply(dir: &Path) -> Value {
    let ring = |name: &str, bytes: &[u8]| {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path.display().to_string()
    };
    json!({
        "recording": false,
        "stopped_by": "request",
        "app": {"state": "stopped", "path": ring("app.recording.cmxtrace", b"app ring"), "recording_bytes": 8},
        "daemon": {
            "op": "trace-stop",
            "recording": false,
            "processes": [
                {"role": "daemon", "pid": 20, "state": "idle",
                 "recording_path": ring("daemon-20.recording.cmxtrace", b"daemon ring"),
                 "recording_bytes": 11, "records_dropped": 0},
                {"role": "terminal-host", "pid": 30, "state": "idle",
                 "recording_path": ring("terminal-host-30.recording.cmxtrace", b"host ring"),
                 "recording_bytes": 9, "records_dropped": 0},
                {"role": "holder", "state": "idle"},
                {"role": "acpmux", "pid": null, "state": "untraced", "reason": "over_total_cap"},
            ],
            "bytes_by_role": {"daemon": 11, "terminal-host": 9},
            "total_bytes": 20,
            "total_cap_bytes": 1000,
        },
        "chromium": {"state": "stopped", "path": ring("cef-trace.json", b"{\"traceEvents\":[]}"), "offset_ns": -1500},
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
    for help in [&["--help"][..], &["help"], &[], &["record", "--help"], &["export", "-h"]] {
        assert_eq!(parsed(help), Ok(Invocation::Help), "{help:?}");
    }
    let usage = crate::localization::catalog().trace.usage;
    for option in [
        "record",
        "start",
        "stop",
        "status",
        "export",
        "--seconds",
        "--out",
        "--in",
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
        // An empty --out would be the current directory.
        &["record", "--seconds", "3", "--out="],
        &["record", "--seconds", "3", "--out", ""],
        &["record", "--seconds", "3", "--out", "  "],
        &["record", "--seconds", "0", "--out", "d"],
        &["record", "--seconds", "591", "--out", "d"],
        &["record", "--seconds", "two", "--out", "d"],
        &["record", "--seconds", "3", "--out", "d", "--seconds-cap", "9"],
        &["record", "--seconds", "3", "--out", "d", "--in", "e"],
        &["record", "--seconds", "3", "--out", "d", "--categories", "motoin"],
        &["record", "--seconds", "3", "--out", "d", "--categories", "key"],
        &["record", "--seconds"],
        &["start", "--seconds-cap", "601"],
        &["start", "--out", "d"],
        &["stop", "--keys"],
        &["status", "extra"],
        &["export"],
        &["export", "--in="],
        &["export", "--in", "d", "--out="],
        &["export", "--in", "d", "--seconds", "3"],
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
    assert_eq!(
        parsed(&["export", "--in", "d", "--out=t.pftrace"]),
        Ok(Invocation::Verb(Verb::Export(ExportPlan {
            dir: PathBuf::from("d"),
            to: Some(PathBuf::from("t.pftrace")),
        })))
    );
}

/// Acceptance (task 021): over a real socket, `record` calls `trace.start` then `trace.stop`
/// (no read barrier, a connection each), waits its seconds, and leaves every ring, the
/// Chromium JSON, the manifest and the Perfetto trace in `--out`. The stop reply is task 020's.
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
        "--chromium",
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
        json!({"categories": ["motion"], "keys": false, "chromium": true, "seconds_cap": 17})
    );
    assert_eq!(requests[1]["params"], json!({}));
    assert_eq!(wait.asked.get(), Some(Duration::from_secs(7)));

    for (name, bytes) in [
        ("app.recording.cmxtrace", &b"app ring"[..]),
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
    assert_eq!(
        manifest["rings"][1],
        json!({"role": "daemon", "pid": 20, "machine": "local", "file": "rings/daemon-20.recording.cmxtrace"})
    );
    assert_eq!(manifest["remotes"], json!([]));
    assert_eq!(manifest["chromium"], json!({"file": CHROMIUM_FILE, "offset_ns": -1500}));
    assert_eq!(
        manifest["not_copied"],
        json!([
            {"role": "holder", "pid": null, "reason": "idle"},
            {"role": "acpmux", "pid": null, "reason": "over_total_cap"},
        ])
    );

    assert_eq!(result["perfetto"], json!(out.join(PERFETTO_FILE).display().to_string()));
    let (bundle, to) = exporter.seen.borrow_mut().take().expect("the exporter ran");
    assert_eq!(to, out.join(PERFETTO_FILE));
    assert_eq!(bundle.dir, out);
    assert_eq!(bundle.rings.len(), 3);
    assert!(bundle.rings.iter().all(|ring| ring.machine == RingMachine::Local));
    assert_eq!(
        bundle.chromium,
        Some(ChromiumFile { path: out.join(CHROMIUM_FILE), offset_ns: Some(-1500) })
    );
}

/// A ring or Chromium file the stop reply names but that is gone, and parts that did not
/// answer, are listed in `not_copied`; nothing is silently dropped.
#[test]
fn cli_trace_record_lists_every_missing_file_in_not_copied() {
    let temp = tempfile::tempdir().unwrap();
    let mut stop = stop_reply(temp.path());
    std::fs::remove_file(stop["app"]["path"].as_str().unwrap()).unwrap();
    stop["daemon"] = json!({"state": "error", "error": "timeout", "message": "no answer"});
    stop["chromium"] = json!({"state": "untraced", "reason": "unsupported"});
    let out = temp.path().join("out");
    let plan =
        record_plan(&["record", "--seconds", "1", "--out", out.to_str().unwrap(), "--chromium"]);
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(move |method| {
            Ok(Ok(if method == "trace.stop" { stop.clone() } else { json!({}) }))
        }),
    };
    let result =
        record(&plan, &mut app, &FakeWait::new(Waited::Elapsed), &PerfettoExport, &mut no_notes())
            .unwrap();
    let not_copied = result["not_copied"].as_array().unwrap();
    let roles: Vec<&str> = not_copied.iter().map(|skip| skip["role"].as_str().unwrap()).collect();
    assert_eq!(roles, ["app", "daemon", "chromium"], "{not_copied:?}");
    assert_eq!(not_copied[1]["reason"], json!("timeout"));
    assert_eq!(not_copied[2]["reason"], json!("unsupported"));
    assert_eq!(result["rings"], json!([]));
    assert_eq!(result["chromium"], Value::Null);

    // Chromium asked for but absent from the reply.
    let mut bare = stop_reply(temp.path());
    bare.as_object_mut().unwrap().remove("chromium");
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(move |method| {
            Ok(Ok(if method == "trace.stop" { bare.clone() } else { json!({}) }))
        }),
    };
    let out = temp.path().join("out2");
    let plan =
        record_plan(&["record", "--seconds", "1", "--out", out.to_str().unwrap(), "--chromium"]);
    let result =
        record(&plan, &mut app, &FakeWait::new(Waited::Elapsed), &PerfettoExport, &mut no_notes())
            .unwrap();
    assert!(
        result["not_copied"]
            .as_array()
            .unwrap()
            .contains(&json!({"role": "chromium", "pid": null, "reason": "no_reply"})),
        "{result}"
    );
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

/// A refused start creates nothing in `--out`, so the same command can run again.
#[test]
fn cli_trace_record_whose_start_is_refused_leaves_out_unused() {
    let temp = tempfile::tempdir().unwrap();
    let out = temp.path().join("out");
    let plan = record_plan(&["record", "--seconds", "1", "--out", out.to_str().unwrap()]);
    let mut refusing = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(|_| {
            Ok(Err(
                json!({"code": "already_recording", "message": "a trace recording is already running"}),
            ))
        }),
    };
    let failure = record(
        &plan,
        &mut refusing,
        &FakeWait::new(Waited::Elapsed),
        &PerfettoExport,
        &mut no_notes(),
    )
    .unwrap_err();
    assert_eq!(failure.exit_code, 1);
    assert_eq!(refusing.methods(), ["trace.start"]);
    assert!(!out.exists(), "a refused start created {}", out.display());

    let stop = stop_reply(temp.path());
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(move |method| {
            Ok(Ok(if method == "trace.stop" { stop.clone() } else { json!({}) }))
        }),
    };
    let result =
        record(&plan, &mut app, &FakeWait::new(Waited::Elapsed), &PerfettoExport, &mut no_notes())
            .unwrap();
    assert_eq!(result["rings"].as_array().map(Vec::len), Some(3));
}

/// The start's request went out and its reply never came: `record` sends a stop, and says
/// whether a recording may still run.
#[test]
fn cli_trace_record_stops_a_start_whose_reply_was_lost() {
    let lost =
        || Err(json!({"code": "app.transport", "message": "Resource temporarily unavailable"}));
    let temp = tempfile::tempdir().unwrap();
    let out = temp.path().join("out");
    let plan = record_plan(&["record", "--seconds", "20", "--out", out.to_str().unwrap()]);
    let run = |reply: Box<dyn FnMut(&str) -> AppReply>| {
        let mut app = ScriptedApp { calls: Vec::new(), reply };
        let failure = record(
            &plan,
            &mut app,
            &FakeWait::new(Waited::Elapsed),
            &PerfettoExport,
            &mut no_notes(),
        )
        .unwrap_err();
        (app.methods().join(" "), failure)
    };

    // The app had started: the stop ends it.
    let (methods, failure) = run(Box::new(move |method| match method {
        "trace.start" => lost(),
        _ => Ok(Ok(json!({"recording": false, "stopped_by": "request"}))),
    }));
    assert_eq!(methods, "trace.start trace.stop");
    assert_eq!(failure.exit_code, 3);
    assert_eq!(failure.error["code"], json!("trace.start_unanswered"));
    let message = failure.error["message"].as_str().unwrap();
    assert!(message.contains("Resource temporarily unavailable"), "{message}");
    assert!(!out.exists());

    // The app is still starting (busy): the cap ends the recording.
    let (methods, failure) = run(Box::new(move |method| match method {
        "trace.start" => lost(),
        _ => Ok(Err(json!({"code": "busy", "message": "a trace start or stop is still running"}))),
    }));
    assert_eq!(methods, "trace.start trace.stop");
    assert_eq!(failure.error["code"], json!("trace.start_unanswered"));
    let message = failure.error["message"].as_str().unwrap();
    assert!(message.contains("30"), "{message}");

    // Nothing had started: the plain transport error.
    let (_, failure) = run(Box::new(move |method| match method {
        "trace.start" => lost(),
        _ => Ok(Err(json!({"code": "not_recording", "message": "no trace recording is running"}))),
    }));
    assert_eq!(failure.error["code"], json!("app.transport"));

    // No connection at all: the request never went out, so no stop is sent.
    let (methods, failure) =
        run(Box::new(|_| Err(json!({"code": "app.unreachable", "message": "no app"}))));
    assert_eq!(methods, "trace.start");
    assert_eq!(failure.exit_code, 3);
}

/// Over a real socket whose app accepts the start and never answers.
#[test]
fn cli_trace_record_over_a_socket_whose_start_reply_never_comes() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("a.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut methods = Vec::new();
        // The start: read it, then drop the connection unanswered.
        for answer in [false, true] {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            methods.push(request["method"].as_str().unwrap().to_owned());
            if answer {
                let reply = json!({"id": 1, "ok": true, "result": {"recording": false}});
                let mut stream = stream;
                stream.write_all(format!("{reply}\n").as_bytes()).unwrap();
            }
        }
        methods
    });
    let global = GlobalArgs { app_socket: Some(socket), ..GlobalArgs::default() };
    let out = temp.path().join("out");
    let plan = record_plan(&["record", "--seconds", "5", "--out", out.to_str().unwrap()]);
    let failure = record(
        &plan,
        &mut AppTrace { global: &global },
        &FakeWait::new(Waited::Elapsed),
        &PerfettoExport,
        &mut no_notes(),
    )
    .unwrap_err();
    assert_eq!(server.join().unwrap(), ["trace.start", "trace.stop"]);
    assert_eq!(failure.error["code"], json!("trace.start_unanswered"));
    assert_eq!(failure.error["details"]["error"]["code"], json!("app.transport"));
    assert!(!out.exists());
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
    assert_eq!(app.methods(), ["trace.start", "trace.stop"]);
    assert_eq!(result["interrupted"], json!(true));
    assert_eq!(result["export"], json!("unavailable"));
    assert_eq!(result["rings"].as_array().map(Vec::len), Some(3));
    assert_eq!(notes.len(), 2, "the recording note and the early stop");
}

/// The stop comes after the wait, so only the cap's slack is left when it fails: 30 s cap,
/// 20 s waited, 10 s left.
#[test]
fn cli_trace_record_names_the_time_left_when_the_stop_fails() {
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
    assert!(
        message.contains(" 10 s") && message.contains("the daemon did not answer"),
        "{message}"
    );
    assert!(!message.contains("30"), "{message}");
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

/// `export` builds the bundle again from a recorded directory's manifest, offsets and machines
/// included, and calls no app method.
#[test]
fn cli_trace_export_reexports_a_recorded_bundle() {
    let temp = tempfile::tempdir().unwrap();
    let stop = stop_reply(temp.path());
    let out = temp.path().join("out");
    let plan =
        record_plan(&["record", "--seconds", "1", "--out", out.to_str().unwrap(), "--chromium"]);
    let mut app = ScriptedApp {
        calls: Vec::new(),
        reply: Box::new(move |method| {
            Ok(Ok(if method == "trace.stop" { stop.clone() } else { json!({}) }))
        }),
    };
    let recorded =
        record(&plan, &mut app, &FakeWait::new(Waited::Elapsed), &PerfettoExport, &mut no_notes())
            .unwrap();
    assert_eq!(recorded["export"], json!("unavailable"));

    let mut no_app = ScriptedApp { calls: Vec::new(), reply: Box::new(|_| panic!("no call")) };
    let exporter = FakeExporter::default();
    let to = temp.path().join("again.pftrace");
    let (value, text) = execute(
        Verb::Export(ExportPlan { dir: out.clone(), to: Some(to.clone()) }),
        &mut no_app,
        &FakeWait::new(Waited::Elapsed),
        &exporter,
        &mut no_notes(),
    )
    .unwrap();
    assert!(no_app.calls.is_empty());
    assert_eq!(value["perfetto"], json!(to.display().to_string()));
    assert!(text.contains(&to.display().to_string()), "{text}");
    assert_eq!(std::fs::read(&to).unwrap(), b"perfetto");
    let (bundle, _) = exporter.seen.borrow_mut().take().unwrap();
    let names: Vec<_> =
        bundle.rings.iter().map(|ring| (ring.role.as_str(), ring.pid, ring.machine)).collect();
    assert_eq!(
        names,
        [
            ("app", None, RingMachine::Local),
            ("daemon", Some(20), RingMachine::Local),
            ("terminal-host", Some(30), RingMachine::Local)
        ]
    );
    assert_eq!(bundle.rings[1].path, out.join(RINGS_DIR).join("daemon-20.recording.cmxtrace"));
    assert_eq!(
        bundle.chromium,
        Some(ChromiumFile { path: out.join(CHROMIUM_FILE), offset_ns: Some(-1500) })
    );

    // A remote machine's ring keeps its machine and offset.
    let manifest = json!({
        "remotes": [{"name": "linux-lane", "offset_ns": 37_000_000, "error_bound_ns": 2_000_000}],
        "rings": [{"role": "daemon", "pid": 7, "machine": {"remote": 0}, "file": "rings/d.cmxtrace"}],
        "chromium": null,
    });
    let remote = temp.path().join("remote");
    std::fs::create_dir(&remote).unwrap();
    std::fs::write(remote.join(MANIFEST_FILE), manifest.to_string()).unwrap();
    export(&ExportPlan { dir: remote.clone(), to: None }, &exporter).unwrap();
    let (bundle, to) = exporter.seen.borrow_mut().take().unwrap();
    assert_eq!(to, remote.join(PERFETTO_FILE));
    assert_eq!(
        bundle.remotes,
        [RemoteMachine {
            name: "linux-lane".into(),
            offset_ns: 37_000_000,
            error_bound_ns: 2_000_000
        }]
    );
    assert_eq!(bundle.rings[0].machine, RingMachine::Remote(0));
    assert_eq!(
        bundle.rings[0],
        RingFile {
            role: "daemon".into(),
            pid: Some(7),
            machine: RingMachine::Remote(0),
            path: remote.join("rings/d.cmxtrace"),
        }
    );
}

#[test]
fn cli_trace_export_refuses_what_is_not_a_bundle() {
    let temp = tempfile::tempdir().unwrap();
    let exporter = FakeExporter::default();
    let plan = ExportPlan { dir: temp.path().to_owned(), to: None };
    assert_eq!(export(&plan, &exporter).unwrap_err().error["code"], json!("trace.not_a_bundle"));
    for manifest in [
        json!({"rings": [{"role": "app", "file": "../elsewhere"}]}),
        json!({"rings": [{"role": "app", "file": "/etc/passwd"}]}),
        json!({"rings": [{"role": "app", "machine": {"remote": 1}, "file": "rings/a"}]}),
    ] {
        std::fs::write(temp.path().join(MANIFEST_FILE), manifest.to_string()).unwrap();
        let failure = export(&plan, &exporter).unwrap_err();
        assert_eq!(failure.error["code"], json!("trace.not_a_bundle"), "{manifest}");
    }
    assert!(exporter.seen.borrow().is_none());
    std::fs::write(temp.path().join(MANIFEST_FILE), json!({"rings": []}).to_string()).unwrap();
    let failure = export(&plan, &PerfettoExport).unwrap_err();
    assert_eq!(failure.error["code"], json!("trace.export_unavailable"));
}

#[test]
fn cli_trace_status_text_lists_the_app_and_daemon_processes() {
    let temp = tempfile::tempdir().unwrap();
    let mut reply = stop_reply(temp.path());
    reply["recording"] = json!(true);
    reply["daemon"]["total_bytes"] = json!(100);
    let text = status_text(&reply, &crate::localization::catalog().trace);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 7, "{text}");
    assert!(lines[0].contains("100") && lines[0].contains("1000"), "{text}");
    assert!(
        lines[1].starts_with("app -: stopped ") && lines[1].ends_with("app.recording.cmxtrace")
    );
    assert!(lines[2].starts_with("daemon 20: idle "), "{text}");
    assert_eq!(lines[4], "holder -: idle");
    assert_eq!(lines[5], "acpmux -: untraced over_total_cap");
    assert!(lines[6].starts_with("chromium -: stopped ") && lines[6].ends_with("cef-trace.json"));

    // A status reply: `chromium` is a flag, and a failed daemon part is one line.
    let status = json!({
        "recording": false,
        "app": {"state": "idle"},
        "daemon": {"state": "error", "error": "timeout", "message": "no answer"},
        "chromium": true,
    });
    let text = status_text(&status, &crate::localization::catalog().trace);
    assert_eq!(
        text.lines().skip(1).collect::<Vec<_>>(),
        ["app -: idle", "daemon -: error timeout"]
    );
}
