//! Behavior of `agent-session-attach-v1` (plans/cmux-next/remote-agent-attach.md):
//! a trusted local client attaches to an agent tab of this daemon's store
//! and streams and drives its acpmux session through the daemon. A fake
//! acpmux on a private unix socket records every frame the daemon sends.
//!
//! Policy tests (AGENTS.md "Remote CLI relay"): the verbs are refused on the
//! remote relay and on WebSocket clients, scoped to agent tabs of this store
//! with a bound session, carry no command-bearing or session params, prompts
//! are one text block, and permission answers name only a request acpmux
//! announced on the attachment.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::agent_session_attach::{AGENT_SESSION_ATTACH_CAPABILITY, MAX_ATTACHMENTS_PER_CLIENT};
use super::*;

const WAIT: Duration = Duration::from_secs(5);
const SESSION: &str = "acp_session_1";

// MARK: Fake acpmux

/// A fake acpmux daemon: answers attach, events, prompt (with
/// `prompt_accepted`) and permission_respond, and lets a test push
/// notifications to the newest connection.
struct FakeAcpmux {
    directory: PathBuf,
    socket: PathBuf,
    frames: Receiver<Value>,
    connections: Receiver<UnixStream>,
    current: Option<UnixStream>,
}

impl FakeAcpmux {
    fn start(label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = PathBuf::from(format!(
            "/tmp/cmux-asa-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let socket = directory.join("a.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (frame_tx, frames) = channel();
        let (connection_tx, connections) = channel();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let _ = connection_tx.send(stream.try_clone().unwrap());
                let frame_tx = frame_tx.clone();
                std::thread::spawn(move || serve(stream, frame_tx));
            }
        });
        Self { directory, socket, frames, connections, current: None }
    }

    /// The next frame the daemon sent to acpmux.
    /// The next frame the daemon sent to acpmux (its session watch skipped).
    fn frame(&self) -> Value {
        loop {
            let frame = self.frames.recv_timeout(WAIT).expect("a frame to acpmux");
            if frame["method"] != json!("_acpmux/watch") {
                return frame;
            }
        }
    }

    fn no_frame(&self) {
        let deadline = Instant::now() + Duration::from_millis(200);
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.frames.recv_timeout(left) {
                Ok(frame) if frame["method"] == json!("_acpmux/watch") => continue,
                Ok(frame) => panic!("the daemon must not reach acpmux: {frame}"),
                Err(_) => return,
            }
        }
    }

    fn no_connection(&self) {
        assert!(
            self.connections.recv_timeout(Duration::from_millis(200)).is_err(),
            "the daemon must not connect to acpmux"
        );
    }

    fn connection(&mut self) -> &mut UnixStream {
        if self.current.is_none() {
            self.current = Some(self.connections.recv_timeout(WAIT).expect("a connection"));
        }
        self.current.as_mut().unwrap()
    }

    fn notify(&mut self, method: &str, params: Value) {
        let line = json!({"jsonrpc":"2.0","method":method,"params":params}).to_string();
        let stream = self.connection();
        writeln!(stream, "{line}").unwrap();
        stream.flush().unwrap();
    }

    fn hang_up(&mut self) {
        let _ = self.connection().shutdown(Shutdown::Both);
    }
}

impl Drop for FakeAcpmux {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn serve(stream: UnixStream, frames: Sender<Value>) {
    let mut writer = stream.try_clone().unwrap();
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { return };
        let frame: Value = serde_json::from_str(&line).unwrap();
        let _ = frames.send(frame.clone());
        let id = frame["id"].clone();
        let params = &frame["params"];
        let reply = match frame["method"].as_str().unwrap_or_default() {
            "_acpmux/attach" => {
                // A running turn: acpmux subscribes first, so a live record
                // can reach the daemon before the attach reply.
                let early = json!({"jsonrpc":"2.0","method":"_acpmux/event","params":{
                    "sessionId": SESSION, "seq": 2, "dir": "in", "kind": "agent_message", "msg": {}}});
                writeln!(writer, "{early}").unwrap();
                Some(json!({
                    "session": {"sessionId": SESSION, "name": "sub", "status": "running",
                                "pending": [{"permissionId": "perm_attach", "options": []}]},
                    "events": [{"sessionId": SESSION, "seq": 1, "dir": "mux", "kind": "user_message", "msg": {}}],
                    "hasMore": false,
                    "lastSeq": 1,
                }))
            }
            "_acpmux/watch" => Some(json!({"sessions": [{"sessionId": "acp_unrelated"}]})),
            "_acpmux/events" => Some(json!({"events": [], "hasMore": false, "lastSeq": 1})),
            "_acpmux/permission_respond" => Some(json!({})),
            "session/prompt" => {
                let accepted = json!({"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{
                    "sessionId": SESSION, "promptId": params["_meta"]["acpmux"]["promptId"],
                    "turnId": "turn_1", "queued": false}});
                writeln!(writer, "{accepted}").unwrap();
                None
            }
            _ => None,
        };
        if let Some(result) = reply {
            writeln!(writer, "{}", json!({"jsonrpc":"2.0","id":id,"result":result})).unwrap();
        }
    }
}

