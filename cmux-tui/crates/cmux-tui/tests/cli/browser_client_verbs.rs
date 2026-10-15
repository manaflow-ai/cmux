//! Daemon verbs for cmux-browser (rewrite unit 0i), through a real daemon
//! socket: per-client attention (`client-attention-v1`) and owner-decided
//! closes of frontend browser tabs (`frontend-tab-close-request-v1`).
//! Every client here is its own long-lived socket connection, as the
//! browser, the CLI and a page are in the product.
#![cfg(unix)]

use super::*;

/// One long-lived JSON-lines connection to the daemon. Replies are matched
/// by request id; targeted control events that arrive in between are kept
/// in order for [`Conn::event`].
struct Conn {
    writer: Box<dyn transport::Stream>,
    receiver: mpsc::Receiver<serde_json::Value>,
    events: VecDeque<serde_json::Value>,
    next_id: u64,
    reader_thread: Option<std::thread::JoinHandle<()>>,
}

const WAIT: Duration = Duration::from_secs(10);

impl Conn {
    fn open(server: &HeadlessServer) -> Self {
        let stream = transport::connect(&server.socket).expect("connect to the daemon socket");
        let writer = stream.try_clone_box().expect("clone the socket");
        let (sender, receiver) = mpsc::channel();
        let reader_thread = std::thread::spawn(move || {
            for line in BufReader::new(stream).lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else { break };
                if sender.send(value).is_err() {
                    break;
                }
            }
        });
        Self {
            writer,
            receiver,
            events: VecDeque::new(),
            next_id: 1,
            reader_thread: Some(reader_thread),
        }
    }

    /// Sends `request` and returns the whole reply (`ok`, `data`, `error_code`).
    fn reply(&mut self, mut request: serde_json::Value) -> serde_json::Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = serde_json::json!(id);
        writeln!(self.writer, "{request}").expect("write the request");
        self.writer.flush().expect("flush the request");
        let deadline = Instant::now() + WAIT;
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_else(|| panic!("no reply to {request}"));
            let message = self
                .receiver
                .recv_timeout(remaining)
                .unwrap_or_else(|_| panic!("no reply to {request}"));
            if message["id"].as_u64() == Some(id) {
                return message;
            }
            self.events.push_back(message);
        }
    }

    /// Sends `request` and returns its `data`; panics on an error reply.
    fn call(&mut self, request: serde_json::Value) -> serde_json::Value {
        let reply = self.reply(request.clone());
        assert_eq!(reply["ok"], true, "{request} failed: {reply}");
        reply["data"].clone()
    }

    /// The next control event named `name`; other events before it are dropped.
    fn event(&mut self, name: &str) -> serde_json::Value {
        if let Some(index) = self.events.iter().position(|event| event["event"] == name) {
            return self.events.remove(index).expect("event at index");
        }
        let deadline = Instant::now() + WAIT;
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_else(|| panic!("no {name} event"));
            let message =
                self.receiver.recv_timeout(remaining).unwrap_or_else(|_| panic!("no {name} event"));
            if message["event"] == name {
                return message;
            }
        }
    }

    /// True when an event named `name` already arrived (no wait).
    fn has_event(&mut self, name: &str) -> bool {
        while let Ok(message) = self.receiver.try_recv() {
            self.events.push_back(message);
        }
        self.events.iter().any(|event| event["event"] == name)
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }
}

fn capabilities(conn: &mut Conn) -> Vec<String> {
    let identify = conn.call(serde_json::json!({"cmd": "identify"}));
    identify["capabilities"]
        .as_array()
        .unwrap_or_else(|| panic!("no capabilities: {identify}"))
        .iter()
        .filter_map(|capability| capability.as_str().map(str::to_string))
        .collect()
}

/// The active pane of the first workspace.
fn first_pane(conn: &mut Conn) -> u64 {
    let tree = conn.call(serde_json::json!({"cmd": "list-workspaces"}));
    tree["workspaces"][0]["screens"][0]["active_pane"]
        .as_u64()
        .unwrap_or_else(|| panic!("no pane: {tree}"))
}

fn tree_has_surface(conn: &mut Conn, surface: u64) -> bool {
    fn walk(value: &serde_json::Value, surface: u64) -> bool {
        match value {
            serde_json::Value::Object(object) => {
                object.get("tabs").and_then(serde_json::Value::as_array).is_some_and(|tabs| {
                    tabs.iter().any(|tab| tab["surface"].as_u64() == Some(surface))
                }) || object.values().any(|child| walk(child, surface))
            }
            serde_json::Value::Array(items) => items.iter().any(|child| walk(child, surface)),
            _ => false,
        }
    }
    let tree = conn.call(serde_json::json!({"cmd": "list-workspaces"}));
    walk(&tree, surface)
}

