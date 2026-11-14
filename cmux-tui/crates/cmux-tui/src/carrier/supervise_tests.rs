//! `carrier supervise` with a shell stand-in for `carrier serve`: the
//! machine's effects run against a real child process (spawn, stderr lines,
//! token lines on stdin, stdin close, SIGTERM, the socket lease). These are
//! the app's old CloudCarrierServe process tests, moved with the lifecycle.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::super::serve_machine::{self, TokenRead};
use super::super::supervise_wire::{AppLine, app_line, error_json, error_of, refresh_delay_at};
use super::*;

/// How long a test waits for any one line.
const LINE_WAIT: Duration = Duration::from_secs(10);

const READY: &str = r#"printf '{"ok":true,"socket":"%s","route":"carrier"}\n' "$1" >&2"#;

/// A fresh directory for one test (removed by the harness at its end).
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-supervise-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn config(dir: &Path, script: &str) -> Config {
    let socket = dir.join("cmux-link-0123456789ab.sock").to_string_lossy().into_owned();
    let launches = dir.join("launches").to_string_lossy().into_owned();
    let script = format!("echo launch >> \"$2\"\n{script}");
    Config {
        program: PathBuf::from("/bin/sh"),
        args: vec!["-c".to_owned(), script, "sh".to_owned(), socket.clone(), launches],
        lease: dir.join("lease"),
        socket,
        ready_deadline: Duration::from_secs(5),
        stop_grace: Duration::from_millis(300),
        kill_after: Duration::from_millis(300),
        lease_wait: Duration::from_secs(5),
        refresh_delay: |_| Duration::from_secs(3600),
        check: |_| Ok(()),
    }
}

struct Harness {
    app: Option<mpsc::UnboundedSender<String>>,
    lines: mpsc::UnboundedReceiver<String>,
    done: tokio::task::JoinHandle<i32>,
    socket: String,
}

impl Harness {
    fn start(config: Config) -> Self {
        let socket = config.socket.clone();
        let (app, input) = mpsc::unbounded_channel();
        let (sink, lines) = mpsc::unbounded_channel();
        let out: Out = Arc::new(move |line| {
            let _ = sink.send(line);
        });
        let done = tokio::spawn(supervise(config, input, out));
        Self { app: Some(app), lines, done, socket }
    }

    fn send(&self, line: Value) {
        if let Some(app) = &self.app {
            app.send(line.to_string()).expect("supervisor reads");
        }
    }

    fn connect(&self, waiter: u64) {
        self.send(json!({"connect": waiter, "keep_refusal": false}));
    }

    fn token(&self, read: u64, token: &str) {
        self.send(json!({"token": read, "env": {"CMUX_CLOUD_ACCESS_TOKEN": token}}));
    }

    /// The next line that has `key`, skipping others.
    async fn expect(&mut self, key: &str) -> Value {
        loop {
            let line = tokio::time::timeout(LINE_WAIT, self.lines.recv())
                .await
                .unwrap_or_else(|_| panic!("no {key} line"))
                .unwrap_or_else(|| panic!("the supervisor ended before a {key} line"));
            let value: Value = serde_json::from_str(&line).expect("a JSON line");
            if value.get(key).is_some() {
                return value;
            }
        }
    }

    /// The next `read_token`'s id.
    async fn read(&mut self) -> u64 {
        self.expect("read_token").await["read_token"].as_u64().expect("a read id")
    }

    /// No line with `key` within `wait`.
    async fn none(&mut self, key: &str, wait: Duration) {
        let deadline = tokio::time::Instant::now() + wait;
        while let Ok(Some(line)) = tokio::time::timeout_at(deadline, self.lines.recv()).await {
            let value: Value = serde_json::from_str(&line).expect("a JSON line");
            assert!(value.get(key).is_none(), "unexpected {line}");
        }
    }

    /// Ends the app's input and waits for the supervisor's exit code.
    async fn end(mut self) -> i32 {
        self.app = None;
        tokio::time::timeout(LINE_WAIT, self.done)
            .await
            .expect("the supervisor exits")
            .expect("joined")
    }
}

fn launches(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("launches")).map(|text| text.lines().count()).unwrap_or(0)
}