// MARK: Client

/// One control connection served by `handle_connection` on a private socket.
struct Client {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    events: VecDeque<Value>,
    next_id: u64,
    directory: PathBuf,
    handler: Option<JoinHandle<()>>,
}

impl Client {
    fn connect(mux: &Arc<Mux>, label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = PathBuf::from(format!(
            "/tmp/cmux-asc-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let client = transport::connect(&path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));
        let reader = client.try_clone_box().unwrap();
        reader.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        Self {
            writer: client,
            reader: BufReader::new(reader),
            events: VecDeque::new(),
            next_id: 1,
            directory,
            handler: Some(handler),
        }
    }

    fn read_line(&mut self, deadline: Instant) -> Option<Value> {
        let mut line = String::new();
        while Instant::now() < deadline {
            match self.reader.read_line(&mut line) {
                Ok(0) => return None,
                Ok(_) if line.ends_with('\n') => return Some(serde_json::from_str(&line).unwrap()),
                Ok(_) => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(error) => panic!("read failed: {error}"),
            }
        }
        None
    }

    fn request(&mut self, mut value: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        value["id"] = json!(id);
        writeln!(self.writer, "{value}").unwrap();
        self.writer.flush().unwrap();
        let deadline = Instant::now() + WAIT;
        loop {
            let line = self.read_line(deadline).expect("no response before the deadline");
            if line.get("event").is_some() {
                self.events.push_back(line);
            } else if line["id"] == json!(id) {
                return line;
            }
        }
    }

    /// The next `agent-session-*` event (buffered first).
    fn event(&mut self, timeout: Duration) -> Option<Value> {
        if let Some(index) = self.events.iter().position(is_agent_event) {
            return self.events.remove(index);
        }
        let deadline = Instant::now() + timeout;
        loop {
            let line = self.read_line(deadline)?;
            if is_agent_event(&line) {
                return Some(line);
            }
        }
    }
}

fn is_agent_event(line: &Value) -> bool {
    line["event"].as_str().is_some_and(|event| event.starts_with("agent-session-"))
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(handler) = self.handler.take() {
            let _ = handler.join();
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

// MARK: Fixtures

fn mux_with(fake: &FakeAcpmux, label: &str) -> Arc<Mux> {
    let mux = Mux::new_for_test(label, crate::SurfaceOptions::default());
    mux.set_acpmux_socket(Some(fake.socket.clone()));
    mux
}

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

/// A workspace with one terminal; returns (terminal surface, its pane).
fn terminal_pane(mux: &Arc<Mux>) -> (SurfaceId, PaneId) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    (terminal, mux.with_state(|state| state.pane_of(terminal)).unwrap())
}

fn agent_tab(mux: &Arc<Mux>, session: Option<&str>) -> SurfaceId {
    let (_, pane) = terminal_pane(mux);
    let created = run(
        mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:brain","session":session,"harness":"claude"}}),
    );
    created["surface"].as_u64().unwrap()
}

fn attach(client: &mut Client, surface: SurfaceId) -> Value {
    client.request(json!({"cmd":"agent-session-attach","surface":surface,"limit":400,
                          "kinds":["transcript"]}))
}

fn assert_code(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert_eq!(reply["error_code"], json!(code), "{reply}");
}

// MARK: Capability and trust

#[test]
fn the_capability_is_advertised_only_with_an_acpmux_socket() {
    let fake = FakeAcpmux::start("cap");
    let mux = mux_with(&fake, "asa-cap");
    let identity = run(&mux, json!({"cmd":"identify"}));
    let advertised = |identity: &Value| {
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == AGENT_SESSION_ATTACH_CAPABILITY)
    };
    assert!(advertised(&identity));
    mux.set_acpmux_socket(None);
    assert!(!advertised(&run(&mux, json!({"cmd":"identify"}))));
}

#[test]
fn the_remote_relay_denies_every_agent_session_verb() {
    let fake = FakeAcpmux::start("relay");
    let mux = mux_with(&fake, "asa-relay");
    let surface = agent_tab(&mux, Some(SESSION));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    for frame in every_verb(surface) {
        assert!(remote_relay::gate::check_frame(&frame.to_string()).is_err());
        remote_relay::handle_frame(&mux, client, &frame.to_string(), &writer);
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_code(&reply, "remote_denied");
    }
    fake.no_connection();
}

/// One frame of every verb on `surface`.
fn every_verb(surface: SurfaceId) -> Vec<Value> {
    vec![
        json!({"id":1,"cmd":"agent-session-attach","surface":surface}),
        json!({"id":2,"cmd":"agent-session-events","surface":surface}),
        json!({"id":3,"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"}),
        json!({"id":4,"cmd":"agent-session-cancel","surface":surface}),
        json!({"id":5,"cmd":"agent-session-permission","surface":surface,
               "permission_id":"perm_attach","option_id":"allow"}),
        json!({"id":6,"cmd":"agent-session-detach","surface":surface}),
    ]
}

#[test]
fn every_verb_is_refused_on_every_untrusted_connection() {
    let fake = FakeAcpmux::start("untrusted");
    let mux = mux_with(&fake, "asa-untrusted");
    let surface = agent_tab(&mux, Some(SESSION));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    // A Unix connection that carries a paired install's link stamp is remote.
    mux.record_remote_check("inst_peer").unwrap();
    let stamped = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let peer = crate::remote_relay_state::LinkPeer {
        install: "inst_peer".into(),
        user: "42".into(),
        team: "team_a".into(),
    };
    mux.bind_remote_peer(stamped, &peer).unwrap();
    let unregistered = 999_999;
    for client in [websocket, stamped, unregistered] {
        for frame in every_verb(surface) {
            let handled =
                agent_session_attach::try_handle(&mux, client, &frame.to_string(), &writer);
            assert_eq!(handled, Some(true));
            let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
            assert_code(&reply, "agent_session.not_trusted");
        }
    }
    fake.no_connection();
}

// MARK: Scope

#[test]
fn attach_is_scoped_to_agent_tabs_of_this_store_with_a_session() {
    let fake = FakeAcpmux::start("scope");
    let mux = mux_with(&fake, "asa-scope");
    let (terminal, _) = terminal_pane(&mux);
    let unbound = agent_tab(&mux, None);
    let mut client = Client::connect(&mux, "scope");
    for surface in [terminal, unbound, 987_654] {
        assert_code(&attach(&mut client, surface), "agent_session.unknown_tab");
    }
    fake.no_connection();
}

#[test]
fn verbs_refuse_session_cwd_and_command_params() {
    let fake = FakeAcpmux::start("params");
    let mux = mux_with(&fake, "asa-params");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "params");
    for extra in [
        json!({"session":"other"}),
        json!({"sessionId":"other"}),
        json!({"cwd":"/"}),
        json!({"command":"rm -rf /"}),
        json!({"initial_command":"x"}),
        json!({"mcpServers":[]}),
        json!({"agent":"codex"}),
    ] {
        let mut frame = json!({"cmd":"agent-session-attach","surface":surface});
        for (key, value) in extra.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    fake.no_connection();
}

#[test]
fn prompt_cancel_and_permission_need_an_attachment() {
    let fake = FakeAcpmux::start("unattached");
    let mux = mux_with(&fake, "asa-unattached");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "unattached");
    for frame in [
        json!({"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"}),
        json!({"cmd":"agent-session-cancel","surface":surface}),
        json!({"cmd":"agent-session-events","surface":surface}),
        json!({"cmd":"agent-session-permission","surface":surface,
               "permission_id":"perm_attach","option_id":"allow"}),
    ] {
        assert_code(&client.request(frame), "agent_session.not_attached");
    }
    fake.no_connection();
}

// MARK: Streaming

#[test]
fn attach_replays_the_page_and_streams_live_records_of_that_session_only() {
    let mut fake = FakeAcpmux::start("stream");
    let mux = mux_with(&fake, "asa-stream");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "stream");
    let reply = attach(&mut client, surface);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["lastSeq"], json!(1));
    assert_eq!(reply["data"]["events"][0]["seq"], json!(1));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/attach"));
    assert_eq!(sent["params"]["sessionId"], json!(SESSION), "session comes from the store record");
    assert_eq!(sent["params"]["eventStream"], json!(true));
    assert_eq!(sent["params"]["kinds"], json!(["transcript"]));

    // The record acpmux sent before its reply follows the reply.
    let early = client.event(WAIT).expect("the early record");
    assert_eq!(early["event"], json!("agent-session-record"));
    assert_eq!(early["record"]["seq"], json!(2));

    fake.notify("_acpmux/event", json!({"sessionId":"acp_other","seq":9,"kind":"agent_message"}));
    fake.notify("_acpmux/session_changed", json!({"sessionId":"acp_other","kind":"status"}));
    fake.notify("_acpmux/event", json!({"sessionId":SESSION,"seq":3,"kind":"agent_message"}));
    fake.notify(
        "_acpmux/session_changed",
        json!({"sessionId":SESSION,"kind":"status","session":{"status":"idle"}}),
    );
    let event = client.event(WAIT).expect("a live record");
    assert_eq!(event["event"], json!("agent-session-record"));
    assert_eq!(event["surface"], json!(surface));
    assert_eq!(event["record"]["seq"], json!(3), "a record of another session is not forwarded");
    let changed = client.event(WAIT).expect("the session's status change");
    assert_eq!(changed["event"], json!("agent-session-changed"));
    assert_eq!(changed["change"]["session"]["status"], json!("idle"));
    assert!(client.event(Duration::from_millis(200)).is_none(), "nothing of other sessions");
}

