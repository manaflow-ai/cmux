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
    adopting_cat_terminal_with(harness, name, Vec::new())
}

/// [`adopting_cat_terminal`], the restarted owner also given `env`.
fn adopting_cat_terminal_with(
    harness: &mut RecoveryHarness,
    name: &str,
    env: Vec<(String, String)>,
) -> (String, libc::pid_t) {
    let (terminal_id, _) = run_cat_workspace(&harness.socket, 1, name);
    let host = wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid as libc::pid_t;
    harness.sigkill();
    harness.extra_env =
        vec![("CMUX_TUI_TEST_ADOPTION_DELAY_MS".into(), ADOPTION_DELAY_MS.to_string())];
    harness.extra_env.extend(env);
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

/// An adoption can take far longer than a creation: at 320 terminals on a loaded Mac the new
/// owner adopted for 48 s after an update. Input queued for an adopting terminal waits for the
/// adoption's end, not the creating-input expiry: given back at the expiry, it reached no one
/// (no client takes the notice) and the person's keys were lost.
#[test]
fn input_sent_while_a_terminal_adopts_longer_than_the_input_expiry_reaches_it() {
    let mut harness = RecoveryHarness::start("input-while-adopting-slow");
    // The creating-input expiry ends long before the adoption does.
    let expiry = vec![("CMUX_TUI_TEST_CREATING_INPUT_EXPIRY_MS".to_string(), "300".to_string())];
    let (terminal_id, _) = adopting_cat_terminal_with(&mut harness, "adopting-slow", expiry);
    let mut connection = Connection::open(&harness.socket);
    let reply = connection.call(serde_json::json!({
        "id": 3, "cmd": "send", "terminal_id": terminal_id, "text": "typed-in-a-slow-adoption\n",
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
    // The cat echoes the line once it was written; given back instead, it never shows.
    let screen = wait_for_screen(&harness.socket, surface, "typed-in-a-slow-adoption");
    assert!(
        screen.contains("typed-in-a-slow-adoption"),
        "input queued while the terminal adopted never reached it: {screen:?}; notices: {:?}",
        connection.notices
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

/// The surface of `terminal_id` once its adoption made it live.
fn adopted_surface(harness: &RecoveryHarness, terminal_id: &str) -> u64 {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 5, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            return surface;
        }
        assert!(Instant::now() < deadline, "the terminal was never adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Input queued while a terminal adopts goes in before input another connection sends to
/// the adopted surface as soon as it is live: the flush starts half a second after the
/// adoption made the surface live, so the later input arrives first and must wait for it.
#[test]
fn input_queued_while_a_terminal_adopts_precedes_input_sent_once_it_is_live() {
    let mut harness = RecoveryHarness::start("input-while-adopting-order");
    let flush =
        vec![("CMUX_TUI_TEST_CREATING_INPUT_FLUSH_DELAY_MS".to_string(), "500".to_string())];
    let (terminal_id, _) = adopting_cat_terminal_with(&mut harness, "adopting-order", flush);
    let mut sender = Connection::open(&harness.socket);
    let reply = sender.call(serde_json::json!({
        "id": 3, "cmd": "send", "terminal_id": terminal_id, "text": "QUEUED",
    }));
    assert_eq!(reply["data"]["queued"], true, "{reply}");

    let surface = adopted_surface(&harness, &terminal_id);
    let mut other = Connection::open(&harness.socket);
    let live = other.call(serde_json::json!({
        "id": 30, "cmd": "send", "surface": surface, "text": "-LIVE\n",
    }));
    assert_eq!(live["ok"], true, "{live}");
    let screen = wait_for_screen(&harness.socket, surface, "QUEUED-LIVE");
    assert!(
        screen.contains("QUEUED-LIVE"),
        "input sent once the terminal was live overtook the queued input: {screen:?}"
    );
}

/// The 64 KiB queue limit holds while a terminal adopts: a request past it is refused whole
/// (`input.overflow`) and queues nothing, what was queued before still reaches the adopted
/// terminal, and a later request that fits is queued behind it.
#[test]
fn more_than_64_kib_for_an_adopting_terminal_is_refused_and_the_queue_is_kept() {
    let mut harness = RecoveryHarness::start("input-while-adopting-overflow");
    let (terminal_id, _) = adopting_cat_terminal(&mut harness, "adopting-overflow");
    let mut sender = Connection::open(&harness.socket);
    // Short lines: a terminal's line discipline limits one line, not the queue.
    let mut first = format!("{}\n", "q".repeat(99)).repeat(600);
    first.push_str("QUEUED-END\n");
    let reply = sender.call(serde_json::json!({
        "id": 3, "cmd": "send", "terminal_id": terminal_id, "text": first,
    }));
    assert_eq!(reply["data"]["queued"], true, "{reply}");
    let over = sender.call(serde_json::json!({
        "id": 4, "cmd": "send", "terminal_id": terminal_id, "text": "OVER\n".repeat(2_000),
    }));
    assert_eq!(over["ok"], false, "{over}");
    assert_eq!(over["error_code"], "input.overflow", "{over}");
    let fits = sender.call(serde_json::json!({
        "id": 5, "cmd": "send", "terminal_id": terminal_id, "text": "FITS-AFTER\n",
    }));
    assert_eq!(fits["data"]["queued"], true, "the refused request queued nothing: {fits}");

    let surface = adopted_surface(&harness, &terminal_id);
    let screen = wait_for_screen(&harness.socket, surface, "FITS-AFTER");
    let end = screen.rfind("QUEUED-END");
    let after = screen.rfind("FITS-AFTER");
    assert!(
        end.is_some() && after.is_some() && end < after,
        "the queue before the refused request did not reach the terminal in order: {screen:?}"
    );
    assert!(!screen.contains("OVER"), "the refused request was written: {screen:?}");
    assert!(
        sender.notices.iter().all(|n| n["event"] != "terminal-input-unclaimed"),
        "written input was also given back: {:?}",
        sender.notices
    );
}

/// An adoption that ends with its host alive but not adoptable gives the queued input back at
/// that end, in the unclaimed notice with reason `failed`, not at the adopting queue's 120 s
/// backstop. The host refuses every hello: its record names a wrong owner token, as a host
/// that shares no protocol with this build refuses (no test seam: a host of this build, a
/// record edited on disk). After the refusals the terminal is unadoptable and its host keeps
/// running.
#[test]
fn input_queued_for_a_live_host_that_cannot_be_adopted_comes_back_when_the_adoption_ends() {
    let mut harness = RecoveryHarness::start("input-while-adopting-unadoptable");
    let (terminal_id, _) = run_cat_workspace(&harness.socket, 1, "adopting-unadoptable");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host_pid = record.host_pid as libc::pid_t;
    // The harness's cleanup adopts nothing with the wrong token; never leak the host.
    struct KillOnDrop(libc::pid_t);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            // SAFETY: the PID is this test's terminal host (a session leader).
            unsafe { libc::killpg(self.0, libc::SIGKILL) };
        }
    }
    let _host_guard = KillOnDrop(host_pid);

    harness.sigkill();
    let mut rewritten: serde_json::Value =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    let token = rewritten["owner_token"].as_str().unwrap().to_string();
    let wrong: String = token.chars().map(|c| if c == 'f' { '0' } else { 'f' }).collect();
    rewritten["owner_token"] = serde_json::json!(wrong);
    fs::write(&record_path, serde_json::to_vec(&rewritten).unwrap()).unwrap();
    harness.restart();

    let mut connection = Connection::open(&harness.socket);
    let reply = connection.call(serde_json::json!({
        "id": 3, "cmd": "send", "terminal_id": terminal_id, "text": "never-adopted",
    }));
    assert_eq!(reply["data"]["queued"], true, "the terminal must still adopt: {reply}");
    let sent = Instant::now();
    let notice = connection.unclaimed();
    let waited = sent.elapsed();
    assert_eq!(notice["terminal_id"], terminal_id.as_str(), "{notice}");
    assert_eq!(
        notice["reason"], "failed",
        "given back by the backstop, not the adoption's end: {notice}"
    );
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(notice["bytes_base64"].as_str().unwrap())
        .unwrap();
    assert_eq!(bytes, b"never-adopted", "{notice}");
    // Three refusals over at least 10 s make the host unadoptable; the backstop is 120 s.
    assert!(waited < test_timeout(Duration::from_secs(40)), "given back after {waited:?}");
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    assert_ne!(resolved["lifecycle"], "exited", "a live host's terminal was ended: {resolved}");
    assert!(process_exists(host_pid), "the host must keep running");
}
