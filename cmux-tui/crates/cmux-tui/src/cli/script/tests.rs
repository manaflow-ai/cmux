//! `cmux script` parsing, output, and the wire exchange against a fake daemon.

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};
use tokio::sync::mpsc;

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|w| (*w).to_string()).collect()
}

#[test]
fn run_takes_a_file_inline_code_or_stdin_with_arguments() {
    assert_eq!(
        parse(&words(&[
            "run",
            "deploy.js",
            "env=prod",
            "n=3",
            "--args",
            r#"{"dry":true}"#,
            "--timeout",
            "500"
        ]))
        .unwrap(),
        Action::Run {
            source: Source::File("deploy.js".into()),
            args: json!({ "env": "prod", "n": "3", "dry": true }),
            timeout_ms: Some(500),
        }
    );
    assert_eq!(
        parse(&words(&["run", "-e", "1 + 1"])).unwrap(),
        Action::Run { source: Source::Inline("1 + 1".into()), args: json!({}), timeout_ms: None }
    );
    assert_eq!(
        parse(&words(&["run", "-", "a=b=c"])).unwrap(),
        Action::Run { source: Source::Stdin, args: json!({ "a": "b=c" }), timeout_ms: None }
    );
    assert_eq!(parse(&words(&["repl"])).unwrap(), Action::Repl { timeout_ms: None });
    assert_eq!(
        parse(&words(&["repl", "--timeout", "10"])).unwrap(),
        Action::Repl { timeout_ms: Some(10) }
    );
    assert_eq!(parse(&words(&["types"])).unwrap(), Action::Types);
    assert_eq!(parse(&words(&["run", "--help"])).unwrap(), Action::Help);
    // A file name may contain `=` when it looks like a path.
    assert_eq!(
        parse(&words(&["run", "./a=b.js", "k=v"])).unwrap(),
        Action::Run {
            source: Source::File("./a=b.js".into()),
            args: json!({ "k": "v" }),
            timeout_ms: None
        }
    );
}

#[test]
fn bad_run_lines_are_usage_errors() {
    for line in [
        &["run"][..],
        &["run", "-e"],
        &["run", "x.js", "y.js"],
        &["run", "x.js", "--args", "[1]"],
        &["run", "x.js", "--args", "{"],
        &["run", "x.js", "--timeout", "soon"],
        &["run", "x.js", "--timeout", "0"],
        &["run", "x.js", "=v"],
        &["run", "-e", "1", "-e", "2"],
        &["run", "-", "-"],
        &["walk"],
        &[],
    ] {
        assert!(parse(&words(line)).is_err(), "{line:?}");
    }
}