#[test]
fn a_rebound_tab_ends_its_attachment_at_the_next_record() {
    let mut fake = FakeAcpmux::start("rebound");
    let mux = mux_with(&fake, "asa-rebound");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "rebound");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    run(
        &mux,
        json!({"cmd":"bind-conversation-tab-session","surface":surface,
               "session":"acp_session_2","expected_session":SESSION}),
    );
    fake.notify("_acpmux/event", json!({"sessionId":SESSION,"seq":3,"kind":"agent_message"}));
    let closed = client.event(WAIT).expect("a close");
    assert_eq!(
        closed,
        json!({"event":"agent-session-closed","surface":surface,"reason":"detached"})
    );
}

#[test]
fn pages_are_bounded_in_bytes_keeping_the_records_next_to_the_cursor() {
    use super::agent_session_attach::{MAX_PAGE_BYTES, bound_page};
    let big = "x".repeat(MAX_PAGE_BYTES / 3);
    let events: Vec<Value> = (1..=5).map(|seq| json!({"seq": seq, "text": big})).collect();
    let page = json!({"events": events, "hasMore": false});
    let seqs = |page: &Value| {
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["seq"].as_u64().unwrap())
            .collect::<Vec<_>>()
    };
    let newest = bound_page(page.clone(), true);
    assert_eq!(seqs(&newest), vec![4, 5]);
    assert_eq!(newest["hasMore"], json!(true));
    assert_eq!(seqs(&bound_page(page, false)), vec![1, 2]);
}