#[tokio::test]
async fn the_serve_socket_is_the_links_socket() {
    let dir = scratch("socket");
    let mut serve = Harness::start(config(&dir, &format!("{READY}\ncat >/dev/null")));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    let resumed = serve.expect("resume").await;
    assert_eq!(resumed, json!({"resume": [1], "socket": serve.socket}));
    assert_eq!(serve.end().await, 0, "stdin's end stops the serve and its child");
    assert_eq!(launches(&dir), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_refused_connection_ends_the_link_with_its_step() {
    let dir = scratch("refused");
    let script = format!(
        "{READY}\nread -r line\nprintf '%s\\n' '{{\"ok\":false,\"error_code\":\"relay\",\"route\":\"carrier\"}}' >&2\ncat >/dev/null"
    );
    let mut serve = Harness::start(config(&dir, &script));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    serve.expect("resume").await;
    // A second connect writes a fresh token, which the stand-in answers with a refused dial.
    serve.connect(2);
    let read = serve.read().await;
    serve.token(read, "t-2");
    let refused = loop {
        let state = serve.expect("state").await;
        if state["state"]["refusal"] != Value::Null {
            break state;
        }
    };
    assert_eq!(refused["state"]["refusal"], json!({"kind": "disconnected", "reason": "relay"}));
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_taken_socket_is_a_clear_failure() {
    let dir = scratch("taken");
    let script = r#"printf '{"ok":false,"error_code":"bad_request","error_detail":"Unix socket path %s is already leased","route":"carrier"}\n' "$1" >&2
exit 64"#;
    let mut serve = Harness::start(config(&dir, script));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    let resumed = serve.expect("resume").await;
    assert_eq!(resumed["error"], error_json(&serve_machine::socket_taken()));
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_serve_on_another_socket_is_refused() {
    let dir = scratch("another");
    let script = r#"printf '{"ok":true,"socket":"/tmp/elsewhere.sock","route":"carrier"}\n' >&2
cat >/dev/null"#;
    let mut serve = Harness::start(config(&dir, script));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    let resumed = serve.expect("resume").await;
    assert_eq!(
        resumed["error"],
        json!({"kind": "invalid_answer", "detail": "served another socket"})
    );
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_grants_vmk_is_published_and_is_the_answer() {
    let dir = scratch("vmk");
    let script = format!(
        "{READY}\nprintf '%s\\n' '{{\"ok\":true,\"route\":\"carrier\",\"vmk\":\"owner\"}}' >&2\ncat >/dev/null"
    );
    let mut serve = Harness::start(config(&dir, &script));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    assert_eq!(serve.expect("publish").await, json!({"publish": "owner"}));
    let state = loop {
        let state = serve.expect("state").await;
        if state["state"]["answer"] != Value::Null {
            break state;
        }
    };
    assert_eq!(state["state"]["answer"], "owner");
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A connect to a ready child writes it the fresh token: the stand-in
/// answers each token line with a connected line naming `team`.
#[tokio::test]
async fn a_running_serve_gets_fresh_tokens() {
    let dir = scratch("tokens");
    let script = format!(
        "{READY}\nwhile IFS= read -r line; do printf '%s\\n' '{{\"ok\":true,\"route\":\"carrier\",\"vmk\":\"team\"}}' >&2; done"
    );
    let mut serve = Harness::start(config(&dir, &script));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    serve.expect("resume").await;
    serve.connect(2);
    let read = serve.read().await;
    serve.token(read, "t-2");
    assert_eq!(serve.expect("resume").await, json!({"resume": [2], "socket": serve.socket}));
    assert_eq!(
        serve.expect("publish").await,
        json!({"publish": "team"}),
        "the child got the token line"
    );
    assert_eq!(serve.end().await, 0);
    assert_eq!(launches(&dir), 1, "the ready child kept serving");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The refresh reads a token on its own while the child is ready.
#[tokio::test]
async fn the_refresh_reads_a_token_while_ready() {
    let dir = scratch("refresh");
    let mut config = config(&dir, &format!("{READY}\ncat >/dev/null"));
    config.refresh_delay = |_| Duration::from_millis(50);
    let mut serve = Harness::start(config);
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    serve.expect("resume").await;
    let refresh = serve.read().await;
    assert!(refresh > read, "a new read with no connect");
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_stop_during_the_pending_token_spawns_nothing() {
    let dir = scratch("stop-token");
    let mut serve = Harness::start(config(&dir, &format!("{READY}\ncat >/dev/null")));
    serve.connect(1);
    let read = serve.read().await;
    serve.send(json!({"stop": true}));
    let resumed = serve.expect("resume").await;
    assert_eq!(resumed["error"], json!({"kind": "disconnected", "reason": "closed"}));
    serve.token(read, "old-account");
    serve.connect(2);
    let later = serve.expect("resume").await;
    assert_eq!(
        later,
        json!({"resume": [2], "error": {"kind": "disconnected", "reason": "closed"}})
    );
    assert_eq!(serve.end().await, 0);
    assert_eq!(launches(&dir), 0, "no child spawned after the stop");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_park_stops_the_child_and_the_next_connect_launches_another() {
    let dir = scratch("park");
    let mut serve = Harness::start(config(&dir, &format!("{READY}\ncat >/dev/null")));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    serve.expect("resume").await;
    serve.send(json!({"park": true}));
    serve.connect(2);
    let read = serve.read().await;
    serve.token(read, "t-2");
    assert_eq!(serve.expect("resume").await, json!({"resume": [2], "socket": serve.socket}));
    assert_eq!(serve.end().await, 0);
    assert_eq!(launches(&dir), 2);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_child_that_ignores_its_closed_stdin_is_terminated() {
    let dir = scratch("stuck");
    let mut serve = Harness::start(config(&dir, &format!("{READY}\nexec sleep 600")));
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    serve.expect("resume").await;
    // The supervisor exits only once the child exited: SIGTERM at the grace.
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_child_that_never_ran_does_not_block_the_next_launch() {
    let dir = scratch("never-ran");
    let mut config = config(&dir, "");
    config.program = dir.join("no-such-cli");
    let mut serve = Harness::start(config);
    serve.connect(1);
    let read = serve.read().await;
    serve.token(read, "t-1");
    let resumed = serve.expect("resume").await;
    assert_eq!(resumed["error"]["kind"], "disconnected");
    serve.connect(2);
    let next = serve.read().await;
    assert!(next > read, "the next connect launches again");
    assert_eq!(serve.end().await, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A session replaced for the same machine starts a second supervisor while
/// the first one's child still serves: the second launches only once that
/// child exited.
#[tokio::test]
async fn a_replaced_supervisor_waits_for_the_old_child() {
    let dir = scratch("replaced");
    let script = format!("{READY}\ncat >/dev/null");
    let mut old = Harness::start(config(&dir, &script));
    old.connect(1);
    let read = old.read().await;
    old.token(read, "t-1");
    old.expect("resume").await;
    let mut new = Harness::start(config(&dir, &script));
    new.connect(1);
    new.none("read_token", Duration::from_millis(300)).await;
    assert_eq!(old.end().await, 0);
    let read = new.read().await;
    new.token(read, "t-2");
    assert_eq!(new.expect("resume").await, json!({"resume": [1], "socket": new.socket}));
    assert_eq!(new.end().await, 0);
    assert_eq!(launches(&dir), 2);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_refresh_comes_before_the_token_expires() {
    fn jwt(exp: u64) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(json!({ "exp": exp }).to_string());
        format!("e30.{payload}.sig")
    }
    let now = UNIX_EPOCH + Duration::from_secs(1_000_000);
    assert_eq!(refresh_delay_at(&jwt(1_000_600), now), Duration::from_secs(540));
    assert_eq!(refresh_delay_at(&jwt(1_000_030), now), Duration::from_secs(15));
    assert_eq!(refresh_delay_at("opaque", now), Duration::from_secs(300));
    assert!(refresh_delay_at(&jwt(u64::MAX), SystemTime::now()) > Duration::ZERO);
}

#[test]
fn every_link_error_round_trips_on_the_wire() {
    let errors = [
        LinkError::disconnected("closed"),
        LinkError::Revoked { reason: "r".to_owned() },
        LinkError::helper_not_running("gone"),
        LinkError::UnsafeSocket("x".to_owned()),
        LinkError::OpenDirectory { path: "/tmp/x".to_owned(), parent: true },
        LinkError::InvalidAnswer("y".to_owned()),
        LinkError::NotUp { state: "parked_timeout".to_owned() },
        LinkError::Failed { code: "ticket".to_owned(), message: "ticket: no".to_owned() },
        LinkError::Unsupported,
    ];
    for error in errors {
        assert_eq!(error_of(&error_json(&error)), Some(error.clone()), "{error}");
    }
    assert_eq!(error_of(&json!({"kind": "nonsense"})), None);
}

#[test]
fn the_apps_lines_are_read() {
    assert_eq!(
        app_line(r#"{"connect":3,"keep_refusal":true}"#),
        Some(AppLine::Connect { waiter: 3, keep_refusal: true })
    );
    assert_eq!(
        app_line(r#"{"connect":4}"#),
        Some(AppLine::Connect { waiter: 4, keep_refusal: false })
    );
    assert_eq!(app_line(r#"{"park":true}"#), Some(AppLine::Park));
    assert_eq!(app_line(r#"{"stop":true}"#), Some(AppLine::Stop));
    assert_eq!(app_line(r#"{"account_ended":true}"#), Some(AppLine::AccountEnded));
    assert_eq!(
        app_line(r#"{"token":2,"fenced":true}"#),
        Some(AppLine::Token { read: 2, result: TokenRead::Fenced })
    );
    assert_eq!(
        app_line(r#"{"token":2,"error":{"kind":"unsupported"}}"#),
        Some(AppLine::Token { read: 2, result: TokenRead::Failed(LinkError::Unsupported) })
    );
    let env = Env::from([("A".to_owned(), "b".to_owned())]);
    assert_eq!(
        app_line(r#"{"token":5,"env":{"A":"b"}}"#),
        Some(AppLine::Token { read: 5, result: TokenRead::Ok(env) })
    );
    assert_eq!(app_line("not json"), None);
    assert_eq!(app_line(r#"{"other":1}"#), None);
}

#[test]
fn the_serve_argv_parses() {
    assert_eq!(
        parse(
            &[
                "supervise",
                "--machine",
                "vm_0123456789abcdefghij",
                "--socket",
                "/tmp/cmux-link-0123456789ab.sock"
            ]
            .map(str::to_owned)
        ),
        Some(("vm_0123456789abcdefghij".to_owned(), "/tmp/cmux-link-0123456789ab.sock".to_owned()))
    );
    assert_eq!(
        parse(
            &["supervise", "--machine", "vm_0123456789abcdefghij", "--socket", "relative.sock"]
                .map(str::to_owned)
        ),
        None
    );
    assert_eq!(parse(&["supervise", "--socket", "/tmp/a.sock"].map(str::to_owned)), None);
}
