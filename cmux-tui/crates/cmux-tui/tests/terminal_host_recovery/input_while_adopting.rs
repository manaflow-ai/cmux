//! Input sent to a terminal while a replacement owner adopts its surviving
//! host (after an update's handoff or a crash) is not refused. Each host
//! adopts on its own thread after the new owner answers, so for a moment
//! (hundreds of milliseconds, seconds with many terminals) the terminal is
//! listed as adopting but has no live surface. `send {terminal_id}` answered
//! `unknown terminal` then, and the bytes a person typed during an update
//! were lost. They are now queued as for a terminal still being created
//! (`terminal-input-while-creating-v1`): written in order once the host is
//! adopted, or given back in a `terminal-input-unclaimed` notice when the
//! adoption ends without a live terminal.

use super::*;

/// Each adoption starts this much after the restart, so the test can send
/// input while its terminal adopts (debug-build seam).
const ADOPTION_DELAY_MS: u64 = 3_000;

/// One persistent connection: replies by id; control notices kept aside.
struct Connection {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    notices: Vec<serde_json::Value>,
}

impl Connection {
    fn open(path: &Path) -> Self {
        let stream = transport::connect(path).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { writer, reader: BufReader::new(stream), notices: Vec::new() }
    }

    fn call(&mut self, value: serde_json::Value) -> serde_json::Value {
        let id = value["id"].clone();
        writeln!(self.writer, "{value}").unwrap();
        loop {
            let message = self.next();
            if message["id"] == id {
                return message;
            }
            assert!(message["event"].is_string(), "unexpected message: {message}");
            self.notices.push(message);
        }
    }

    fn next(&mut self) -> serde_json::Value {
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// The next `terminal-input-unclaimed` notice on this connection.
    fn unclaimed(&mut self) -> serde_json::Value {
        if let Some(index) =
            self.notices.iter().position(|n| n["event"] == "terminal-input-unclaimed")
        {
            return self.notices.remove(index);
        }
        loop {
            let message = self.next();
            if message["event"] == "terminal-input-unclaimed" {
                return message;
            }
        }
    }
}

/// A cat terminal whose daemon was killed, restarted with every adoption
/// held for [`ADOPTION_DELAY_MS`]: returns the terminal id and its host pid.
fn adopting_cat_terminal(harness: &mut RecoveryHarness, name: &str) -> (String, libc::pid_t) {
    let (terminal_id, _) = run_cat_workspace(&harness.socket, 1, name);
    let host = wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid as libc::pid_t;
    harness.sigkill();
    harness.extra_env =
        vec![("CMUX_TUI_TEST_ADOPTION_DELAY_MS".into(), ADOPTION_DELAY_MS.to_string())];
    harness.restart();
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    assert!(
        resolved["lifecycle"] == "adopting" && resolved["surface"].as_u64().is_none(),
        "the terminal must still adopt when the input is sent: {resolved}"
    );
    (terminal_id, host)
}

#[test]
fn input_sent_while_a_terminal_adopts_reaches_it_once_adopted() {
    let mut harness = RecoveryHarness::start("input-while-adopting");
    let (terminal_id, _) = adopting_cat_terminal(&mut harness, "adopting-input");
    let mut connection = Connection::open(&harness.socket);
    let reply = connection.call(serde_json::json!({
        "id": 3, "cmd": "send", "terminal_id": terminal_id, "text": "typed-while-adopting-1\n",
    }));
    assert_eq!(reply["ok"], true, "input sent while the terminal adopts was refused: {reply}");
    assert_eq!(reply["data"]["queued"], true, "{reply}");
    let reply = connection.call(serde_json::json!({
        "id": 4, "cmd": "send", "terminal_id": terminal_id, "text": "typed-while-adopting-2\n",
    }));
    assert_eq!(reply["data"]["queued"], true, "{reply}");

    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 5, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "the terminal was never adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(20));
    };
    let screen = wait_for_screen(&harness.socket, surface, "typed-while-adopting-2");
    let first = screen.find("typed-while-adopting-1");
    let second = screen.find("typed-while-adopting-2");
    assert!(
        first.is_some() && second.is_some() && first < second,
        "the queued input did not reach the adopted terminal in order: {screen:?}"
    );
    assert!(
        connection.notices.iter().all(|n| n["event"] != "terminal-input-unclaimed"),
        "written input was also given back: {:?}",
        connection.notices
    );
}

#[test]
fn input_sent_while_a_terminal_adopts_comes_back_when_its_host_is_gone() {
    let mut harness = RecoveryHarness::start("input-while-adopting-lost");
    // A lost host's terminal stays ended: no respawn takes the queue.
    harness.respawn = false;
    let (terminal_id, host) = adopting_cat_terminal(&mut harness, "adopting-lost");
    let mut connection = Connection::open(&harness.socket);
    let reply = connection.call(serde_json::json!({
        "id": 3, "cmd": "send", "terminal_id": terminal_id, "text": "never-written",
    }));
    assert_eq!(reply["ok"], true, "input sent while the terminal adopts was refused: {reply}");
    assert_eq!(reply["data"]["queued"], true, "{reply}");
    // The host dies before its adoption starts.
    // SAFETY: the durable record names this harness's live terminal host.
    assert_eq!(unsafe { libc::kill(host, libc::SIGKILL) }, 0);

    let notice = connection.unclaimed();
    assert_eq!(notice["terminal_id"], terminal_id.as_str(), "{notice}");
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(notice["bytes_base64"].as_str().unwrap())
        .unwrap();
    assert_eq!(bytes, b"never-written", "{notice}");
}