#[test]
fn events_pages_on_the_attachment_for_a_replay_after_a_gap() {
    let fake = FakeAcpmux::start("events");
    let mux = mux_with(&fake, "asa-events");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "events");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-session-events","surface":surface,
                                      "after_seq":1,"limit":100000}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/events"));
    assert_eq!(sent["params"]["sessionId"], json!(SESSION));
    assert_eq!(sent["params"]["afterSeq"], json!(1));
    assert_eq!(sent["params"]["limit"], json!(500), "pages are bounded");
}

#[test]
fn lag_and_acpmux_exit_end_the_attachment_with_a_reason() {
    let mut fake = FakeAcpmux::start("lag");
    let mux = mux_with(&fake, "asa-lag");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "lag");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    fake.notify("_acpmux/lagged", json!({"dropped": 3}));
    let closed = client.event(WAIT).expect("a close");
    assert_eq!(closed, json!({"event":"agent-session-closed","surface":surface,"reason":"lagged"}));
    // Attach again (the replay path), then acpmux goes away.
    let mut fake2 = FakeAcpmux::start("lag2");
    mux.set_acpmux_socket(Some(fake2.socket.clone()));
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    fake2.hang_up();
    let closed = client.event(WAIT).expect("a close");
    assert_eq!(closed["reason"], json!("acpmux_closed"));
}

