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
    tab_index(conn, surface).is_some()
}

/// The index of `surface` among its pane's tabs, if it is in the tree.
fn tab_index(conn: &mut Conn, surface: u64) -> Option<usize> {
    fn walk(value: &serde_json::Value, surface: u64) -> Option<usize> {
        match value {
            serde_json::Value::Object(object) => object
                .get("tabs")
                .and_then(serde_json::Value::as_array)
                .and_then(|tabs| {
                    tabs.iter().position(|tab| tab["surface"].as_u64() == Some(surface))
                })
                .or_else(|| object.values().find_map(|child| walk(child, surface))),
            serde_json::Value::Array(items) => items.iter().find_map(|child| walk(child, surface)),
            _ => None,
        }
    }
    let tree = conn.call(serde_json::json!({"cmd": "list-workspaces"}));
    walk(&tree, surface)
}

fn new_frontend_tab(conn: &mut Conn, pane: u64, owner: Option<&str>) -> serde_json::Value {
    let mut request = serde_json::json!({
        "cmd": "new-frontend-browser-tab", "pane": pane, "url": "https://example.com/",
        "engine": "cef",
    });
    if let Some(owner) = owner {
        request["owner"] = serde_json::json!(owner);
    }
    let created = conn.call(request);
    assert!(created["surface"].as_u64().is_some(), "no surface: {created}");
    created
}

