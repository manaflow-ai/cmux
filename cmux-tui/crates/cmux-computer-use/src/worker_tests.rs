//! The control channel in-process (pipes for stdin and stdout), with the
//! fake desktop and the real agent socket.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

use super::*;
use crate::desktop::fake::FakeDesktop;

fn fake() -> Result<Platform, String> {
    Ok(Platform {
        desktop: Arc::new(FakeDesktop::standard()),
        cursor: Arc::new(NoCursor),
        takeover: Arc::new(NoTakeover),
    })
}

struct Harness {
    stdin: Option<std::io::PipeWriter>,
    stdout: BufReader<std::io::PipeReader>,
    worker: std::thread::JoinHandle<i32>,
    dir: PathBuf,
}

impl Harness {
    fn start(tag: &str, platform: fn() -> Result<Platform, String>, timeout: Duration) -> Self {
        let (in_r, in_w) = std::io::pipe().unwrap();
        let (out_r, out_w) = std::io::pipe().unwrap();
        let worker =
            std::thread::spawn(move || run(BufReader::new(in_r), out_w, platform, timeout));
        let dir = PathBuf::from(format!("/tmp/cuw{tag}{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Self { stdin: Some(in_w), stdout: BufReader::new(out_r), worker, dir }
    }
    fn socket(&self) -> PathBuf {
        self.dir.join("r").join("cu.sock")
    }
    fn send(&mut self, v: Value) {
        writeln!(self.stdin.as_mut().unwrap(), "{v}").unwrap();
    }
    fn recv(&mut self) -> Value {
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or(Value::Null)
    }
    fn configure(&mut self, config: Value) -> Value {
        let socket = self.socket();
        let state = self.dir.join("state");
        self.send(json!({
            "type": "configure", "config": config, "socket": socket, "secret": wire::hex(&[3; 32]),
            "state_dir": state, "machine": "test-box",
        }));
        self.recv()
    }
    fn finish(mut self) -> i32 {
        drop(self.stdin.take());
        let code = self.worker.join().unwrap();
        let _ = std::fs::remove_dir_all(&self.dir);
        code
    }
}

fn agent(socket: &PathBuf) -> (UnixStream, BufReader<UnixStream>) {
    let stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    writeln!(writer, "{}", json!({"secret": wire::hex(&[3; 32])})).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "{line}");
    (writer, reader)
}

fn recv(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[test]
fn configure_ready_ask_answer_and_exit_on_stdin_close() {
    let mut h = Harness::start("ask", fake, ASK_TIMEOUT);
    let ready = h.configure(json!({"mode": "askEveryTime"}));
    assert_eq!(ready["type"], "ready", "{ready}");
    assert_eq!(ready["pid"], std::process::id());
    let (mut w, mut r) = agent(&h.socket());
    writeln!(
        w,
        "{}",
        json!({"id": 1, "method": "tools/call", "name": "click", "session": "s",
        "arguments": {"window_id": "1", "element_id": "e1"}, "call_id": "c1"})
    )
    .unwrap();
    let ask = h.recv();
    assert_eq!(ask["type"], "ask", "{ask}");
    assert_eq!(ask["question"]["app"]["id"], "com.apple.Safari");
    h.send(json!({"type": "answer", "id": ask["id"], "answer": "allow_once"}));
    let done = recv(&mut r);
    assert_eq!(done["result"]["is_error"], false, "{done}");
    // Lowering the mode applies at once.
    h.send(json!({"type": "config", "config": {"mode": "lookOnly"}}));
    writeln!(
        w,
        "{}",
        json!({"id": 2, "method": "tools/call", "name": "click", "session": "s",
        "arguments": {"window_id": "1", "element_id": "e1"}, "call_id": "c2"})
    )
    .unwrap();
    assert_eq!(recv(&mut r)["result"]["code"], "look_only");
    // Saved approvals through the control channel.
    h.send(json!({"type": "approvals", "action": "never", "app_id": "com.apple.Safari"}));
    h.send(json!({"type": "approvals", "action": "list", "id": 5}));
    let list = h.recv();
    assert_eq!(
        list,
        json!({"type": "approvals", "id": 5, "saved": {"always": [], "never": ["com.apple.Safari"]}})
    );
    let socket = h.socket();
    let state = h.dir.join("state");
    assert!(state.join("approvals.json").exists());
    assert_eq!(h.finish(), EXIT_OK);
    assert!(!socket.exists());
    let _ = state;
}

#[test]
fn an_unanswered_question_is_unavailable() {
    let mut h = Harness::start("timeout", fake, Duration::from_millis(50));
    assert_eq!(h.configure(json!({"mode": "askEveryTime"}))["type"], "ready");
    let (mut w, mut r) = agent(&h.socket());
    writeln!(
        w,
        "{}",
        json!({"id": 1, "method": "tools/call", "name": "click", "session": "s",
        "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    assert_eq!(h.recv()["type"], "ask");
    let done = recv(&mut r);
    assert_eq!(done["result"]["is_error"], true, "{done}");
    assert_eq!(h.finish(), EXIT_OK);
}

#[test]
fn no_desktop_and_a_bad_configure_are_reported() {
    let mut h = Harness::start("nodesk", || Err("no display".into()), ASK_TIMEOUT);
    assert_eq!(h.configure(json!(null)), json!({"type": "unavailable", "reason": "no display"}));
    assert_eq!(h.finish(), EXIT_UNAVAILABLE);
    let mut h = Harness::start("bad", fake, ASK_TIMEOUT);
    h.send(json!({"type": "configure", "socket": "/tmp/x.sock", "secret": "ab"}));
    assert_eq!(h.recv()["type"], "error");
    assert_eq!(h.finish(), EXIT_BAD_CONFIGURE);
}

#[test]
fn the_persons_stop_reaches_the_agent_through_the_socket_and_resume_undoes_it() {
    let mut h = Harness::start("stop", fake, ASK_TIMEOUT);
    assert_eq!(h.configure(json!({"mode": "fullAccess"}))["type"], "ready");
    let (mut w, mut r) = agent(&h.socket());
    h.send(json!({"type": "session", "action": "stop", "session": "s", "label": "Claude"}));
    // Control lines run in order: the list's answer means the stop is in.
    h.send(json!({"type": "approvals", "action": "list", "id": 1}));
    assert_eq!(h.recv()["id"], 1);
    let click = |w: &mut UnixStream, id: u64| {
        writeln!(
            w,
            "{}",
            json!({"id": id, "method": "tools/call", "name": "click", "session": "s",
            "arguments": {"window_id": "1", "element_id": "e1", "observe": false},
            "call_id": format!("c{id}")})
        )
        .unwrap();
    };
    click(&mut w, 2);
    let done = recv(&mut r);
    assert_eq!(done["result"]["is_error"], true, "{done}");
    assert_eq!(done["result"]["code"], crate::stop::STOPPED_CODE);
    assert_eq!(done["result"]["body"]["error"], crate::stop::STOPPED_MESSAGE);
    h.send(json!({"type": "session", "action": "resume", "session": "s"}));
    h.send(json!({"type": "approvals", "action": "list", "id": 3}));
    assert_eq!(h.recv()["id"], 3);
    click(&mut w, 4);
    assert_eq!(recv(&mut r)["result"]["is_error"], false);
    assert_eq!(h.finish(), EXIT_OK);
}
