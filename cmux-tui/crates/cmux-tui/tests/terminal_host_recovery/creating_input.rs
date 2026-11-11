//! `terminal-input-while-creating-v1` over the daemon socket (cx-wb5.78): input sent to the
//! caller-minted `terminal_id` of a split that is still being created is queued, in order across
//! connections, and written to the new terminal once it is live; a creation that outlives the
//! expiry gives each sending connection its own bytes back in one `terminal-input-unclaimed`
//! notice; a refused creation never takes input; more than 64 KiB is refused with
//! `input.overflow`; a creation whose creator cancelled its input (`cancel-creating-input`, the
//! close of a pane that is still starting) writes none of it.

use super::super::*;
use std::sync::mpsc;

/// A caller-minted terminal id unique to this test process. A host binds
/// its socket at `/tmp/cmux-th-<uid>/<terminal id>.sock`, one folder for
/// every daemon of the user: a fixed id met the socket a host of another run
/// (a concurrent step, or a host a reaper killed) left there, and the split
/// failed with "terminal host identity already exists".
fn creating_terminal(n: u64) -> String {
    use std::sync::OnceLock;
    static RUN: OnceLock<u32> = OnceLock::new();
    let run = RUN.get_or_init(|| {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos();
        nanos ^ std::process::id().rotate_left(16)
    });
    format!("{run:08x}000040008000{n:012x}")
}

fn pane_id(n: u64) -> String {
    format!("pane_{:032x}", 0x5200_0000_0000_0000_0000_0000_0000_0000u128 + u128::from(n))
}

fn first_pane(harness: &RecoveryHarness, name: &str) -> u64 {
    run_cat_workspace(&harness.socket, 1, name);
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap()
}

/// One persistent connection: requests answered by id; control notices kept aside.
struct Connection {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    notices: Vec<serde_json::Value>,
    /// Replies to requests sent with [`Connection::send`], read while another reply was awaited.
    replies: Vec<serde_json::Value>,
}

impl Connection {
    fn open(path: &Path) -> Self {
        let stream = transport::connect(path).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { writer, reader: BufReader::new(stream), notices: Vec::new(), replies: Vec::new() }
    }

    fn call(&mut self, value: serde_json::Value) -> serde_json::Value {
        let id = value["id"].clone();
        self.send(value);
        self.reply(&id)
    }

    /// Writes a request and does not wait for its reply ([`Connection::reply`] reads it).
    fn send(&mut self, value: serde_json::Value) {
        writeln!(self.writer, "{value}").unwrap();
    }

    /// The reply to request `id` of this connection; other replies and notices are kept.
    fn reply(&mut self, id: &serde_json::Value) -> serde_json::Value {
        if let Some(index) = self.replies.iter().position(|reply| reply["id"] == *id) {
            return self.replies.remove(index);
        }
        loop {
            let message = self.next();
            if message["id"] == *id {
                return message;
            }
            if message["event"].is_string() {
                self.notices.push(message);
            } else {
                assert!(!message["id"].is_null(), "unexpected message: {message}");
                self.replies.push(message);
            }
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
            self.notices.push(message);
        }
    }
}

/// Send `text` to the creating `terminal_id` once the daemon registered it (the split runs on
/// another thread, so the first sends may arrive before it): returns the reply that queued it.
fn queue(connection: &mut Connection, id: u64, terminal_id: &str, text: &str) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let reply = connection.call(serde_json::json!({
            "id": id, "cmd": "send", "terminal_id": terminal_id, "text": text,
        }));
        if reply["ok"] == true {
            return reply;
        }
        assert!(reply["error"].as_str().is_some_and(|e| e.contains("unknown terminal")), "{reply}");
        assert!(Instant::now() < deadline, "the split never registered {terminal_id}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Run `command` on its own connection and thread; the reply arrives on the channel.
fn spawn_request(path: &Path, command: serde_json::Value) -> mpsc::Receiver<serde_json::Value> {
    let (sender, receiver) = mpsc::channel();
    let path = path.to_path_buf();
    std::thread::spawn(move || {
        let _ = sender.send(request_response(&path, command));
    });
    receiver
}

fn base64_text(value: &serde_json::Value) -> String {
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value["bytes_base64"].as_str().unwrap())
        .unwrap();
    String::from_utf8(bytes).unwrap()
}

