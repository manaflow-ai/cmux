//! `cmux open <url>` and `cmux open -` against an app that serves only the
//! methods the real cmux-next app serves (cx-i2iu, cx-jon0).
//!
//! nxdog71-v2: `cmux open <url>` opened nothing, because the app answered
//! `Unknown method browser.open_split`. cmux-chat (271491197ee3) opens its
//! one-time `/o/<code>` URLs with `cmux open "$code_url" >/dev/null`; `cmux
//! open -` reads URLs from stdin so a token never sits in argv.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const CALLER_TERMINAL: &str = "term_55555555555555555555555555555555";
const NEW_TAB: &str = "tab_77777777777777777777777777777777";
const WORKSPACE: &str = "ws_11111111111111111111111111111111";
const CHAT_CODE: &str = "Zx9k2LqP4wQe";
static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

/// The params the real app's `browser.open_split` takes; any other is
/// refused. `after` is the router's read barrier, which every CLI call sends.
const OPEN_SPLIT_PARAMS: [&str; 8] = [
    "url",
    "workspace_id",
    "terminal_id",
    "focus",
    "transparent_background",
    "idempotency_key",
    "origin",
    "after",
];

#[test]
fn cmux_chat_open_of_a_one_time_code_url_opens_one_tab_in_the_callers_pane() {
    let url = format!("http://127.0.0.1:7739/o/{CHAT_CODE}");
    let run = run(&["open", &url], Some(CALLER_TERMINAL), None);
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["method"], "browser.open_split", "{call}");
    assert_eq!(call["params"]["url"], url.as_str(), "{call}");
    assert_eq!(call["params"]["terminal_id"], CALLER_TERMINAL, "{call}");
    // Not a terminal on stdin/stdout: an agent or script, which never moves the view.
    assert_eq!(call["params"]["focus"], false, "{call}");
    assert!(!run.stdout().contains(CHAT_CODE), "stdout echoed the URL: {}", run.stdout());
    assert!(!run.stderr().contains(CHAT_CODE), "stderr echoed the URL: {}", run.stderr());
}

#[test]
fn open_dash_opens_every_stdin_url_in_order_and_skips_blank_lines() {
    let stdin = "https://example.com/\n\n   \r\nhttps://example.org/?token=abc123\n";
    let run = run(&["open", "-"], Some(CALLER_TERMINAL), Some(stdin));
    assert!(run.output.status.success(), "{}", run.stderr());
    let methods: Vec<_> = run.app.iter().map(|call| call["method"].clone()).collect();
    assert_eq!(methods, vec![json!("browser.open_split"); 2], "{:?}", run.app);
    let urls: Vec<_> = run.app.iter().map(|call| call["params"]["url"].clone()).collect();
    assert_eq!(
        urls,
        vec![json!("https://example.com/"), json!("https://example.org/?token=abc123")]
    );
    assert!(run.app.iter().all(|call| call["params"]["terminal_id"] == CALLER_TERMINAL));
    assert!(!run.stderr().contains("abc123") && !run.stdout().contains("abc123"));
}

#[test]
fn open_dash_refuses_an_invalid_url_before_it_opens_anything() {
    let stdin = "https://example.com/\nnot a url?token=SECRET77\n";
    let run = run(&["open", "-"], None, Some(stdin));
    assert!(!run.output.status.success(), "an invalid URL succeeded");
    assert!(run.app.is_empty(), "opened before validating every line: {:?}", run.app);
    assert!(run.stderr().contains("line 2"), "{}", run.stderr());
    assert!(!run.stderr().contains("SECRET77"), "the error echoed the line: {}", run.stderr());
}

#[test]
fn open_dash_stops_at_the_first_app_refusal() {
    let stdin =
        "https://example.com/\nhttps://refuse.example/?token=SECRET88\nhttps://example.org/\n";
    let run = run(&["open", "-"], None, Some(stdin));
    assert!(!run.output.status.success(), "a refusal succeeded");
    assert_eq!(run.app.len(), 2, "kept opening after a refusal: {:?}", run.app);
    assert!(!run.stderr().contains("SECRET88"), "{}", run.stderr());
}