// MARK: Driving the session

#[test]
fn a_prompt_is_one_text_block_on_the_pinned_session() {
    let fake = FakeAcpmux::start("prompt");
    let mux = mux_with(&fake, "asa-prompt");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "prompt");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-session-prompt","surface":surface,
                                      "prompt_id":"prompt-1","text":"hello there"}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["turn_id"], json!("turn_1"));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("session/prompt"));
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION,"prompt":[{"type":"text","text":"hello there"}],
               "_meta":{"acpmux":{"promptId":"prompt-1"}}})
    );
    for bad in [
        json!({"prompt_id":"p 2","text":"x"}),
        json!({"prompt_id":"p2","text":"   "}),
        json!({"prompt_id":"p2","text":"x".repeat(agent_session_attach::MAX_PROMPT_BYTES + 1)}),
        json!({"prompt_id":"p2","text":"x","prompt":[{"type":"resource_link","uri":"file:///etc"}]}),
    ] {
        let mut frame = json!({"cmd":"agent-session-prompt","surface":surface});
        for (key, value) in bad.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    fake.no_frame();
}

#[test]
fn cancel_goes_to_the_pinned_session() {
    let fake = FakeAcpmux::start("cancel");
    let mux = mux_with(&fake, "asa-cancel");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "cancel");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    assert_eq!(
        client.request(json!({"cmd":"agent-session-cancel","surface":surface}))["ok"],
        json!(true)
    );
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("session/cancel"));
    assert_eq!(sent["params"], json!({"sessionId": SESSION}));
    assert!(sent.get("id").is_none(), "cancel is a notification");
}

#[test]
fn permission_answers_only_announced_requests_once_and_never_by_itself() {
    let mut fake = FakeAcpmux::start("perm");
    let mux = mux_with(&fake, "asa-perm");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "perm");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let answer = |client: &mut Client, permission: &str| {
        client.request(json!({"cmd":"agent-session-permission","surface":surface,
                              "permission_id":permission,"option_id":"allow"}))
    };
    assert_code(&answer(&mut client, "perm_never_asked"), "agent_session.unknown_permission");
    let _ = client.event(WAIT).expect("the early record");
    fake.notify(
        "_acpmux/permission_pending",
        json!({"sessionId":SESSION,"permissionId":"perm_live",
                                                       "options":[{"optionId":"allow"}]}),
    );
    let shown = client.event(WAIT).expect("the request is shown to the user");
    assert_eq!(shown["event"], json!("agent-session-permission"));
    assert_eq!(shown["request"]["permissionId"], json!("perm_live"));
    // The daemon did not answer it by itself.
    fake.no_frame();
    assert_eq!(answer(&mut client, "perm_live")["ok"], json!(true));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/permission_respond"));
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION,"permissionId":"perm_live","optionId":"allow"})
    );
    assert_code(&answer(&mut client, "perm_live"), "agent_session.unknown_permission");
    // A request pending at attach time is answerable too.
    assert_eq!(answer(&mut client, "perm_attach")["ok"], json!(true));
}

// MARK: Lifecycle and bounds

#[test]
fn detach_and_disconnect_close_the_acpmux_link() {
    let fake = FakeAcpmux::start("detach");
    let mux = mux_with(&fake, "asa-detach");
    let first = agent_tab(&mux, Some(SESSION));
    let second = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "detach");
    assert_eq!(attach(&mut client, first)["ok"], json!(true));
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 1);
    assert_eq!(
        client.request(json!({"cmd":"agent-session-detach","surface":first}))["ok"],
        json!(true)
    );
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 0);
    assert_eq!(fake.frame()["method"], json!("_acpmux/attach"));
    assert_eq!(attach(&mut client, second)["ok"], json!(true));
    drop(client);
    let deadline = Instant::now() + WAIT;
    while mux.control_clients.agent_sessions.attachment_count() != 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 0);
}