#[test]
fn input_for_a_creating_terminal_is_queued_then_written_in_order() {
    // Each host takes a second to start, so the split stays creating while input arrives.
    let harness = RecoveryHarness::start_with_host_ready_delay("creating-input-order", 1_000);
    let identify = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c == "terminal-input-while-creating-v1"),
        "{identify}"
    );
    let pane = first_pane(&harness, "creating-order");
    let terminal_id = creating_terminal(1);
    let split = spawn_request(
        &harness.socket,
        serde_json::json!({"id": 10, "cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal_id}),
    );

    // Two connections queue in arrival order; both are told their bytes wait.
    let mut first = Connection::open(&harness.socket);
    let mut second = Connection::open(&harness.socket);
    let queued = queue(&mut first, 20, &terminal_id, "AB");
    assert_eq!(queued["data"]["queued"], true, "{queued}");
    let queued = second.call(serde_json::json!({
        "id": 21, "cmd": "send", "terminal_id": terminal_id, "text": "CD",
    }));
    assert_eq!(queued["data"]["queued"], true, "{queued}");
    let queued = first.call(serde_json::json!({
        "id": 22, "cmd": "send", "terminal_id": terminal_id, "text": "EF",
    }));
    assert_eq!(queued["data"]["queued"], true, "{queued}");

    let created = split.recv_timeout(test_timeout(Duration::from_secs(20))).unwrap();
    assert_eq!(created["ok"], true, "{created}");
    let surface = created["data"]["surface"].as_u64().unwrap();
    // The queue is written to the live terminal after the commit, on its own
    // thread: until it is, input to the id still joins the queue (in order).
    // Once it is written, input to the id is written at once.
    wait_for_screen(&harness.socket, surface, "ABCDEF");
    let live = first.call(serde_json::json!({
        "id": 23, "cmd": "send", "terminal_id": terminal_id, "text": "GH",
    }));
    assert_eq!(live["ok"], true, "{live}");
    assert!(live["data"]["queued"].is_null(), "{live}");
    let screen = wait_for_screen(&harness.socket, surface, "ABCDEFGH");
    assert_eq!(screen.matches("ABCDEFGH").count(), 1, "queued input ran once, in order: {screen}");
    assert!(first.notices.iter().all(|n| n["event"] != "terminal-input-unclaimed"));
}

#[test]
fn a_refused_creation_takes_no_input() {
    let harness = RecoveryHarness::start_with_host_ready_delay("creating-input-refused", 500);
    let pane = first_pane(&harness, "creating-refused");
    let taken = request(
        &harness.socket,
        serde_json::json!({"id": 10, "cmd": "split", "pane": pane, "dir": "down", "pane_id": pane_id(1)}),
    );
    let taken_surface = taken["surface"].as_u64().unwrap();
    // The same pane id with another request is refused before anything is created, so its
    // terminal id never waits for input: a send to it fails and writes nothing anywhere.
    let terminal_id = creating_terminal(2);
    let refused = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 11, "cmd": "split", "pane": pane, "dir": "right",
            "pane_id": pane_id(1), "terminal_id": terminal_id,
        }),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    let mut sender = Connection::open(&harness.socket);
    let sent = sender.call(serde_json::json!({
        "id": 20, "cmd": "send", "terminal_id": terminal_id, "text": "REFUSED-INPUT",
    }));
    assert_eq!(sent["ok"], false, "{sent}");
    assert!(sent["error"].as_str().unwrap().contains("unknown terminal"), "{sent}");
    let screen = request(
        &harness.socket,
        serde_json::json!({"id": 21, "cmd": "read-screen", "surface": taken_surface}),
    );
    assert!(!screen["text"].as_str().unwrap().contains("REFUSED-INPUT"), "{screen}");
}