#[test]
fn client_attention_keeps_the_latest_report_per_connection_until_it_ends() {
    let server = HeadlessServer::start("client-attention");
    state_cli(&server, None, &["workspace", "create", "--name", "pages"]);
    let mut browser = Conn::open(&server);
    let mut reader = Conn::open(&server);
    assert!(capabilities(&mut reader).iter().any(|name| name == "client-attention-v1"));
    let pane = first_pane(&mut reader);

    let first = browser.call(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": false, "pane": pane, "tab": 0, "last_input_ms_ago": 60_000,
    }));
    assert_eq!(first["coalesced"], false, "{first}");
    // A second report right away is still stored (latest wins), and the
    // daemon tells the client that it sends faster than 4 per second.
    let second = browser.call(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": true, "pane": pane, "tab": 0, "last_input_ms_ago": 1_500,
    }));
    assert_eq!(second["coalesced"], true, "{second}");

    let read = reader.call(serde_json::json!({"cmd": "client-attention", "pane": pane}));
    let clients = read["clients"].as_array().unwrap_or_else(|| panic!("no clients: {read}"));
    assert_eq!(clients.len(), 1, "{read}");
    let record = &clients[0];
    assert_eq!(record["client_id"], "browser-window-1", "{read}");
    assert_eq!(record["key_window"], true, "{read}");
    assert_eq!(record["app_active"], true, "a key window is an active app: {read}");
    assert_eq!(record["pane"], pane, "{read}");
    assert_eq!(record["tab"], 0, "{read}");
    // The age grows from the report: never smaller than what was reported,
    // and far from the older report's minute.
    let age = record["last_input_ms_ago"].as_u64().unwrap_or_else(|| panic!("{read}"));
    assert!((1_500..60_000).contains(&age), "{read}");
    assert_eq!(read["app_active"], true, "{read}");
    assert_eq!(read["pane_attention"]["viewed"], true, "{read}");
    assert_eq!(read["pane_attention"]["pane"], pane, "{read}");

    // Refusals change nothing.
    let bad_id = browser.reply(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "", "key_window": false,
    }));
    assert_eq!(bad_id["ok"], false, "{bad_id}");
    let dead_pane = browser.reply(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": false, "pane": 999_999,
    }));
    assert_eq!(dead_pane["ok"], false, "{dead_pane}");
    let tab_alone = browser.reply(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": false, "tab": 1,
    }));
    assert_eq!(tab_alone["ok"], false, "{tab_alone}");
    let read = reader.call(serde_json::json!({
        "cmd": "client-attention", "client_id": "browser-window-1",
    }));
    assert_eq!(read["clients"][0]["key_window"], true, "{read}");

    // The record ends with its connection.
    drop(browser);
    let deadline = Instant::now() + WAIT;
    loop {
        let read = reader.call(serde_json::json!({"cmd": "client-attention"}));
        if read["clients"].as_array().is_some_and(Vec::is_empty) {
            assert_eq!(read["app_active"], false, "{read}");
            break;
        }
        assert!(Instant::now() < deadline, "attention outlived its connection: {read}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn frontend_browser_tab_close_goes_through_its_owner_and_its_veto() {
    const OWNER: &str = "cmux-browser-install-0i";
    let server = HeadlessServer::start("frontend-tab-close");
    state_cli(&server, None, &["workspace", "create", "--name", "pages"]);
    let mut browser = Conn::open(&server);
    let mut cli = Conn::open(&server);
    let mut stranger = Conn::open(&server);
    assert!(capabilities(&mut cli).iter().any(|name| name == "frontend-tab-close-request-v1"));
    let pane = first_pane(&mut cli);
    let created = browser.call(serde_json::json!({
        "cmd": "new-frontend-browser-tab", "pane": pane, "url": "https://example.com/",
        "engine": "cef", "owner": OWNER,
    }));
    let surface = created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"));
    let close =
        serde_json::json!({"cmd": "request-frontend-browser-tab-close", "surface": surface});

    // No owner connection yet: nothing is asked and nothing changes.
    let undelegated = cli.call(close.clone());
    assert_eq!(undelegated, serde_json::json!({"delegated": false, "request_id": null}));
    assert!(tree_has_surface(&mut cli, surface));

    let ready = browser.call(serde_json::json!({
        "cmd": "frontend-browser-tab-close-subscribe", "owner": OWNER,
    }));
    assert_eq!(ready["close_requests_ready"], true, "{ready}");

    // 1. The page vetoes (beforeunload): the tab stays.
    let asked = cli.call(close.clone());
    assert_eq!(asked["delegated"], true, "{asked}");
    let request_id = asked["request_id"].as_str().expect("request id").to_string();
    let event = browser.event("frontend-browser-tab-close-requested");
    assert_eq!(event["request_id"], request_id.as_str(), "{event}");
    assert_eq!(event["surface"], surface, "{event}");
    assert_eq!(event["tab_resource_id"], created["tab_resource_id"], "{event}");
    assert!(!stranger.has_event("frontend-browser-tab-close-requested"));
    // A second request for the same tab joins the open one.
    let joined = stranger.call(close.clone());
    assert_eq!(joined["request_id"], request_id.as_str(), "{joined}");
    // Only the connection that got the event may answer.
    let foreign = stranger.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id,
        "outcome": "cancelled",
    }));
    assert_eq!(foreign["accepted"], false, "{foreign}");
    let closing = browser.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id,
        "outcome": "closing",
    }));
    assert_eq!(closing["accepted"], true, "{closing}");
    assert!(tree_has_surface(&mut cli, surface), "closing keeps the tab until the removal report");
    let vetoed = browser.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id,
        "outcome": "cancelled",
    }));
    assert_eq!(vetoed["accepted"], true, "{vetoed}");
    for requester in [&mut cli, &mut stranger] {
        let settled = requester.event("frontend-browser-tab-close-settled");
        assert_eq!(settled["request_id"], request_id.as_str(), "{settled}");
        assert_eq!(settled["outcome"], "cancelled", "{settled}");
    }
    let again = browser.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id,
        "outcome": "closing",
    }));
    assert_eq!(again["accepted"], false, "a settled request takes no answer: {again}");
    assert!(tree_has_surface(&mut cli, surface));

    // 2. Only the owner's connection decides that the tab is gone.
    let forged = stranger.reply(serde_json::json!({
        "cmd": "report-frontend-browser-tab-removed", "surface": surface, "reason": "closed",
    }));
    assert_eq!(forged["ok"], false, "{forged}");
    assert_eq!(forged["error_code"], "origin.forbidden", "{forged}");
    assert!(tree_has_surface(&mut cli, surface));

    // 3. The close goes through: the tab leaves the store on the report.
    let asked = cli.call(close.clone());
    let request_id = asked["request_id"].as_str().expect("request id").to_string();
    let event = browser.event("frontend-browser-tab-close-requested");
    assert_eq!(event["request_id"], request_id.as_str(), "{event}");
    browser.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id,
        "outcome": "closing",
    }));
    let report = serde_json::json!({
        "cmd": "report-frontend-browser-tab-removed", "surface": surface, "reason": "closed",
        "request_id": request_id, "origin": "cmux-browser", "mutation_id": "close-0i-1",
    });
    let removed = browser.call(report.clone());
    assert_eq!(removed, serde_json::json!({"removed": true, "replayed": false}));
    let settled = cli.event("frontend-browser-tab-close-settled");
    assert_eq!(settled["request_id"], request_id.as_str(), "{settled}");
    assert_eq!(settled["outcome"], "removed", "{settled}");
    assert!(!tree_has_surface(&mut cli, surface));
    // A retry of the same report replays the committed close.
    let retried = browser.call(report);
    assert_eq!(retried, serde_json::json!({"removed": true, "replayed": true}));
}