#[test]
fn open_dash_with_no_url_fails() {
    let run = run(&["open", "-"], None, Some("\n  \n"));
    assert!(!run.output.status.success());
    assert!(run.app.is_empty(), "{:?}", run.app);
}

#[test]
fn open_dash_takes_no_other_target() {
    let run = run(&["open", "-", "https://example.com/"], None, Some("https://example.org/\n"));
    assert!(!run.output.status.success());
    assert!(run.app.is_empty(), "{:?}", run.app);
}

#[test]
fn open_with_a_workspace_names_it_and_keeps_the_view() {
    let run = run(&["open", "--workspace", WORKSPACE, "https://example.com/"], None, None);
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["workspace_id"], WORKSPACE, "{call}");
    assert_eq!(call["params"]["focus"], false, "{call}");
}

struct Finished {
    output: Output,
    app: Vec<Value>,
}

impl Finished {
    fn stderr(&self) -> String {
        String::from_utf8_lossy(&self.output.stderr).into_owned()
    }

    fn stdout(&self) -> String {
        String::from_utf8_lossy(&self.output.stdout).into_owned()
    }
}

fn run(args: &[&str], caller_terminal: Option<&str>, stdin: Option<&str>) -> Finished {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
    let dir: PathBuf =
        Path::new("/tmp").join(format!("cmux-openurl-{}-{stamp}-{sequence}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("app.sock");
    let done = Arc::new(AtomicBool::new(false));
    let app = strict_app(&socket, done.clone());
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .arg("--app-socket")
        .arg(&socket)
        .args(args)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_FOCUS_NEW")
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(terminal) = caller_terminal {
        command.env("CMUX_TUI_TERMINAL_ID", terminal);
    }
    let mut child = command.spawn().unwrap();
    if let Some(text) = stdin {
        let mut pipe = child.stdin.take().unwrap();
        pipe.write_all(text.as_bytes()).unwrap();
    }
    let output = child.wait_with_output().unwrap();
    done.store(true, Ordering::Relaxed);
    let app = app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    Finished { output, app }
}

/// The real app's answer: `browser.open_split` opens a tab unless the URL is
/// not http(s), a param is unknown, or the host is `refuse.example`; every
/// other method is `method_not_found`, as the real router answers.
fn app_response(request: &Value) -> Value {
    let method = request["method"].as_str().unwrap_or_default();
    let params = &request["params"];
    let error = |code: &str, message: String| json!({"id": request["id"], "ok": false, "error": {"code": code, "message": message}});
    if method != "browser.open_split" {
        return error("method_not_found", format!("Unknown method {method}"));
    }
    if let Some(unknown) = params
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, _)| key)
        .find(|key| !OPEN_SPLIT_PARAMS.contains(&key.as_str()))
    {
        return error(
            "invalid_params",
            format!("browser.open_split does not take params.{unknown}"),
        );
    }
    let url = params["url"].as_str().unwrap_or_default();
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return error(
            "invalid_params",
            "browser.open_split opens only absolute http and https URLs".into(),
        );
    }
    if url.contains("refuse.example") {
        return error("unavailable", "openBrowser unavailable: no browser engine".into());
    }
    json!({"id": request["id"], "ok": true, "result": {"tab_id": NEW_TAB, "created": [NEW_TAB],
        "placement": "caller_terminal", "revealed": false, "replayed": false}})
}

fn strict_app(socket: &Path, done: Arc<AtomicBool>) -> JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let received = Arc::new(Mutex::new(Vec::new()));
    std::thread::spawn(move || {
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut writer = stream;
                    let mut line = String::new();
                    while reader.read_line(&mut line).unwrap_or(0) > 0 {
                        let request: Value = serde_json::from_str(&line).unwrap();
                        line.clear();
                        let response = app_response(&request);
                        received.lock().unwrap().push(request);
                        if writeln!(writer, "{response}").is_err() {
                            break;
                        }
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if done.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("app accept: {error}"),
            }
        }
        std::mem::take(&mut *received.lock().unwrap())
    })
}