#[test]
fn attachments_per_connection_are_bounded() {
    let fake = FakeAcpmux::start("limit");
    let mux = mux_with(&fake, "asa-limit");
    let mut client = Client::connect(&mux, "limit");
    for _ in 0..MAX_ATTACHMENTS_PER_CLIENT {
        let surface = agent_tab(&mux, Some(SESSION));
        assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    }
    let surface = agent_tab(&mux, Some(SESSION));
    assert_code(&attach(&mut client, surface), "agent_session.limit");
}

#[test]
fn a_closed_tab_ends_its_attachment() {
    let fake = FakeAcpmux::start("closed");
    let mux = mux_with(&fake, "asa-closed");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "closed");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    run(&mux, json!({"cmd":"close-surface","surface":surface}));
    let reply = client.request(json!({"cmd":"agent-session-prompt","surface":surface,
                                      "prompt_id":"p1","text":"hi"}));
    assert_code(&reply, "agent_session.unknown_tab");
    let mut closed = client.event(WAIT).expect("a close");
    if closed["event"] == json!("agent-session-record") {
        closed = client.event(WAIT).expect("a close");
    }
    assert_eq!(closed["reason"], json!("detached"));
    fake.no_frame();
}

// MARK: Scope (security review)

#[test]
fn a_record_that_names_a_session_only_by_prefix_is_not_attached() {
    let fake = FakeAcpmux::start("prefix");
    let mux = mux_with(&fake, "asa-prefix");
    // acpmux resolves a unique prefix; the fake resolves anything to SESSION.
    let surface = agent_tab(&mux, Some("acp_sess"));
    let mut client = Client::connect(&mux, "prefix");
    assert_code(&attach(&mut client, surface), "agent_session.unknown_tab");
    assert_eq!(mux.control_clients.agent_sessions.attachment_count(), 0);
}

#[test]
fn another_connection_cannot_drive_an_attachment() {
    let fake = FakeAcpmux::start("other");
    let mux = mux_with(&fake, "asa-other");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "owner");
    assert_eq!(attach(&mut owner, surface)["ok"], json!(true));
    let _ = fake.frame();
    let mut stranger = Client::connect(&mux, "stranger");
    for frame in every_verb(surface).into_iter().skip(1).take(4) {
        let mut frame = frame;
        frame.as_object_mut().unwrap().remove("id");
        assert_code(&stranger.request(frame), "agent_session.not_attached");
    }
    fake.no_frame();
}

#[test]
fn every_verb_refuses_session_cwd_command_and_meta_params() {
    let fake = FakeAcpmux::start("allparams");
    let mux = mux_with(&fake, "asa-allparams");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "allparams");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    for extra in [
        json!({"sessionId":"other"}),
        json!({"cwd":"/"}),
        json!({"command":"x"}),
        json!({"_meta":{"acpmux":{"steer":true}}}),
        json!({"prompt":[{"type":"text","text":"x"}]}),
    ] {
        for mut frame in every_verb(surface).into_iter().skip(1).take(4) {
            frame.as_object_mut().unwrap().remove("id");
            for (key, value) in extra.as_object().unwrap() {
                frame[key] = value.clone();
            }
            assert_code(&client.request(frame), "agent_session.bad_request");
        }
    }
    fake.no_frame();
}

#[test]
fn a_permission_of_another_session_is_not_answerable() {
    let mut fake = FakeAcpmux::start("otherperm");
    let mux = mux_with(&fake, "asa-otherperm");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "otherperm");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");
    fake.notify(
        "_acpmux/permission_pending",
        json!({"sessionId":"acp_other","permissionId":"perm_other","options":[]}),
    );
    assert!(client.event(Duration::from_millis(200)).is_none(), "not shown");
    let reply = client.request(json!({"cmd":"agent-session-permission","surface":surface,
                                      "permission_id":"perm_other","option_id":"allow"}));
    assert_code(&reply, "agent_session.unknown_permission");
    fake.no_frame();
}