#[test]
fn an_owner_that_goes_away_leaves_its_tabs_and_settles_its_requests() {
    const OWNER: &str = "cmux-browser-install-0i-gone";
    let server = HeadlessServer::start("frontend-tab-close-owner-gone");
    state_cli(&server, None, &["workspace", "create", "--name", "pages"]);
    let mut browser = Conn::open(&server);
    let mut cli = Conn::open(&server);
    let pane = first_pane(&mut cli);
    let created = browser.call(serde_json::json!({
        "cmd": "new-frontend-browser-tab", "pane": pane, "url": "https://example.com/",
        "engine": "cef", "owner": OWNER,
    }));
    let surface = created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"));
    browser
        .call(serde_json::json!({"cmd": "frontend-browser-tab-close-subscribe", "owner": OWNER}));
    let asked = cli.call(serde_json::json!({
        "cmd": "request-frontend-browser-tab-close", "surface": surface,
    }));
    let request_id = asked["request_id"].as_str().expect("request id").to_string();
    browser.event("frontend-browser-tab-close-requested");

    drop(browser);
    let settled = cli.event("frontend-browser-tab-close-settled");
    assert_eq!(settled["request_id"], request_id.as_str(), "{settled}");
    assert_eq!(settled["outcome"], "owner_gone", "{settled}");
    assert!(tree_has_surface(&mut cli, surface), "the tab waits for its owner to come back");
    // With no owner connection the next request is not delegated.
    let undelegated = cli.call(serde_json::json!({
        "cmd": "request-frontend-browser-tab-close", "surface": surface,
    }));
    assert_eq!(undelegated["delegated"], false, "{undelegated}");
}