#[test]
fn typescript_files_are_refused_and_other_sources_load() {
    let error = load(&Source::File("x.ts".into()), || unreachable!()).unwrap_err();
    assert!(error.contains("x.ts"), "{error}");
    assert_eq!(load(&Source::Inline("1".into()), || unreachable!()).unwrap(), "1");
    assert_eq!(load(&Source::Stdin, || Ok("2".into())).unwrap(), "2");
    let dir = std::env::temp_dir().join(format!("cmux-script-load-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.js");
    std::fs::write(&file, "3").unwrap();
    assert_eq!(load(&Source::File(file), || unreachable!()).unwrap(), "3");
    assert!(load(&Source::File(dir.join("missing.js")), || unreachable!()).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn types_are_the_generated_global_plus_the_script_additions() {
    assert!(TYPES.contains("declare const cmux: CmuxGlobal"));
    assert!(TYPES.contains("wait<T = unknown>(stream: string"));
    assert!(
        TYPES.find("declare const cmux").unwrap()
            < TYPES.find("args: Record<string, unknown>").unwrap()
    );
}

#[test]
fn values_render_for_people_and_for_machines() {
    assert_eq!(render(&json!(null), OutputMode::Human), None);
    assert_eq!(render(&json!("hi"), OutputMode::Human).as_deref(), Some("hi"));
    assert_eq!(render(&json!({ "a": 1 }), OutputMode::Human).as_deref(), Some("{\n  \"a\": 1\n}"));
    assert_eq!(render(&json!("hi"), OutputMode::Json).as_deref(), Some("\"hi\""));
    assert_eq!(render(&json!(null), OutputMode::Json).as_deref(), Some("null"));
    assert_eq!(render(&json!(1), OutputMode::Quiet), None);
    let ok = Outcome::Answer(json!({ "id": "script-run-1", "ok": true, "data": { "value": 2 } }));
    assert_eq!(report(&ok, OutputMode::Human), (Some("2".into()), None, 0));
    let failed = Outcome::Answer(
        json!({ "ok": false, "error_code": "selector.not_found", "error": "no tab", "error_details": { "op": "tab.focus" } }),
    );
    let (_, text, code) = report(&failed, OutputMode::Human);
    assert_eq!(code, 1);
    assert_eq!(text.unwrap(), "cmux: selector.not_found: no tab\n{\"op\":\"tab.focus\"}");
    let old = Outcome::Answer(json!({
        "ok": false,
        "error": "bad request: unknown variant `script-run`, expected one of `identify`"
    }));
    assert!(report(&old, OutputMode::Human).1.unwrap().contains(messages().unsupported_daemon));
    // A new daemon's own bad-request keeps its text.
    let new = Outcome::Answer(
        json!({ "ok": false, "error_code": "bad-request", "error": "unknown variant `script-walk`" }),
    );
    assert!(report(&new, OutputMode::Human).1.unwrap().starts_with("cmux: bad-request:"));
    let dropped =
        Outcome::Answer(json!({ "ok": true, "data": { "value": null, "dropped_log_lines": 7 } }));
    let (out, note, code) = report(&dropped, OutputMode::Human);
    assert_eq!((out, code), (None, 0));
    assert!(note.unwrap().contains('7'));
    assert_eq!(report(&Outcome::Closed, OutputMode::Human).2, 3);
    assert_eq!(
        report(&Outcome::Cancelled { confirmed: true }, OutputMode::Human).2,
        EXIT_CANCELLED
    );
}

struct FakeInterrupts(mpsc::UnboundedReceiver<()>);

impl Interrupts for FakeInterrupts {
    async fn next(&mut self) {
        if self.0.recv().await.is_none() {
            std::future::pending::<()>().await;
        }
    }
}

/// The daemon side of the connection.
struct Daemon {
    lines: Lines<BufReader<tokio::io::ReadHalf<DuplexStream>>>,
    writer: tokio::io::WriteHalf<DuplexStream>,
}

impl Daemon {
    async fn read(&mut self) -> Value {
        let line = self.lines.next_line().await.unwrap().expect("a request line");
        serde_json::from_str(&line).unwrap()
    }

    async fn write(&mut self, value: Value) {
        let mut line = value.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes()).await.unwrap();
    }
}

type Client =
    (Lines<BufReader<tokio::io::ReadHalf<DuplexStream>>>, tokio::io::WriteHalf<DuplexStream>);

fn pair() -> (Client, Daemon) {
    let (client, daemon) = tokio::io::duplex(64 * 1024);
    let (client_read, client_write) = tokio::io::split(client);
    let (daemon_read, daemon_write) = tokio::io::split(daemon);
    (
        (BufReader::new(client_read).lines(), client_write),
        Daemon { lines: BufReader::new(daemon_read).lines(), writer: daemon_write },
    )
}

#[tokio::test]
async fn run_sends_the_code_prints_logs_as_they_come_and_returns_the_answer() {
    let ((mut lines, mut writer), mut daemon) = pair();
    let (_tx, rx) = mpsc::unbounded_channel();
    let mut interrupts = FakeInterrupts(rx);
    let request = run_request("cmux.args.n", &json!({ "n": "1" }), Some(900));
    let server = tokio::spawn(async move {
        let request = daemon.read().await;
        assert_eq!(request["cmd"], "script-run");
        assert_eq!(request["code"], "cmux.args.n");
        assert_eq!(request["args"], json!({ "n": "1" }));
        assert_eq!(request["timeout_ms"], 900);
        let id = request["id"].clone();
        daemon.write(json!({ "event": "script-log", "request": id, "level": "info", "message": "hello" })).await;
        daemon.write(json!({ "event": "other" })).await;
        daemon.write(json!({ "id": id, "ok": true, "data": { "value": "1" } })).await;
        daemon
    });
    let mut logs = Vec::new();
    let outcome = exchange(
        &mut lines,
        &mut writer,
        &request,
        &mut interrupts,
        &mut |l, m| logs.push((l.to_string(), m.to_string())),
        CANCEL_WAIT,
    )
    .await;
    server.await.unwrap();
    assert_eq!(logs, [("info".to_string(), "hello".to_string())]);
    assert_eq!(report(&outcome, OutputMode::Human), (Some("1".into()), None, 0));
}

#[tokio::test]
async fn ctrl_c_sends_cancel_request_for_the_running_cell() {
    let ((mut lines, mut writer), mut daemon) = pair();
    let (tx, rx) = mpsc::unbounded_channel();
    let mut interrupts = FakeInterrupts(rx);
    let request = run_request("await new Promise(() => {})", &json!({}), None);
    let server = tokio::spawn(async move {
        let request = daemon.read().await;
        tx.send(()).unwrap();
        let cancel = daemon.read().await;
        assert_eq!(cancel["cmd"], "cancel-request");
        assert_eq!(cancel["target"], request["id"]);
        daemon.write(json!({ "id": request["id"], "ok": false, "error_code": "script.cancelled", "error": "the script was cancelled" })).await;
        (daemon, tx)
    });
    let outcome =
        exchange(&mut lines, &mut writer, &request, &mut interrupts, &mut |_, _| {}, CANCEL_WAIT)
            .await;
    let _ = server.await.unwrap();
    assert_eq!(outcome, Outcome::Cancelled { confirmed: true });
}

#[derive(Default)]
struct Recorder {
    prompts: Vec<String>,
    values: Vec<Value>,
    errors: Vec<String>,
    logs: Vec<(String, String)>,
}

impl ReplOutput for Recorder {
    fn prompt(&mut self, text: &str) {
        self.prompts.push(text.to_string());
    }
    fn value(&mut self, value: &Value) {
        self.values.push(value.clone());
    }
    fn error(&mut self, text: &str) {
        self.errors.push(text.to_string());
    }
    fn log(&mut self, level: &str, message: &str) {
        self.logs.push((level.to_string(), message.to_string()));
    }
}

#[tokio::test]
async fn the_repl_keeps_one_session_joins_continued_lines_and_restarts_ended_sessions() {
    let ((mut lines, mut writer), mut daemon) = pair();
    let (_tx, rx) = mpsc::unbounded_channel();
    let mut interrupts = FakeInterrupts(rx);
    let input_text =
        "const a = 1\nfunction f() {\\\n  return a + 1 }\nf()\nwhile (true) {}\na\n.exit\n";
    let mut input = BufReader::new(input_text.as_bytes()).lines();
    let server = tokio::spawn(async move {
        let mut cells = Vec::new();
        let mut closed: Vec<String> = Vec::new();
        let mut sessions = 0;
        loop {
            let request = daemon.read().await;
            let id = request["id"].clone();
            match request["cmd"].as_str().unwrap() {
                "script-repl-open" => {
                    sessions += 1;
                    daemon.write(json!({ "id": id, "ok": true, "data": { "session": format!("scr_{sessions}") } })).await;
                }
                "script-repl-eval" => {
                    let code = request["code"].as_str().unwrap().to_string();
                    cells.push((request["session"].as_str().unwrap().to_string(), code.clone()));
                    let answer = match code.as_str() {
                        "f()" => json!({ "id": id, "ok": true, "data": { "value": 2 } }),
                        "while (true) {}" => {
                            json!({ "id": id, "ok": false, "error_code": "script.cpu", "error": "too long" })
                        }
                        "a" => {
                            json!({ "id": id, "ok": false, "error_code": "script.error", "error": "ReferenceError: a is not defined" })
                        }
                        _ => json!({ "id": id, "ok": true, "data": { "value": null } }),
                    };
                    daemon.write(answer).await;
                }
                "script-repl-close" => {
                    closed.push(request["session"].as_str().unwrap().to_string());
                    if request["session"] == "scr_2" {
                        return (cells, closed);
                    }
                }
                other => panic!("unexpected {other}"),
            }
        }
    });
    let mut out = Recorder::default();
    let code =
        repl(&mut lines, &mut writer, &mut input, &mut interrupts, &mut out, None, CANCEL_WAIT)
            .await;
    let (cells, closed) = server.await.unwrap();
    assert_eq!(code, 0);
    // The ended session is closed before the new one opens; the last on exit.
    assert_eq!(closed, ["scr_1", "scr_2"]);
    assert_eq!(
        cells,
        [
            ("scr_1".to_string(), "const a = 1".to_string()),
            ("scr_1".to_string(), "function f() {\n  return a + 1 }".to_string()),
            ("scr_1".to_string(), "f()".to_string()),
            ("scr_1".to_string(), "while (true) {}".to_string()),
            ("scr_2".to_string(), "a".to_string()),
        ]
    );
    assert_eq!(out.values, [json!(2)]);
    assert!(out.prompts.contains(&"...> ".to_string()));
    assert_eq!(out.errors.len(), 3, "{:?}", out.errors);
    assert_eq!(out.errors[1], messages().restarted);
}