#[test]
fn a_creation_that_outlives_the_expiry_gives_the_input_back() {
    let mut harness = RecoveryHarness::start_unstarted("creating-input-expiry");
    harness.host_ready_delay_ms = Some(3_000);
    harness.extra_env.push(("CMUX_TUI_TEST_CREATING_INPUT_EXPIRY_MS".into(), "300".into()));
    harness.restart();
    let pane = first_pane(&harness, "creating-expiry");
    let terminal_id = creating_terminal(3);
    let split = spawn_request(
        &harness.socket,
        serde_json::json!({"id": 10, "cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal_id}),
    );
    let mut sender = Connection::open(&harness.socket);
    queue(&mut sender, 20, &terminal_id, "EXPIRED-INPUT");
    let notice = sender.unclaimed();
    assert_eq!(notice["reason"], "expired", "{notice}");
    assert_eq!(base64_text(&notice), "EXPIRED-INPUT");

    // The split still commits; the expired input was not written to it.
    let created = split.recv_timeout(test_timeout(Duration::from_secs(20))).unwrap();
    assert_eq!(created["ok"], true, "{created}");
    let surface = created["data"]["surface"].as_u64().unwrap();
    let marker = "AFTER-EXPIRY";
    let live = sender.call(serde_json::json!({
        "id": 21, "cmd": "send", "terminal_id": terminal_id, "text": marker,
    }));
    assert_eq!(live["ok"], true, "{live}");
    let screen = wait_for_screen(&harness.socket, surface, marker);
    assert!(!screen.contains("EXPIRED-INPUT"), "expired input was written: {screen}");
}

#[test]
fn more_than_64_kib_for_a_creating_terminal_is_refused() {
    let harness = RecoveryHarness::start_with_host_ready_delay("creating-input-overflow", 2_000);
    let pane = first_pane(&harness, "creating-overflow");
    let terminal_id = creating_terminal(4);
    let split = spawn_request(
        &harness.socket,
        serde_json::json!({"id": 10, "cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal_id}),
    );
    let mut sender = Connection::open(&harness.socket);
    queue(&mut sender, 20, &terminal_id, &"a".repeat(60_000));
    let over = sender.call(serde_json::json!({
        "id": 21, "cmd": "send", "terminal_id": terminal_id, "text": "b".repeat(10_000),
    }));
    assert_eq!(over["ok"], false, "{over}");
    assert_eq!(over["error_code"], "input.overflow", "{over}");
    let fits = sender.call(serde_json::json!({
        "id": 22, "cmd": "send", "terminal_id": terminal_id, "text": "c",
    }));
    assert_eq!(fits["data"]["queued"], true, "the refused request queued nothing: {fits}");
    let created = split.recv_timeout(test_timeout(Duration::from_secs(20))).unwrap();
    assert_eq!(created["ok"], true, "{created}");
}

#[test]
fn queued_input_precedes_input_sent_to_the_new_surface() {
    // The flush starts half a second after the commit, so input by surface id arrives first.
    let mut harness = RecoveryHarness::start_unstarted("creating-input-mixed");
    harness.host_ready_delay_ms = Some(1_000);
    harness.extra_env.push(("CMUX_TUI_TEST_CREATING_INPUT_FLUSH_DELAY_MS".into(), "500".into()));
    harness.restart();
    let pane = first_pane(&harness, "creating-mixed");
    let terminal_id = creating_terminal(5);
    let split = spawn_request(
        &harness.socket,
        serde_json::json!({"id": 10, "cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal_id}),
    );
    let mut sender = Connection::open(&harness.socket);
    queue(&mut sender, 20, &terminal_id, "QUEUED");
    let created = split.recv_timeout(test_timeout(Duration::from_secs(20))).unwrap();
    assert_eq!(created["ok"], true, "{created}");
    let surface = created["data"]["surface"].as_u64().unwrap();
    // Another connection types into the new surface by its id as soon as the reply names it.
    let mut other = Connection::open(&harness.socket);
    let live = other.call(serde_json::json!({
        "id": 30, "cmd": "send", "surface": surface, "text": "-LIVE",
    }));
    assert_eq!(live["ok"], true, "{live}");
    let screen = wait_for_screen(&harness.socket, surface, "QUEUED-LIVE");
    assert_eq!(screen.matches("QUEUED-LIVE").count(), 1, "queued input ran first, once: {screen}");
}

/// Waits until `path` exists; false when it does not within the test timeout.
fn wait_for_file(path: &Path) -> bool {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    path.exists()
}

/// A harness whose terminals run a plain `/bin/sh` and whose hosts take `host_ready_delay_ms`
/// to start: a split stays creating that long, and a typed line with Return runs as a command.
fn slow_shell_harness(name: &str, host_ready_delay_ms: u64) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.host_ready_delay_ms = Some(host_ready_delay_ms);
    harness.shell_integration = false;
    harness.restart();
    harness
}

/// The person splits while the daemon is slow, types a line with Return in the starting pane,
/// then closes it (the app cancels the creation's input in the turn of the close). The split
/// commits late. The shell of the closed pane must get none of the typed line: before
/// `creating-input-cancel-v1` the commit wrote the queue to the new terminal and its shell ran
/// the line before the app's close ended it.
#[test]
fn a_line_typed_in_a_starting_pane_the_person_closed_never_runs() {
    let harness = slow_shell_harness("creating-input-cancel", 1_500);
    let pane = first_pane(&harness, "creating-cancel");
    let terminal_id = creating_terminal(6);
    let typed_line_ran = harness.dir.join("typed-line-ran");
    let later_line_ran = harness.dir.join("later-line-ran");

    // The app: one connection creates, types and closes.
    let mut app = Connection::open(&harness.socket);
    app.send(serde_json::json!({
        "id": 10, "cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal_id,
    }));
    let typed = format!("touch {}\r", typed_line_ran.display());
    let queued = queue(&mut app, 20, &terminal_id, &typed);
    assert_eq!(queued["data"]["queued"], true, "{queued}");
    // The Close of the starting pane, before the daemon committed the split.
    let cancelled = app.call(serde_json::json!({
        "id": 21, "cmd": "cancel-creating-input", "terminal_id": terminal_id,
    }));

    // The late commit. The app learns the surface from the reply and closes it; before that
    // close, a line sent by surface proves that the shell runs what it gets (the daemon writes
    // a creation's queue before any later input).
    let created = app.reply(&serde_json::json!(10));
    assert_eq!(created["ok"], true, "{created}");
    let surface = created["data"]["surface"].as_u64().unwrap();
    let later = app.call(serde_json::json!({
        "id": 22, "cmd": "send", "surface": surface,
        "text": format!("touch {}\r", later_line_ran.display()),
    }));
    assert_eq!(later["ok"], true, "{later}");
    assert!(wait_for_file(&later_line_ran), "the new terminal's shell ran nothing");
    let screen = request(
        &harness.socket,
        serde_json::json!({"id": 30, "cmd": "read-screen", "surface": surface}),
    );
    assert!(
        !typed_line_ran.exists(),
        "the shell of the closed pane ran the typed line; its screen: {screen}"
    );
    assert!(
        !screen["text"].as_str().unwrap().contains("typed-line-ran"),
        "the closed pane's terminal got the typed line: {screen}"
    );
    assert_eq!(cancelled["ok"], true, "{cancelled}");
    assert_eq!(cancelled["data"]["cancelled"], true, "{cancelled}");
    // The cancelled bytes are the caller's own: dropped, never given back to it (the app would
    // hand a give-back to the terminal that has focus).
    assert!(
        app.notices.iter().all(|n| n["event"] != "terminal-input-unclaimed"),
        "{:?}",
        app.notices
    );

    // The app's close of the cancelled creation, as today.
    let closed = app.call(serde_json::json!({
        "id": 23, "cmd": "close-tabs", "surfaces": [surface], "end_terminals": true,
    }));
    assert_eq!(closed["ok"], true, "{closed}");
    assert!(!typed_line_ran.exists(), "the typed line ran after the close");
}
