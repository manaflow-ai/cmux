//! `cmux browser <browser_…> navigate|back|forward|reload|activate|key` on a
//! browser the cmux app draws itself (WebKit or CEF). The daemon has no CDP
//! session for such a page: it refuses with `browser_rendered_by_app` and
//! names the page's tab. The CLI then runs the verb through the app's own
//! `browser.page.*` method for that tab, the path `cmux browser tab_… <verb>`
//! takes, including raw mouse, wheel, text and key input
//! (`browser.page.mouse|wheel|insert_text|key`).
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const BROWSER: &str = "browser_88888888888888888888888888888888";
const TAB: &str = "tab_77777777777777777777777777777777";
const URL: &str = "https://example.org/";
static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

#[test]
fn navigate_on_an_app_drawn_browser_runs_through_the_app() {
    let run = run(&["--json", "browser", BROWSER, "navigate", "--url", URL]);
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["method"], "browser.page.navigate", "{call}");
    assert_eq!(call["params"]["tab"], TAB, "{call}");
    assert_eq!(call["params"]["url"], URL, "{call}");
    let reply: Value = serde_json::from_slice(&run.output.stdout).expect("JSON reply");
    assert_eq!(reply["value"]["tab"], TAB, "{reply}");
}

#[test]
fn history_verbs_activate_and_a_key_press_on_an_app_drawn_browser_run_through_the_app() {
    let cases: [(&[&str], &str, Value); 5] = [
        (&["back"], "browser.page.back", json!({"tab": TAB})),
        (&["forward"], "browser.page.forward", json!({"tab": TAB})),
        (&["reload"], "browser.page.reload", json!({"tab": TAB})),
        (&["activate"], "browser.page.select_tab", json!({"tab": TAB})),
        (
            &["key", "--key", "Enter", "--kind", "press"],
            "browser.page.press",
            json!({"tab": TAB, "key": "Enter"}),
        ),
    ];
    for (verb, method, expected) in cases {
        let mut args = vec!["--json", "browser", BROWSER];
        args.extend_from_slice(verb);
        let run = run(&args);
        assert!(run.output.status.success(), "{verb:?}: {}", run.stderr());
        let [call] = run.app.as_slice() else { panic!("{verb:?}: one app call: {:?}", run.app) };
        assert_eq!(call["method"], method, "{verb:?}: {call}");
        for (key, value) in expected.as_object().unwrap() {
            assert_eq!(&call["params"][key], value, "{verb:?}: {call}");
        }
    }
}

#[test]
fn raw_mouse_wheel_text_and_key_input_on_an_app_drawn_browser_run_through_the_app() {
    let cases: [(&[&str], &str, Value); 5] = [
        (
            &[
                "mouse",
                "--kind",
                "down",
                "--x-px",
                "10",
                "--y-px",
                "20",
                "--pointer-frame-seq",
                "1",
                "--button",
                "left",
                "--click-count",
                "1",
            ],
            "browser.page.mouse",
            json!({"tab": TAB, "kind": "down", "x": 10.0, "y": 20.0, "button": "left",
                "click_count": 1}),
        ),
        (
            &["mouse", "--kind", "move", "--x-px", "1", "--y-px", "2", "--pointer-frame-seq", "1"],
            "browser.page.mouse",
            json!({"tab": TAB, "kind": "move", "x": 1.0, "y": 2.0}),
        ),
        (
            &[
                "wheel",
                "--delta-x",
                "0",
                "--delta-y",
                "120",
                "--x-px",
                "5",
                "--y-px",
                "6",
                "--pointer-frame-seq",
                "1",
            ],
            "browser.page.wheel",
            json!({"tab": TAB, "x": 5.0, "y": 6.0, "dx": 0.0, "dy": 120.0}),
        ),
        (
            &["text", "--text", "hello"],
            "browser.page.insert_text",
            json!({"tab": TAB, "text": "hello"}),
        ),
        (
            &["key", "--key", "k", "--kind", "down", "--modifiers", "meta"],
            "browser.page.key",
            json!({"tab": TAB, "key": "k", "kind": "down", "modifiers": ["meta"]}),
        ),
    ];
    for (verb, method, expected) in cases {
        let mut args = vec!["--json", "browser", BROWSER];
        args.extend_from_slice(verb);
        let run = run(&args);
        assert!(run.output.status.success(), "{verb:?}: {}", run.stderr());
        let [call] = run.app.as_slice() else { panic!("{verb:?}: one app call: {:?}", run.app) };
        assert_eq!(call["method"], method, "{verb:?}: {call}");
        for (key, value) in expected.as_object().unwrap() {
            assert_eq!(&call["params"][key], value, "{verb:?}: {call}");
        }
    }
}

struct Finished {
    output: Output,
    app: Vec<Value>,
}

impl Finished {
    fn stderr(&self) -> String {
        String::from_utf8_lossy(&self.output.stderr).into_owned()
    }
}

fn run(args: &[&str]) -> Finished {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
    let dir: PathBuf =
        Path::new("/tmp").join(format!("cmux-broute-{}-{stamp}-{sequence}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let daemon_socket = dir.join("mux.sock");
    let app_socket = dir.join("app.sock");
    let daemon = fake_daemon(&daemon_socket);
    let done = Arc::new(AtomicBool::new(false));
    let app = fake_app(&app_socket, done.clone());
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(&app_socket)
        .args(args)
        .env("CMUX_TUI_SOCKET", &daemon_socket)
        .env("LC_ALL", "en_US.UTF-8")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    let _ = daemon.join();
    let app = app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    Finished { output, app }
}

/// A daemon that refuses every browser effect the way the real one does for
/// an app-drawn browser.
fn fake_daemon(socket: &Path) -> JoinHandle<()> {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else { return };
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            let request: Value = serde_json::from_str(&line).expect("CLI sent invalid JSON");
            line.clear();
            let response = if request["cmd"] == "set-client-info" {
                json!({"id": request["id"], "ok": true, "data": {}})
            } else {
                let operation = request["operation"].as_str().unwrap_or_default().to_owned();
                if operation.starts_with("browser.") {
                    json!({"protocol": "cmux.protocol/2", "type": "response", "id": request["id"],
                        "ok": false, "error": {"code": "operation.failed",
                        "message": "the cmux app draws this browser",
                        "details": {"operation": operation, "reason": "the cmux app draws this browser",
                            "extra": {"code": "browser_rendered_by_app", "tab_id": TAB,
                                "browser_id": BROWSER}},
                        "retryable": false}})
                } else {
                    json!({"protocol": "cmux.protocol/2", "type": "response", "id": request["id"],
                        "ok": false, "error": {"code": "resource.not_found",
                        "message": format!("unexpected {operation}"), "details": {},
                        "retryable": false}})
                }
            };
            if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err() {
                break;
            }
        }
    })
}

/// An app control socket that answers each `browser.page.*` call as the app
/// does (`{tab, …}`) and records it.
fn fake_app(socket: &Path, done: Arc<AtomicBool>) -> JoinHandle<Vec<Value>> {
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
                        let response = json!({"id": request["id"], "ok": true,
                            "result": {"tab": request["params"]["tab"], "ran": true}});
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