#[test]
fn client_attention_keeps_typing_per_tab_and_ends_with_its_connection() {
    let server = HeadlessServer::start("client-attention");
    state_cli(&server, None, &["workspace", "create", "--name", "pages"]);
    let mut browser = Conn::open(&server);
    let mut reader = Conn::open(&server);
    assert!(capabilities(&mut reader).iter().any(|name| name == "client-attention-v1"));
    let pane = first_pane(&mut reader);
    let typed = new_frontend_tab(&mut reader, pane, None)["surface"].as_u64().unwrap();
    let other = new_frontend_tab(&mut reader, pane, None)["surface"].as_u64().unwrap();
    let typed_index = tab_index(&mut reader, typed).expect("typed tab in the tree");
    let other_index = tab_index(&mut reader, other).expect("other tab in the tree");
    let attention = |reader: &mut Conn, surface: u64| {
        reader.call(serde_json::json!({"cmd": "client-attention", "surface": surface}))
    };

    // The user types in one tab of the key window.
    let reply = browser.call(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": true, "app_active": true, "pane": pane, "tab": typed_index,
        "recent_input": [{"surface": typed, "ms_ago": 1_500}], "utc_offset_minutes": 120,
    }));
    assert_eq!(reply, serde_json::json!({}));
    let read = attention(&mut reader, typed);
    let tab = &read["tab_attention"];
    assert_eq!(tab["surface"], typed, "{read}");
    assert_eq!(tab["pane"], pane, "{read}");
    assert_eq!(tab["viewed"], true, "{read}");
    assert_eq!(tab["app_active"], true, "{read}");
    assert_eq!(tab["utc_offset_minutes"], 120, "{read}");
    // The age grows from the report: never smaller than what was reported.
    let age = tab["typed_ms_ago"].as_u64().unwrap_or_else(|| panic!("{read}"));
    assert!((1_500..60_000).contains(&age), "{read}");

    // Focus moves to the other tab. The typing stays with the first tab
    // (cmux-next keeps the last keystroke per tab), which is no longer viewed.
    browser.call(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": true, "app_active": true, "pane": pane, "tab": other_index,
        "recent_input": [{"surface": typed, "ms_ago": 1_600}],
    }));
    let read = attention(&mut reader, typed);
    assert_eq!(read["tab_attention"]["viewed"], false, "{read}");
    assert!(read["tab_attention"]["typed_ms_ago"].as_u64().is_some(), "{read}");
    let read = attention(&mut reader, other);
    assert_eq!(read["tab_attention"]["viewed"], true, "{read}");
    assert_eq!(read["tab_attention"]["typed_ms_ago"], serde_json::Value::Null, "{read}");

    // An inactive app views nothing.
    browser.call(serde_json::json!({
        "cmd": "report-client-attention", "client_id": "browser-window-1",
        "key_window": true, "app_active": false, "pane": pane, "tab": other_index,
    }));
    let read = attention(&mut reader, other);
    assert_eq!(read["tab_attention"]["viewed"], false, "{read}");
    assert_eq!(read["app_active"], false, "{read}");

    // Refusals change nothing.
    let too_many: Vec<serde_json::Value> =
        (0..17).map(|ms| serde_json::json!({"surface": typed, "ms_ago": ms})).collect();
    for refused in [
        serde_json::json!({"client_id": "", "key_window": false, "app_active": false}),
        serde_json::json!({"client_id": "browser-window-1", "key_window": false,
            "app_active": false, "pane": 999_999}),
        serde_json::json!({"client_id": "browser-window-1", "key_window": false,
            "app_active": false, "tab": 1}),
        serde_json::json!({"client_id": "browser-window-1", "key_window": false,
            "app_active": false, "recent_input": too_many}),
        serde_json::json!({"client_id": "browser-window-1", "key_window": false,
            "app_active": false, "utc_offset_minutes": 841}),
        serde_json::json!({"client_id": "browser-window-1", "key_window": false,
            "app_active": false, "utc_offset_minutes": i32::MIN}),
    ] {
        let mut request = refused.clone();
        request["cmd"] = serde_json::json!("report-client-attention");
        let reply = browser.reply(request);
        assert_eq!(reply["ok"], false, "{refused} was accepted: {reply}");
    }
    let read = reader.call(serde_json::json!({
        "cmd": "client-attention", "client_id": "browser-window-1",
    }));
    let record = &read["clients"][0];
    assert_eq!(record["key_window"], true, "{read}");
    assert_eq!(record["tab"], other_index, "{read}");
    assert_eq!(record["recent_input"], serde_json::json!([]), "{read}");

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
    // The longest deadline: these steps must not race the timeout.
    let close = serde_json::json!({
        "cmd": "request-frontend-browser-tab-close", "surface": surface, "deadline_ms": 30000,
    });

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
    assert_eq!(event["owner"], OWNER, "{event}");
    assert_eq!(event["tab_resource_id"], created["tab_resource_id"], "{event}");
    // The owner's event arrived first (above), so a stranger event sent
    // with it would be read by now.
    let _ = stranger.call(serde_json::json!({"cmd": "identify"}));
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
        "cmd": "report-frontend-browser-tab-removed", "surface": surface,
        "reason": "user_closed",
    }));
    assert_eq!(forged["ok"], false, "{forged}");
    assert_eq!(forged["error_code"], "origin.forbidden", "{forged}");
    assert!(tree_has_surface(&mut cli, surface));

    // 3. The close goes through: the tab leaves the store on the report.
    let asked = cli.call(close);
    let request_id = asked["request_id"].as_str().expect("request id").to_string();
    let event = browser.event("frontend-browser-tab-close-requested");
    assert_eq!(event["request_id"], request_id.as_str(), "{event}");
    browser.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id,
        "outcome": "closing",
    }));
    let report = serde_json::json!({
        "cmd": "report-frontend-browser-tab-removed", "surface": surface,
        "reason": "answered", "request_id": request_id, "origin": "cmux-browser", "mutation_id": "close-0i-1",
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

    // 4. A tab that leaves the store by another path (close-surface) gets no
    // removal report; its open request settles `removed` all the same.
    let elsewhere = new_frontend_tab(&mut cli, pane, Some(OWNER))["surface"].as_u64().unwrap();
    let kept = new_frontend_tab(&mut cli, pane, Some(OWNER))["surface"].as_u64().unwrap();
    let asked = cli.call(serde_json::json!({
        "cmd": "request-frontend-browser-tab-close", "surface": elsewhere, "deadline_ms": 30000,
    }));
    let request_id = asked["request_id"].as_str().expect("request id").to_string();
    browser.event("frontend-browser-tab-close-requested");
    cli.call(serde_json::json!({"cmd": "close-surface", "surface": elsewhere}));
    stranger.call(serde_json::json!({
        "cmd": "request-frontend-browser-tab-close", "surface": kept, "deadline_ms": 30000,
    }));
    let settled = cli.event("frontend-browser-tab-close-settled");
    assert_eq!(settled["request_id"], request_id.as_str(), "{settled}");
    assert_eq!(settled["outcome"], "removed", "{settled}");
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
        "cmd": "request-frontend-browser-tab-close", "surface": surface, "deadline_ms": 30000,
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

#[test]
fn an_owner_that_does_not_answer_in_time_must_close_the_tab() {
    const OWNER: &str = "cmux-browser-install-0i-slow";
    let server = HeadlessServer::start("frontend-tab-close-timed-out");
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

    // Out of range deadlines are bad requests.
    for deadline_ms in [0, 30001] {
        let refused = cli.reply(serde_json::json!({
            "cmd": "request-frontend-browser-tab-close", "surface": surface,
            "deadline_ms": deadline_ms,
        }));
        assert_eq!(refused["ok"], false, "deadline_ms {deadline_ms}: {refused}");
    }

    // The owner gets the request and does not answer.
    let asked = cli.call(serde_json::json!({
        "cmd": "request-frontend-browser-tab-close", "surface": surface, "deadline_ms": 200,
    }));
    let request_id = asked["request_id"].as_str().expect("request id").to_string();
    browser.event("frontend-browser-tab-close-requested");

    // Both the requester and the owner learn that the request timed out.
    for conn in [&mut cli, &mut browser] {
        let settled = conn.event("frontend-browser-tab-close-settled");
        assert_eq!(settled["request_id"], request_id.as_str(), "{settled}");
        assert_eq!(settled["surface"], surface, "{settled}");
        assert_eq!(settled["outcome"], "timed_out", "{settled}");
    }
    // The tab stays until the owner closes it; a late answer is refused.
    assert!(tree_has_surface(&mut cli, surface));
    let late = browser.call(serde_json::json!({
        "cmd": "answer-frontend-browser-tab-close", "request_id": request_id, "outcome": "cancelled",
    }));
    assert_eq!(late["accepted"], false, "{late}");

    // The owner closes the tab without a veto and reports the removal.
    let removed = browser.call(serde_json::json!({
        "cmd": "report-frontend-browser-tab-removed", "surface": surface, "reason": "answered",
        "request_id": request_id,
    }));
    assert_eq!(removed["removed"], true, "{removed}");
    assert!(!tree_has_surface(&mut cli, surface));
}
